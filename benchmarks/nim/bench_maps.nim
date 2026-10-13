## Benchmarks for Concurrent Associative Maps & Sets:
##   - Maps: Ctrie, SkipListMap, LockedTable, DashMap (Rust), Flurry (Rust),
##           crossbeam::SkipMap (Rust), boost::concurrent_flat_map (C++)
##   - Sets: SkipListSet (Set[int]), LockedSet, crossbeam::SkipSet (Rust),
##           boost::concurrent_flat_set (C++)
##
## Evaluates throughput under canonical multi-threaded workloads:
##   - Read-Heavy (`read_heavy`): 90% lookup / 10% update
##   - Balanced (`balanced`): 50% lookup / 50% update
##   - Write-Heavy (`write_heavy`): 10% lookup / 90% update
##   - Set Mixed (`set_mixed`): 80% contains / 10% insert / 10% remove
##   - Set Algebra (`set_algebra`): concurrent intersect, union, difference
##   - Snapshot Iteration (`snapshot_iter`): Ctrie O(1) wait-free snapshot
##     iteration vs DashMap shard-locked iteration vs LockedTable under contention
##
## Concurrency topographies: 1, 2, 4, 8 threads.
## Emits BMF JSON format with `throughput_ops_ms` (and `latency_p99_ns` for snapshot_iter).

import std/[locks, monotimes, options, os, parseopt, random, sets, strformat, tables, times]
import ./bench_common
import lockfree/atomics
import lockfree/ctrie
import lockfree/skiplist
import lockfree/set as lfset

const
  BenchMapRuns* {.intdefine.} = 3
  BenchMapWarmup* {.intdefine.} = 1
  BenchMapOpsPerThread* {.intdefine.} = 100_000
  InitialKeyCount = 50_000
  KeyUniverse = 100_000
  SnapshotKeyCount = 4_000
  AlgebraSetSize = 1_000

when defined(adapter_rust_ffi_available):
  import ./adapters/crossbeam_link
  proc dm_init(): pointer {.importc, cdecl.}
  proc dm_get(m: pointer, key: uint64, outVal: ptr uint64): bool {.importc, cdecl.}
  proc dm_put(m: pointer, key: uint64, val: uint64): bool {.importc, cdecl.}
  proc dm_iter_sum(m: pointer): uint64 {.importc, cdecl.}
  proc dm_destroy(m: pointer) {.importc, cdecl.}

  proc flurry_init(): pointer {.importc, cdecl.}
  proc flurry_get(m: pointer, key: uint64, outVal: ptr uint64): bool {.importc, cdecl.}
  proc flurry_put(m: pointer, key: uint64, val: uint64): bool {.importc, cdecl.}
  proc flurry_destroy(m: pointer) {.importc, cdecl.}

  proc cb_skipmap_init(): pointer {.importc, cdecl.}
  proc cb_skipmap_get(m: pointer, key: uint64, outVal: ptr uint64): bool {.importc, cdecl.}
  proc cb_skipmap_put(m: pointer, key: uint64, val: uint64): bool {.importc, cdecl.}
  proc cb_skipmap_destroy(m: pointer) {.importc, cdecl.}

  proc cb_skipset_init(): pointer {.importc, cdecl.}
  proc cb_skipset_contains(s: pointer, key: uint64): bool {.importc, cdecl.}
  proc cb_skipset_insert(s: pointer, key: uint64): bool {.importc, cdecl.}
  proc cb_skipset_remove(s: pointer, key: uint64): bool {.importc, cdecl.}
  proc cb_skipset_destroy(s: pointer) {.importc, cdecl.}

