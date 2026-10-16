## Migrated from `t_spmc.nim` — exercises the unified Queue type
## under the `ccSingle x ccMulti` (SPMC) bounded cardinality, which
## corresponds to the legacy `Spmc[N, C, T]` shape.
##
## Mechanical conversion from the migration table:
##   Spmc[N, C, T] -> BQueue[T, ccSingle, ccMulti, ##                             N, 0, C]
##   initSpmc[N, C, T]() -> newBQueue[T, ccSingle, ccMulti, ##                                       N, 0, C]()
##
## Test count parity: 27 tests (matches t_spmc.nim).
## 7, 5, 6.1.

import lockfree/atomics
import lockfree/atomics/dsl
import options
import sequtils
import unittest2

import lockfree
import lockfree/exceptions
import lockfree/bqueue as q_mod
import lockfree/strategy
import lockfree/reclamation
import lockfree/internal/pinscope_stub
import lockfree/endpoint
import lockfree/role_tags
template testCapacity(queue: untyped) =
  check(queue.capacity == 8)

template testHeadAndTailReset(queue: untyped) =
  discard

template testSucPopOne(queue: untyped) =
  discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])
  var res = (block: (var lfqT = queue.getConsumerHere(0); lfqT.pop()))
  check(res.isSome)
  check(res.get == 1)
  queue.checkState(head = 1'u64, tail = 8'u64, data = (@[1, 2, 3, 4, 5, 6, 7, 8]))

template testSucPopAll(queue: untyped) =
  discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])
  var items = newSeq[int]()
  for i in 1 .. 8:
    var res = (block: (var lfqT = queue.getConsumerHere(0); lfqT.pop()))
    check(res.isSome)
    items.add(res.get)
  check(items == @[1, 2, 3, 4, 5, 6, 7, 8])
  queue.checkState(head = 8'u64, tail = 8'u64, data = (@[1, 2, 3, 4, 5, 6, 7, 8]))

template testSucPopEmpty(queue: untyped) =
  check((block: (var lfqT = queue.getConsumerHere(0); lfqT.pop())).isNone)
  queue.checkState(head = 0'u64, tail = 0'u64)

template testSucPopTooMany(queue: untyped) =
  discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])
  for i in 1 .. 8:
    discard (block: (var lfqT = queue.getConsumerHere(0); lfqT.pop()))
  check((block: (var lfqT = queue.getConsumerHere(0); lfqT.pop())).isNone)
  queue.checkState(head = 8'u64, tail = 8'u64, data = (@[1, 2, 3, 4, 5, 6, 7, 8]))

template testSucPopWrap(queue: untyped) =
  discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])
  for i in 1 .. 4:
    discard (block: (var lfqT = queue.getConsumerHere(0); lfqT.pop()))
  discard queue.push(@[9, 10, 11, 12])
  var items = newSeq[int]()
  for i in 1 .. 8:
    var res = (block: (var lfqT = queue.getConsumerHere(0); lfqT.pop()))
    check(res.isSome)
    items.add(res.get)
  check(items == @[5, 6, 7, 8, 9, 10, 11, 12])
  queue.checkState(head = 12'u64, tail = 12'u64, data = (@[9, 10, 11, 12, 5, 6, 7, 8]))

template testSucPopCountOne(queue: untyped) =
  check(queue.push(@[1, 2, 3, 4, 5, 6, 7, 8]).isNone)
  for i in 1 .. 8:
    var popped = (block: (var lfqT = queue.getConsumerHere(0); lfqT.pop(1)))
    check(popped.isSome)
    check(popped.get() == @[i])
  queue.checkState(head = 8'u64, tail = 8'u64, data = (@[1, 2, 3, 4, 5, 6, 7, 8]))

template testSucPopCountAll(queue: untyped) =
  discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])
  var popped = (block: (var lfqT = queue.getConsumerHere(0); lfqT.pop(8)))
  check(popped.isSome)
  check(popped.get() == @[1, 2, 3, 4, 5, 6, 7, 8])
  queue.checkState(head = 8'u64, tail = 8'u64, data = (@[1, 2, 3, 4, 5, 6, 7, 8]))

template testSucPopCountEmpty(queue: untyped) =
  var popped = (block: (var lfqT = queue.getConsumerHere(0); lfqT.pop(1)))
  check(popped.isNone)
  queue.checkState(head = 0'u64, tail = 0'u64)

template testSucPopCountTooMany(queue: untyped) =
  check(queue.push(@[1, 2, 3, 4, 5, 6, 7, 8]).isNone)
  queue.checkState(head = 0'u64, tail = 8'u64, data = (@[1, 2, 3, 4, 5, 6, 7, 8]))
  var popped = (block: (var lfqT = queue.getConsumerHere(0); lfqT.pop(10)))
  check(popped.isSome)
  check(popped.get() == @[1, 2, 3, 4, 5, 6, 7, 8])
  queue.checkState(head = 8'u64, tail = 8'u64, data = (@[1, 2, 3, 4, 5, 6, 7, 8]))

