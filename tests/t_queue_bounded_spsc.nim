## Migrated from `t_spsc.nim` — exercises the unified Queue type
## under the `ccSingle x ccSingle` (SPSC) bounded cardinality, which
## corresponds to the legacy `Spsc[N, T]` shape.
##
## Mechanical conversion from the migration table:
##   Spsc[N, T] -> BQueue[T, ccSingle, ccSingle, ##                          N, 0, 0]
##   initSpsc[N, T]() -> newBQueue[T, ccSingle, ccSingle, ##                                    N, 0, 0]()
##
## Test count parity: 21 tests (matches t_spsc.nim).
## 7, 5, 6.1.

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
template testCapacity(queue: untyped) =
  check(queue.capacity == 8)

template testHeadAndTailReset(queue: untyped) =
  queue.head.sequential(17)
  queue.tail.sequential(17)
  queue.checkState(head = 17, tail = 17, storage = repeat(0, 9))
  check(queue.push(@[1]).isNone)
  queue.checkState(head = 17, tail = 0, storage = (@[0, 0, 0, 0, 0, 0, 0, 0, 1]))
  let res = queue.pop(1)
  check(res.isSome)
  check(res.get == @[1])
  queue.checkState(head = 0, tail = 0, storage = (@[0, 0, 0, 0, 0, 0, 0, 0, 1]))

template testWraps(queue: untyped) =
  check(queue.push(@[1, 2, 3, 4, 5, 6, 7, 8]).isNone)
  var popRes = queue.pop(4)
  check(popRes.isSome)
  check(popRes.get == @[1, 2, 3, 4])
  let pushRes = queue.push(@[9, 10, 11, 12])
  check(pushRes.isNone)
  queue.checkState(head = 4, tail = 12, storage = (@[10, 11, 12, 4, 5, 6, 7, 8, 9]))
  popRes = queue.pop(4)
  check(popRes.isSome)
  check(popRes.get == @[5, 6, 7, 8])
  queue.checkState(head = 8, tail = 12, storage = (@[10, 11, 12, 4, 5, 6, 7, 8, 9]))
  popRes = queue.pop(4)
  check(popRes.isSome)
  check(popRes.get == @[9, 10, 11, 12])
  queue.checkState(head = 12, tail = 12, storage = (@[10, 11, 12, 4, 5, 6, 7, 8, 9]))

template testSipPush(queue: untyped) =
  for i in 1 .. 8:
    check(queue.push(i) == true)
  queue.checkState(head = 0, tail = 8, storage = (@[1, 2, 3, 4, 5, 6, 7, 8, 0]))

template testSipPushOverflow(queue: untyped) =
  for i in 1 .. 8:
    discard queue.push(i)
  check(queue.push(9) == false)
  queue.checkState(head = 0, tail = 8, storage = (@[1, 2, 3, 4, 5, 6, 7, 8, 0]))

template testSipPushWrap(queue: untyped) =
  for i in 1 .. 4:
    discard queue.push(i)
  for i in 1 .. 2:
    discard queue.pop()
  for i in 5 .. 10:
    check(queue.push(i) == true)
  queue.checkState(head = 2, tail = 10, storage = (@[10, 2, 3, 4, 5, 6, 7, 8, 9]))

template testSipPushSeq(queue: untyped) =
  check(queue.push(@[1, 2, 3, 4, 5, 6, 7, 8]).isNone)
  queue.checkState(head = 0, tail = 8, storage = (@[1, 2, 3, 4, 5, 6, 7, 8, 0]))

template testSipPushSeqOverflow(queue: untyped) =
  let res = queue.push(@[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16])
  check(res.isSome)
  check(res.get == 8 .. 15)
  queue.checkState(head = 0, tail = 8, storage = (@[1, 2, 3, 4, 5, 6, 7, 8, 0]))

template testSipPushSeqWrap(queue: untyped) =
  discard queue.push(@[1, 2, 3, 4])
  for i in 1 .. 2:
    discard queue.pop()
  var res = queue.push(@[5, 6, 7, 8, 9, 10])
  check(res.isNone)
  queue.checkState(head = 2, tail = 10, storage = (@[10, 2, 3, 4, 5, 6, 7, 8, 9]))

template testSicPopOne(queue: untyped) =
  discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])
  let res = queue.pop()
  check(res.isSome)
  check(res.get == 1)
  queue.checkState(head = 1, tail = 8, storage = (@[1, 2, 3, 4, 5, 6, 7, 8, 0]))

template testSicPopAll(queue: untyped) =
  discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])
  var items = newSeq[int]()
  for i in 1 .. 8:
    let res = queue.pop()
    check(res.isSome)
    items.add(res.get)
  check(items == @[1, 2, 3, 4, 5, 6, 7, 8])
  queue.checkState(head = 8, tail = 8, storage = (@[1, 2, 3, 4, 5, 6, 7, 8, 0]))

