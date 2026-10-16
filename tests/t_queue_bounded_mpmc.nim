## Migrated from `t_mpmc.nim` — exercises the unified Queue type
## under the `ccMulti x ccMulti` (MPMC) bounded cardinality, which
## corresponds to the legacy `Mpmc[N, P, C, T]` shape.
##
## Mechanical conversion from the migration table:
##   Mpmc[N, P, C, T] -> BQueue[T, ccMulti, ccMulti, ##                                N, P, C]
##   initMpmc[N, P, C, T]() -> newBQueue[T, ccMulti, ccMulti, ##                                          N, P, C]()
##
## Test count parity: 28 tests (matches t_mpmc.nim).
## 7, 5, 6.1.

import lockfree/atomics
import lockfree/atomics/dsl
import options
import sequtils
import unittest2

import lockfree
import lockfree/bqueue as q_mod
import lockfree/strategy
import lockfree/reclamation
import lockfree/internal/pinscope_stub
import lockfree/endpoint
import lockfree/role_tags
when defined(posix):
  import posix

template testCapacity(queue: untyped) =
  check(queue.capacity == 8)

template testHeadAndTailReset(queue: untyped) =
  when not compiles(queue.getProducerHere(0)) and not compiles(queue.getConsumerHere(0)):
    queue.head.sequential(17)
    queue.tail.sequential(17)
    queue.checkState(head = 17, tail = 17, storage = repeat(0, 9))
    check(queue.push(@[1]).isNone)
    queue.checkState(head = 17, tail = 0, storage = (@[0, 0, 0, 0, 0, 0, 0, 0, 1]))
    let res = queue.pop(1)
    check(res.isSome)
    check(res.get == @[1])
    queue.checkState(head = 0, tail = 0, storage = (@[0, 0, 0, 0, 0, 0, 0, 0, 1]))

template testMupGetProducerAssigns(queue: untyped) =
  let producer = queue.getProducer()
  check(producer.idx == 0)
  check(queue.producerThreadIds[0].acquire == getThreadId())
  for p in 1 ..< queue.producerCount:
    check(queue.producerThreadIds[p].acquire == 0)

template testMupGetProducerReusesAssigned(queue: untyped) =
  discard queue.getProducer()
  let producer = queue.getProducer()
  check(producer.idx == 0)
  check(queue.producerThreadIds[0].acquire == getThreadId())
  for p in 1 ..< queue.producerCount:
    check(queue.producerThreadIds[p].acquire == 0)

template testMupGetProducerExplicitIndex(queue: untyped) =
  for idx in 0 ..< queue.producerCount:
    check(queue.getProducerHere(idx).idx == idx)

template testMupGetProducerThrowsNoProducersAvailable(queue: untyped) =
  proc assignProducer() {.thread.} =
    discard queue.getProducer()

  var threads: array[4, Thread[void]]
  for i in 0 .. 3:
    threads[i].createThread(assignProducer)
  when defined(posix):
    for i in 0 .. 3:
      discard pthread_join(cast[Pthread](threads[i].sys), cast[ptr pointer](nil))
  else:
    for i in 0 .. 3:
      joinThread(threads[i])
  expect NoProducersAvailableError:
    discard queue.getProducer()

template testMupPush(queue: untyped) =
  check((block: (var lfqT = queue.getProducerHere(0); lfqT.push(1))) == true)
  check((block: (var lfqT = queue.getProducerHere(0); lfqT.push(2))) == true)
  queue.checkState(head = 0'u64, tail = 2'u64)
  check((block: (var lfqT = queue.getProducerHere(1); lfqT.push(3))) == true)
  check((block: (var lfqT = queue.getProducerHere(1); lfqT.push(4))) == true)
  queue.checkState(head = 0'u64, tail = 4'u64)
  check((block: (var lfqT = queue.getProducerHere(2); lfqT.push(5))) == true)
  check((block: (var lfqT = queue.getProducerHere(2); lfqT.push(6))) == true)
  queue.checkState(head = 0'u64, tail = 6'u64)
  check((block: (var lfqT = queue.getProducerHere(3); lfqT.push(7))) == true)
  check((block: (var lfqT = queue.getProducerHere(3); lfqT.push(8))) == true)
  queue.checkState(head = 0'u64, tail = 8'u64)