when defined(adapter_boost_lockfree_available) and defined(cpp):
  {.passC: "-std=c++17".}
  when defined(macosx) or defined(macos):
    {.passC: "-I/opt/homebrew/opt/boost/include".}
    {.passC: "-I/usr/local/include".}
  else:
    {.passC: "-I/usr/include".}
    {.passC: "-I/usr/local/include".}

  {.emit: """/*INCLUDESECTION*/
#include <boost/unordered/concurrent_flat_map.hpp>
#include <boost/unordered/concurrent_flat_set.hpp>
#include <cstdint>

extern "C" {
  static inline void* bench_boost_cmap_init() {
    auto* m = new boost::concurrent_flat_map<uint64_t, uint64_t>();
    m->reserve(65536);
    return static_cast<void*>(m);
  }
  static inline bool bench_boost_cmap_get(void* p, uint64_t k, uint64_t* out) {
    auto* m = static_cast<boost::concurrent_flat_map<uint64_t, uint64_t>*>(p);
    bool found = false;
    m->cvisit(k, [&](const auto& kv) {
      *out = kv.second;
      found = true;
    });
    return found;
  }
  static inline void bench_boost_cmap_put(void* p, uint64_t k, uint64_t v) {
    auto* m = static_cast<boost::concurrent_flat_map<uint64_t, uint64_t>*>(p);
    m->insert_or_assign(k, v);
  }
  static inline void bench_boost_cmap_destroy(void* p) {
    delete static_cast<boost::concurrent_flat_map<uint64_t, uint64_t>*>(p);
  }

  static inline void* bench_boost_cset_init() {
    auto* s = new boost::concurrent_flat_set<uint64_t>();
    s->reserve(65536);
    return static_cast<void*>(s);
  }
  static inline bool bench_boost_cset_contains(void* p, uint64_t k) {
    auto* s = static_cast<boost::concurrent_flat_set<uint64_t>*>(p);
    return s->contains(k);
  }
  static inline bool bench_boost_cset_insert(void* p, uint64_t k) {
    auto* s = static_cast<boost::concurrent_flat_set<uint64_t>*>(p);
    return s->insert(k);
  }
  static inline bool bench_boost_cset_remove(void* p, uint64_t k) {
    auto* s = static_cast<boost::concurrent_flat_set<uint64_t>*>(p);
    return s->erase(k) > 0;
  }
  static inline void bench_boost_cset_destroy(void* p) {
    delete static_cast<boost::concurrent_flat_set<uint64_t>*>(p);
  }
}
""".}

  proc bench_boost_cmap_init(): pointer {.importc, cdecl, nodecl.}
  proc bench_boost_cmap_get(p: pointer, k: uint64, outVal: ptr uint64): bool {.importc, cdecl, nodecl.}
  proc bench_boost_cmap_put(p: pointer, k: uint64, v: uint64) {.importc, cdecl, nodecl.}
  proc bench_boost_cmap_destroy(p: pointer) {.importc, cdecl, nodecl.}

  proc bench_boost_cset_init(): pointer {.importc, cdecl, nodecl.}
  proc bench_boost_cset_contains(p: pointer, k: uint64): bool {.importc, cdecl, nodecl.}
  proc bench_boost_cset_insert(p: pointer, k: uint64): bool {.importc, cdecl, nodecl.}
  proc bench_boost_cset_remove(p: pointer, k: uint64): bool {.importc, cdecl, nodecl.}
  proc bench_boost_cset_destroy(p: pointer) {.importc, cdecl, nodecl.}

# ---------------------------------------------------------------------------
# Locked Baselines (Map & Set)
# ---------------------------------------------------------------------------

type
  LockedTable = ref object
    lock: Lock
    data: tables.Table[int, int]

  LockedSet = ref object
    lock: Lock
    data: HashSet[int]

proc newLockedTable(): LockedTable =
  new(result)
  initLock(result.lock)
  result.data = tables.initTable[int, int](65536)

proc destroyLockedTable(lt: LockedTable) =
  if lt != nil:
    deinitLock(lt.lock)

proc put(lt: LockedTable, k, v: int) {.inline.} =
  withLock(lt.lock):
    lt.data[k] = v

proc get(lt: LockedTable, k: int): (bool, int) {.inline.} =
  withLock(lt.lock):
    if k in lt.data:
      return (true, lt.data[k])
    return (false, 0)

proc iterSum(lt: LockedTable): uint64 {.inline.} =
  withLock(lt.lock):
    for _, v in lt.data.pairs:
      result += uint64(v)

proc newLockedSet(): LockedSet =
  new(result)
  initLock(result.lock)
  result.data = initHashSet[int](65536)

proc destroyLockedSet(ls: LockedSet) =
  if ls != nil:
    deinitLock(ls.lock)

proc contains(ls: LockedSet, k: int): bool {.inline.} =
  withLock(ls.lock):
    result = k in ls.data

proc insert(ls: LockedSet, k: int): bool {.inline.} =
  withLock(ls.lock):
    result = not ls.data.containsOrIncl(k)

proc remove(ls: LockedSet, k: int): bool {.inline.} =
  withLock(ls.lock):
    if k in ls.data:
      ls.data.excl(k)
      return true
    return false

# ---------------------------------------------------------------------------
# 1. Concurrent Map Workloads (read_heavy, balanced, write_heavy)
# ---------------------------------------------------------------------------

