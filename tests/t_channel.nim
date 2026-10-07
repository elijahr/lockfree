## Unit and integration tests for lockfree/channel (Channel Facade).
##
## Verifies:
##   - Bounded channel semantics (capacity limits, FIFO, len/isFull/isEmpty).
##   - Unbounded channel semantics (segment growth, FIFO, len/isEmpty).
##   - Path-C payload transparency (POD, string, seq, ref object).
##   - Auto-registration for threads using thread-local storage.
##   - Multi-producer multi-consumer (MPMC) threaded worker pool.
##   - Channel[T] ergonomic wrapper object and tuple unpacking.
##   - Smart role-inferring withEndpoint macro on BQueue and Queue.

import std/options
import unittest2

import lockfree
import lockfree/channel
import lockfree/bqueue
import lockfree/queue
import lockfree/strategy
import lockfree/atomics
import lockfree/atomics/backoff

type
  DummyRefObj = ref object
    id: int
    name: string

suite "Channel Facade — Bounded Channels":
  test "basic send/recv and FIFO order":
    let (tx, rx) = newChannel[int](capacity = 16)
    check:
      tx.kind == ckBounded
      rx.kind == ckBounded
      rx.isEmpty
      not tx.isFull
      tx.len == 0

    check tx.send(1)
    check tx.send(2)
    check tx.send(3)

    check tx.len == 3
    check rx.len == 3
    check not rx.isEmpty

    check rx.recv() == some(1)
    check rx.recv() == some(2)
    check rx.recv() == some(3)
    check rx.recv() == none(int)
    check rx.isEmpty

  test "capacity saturation":
    let (tx, rx) = newChannel[int](capacity = 16)
    for i in 1 .. 16:
      check tx.send(i)

    check tx.isFull
    check not tx.send(999) # Channel full, must reject

    check rx.recv() == some(1)
    check not tx.isFull
    check tx.send(999) # Space freed, push succeeds

  test "close semantics":
    let (tx, rx) = newChannel[int](capacity = 16)
    check tx.send(100)
    check tx.send(200)

    check not tx.isClosed
    tx.close()
    check tx.isClosed
    check rx.isClosed

    # Cannot send to closed channel
    check not tx.send(300)

    # Receiver can drain remaining buffered items
    check rx.recv() == some(100)
    check rx.recv() == some(200)
    check rx.recv() == none(int)

  test "dynamic capacity":
    let (tx, rx) = newChannel[int](64)
    check tx.kind == ckBounded
    for i in 1 .. 50:
      check tx.send(i)
    for i in 1 .. 50:
      check rx.recv() == some(i)

suite "Channel Facade — Unbounded Channels":
  test "segment crossing growth":
    let (tx, rx) = newUnboundedChannel[int](segmentSize = 16)
    check:
      tx.kind == ckUnbounded
      rx.kind == ckUnbounded
      rx.isEmpty

    # Send 100 items (spans 7 segments of size 16)
    for i in 1 .. 100:
      check tx.send(i)

    check tx.len == 100
    check not rx.isEmpty

    for i in 1 .. 100:
      let item = rx.recv()
      check item == some(i)

    check rx.recv() == none(int)
    check rx.isEmpty

  test "dynamic segment size and close":
    let (tx, rx) = newUnboundedChannel[int](32)
    check tx.send(42)
    rx.close()
    check tx.isClosed
    check not tx.send(43) # Closed
    check rx.recv() == some(42)
    check rx.recv() == none(int)

suite "Channel Facade — ChannelConfig & Channel[T] Ergonomics":
  test "ChannelConfig bounded & unbounded construction":
    let cfgB = ChannelConfig(kind: ckBounded, capacity: 32)
    let (txB, rxB) = newChannel[int](cfgB)
    check txB.kind == ckBounded
    check txB.send(1)
    check rxB.recv() == some(1)

    let cfgU = ChannelConfig(kind: ckUnbounded, segmentSize: 32)
    let (txU, rxU) = newChannel[int](cfgU)
    check txU.kind == ckUnbounded
    check txU.send(2)
    check rxU.recv() == some(2)

  test "Channel[T] object API and tuple conversion":
    var ch = channel[string](capacity = 16)
    check ch.kind == ckBounded
    check ch.send("hello")
    check ch.trySend("world")
    check ch.len == 2

    check ch.recv() == some("hello")
    check ch.tryRecv() == some("world")
    check ch.recv() == none(string)

    # Tuple unpacking
    let (tx, rx) = ch.split()
    check tx.send("unpacked")
    check rx.recv() == some("unpacked")

  test "unboundedChannel[T] constructor":
    let ch = unboundedChannel[int](segmentSize = 16)
    check ch.kind == ckUnbounded
    check ch.send(777)
    check ch.recv() == some(777)

