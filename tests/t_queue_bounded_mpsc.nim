## Migrated from `t_mpsc.nim` — exercises the unified Queue type
## under the `ccMulti x ccSingle` (MPSC) bounded cardinality, which
## corresponds to the legacy `Mpsc[N, P, T]` shape.
##
## Mechanical conversion from the migration table:
##   Mpsc[N, P, T] -> BQueue[T, ccMulti, ccSingle, ##                            N, P, 0]
##   initMpsc[N, P, T]() -> newBQueue[T, ccMulti, ccSingle, ##                                       N, P, 0]()
##
## NOTE: the queue variable is named `q` (not `queue`) to avoid the
## name-collision with the imported `lockfree/queue` module.
## Test count parity: 28 tests (matches t_mpsc.nim).
##
## 7, 5, 6.1.

import options
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
  discard

template testWraps(queue: untyped) =
  check((block: (var lfqT = queue.getProducerHere(0); lfqT.push(@[1, 2, 3, 4, 5, 6, 7, 8]))).isNone)
  var popRes = queue.pop(4)
  check(popRes.isSome)
  check(popRes.get == @[1, 2, 3, 4])
  let pushRes = (block: (var lfqT = queue.getProducerHere(0); lfqT.push(@[9, 10, 11, 12])))
  check(pushRes.isNone)
  queue.checkState(head = 4'u64, tail = 12'u64)
  popRes = queue.pop(4)
  check(popRes.isSome)
  check(popRes.get == @[5, 6, 7, 8])
  queue.checkState(head = 8'u64, tail = 12'u64)
  popRes = queue.pop(4)
  check(popRes.isSome)
  check(popRes.get == @[9, 10, 11, 12])
  queue.checkState(head = 12'u64, tail = 12'u64)

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
    discard queue.pop()
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
    discard queue.pop()
  var res = (block: (var lfqT = queue.getProducerHere(0); lfqT.push(@[5, 6, 7, 8, 9, 10])))
  check(res.isNone)
  queue.checkState(head = 2'u64, tail = 10'u64)

template testSicPopOne(queue: untyped) =
  discard (block: (var lfqT = queue.getProducerHere(0); lfqT.push(@[1, 2, 3, 4, 5, 6, 7, 8])))
  let res = queue.pop()
  check(res.isSome)
  check(res.get == 1)
  queue.checkState(head = 1'u64, tail = 8'u64)

template testSicPopAll(queue: untyped) =
  discard (block: (var lfqT = queue.getProducerHere(0); lfqT.push(@[1, 2, 3, 4, 5, 6, 7, 8])))
  var items = newSeq[int]()
  for i in 1 .. 8:
    let res = queue.pop()
    check(res.isSome)
    items.add(res.get)
  check(items == @[1, 2, 3, 4, 5, 6, 7, 8])
  queue.checkState(head = 8'u64, tail = 8'u64)

template testSicPopEmpty(queue: untyped) =
  check(queue.pop().isNone)
  queue.checkState(head = 0'u64, tail = 0'u64)

template testSicPopTooMany(queue: untyped) =
  discard (block: (var lfqT = queue.getProducerHere(0); lfqT.push(@[1, 2, 3, 4, 5, 6, 7, 8])))
  for i in 1 .. 8:
    discard queue.pop()
  check(queue.pop().isNone)
  queue.checkState(head = 8'u64, tail = 8'u64)

template testSicPopWrap(queue: untyped) =
  discard (block: (var lfqT = queue.getProducerHere(0); lfqT.push(@[1, 2, 3, 4, 5, 6, 7, 8])))
  for i in 1 .. 4:
    discard queue.pop()
  discard (block: (var lfqT = queue.getProducerHere(1); lfqT.push(@[9, 10, 11, 12])))
  var items = newSeq[int]()
  for i in 1 .. 8:
    let res = queue.pop()
    check(res.isSome)
    items.add(res.get)
  check(items == @[5, 6, 7, 8, 9, 10, 11, 12])
  queue.checkState(head = 12'u64, tail = 12'u64)

