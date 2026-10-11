## Multi-threaded integration tests for Atomic Associative Map Operations.

import std/[options, algorithm]
import unittest2
import lockfree
import lockfree/ctrie
import lockfree/skiplist

suite "Wave 5A: Multi-Threaded Concurrency & Lost Update Stress":
  type
    CounterContextCtrie = object
      map: ptr Ctrie[int, int, 64]
      increments: int

    CounterContextSkipList = object
      map: ptr SkipListMap[int, int, 64, 16]
      increments: int

  proc ctrieCounterWorker(ctx: ptr CounterContextCtrie) {.thread.} =
    for _ in 0 ..< ctx.increments:
      discard ctx.map[].atomicUpdate(42, proc(oldVal: int): int = oldVal + 1)

  proc skipListCounterWorker(ctx: ptr CounterContextSkipList) {.thread.} =
    for _ in 0 ..< ctx.increments:
      discard ctx.map[].atomicUpdate(42, proc(oldVal: int): int = oldVal + 1)

  test "Ctrie atomicUpdate 8 threads concurrent counter (zero lost updates)":
    var map = newCtrie[int, int, 64]()
    discard map.put(42, 0)

    const NumThreads = 8
    const IncrementsPerThread = 1000
    var threads: array[NumThreads, Thread[ptr CounterContextCtrie]]
    var ctxs: array[NumThreads, CounterContextCtrie]

    for i in 0 ..< NumThreads:
      ctxs[i] = CounterContextCtrie(
        map: addr map,
        increments: IncrementsPerThread
      )
      createThread(threads[i], ctrieCounterWorker, addr ctxs[i])

    for i in 0 ..< NumThreads:
      joinThread(threads[i])

    let expected = NumThreads * IncrementsPerThread
    let actual = map.get(42).get
    check actual == expected

  test "SkipListMap atomicUpdate 8 threads concurrent counter (zero lost updates)":
    var map = newSkipListMap[int, int, 64, 16]()
    discard map.put(42, 0)

    const NumThreads = 8
    const IncrementsPerThread = 1000
    var threads: array[NumThreads, Thread[ptr CounterContextSkipList]]
    var ctxs: array[NumThreads, CounterContextSkipList]

    for i in 0 ..< NumThreads:
      ctxs[i] = CounterContextSkipList(
        map: addr map,
        increments: IncrementsPerThread
      )
      createThread(threads[i], skipListCounterWorker, addr ctxs[i])

    for i in 0 ..< NumThreads:
      joinThread(threads[i])

    let expected = NumThreads * IncrementsPerThread
    let actual = map.get(42).get
    check actual == expected

  type
    UpsertContextCtrie = object
      map: ptr Ctrie[int, int, 64]
      threadId: int
      items: int

    UpsertContextSkipList = object
      map: ptr SkipListMap[int, int, 64, 16]
      threadId: int
      items: int

  proc ctrieUpsertWorker(ctx: ptr UpsertContextCtrie) {.thread.} =
    for i in 0 ..< ctx.items:
      let k = i mod 20
      discard ctx.map[].upsert(k, 1, proc(oldVal: int): int = oldVal + 1)

  proc skipListUpsertWorker(ctx: ptr UpsertContextSkipList) {.thread.} =
    for i in 0 ..< ctx.items:
      let k = i mod 20
      discard ctx.map[].upsert(k, 1, proc(oldVal: int): int = oldVal + 1)

  test "Ctrie concurrent upsert contention across overlapping keys":
    var map = newCtrie[int, int, 64]()
    const NumThreads = 8
    const ItemsPerThread = 500
    var threads: array[NumThreads, Thread[ptr UpsertContextCtrie]]
    var ctxs: array[NumThreads, UpsertContextCtrie]

    for i in 0 ..< NumThreads:
      ctxs[i] = UpsertContextCtrie(
        map: addr map,
        threadId: i,
        items: ItemsPerThread
      )
      createThread(threads[i], ctrieUpsertWorker, addr ctxs[i])

    for i in 0 ..< NumThreads:
      joinThread(threads[i])

    check map.len == 20
    var sum = 0
    for k in 0 ..< 20:
      sum += map.get(k).get
    check sum == NumThreads * ItemsPerThread

  test "SkipListMap concurrent upsert contention across overlapping keys":
    var map = newSkipListMap[int, int, 64, 16]()
    const NumThreads = 8
    const ItemsPerThread = 500
    var threads: array[NumThreads, Thread[ptr UpsertContextSkipList]]
    var ctxs: array[NumThreads, UpsertContextSkipList]

    for i in 0 ..< NumThreads:
      ctxs[i] = UpsertContextSkipList(
        map: addr map,
        threadId: i,
        items: ItemsPerThread
      )
      createThread(threads[i], skipListUpsertWorker, addr ctxs[i])

    for i in 0 ..< NumThreads:
      joinThread(threads[i])

    check map.len == 20
    var sum = 0
    for k in 0 ..< 20:
      sum += map.get(k).get
    check sum == NumThreads * ItemsPerThread

  test "Concurrent snapshot iteration while writers perform atomicUpdate & upsert":
    var map = newSkipListMap[int, int, 64, 16]()
    for i in 0 ..< 50:
      discard map.put(i, i * 10)

    # Background reader takes snapshots while writer updates
    type SnapshotContext = object
      map: ptr SkipListMap[int, int, 64, 16]
      snapshotsTaken: int

    proc readerWorker(ctx: ptr SnapshotContext) {.thread.} =
      for _ in 0 ..< 50:
        let snap = ctx.map[].snapshotPairs()
        check snap.len >= 50
        # Assert strictly sorted keys in snapshot
        for idx in 1 ..< snap.len:
          check snap[idx][0] > snap[idx - 1][0]
        inc ctx.snapshotsTaken

    var readerThread: Thread[ptr SnapshotContext]
    var rCtx = SnapshotContext(map: addr map, snapshotsTaken: 0)
    createThread(readerThread, readerWorker, addr rCtx)

    # Writer performs atomicUpdates concurrently
    for round in 0 ..< 500:
      let k = round mod 50
      discard map.atomicUpdate(k, proc(v: int): int = v + 1)

    joinThread(readerThread)
    check rCtx.snapshotsTaken == 50
