discard """
  matrix: "--mm:orc; --mm:arc; --mm:refc"
  cmd: "nim c -r --threads:on --path:src $file"
"""

import unittest2
import std/options
import lockfree/atomics
import lockfree/bqueue128
import lockfree/constants

suite "BQueue128 (128-Bit DWCAS Bounded MPMC Queue)":

  test "Single-threaded basic FIFO, boundary conditions, and len":
    const Cap = 8
    var q = initBQueue128[int, Cap]()
    check q.capacity == Cap
    check q.len == 0
    check q.isEmpty
    check not q.isFull

    # Push up to capacity
    for i in 1 .. Cap:
      check q.tryPush(i * 10)
      check q.len == i

    check q.isFull
    check not q.isEmpty
    # Next push must fail because queue is full
    check not q.tryPush(999)

    # Peek check
    var peekVal: int
    check q.tryPeek(peekVal)
    check peekVal == 10
    check q.peek().get() == 10

    # Pop elements
    for i in 1 .. Cap:
      var val: int
      check q.tryPop(val)
      check val == i * 10

    check q.isEmpty
    check q.len == 0
    check not q.tryPop(peekVal)
    check q.pop().isNone()

  test "Multi-turn wrap-around across ring buffer cycles":
    const Cap = 16
    var q = initBQueue128[uint64, Cap]()
    const TotalOps = 20_000

    for i in 1'u64 .. TotalOps:
      check q.tryPush(i)
      var val: uint64
      check q.tryPop(val)
      check val == i

    check q.isEmpty
    check q.len == 0

  test "FIND-D2-01 regression: Counter wraparound across uint64.high without RangeDefect":
    const Cap = 8
    var q = initBQueue128[uint64, Cap]()
    # Advance state to just before uint64 overflow:
    let startPos = uint64.high - 4'u64
    store(q.head, startPos, moRelaxed)
    store(q.tail, startPos, moRelaxed)
    for i in 0 ..< Cap:
      let slotPos = startPos + uint64(i)
      var p: Pair[uint64, uint64]
      p.first = slotPos
      p.second = 0'u64
      store(q.cells[slotPos and uint64(Cap - 1)], p, moRelaxed)

    # Perform pushes, peeks, and pops across the uint64.high boundary (wraps around to 0)
    for i in 1'u64 .. 20'u64:
      check q.tryPush(i * 100)
      var peekVal: uint64
      check q.tryPeek(peekVal)
      check peekVal == i * 100
      var val: uint64
      check q.tryPop(val)
      check val == i * 100

    check q.isEmpty

  test "Drain and clear operations":
    const Cap = 32
    var q = initBQueue128[int, Cap]()
    for i in 1 .. 20:
      check q.tryPush(i)
    check q.len == 20

    let drained = q.drain()
    check drained.len == 20
    for i in 0 ..< 20:
      check drained[i] == i + 1
    check q.isEmpty

    for i in 1 .. 15:
      check q.tryPush(i)
    q.clear()
    check q.isEmpty

  test "Heap-allocated aligned instance verification":
    const Cap = 64
    let q = allocAlignedBQueue128[int, Cap]()
    let addrUint = cast[uint](q)
    check (addrUint mod uint(CacheLineBytes)) == 0

    for i in 1 .. Cap:
      check q[].tryPush(i)

    var sum = 0
    var val: int
    while q[].tryPop(val):
      sum += val

    check sum == (Cap * (Cap + 1)) div 2
    freeAlignedBQueue128(q)

  test "Multi-threaded SPSC: 1 Producer, 1 Consumer":
    const Cap = 64
    const Count = 50_000
    var q = initBQueue128[int, Cap]()

    type SpscCtx = object
      qPtr: ptr BQueue128[int, Cap]
      consumerSum: Atomic[int64]

    var ctx: SpscCtx
    ctx.qPtr = addr q
    store(ctx.consumerSum, 0'i64)

    proc producer(c: ptr SpscCtx) {.thread.} =
      for i in 1 .. Count:
        while not c.qPtr[].tryPush(i):
          discard

    proc consumer(c: ptr SpscCtx) {.thread.} =
      var total: int64 = 0
      var popped = 0
      var val: int
      while popped < Count:
        if c.qPtr[].tryPop(val):
          total += val
          inc popped
      store(c.consumerSum, total)

    var prodThread: Thread[ptr SpscCtx]
    var consThread: Thread[ptr SpscCtx]

    createThread(consThread, consumer, addr ctx)
    createThread(prodThread, producer, addr ctx)

    joinThread(prodThread)
    joinThread(consThread)

    let expectedSum = (int64(Count) * int64(Count + 1)) div 2
    check load(ctx.consumerSum) == expectedSum
    check q.isEmpty

  test "Multi-threaded MPMC: 4 Producers, 4 Consumers":
    const Cap = 128
    const ItemsPerProducer = 20_000
    const NumProducers = 4
    const NumConsumers = 4
    const TotalItems = NumProducers * ItemsPerProducer

    var q = initBQueue128[int, Cap]()

    type MpmcCtx = object
      qPtr: ptr BQueue128[int, Cap]
      itemsConsumed: Atomic[int]
      totalConsumedSum: Atomic[int64]

    var ctx: MpmcCtx
    ctx.qPtr = addr q
    store(ctx.itemsConsumed, 0)
    store(ctx.totalConsumedSum, 0'i64)

    proc producerWorker(c: ptr MpmcCtx) {.thread.} =
      for i in 1 .. ItemsPerProducer:
        while not c.qPtr[].tryPush(i):
          discard

    proc consumerWorker(c: ptr MpmcCtx) {.thread.} =
      var localSum: int64 = 0
      var val: int
      while true:
        if c.qPtr[].tryPop(val):
          localSum += val
          let count = c.itemsConsumed.fetchAdd(1) + 1
          if count == TotalItems:
            discard c.totalConsumedSum.fetchAdd(localSum)
            break
          elif count > TotalItems:
            break
        else:
          if load(c.itemsConsumed) >= TotalItems:
            discard fetchAdd(c.totalConsumedSum, localSum)
            break

    var prodThreads: array[NumProducers, Thread[ptr MpmcCtx]]
    var consThreads: array[NumConsumers, Thread[ptr MpmcCtx]]

    for i in 0 ..< NumConsumers:
      createThread(consThreads[i], consumerWorker, addr ctx)

    for i in 0 ..< NumProducers:
      createThread(prodThreads[i], producerWorker, addr ctx)

    for i in 0 ..< NumProducers:
      joinThread(prodThreads[i])

    for i in 0 ..< NumConsumers:
      joinThread(consThreads[i])

    let expectedSum = int64(NumProducers) * ((int64(ItemsPerProducer) * int64(ItemsPerProducer + 1)) div 2)
    check load(ctx.itemsConsumed) == TotalItems
    check load(ctx.totalConsumedSum) == expectedSum
    check q.isEmpty
