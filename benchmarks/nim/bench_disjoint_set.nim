## Benchmarks for Concurrent Disjoint-Set (Union-Find / DSU):
##   1. Read Contention (`disjoint_set_find` across 1t, 2t, 4t, 8t, 16t):
##      - `disjoint_set` (Nim Lock-Free Concurrent DisjointSet with path splitting)
##      - `locked_disjoint_set` (Nim seq + Lock baseline)
##   2. Random Edge Stream Union/Connectivity (`disjoint_set_union` across 1t, 2t, 4t, 8t, 16t):
##      - `disjoint_set` (Nim Lock-Free Concurrent DisjointSet)
##      - `locked_disjoint_set` (Nim seq + Lock baseline)
##
## Emits BMF JSON format with `throughput_ops_ms`.

import std/[locks, monotimes, os, parseopt, strformat, times]
import ./bench_common
import lockfree/disjoint_set

const
  BenchDSRuns* {.intdefine.} = 3
  BenchDSWarmup* {.intdefine.} = 1
  BenchDSSize* = 100_000
  BenchDSOpsCount* {.intdefine.} = 500_000

# -----------------------------------------------------------------------------
# Locked Disjoint-Set Baseline
# -----------------------------------------------------------------------------
type
  LockedDisjointSet = ref object
    lock: Lock
    parent: seq[int]
    rank: seq[int]
    setCount: int

proc newLockedDisjointSet(size: int): LockedDisjointSet =
  new(result)
  initLock(result.lock)
  result.parent = newSeq[int](size)
  result.rank = newSeq[int](size)
  result.setCount = size
  for i in 0 ..< size:
    result.parent[i] = i
    result.rank[i] = 0

proc destroyLockedDisjointSet(ds: LockedDisjointSet) =
  if ds != nil:
    deinitLock(ds.lock)

proc find(ds: LockedDisjointSet, x: int): int =
  withLock(ds.lock):
    var root = x
    while root != ds.parent[root]:
      root = ds.parent[root]
    var cur = x
    while cur != root:
      let nxt = ds.parent[cur]
      ds.parent[cur] = root
      cur = nxt
    return root

proc union(ds: LockedDisjointSet, x, y: int): bool =
  withLock(ds.lock):
    var rx = x
    while rx != ds.parent[rx]: rx = ds.parent[rx]
    var ry = y
    while ry != ds.parent[ry]: ry = ds.parent[ry]
    if rx == ry: return false
    if ds.rank[rx] < ds.rank[ry]:
      ds.parent[rx] = ry
    elif ds.rank[rx] > ds.rank[ry]:
      ds.parent[ry] = rx
    else:
      ds.parent[ry] = rx
      inc ds.rank[rx]
    dec ds.setCount
    return true

proc sameSet(ds: LockedDisjointSet, x, y: int): bool =
  withLock(ds.lock):
    var rx = x
    while rx != ds.parent[rx]: rx = ds.parent[rx]
    var ry = y
    while ry != ds.parent[ry]: ry = ds.parent[ry]
    return rx == ry

# -----------------------------------------------------------------------------
# DisjointSet Benchmark Harness
# -----------------------------------------------------------------------------
type
  DSKind = enum
    dskLockFree
    dskLocked

  DSWorkerCtx = object
    kind: DSKind
    lfPtr: ptr DisjointSet
    lockedPtr: LockedDisjointSet
    opsCount: int
    threadId: int
    isFindBench: bool
    checksum: uint64

proc dsWorkerBody(ctxPtr: ptr DSWorkerCtx) {.thread.} =
  let ctx = ctxPtr[]
  let ops = ctx.opsCount
  var localChecksum = 0'u64
  # Pre-generate deterministic pseudo-random sequence for repeatability
  var rngState = uint64(ctx.threadId * 10007 + 1)
  template fastRand(): int =
    rngState = rngState * 6364136223846793005'u64 + 1'u64
    int((rngState shr 33) mod uint64(BenchDSSize))

  if ctx.isFindBench:
    for _ in 0 ..< ops:
      let x = fastRand()
      let root = if ctx.kind == dskLockFree:
        ctx.lfPtr[].find(x)
      else:
        ctx.lockedPtr.find(x)
      localChecksum = localChecksum xor uint64(root)
  else:
    # 70% sameSet queries, 30% union edge additions
    for _ in 0 ..< ops:
      let u = fastRand()
      let v = fastRand()
      let opType = (rngState shr 28) and 0x7'u64
      if opType < 5: # ~71% sameSet
        let same = if ctx.kind == dskLockFree:
          ctx.lfPtr[].sameSet(u, v)
        else:
          ctx.lockedPtr.sameSet(u, v)
        if same: localChecksum = localChecksum xor 1'u64
      else: # ~29% union
        let merged = if ctx.kind == dskLockFree:
          ctx.lfPtr[].union(u, v)
        else:
          ctx.lockedPtr.union(u, v)
        if merged: localChecksum = localChecksum xor 2'u64

  ctxPtr[].checksum = localChecksum

