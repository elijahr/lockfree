## Multi-threaded integration tests for SkipListSet.
## Remediates GM-07 by checking insert return values for lost updates.

when not compileOption("threads"):
  {.error: "tests/t_set_threaded requires --threads:on".}

import unittest2
import lockfree/set
import lockfree/atomics
import lockfree/smr/nebr

suite "SkipListSet - Multithreaded Concurrency":
  const
    ItemCount = 2000
    ThreadCount = 4
    ItemsPerThread = ItemCount div ThreadCount

  type
    DisjointWorkerCtx = object
      set: ptr Set[int]
      threadIdx: int
      failedCount: ptr Atomic[int]

    OverlappingWorkerCtx = object
      set: ptr Set[int]
      threadIdx: int

    MixedWorkerCtx = object
      set: ptr Set[int]
      threadIdx: int
      insertDone: ptr Atomic[bool]

  proc disjointInsertWorker(ctx: ptr DisjointWorkerCtx) {.thread.} =
    {.cast(gcsafe).}:
      let base = ctx.threadIdx * ItemsPerThread
      for i in 0 ..< ItemsPerThread:
        let inserted = ctx.set[].insert(base + i)
        if not inserted:
          discard ctx.failedCount[].fetchAdd(1, moRelaxed)

  proc overlappingInsertWorker(ctx: ptr OverlappingWorkerCtx) {.thread.} =
    {.cast(gcsafe).}:
      # Each thread attempts to insert the same 0 ..< 500 range
      for i in 0 ..< 500:
        discard ctx.set[].insert(i)

  proc mixedWorker(ctx: ptr MixedWorkerCtx) {.thread.} =
    {.cast(gcsafe).}:
      let base = ctx.threadIdx * 500
      for i in 0 ..< 500:
        discard ctx.set[].insert(base + i)
      # Now remove half of them
      for i in 0 ..< 250:
        discard ctx.set[].remove(base + i)

  test "Concurrent Disjoint Insertions (2,000 items)":
    var s = newSet[int]()
    var failed: Atomic[int]
    failed.store(0, moRelaxed)
    var ctxs: array[ThreadCount, DisjointWorkerCtx]
    var threads: array[ThreadCount, Thread[ptr DisjointWorkerCtx]]

    for i in 0 ..< ThreadCount:
      ctxs[i] = DisjointWorkerCtx(set: addr s, threadIdx: i, failedCount: addr failed)
      createThread(threads[i], disjointInsertWorker, addr ctxs[i])

    for i in 0 ..< ThreadCount:
      joinThread(threads[i])

    check failed.load(moRelaxed) == 0
    check s.len == ItemCount
    for i in 0 ..< ItemCount:
      check s.contains(i)

    # Verify order is strictly sorted
    var prev = -1
    var count = 0
    for x in s:
      check x > prev
      prev = x
      inc count
    check count == ItemCount

  test "Concurrent Overlapping Insertions & Deduplication":
    var s = newSet[int]()
    var ctxs: array[ThreadCount, OverlappingWorkerCtx]
    var threads: array[ThreadCount, Thread[ptr OverlappingWorkerCtx]]

    for i in 0 ..< ThreadCount:
      ctxs[i] = OverlappingWorkerCtx(set: addr s, threadIdx: i)
      createThread(threads[i], overlappingInsertWorker, addr ctxs[i])

    for i in 0 ..< ThreadCount:
      joinThread(threads[i])

    check s.len == 500
    for i in 0 ..< 500:
      check s.contains(i)

  test "Concurrent Interleaved Insert & Remove Stress":
    var s = newSet[int]()
    var ctxs: array[ThreadCount, MixedWorkerCtx]
    var threads: array[ThreadCount, Thread[ptr MixedWorkerCtx]]
    var flag: Atomic[bool]
    flag.store(false, moRelaxed)

    for i in 0 ..< ThreadCount:
      ctxs[i] = MixedWorkerCtx(set: addr s, threadIdx: i, insertDone: addr flag)
      createThread(threads[i], mixedWorker, addr ctxs[i])

    for i in 0 ..< ThreadCount:
      joinThread(threads[i])

    # 4 threads inserted 500 each (2000 total), then each removed 250 (1000 remaining)
    check s.len == 1000
    for t in 0 ..< ThreadCount:
      let base = t * 500
      for i in 0 ..< 250:
        check not s.contains(base + i)
      for i in 250 ..< 500:
        check s.contains(base + i)
