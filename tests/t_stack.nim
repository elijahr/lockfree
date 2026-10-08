## Comprehensive test suite for TreiberStack with Elimination-Backoff Array.
## Validates API surface, LIFO ordering, bulk operations, managed types (ARC/ORC/refc),
## and multi-threaded MPSC, SPMC, and MPMC stress concurrency.

import std/options
import unittest2

import lockfree/stack
import lockfree/atomics

type
  PayloadRef = ref object
    id: int
    data: string

suite "TreiberStack - Basic API & Semantics":
  test "empty stack invariants":
    var s = initTreiberStack[int]()
    check s.len == 0
    check s.isEmpty
    check s.peek().isNone
    check s.pop().isNone
    check s.drain() == newSeq[int]()

  test "LIFO ordering single-threaded":
    var s = initTreiberStack[int]()
    s.push(1)
    s.push(2)
    s.push(3)
    check s.len == 3
    check not s.isEmpty

    let p1 = s.pop()
    check p1.isSome and p1.get == 3
    let p2 = s.pop()
    check p2.isSome and p2.get == 2
    let p3 = s.pop()
    check p3.isSome and p3.get == 1
    check s.pop().isNone
    check s.len == 0
    check s.isEmpty

  test "peek does not consume item":
    var s = newTreiberStack[string]()
    s.push("first")
    s.push("second")
    check s.peek() == some("second")
    check s.peek() == some("second")
    check s.len == 2
    check s.pop() == some("second")
    check s.peek() == some("first")
    check s.pop() == some("first")
    check s.peek().isNone

  test "peek and len on immutable binding":
    var s = initStack[int]()
    s.push(42)
    s.push(99)
    let ro = s # shallow alias via let
    check ro.len == 2
    check not ro.isEmpty
    check ro.peek() == some(99)

  test "bulk push openArray":
    var s = initStack[int]()
    s.push([10, 20, 30])
    check s.len == 3
    check s.pop() == some(30)
    check s.pop() == some(20)
    check s.pop() == some(10)
    check s.pop().isNone

  test "interleaved push and pop":
    var s = initStack[int]()
    s.push(1)
    s.push(2)
    check s.pop() == some(2)
    s.push(3)
    check s.pop() == some(3)
    s.push(4)
    check s.pop() == some(4)
    check s.pop() == some(1)
    check s.pop().isNone
    check s.isEmpty

  test "drain empty and populated":
    var s = initStack[int]()
    check s.drain() == newSeq[int]()

    s.push([1, 2, 3, 4, 5])
    let drained = s.drain()
    check drained == @[5, 4, 3, 2, 1]
    check s.isEmpty
    check s.len == 0
    check s.pop().isNone

  test "drainInto appends in LIFO order":
    var s = initStack[int]()
    var outSeq = @[100, 200]
    s.drainInto(outSeq)
    check outSeq == @[100, 200]

    s.push([10, 20, 30])
    s.drainInto(outSeq)
    check outSeq == @[100, 200, 30, 20, 10]
    check s.isEmpty
    check s.len == 0

  test "constructors and aliases":
    var s1 = initTreiberStack[int]()
    var s2 = newTreiberStack[int]()
    var s3 = initStack[int]()
    var s4 = newStack[int]()
    var s5: ref ConcurrentStack[int] = newConcurrentStack[int]()

    s1.push(1)
    s2.push(2)
    s3.push(3)
    s4.push(4)
    s5[].push(5)

    check s1.pop() == some(1)
    check s2.pop() == some(2)
    check s3.pop() == some(3)
    check s4.pop() == some(4)
    check s5[].pop() == some(5)

suite "TreiberStack - Managed Types (ARC/ORC/Refc)":
  test "string payloads and free-list recycling":
    var s = initStack[string]()
    for round in 0 ..< 10:
      for i in 0 ..< 50:
        s.push("item_" & $i)
      check s.len == 50
      for i in countdown(49, 0):
        check s.pop() == some("item_" & $i)
      check s.isEmpty

  test "seq[int] payloads":
    var s = initStack[seq[int]]()
    s.push(@[1, 2, 3])
    s.push(@[4, 5])
    s.push(@[6])
    check s.pop() == some(@[6])
    check s.pop() == some(@[4, 5])
    check s.pop() == some(@[1, 2, 3])
    check s.isEmpty

  test "ref object payloads":
    var s = initStack[PayloadRef]()
    s.push(PayloadRef(id: 1, data: "alpha"))
    s.push(PayloadRef(id: 2, data: "beta"))
    let b = s.pop()
    check b.isSome and b.get.id == 2 and b.get.data == "beta"
    let a = s.pop()
    check a.isSome and a.get.id == 1 and a.get.data == "alpha"
    check s.isEmpty

