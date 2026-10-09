## # Test Suite: Wave 5A Atomic Associative Map Operations
##
## Verifies compound read-modify-write operations across Ctrie and SkipListMap:
## - computeIfAbsent
## - atomicUpdate
## - upsert
## - snapshotPairs, snapshotKeys, snapshotValues
## - High-contention multi-threaded counter stress (lost update verification)
## - ARC/ORC heap payload memory safety and SMR epoch safety

import std/[options, algorithm]
import unittest2
import lockfree
import lockfree/ctrie
import lockfree/skiplist

type
  PayloadRef = ref object
    count: int
    tag: string

suite "Wave 5A: Single-Threaded Atomic Associative Operations":
  test "Ctrie computeIfAbsent basic semantics":
    let map = newCtrie[string, int]()
    # Key absent: compute
    var callCount = 0
    let v1 = map.computeIfAbsent("counter", proc(k: string): int =
      inc callCount
      42
    )
    check v1 == 42
    check callCount == 1
    check map.len == 1
    check map.get("counter") == some(42)

    # Key present: do not compute
    let v2 = map.computeIfAbsent("counter", proc(k: string): int =
      inc callCount
      999
    )
    check v2 == 42
    check callCount == 1
    check map.len == 1

    # Parameterless overload
    let v3 = map.computeIfAbsent("other", proc(): int = 100)
    check v3 == 100
    check map.len == 2

  test "SkipListMap computeIfAbsent basic semantics":
    var map = newSkipListMap[string, int]()
    var callCount = 0
    let v1 = map.computeIfAbsent("counter", proc(k: string): int =
      inc callCount
      42
    )
    check v1 == 42
    check callCount == 1
    check map.len == 1
    check map.get("counter") == some(42)

    # Key present
    let v2 = map.computeIfAbsent("counter", proc(k: string): int =
      inc callCount
      999
    )
    check v2 == 42
    check callCount == 1
    check map.len == 1

    # Parameterless overload
    let v3 = map.computeIfAbsent("other", proc(): int = 100)
    check v3 == 100
    check map.len == 2

  test "Ctrie atomicUpdate semantics":
    let map = newCtrie[string, int]()
    # Absent key returns none
    check map.atomicUpdate("counter", proc(v: int): int = v + 1).isNone
    check map.len == 0

    # Insert key and update
    discard map.put("counter", 10)
    let res = map.atomicUpdate("counter", proc(v: int): int = v * 2)
    check res == some(20)
    check map.get("counter") == some(20)
    check map.len == 1

  test "SkipListMap atomicUpdate semantics":
    var map = newSkipListMap[string, int]()
    # Absent key returns none
    check map.atomicUpdate("counter", proc(v: int): int = v + 1).isNone
    check map.len == 0

    # Insert key and update
    discard map.put("counter", 10)
    let res = map.atomicUpdate("counter", proc(v: int): int = v * 2)
    check res == some(20)
    check map.get("counter") == some(20)
    check map.len == 1

  test "Ctrie upsert semantics":
    let map = newCtrie[string, int]()
    # Absent key: inserts insertVal
    let v1 = map.upsert("counter", 100, proc(old: int): int = old + 1)
    check v1 == 100
    check map.get("counter") == some(100)
    check map.len == 1

    # Present key: updates via updateProc
    let v2 = map.upsert("counter", 500, proc(old: int): int = old + 50)
    check v2 == 150
    check map.get("counter") == some(150)
    check map.len == 1

  test "SkipListMap upsert semantics":
    var map = newSkipListMap[string, int]()
    # Absent key: inserts insertVal
    let v1 = map.upsert("counter", 100, proc(old: int): int = old + 1)
    check v1 == 100
    check map.get("counter") == some(100)
    check map.len == 1

    # Present key: updates via updateProc
    let v2 = map.upsert("counter", 500, proc(old: int): int = old + 50)
    check v2 == 150
    check map.get("counter") == some(150)
    check map.len == 1

  test "Ctrie and SkipListMap snapshot materialized views":
    let c = newCtrie[int, string]()
    var s = newSkipListMap[int, string]()
    for i in [30, 10, 20]:
      discard c.put(i, "val_" & $i)
      discard s.put(i, "val_" & $i)

    # SkipListMap snapshot should be in strictly sorted key order
    let sPairs = s.snapshotPairs()
    let sKeys = s.snapshotKeys()
    let sVals = s.snapshotValues()
    check sPairs == @[(10, "val_10"), (20, "val_20"), (30, "val_30")]
    check sKeys == @[10, 20, 30]
    check sVals == @["val_10", "val_20", "val_30"]

    # Ctrie snapshot pairs/keys/values
    let cPairs = c.snapshotPairs()
    let cKeys = c.snapshotKeys()
    let cVals = c.snapshotValues()
    check cPairs.len == 3
    check cKeys.len == 3
    check cVals.len == 3
    var sortedCKeys = cKeys
    sortedCKeys.sort()
    check sortedCKeys == @[10, 20, 30]

  test "ARC/ORC Ref Object payload safety in atomicUpdate and upsert":
    let map = newCtrie[int, PayloadRef]()
    discard map.upsert(1, PayloadRef(count: 1, tag: "initial"), proc(old: PayloadRef): PayloadRef =
      PayloadRef(count: old.count + 1, tag: "updated")
    )
    check map.get(1).get.count == 1
    check map.get(1).get.tag == "initial"

    discard map.upsert(1, PayloadRef(count: 99, tag: "fail"), proc(old: PayloadRef): PayloadRef =
      PayloadRef(count: old.count + 1, tag: "second")
    )
    check map.get(1).get.count == 2
    check map.get(1).get.tag == "second"

    var sMap = newSkipListMap[int, PayloadRef]()
    discard sMap.upsert(1, PayloadRef(count: 1, tag: "initial"), proc(old: PayloadRef): PayloadRef =
      PayloadRef(count: old.count + 1, tag: "updated")
    )
    check sMap.get(1).get.count == 1
    check sMap.get(1).get.tag == "initial"

    discard sMap.atomicUpdate(1, proc(old: PayloadRef): PayloadRef =
      PayloadRef(count: old.count + 10, tag: "atomic")
    )
    check sMap.get(1).get.count == 11
    check sMap.get(1).get.tag == "atomic"