proc runDSBenchmark(
    kind: DSKind,
    numThreads: int,
    totalOps: int,
    isFind: bool
): float =
  var lfDS: DisjointSet
  var lockedDS: LockedDisjointSet

  case kind
  of dskLockFree:
    lfDS = initDisjointSet(BenchDSSize)
  of dskLocked:
    lockedDS = newLockedDisjointSet(BenchDSSize)

  # Pre-populate some components for find benchmark
  if isFind:
    for i in 0 ..< BenchDSSize div 2:
      let a = i * 2
      let b = a + 1
      if kind == dskLockFree:
        discard lfDS.union(a, b)
      else:
        discard lockedDS.union(a, b)

  defer:
    if kind == dskLockFree:
      lfDS.destroy()
    else:
      destroyLockedDisjointSet(lockedDS)

  var threads = newSeq[Thread[ptr DSWorkerCtx]](numThreads)
  var ctxs = newSeq[DSWorkerCtx](numThreads)

  let base = totalOps div numThreads
  let rem = totalOps mod numThreads

  for i in 0 ..< numThreads:
    ctxs[i] = DSWorkerCtx(
      kind: kind,
      lfPtr: addr lfDS,
      lockedPtr: lockedDS,
      opsCount: base + (if i < rem: 1 else: 0),
      threadId: i,
      isFindBench: isFind
    )

  let t0 = getMonoTime()
  for i in 0 ..< numThreads:
    createThread(threads[i], dsWorkerBody, addr ctxs[i])
  for i in 0 ..< numThreads:
    joinThread(threads[i])
  let elapsedNs = float(inNanoseconds(getMonoTime() - t0))

  if elapsedNs <= 0.0:
    return 0.0
  result = float(totalOps) * 1_000_000.0 / elapsedNs

proc matchesFilter(libSlug: string, filters: seq[string]): bool {.inline.} =
  filters.len == 0 or libSlug in filters

proc main() =
  var outputPath = ""
  var filters: seq[string] = @[]
  var p = initOptParser(commandLineParams())
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdLongOption, cmdShortOption:
      if p.key in ["o", "output", "bmf-out"]:
        outputPath = p.val
    of cmdArgument:
      filters.add(p.key)

  let dsTargets = [
    (dskLockFree, "disjoint_set"),
    (dskLocked, "locked_disjoint_set")
  ]

  if filters.len > 0:
    var supported: seq[string] = @[]
    for (_, slug) in dsTargets: supported.add(slug)
    for f in filters:
      if f notin supported:
        echo &"Unknown target: {f} (supported: {supported})"
        quit 1

  echo "Concurrent Disjoint-Set Benchmark (Lock-Free vs Locked)"
  echo "======================================================="

  var emitter = initBMFEmitter()
  let threadConfigs = [1, 2, 4, 8, 16]

  # 1. find Read Contention
  echo "\n--- DisjointSet find Contention ---"
  for (dKind, libSlug) in dsTargets:
    if not matchesFilter(libSlug, filters): continue
    for threads in threadConfigs:
      for _ in 0 ..< BenchDSWarmup:
        discard runDSBenchmark(dKind, threads, BenchDSOpsCount, isFind = true)
      var samples = newSeq[float](BenchDSRuns)
      for r in 0 ..< BenchDSRuns:
        samples[r] = runDSBenchmark(dKind, threads, BenchDSOpsCount, isFind = true)
      let m = mean(samples)
      let s = stddev(samples)
      let slug = &"{libSlug}/disjoint_set_find/{threads}t"
      emitter.addMeasure(slug, "throughput_ops_ms", m, m - s, m + s)
      echo &"{slug}: mean = {m:10.1f} ops/ms, stddev = {s:8.1f}"

  # 2. union & sameSet Contention
  echo "\n--- DisjointSet union & sameSet Graph Edge Stream ---"
  for (dKind, libSlug) in dsTargets:
    if not matchesFilter(libSlug, filters): continue
    for threads in threadConfigs:
      for _ in 0 ..< BenchDSWarmup:
        discard runDSBenchmark(dKind, threads, BenchDSOpsCount, isFind = false)
      var samples = newSeq[float](BenchDSRuns)
      for r in 0 ..< BenchDSRuns:
        samples[r] = runDSBenchmark(dKind, threads, BenchDSOpsCount, isFind = false)
      let m = mean(samples)
      let s = stddev(samples)
      let slug = &"{libSlug}/disjoint_set_union/{threads}t"
      emitter.addMeasure(slug, "throughput_ops_ms", m, m - s, m + s)
      echo &"{slug}: mean = {m:10.1f} ops/ms, stddev = {s:8.1f}"

  if outputPath.len > 0:
    emitter.emit(outputPath)
    echo &"\nEmitted results to {outputPath}"

when isMainModule:
  main()
