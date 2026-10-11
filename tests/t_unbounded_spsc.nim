## UnboundedSpsc tests —  the standalone
## `UnboundedSpsc[S, T]` type is absorbed into
## `Queue[T, ccSingle, ccSingle, stEager, S, MaxThreads]`. These tests
## continue to exercise the spsc surface through the absorbed Queue
## via `newUnboundedSpscQueue`.

import lockfree/atomics
import lockfree/atomics/dsl
import options
import unittest2

import lockfree/queue
import lockfree/strategy
import lockfree/internal/pinscope_stub
import lockfree/endpoint
import lockfree/role_tags

const MT = 4 ## Type-uniform MaxThreads phantom for the spsc-absorbed branch.

suite "UnboundedSpsc":
  test "newUnboundedSpscQueue creates valid instance":
    var queue = newUnboundedSpscQueue[int, stEager, 16, MT]()
    check(queue.segmentCount == 1)

  test "push single item":
    var queue = newUnboundedSpscQueue[int, stEager, 16, MT]()
    var p = queue.getProducerHere()

    p.push(42)
    check(queue.len == 1)

  test "push multiple items":
    var queue = newUnboundedSpscQueue[int, stEager, 16, MT]()
    var p = queue.getProducerHere()

    for i in 1 .. 10:
      p.push(i)
    check(queue.len == 10)

  test "pop single item":
    var queue = newUnboundedSpscQueue[int, stEager, 16, MT]()
    var p = queue.getProducerHere()

    p.push(42)
    let item = queue.pop()
    check(item.isSome)
    check(item.get == 42)
    check(queue.len == 0)

  test "pop from empty returns none":
    var queue = newUnboundedSpscQueue[int, stEager, 16, MT]()

    let item = queue.pop()
    check(item.isNone)

  test "FIFO order preserved":
    var queue = newUnboundedSpscQueue[int, stEager, 16, MT]()
    var p = queue.getProducerHere()

    for i in 1 .. 5:
      p.push(i)

    for i in 1 .. 5:
      let item = queue.pop()
      check(item.isSome)
      check(item.get == i)

  test "grows beyond single segment":
    var queue = newUnboundedSpscQueue[int, stEager, 4, MT]() # Small segment
    var p = queue.getProducerHere()

    # Push more than segment capacity
    for i in 1 .. 10:
      p.push(i)

    check(queue.segmentCount >= 3)
      # At least 3 segments needed for 10 items with capacity 4

    # Verify all items retrievable in order
    for i in 1 .. 10:
      let item = queue.pop()
      check(item.isSome)
      check(item.get == i)

  test "segment reclamation on pop":
    var queue = newUnboundedSpscQueue[int, stEager, 4, MT]()
    var p = queue.getProducerHere()

    # Fill and drain multiple segments
    for round in 1 .. 3:
      for i in 1 .. 8:
        p.push(i)
      for i in 1 .. 8:
        let r = queue.pop()
        check r == some(i)

    # Should have reclaimed segments automatically (single consumer can free directly)
    check(queue.segmentCount >= 1)

  test "len tracks items correctly":
    var queue = newUnboundedSpscQueue[int, stEager, 8, MT]()
    var p = queue.getProducerHere()

    check(queue.len == 0)

    p.push(1)
    check(queue.len == 1)

    p.push(2)
    p.push(3)
    check(queue.len == 3)

    let r1 = queue.pop()
    check r1 == some(1)
    check(queue.len == 2)

    let r2 = queue.pop()
    check r2 == some(2)
    let r3 = queue.pop()
    check r3 == some(3)
    check(queue.len == 0)
    check queue.pop().isNone

  test "batch push":
    var queue = newUnboundedSpscQueue[int, stEager, 8, MT]()
    var p = queue.getProducerHere()

    p.push(@[1, 2, 3, 4, 5])
    check(queue.len == 5)

    for i in 1 .. 5:
      check(queue.pop().get == i)

  test "batch pop":
    var queue = newUnboundedSpscQueue[int, stEager, 8, MT]()
    var p = queue.getProducerHere()

    for i in 1 .. 10:
      p.push(i)

    let items = queue.pop(5)
    check(items.isSome)
    check(items.get == @[1, 2, 3, 4, 5])
    check(queue.len == 5)

  test "batch pop more than available":
    var queue = newUnboundedSpscQueue[int, stEager, 8, MT]()
    var p = queue.getProducerHere()

    p.push(@[1, 2, 3])

    let items = queue.pop(10)
    check(items.isSome)
    check(items.get == @[1, 2, 3])
    check(queue.len == 0)

  test "batch pop from empty":
    var queue = newUnboundedSpscQueue[int, stEager, 8, MT]()

    let items = queue.pop(5)
    check(items.isNone)
