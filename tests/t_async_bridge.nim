## tests/t_async_bridge.nim
##
## Comprehensive test suite for Wave 3C Async Bridge (src/lockfree/async_bridge.nim)
## with std/asyncdispatch.

import std/[asyncdispatch, options, os]
import unittest2
import lockfree/atomics
import lockfree/strategy
import lockfree/bqueue
import lockfree/queue
import lockfree/rendezvous
import lockfree/broadcast
import lockfree/async_bridge

suite "AsyncBQueue (Bounded Async Queue)":
  test "basic sendAsync and recvAsync roundtrip":
    var q = newAsyncBQueue[int, ccSingle, ccSingle, 16, 0, 0]()
    check waitFor(q.sendAsync(42)) == true
    let popped = waitFor(q.recvAsync())
    check popped == some(42)

  test "FIFO ordering preserved":
    var q = newAsyncBQueue[int, ccSingle, ccSingle, 16, 0, 0]()
    check waitFor(q.sendAsync(1)) == true
    check waitFor(q.sendAsync(2)) == true
    check waitFor(q.sendAsync(3)) == true
    check waitFor(q.recvAsync()) == some(1)
    check waitFor(q.recvAsync()) == some(2)
    check waitFor(q.recvAsync()) == some(3)

  test "tryPopAsync speculative non-blocking execution":
    var q = newAsyncBQueue[int, ccSingle, ccSingle, 16, 0, 0]()
    # Empty queue returns none
    check waitFor(q.tryPopAsync()) == none(int)
    # Push item
    check q.push(99) == true
    # Now tryPopAsync returns some(99)
    check waitFor(q.tryPopAsync()) == some(99)
    check waitFor(q.tryPopAsync()) == none(int)

  test "consumer awaits until producer pushes":
    var q = newAsyncBQueue[int, ccSingle, ccSingle, 16, 0, 0]()
    var fut = q.recvAsync()
    check fut.finished == false
    check q.push(123) == true
    # Run event loop to dispatch wakeup
    poll(10)
    check fut.finished == true
    check waitFor(fut) == some(123)

  test "bounded backpressure: producer suspends when full":
    # Queue with capacity 2
    var q = newAsyncBQueue[int, ccSingle, ccSingle, 2, 0, 0]()
    check waitFor(q.sendAsync(10)) == true
    check waitFor(q.sendAsync(20)) == true
    # Third item should suspend
    var sendFut = q.sendAsync(30)
    check sendFut.finished == false

    # Pop one item; producer should wake and complete
    check waitFor(q.recvAsync()) == some(10)
    poll(10)
    check sendFut.finished == true
    check waitFor(sendFut) == true
    # Verify remaining items
    check waitFor(q.recvAsync()) == some(20)
    check waitFor(q.recvAsync()) == some(30)

  test "cross-thread producer to async consumer":
    var q = newAsyncBQueue[int, ccSingle, ccSingle, 16, 0, 0]()
    var th: Thread[ptr AsyncBQueue[int, ccSingle, ccSingle, 16, 0, 0]]
    createThread(th, proc(qp: ptr AsyncBQueue[int, ccSingle, ccSingle, 16, 0, 0]) {.thread.} =
      sleep(30)
      discard qp[].push(777)
    , addr q)

    let val = waitFor(q.recvAsync())
    check val == some(777)
    joinThread(th)

suite "AsyncQueue (Unbounded LCRQ Async Queue)":
  test "basic sendAsync and recvAsync roundtrip":
    var q = newAsyncQueue(AsyncQueueSpsc[int, 64, 1])
    check waitFor(q.sendAsync(100)) == true
    check waitFor(q.recvAsync()) == some(100)

  test "FIFO ordering":
    var q = newAsyncQueue(AsyncQueueSpsc[string, 64, 1])
    check waitFor(q.sendAsync("alpha")) == true
    check waitFor(q.sendAsync("beta")) == true
    check waitFor(q.sendAsync("gamma")) == true
    check waitFor(q.recvAsync()) == some("alpha")
    check waitFor(q.recvAsync()) == some("beta")
    check waitFor(q.recvAsync()) == some("gamma")

  test "tryPopAsync on empty and populated":
    var q = newAsyncQueue(AsyncQueueSpsc[int, 64, 1])
    check waitFor(q.tryPopAsync()) == none(int)
    check waitFor(q.sendAsync(555)) == true
    check waitFor(q.tryPopAsync()) == some(555)
    check waitFor(q.tryPopAsync()) == none(int)

