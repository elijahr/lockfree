## Tier 2: Multithreaded concurrency test suite for TreiberStack with Elimination-Backoff Array.
## Validates multi-threaded MPSC, SPMC, MPMC, and elimination collision exchange.

when not compileOption("threads"):
  {.error: "t_stack_threaded requires --threads:on".}

import std/options
import unittest2

import lockfree/stack
import lockfree/atomics
import lockfree/backoff

const
  ItemCount = 2000
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
    var consumed = 0
    while true:
      let item = s.pop()
      if item.isNone:
        break
      let val = item.get
      check val >= 0 and val < ItemCount
      check not received[val].exchange(true, moRelaxed)
      inc consumed

    check consumed == ItemCount
    for i in 0 ..< ItemCount:
      check received[i].load(moRelaxed)
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

  test "MPMC - 4 producers, 4 consumers":
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
    # Stresses the elimination array with concurrent pushers and poppers
    # Remediates GM-01: asserts exact conservation between pushed, popped, and drained items.
    var s = initTreiberStack[int]()
    const OpsPerThread = 2000
    var totalPushed {.global.}: Atomic[int]
    var totalPopped {.global.}: Atomic[int]
    totalPushed.store(0, moRelaxed)
    totalPopped.store(0, moRelaxed)

    type WorkerCtx = object
      stack: ptr TreiberStack[int]

    proc workerPushPop(ctx: ptr WorkerCtx) {.thread.} =
      {.cast(gcsafe).}:
        for i in 0 ..< OpsPerThread:
          ctx.stack[].push(i)
          discard totalPushed.fetchAdd(1, moRelaxed)
          let item = ctx.stack[].pop()
          if item.isSome:
            discard totalPopped.fetchAdd(1, moRelaxed)

    var wCtx: array[4, WorkerCtx]
    var wThreads: array[4, Thread[ptr WorkerCtx]]
    for i in 0 ..< 4:
      wCtx[i] = WorkerCtx(stack: addr s)
      createThread(wThreads[i], workerPushPop, addr wCtx[i])

    for i in 0 ..< 4:
      joinThread(wThreads[i])

    let drained = s.drain()
    check totalPushed.load(moRelaxed) == totalPopped.load(moRelaxed) + drained.len
    check s.isEmpty
    check s.len == 0

  test "Preemptive high-contention push/pop/peek/drain with sched_yield":
    const
      StressThreads = 8
      StressIters = 1000
    var s = initTreiberStack[int]()
    var pushedSum {.global.}: Atomic[int]
    var poppedSum {.global.}: Atomic[int]
    var invalidPeek {.global.}: Atomic[bool]
    pushedSum.store(0, moRelaxed)
    poppedSum.store(0, moRelaxed)
    invalidPeek.store(false, moRelaxed)

    type PreemptIntCtx = object
      stack: ptr TreiberStack[int]
      tid: int

    proc preemptIntWorker(ctx: ptr PreemptIntCtx) {.thread.} =
      {.cast(gcsafe).}:
        ctx.stack[].registerThread()
        defer:
          ctx.stack[].unregisterThread()
        for i in 1 .. StressIters:
          let val = ctx.tid * 10000 + i
          ctx.stack[].push(val)
          discard pushedSum.fetchAdd(val, moRelaxed)
          if (i and 7) == 0:
            schedYield()
          let pk = ctx.stack[].peek()
          if pk.isSome:
            if pk.get <= 0:
              invalidPeek.store(true, moRelaxed)
          if (i and 3) == 0:
            schedYield()
          if (i mod 97) == 0:
            let batch = ctx.stack[].drain()
            var batchSum = 0
            for b in batch:
              batchSum += b
            discard poppedSum.fetchAdd(batchSum, moRelaxed)
          else:
            let popped = ctx.stack[].pop()
            if popped.isSome:
              discard poppedSum.fetchAdd(popped.get, moRelaxed)

    var ctxs: array[StressThreads, PreemptIntCtx]
    var threads: array[StressThreads, Thread[ptr PreemptIntCtx]]
    for i in 0 ..< StressThreads:
      ctxs[i] = PreemptIntCtx(stack: addr s, tid: i + 1)
      createThread(threads[i], preemptIntWorker, addr ctxs[i])

    for i in 0 ..< StressThreads:
      joinThread(threads[i])

    let tailDrain = s.drain()
    var tailSum = 0
    for v in tailDrain:
      tailSum += v

    check not invalidPeek.load(moRelaxed)
    check pushedSum.load(moRelaxed) == poppedSum.load(moRelaxed) + tailSum
    check s.isEmpty
    check s.len == 0

