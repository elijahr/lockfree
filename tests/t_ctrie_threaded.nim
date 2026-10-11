## Multi-threaded integration tests for Ctrie.

import std/[options, os, hashes]
import unittest2
import lockfree
import lockfree/ctrie

suite "Ctrie Multi-Threaded Concurrency":
  type
    StressContext = object
      map: ptr Ctrie[int, int, 64]
      numItemsPerThread: int
      threadId: int

  proc workerThread(ctx: ptr StressContext) {.thread.} =
    let startIdx = ctx.threadId * ctx.numItemsPerThread
    let endIdx = startIdx + ctx.numItemsPerThread
    for i in startIdx ..< endIdx:
      ctx.map[].put(i, i * 2)

  test "4 threads concurrent insertions":
    var map = newCtrie[int, int, 64]()
    const NumThreads = 4
    const ItemsPerThread = 250
    var threads: array[NumThreads, Thread[ptr StressContext]]
    var ctxs: array[NumThreads, StressContext]

    for i in 0 ..< NumThreads:
      ctxs[i] = StressContext(
        map: addr map,
        numItemsPerThread: ItemsPerThread,
        threadId: i
      )
      createThread(threads[i], workerThread, addr ctxs[i])

    for i in 0 ..< NumThreads:
      joinThread(threads[i])

    check map.len == NumThreads * ItemsPerThread
    for i in 0 ..< NumThreads * ItemsPerThread:
      check map.get(i) == some(i * 2)

suite "Ctrie Remediations: HIGH-02 computeIfAbsent Concurrency":
  type
    ComputeContext = object
      map: ptr Ctrie[int, int, 64]
      results: ptr array[8, int]
      threadId: int

  proc computeWorker(ctx: ptr ComputeContext) {.thread.} =
    let res = ctx.map[].computeIfAbsent(1001, proc(k: int): int =
      # Thread-specific compute attempt
      (ctx.threadId + 1) * 100
    )
    ctx.results[ctx.threadId] = res

  test "8 threads concurrent computeIfAbsent on single key":
    var map = newCtrie[int, int, 64]()
    const NumThreads = 8
    var threads: array[NumThreads, Thread[ptr ComputeContext]]
    var ctxs: array[NumThreads, ComputeContext]
    var results: array[NumThreads, int]

    for i in 0 ..< NumThreads:
      ctxs[i] = ComputeContext(
        map: addr map,
        results: addr results,
        threadId: i
      )
      createThread(threads[i], computeWorker, addr ctxs[i])

    for i in 0 ..< NumThreads:
      joinThread(threads[i])

    check map.len == 1
    let winner = map.get(1001)
    check winner.isSome
    # Every thread must observe the exact same value without lost updates
    for i in 0 ..< NumThreads:
      check results[i] == winner.get

suite "Ctrie Remediations: CRIT-02 Snapshot SMR Pinning & Concurrent Mutation":
  type
    MutatorContext = object
      map: ptr Ctrie[int, int, 64]
      stopFlag: ptr Atomic[bool]

    ReaderContext = object
      snap: Snapshot[int, int, 64]
      stopFlag: ptr Atomic[bool]
      readCount: int

  proc mutatorThread(ctx: ptr MutatorContext) {.thread.} =
    var iter = 0
    while not ctx.stopFlag[].load(moAcquire):
      inc iter
      # Overwrite existing keys to retire nodes
      for k in 1 .. 50:
        ctx.map[].put(k, iter * 1000 + k)
      # Delete and reinsert
      for k in 26 .. 50:
        discard ctx.map[].delete(k)
      for k in 26 .. 50:
        ctx.map[].put(k, iter * 2000 + k)

  proc readerThread(ctx: ptr ReaderContext) {.thread.} =
    while not ctx.stopFlag[].load(moAcquire):
      for k, v in ctx.snap.pairs:
        inc ctx.readCount
        if k in 1 .. 50:
          # In the snapshot, all keys 1..50 must have their original snapshot values!
          assert v == k * 10
      let v1 = ctx.snap.get(1)
      assert v1 == some(10)

  test "concurrent mutator and snapshot reader under SMR epoch transitions":
    var map = newCtrie[int, int, 64]()
    for i in 1 .. 50:
      map[i] = i * 10

    let snap = map.snapshot()
    var stopFlag: Atomic[bool]
    stopFlag.store(false, moRelaxed)

    var mutCtx = MutatorContext(map: addr map, stopFlag: addr stopFlag)
    var readCtx = ReaderContext(snap: snap, stopFlag: addr stopFlag, readCount: 0)

    var tMut: Thread[ptr MutatorContext]
    var tRead: Thread[ptr ReaderContext]

    createThread(tMut, mutatorThread, addr mutCtx)
    createThread(tRead, readerThread, addr readCtx)

    # Let threads run concurrently for 200ms
    sleep(200)
    stopFlag.store(true, moRelease)

    joinThread(tMut)
    joinThread(tRead)

    check readCtx.readCount > 0
    # Final check: snapshot must still be 100% intact
    check snap.len == 50
    for i in 1 .. 50:
      check snap.get(i) == some(i * 10)