suite "AsyncRendezvousChannel (Zero-Buffer Synchronous CSP)":
  test "coroutine-to-coroutine rendezvous handoff":
    var ch = newAsyncRendezvousChannel[string]()
    proc sender(c: AsyncRendezvousChannel[string]) {.async.} =
      await sleepAsync(20)
      discard await c.sendAsync("hello-csp")

    proc receiver(c: AsyncRendezvousChannel[string]): Future[string] {.async.} =
      let valOpt = await c.recvAsync()
      if valOpt.isSome:
        return valOpt.get()
      return ""

    asyncCheck sender(ch)
    let res = waitFor(receiver(ch))
    check res == "hello-csp"

  test "worker thread send to async coroutine recvAsync":
    var ch = newAsyncRendezvousChannel[int]()
    var th: Thread[ptr AsyncRendezvousChannel[int]]
    createThread(th, proc(cp: ptr AsyncRendezvousChannel[int]) {.thread.} =
      sleep(30)
      discard cp[].send(9876)
    , addr ch)

    let received = waitFor(ch.recvAsync())
    check received == some(9876)
    joinThread(th)

  test "async coroutine sendAsync to worker thread recv":
    type RecvThreadArg = object
      cp: ptr AsyncRendezvousChannel[int]
      outVal: ptr Atomic[int]

    var ch = newAsyncRendezvousChannel[int]()
    var receivedVal: Atomic[int]
    receivedVal.store(0, moRelaxed)

    var arg = RecvThreadArg(cp: addr ch, outVal: addr receivedVal)
    var th: Thread[ptr RecvThreadArg]
    createThread(th, proc(a: ptr RecvThreadArg) {.thread.} =
      sleep(30)
      var v: int
      discard a[].cp[].recv(v)
      a[].outVal[].store(v, moRelaxed)
    , addr arg)

    check waitFor(ch.sendAsync(54321)) == true
    joinThread(th)
    check receivedVal.load(moRelaxed) == 54321

  test "tryPopAsync on RendezvousChannel":
    var ch = newAsyncRendezvousChannel[int]()
    # No sender present -> returns none
    check waitFor(ch.tryPopAsync()) == none(int)

  test "bilateral CAS arbitration on cancellation (withTimeout)":
    var ch = newAsyncRendezvousChannel[int]()
    # Receiver awaits with short timeout when no sender arrives
    let ok = waitFor(withTimeout(ch.recvAsync(), 15))
    check ok == false
    # Channel must still be operational
    var sendTh: Thread[ptr AsyncRendezvousChannel[int]]
    createThread(sendTh, proc(cp: ptr AsyncRendezvousChannel[int]) {.thread.} =
      sleep(20)
      discard cp[].send(999)
    , addr ch)
    let val = waitFor(ch.recvAsync())
    check val == some(999)
    joinThread(sendTh)

suite "AsyncBroadcastRing & AsyncBroadcastCursor (Pub-Sub Multicast)":
  test "1-to-N fanout with async subscribers":
    var ring = newAsyncBroadcastRing[int](16)
    var c1 = ring.subscribe(soFromLatest)
    var c2 = ring.subscribe(soFromLatest)

    # Publish message
    check waitFor(ring.sendAsync(101)) == true
    check waitFor(ring.sendAsync(202)) == true

    # Both cursors receive both messages in sequence
    check waitFor(c1.recvAsync()) == some(101)
    check waitFor(c1.recvAsync()) == some(202)
    check waitFor(c2.recvAsync()) == some(101)
    check waitFor(c2.recvAsync()) == some(202)

  test "tryPopAsync on BroadcastCursor":
    var ring = newAsyncBroadcastRing[string](16)
    var c = ring.subscribe(soFromLatest)
    check waitFor(c.tryPopAsync()) == none(string)
    check waitFor(ring.sendAsync("stream-msg")) == true
    check waitFor(c.tryPopAsync()) == some("stream-msg")
    check waitFor(c.tryPopAsync()) == none(string)

  test "cross-thread publisher waking async subscriber":
    var ring = newAsyncBroadcastRing[int](16)
    var c = ring.subscribe(soFromLatest)

    var th: Thread[ptr AsyncBroadcastRing[int]]
    createThread(th, proc(rp: ptr AsyncBroadcastRing[int]) {.thread.} =
      sleep(30)
      rp[].publish(888)
    , addr ring)

    let val = waitFor(c.recvAsync())
    check val == some(888)
    joinThread(th)

suite "AsyncBridge Dekker Store-Load Stress & Zero Dropped Signals":
  test "AsyncBQueue high coroutine churn producer-consumer stress":
    var q = newAsyncBQueue[int, ccSingle, ccSingle, 8, 0, 0]()
    const TotalItems = 2000

    proc producer(queue: AsyncBQueue[int, ccSingle, ccSingle, 8, 0, 0]): Future[void] {.async.} =
      for i in 1..TotalItems:
        discard await queue.sendAsync(i)

    proc consumer(queue: AsyncBQueue[int, ccSingle, ccSingle, 8, 0, 0]): Future[seq[int]] {.async.} =
      result = @[]
      while result.len < TotalItems:
        let itemOpt = await queue.recvAsync()
        if itemOpt.isSome:
          result.add(itemOpt.get)

    let prodFut = producer(q)
    let consFut = consumer(q)
    let received = waitFor(consFut)
    waitFor(prodFut)
    check received.len == TotalItems
    for i in 0 ..< TotalItems:
      check received[i] == i + 1

  test "AsyncQueue high churn cross-thread producer to async consumer":
    var q = newAsyncQueue(AsyncQueueSpsc[int, 64, 1])
    const TotalItems = 3000

    type ProdArg = object
      qp: ptr AsyncQueueSpsc[int, 64, 1]

    var arg = ProdArg(qp: addr q)
    var th: Thread[ptr ProdArg]
    createThread(th, proc(a: ptr ProdArg) {.thread.} =
      for i in 1..TotalItems:
        discard a.qp[].sendAsync(i)
    , addr arg)

    proc consumer(queue: AsyncQueueSpsc[int, 64, 1]): Future[seq[int]] {.async.} =
      result = @[]
      while result.len < TotalItems:
        let itemOpt = await queue.recvAsync()
        if itemOpt.isSome:
          result.add(itemOpt.get)

    let received = waitFor(consumer(q))
    joinThread(th)
    check received.len == TotalItems
    for i in 0 ..< TotalItems:
      check received[i] == i + 1
