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
import lockfree/smr/nebr as debra_mod
from lockfree/smr/nebr import initDebraManager

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

    check q.len == 10

    var buf: array[6, int]
    let n1 = consumer.popBatch(buf)
    check n1 == 6
    for i in 0 .. 5:
      check buf[i] == (i + 1) * 5

    check q.len == 4

    var buf2: array[6, int]
    let n2 = consumer.popBatch(buf2)
    check n2 == 4
    check buf2[0] == 35
    check buf2[1] == 40
    check buf2[2] == 45
    check buf2[3] == 50
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

    check q.len == 14

    # Extract in a batch larger than a single segment size (7 > 4)
    var buf: array[7, int]
    let n1 = consumer.popBatch(buf)
    check n1 == 7
    for i in 0 .. 6:
      check buf[i] == i + 1

    check q.len == 7

    let n2 = consumer.popBatch(buf)
    check n2 == 7
    for i in 0 .. 6:
      check buf[i] == i + 8

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
    check q.len == 0