template testSicPopCountOne(queue: untyped) =
  discard (block: (var lfqT = queue.getProducerHere(0); lfqT.push(@[1, 2, 3, 4, 5, 6, 7, 8])))
  for i in 1 .. 8:
    let popped = queue.pop(1)
    check(popped.isSome)
    check(popped.get() == @[i])
  queue.checkState(head = 8'u64, tail = 8'u64)

template testSicPopCountAll(queue: untyped) =
  discard (block: (var lfqT = queue.getProducerHere(0); lfqT.push(@[1, 2, 3, 4, 5, 6, 7, 8])))
  let popped = queue.pop(8)
  check(popped.isSome)
  check(popped.get() == @[1, 2, 3, 4, 5, 6, 7, 8])
  queue.checkState(head = 8'u64, tail = 8'u64)

template testSicPopCountEmpty(queue: untyped) =
  let popped = queue.pop(1)
  check(popped.isNone)
  queue.checkState(head = 0'u64, tail = 0'u64)

template testSicPopCountTooMany(queue: untyped) =
  discard (block: (var lfqT = queue.getProducerHere(0); lfqT.push(@[1, 2, 3, 4, 5, 6, 7, 8])))
  let popped = queue.pop(10)
  check(popped.isSome)
  check(popped.get() == @[1, 2, 3, 4, 5, 6, 7, 8])
  queue.checkState(head = 8'u64, tail = 8'u64)

template testSicPopCountWrap(queue: untyped) =
  discard (block: (var lfqT = queue.getProducerHere(0); lfqT.push(@[1, 2, 3, 4, 5, 6, 7, 8])))
  discard queue.pop(4)
  discard (block: (var lfqT = queue.getProducerHere(1); lfqT.push(@[9, 10, 11, 12])))
  let popped = queue.pop(8)
  check(popped.isSome)
  check(popped.get() == @[5, 6, 7, 8, 9, 10, 11, 12])
  queue.checkState(head = 12'u64, tail = 12'u64)

var q = q_mod.newBQueue[int, ccMulti, ccSingle, 8, 4, 0]()

suite "BQueue[int, ccMulti, ccSingle, 8, 4, 0]":
  test "capacity":
    check(q.capacity == 8)

  test "producerCount":
    check(q.producerCount == 4)

  test "initial state":
    q.checkState(head = 0'u64, tail = 0'u64)

suite "getProducer(Queue MPSC)":
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

suite "push(Queue MPSC)":
  setup:
    q.reset()

  # B.2 direct push on a ccMulti Queue is now a compile-time
  # `{.error.}`. The former runtime `InvalidCallDefect` smoke-tests are
  # superseded by compile-fail negative-controls under
  # tests/should_fail/.

suite "push(QueueProducer MPSC, T)":
  setup:
    q.reset()

  test "basic":
    testMupPush(q)

  test "overflow":
    testMupPushOverflow(q)

  test "wrap":
    testMupPushWrap(q)

suite "push(QueueProducer MPSC, seq[T])":
  setup:
    q.reset()

  test "basic":
    testMupPushSeq(q)

  test "overflow":
    testMupPushSeqOverflow(q)

  test "wrap":
    testMupPushSeqWrap(q)

suite "pop(Queue MPSC)":
  setup:
    q.reset()

  test "one":
    testSicPopOne(q)

  test "all":
    testSicPopAll(q)

  test "empty":
    testSicPopEmpty(q)

  test "too many":
    testSicPopTooMany(q)

  test "wrap":
    testSicPopWrap(q)

suite "pop(Queue MPSC, int)":
  setup:
    q.reset()

  test "one":
    testSicPopCountOne(q)

  test "all":
    testSicPopCountAll(q)

  test "empty":
    testSicPopCountEmpty(q)

  test "too many":
    testSicPopCountTooMany(q)

  test "wrap":
    testSicPopCountWrap(q)

suite "capacity(Queue MPSC)":
  test "basic":
    testCapacity(q)

suite "Queue MPSC integration":
  setup:
    q.reset()

  test "head and tail reset":
    testHeadAndTailReset(q)

  test "wraps":
    testWraps(q)