when compileOption("threads"):
  const
    ItemCount = 10000
    ThreadCount = 4
    ItemsPerThread = ItemCount div ThreadCount

  type
    MpscProdCtx = object
      stack: ptr TreiberStack[int]
      threadIdx: int

    SpmcConsCtx = object
      stack: ptr TreiberStack[int]
      received: ptr array[ItemCount, Atomic[bool]]
      duplicateFound: ptr Atomic[bool]
      totalConsumed: ptr Atomic[int]
      producerDone: ptr Atomic[bool]

    MpmcProdCtx = object
      stack: ptr TreiberStack[int]
      producersDone: ptr Atomic[int]
      threadIdx: int

    MpmcConsCtx = object
      stack: ptr TreiberStack[int]
      received: ptr array[ItemCount, Atomic[bool]]
      duplicateFound: ptr Atomic[bool]
      producersDone: ptr Atomic[int]
      totalConsumed: ptr Atomic[int]

  proc mpscProducer(ctx: ptr MpscProdCtx) {.thread.} =
    {.cast(gcsafe).}:
      let base = ctx.threadIdx * ItemsPerThread
      for i in 0 ..< ItemsPerThread:
        ctx.stack[].push(base + i)

  proc spmcConsumer(ctx: ptr SpmcConsCtx) {.thread.} =
    {.cast(gcsafe).}:
      while true:
        let item = ctx.stack[].pop()
        if item.isSome:
          let val = item.get
          if val >= 0 and val < ItemCount:
            if ctx.received[val].exchange(true, moRelaxed):
              ctx.duplicateFound[].store(true, moRelaxed)
          if ctx.totalConsumed[].fetchAdd(1, moRelaxed) + 1 >= ItemCount:
            break
        elif ctx.producerDone[].load(moAcquire):
          if ctx.totalConsumed[].load(moRelaxed) >= ItemCount:
            break

  proc mpmcProducer(ctx: ptr MpmcProdCtx) {.thread.} =
    {.cast(gcsafe).}:
      let base = ctx.threadIdx * ItemsPerThread
      for i in 0 ..< ItemsPerThread:
        ctx.stack[].push(base + i)
      discard ctx.producersDone[].fetchAdd(1, moRelease)

  proc mpmcConsumer(ctx: ptr MpmcConsCtx) {.thread.} =
    {.cast(gcsafe).}:
      while true:
        let item = ctx.stack[].pop()
        if item.isSome:
          let val = item.get
          if val >= 0 and val < ItemCount:
            if ctx.received[val].exchange(true, moRelaxed):
              ctx.duplicateFound[].store(true, moRelaxed)
          if ctx.totalConsumed[].fetchAdd(1, moRelaxed) + 1 >= ItemCount:
            break
        elif ctx.producersDone[].load(moAcquire) >= ThreadCount:
          if ctx.totalConsumed[].load(moRelaxed) >= ItemCount:
            break

  suite "TreiberStack - Multithreaded Concurrency":
    var
      received: array[ItemCount, Atomic[bool]]
      duplicateFound: Atomic[bool]
      producersDone: Atomic[int]
      producerDone: Atomic[bool]
      totalConsumed: Atomic[int]

    setup:
      for i in 0 ..< ItemCount:
        received[i].store(false, moRelaxed)
      duplicateFound.store(false, moRelaxed)
      producersDone.store(0, moRelaxed)
      producerDone.store(false, moRelaxed)
      totalConsumed.store(0, moRelaxed)

    test "MPSC - 4 producers, 1 consumer":
      var s = initTreiberStack[int]()
      var prodCtx: array[ThreadCount, MpscProdCtx]
      var prodThreads: array[ThreadCount, Thread[ptr MpscProdCtx]]

      for i in 0 ..< ThreadCount:
        prodCtx[i] = MpscProdCtx(stack: addr s, threadIdx: i)
        createThread(prodThreads[i], mpscProducer, addr prodCtx[i])

      for i in 0 ..< ThreadCount:
        joinThread(prodThreads[i])

      check s.len == ItemCount
      var poppedCount = 0
      while true:
        let it = s.pop()
        if it.isNone: break
        let v = it.get
        check v >= 0 and v < ItemCount
        check not received[v].exchange(true, moRelaxed)
        inc poppedCount

      check poppedCount == ItemCount
      check s.isEmpty

    test "SPMC - 1 producer, 4 consumers":
      var s = initTreiberStack[int]()
      var consCtx: array[ThreadCount, SpmcConsCtx]
      var consThreads: array[ThreadCount, Thread[ptr SpmcConsCtx]]

      for i in 0 ..< ThreadCount:
        consCtx[i] = SpmcConsCtx(
          stack: addr s,
          received: addr received,
          duplicateFound: addr duplicateFound,
          totalConsumed: addr totalConsumed,
          producerDone: addr producerDone
        )
        createThread(consThreads[i], spmcConsumer, addr consCtx[i])

      # Producer pushes all items
      for i in 0 ..< ItemCount:
        s.push(i)
      producerDone.store(true, moRelease)

      for i in 0 ..< ThreadCount:
        joinThread(consThreads[i])

      check not duplicateFound.load(moRelaxed)
      check totalConsumed.load(moRelaxed) == ItemCount
      for i in 0 ..< ItemCount:
        check received[i].load(moRelaxed)
      check s.isEmpty

    test "MPMC - 4 producers, 4 consumers (10,000 items)":
      var s = initTreiberStack[int]()
      var prodCtx: array[ThreadCount, MpmcProdCtx]
      var consCtx: array[ThreadCount, MpmcConsCtx]
      var prodThreads: array[ThreadCount, Thread[ptr MpmcProdCtx]]
      var consThreads: array[ThreadCount, Thread[ptr MpmcConsCtx]]

      for i in 0 ..< ThreadCount:
        consCtx[i] = MpmcConsCtx(
          stack: addr s,
          received: addr received,
          duplicateFound: addr duplicateFound,
          producersDone: addr producersDone,
          totalConsumed: addr totalConsumed
        )
        createThread(consThreads[i], mpmcConsumer, addr consCtx[i])

      for i in 0 ..< ThreadCount:
        prodCtx[i] = MpmcProdCtx(
          stack: addr s,
          producersDone: addr producersDone,
          threadIdx: i
        )
        createThread(prodThreads[i], mpmcProducer, addr prodCtx[i])

      for i in 0 ..< ThreadCount:
        joinThread(prodThreads[i])
      for i in 0 ..< ThreadCount:
        joinThread(consThreads[i])

      check not duplicateFound.load(moRelaxed)
      check totalConsumed.load(moRelaxed) == ItemCount
      for i in 0 ..< ItemCount:
        check received[i].load(moRelaxed)
      check s.isEmpty

    test "High-contention rapid push/pop collision exchange":
      # Stresses the elimination array by running concurrent pushers and poppers
      var s = initTreiberStack[int]()
      const OpsPerThread = 5000
      var doneFlag: Atomic[bool]
      doneFlag.store(false, moRelaxed)

      type WorkerCtx = object
        stack: ptr TreiberStack[int]
        done: ptr Atomic[bool]

      proc workerPushPop(ctx: ptr WorkerCtx) {.thread.} =
        {.cast(gcsafe).}:
          for i in 0 ..< OpsPerThread:
            ctx.stack[].push(i)
            discard ctx.stack[].pop()

      var wCtx: array[4, WorkerCtx]
      var wThreads: array[4, Thread[ptr WorkerCtx]]
      for i in 0 ..< 4:
        wCtx[i] = WorkerCtx(stack: addr s, done: addr doneFlag)
        createThread(wThreads[i], workerPushPop, addr wCtx[i])

      for i in 0 ..< 4:
        joinThread(wThreads[i])

      # Drain any remaining items and ensure stack integrity
      discard s.drain()
      check s.isEmpty
      check s.len == 0