template testSicPopEmpty(queue: untyped) =
  check(queue.pop().isNone)
  queue.checkState(head = 0, tail = 0, storage = repeat(0, 9))

template testSicPopTooMany(queue: untyped) =
  discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])
  for i in 1 .. 8:
    discard queue.pop()
  check(queue.pop().isNone)
  queue.checkState(head = 8, tail = 8, storage = (@[1, 2, 3, 4, 5, 6, 7, 8, 0]))

template testSicPopWrap(queue: untyped) =
  discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])
  for i in 1 .. 4:
    discard queue.pop()
  discard queue.push(@[9, 10, 11, 12])
  var items = newSeq[int]()
  for i in 1 .. 8:
    let res = queue.pop()
    check(res.isSome)
    items.add(res.get)
  check(items == @[5, 6, 7, 8, 9, 10, 11, 12])
  queue.checkState(head = 12, tail = 12, storage = (@[10, 11, 12, 4, 5, 6, 7, 8, 9]))

template testSicPopCountOne(queue: untyped) =
  discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])
  for i in 1 .. 8:
    let popped = queue.pop(1)
    check(popped.isSome)
    check(popped.get() == @[i])
  queue.checkState(head = 8, tail = 8, storage = (@[1, 2, 3, 4, 5, 6, 7, 8, 0]))

template testSicPopCountAll(queue: untyped) =
  discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])
  let popped = queue.pop(8)
  check(popped.isSome)
  check(popped.get() == @[1, 2, 3, 4, 5, 6, 7, 8])
  queue.checkState(head = 8, tail = 8, storage = (@[1, 2, 3, 4, 5, 6, 7, 8, 0]))

template testSicPopCountEmpty(queue: untyped) =
  let popped = queue.pop(1)
  check(popped.isNone)
  queue.checkState(head = 0, tail = 0, storage = repeat(0, 9))

template testSicPopCountZero(queue: untyped) =
  discard queue.push(@[1, 2, 3])
  check(queue.pop(0).isNone)
  let after = queue.pop(1)
  check(after.isSome)
  check(after.get() == @[1])

template testSicPopCountNegative(queue: untyped) =
  discard queue.push(@[1, 2, 3])
  check(queue.pop(-1).isNone)
  let after = queue.pop(1)
  check(after.isSome)
  check(after.get() == @[1])

template testSicPopCountTooMany(queue: untyped) =
  discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])
  let popped = queue.pop(10)
  check(popped.isSome)
  check(popped.get() == @[1, 2, 3, 4, 5, 6, 7, 8])
  queue.checkState(head = 8, tail = 8, storage = (@[1, 2, 3, 4, 5, 6, 7, 8, 0]))

template testSicPopCountWrap(queue: untyped) =
  discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])
  discard queue.pop(4)
  discard queue.push(@[9, 10, 11, 12])
  let popped = queue.pop(8)
  check(popped.isSome)
  check(popped.get() == @[5, 6, 7, 8, 9, 10, 11, 12])
  queue.checkState(head = 12, tail = 12, storage = (@[10, 11, 12, 4, 5, 6, 7, 8, 9]))

var q = q_mod.newBQueue[int, ccSingle, ccSingle, 8, 0, 0]()

suite "BQueue[int, ccSingle, ccSingle, 8, 0, 0]":
  test "capacity":
    check(q.capacity == 8)

  test "initial state":
    q.checkState(
      head = 0, tail = 0, storage = repeat(0, 9) # N+1 slots
    )

suite "push(Queue SPSC, T)":
  setup:
    q.reset()

  test "basic":
    testSipPush(q)

  test "overflow":
    testSipPushOverflow(q)

  test "wrap":
    testSipPushWrap(q)

suite "push(Queue SPSC, seq[T])":
  setup:
    q.reset()

  test "basic":
    testSipPushSeq(q)

  test "overflow":
    testSipPushSeqOverflow(q)

  test "wrap":
    testSipPushSeqWrap(q)

suite "pop(Queue SPSC)":
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

suite "pop(Queue SPSC, int)":
  setup:
    q.reset()

  test "one":
    testSicPopCountOne(q)

  test "all":
    testSicPopCountAll(q)

  test "empty":
    testSicPopCountEmpty(q)

  test "zero count returns none (T1-G1-001)":
    testSicPopCountZero(q)

  test "negative count returns none without crash (T1-G1-001)":
    testSicPopCountNegative(q)

  test "too many":
    testSicPopCountTooMany(q)

  test "wrap":
    testSicPopCountWrap(q)

suite "capacity(Queue SPSC)":
  test "basic":
    testCapacity(q)

suite "Queue SPSC integration":
  setup:
    q.reset()

  test "head and tail reset":
    testHeadAndTailReset(q)

  test "wraps":
    testWraps(q)
