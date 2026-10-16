## tests/t_async_bridge.nim
##
## Comprehensive test suite for Async Bridge (src/lockfree/async_bridge.nim)
## under both std/asyncdispatch and Chronos (-d:lockfreeChronos).

import std/[options, os]
when defined(lockfreeChronos):
  import chronos
  template spawnAsync(fut: untyped) =
    asyncSpawn fut
  proc sleepMs(ms: int): Future[void] =
    sleepAsync(milliseconds(ms))
  proc timeoutMs[T](fut: Future[T], ms: int): Future[bool] =
    withTimeout(fut, milliseconds(ms))
  proc stepLoop() =
    waitFor(sleepAsync(milliseconds(5)))
else:
  import std/asyncdispatch
  template spawnAsync(fut: untyped) =
    asyncCheck fut
  proc sleepMs(ms: int): Future[void] =
    sleepAsync(ms)
  proc timeoutMs[T](fut: Future[T], ms: int): Future[bool] {.used.} =
    withTimeout(fut, ms)
  proc stepLoop() =
    try:
      poll(10)
    except ValueError:
      discard

import unittest2
import lockfree/atomics
import lockfree/strategy
import lockfree/bqueue
import lockfree/queue
import lockfree/rendezvous
import lockfree/broadcast
import lockfree/deque
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
    check waitFor(q.tryPopAsync()) == none(int)
    check q.push(99) == true
    check waitFor(q.tryPopAsync()) == some(99)
    check waitFor(q.tryPopAsync()) == none(int)

  test "consumer awaits until producer pushes":
    var q = newAsyncBQueue[int, ccSingle, ccSingle, 16, 0, 0]()
    var fut = q.recvAsync()
    check fut.finished == false
    check q.push(123) == true
    stepLoop()
    check waitFor(fut) == some(123)

  test "bounded backpressure: producer suspends when full":
    var q = newAsyncBQueue[int, ccSingle, ccSingle, 2, 0, 0]()
    check waitFor(q.sendAsync(10)) == true
    check waitFor(q.sendAsync(20)) == true
    var sendFut = q.sendAsync(30)
    check sendFut.finished == false

    check waitFor(q.recvAsync()) == some(10)
    stepLoop()
    check waitFor(sendFut) == true
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

  test "synchronous push and trySend wake async consumer without Future allocation":
    var q = newAsyncQueue(AsyncQueueSpsc[int, 64, 1])
    var recvFut = q.recvAsync()
    check recvFut.finished == false
    check q.push(314) == true
    check waitFor(recvFut) == some(314)
    check q.trySend(271) == true
    check waitFor(q.recvAsync()) == some(271)

suite "AsyncRendezvousChannel (Zero-Buffer Synchronous CSP)":
  test "coroutine-to-coroutine rendezvous handoff":
    var ch = newAsyncRendezvousChannel[string]()
    proc sender(c: AsyncRendezvousChannel[string]): Future[void] {.async.} =
      await sleepMs(20)
      discard await c.sendAsync("hello-csp")

    proc receiver(c: AsyncRendezvousChannel[string]): Future[string] {.async.} =
      let valOpt = await c.recvAsync()
      if valOpt.isSome:
        return valOpt.get()
      return ""

    spawnAsync sender(ch)
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
    check waitFor(ch.tryPopAsync()) == none(int)

  test "bilateral CAS arbitration on cancellation (withTimeout)":
    var ch = newAsyncRendezvousChannel[int]()
    when defined(lockfreeChronos):
      let ok = waitFor(timeoutMs(ch.recvAsync(), 15))
      check ok == false
      stepLoop()
    else:
      var parkedFut = ch.recvAsync()
      check ch.receiverSignal.waiters.len == 1
      ch.receiverSignal.waiters[0].fail(newException(ValueError, "cancelled"))
      stepLoop()
      stepLoop()
      check parkedFut.failed == true
      check ch.receiverSignal.waiters.len == 0
    var sendTh: Thread[ptr AsyncRendezvousChannel[int]]
    createThread(sendTh, proc(cp: ptr AsyncRendezvousChannel[int]) {.thread.} =
      sleep(20)
      discard cp[].send(999)
    , addr ch)
    let val = waitFor(ch.recvAsync())
    check val == some(999)
    joinThread(sendTh)

  test "Scherer-Scott dual queue strict FIFO ordering across parked async receivers":
    var ch = newAsyncRendezvousChannel[int]()
    var r1 = ch.recvAsync()
    var r2 = ch.recvAsync()
    check r1.finished == false
    check r2.finished == false
    check waitFor(ch.sendAsync(111)) == true
    check waitFor(r1) == some(111)
    check r2.finished == false
    check waitFor(ch.sendAsync(222)) == true
    check waitFor(r2) == some(222)
    ch.close()