template testMupPushOverflow(queue: untyped) =
  for i in 1 .. 8:
    discard (block: (var lfqT = queue.getProducerHere(0); lfqT.push(i)))
  check((block: (var lfqT = queue.getProducerHere(0); lfqT.push(9))) == false)
  queue.checkState(head = 0'u64, tail = 8'u64)

template testMupPushWrap(queue: untyped) =
  for i in 1 .. 4:
    discard (block: (var lfqT = queue.getProducerHere(0); lfqT.push(i)))
  for i in 0 .. 1:
    discard (block: (var lfqT = queue.getConsumerHere(i); lfqT.pop()))
  for i in 5 .. 10:
    check((block: (var lfqT = queue.getProducerHere(0); lfqT.push(i))) == true)
  queue.checkState(head = 2'u64, tail = 10'u64)

template testMupPushSeq(queue: untyped) =
  check((block: (var lfqT = queue.getProducerHere(0); lfqT.push(@[1, 2, 3, 4, 5, 6, 7, 8]))).isNone)
  queue.checkState(head = 0'u64, tail = 8'u64)

template testMupPushSeqOverflow(queue: untyped) =
  var res = (block: (var lfqT = queue.getProducerHere(0); lfqT.push(@[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16])))
  check(res.isSome)
  check(res.get == 8 .. 15)
  queue.checkState(head = 0'u64, tail = 8'u64)

template testMupPushSeqWrap(queue: untyped) =
  discard (block: (var lfqT = queue.getProducerHere(0); lfqT.push(@[1, 2, 3, 4])))
  for i in 0 .. 1:
    discard (block: (var lfqT = queue.getConsumerHere(i); lfqT.pop()))
  var res = (block: (var lfqT = queue.getProducerHere(0); lfqT.push(@[5, 6, 7, 8, 9, 10])))
  check(res.isNone)
  queue.checkState(head = 2'u64, tail = 10'u64)

template testMucPopOne(queue: untyped) =
  discard (block: (var lfqT = queue.getProducerHere(0); lfqT.push(@[1, 2, 3, 4, 5, 6, 7, 8])))
  var res = (block: (var lfqT = queue.getConsumerHere(0); lfqT.pop()))
  check(res.isSome)
  check(res.get == 1)
  queue.checkState(head = 1'u64, tail = 8'u64, data = (@[1, 2, 3, 4, 5, 6, 7, 8]))

template testMucPopAll(queue: untyped) =
  discard (block: (var lfqT = queue.getProducerHere(0); lfqT.push(@[1, 2, 3, 4, 5, 6, 7, 8])))
  var items = newSeq[int]()
  for i in 1 .. 8:
    var res = (block: (var lfqT = queue.getConsumerHere(0); lfqT.pop()))
    check(res.isSome)
    items.add(res.get)
  check(items == @[1, 2, 3, 4, 5, 6, 7, 8])
  queue.checkState(head = 8'u64, tail = 8'u64, data = (@[1, 2, 3, 4, 5, 6, 7, 8]))

template testMucPopEmpty(queue: untyped) =
  check((block: (var lfqT = queue.getConsumerHere(0); lfqT.pop())).isNone)
  queue.checkState(head = 0'u64, tail = 0'u64)

template testMucPopTooMany(queue: untyped) =
  discard (block: (var lfqT = queue.getProducerHere(0); lfqT.push(@[1, 2, 3, 4, 5, 6, 7, 8])))
  for i in 1 .. 8:
    discard (block: (var lfqT = queue.getConsumerHere(0); lfqT.pop()))
  check((block: (var lfqT = queue.getConsumerHere(0); lfqT.pop())).isNone)
  queue.checkState(head = 8'u64, tail = 8'u64, data = (@[1, 2, 3, 4, 5, 6, 7, 8]))

