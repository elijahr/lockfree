## Tests for systems optimizations:
## 1. ARCH-01: Destructor walk for non-copyable value types with custom =destroy
## 2. Apple Silicon 128B CacheLineBytes
## 3. isEmpty and optional itemCount tracking

import std/atomics
import unittest2
import options

import lockfree/constants
import lockfree/bqueue
import lockfree/queue
import lockfree/endpoint
import lockfree/strategy

var customDtorCount {.global.}: Atomic[int]

type
  CustomHandle = object
    id: int

proc `=copy`(dst: var CustomHandle, src: CustomHandle) {.error.}
proc `=destroy`(x: var CustomHandle) =
  if x.id != 0:
    discard customDtorCount.fetchAdd(1, moRelaxed)
    x.id = 0

suite "Systems Optimization — ARCH-01 Non-Copyable Destructor Walk":
  test "BQueue SPSC destroys unpopped non-copyable items":
    customDtorCount.store(0, moRelaxed)
    block:
      var q = newSpscQueue[CustomHandle, 8]()
      discard q.push(CustomHandle(id: 101))
      discard q.push(CustomHandle(id: 102))
      # Queue dropped with items in flight
    check customDtorCount.load(moRelaxed) == 2

  test "BQueue MPMC destroys unpopped non-copyable items":
    customDtorCount.store(0, moRelaxed)
    block:
      var q = newMpmcQueue[CustomHandle, 8, 2, 2]()
      var p = q.getProducerHere()
      discard p.push(CustomHandle(id: 201))
      discard p.push(CustomHandle(id: 202))
    check customDtorCount.load(moRelaxed) == 2

  test "Queue SPSC destroys unpopped non-copyable items":
    customDtorCount.store(0, moRelaxed)
    block:
      var q = newQueue(Queue[CustomHandle, ccSingle, ccSingle, stEager, 8, 4])
      var p = q.getProducerHere()
      p.push(CustomHandle(id: 301))
      p.push(CustomHandle(id: 302))
    check customDtorCount.load(moRelaxed) == 2

  test "Queue MPMC destroys unpopped non-copyable items":
    customDtorCount.store(0, moRelaxed)
    block:
      var q = newQueue(Queue[CustomHandle, ccMulti, ccMulti, stEager, 8, 4])
      var p = q.getProducerHere()
      p.push(CustomHandle(id: 401))
      p.push(CustomHandle(id: 402))
    check customDtorCount.load(moRelaxed) == 2

  test "Queue MPMC popped item destroyed exactly once on receiver scope exit":
    customDtorCount.store(0, moRelaxed)
    block:
      var q = newQueue(Queue[CustomHandle, ccMulti, ccMulti, stEager, 8, 4])
      var p = q.getProducerHere()
      var c = q.getConsumerHere()
      p.push(CustomHandle(id: 501))
      check customDtorCount.load(moRelaxed) == 0
      let v = c.pop()
      check v.isSome and v.get.id == 501
      check customDtorCount.load(moRelaxed) == 0
    check customDtorCount.load(moRelaxed) == 1

suite "Systems Optimization — Apple Silicon 128B CacheLineBytes":
  test "CacheLineBytes matches architecture default":
    when (defined(macosx) and defined(arm64)) or defined(powerpc):
      check CacheLineBytes == 128
    else:
      check CacheLineBytes == 64

suite "Systems Optimization — Queue.isEmpty":
  test "isEmpty tracks emptiness across push and pop (SPSC)":
    var q = newQueue(Queue[int, ccSingle, ccSingle, stEager, 8, 4])
    var p = q.getProducerHere()
    var c = q.getConsumerHere()
    check q.isEmpty()
    p.push(42)
    check not q.isEmpty()
    let v = c.pop()
    check v.isSome and v.get == 42
    check q.isEmpty()

  test "isEmpty tracks emptiness across push and pop (MPMC)":
    var q = newQueue(Queue[int, ccMulti, ccMulti, stEager, 8, 4])
    var p = q.getProducerHere()
    var c = q.getConsumerHere()
    check q.isEmpty()
    p.push(100)
    check not q.isEmpty()
    let v = c.pop()
    check v.isSome and v.get == 100
    check q.isEmpty()