suite "AsyncBroadcastRing & AsyncBroadcastCursor (Pub-Sub Multicast)":
  test "1-to-N fanout with async subscribers":
    var ring = newAsyncBroadcastRing[int](16)
    var c1 = ring.subscribe(soFromLatest)
    var c2 = ring.subscribe(soFromLatest)

    check waitFor(ring.sendAsync(101)) == true
    check waitFor(ring.sendAsync(202)) == true

    check waitFor(c1.recvAsync()) == some(101)
    check waitFor(c1.recvAsync()) == some(202)
    check waitFor(c2.recvAsync()) == some(101)
    check waitFor(c2.recvAsync()) == some(202)

    c1.unsubscribe()
    c2.unsubscribe()

  test "concurrent parked subscribers all wake on single publish (per-cursor signal isolation)":
    var ring = newAsyncBroadcastRing[int](16)
    var c1 = ring.subscribe(soFromLatest)
    var c2 = ring.subscribe(soFromLatest)
    var c3 = ring.subscribe(soFromLatest)

    # Park all 3 subscribers BEFORE publishing
    var f1 = c1.recvAsync()
    var f2 = c2.recvAsync()
    var f3 = c3.recvAsync()
    check f1.finished == false
    check f2.finished == false
    check f3.finished == false

    ring.publish(4242)
    check waitFor(f1) == some(4242)
    check waitFor(f2) == some(4242)
    check waitFor(f3) == some(4242)

    c1.unsubscribe()
    c2.unsubscribe()
    c3.unsubscribe()

  test "unsubscribe releases cursor table slots and unblocks parked reader":
    var ring = newAsyncBroadcastRing[int](capacity = 16, maxReaders = 2)
    for round in 0 ..< 6:
      var c = ring.subscribe(soFromLatest)
      check ring.subscriberCount == 1
      c.unsubscribe()
      check ring.subscriberCount == 0
      check c.isClosed == true

    var cParked = ring.subscribe(soFromLatest)
    var recvFut = cParked.recvAsync()
    check recvFut.finished == false
    cParked.close()
    check waitFor(recvFut) == none(int)

  test "pollAsync surfaces prLagged(skippedCount) and recvAsync auto-advances on lag":
    # Minimum ring capacity is 16
    var ring = newAsyncBroadcastRing[int](capacity = 16, overflowMode = omDropOldest)
    var cPoll = ring.subscribe(soFromLatest)
    var cRecv = ring.subscribe(soFromLatest)

    # Publish 20 items into a capacity-16 ring; slot 0 is overwritten on lap 2 by seq 17
    for i in 1 .. 20:
      ring.publish(i)

    # pollAsync surfaces explicit prLagged(skippedCount = 16) first, then item 17
    let p1 = waitFor(cPoll.pollAsync())
    check p1.kind == prLagged
    check p1.skippedCount == 16'u64
    let p2 = waitFor(cPoll.pollAsync())
    check p2.kind == prSuccess
    check p2.val == 17

    # recvAsync automatically skips over prLagged without sleeping and returns item 17
    let r1 = waitFor(cRecv.recvAsync())
    check r1 == some(17)
    check cRecv.lag == 16'u64

    cPoll.unsubscribe()
    cRecv.unsubscribe()

  test "waitReadable suspends until readable without consuming message":
    var ring = newAsyncBroadcastRing[string](16)
    var c = ring.subscribe(soFromLatest)
    check c.isReadable == false

    var waitFut = c.waitReadable()
    check waitFut.finished == false

    ring.publish("peek-THEN-pop")
    check waitFor(waitFut) == true
    check c.isReadable == true
    check waitFor(c.recvAsync()) == some("peek-THEN-pop")
    check c.isReadable == false

    c.unsubscribe()

  test "omBackoff lossless backpressure: sendAsync suspends when full and wakes on poll or unsubscribe":
    var ring = newAsyncBroadcastRing[int](capacity = 16, overflowMode = omBackoff)
    var cSlow = ring.subscribe(soFromLatest)
    var cFast = ring.subscribe(soFromLatest)

    for i in 1 .. 16:
      check waitFor(ring.sendAsync(i)) == true
      check waitFor(cFast.recvAsync()) == some(i)

    # cSlow is still at seq 0, so ring is full under omBackoff
    var p1Fut = ring.sendAsync(17)
    var p2Fut = ring.sendAsync(18)
    check p1Fut.finished == false
    check p2Fut.finished == false

    # cSlow reads 1 item -> unblocks the first waiting producer (p1Fut) in FIFO order
    check waitFor(cSlow.recvAsync()) == some(1)
    check waitFor(p1Fut) == true
    check p2Fut.finished == false

    # Queue a third producer while p2Fut is still parked; unsubscribing cSlow
    # unblocks all remaining stalled producers (p2Fut then p3Fut) in strict FIFO order
    var p3Fut = ring.sendAsync(19)
    check p3Fut.finished == false
    cSlow.unsubscribe()
    check waitFor(p2Fut) == true
    check waitFor(p3Fut) == true

    check waitFor(cFast.recvAsync()) == some(17)
    check waitFor(cFast.recvAsync()) == some(18)
    check waitFor(cFast.recvAsync()) == some(19)
    cFast.unsubscribe()
    ring.close()

  test "tryPopAsync on BroadcastCursor":
    var ring = newAsyncBroadcastRing[string](16)
    var c = ring.subscribe(soFromLatest)
    check waitFor(c.tryPopAsync()) == none(string)
    check waitFor(ring.sendAsync("stream-msg")) == true
    check waitFor(c.tryPopAsync()) == some("stream-msg")
    check waitFor(c.tryPopAsync()) == none(string)
    c.unsubscribe()

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
    c.unsubscribe()