type
  MapKind = enum
    mkCtrie
    mkSkipList
    mkLockedTable
    mkDashMap
    mkFlurry
    mkCrossbeamSkipMap
    mkBoostFlatMap

  WorkloadKind = enum
    wkReadHeavy   # 90% get, 10% put
    wkBalanced    # 50% get, 50% put
    wkWriteHeavy  # 10% get, 90% put

  ThreadWorkerCtx = object
    mapKind: MapKind
    workload: WorkloadKind
    ctriePtr: ptr Ctrie[int, int]
    skipMapPtr: ptr SkipListMap[int, int]
    lockedTab: LockedTable
    ffiPtr: pointer
    opsCount: int
    threadId: int
    checksum: uint64

proc workerBody(ctxPtr: ptr ThreadWorkerCtx) {.thread.} =
  let ctx = ctxPtr[]
  var rng = initRand(1337 + ctx.threadId * 17)
  let readThreshold = case ctx.workload
    of wkReadHeavy: 90
    of wkBalanced: 50
    of wkWriteHeavy: 10
  var localSum = 0'u64

  for _ in 0 ..< ctx.opsCount:
    let r = rng.rand(99)
    let key = rng.rand(KeyUniverse - 1)
    if r < readThreshold:
      case ctx.mapKind
      of mkCtrie:
        let res = ctx.ctriePtr[].get(key)
        if res.isSome:
          localSum += uint64(res.get)
      of mkSkipList:
        let res = ctx.skipMapPtr[].get(key)
        if res.isSome:
          localSum += uint64(res.get)
      of mkLockedTable:
        let (ok, v) = ctx.lockedTab.get(key)
        if ok:
          localSum += uint64(v)
      of mkDashMap:
        when defined(adapter_rust_ffi_available):
          var outVal = 0'u64
          if dm_get(ctx.ffiPtr, uint64(key), addr outVal):
            localSum += outVal
      of mkFlurry:
        when defined(adapter_rust_ffi_available):
          var outVal = 0'u64
          if flurry_get(ctx.ffiPtr, uint64(key), addr outVal):
            localSum += outVal
      of mkCrossbeamSkipMap:
        when defined(adapter_rust_ffi_available):
          var outVal = 0'u64
          if cb_skipmap_get(ctx.ffiPtr, uint64(key), addr outVal):
            localSum += outVal
      of mkBoostFlatMap:
        when defined(adapter_boost_lockfree_available) and defined(cpp):
          var outVal = 0'u64
          if bench_boost_cmap_get(ctx.ffiPtr, uint64(key), addr outVal):
            localSum += outVal
    else:
      let val = rng.rand(1_000_000)
      case ctx.mapKind
      of mkCtrie:
        discard ctx.ctriePtr[].put(key, val)
      of mkSkipList:
        discard ctx.skipMapPtr[].put(key, val)
      of mkLockedTable:
        ctx.lockedTab.put(key, val)
      of mkDashMap:
        when defined(adapter_rust_ffi_available):
          discard dm_put(ctx.ffiPtr, uint64(key), uint64(val))
      of mkFlurry:
        when defined(adapter_rust_ffi_available):
          discard flurry_put(ctx.ffiPtr, uint64(key), uint64(val))
      of mkCrossbeamSkipMap:
        when defined(adapter_rust_ffi_available):
          discard cb_skipmap_put(ctx.ffiPtr, uint64(key), uint64(val))
      of mkBoostFlatMap:
        when defined(adapter_boost_lockfree_available) and defined(cpp):
          bench_boost_cmap_put(ctx.ffiPtr, uint64(key), uint64(val))
  ctxPtr.checksum = localSum