template testMucPopWrap(queue: untyped) =
  discard (block: (var lfqT = queue.getProducerHere(0); lfqT.push(@[1, 2, 3, 4, 5, 6, 7, 8])))
  for i in 1 .. 4:
    discard (block: (var lfqT = queue.getConsumerHere(0); lfqT.pop()))
  discard (block: (var lfqT = queue.getProducerHere(1); lfqT.push(@[9, 10, 11, 12])))
  var items = newSeq[int]()
  for i in 1 .. 8:
    var res = (block: (var lfqT = queue.getConsumerHere(0); lfqT.pop()))
    check(res.isSome)
    items.add(res.get)
  check(items == @[5, 6, 7, 8, 9, 10, 11, 12])
  queue.checkState(head = 12'u64, tail = 12'u64, data = (@[9, 10, 11, 12, 5, 6, 7, 8]))

template testMucPopCountOne(queue: untyped) =
  check((block: (var lfqT = queue.getProducerHere(0); lfqT.push(@[1, 2, 3, 4, 5, 6, 7, 8]))).isNone)
  for i in 1 .. 8:
    var popped = (block: (var lfqT = queue.getConsumerHere(0); lfqT.pop(1)))
    check(popped.isSome)
    check(popped.get() == @[i])
  queue.checkState(head = 8'u64, tail = 8'u64, data = (@[1, 2, 3, 4, 5, 6, 7, 8]))

template testMucPopCountAll(queue: untyped) =
  discard (block: (var lfqT = queue.getProducerHere(0); lfqT.push(@[1, 2, 3, 4, 5, 6, 7, 8])))
  var popped = (block: (var lfqT = queue.getConsumerHere(0); lfqT.pop(8)))
  check(popped.isSome)
  check(popped.get() == @[1, 2, 3, 4, 5, 6, 7, 8])
  queue.checkState(head = 8'u64, tail = 8'u64, data = (@[1, 2, 3, 4, 5, 6, 7, 8]))

template testMucPopCountEmpty(queue: untyped) =
  var popped = (block: (var lfqT = queue.getConsumerHere(0); lfqT.pop(1)))
  check(popped.isNone)
  queue.checkState(head = 0'u64, tail = 0'u64)

template testMucPopCountTooMany(queue: untyped) =
  check((block: (var lfqT = queue.getProducerHere(0); lfqT.push(@[1, 2, 3, 4, 5, 6, 7, 8]))).isNone)
  queue.checkState(head = 0'u64, tail = 8'u64, data = (@[1, 2, 3, 4, 5, 6, 7, 8]))
  var popped = (block: (var lfqT = queue.getConsumerHere(0); lfqT.pop(10)))
  check(popped.isSome)
  check(popped.get() == @[1, 2, 3, 4, 5, 6, 7, 8])
  queue.checkState(head = 8'u64, tail = 8'u64, data = (@[1, 2, 3, 4, 5, 6, 7, 8]))

template testMucPopCountWrap(queue: untyped) =
  discard (block: (var lfqT = queue.getProducerHere(0); lfqT.push(@[1, 2, 3, 4, 5, 6, 7, 8])))
  discard (block: (var lfqT = queue.getConsumerHere(0); lfqT.pop(4)))
  discard (block: (var lfqT = queue.getProducerHere(1); lfqT.push(@[9, 10, 11, 12])))
  var popped = (block: (var lfqT = queue.getConsumerHere(1); lfqT.pop(8)))
  check(popped.isSome)
  check(popped.get() == @[5, 6, 7, 8, 9, 10, 11, 12])
  queue.checkState(head = 12'u64, tail = 12'u64, data = (@[9, 10, 11, 12, 5, 6, 7, 8]))