suite "Wave 5A: Multi-Threaded Concurrency & Lost Update Stress":
  type
    CounterContextCtrie = object
      map: ptr Ctrie[string, int, 64]
      increments: int

    CounterContextSkipList = object
      map: ptr SkipListMap[string, int, 64, 16]
      increments: int

  proc ctrieCounterWorker(ctx: ptr CounterContextCtrie) {.thread.} =
    for _ in 0 ..< ctx.increments:
      discard ctx.map[].atomicUpdate("shared_key", proc(oldVal: int): int = oldVal + 1)

  proc skipListCounterWorker(ctx: ptr CounterContextSkipList) {.thread.} =
    for _ in 0 ..< ctx.increments:
      discard ctx.map[].atomicUpdate("shared_key", proc(oldVal: int): int = oldVal + 1)

  test "Ctrie atomicUpdate 8 threads concurrent counter (zero lost updates)":
    var map = newCtrie[string, int, 64]()
    discard map.put("shared_key", 0)

    const NumThreads = 8
    const IncrementsPerThread = 5000
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
    let actual = map.get("shared_key").get
    check actual == expected

  test "SkipListMap atomicUpdate 8 threads concurrent counter (zero lost updates)":
    var map = newSkipListMap[string, int, 64, 16]()
    discard map.put("shared_key", 0)

    const NumThreads = 8
    const IncrementsPerThread = 5000
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
    let actual = map.get("shared_key").get
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
    const ItemsPerThread = 2000
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
    const ItemsPerThread = 2000
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
      for _ in 0 ..< 100:
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
    for round in 0 ..< 2000:
      let k = round mod 50
      discard map.atomicUpdate(k, proc(v: int): int = v + 1)

    joinThread(readerThread)
    check rCtx.snapshotsTaken == 100