proc runOneBenchmark(
    mapKind: MapKind,
    workload: WorkloadKind,
    numThreads: int,
    opsPerThread: int
): float =
  var cMap: Ctrie[int, int]
  var sMap: SkipListMap[int, int]
  var lTab: LockedTable
  var ffiPtr: pointer = nil

  # Pre-populate identically across all map implementations (HIGH-A04)
  case mapKind
  of mkCtrie:
    cMap = newCtrie[int, int]()
    for i in 0 ..< InitialKeyCount:
      discard cMap.put(i * 2, i * 2)
  of mkSkipList:
    sMap = newSkipListMap[int, int]()
    for i in 0 ..< InitialKeyCount:
      discard sMap.put(i * 2, i * 2)
  of mkLockedTable:
    lTab = newLockedTable()
    for i in 0 ..< InitialKeyCount:
      lTab.put(i * 2, i * 2)
  of mkDashMap:
    when defined(adapter_rust_ffi_available):
      ffiPtr = dm_init()
      for i in 0 ..< InitialKeyCount:
        discard dm_put(ffiPtr, uint64(i * 2), uint64(i * 2))
  of mkFlurry:
    when defined(adapter_rust_ffi_available):
      ffiPtr = flurry_init()
      for i in 0 ..< InitialKeyCount:
        discard flurry_put(ffiPtr, uint64(i * 2), uint64(i * 2))
  of mkCrossbeamSkipMap:
    when defined(adapter_rust_ffi_available):
      ffiPtr = cb_skipmap_init()
      for i in 0 ..< InitialKeyCount:
        discard cb_skipmap_put(ffiPtr, uint64(i * 2), uint64(i * 2))
  of mkBoostFlatMap:
    when defined(adapter_boost_lockfree_available) and defined(cpp):
      ffiPtr = bench_boost_cmap_init()
      for i in 0 ..< InitialKeyCount:
        bench_boost_cmap_put(ffiPtr, uint64(i * 2), uint64(i * 2))

  defer:
    case mapKind
    of mkLockedTable:
      destroyLockedTable(lTab)
    of mkDashMap:
      when defined(adapter_rust_ffi_available):
        dm_destroy(ffiPtr)
    of mkFlurry:
      when defined(adapter_rust_ffi_available):
        flurry_destroy(ffiPtr)
    of mkCrossbeamSkipMap:
      when defined(adapter_rust_ffi_available):
        cb_skipmap_destroy(ffiPtr)
    of mkBoostFlatMap:
      when defined(adapter_boost_lockfree_available) and defined(cpp):
        bench_boost_cmap_destroy(ffiPtr)
    else:
      discard

  var threads = newSeq[Thread[ptr ThreadWorkerCtx]](numThreads)
  var ctxs = newSeq[ThreadWorkerCtx](numThreads)

  for i in 0 ..< numThreads:
    ctxs[i] = ThreadWorkerCtx(
      mapKind: mapKind,
      workload: workload,
      ctriePtr: addr cMap,
      skipMapPtr: addr sMap,
      lockedTab: lTab,
      ffiPtr: ffiPtr,
      opsCount: opsPerThread,
      threadId: i
    )

  let t0 = getMonoTime()
  for i in 0 ..< numThreads:
    createThread(threads[i], workerBody, addr ctxs[i])
  for i in 0 ..< numThreads:
    joinThread(threads[i])
  let elapsedNs = float(inNanoseconds(getMonoTime() - t0))

  let totalOps = numThreads * opsPerThread
  if elapsedNs <= 0.0:
    return 0.0
  result = float(totalOps) * 1_000_000.0 / elapsedNs

proc runBenchSeries(
    emitter: var BMFEmitter,
    mapKind: MapKind,
    libName: string,
    workload: WorkloadKind,
    workloadSlug: string,
    numThreads: int,
    opsPerThread: int,
    runs: int,
    warmup: int
) =
  for _ in 0 ..< warmup:
    discard runOneBenchmark(mapKind, workload, numThreads, opsPerThread)

  var samples = newSeq[float](runs)
  for i in 0 ..< runs:
    samples[i] = runOneBenchmark(mapKind, workload, numThreads, opsPerThread)

  let m = mean(samples)
  let s = stddev(samples)
  let slug = &"{libName}/{workloadSlug}/{numThreads}t"
  emitter.addMeasure(slug, "throughput_ops_ms", m, m - s, m + s)
  echo &"{slug}: mean = {m:10.1f} ops/ms, stddev = {s:8.1f}"

# ---------------------------------------------------------------------------
# 2. Concurrent Set Workloads (set_mixed & set_algebra)
# ---------------------------------------------------------------------------

type
  SetKind = enum
    skSkipListSet
    skLockedSet
    skCrossbeamSkipSet
    skBoostFlatSet

  SetWorkerCtx = object
    setKind: SetKind
    skipSetPtr: ptr lfset.SkipListSet[int]
    lockedSet: LockedSet
    ffiPtr: pointer
    opsCount: int
    threadId: int
    checksum: uint64