suite "Channel Facade — Path-C Payload Transparency":
  test "string payloads":
    let (tx, rx) = newChannel[string](capacity = 16)
    check tx.send("lockfree")
    check tx.send("channel")
    check rx.recv() == some("lockfree")
    check rx.recv() == some("channel")

  test "seq payloads":
    let (tx, rx) = newChannel[seq[int]](capacity = 16)
    check tx.send(@[1, 2, 3])
    check tx.send(@[4, 5])
    check rx.recv() == some(@[1, 2, 3])
    check rx.recv() == some(@[4, 5])

  test "ref object payloads":
    let (tx, rx) = newChannel[DummyRefObj](capacity = 16)
    let obj1 = DummyRefObj(id: 1, name: "alpha")
    let obj2 = DummyRefObj(id: 2, name: "beta")
    check tx.send(obj1)
    check tx.send(obj2)
    let r1 = rx.recv()
    let r2 = rx.recv()
    check r1.isSome and r1.get.id == 1 and r1.get.name == "alpha"
    check r2.isSome and r2.get.id == 2 and r2.get.name == "beta"

suite "Channel Facade — Multi-Threaded Worker Pool":
  type WorkerContext = object
    tx: Sender[int]
    rx: Receiver[int]
    producerId: int
    itemsPerProducer: int
    receivedCount: ptr Atomic[int]
    receivedArr: ptr array[2000, Atomic[bool]]

  proc producerWorker(ctx: WorkerContext) {.thread.} =
    let base = ctx.producerId * ctx.itemsPerProducer
    for i in 0 ..< ctx.itemsPerProducer:
      let item = base + i
      while not ctx.tx.send(item):
        cpuPause()

  proc consumerWorker(ctx: WorkerContext) {.thread.} =
    while ctx.receivedCount[].load(moRelaxed) < 2000:
      let itemOpt = ctx.rx.recv()
      if itemOpt.isSome:
        let val = itemOpt.get
        if val >= 0 and val < 2000:
          if not ctx.receivedArr[val].exchange(true, moRelaxed):
            discard ctx.receivedCount[].fetchAdd(1, moRelaxed)
      else:
        cpuPause()

  test "bounded 4P/4C worker pool auto-registration":
    let (tx, rx) = newChannel[int](capacity = 64)
    var receivedArr: array[2000, Atomic[bool]]
    for i in 0 ..< 2000:
      receivedArr[i].store(false, moRelaxed)
    var receivedCount: Atomic[int]
    receivedCount.store(0, moRelaxed)

    var pThreads: array[4, Thread[WorkerContext]]
    var cThreads: array[4, Thread[WorkerContext]]

    for i in 0 ..< 4:
      createThread(cThreads[i], consumerWorker, WorkerContext(
        rx: rx, receivedCount: addr receivedCount, receivedArr: addr receivedArr
      ))

    for i in 0 ..< 4:
      createThread(pThreads[i], producerWorker, WorkerContext(
        tx: tx, producerId: i, itemsPerProducer: 500
      ))

    for i in 0 ..< 4:
      joinThread(pThreads[i])
    for i in 0 ..< 4:
      joinThread(cThreads[i])

    check receivedCount.load(moRelaxed) == 2000
    for i in 0 ..< 2000:
      check receivedArr[i].load(moRelaxed)

  test "unbounded 4P/4C worker pool auto-registration":
    let (tx, rx) = newUnboundedChannel[int](segmentSize = 32)
    var receivedArr: array[2000, Atomic[bool]]
    for i in 0 ..< 2000:
      receivedArr[i].store(false, moRelaxed)
    var receivedCount: Atomic[int]
    receivedCount.store(0, moRelaxed)

    var pThreads: array[4, Thread[WorkerContext]]
    var cThreads: array[4, Thread[WorkerContext]]

    for i in 0 ..< 4:
      createThread(cThreads[i], consumerWorker, WorkerContext(
        rx: rx, receivedCount: addr receivedCount, receivedArr: addr receivedArr
      ))

    for i in 0 ..< 4:
      createThread(pThreads[i], producerWorker, WorkerContext(
        tx: tx, producerId: i, itemsPerProducer: 500
      ))

    for i in 0 ..< 4:
      joinThread(pThreads[i])
    for i in 0 ..< 4:
      joinThread(cThreads[i])

    check receivedCount.load(moRelaxed) == 2000
    for i in 0 ..< 2000:
      check receivedArr[i].load(moRelaxed)

  type StressWorkerContext = object
    tx: Sender[int]
    rx: Receiver[int]
    producerId: int
    itemsPerProducer: int
    totalExpected: int
    receivedCount: ptr Atomic[int]

  proc stressProducerWorker(ctx: StressWorkerContext) {.thread.} =
    let base = ctx.producerId * ctx.itemsPerProducer
    for i in 0 ..< ctx.itemsPerProducer:
      let item = base + i
      while not ctx.tx.send(item):
        cpuPause()

  proc stressConsumerWorker(ctx: StressWorkerContext) {.thread.} =
    while ctx.receivedCount[].load(moRelaxed) < ctx.totalExpected:
      let itemOpt = ctx.rx.recv()
      if itemOpt.isSome:
        discard ctx.receivedCount[].fetchAdd(1, moRelaxed)
      else:
        cpuPause()

  test "bounded 4P/4C channel 100k stress":
    const TotalItems = 100_000
    const NumProducers = 4
    const NumConsumers = 4
    const PerProducer = TotalItems div NumProducers

    let (tx, rx) = newChannel[int](capacity = 1024)
    var receivedCount: Atomic[int]
    receivedCount.store(0, moRelaxed)

    var pThreads: array[NumProducers, Thread[StressWorkerContext]]
    var cThreads: array[NumConsumers, Thread[StressWorkerContext]]

    for i in 0 ..< NumConsumers:
      createThread(cThreads[i], stressConsumerWorker, StressWorkerContext(
        rx: rx, totalExpected: TotalItems, receivedCount: addr receivedCount
      ))

    for i in 0 ..< NumProducers:
      createThread(pThreads[i], stressProducerWorker, StressWorkerContext(
        tx: tx, producerId: i, itemsPerProducer: PerProducer
      ))

    for i in 0 ..< NumProducers:
      joinThread(pThreads[i])
    for i in 0 ..< NumConsumers:
      joinThread(cThreads[i])

    check receivedCount.load(moRelaxed) == TotalItems

  test "unbounded 4P/4C channel 100k stress":
    const TotalItems = 100_000
    const NumProducers = 4
    const NumConsumers = 4
    const PerProducer = TotalItems div NumProducers

    let (tx, rx) = newUnboundedChannel[int](segmentSize = 64)
    var receivedCount: Atomic[int]
    receivedCount.store(0, moRelaxed)

    var pThreads: array[NumProducers, Thread[StressWorkerContext]]
    var cThreads: array[NumConsumers, Thread[StressWorkerContext]]

    for i in 0 ..< NumConsumers:
      createThread(cThreads[i], stressConsumerWorker, StressWorkerContext(
        rx: rx, totalExpected: TotalItems, receivedCount: addr receivedCount
      ))

    for i in 0 ..< NumProducers:
      createThread(pThreads[i], stressProducerWorker, StressWorkerContext(
        tx: tx, producerId: i, itemsPerProducer: PerProducer
      ))

    for i in 0 ..< NumProducers:
      joinThread(pThreads[i])
    for i in 0 ..< NumConsumers:
      joinThread(cThreads[i])

    check receivedCount.load(moRelaxed) == TotalItems

suite "Smart withEndpoint Macro":
  test "BQueue auto-infers producer on dot-push":
    var bq = newBQueue[int, ccMulti, ccMulti, 16, 4, 4]()
    withEndpoint(bq, ep):
      check ep.push(111)
      check ep.push(222)

    withEndpoint(bq, ep):
      check ep.pop() == some(111)
      check ep.pop() == some(222)

  test "BQueue auto-infers consumer on prefix-pop":
    var bq = newBQueue[int, ccMulti, ccMulti, 16, 4, 4]()
    withEndpoint(bq, prod):
      check push(prod, 333)

    withEndpoint(bq, cons):
      check pop(cons) == some(333)

  test "Queue (unbounded) auto-infers producer and consumer":
    var uq = newUnboundedMpmcQueue[int, stEager, 16, 4]()
    withEndpoint(uq, prod):
      prod.push(444)
      prod.push(555)

    withEndpoint(uq, cons):
      check cons.pop() == some(444)
      check cons.pop() == some(555)