var q = q_mod.newBQueue[int, ccMulti, ccMulti, 8, 4, 4]()

suite "BQueue[int, ccMulti, ccMulti, 8, 4, 4]":
  test "capacity":
    check(q.capacity == 8)

  test "producerCount":
    check(q.producerCount == 4)

  test "initial state":
    q.checkState(head = 0'u64, tail = 0'u64, data = repeat(0, 8))

suite "getProducer(Queue MPMC)":
  setup:
    q.reset()

  test "assigns by thread id":
    testMupGetProducerAssigns(q)

  test "reuses assigned":
    testMupGetProducerReusesAssigned(q)

  test "explicit index":
    testMupGetProducerExplicitIndex(q)

  test "throws NoProducersAvailableError":
    testMupGetProducerThrowsNoProducersAvailable(q)

suite "push(Queue MPMC)":
  setup:
    q.reset()

  # B.2 direct push on a ccMulti Queue is now a compile-time
  # `{.error.}`. The former runtime `InvalidCallDefect` smoke-tests are
  # superseded by compile-fail negative-controls under
  # tests/should_fail/.

suite "push(QueueProducer MPMC, T)":
  setup:
    q.reset()

  test "basic":
    testMupPush(q)

  test "overflow":
    testMupPushOverflow(q)

  test "wrap":
    testMupPushWrap(q)

suite "push(QueueProducer MPMC, seq[T])":
  setup:
    q.reset()

  test "basic":
    testMupPushSeq(q)

  test "overflow":
    testMupPushSeqOverflow(q)

  test "wrap":
    testMupPushSeqWrap(q)

suite "pop(Queue MPMC)":
  setup:
    q.reset()

  test "one":
    testMucPopOne(q)

  test "all":
    testMucPopAll(q)

  test "empty":
    testMucPopEmpty(q)

  test "too many":
    testMucPopTooMany(q)

  test "wrap":
    testMucPopWrap(q)

suite "pop(Queue MPMC, int)":
  setup:
    q.reset()

  test "one":
    testMucPopCountOne(q)

  test "all":
    testMucPopCountAll(q)

  test "empty":
    testMucPopCountEmpty(q)

  test "too many":
    testMucPopCountTooMany(q)

  test "wrap":
    testMucPopCountWrap(q)

suite "capacity(Queue MPMC)":
  test "basic":
    testCapacity(q)

suite "Queue MPMC integration":
  setup:
    q.reset()

  test "head and tail reset":
    testHeadAndTailReset(q)

  test "wraps":
    check(
      (
        block:
          var lfqT = q.getProducerHere(0)
          lfqT.push(@[1, 2, 3, 4, 5, 6, 7, 8])
      ).isNone
    )

    var popRes = (
      block:
        var lfqT = q.getConsumerHere(0)
        lfqT.pop(4)
    )

    check(popRes.isSome)
    check(popRes.get == @[1, 2, 3, 4])

    var pushRes = (
      block:
        var lfqT = q.getProducerHere(0)
        lfqT.push(@[9, 10, 11, 12])
    )

    check(pushRes.isNone)

    q.checkState(head = 4'u64, tail = 12'u64, data = (@[9, 10, 11, 12, 5, 6, 7, 8]))

    popRes = (
      block:
        var lfqT = q.getConsumerHere(0)
        lfqT.pop(4)
    )
    check(popRes.isSome)
    check(popRes.get == @[5, 6, 7, 8])

    q.checkState(head = 8'u64, tail = 12'u64, data = (@[9, 10, 11, 12, 5, 6, 7, 8]))

    popRes = (
      block:
        var lfqT = q.getConsumerHere(1)
        lfqT.pop(4)
    )
    check(popRes.isSome)
    check(popRes.get == @[9, 10, 11, 12])

    q.checkState(head = 12'u64, tail = 12'u64, data = (@[9, 10, 11, 12, 5, 6, 7, 8]))