proc setMixedWorkerBody(ctxPtr: ptr SetWorkerCtx) {.thread.} =
  let ctx = ctxPtr[]
  var rng = initRand(4242 + ctx.threadId * 29)
  var localHits = 0'u64

  for _ in 0 ..< ctx.opsCount:
    let r = rng.rand(99)
    let key = rng.rand(KeyUniverse - 1)
    if r < 80:
      # 80% contains
      case ctx.setKind
      of skSkipListSet:
        if ctx.skipSetPtr[].contains(key):
          inc localHits
      of skLockedSet:
        if ctx.lockedSet.contains(key):
          inc localHits
      of skCrossbeamSkipSet:
        when defined(adapter_rust_ffi_available):
          if cb_skipset_contains(ctx.ffiPtr, uint64(key)):
            inc localHits
      of skBoostFlatSet:
        when defined(adapter_boost_lockfree_available) and defined(cpp):
          if bench_boost_cset_contains(ctx.ffiPtr, uint64(key)):
            inc localHits
    elif r < 90:
      # 10% insert
      case ctx.setKind
      of skSkipListSet:
        if ctx.skipSetPtr[].insert(key):
          inc localHits
      of skLockedSet:
        if ctx.lockedSet.insert(key):
          inc localHits
      of skCrossbeamSkipSet:
        when defined(adapter_rust_ffi_available):
          if cb_skipset_insert(ctx.ffiPtr, uint64(key)):
            inc localHits
      of skBoostFlatSet:
        when defined(adapter_boost_lockfree_available) and defined(cpp):
          if bench_boost_cset_insert(ctx.ffiPtr, uint64(key)):
            inc localHits
    else:
      # 10% remove
      case ctx.setKind
      of skSkipListSet:
        if ctx.skipSetPtr[].remove(key):
          inc localHits
      of skLockedSet:
        if ctx.lockedSet.remove(key):
          inc localHits
      of skCrossbeamSkipSet:
        when defined(adapter_rust_ffi_available):
          if cb_skipset_remove(ctx.ffiPtr, uint64(key)):
            inc localHits
      of skBoostFlatSet:
        when defined(adapter_boost_lockfree_available) and defined(cpp):
          if bench_boost_cset_remove(ctx.ffiPtr, uint64(key)):
            inc localHits
  ctxPtr.checksum = localHits

proc runSetMixedBenchmark(setKind: SetKind, numThreads: int, opsPerThread: int): float =
  var sSet: lfset.SkipListSet[int]
  var lSet: LockedSet
  var ffiPtr: pointer = nil

  case setKind
  of skSkipListSet:
    sSet = lfset.newSkipListSet[int]()
    for i in 0 ..< InitialKeyCount:
      discard sSet.insert(i * 2)
  of skLockedSet:
    lSet = newLockedSet()
    for i in 0 ..< InitialKeyCount:
      discard lSet.insert(i * 2)
  of skCrossbeamSkipSet:
    when defined(adapter_rust_ffi_available):
      ffiPtr = cb_skipset_init()
      for i in 0 ..< InitialKeyCount:
        discard cb_skipset_insert(ffiPtr, uint64(i * 2))
  of skBoostFlatSet:
    when defined(adapter_boost_lockfree_available) and defined(cpp):
      ffiPtr = bench_boost_cset_init()
      for i in 0 ..< InitialKeyCount:
        discard bench_boost_cset_insert(ffiPtr, uint64(i * 2))

  defer:
    case setKind
    of skLockedSet:
      destroyLockedSet(lSet)
    of skCrossbeamSkipSet:
      when defined(adapter_rust_ffi_available):
        cb_skipset_destroy(ffiPtr)
    of skBoostFlatSet:
      when defined(adapter_boost_lockfree_available) and defined(cpp):
        bench_boost_cset_destroy(ffiPtr)
    else:
      discard

  var threads = newSeq[Thread[ptr SetWorkerCtx]](numThreads)
  var ctxs = newSeq[SetWorkerCtx](numThreads)
  for i in 0 ..< numThreads:
    ctxs[i] = SetWorkerCtx(
      setKind: setKind,
      skipSetPtr: addr sSet,
      lockedSet: lSet,
      ffiPtr: ffiPtr,
      opsCount: opsPerThread,
      threadId: i
    )

  let t0 = getMonoTime()
  for i in 0 ..< numThreads:
    createThread(threads[i], setMixedWorkerBody, addr ctxs[i])
  for i in 0 ..< numThreads:
    joinThread(threads[i])
  let elapsedNs = float(inNanoseconds(getMonoTime() - t0))

  if elapsedNs <= 0.0:
    return 0.0
  result = float(numThreads * opsPerThread) * 1_000_000.0 / elapsedNs

type
  SetAlgebraCtx = object
    setKind: SetKind
    skipA: ptr lfset.SkipListSet[int]
    skipB: ptr lfset.SkipListSet[int]
    lockedA: LockedSet
    lockedB: LockedSet
    iters: int
    threadId: int
    checksum: int