suite "AsyncTopicBus (Multiplexed Pub-Sub Topic Router)":
  test "multi-topic isolation and async fanout":
    var bus = newAsyncTopicBus[string]()
    var subOrders1 = bus.subscribe("orders", soFromLatest)
    var subOrders2 = bus.subscribe("orders", soFromLatest)
    var subMetrics = bus.subscribe("metrics", soFromLatest)

    check bus.hasTopic("orders") == true
    check bus.hasTopic("metrics") == true
    check bus.hasTopic("unknown") == false
    check bus.topicCount == 2

    var fOrd1 = subOrders1.recvAsync()
    var fOrd2 = subOrders2.recvAsync()
    var fMet = subMetrics.recvAsync()

    check waitFor(bus.sendAsync("orders", "order-100")) == true
    bus.publish("metrics", "cpu=42%")

    check waitFor(fOrd1) == some("order-100")
    check waitFor(fOrd2) == some("order-100")
    check waitFor(fMet) == some("cpu=42%")

    subOrders1.unsubscribe()
    subOrders2.unsubscribe()
    subMetrics.unsubscribe()

  test "toAsync(TopicBus) preserves custom TopicBusConfig":
    let customCfg = TopicBusConfig(
      defaultRingCapacity: 32,
      defaultOverflowMode: omBackoff,
      defaultMaxReaders: 8
    )
    var syncBus = initTopicBus[int](customCfg)
    var asyncBus = syncBus.toAsync()
    check asyncBus.config.defaultRingCapacity == 32
    check asyncBus.config.defaultOverflowMode == omBackoff
    check asyncBus.config.defaultMaxReaders == 8
    var sub = asyncBus.subscribe("cfg-topic", soFromLatest)
    check waitFor(asyncBus.sendAsync("cfg-topic", 77)) == true
    check waitFor(sub.recvAsync()) == some(77)
    sub.unsubscribe()

  test "lock-free Ctrie topic routing across many topics and shared underlying TopicBus":
    var syncBus = initTopicBus[int]()
    var asyncBus = syncBus.toAsync()
    var subs: seq[AsyncBroadcastCursor[int]] = @[]
    for i in 0 ..< 16:
      subs.add(asyncBus.subscribe("topic-" & $i, soFromLatest))
    check asyncBus.topicCount == 16
    check syncBus.topicCount == 16
    for i in 0 ..< 16:
      # Publish via synchronous TopicBus for even indices, asyncBus for odd indices
      if (i and 1) == 0:
        syncBus.publish("topic-" & $i, i * 10)
        # Wake async cursor via asyncBus ring
        asyncBus.getOrCreateTopicRing("topic-" & $i).notifyCursors()
      else:
        check waitFor(asyncBus.sendAsync("topic-" & $i, i * 10)) == true
    for i in 0 ..< 16:
      check waitFor(subs[i].recvAsync()) == some(i * 10)
      subs[i].unsubscribe()

