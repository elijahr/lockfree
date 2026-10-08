## Unit tests for ergonomic queue aliases and concurrency topology constructors
## Verifies that:
## 1. All bounded aliases (BoundedQueue, MpmcBoundedQueue, SpscBoundedQueue, MpscBoundedQueue, SpmcBoundedQueue)
##    and their constructors compile, instantiate, and function identically to BQueue.
## 2. All unbounded aliases (UnboundedQueue, MpmcQueue, SpscQueue, MpscQueue, SpmcQueue)
##    and their constructors compile, instantiate, and function identically to Queue.
## 3. All aliases are cleanly accessible directly via `import lockfree`.

import unittest2
import lockfree
import std/options

suite "Ergonomic Queue Aliases & Concurrency Topology Verification":

  test "BoundedQueue generic alias":
    var q = newBoundedQueue[int, ccSingle, ccSingle, 16, 0, 0]()
    check q.push(10)
    check q.push(20)
    let a = q.pop()
    let b = q.pop()
    check a.isSome and a.get == 10
    check b.isSome and b.get == 20

  test "SpscBoundedQueue alias and constructor":
    var q = newSpscBoundedQueue[int, 8]()
    check q.capacity == 8
    check q.push(42)
    let item = q.pop()
    check item.isSome and item.get == 42
    check q.pop().isNone

  test "MpmcBoundedQueue alias and constructor":
    var q = newMpmcBoundedQueue[int, 16, 4, 4]()
    check q.capacity == 16
    var p = q.getProducer(0).bindToThread()
    var c = q.getConsumer(0).bindToThread()
    check p.push(99)
    let item = c.pop()
    check item.isSome and item.get == 99

  test "MpscBoundedQueue alias and constructor":
    var q = newMpscBoundedQueue[int, 16, 4]()
    check q.capacity == 16
    var p = q.getProducer(0).bindToThread()
    check p.push(77)
    let item = q.pop()
    check item.isSome and item.get == 77

  test "SpmcBoundedQueue alias and constructor":
    var q = newSpmcBoundedQueue[int, 16, 4]()
    check q.capacity == 16
    var c = q.getConsumer(0).bindToThread()
    check q.push(88)
    let item = c.pop()
    check item.isSome and item.get == 88

  test "UnboundedQueue generic alias":
    var q = newUnboundedQueue[int, ccSingle, ccSingle, stEager, 16, 1]()
    var p = q.getProducer().bindToThread()
    var c = q.getConsumer().bindToThread()
    p.push(100)
    p.push(200)
    let a = c.pop()
    let b = c.pop()
    check a.isSome and a.get == 100
    check b.isSome and b.get == 200

  test "SpscQueue alias and constructor":
    var q = newSpscUnboundedQueue[int, stEager, 16, 1]()
    var p = q.getProducer().bindToThread()
    var c = q.getConsumer().bindToThread()
    p.push(123)
    let item = c.pop()
    check item.isSome and item.get == 123

  test "MpmcQueue alias and constructor":
    var q = newMpmcUnboundedQueue[int, stEager, 16, 4]()
    var p = q.getProducer().bindToThread()
    var c = q.getConsumer().bindToThread()
    p.push(555)
    let item = c.pop()
    check item.isSome and item.get == 555

  test "MpscQueue alias and constructor":
    var q = newMpscUnboundedQueue[int, stEager, 16, 4]()
    var p = q.getProducer().bindToThread()
    var c = q.getConsumer().bindToThread()
    p.push(666)
    let item = c.pop()
    check item.isSome and item.get == 666

  test "SpmcQueue alias and constructor":
    var q = newSpmcUnboundedQueue[int, stEager, 16, 4]()
    var p = q.getProducer().bindToThread()
    var c = q.getConsumer().bindToThread()
    p.push(777)
    let item = c.pop()
    check item.isSome and item.get == 777