proc setAlgebraWorkerBody(ctxPtr: ptr SetAlgebraCtx) {.thread.} =
  let ctx = ctxPtr[]
  var localCount = 0
  for i in 0 ..< ctx.iters:
    case ctx.setKind
    of skSkipListSet:
      case i mod 3
      of 0:
        let res = lfset.intersect(ctx.skipA[], ctx.skipB[])
        localCount += res.len
      of 1:
        let res = lfset.union(ctx.skipA[], ctx.skipB[])
        localCount += res.len
      else:
        let res = lfset.difference(ctx.skipA[], ctx.skipB[])
        localCount += res.len
    of skLockedSet:
      withLock(ctx.lockedA.lock):
        withLock(ctx.lockedB.lock):
          case i mod 3
          of 0:
            let res = sets.intersection(ctx.lockedA.data, ctx.lockedB.data)
            localCount += res.len
          of 1:
            let res = sets.union(ctx.lockedA.data, ctx.lockedB.data)
            localCount += res.len
          else:
            let res = sets.difference(ctx.lockedA.data, ctx.lockedB.data)
            localCount += res.len
    else:
      discard
  ctxPtr.checksum = localCount

proc runSetAlgebraBenchmark(setKind: SetKind, numThreads: int, itersPerThread: int): float =
  var sA, sB: lfset.SkipListSet[int]
  var lA, lB: LockedSet

  if setKind == skSkipListSet:
    sA = lfset.newSkipListSet[int]()
    sB = lfset.newSkipListSet[int]()
    for i in 0 ..< AlgebraSetSize:
      discard sA.insert(i * 2)
      discard sB.insert(i * 3)
  else:
    lA = newLockedSet()
    lB = newLockedSet()
    for i in 0 ..< AlgebraSetSize:
      discard lA.insert(i * 2)
      discard lB.insert(i * 3)

  defer:
    if setKind == skLockedSet:
      destroyLockedSet(lA)
      destroyLockedSet(lB)

  var threads = newSeq[Thread[ptr SetAlgebraCtx]](numThreads)
  var ctxs = newSeq[SetAlgebraCtx](numThreads)
  for i in 0 ..< numThreads:
    ctxs[i] = SetAlgebraCtx(
      setKind: setKind,
      skipA: addr sA,
      skipB: addr sB,
      lockedA: lA,
      lockedB: lB,
      iters: itersPerThread,
      threadId: i
    )

  let t0 = getMonoTime()
  for i in 0 ..< numThreads:
    createThread(threads[i], setAlgebraWorkerBody, addr ctxs[i])
  for i in 0 ..< numThreads:
    joinThread(threads[i])
  let elapsedNs = float(inNanoseconds(getMonoTime() - t0))

  if elapsedNs <= 0.0:
    return 0.0
  # Each algebra operation processes AlgebraSetSize elements
  let totalElementOps = numThreads * itersPerThread * AlgebraSetSize
  result = float(totalElementOps) * 1_000_000.0 / elapsedNs

# ---------------------------------------------------------------------------
# 3. Ctrie O(1) Wait-Free Snapshot Iteration under Contention (snapshot_iter)
# ---------------------------------------------------------------------------

type
  SnapshotWorkerCtx = object
    mapKind: MapKind
    ctriePtr: ptr Ctrie[int, int]
    lockedTab: LockedTable
    ffiPtr: pointer
    isIterator: bool
    iters: int
    stopFlag: ptr Atomic[bool]
    threadId: int
    latenciesNs: seq[float]
    checksum: uint64

proc snapshotWorkerBody(ctxPtr: ptr SnapshotWorkerCtx) {.thread.} =
  if ctxPtr.isIterator:
    var sum = 0'u64
    ctxPtr.latenciesNs = newSeqOfCap[float](ctxPtr.iters)
    for _ in 0 ..< ctxPtr.iters:
      let tStart = getMonoTime()
      case ctxPtr.mapKind
      of mkCtrie:
        let snap = ctxPtr.ctriePtr[].snapshot()
        for _, v in snap.pairs:
          sum += uint64(v)
      of mkDashMap:
        when defined(adapter_rust_ffi_available):
          sum += dm_iter_sum(ctxPtr.ffiPtr)
      of mkLockedTable:
        sum += ctxPtr.lockedTab.iterSum()
      else:
        discard
      let dtNs = float(inNanoseconds(getMonoTime() - tStart))
      ctxPtr.latenciesNs.add(dtNs)
    ctxPtr.checksum = sum
  else:
    var rng = initRand(9001 + ctxPtr.threadId * 31)
    while not ctxPtr.stopFlag[].load(moAcquire):
      let k = rng.rand(SnapshotKeyCount - 1)
      let v = rng.rand(100_000)
      case ctxPtr.mapKind
      of mkCtrie:
        discard ctxPtr.ctriePtr[].put(k, v)
      of mkDashMap:
        when defined(adapter_rust_ffi_available):
          discard dm_put(ctxPtr.ffiPtr, uint64(k), uint64(v))
      of mkLockedTable:
        ctxPtr.lockedTab.put(k, v)
      else:
        discard