template testSucPopCountWrap(queue: untyped) =
  discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])
  discard (block: (var lfqT = queue.getConsumerHere(0); lfqT.pop(4)))
  discard queue.push(@[9, 10, 11, 12])
  var popped = (block: (var lfqT = queue.getConsumerHere(1); lfqT.pop(8)))
  check(popped.isSome)
  check(popped.get() == @[5, 6, 7, 8, 9, 10, 11, 12])
  queue.checkState(head = 12'u64, tail = 12'u64, data = (@[9, 10, 11, 12, 5, 6, 7, 8]))

template testSucGetConsumerAssigns(queue: untyped) =
  let consumer = queue.getConsumer()
  check(consumer.idx >= 0)
  check(consumer.idx < 4)

template testSucGetConsumerReusesAssigned(queue: untyped) =
  let consumer1 = queue.getConsumer()
  let consumer2 = queue.getConsumer()
  check(consumer1.idx == consumer2.idx)

template testSucGetConsumerExplicitIndex(queue: untyped) =
  var consumer = queue.getConsumerHere(2)
  check(consumer.idx == 2)

var q = q_mod.newBQueue[int, ccSingle, ccMulti, 8, 0, 4]()

suite "BQueue[int, ccSingle, ccMulti, 8, 0, 4]":
  test "capacity":
    check(q.capacity == 8)

  test "consumerCount":
    check(q.consumerCount == 4)

  test "initial state":
    q.checkState(head = 0'u64, tail = 0'u64, data = repeat(0, 8))
    q.checkState(head = 0'u64, tail = 0'u64)

suite "getConsumer(Queue SPMC)":
  setup:
    q.reset()

  test "assigns by thread id":
    testSucGetConsumerAssigns(q)

  test "reuses assigned":
    testSucGetConsumerReusesAssigned(q)

  test "explicit index":
    testSucGetConsumerExplicitIndex(q)

  test "throws NoConsumersAvailableError":
    for c in 0 ..< 4:
      q.consumerThreadIds[c].store(int.high - c, moSequentiallyConsistent)

    expect NoConsumersAvailableError:
      discard q.getConsumer()

suite "pop(QueueConsumer SPMC)":
  setup:
    q.reset()

  test "one":
    testSucPopOne(q)

  test "all":
    testSucPopAll(q)

  test "empty":
    testSucPopEmpty(q)

  test "too many":
    testSucPopTooMany(q)

  test "wrap":
    testSucPopWrap(q)

suite "pop(QueueConsumer SPMC, int)":
  setup:
    q.reset()

  test "one":
    testSucPopCountOne(q)

  test "all":
    testSucPopCountAll(q)

  test "empty":
    testSucPopCountEmpty(q)

  test "too many":
    testSucPopCountTooMany(q)

  test "wrap":
    testSucPopCountWrap(q)

suite "pop(Queue SPMC)":
  setup:
    q.reset()

  # B.2 direct pop on a ccMulti-consumer Queue is now a
  # compile-time `{.error.}`. The former runtime `InvalidCallDefect`
  # smoke-tests are superseded by compile-fail negative-
  # controls under tests/should_fail/.

suite "push(Queue SPMC, T)":
  setup:
    q.reset()

  test "basic":
    check(q.push(1) == true)
    q.checkState(head = 0'u64, tail = 1'u64)

  test "overflow":
    for i in 1 .. 8:
      check(q.push(i) == true)
    check(q.push(9) == false)

  test "wrap":
    for i in 1 .. 8:
      discard q.push(i)
    for i in 1 .. 4:
      discard (
        block:
          var lfqT = q.getConsumerHere(0)
          lfqT.pop()
      )
    for i in 9 .. 12:
      check(q.push(i) == true)
    q.checkState(head = 4'u64, tail = 12'u64, data = (@[9, 10, 11, 12, 5, 6, 7, 8]))

suite "push(Queue SPMC, seq[T])":
  setup:
    q.reset()

  test "basic":
    check(q.push(@[1, 2, 3, 4]).isNone)
    q.checkState(head = 0'u64, tail = 4'u64)

  test "overflow":
    let unpushed = q.push(@[1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
    check(unpushed.isSome)
    check(unpushed.get == 8 .. 9)

  test "wrap":
    discard q.push(@[1, 2, 3, 4, 5, 6, 7, 8])
    for i in 1 .. 4:
      discard (
        block:
          var lfqT = q.getConsumerHere(0)
          lfqT.pop()
      )
    check(q.push(@[9, 10, 11, 12]).isNone)
    q.checkState(head = 4'u64, tail = 12'u64, data = (@[9, 10, 11, 12, 5, 6, 7, 8]))

suite "capacity(Queue SPMC)":
  test "basic":
    testCapacity(q)

suite "Queue SPMC integration":
  setup:
    q.reset()

  test "head and tail reset":
    testHeadAndTailReset(q)