suite "AsyncChaseLevDeque (Work-Stealing Deque Async Thief Parking)":
  test "owner LIFO popBottom vs async thief FIFO stealAsync":
    var dq = newAsyncChaseLevDeque[int](64)
    dq.pushBottom(10)
    dq.pushBottom(20)
    dq.pushBottom(30)

    # Thief steals from top (FIFO -> 10)
    check waitFor(dq.stealAsync()) == some(10)
    # Owner pops from bottom (LIFO -> 30)
    check dq.popBottom() == some(30)
    # Thief steals remaining item (20)
    check waitFor(dq.tryStealAsync()) == some(20)
    check waitFor(dq.tryStealAsync()) == none(int)

  test "zero-spin thief parking on empty deque wakes on owner pushBottom":
    var dq = newAsyncChaseLevDeque[int](64)
    var stealFut = dq.stealAsync()
    check stealFut.finished == false
    check dq.waitingThieves.load(moSequentiallyConsistent) == 1

    dq.pushBottom(9001)
    check waitFor(stealFut) == some(9001)
    check dq.waitingThieves.load(moSequentiallyConsistent) == 0

  test "cascading multi-thief wakeups when multiple items available":
    var dq = newAsyncChaseLevDeque[int](64)
    var t1 = dq.stealAsync()
    var t2 = dq.stealAsync()
    var t3 = dq.stealAsync()
    check dq.waitingThieves.load(moSequentiallyConsistent) == 3

    dq.pushBottom(1)
    dq.pushBottom(2)
    dq.pushBottom(3)

    let v1 = waitFor(t1)
    let v2 = waitFor(t2)
    let v3 = waitFor(t3)
    check v1.isSome and v2.isSome and v3.isSome
    check (v1.get + v2.get + v3.get) == 6
    check dq.waitingThieves.load(moSequentiallyConsistent) == 0

  test "stealBatchAsync suspends when empty and steals batch on wakeup":
    var dq = newAsyncChaseLevDeque[int](64)
    var batchFut = dq.stealBatchAsync(maxItems = 3)
    check batchFut.finished == false

    for i in 1 .. 6:
      dq.pushBottom(i * 10)

    let stolen = waitFor(batchFut)
    check stolen == @[10, 20, 30]
    let rest = waitFor(dq.stealBatchAsync(maxItems = 10))
    check rest == @[40, 50, 60]

  test "cross-thread worker pushBottom waking async thief":
    var dq = newAsyncChaseLevDeque[int](64)
    var th: Thread[ptr AsyncChaseLevDeque[int]]
    createThread(th, proc(dp: ptr AsyncChaseLevDeque[int]) {.thread.} =
      sleep(30)
      dp[].pushBottom(4321)
    , addr dq)

    let stolen = waitFor(dq.stealAsync())
    check stolen == some(4321)
    joinThread(th)

  test "thief timeout/cancellation cleans up waitingThieves and thiefSignal waiters":
    var dq = newAsyncChaseLevDeque[int](64)
    when defined(lockfreeChronos):
      let ok = waitFor(timeoutMs(dq.stealAsync(), 15))
      check ok == false
      stepLoop()
      check dq.waitingThieves.load(moSequentiallyConsistent) == 0
      check dq.thiefSignal.waiters.len == 0
      dq.pushBottom(55)
      check waitFor(dq.stealAsync()) == some(55)
      dq.close()
    else:
      var parkedFut = dq.stealAsync()
      check dq.waitingThieves.load(moSequentiallyConsistent) == 1
      check dq.thiefSignal.waiters.len == 1
      # Trigger exception unwinding on the parked signal waiter in std/asyncdispatch
      dq.thiefSignal.waiters[0].fail(newException(ValueError, "cancelled"))
      stepLoop()
      stepLoop()
      check parkedFut.failed == true
      check dq.waitingThieves.load(moSequentiallyConsistent) == 0
      check dq.thiefSignal.waiters.len == 0
      dq.pushBottom(55)
      check waitFor(dq.stealAsync()) == some(55)
      dq.close()
      stepLoop()
      stepLoop()

  test "close wakes parked thieves with none / empty batch":
    var dq = newAsyncChaseLevDeque[int](64)
    var sFut = dq.stealAsync()
    var bFut = dq.stealBatchAsync()
    check sFut.finished == false
    check bFut.finished == false

    dq.close()
    check dq.isClosed == true
    check waitFor(sFut) == none(int)
    check waitFor(bFut).len == 0

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
        discard a.qp[].push(i)
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