proc runSnapshotIterBenchmark(
    mapKind: MapKind,
    numThreads: int,
    snapIters: int
): (float, float) =
  var cMap: Ctrie[int, int]
  var lTab: LockedTable
  var ffiPtr: pointer = nil

  case mapKind
  of mkCtrie:
    cMap = newCtrie[int, int]()
    for i in 0 ..< SnapshotKeyCount:
      discard cMap.put(i, i)
  of mkDashMap:
    when defined(adapter_rust_ffi_available):
      ffiPtr = dm_init()
      for i in 0 ..< SnapshotKeyCount:
        discard dm_put(ffiPtr, uint64(i), uint64(i))
  of mkLockedTable:
    lTab = newLockedTable()
    for i in 0 ..< SnapshotKeyCount:
      lTab.put(i, i)
  else:
    discard

  defer:
    if mapKind == mkLockedTable:
      destroyLockedTable(lTab)
    elif mapKind == mkDashMap:
      when defined(adapter_rust_ffi_available):
        dm_destroy(ffiPtr)

  var stopFlag = Atomic[bool]()
  stopFlag.store(false, moRelaxed)

  let numReaders = max(1, numThreads div 2)
  var threads = newSeq[Thread[ptr SnapshotWorkerCtx]](numThreads)
  var ctxs = newSeq[SnapshotWorkerCtx](numThreads)

  for i in 0 ..< numThreads:
    ctxs[i] = SnapshotWorkerCtx(
      mapKind: mapKind,
      ctriePtr: addr cMap,
      lockedTab: lTab,
      ffiPtr: ffiPtr,
      isIterator: i < numReaders,
      iters: snapIters,
      stopFlag: addr stopFlag,
      threadId: i
    )

  let t0 = getMonoTime()
  for i in 0 ..< numThreads:
    createThread(threads[i], snapshotWorkerBody, addr ctxs[i])
  for i in 0 ..< numReaders:
    joinThread(threads[i])
  stopFlag.store(true, moRelease)
  for i in numReaders ..< numThreads:
    joinThread(threads[i])
  let elapsedNs = float(inNanoseconds(getMonoTime() - t0))

  var allLatencies: seq[float] = @[]
  for i in 0 ..< numReaders:
    allLatencies.add(ctxs[i].latenciesNs)

  let p99 = if allLatencies.len > 0: percentile(allLatencies, 0.99) else: 0.0
  let totalVisited = float(numReaders * snapIters * SnapshotKeyCount)
  let opsMs = if elapsedNs > 0.0: totalVisited * 1_000_000.0 / elapsedNs else: 0.0
  result = (opsMs, p99)

