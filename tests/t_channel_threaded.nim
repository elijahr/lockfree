## Multi-threaded integration tests for lockfree/channel (Channel Facade).

import std/options
import unittest2

import lockfree
import lockfree/channel
import lockfree/bqueue
import lockfree/queue
import lockfree/strategy
import lockfree/atomics
import lockfree/atomics/backoff

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

  test "bounded 4P/4C channel stress":
    const TotalItems = 2000
    const NumProducers = 4
    const NumConsumers = 4
    const PerProducer = TotalItems div NumProducers

    let (tx, rx) = newChannel[int](capacity = 256)
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

  test "unbounded 4P/4C channel stress":
    const TotalItems = 2000
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
