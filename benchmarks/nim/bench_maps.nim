## Benchmarks for Concurrent Associative Maps & Sets: Ctrie vs SkipListMap vs Locked Table.
##
## Evaluates throughput under three canonical multi-threaded workloads:
##   - Read-Heavy: 90% lookup / 10% update
##   - Balanced: 50% lookup / 50% update
##   - Write-Heavy: 10% lookup / 90% update
##
## Concurrency topographies: 1, 2, 4, 8 threads.
## Emits BMF JSON format with `throughput_ops_ms`.

import std/[locks, monotimes, os, parseopt, random, strformat, tables, times]
import ./bench_common
import lockfree/ctrie
import lockfree/skiplist

const
  BenchMapRuns* {.intdefine.} = 3
  BenchMapWarmup* {.intdefine.} = 1
  BenchMapOpsPerThread* {.intdefine.} = 100_000
  InitialKeyCount = 50_000
  KeyUniverse = 100_000

type
  LockedTable = ref object
    lock: Lock
    data: tables.Table[int, int]

proc newLockedTable(): LockedTable =
  new(result)
  initLock(result.lock)
  result.data = tables.initTable[int, int]()

proc put(lt: LockedTable, k, v: int) {.inline.} =
  withLock(lt.lock):
    lt.data[k] = v

proc get(lt: LockedTable, k: int): (bool, int) {.inline.} =
  withLock(lt.lock):
    if k in lt.data:
      return (true, lt.data[k])
    return (false, 0)

type
  MapKind = enum
    mkCtrie
    mkSkipList
    mkLockedTable

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
    opsCount: int
    threadId: int

proc workerBody(ctxPtr: ptr ThreadWorkerCtx) {.thread.} =
  let ctx = ctxPtr[]
  var rng = initRand(1337 + ctx.threadId * 17)
  let readThreshold = case ctx.workload
    of wkReadHeavy: 90
    of wkBalanced: 50
    of wkWriteHeavy: 10

  for _ in 0 ..< ctx.opsCount:
    let r = rng.rand(99)
    let key = rng.rand(KeyUniverse - 1)
    if r < readThreshold:
      # Read
      case ctx.mapKind
      of mkCtrie:
        discard ctx.ctriePtr[].get(key)
      of mkSkipList:
        discard ctx.skipMapPtr[].get(key)
      of mkLockedTable:
        discard ctx.lockedTab.get(key)
    else:
      # Write
      let val = rng.rand(1_000_000)
      case ctx.mapKind
      of mkCtrie:
        discard ctx.ctriePtr[].put(key, val)
      of mkSkipList:
        discard ctx.skipMapPtr[].put(key, val)
      of mkLockedTable:
        ctx.lockedTab.put(key, val)

proc runOneBenchmark(
    mapKind: MapKind,
    workload: WorkloadKind,
    numThreads: int,
    opsPerThread: int
): float =
  var cMap: Ctrie[int, int]
  var sMap: SkipListMap[int, int]
  var lTab: LockedTable

  # Pre-populate
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

  var threads = newSeq[Thread[ptr ThreadWorkerCtx]](numThreads)
  var ctxs = newSeq[ThreadWorkerCtx](numThreads)

  for i in 0 ..< numThreads:
    ctxs[i] = ThreadWorkerCtx(
      mapKind: mapKind,
      workload: workload,
      ctriePtr: addr cMap,
      skipMapPtr: addr sMap,
      lockedTab: lTab,
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

  echo "Associative Maps & Sets Benchmark (Ctrie vs SkipList vs LockedTable)"
  echo "===================================================================="

  var emitter = initBMFEmitter()
  let threadConfigs = [1, 2, 4, 8]
  let workloads = [
    (wkReadHeavy, "read_heavy"),
    (wkBalanced, "balanced"),
    (wkWriteHeavy, "write_heavy")
  ]
  let targets = [
    (mkCtrie, "ctrie"),
    (mkSkipList, "skiplist"),
    (mkLockedTable, "locked_table")
  ]

  for (wKind, wSlug) in workloads:
    echo &"\n--- Workload: {wSlug} ---"
    for threads in threadConfigs:
      for (mKind, libName) in targets:
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

  if outputPath.len > 0:
    emitter.emit(outputPath)
    echo &"\nEmitted results to {outputPath}"

when isMainModule:
  main()