proc main() =
  var outputPath = ""
  var p = initOptParser(commandLineParams())
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdLongOption, cmdShortOption:
      if p.key in ["o", "output", "bmf-out"]:
        outputPath = p.val
    of cmdArgument: discard

  echo "Associative Maps & Sets Benchmark (Nim vs Rust vs C++)"
  echo "======================================================"

  var emitter = initBMFEmitter()
  let threadConfigs = [1, 2, 4, 8]
  let workloads = [
    (wkReadHeavy, "read_heavy"),
    (wkBalanced, "balanced"),
    (wkWriteHeavy, "write_heavy")
  ]

  var mapTargets = @[
    (mkCtrie, "ctrie"),
    (mkSkipList, "skiplist"),
    (mkLockedTable, "locked_table")
  ]
  when defined(adapter_rust_ffi_available):
    mapTargets.add((mkDashMap, "dashmap"))
    mapTargets.add((mkFlurry, "flurry"))
    mapTargets.add((mkCrossbeamSkipMap, "crossbeam_skipmap"))
  when defined(adapter_boost_lockfree_available) and defined(cpp):
    mapTargets.add((mkBoostFlatMap, "boost_concurrent_flat_map"))

  for (wKind, wSlug) in workloads:
    echo &"\n--- Workload: {wSlug} ---"
    for threads in threadConfigs:
      for (mKind, libName) in mapTargets:
        runBenchSeries(
          emitter,
          mKind,
          libName,
          wKind,
          wSlug,
          threads,
          BenchMapOpsPerThread,
          BenchMapRuns,
          BenchMapWarmup
        )

  # Set Mixed (80% contains / 10% insert / 10% remove)
  echo "\n--- Workload: set_mixed (80% Read / 20% Mutate) ---"
  var setTargets = @[
    (skSkipListSet, "skiplist_set"),
    (skLockedSet, "locked_set")
  ]
  when defined(adapter_rust_ffi_available):
    setTargets.add((skCrossbeamSkipSet, "crossbeam_skipset"))
  when defined(adapter_boost_lockfree_available) and defined(cpp):
    setTargets.add((skBoostFlatSet, "boost_concurrent_flat_set"))

  for threads in threadConfigs:
    for (sKind, libName) in setTargets:
      for _ in 0 ..< BenchMapWarmup:
        discard runSetMixedBenchmark(sKind, threads, BenchMapOpsPerThread)
      var samples = newSeq[float](BenchMapRuns)
      for r in 0 ..< BenchMapRuns:
        samples[r] = runSetMixedBenchmark(sKind, threads, BenchMapOpsPerThread)
      let m = mean(samples)
      let s = stddev(samples)
      let slug = &"{libName}/set_mixed/{threads}t"
      emitter.addMeasure(slug, "throughput_ops_ms", m, m - s, m + s)
      echo &"{slug}: mean = {m:10.1f} ops/ms, stddev = {s:8.1f}"

  # Set Algebra (intersect / union / difference)
  echo "\n--- Workload: set_algebra (Concurrent Intersect/Union/Difference) ---"
  let algebraIters = max(5, BenchMapOpsPerThread div 2000)
  for threads in threadConfigs:
    for (sKind, libName) in [(skSkipListSet, "skiplist_set"), (skLockedSet, "locked_set")]:
      for _ in 0 ..< BenchMapWarmup:
        discard runSetAlgebraBenchmark(sKind, threads, algebraIters)
      var samples = newSeq[float](BenchMapRuns)
      for r in 0 ..< BenchMapRuns:
        samples[r] = runSetAlgebraBenchmark(sKind, threads, algebraIters)
      let m = mean(samples)
      let s = stddev(samples)
      let slug = &"{libName}/set_algebra/{threads}t"
      emitter.addMeasure(slug, "throughput_ops_ms", m, m - s, m + s)
      echo &"{slug}: mean = {m:10.1f} ops/ms, stddev = {s:8.1f}"

  # Snapshot Iteration under Concurrent Writer Contention
  echo "\n--- Workload: snapshot_iter (O(1) Wait-Free Snapshot vs Shard/Global Lock) ---"
  let snapIters = max(10, BenchMapOpsPerThread div 1000)
  var snapTargets = @[
    (mkCtrie, "ctrie"),
    (mkLockedTable, "locked_table")
  ]
  when defined(adapter_rust_ffi_available):
    snapTargets.add((mkDashMap, "dashmap"))

  for threads in threadConfigs:
    for (mKind, libName) in snapTargets:
      for _ in 0 ..< BenchMapWarmup:
        discard runSnapshotIterBenchmark(mKind, threads, snapIters)
      var tSamples = newSeq[float](BenchMapRuns)
      var lSamples = newSeq[float](BenchMapRuns)
      for r in 0 ..< BenchMapRuns:
        let (opsMs, p99Ns) = runSnapshotIterBenchmark(mKind, threads, snapIters)
        tSamples[r] = opsMs
        lSamples[r] = p99Ns
      let tm = mean(tSamples)
      let ts = stddev(tSamples)
      let lm = mean(lSamples)
      let ls = stddev(lSamples)
      let slug = &"{libName}/snapshot_iter/{threads}t"
      emitter.addMeasure(slug, "throughput_ops_ms", tm, tm - ts, tm + ts)
      emitter.addMeasure(slug, "latency_p99_ns", lm, max(0.0, lm - ls), lm + ls)
      echo &"{slug}: mean = {tm:10.1f} ops/ms, p99 = {lm:10.1f} ns"

  if outputPath.len > 0:
    emitter.emit(outputPath)
    echo &"\nEmitted results to {outputPath}"

when isMainModule:
  main()
