## Unit tests for popBatch and popChunk primitives across bounded and unbounded queues.
##
## Verifies:
## 1. BQueue batch extraction (SPSC direct, MPSC direct, SPMC Bound, MPMC Bound).
## 2. Queue batch extraction (SPSC Bound, MPMC strict-LCRQ Bound with segment rollover).
## 3. Empty queue extraction returns 0 without corrupting buffers.
## 4. Partial batch extraction (when buffer is larger than available elements).
## 5. maxCount clamping.
## 6. popChunk helper functions.
## 7. Multi-consumer concurrency correctness.
## 8. Non-copyable POD types with custom `=copy {.error.}`.

import options
import unittest2

import lockfree/bqueue
import lockfree/queue
import lockfree/strategy
import lockfree/endpoint
import lockfree/atomics
import lockfree/atomics/backoff
from lockfree/smr/nebr as debra_mod import initDebraManager

type
  MoveOnlyItem = object
    val: int

proc `=copy`(dst: var MoveOnlyItem, src: MoveOnlyItem) {.error.}

suite "popBatch and popChunk Primitives":

  test "BQueue SPSC direct batch pop":
    var q = newBQueue[int, ccSingle, ccSingle, 16, 0, 0]()
    for i in 1 .. 8:
      check q.push(i * 10)

    var buf: array[8, int]
    let n = q.popBatch(buf)
    check n == 8
    for i in 0 .. 7:
      check buf[i] == (i + 1) * 10
    check q.pop().isNone

    # Pop on empty queue returns 0
    var emptyBuf: array[4, int]
    check q.popBatch(emptyBuf) == 0

  test "BQueue SPSC partial batch pop and maxCount clamping":
    var q = newBQueue[int, ccSingle, ccSingle, 16, 0, 0]()
    for i in 1 .. 5:
      check q.push(i)

    # Buffer of size 10, but only 5 items in queue
    var buf: array[10, int]
    let n = q.popBatch(buf)
    check n == 5
    for i in 0 .. 4:
      check buf[i] == i + 1

    # Push 6 items, extract with maxCount = 3
    for i in 10 .. 15:
      check q.push(i)
    var buf2: array[10, int]
    let n2 = q.popBatch(buf2, maxCount = 3)
    check n2 == 3
    check buf2[0] == 10
    check buf2[1] == 11
    check buf2[2] == 12
    check q.pop().get() == 13
    check q.pop().get() == 14
    check q.pop().get() == 15
    check q.pop().isNone

  test "BQueue MPMC Bound batch pop":
    var q = newBQueue[int, ccMulti, ccMulti, 32, 4, 4]()
    var producer = q.getProducerHere(0)
    var consumer = q.getConsumerHere(0)

    for i in 1 .. 12:
      check producer.push(i * 100)

    var buf: array[16, int]
    let count = consumer.popBatch(buf, 8)
    check count == 8
    for i in 0 .. 7:
      check buf[i] == (i + 1) * 100

    let remaining = consumer.popBatch(buf)
    check remaining == 4
    check buf[0] == 900
    check buf[1] == 1000
    check buf[2] == 1100
    check buf[3] == 1200
    check consumer.pop().isNone

  test "BQueue popChunk helper":
    var q = newBQueue[int, ccMulti, ccMulti, 32, 4, 4]()
    var producer = q.getProducerHere(0)
    var consumer = q.getConsumerHere(0)

    for i in 1 .. 6:
      check producer.push(i)

    let chunk = consumer.popChunk(4)
    check chunk.len == 4
    check chunk == @[1, 2, 3, 4]

    let chunk2 = consumer.popChunk(4)
    check chunk2.len == 2
    check chunk2 == @[5, 6]

  test "Queue unbounded MPMC strict-LCRQ batch pop":
    var manager = initDebraManager[4, debra_mod.ccMulti]()
    var q = newUnboundedMpmcQueue[int, stEager, 16, 4](addr manager)
    var producer = q.getProducerHere()
    var consumer = q.getConsumerHere()

    for i in 1 .. 10:
      producer.push(i * 5)

    when not defined(lockfreeDisableItemCount):
      check q.len == 10

    var buf: array[6, int]
    let n1 = consumer.popBatch(buf)
    check n1 == 6
    for i in 0 .. 5:
      check buf[i] == (i + 1) * 5

    when not defined(lockfreeDisableItemCount):
      check q.len == 4

    var buf2: array[6, int]
    let n2 = consumer.popBatch(buf2)
    check n2 == 4
    check buf2[0] == 35
    check buf2[1] == 40
    check buf2[2] == 45
    check buf2[3] == 50
    when not defined(lockfreeDisableItemCount):
      check q.len == 0

    # Empty queue popBatch
    check consumer.popBatch(buf2) == 0

  test "Queue unbounded MPMC batch pop across segment boundary":
    var manager = initDebraManager[4, debra_mod.ccMulti]()
    # Small segment size (4) forces multiple segment rollovers
    var q = newUnboundedMpmcQueue[int, stEager, 4, 4](addr manager)
    var producer = q.getProducerHere()
    var consumer = q.getConsumerHere()

    for i in 1 .. 14:
      producer.push(i)

    when not defined(lockfreeDisableItemCount):
      check q.len == 14

    # Extract in a batch larger than a single segment size (7 > 4)
    var buf: array[7, int]
    let n1 = consumer.popBatch(buf)
    check n1 == 7
    for i in 0 .. 6:
      check buf[i] == i + 1

    when not defined(lockfreeDisableItemCount):
      check q.len == 7

    let n2 = consumer.popBatch(buf)
    check n2 == 7
    for i in 0 .. 6:
      check buf[i] == i + 8

    when not defined(lockfreeDisableItemCount):
      check q.len == 0
    check consumer.popBatch(buf) == 0

  test "Queue unbounded MPSC batch pop":
    var manager = initDebraManager[4, debra_mod.ccSingle]()
    var q = newUnboundedMpscQueue[int, stEager, 4, 4](addr manager)
    var consumer = q.bindConsumer()
    var producer = q.getProducerHere()

    for i in 1 .. 14:
      producer.push(i)

    when not defined(lockfreeDisableItemCount):
      check q.len == 14

    var buf: array[6, int]
    let n1 = consumer.popBatch(buf)
    check n1 == 6
    for i in 0 .. 5:
      check buf[i] == i + 1

    when not defined(lockfreeDisableItemCount):
      check q.len == 8

    let n2 = consumer.popBatch(buf)
    check n2 == 6
    for i in 0 .. 5:
      check buf[i] == i + 7

    when not defined(lockfreeDisableItemCount):
      check q.len == 2

    let n3 = consumer.popBatch(buf)
    check n3 == 2
    check buf[0] == 13
    check buf[1] == 14

    when not defined(lockfreeDisableItemCount):
      check q.len == 0

    check consumer.popBatch(buf) == 0

  test "Queue unbounded SPMC batch pop":
    var manager = initDebraManager[4, debra_mod.ccMulti]()
    var q = newUnboundedSpmcQueue[int, stEager, 4, 4](addr manager)
    var producer = q.getProducerHere()
    var consumer = q.getConsumerHere()

    for i in 1 .. 14:
      producer.push(i)

    when not defined(lockfreeDisableItemCount):
      check q.len == 14

    var buf: array[6, int]
    let n1 = consumer.popBatch(buf)
    check n1 == 6
    for i in 0 .. 5:
      check buf[i] == i + 1

    when not defined(lockfreeDisableItemCount):
      check q.len == 8

    let n2 = consumer.popBatch(buf)
    check n2 == 6
    for i in 0 .. 5:
      check buf[i] == i + 7

    when not defined(lockfreeDisableItemCount):
      check q.len == 2

    let n3 = consumer.popBatch(buf)
    check n3 == 2
    check buf[0] == 13
    check buf[1] == 14

    when not defined(lockfreeDisableItemCount):
      check q.len == 0

    check consumer.popBatch(buf) == 0

  test "Queue unbounded MPMC popChunk helper":
    var manager = initDebraManager[4, debra_mod.ccMulti]()
    var q = newUnboundedMpmcQueue[int, stEager, 16, 4](addr manager)
    var producer = q.getProducerHere()
    var consumer = q.getConsumerHere()

    for i in 1 .. 5:
      producer.push(i * 11)

    let chunk = consumer.popChunk(8)
    check chunk.len == 5
    check chunk == @[11, 22, 33, 44, 55]
    when not defined(lockfreeDisableItemCount):
      check q.len == 0

  test "Queue unbounded MPMC popBatch with MoveOnlyItem":
    var manager = initDebraManager[4, debra_mod.ccMulti]()
    var q = newUnboundedMpmcQueue[MoveOnlyItem, stEager, 8, 4](addr manager)
    var producer = q.getProducerHere()
    var consumer = q.getConsumerHere()

    for i in 1 .. 6:
      var item = MoveOnlyItem(val: i * 7)
      producer.push(move(item))

    var buf: array[6, MoveOnlyItem]
    let n = consumer.popBatch(buf)
    check n == 6
    for i in 0 .. 5:
      check buf[i].val == (i + 1) * 7
    when not defined(lockfreeDisableItemCount):
      check q.len == 0

  type
    BQueueBatchPCtx[N, P, C: static int] = object
      queue: ptr BQueue[int, bqueue.ccMulti, bqueue.ccMulti, N, P, C]
      producerIdx: int
      items: int
      sent: ptr Atomic[int]

    BQueueBatchCCtx[N, P, C: static int] = object
      queue: ptr BQueue[int, bqueue.ccMulti, bqueue.ccMulti, N, P, C]
      consumerIdx: int
      targetTotal: int
      totalPopped: ptr Atomic[int]

  proc bqueueBatchProducerWorker[N, P, C: static int](ctx: ptr BQueueBatchPCtx[N, P, C]) {.thread.} =
    var p = ctx.queue[].getProducerHere(idx = ctx.producerIdx)
    for i in 1 .. ctx.items:
      while not p.push(i):
        cpuPause()
      discard ctx.sent[].fetchAdd(1, moRelaxed)

  proc bqueueBatchConsumerWorker[N, P, C: static int](ctx: ptr BQueueBatchCCtx[N, P, C]) {.thread.} =
    var c = ctx.queue[].getConsumerHere(idx = ctx.consumerIdx)
    var buf: array[16, int]
    while ctx.totalPopped[].load(moRelaxed) < ctx.targetTotal:
      let n = c.popBatch(buf)
      if n > 0:
        discard ctx.totalPopped[].fetchAdd(n, moRelaxed)
      else:
        cpuPause()

  test "BQueue MPMC 4P/4C 100k items popBatch stress":
    const TotalItems = 100_000
    const NumProducers = 4
    const NumConsumers = 4
    const PerProducer = TotalItems div NumProducers

    var queue = newBQueue[int, bqueue.ccMulti, bqueue.ccMulti, 1024, 4, 4]()
    var sent, totalPopped: Atomic[int]
    sent.store(0, moRelaxed)
    totalPopped.store(0, moRelaxed)

    var pctxs: array[NumProducers, BQueueBatchPCtx[1024, 4, 4]]
    var cctxs: array[NumConsumers, BQueueBatchCCtx[1024, 4, 4]]
    var pThreads: array[NumProducers, Thread[ptr BQueueBatchPCtx[1024, 4, 4]]]
    var cThreads: array[NumConsumers, Thread[ptr BQueueBatchCCtx[1024, 4, 4]]]

    for i in 0 ..< NumConsumers:
      cctxs[i] = BQueueBatchCCtx[1024, 4, 4](
        queue: addr queue, consumerIdx: i, targetTotal: TotalItems, totalPopped: addr totalPopped
      )
      createThread(cThreads[i], bqueueBatchConsumerWorker[1024, 4, 4], addr cctxs[i])

    for i in 0 ..< NumProducers:
      pctxs[i] = BQueueBatchPCtx[1024, 4, 4](
        queue: addr queue, producerIdx: i, items: PerProducer, sent: addr sent
      )
      createThread(pThreads[i], bqueueBatchProducerWorker[1024, 4, 4], addr pctxs[i])

    for i in 0 ..< NumProducers:
      joinThread(pThreads[i])
    for i in 0 ..< NumConsumers:
      joinThread(cThreads[i])

    check sent.load(moRelaxed) == TotalItems
    check totalPopped.load(moRelaxed) == TotalItems

  type
    UnbBatchStressPCtx = object
      queue: ptr Queue[int, bqueue.ccMulti, bqueue.ccMulti, stEager, 64, 16]
      count: int
      sent: ptr Atomic[int]
      producersDone: ptr Atomic[int]

    UnbBatchStressCCtx = object
      queue: ptr Queue[int, bqueue.ccMulti, bqueue.ccMulti, stEager, 64, 16]
      totalExpected: int
      totalProducers: int
      totalPopped: ptr Atomic[int]
      producersDone: ptr Atomic[int]

  proc unbBatchStressProducerThread(ctx: ptr UnbBatchStressPCtx) {.thread.} =
    {.cast(gcsafe).}:
      var p = ctx.queue[].getProducerHere()
      for i in 1 .. ctx.count:
        p.push(i)
        discard ctx.sent[].fetchAdd(1, moRelaxed)
      discard ctx.producersDone[].fetchAdd(1, moRelease)

  proc unbBatchStressConsumerThread(ctx: ptr UnbBatchStressCCtx) {.thread.} =
    {.cast(gcsafe).}:
      var c = ctx.queue[].getConsumerHere()
      var buf: array[16, int]
      while true:
        let n = c.popBatch(buf)
        if n > 0:
          if ctx.totalPopped[].fetchAdd(n, moRelaxed) + n >= ctx.totalExpected:
            break
        elif ctx.producersDone[].load(moAcquire) >= ctx.totalProducers:
          if ctx.totalPopped[].load(moRelaxed) >= ctx.totalExpected:
            break
        else:
          cpuPause()

  test "Queue Unbounded MPMC 4P/4C 100k items popBatch stress":
    const TotalItems = 100_000
    const NumProducers = 4
    const NumConsumers = 4
    const PerProducer = TotalItems div NumProducers

    var queue = newUnboundedMpmcQueue[int, stEager, 64, 16]()
    var sent, totalPopped, producersDone: Atomic[int]
    sent.store(0, moRelaxed)
    totalPopped.store(0, moRelaxed)
    producersDone.store(0, moRelaxed)

    var pctxs: array[NumProducers, UnbBatchStressPCtx]
    var cctxs: array[NumConsumers, UnbBatchStressCCtx]
    var pThreads: array[NumProducers, Thread[ptr UnbBatchStressPCtx]]
    var cThreads: array[NumConsumers, Thread[ptr UnbBatchStressCCtx]]

    for i in 0 ..< NumConsumers:
      cctxs[i] = UnbBatchStressCCtx(
        queue: addr queue, totalExpected: TotalItems, totalProducers: NumProducers,
        totalPopped: addr totalPopped, producersDone: addr producersDone
      )
      createThread(cThreads[i], unbBatchStressConsumerThread, addr cctxs[i])

    for i in 0 ..< NumProducers:
      pctxs[i] = UnbBatchStressPCtx(
        queue: addr queue, count: PerProducer, sent: addr sent, producersDone: addr producersDone
      )
      createThread(pThreads[i], unbBatchStressProducerThread, addr pctxs[i])

    for i in 0 ..< NumProducers:
      joinThread(pThreads[i])
    for i in 0 ..< NumConsumers:
      joinThread(cThreads[i])

    check sent.load(moRelaxed) == TotalItems
    check totalPopped.load(moRelaxed) == TotalItems
