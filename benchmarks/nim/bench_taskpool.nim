## Benchmarks for Work-Stealing TaskPool: parallelFor, forkJoin, and spawn+sync.
##
## Evaluates across 1t, 2t, 4t, 8t workers:
##   1. `taskpool_parfor`: Chunked parallel loop throughput (`parallelFor`).
##   2. `taskpool_forkjoin`: Recursive divide-and-conquer task tree (`forkJoin`).
##   3. `taskpool_spawnsync`: High-churn task submission and barrier drain (`spawn` + `sync`).
##
## Lifecycle Isolation (CRIT-B03):
##   - `initTaskPool(numWorkers)` and `pool.shutdown(wait = true)` are executed
##     outside the timed `getMonoTime()` window so only scheduler dispatch,
##     work-stealing, and barrier completion are measured.
##   - Every run invokes `pool.shutdown(wait = true)` cleanly before returning.
##
## Compares:
##   - `taskpool`: lockfree work-stealing `TaskPool` (ChaseLevDeque + TreiberStack)
##   - `locked_task_queue`: Mutex-guarded shared task queue + worker pool baseline
##   - Optional Rust FFI (`-d:adapter_rust_ffi_available` or `-d:adapter_rayon_available`):
##     `rayon_pool` (`rayon::ThreadPool`).

import std/[locks, monotimes, os, parseopt, strformat, times]
import ./bench_common
import lockfree/taskpool
import lockfree/atomics

const
  BenchTaskPoolRuns* {.intdefine.} = 3
  BenchTaskPoolWarmup* {.intdefine.} = 1
  BenchParForCount* {.intdefine.} = 500_000
  BenchForkJoinDepth* {.intdefine.} = 13 # 2^14 - 1 = 16,383 tasks
  BenchSpawnSyncCount* {.intdefine.} = 25_000

when defined(adapter_rust_ffi_available) or defined(adapter_rayon_available):
  import ./adapters/crossbeam_link
  proc rayon_pool_init(numThreads: csize_t): pointer {.importc, cdecl.}
  proc rayon_pool_parfor(pool: pointer, count: csize_t, outSum: ptr uint64): bool {.importc, cdecl.}
  proc rayon_pool_forkjoin(pool: pointer, depth: csize_t, outSum: ptr uint64): bool {.importc, cdecl.}
  proc rayon_pool_destroy(pool: pointer) {.importc, cdecl.}

proc mix64(x: uint64): uint64 {.inline.} =
  var z = x + 0x9e3779b97f4a7c15'u64
  z = (z xor (z shr 30)) * 0xbf58476d1ce4e5b9'u64
  z = (z xor (z shr 27)) * 0x94d049bb133111eb'u64
  result = z xor (z shr 31)

# -----------------------------------------------------------------------------
# Mutex-Guarded Task Queue Baseline
# -----------------------------------------------------------------------------
type
  LockedWorkItem = object
    isForkJoin: bool
    first: int
    last: int
    depth: int
    seed: uint64
    outPtr: ptr Atomic[uint64]
    pending: ptr Atomic[int64]

  LockedPoolCore = object
    lock: Lock
    cond: Cond
    queue: seq[LockedWorkItem]
    head: int
    stop: bool
    numWorkers: int
    threads: seq[Thread[ptr LockedPoolCore]]

proc submitLockedItem(core: ptr LockedPoolCore, item: LockedWorkItem) {.inline.} =
  acquire(core.lock)
  core.queue.add(item)
  signal(core.cond)
  release(core.lock)

proc lockedExecuteForkJoin(
    core: ptr LockedPoolCore,
    depth: int,
    seed: uint64,
    outPtr: ptr Atomic[uint64],
    pending: ptr Atomic[int64]
) {.gcsafe.} =
  var curDepth = depth
  var curSeed = seed
  while curDepth > 0:
    submitLockedItem(core, LockedWorkItem(
      isForkJoin: true,
      depth: curDepth - 1,
      seed: curSeed * 2'u64 + 2'u64,
      outPtr: outPtr,
      pending: pending
    ))
    curDepth -= 1
    curSeed = curSeed * 2'u64 + 1'u64
  var acc = curSeed
  for k in 0 ..< 16:
    acc = mix64(acc + uint64(k))
  if outPtr != nil:
    discard outPtr[].fetchAdd(acc, moRelaxed)
  if pending != nil:
    discard pending[].fetchSub(1'i64, moRelease)

proc lockedWorkerMain(core: ptr LockedPoolCore) {.thread.} =
  while true:
    var item: LockedWorkItem
    var hasItem = false
    acquire(core.lock)
    while core.head >= core.queue.len and not core.stop:
      wait(core.cond, core.lock)
    if core.head < core.queue.len:
      item = core.queue[core.head]
      inc core.head
      if core.head >= core.queue.len:
        core.queue.setLen(0)
        core.head = 0
      hasItem = true
    elif core.stop:
      release(core.lock)
      break
    release(core.lock)

    if hasItem:
      if item.isForkJoin:
        lockedExecuteForkJoin(core, item.depth, item.seed, item.outPtr, item.pending)
      else:
        var localAcc = 0'u64
        for i in item.first .. item.last:
          localAcc += mix64(uint64(i))
          if (i and 63) == 63 or i == item.last:
            if item.outPtr != nil:
              discard item.outPtr[].fetchAdd(localAcc, moRelaxed)
            localAcc = 0'u64
        if item.pending != nil:
          discard item.pending[].fetchSub(1'i64, moRelease)

proc initLockedPool(numWorkers: int): ptr LockedPoolCore =
  result = cast[ptr LockedPoolCore](allocShared0(sizeof(LockedPoolCore)))
  initLock(result.lock)
  initCond(result.cond)
  result.queue = newSeqOfCap[LockedWorkItem](1024)
  result.head = 0
  result.stop = false
  result.numWorkers = numWorkers
  result.threads = newSeq[Thread[ptr LockedPoolCore]](numWorkers)
  for i in 0 ..< numWorkers:
    createThread(result.threads[i], lockedWorkerMain, result)

proc shutdownLockedPool(core: ptr LockedPoolCore) =
  if core == nil: return
  acquire(core.lock)
  core.stop = true
  broadcast(core.cond)
  release(core.lock)
  for i in 0 ..< core.numWorkers:
    joinThread(core.threads[i])
  deinitCond(core.cond)
  deinitLock(core.lock)
  `=destroy`(core.queue)
  `=destroy`(core.threads)
  deallocShared(core)

# -----------------------------------------------------------------------------
# 1. parallelFor Workload
# -----------------------------------------------------------------------------
const ParForChunkSize = 256
var parForThreadAcc {.threadvar.}: uint64

proc runTaskPoolParForTrial(pool: var TaskPool, count: int): float =
  var sinkAcc = Atomic[uint64]()
  sinkAcc.store(0'u64, moRelaxed)
  let sinkPtr = addr sinkAcc

  let t0 = getMonoTime()
  pool.parallelFor(0, count - 1, proc(i: int) {.closure, gcsafe.} =
    let acc = parForThreadAcc + mix64(uint64(i))
    if (i and 63) == 63 or i + 1 == count:
      discard sinkPtr[].fetchAdd(acc, moRelaxed)
      parForThreadAcc = 0'u64
    else:
      parForThreadAcc = acc
  , chunkSize = ParForChunkSize)
  let elapsedNs = float(inNanoseconds(getMonoTime() - t0))
  if elapsedNs <= 0.0: return 0.0
  result = float(count) * 1_000_000.0 / elapsedNs

proc runLockedParForTrial(core: ptr LockedPoolCore, count: int): float =
  var sinkAcc = Atomic[uint64]()
  var pending = Atomic[int64]()
  sinkAcc.store(0'u64, moRelaxed)

  let effChunk = ParForChunkSize
  let numChunks = (count + effChunk - 1) div effChunk
  pending.store(int64(numChunks), moRelaxed)

  let t0 = getMonoTime()
  for c in 0 ..< numChunks:
    let cStart = c * effChunk
    let cEnd = min(count - 1, cStart + effChunk - 1)
    submitLockedItem(core, LockedWorkItem(
      isForkJoin: false,
      first: cStart,
      last: cEnd,
      outPtr: addr sinkAcc,
      pending: addr pending
    ))
  while pending.load(moAcquire) > 0:
    benchBackoffOnPeerWait()
  let elapsedNs = float(inNanoseconds(getMonoTime() - t0))
  if elapsedNs <= 0.0: return 0.0
  result = float(count) * 1_000_000.0 / elapsedNs

when defined(adapter_rust_ffi_available) or defined(adapter_rayon_available):
  proc runRayonParForTrial(rPool: pointer, count: int): float =
    if rPool == nil: return 0.0
    var outSum = 0'u64
    let t0 = getMonoTime()
    discard rayon_pool_parfor(rPool, csize_t(count), addr outSum)
    let elapsedNs = float(inNanoseconds(getMonoTime() - t0))
    if elapsedNs <= 0.0: return 0.0
    result = float(count) * 1_000_000.0 / elapsedNs

# -----------------------------------------------------------------------------
# 2. forkJoin Recursive Divide-and-Conquer Workload
# -----------------------------------------------------------------------------
proc forkJoinTree(pool: TaskPool, depth: int, seed: uint64, sinkPtr: ptr Atomic[uint64]) {.gcsafe.} =
  if depth <= 0:
    var acc = seed
    for k in 0 ..< 16:
      acc = mix64(acc + uint64(k))
    discard sinkPtr[].fetchAdd(acc, moRelaxed)
    return
  pool.forkJoin(
    proc() {.closure, gcsafe.} =
      forkJoinTree(pool, depth - 1, seed * 2'u64 + 1'u64, sinkPtr),
    proc() {.closure, gcsafe.} =
      forkJoinTree(pool, depth - 1, seed * 2'u64 + 2'u64, sinkPtr)
  )

proc runTaskPoolForkJoinTrial(pool: var TaskPool, depth: int): float =
  var sinkAcc = Atomic[uint64]()
  sinkAcc.store(0'u64, moRelaxed)
  let totalNodes = (1 shl (depth + 1)) - 1

  let t0 = getMonoTime()
  forkJoinTree(pool, depth, 1'u64, addr sinkAcc)
  let elapsedNs = float(inNanoseconds(getMonoTime() - t0))
  if elapsedNs <= 0.0: return 0.0
  result = float(totalNodes) * 1_000_000.0 / elapsedNs

proc runLockedForkJoinTrial(core: ptr LockedPoolCore, depth: int): float =
  var sinkAcc = Atomic[uint64]()
  var pending = Atomic[int64]()
  sinkAcc.store(0'u64, moRelaxed)
  let totalNodes = (1 shl (depth + 1)) - 1
  let numLeaves = 1 shl max(0, depth)
  pending.store(int64(numLeaves), moRelaxed)

  let t0 = getMonoTime()
  submitLockedItem(core, LockedWorkItem(
    isForkJoin: true,
    depth: depth,
    seed: 1'u64,
    outPtr: addr sinkAcc,
    pending: addr pending
  ))
  while pending.load(moAcquire) > 0:
    benchBackoffOnPeerWait()
  let elapsedNs = float(inNanoseconds(getMonoTime() - t0))
  if elapsedNs <= 0.0: return 0.0
  result = float(totalNodes) * 1_000_000.0 / elapsedNs

when defined(adapter_rust_ffi_available) or defined(adapter_rayon_available):
  proc runRayonForkJoinTrial(rPool: pointer, depth: int): float =
    if rPool == nil: return 0.0
    let totalNodes = (1 shl (depth + 1)) - 1
    var outSum = 0'u64
    let t0 = getMonoTime()
    discard rayon_pool_forkjoin(rPool, csize_t(depth), addr outSum)
    let elapsedNs = float(inNanoseconds(getMonoTime() - t0))
    if elapsedNs <= 0.0: return 0.0
    result = float(totalNodes) * 1_000_000.0 / elapsedNs

# -----------------------------------------------------------------------------
# 3. spawn + sync High-Churn Task Submission Workload
# -----------------------------------------------------------------------------
proc spawnNimcallTask(arg: pointer) {.nimcall, gcsafe.} =
  let p = cast[ptr Atomic[uint64]](arg)
  var acc = 0x9E3779B97F4A7C15'u64
  for k in 0 ..< 8:
    acc = mix64(acc + uint64(k))
  discard p[].fetchAdd(acc, moRelaxed)

proc runTaskPoolSpawnSyncTrial(pool: var TaskPool, taskCount: int): float =
  var counter = Atomic[uint64]()
  counter.store(0'u64, moRelaxed)

  let t0 = getMonoTime()
  for _ in 0 ..< taskCount:
    pool.spawn(spawnNimcallTask, cast[pointer](addr counter))
  pool.sync()
  let elapsedNs = float(inNanoseconds(getMonoTime() - t0))
  if elapsedNs <= 0.0: return 0.0
  result = float(taskCount) * 1_000_000.0 / elapsedNs

proc runLockedSpawnSyncTrial(core: ptr LockedPoolCore, taskCount: int): float =
  var sinkAcc = Atomic[uint64]()
  var pending = Atomic[int64]()
  sinkAcc.store(0'u64, moRelaxed)
  pending.store(int64(taskCount), moRelaxed)

  let t0 = getMonoTime()
  for i in 0 ..< taskCount:
    submitLockedItem(core, LockedWorkItem(
      isForkJoin: false,
      first: i,
      last: i + 7,
      outPtr: addr sinkAcc,
      pending: addr pending
    ))
  while pending.load(moAcquire) > 0:
    benchBackoffOnPeerWait()
  let elapsedNs = float(inNanoseconds(getMonoTime() - t0))
  if elapsedNs <= 0.0: return 0.0
  result = float(taskCount) * 1_000_000.0 / elapsedNs

proc recordSeries(
    emitter: var BMFEmitter,
    slug: string,
    samples: openArray[float]
) =
  let m = mean(samples)
  let s = stddev(samples)
  emitter.addMeasure(slug, "throughput_ops_ms", m, m - s, m + s)
  echo &"{slug}: mean = {m:10.1f} ops/ms, stddev = {s:8.1f}"

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

  var supported = @["taskpool", "locked_task_queue"]
  when defined(adapter_rust_ffi_available) or defined(adapter_rayon_available):
    supported.add("rayon_pool")
  if filters.len > 0:
    for f in filters:
      if f notin supported:
        echo &"Unknown target: {f} (supported: {supported})"
        quit 1

  echo "TaskPool Work-Stealing Scheduler Benchmark (parallelFor, forkJoin, spawn+sync)"
  echo "=============================================================================="

  var emitter = initBMFEmitter()
  let threadCounts = [1, 2, 4, 8]

  echo "\n--- 1. Parallel Loop Throughput (taskpool_parfor) ---"
  for nw in threadCounts:
    if matchesFilter("taskpool", filters):
      var pool = initTaskPool(nw)
      for _ in 0 ..< BenchTaskPoolWarmup:
        discard runTaskPoolParForTrial(pool, BenchParForCount)
      var tpSamples = newSeq[float](BenchTaskPoolRuns)
      for r in 0 ..< BenchTaskPoolRuns:
        tpSamples[r] = runTaskPoolParForTrial(pool, BenchParForCount)
      pool.shutdown(wait = true)
      recordSeries(emitter, &"taskpool/taskpool_parfor/{nw}t", tpSamples)

    if matchesFilter("locked_task_queue", filters):
      let core = initLockedPool(nw)
      for _ in 0 ..< BenchTaskPoolWarmup:
        discard runLockedParForTrial(core, BenchParForCount)
      var lqSamples = newSeq[float](BenchTaskPoolRuns)
      for r in 0 ..< BenchTaskPoolRuns:
        lqSamples[r] = runLockedParForTrial(core, BenchParForCount)
      shutdownLockedPool(core)
      recordSeries(emitter, &"locked_task_queue/taskpool_parfor/{nw}t", lqSamples)

    when defined(adapter_rust_ffi_available) or defined(adapter_rayon_available):
      if matchesFilter("rayon_pool", filters):
        let rPool = rayon_pool_init(csize_t(nw))
        for _ in 0 ..< BenchTaskPoolWarmup:
          discard runRayonParForTrial(rPool, BenchParForCount)
        var rySamples = newSeq[float](BenchTaskPoolRuns)
        for r in 0 ..< BenchTaskPoolRuns:
          rySamples[r] = runRayonParForTrial(rPool, BenchParForCount)
        rayon_pool_destroy(rPool)
        recordSeries(emitter, &"rayon_pool/taskpool_parfor/{nw}t", rySamples)

  echo "\n--- 2. Recursive Fork-Join Throughput (taskpool_forkjoin) ---"
  for nw in threadCounts:
    if matchesFilter("taskpool", filters):
      var pool = initTaskPool(nw)
      for _ in 0 ..< BenchTaskPoolWarmup:
        discard runTaskPoolForkJoinTrial(pool, BenchForkJoinDepth)
      var tpSamples = newSeq[float](BenchTaskPoolRuns)
      for r in 0 ..< BenchTaskPoolRuns:
        tpSamples[r] = runTaskPoolForkJoinTrial(pool, BenchForkJoinDepth)
      pool.shutdown(wait = true)
      recordSeries(emitter, &"taskpool/taskpool_forkjoin/{nw}t", tpSamples)

    if matchesFilter("locked_task_queue", filters):
      let core = initLockedPool(nw)
      for _ in 0 ..< BenchTaskPoolWarmup:
        discard runLockedForkJoinTrial(core, BenchForkJoinDepth)
      var lqSamples = newSeq[float](BenchTaskPoolRuns)
      for r in 0 ..< BenchTaskPoolRuns:
        lqSamples[r] = runLockedForkJoinTrial(core, BenchForkJoinDepth)
      shutdownLockedPool(core)
      recordSeries(emitter, &"locked_task_queue/taskpool_forkjoin/{nw}t", lqSamples)

    when defined(adapter_rust_ffi_available) or defined(adapter_rayon_available):
      if matchesFilter("rayon_pool", filters):
        let rPool = rayon_pool_init(csize_t(nw))
        for _ in 0 ..< BenchTaskPoolWarmup:
          discard runRayonForkJoinTrial(rPool, BenchForkJoinDepth)
        var rySamples = newSeq[float](BenchTaskPoolRuns)
        for r in 0 ..< BenchTaskPoolRuns:
          rySamples[r] = runRayonForkJoinTrial(rPool, BenchForkJoinDepth)
        rayon_pool_destroy(rPool)
        recordSeries(emitter, &"rayon_pool/taskpool_forkjoin/{nw}t", rySamples)

  echo "\n--- 3. High-Churn Task Spawn & Sync (taskpool_spawnsync) ---"
  for nw in threadCounts:
    if matchesFilter("taskpool", filters):
      var pool = initTaskPool(nw)
      for _ in 0 ..< BenchTaskPoolWarmup:
        discard runTaskPoolSpawnSyncTrial(pool, BenchSpawnSyncCount)
      var tpSamples = newSeq[float](BenchTaskPoolRuns)
      for r in 0 ..< BenchTaskPoolRuns:
        tpSamples[r] = runTaskPoolSpawnSyncTrial(pool, BenchSpawnSyncCount)
      pool.shutdown(wait = true)
      recordSeries(emitter, &"taskpool/taskpool_spawnsync/{nw}t", tpSamples)

    if matchesFilter("locked_task_queue", filters):
      let core = initLockedPool(nw)
      for _ in 0 ..< BenchTaskPoolWarmup:
        discard runLockedSpawnSyncTrial(core, BenchSpawnSyncCount)
      var lqSamples = newSeq[float](BenchTaskPoolRuns)
      for r in 0 ..< BenchTaskPoolRuns:
        lqSamples[r] = runLockedSpawnSyncTrial(core, BenchSpawnSyncCount)
      shutdownLockedPool(core)
      recordSeries(emitter, &"locked_task_queue/taskpool_spawnsync/{nw}t", lqSamples)

  if outputPath.len > 0:
    emitter.emit(outputPath)
    echo &"\nEmitted results to {outputPath}"

when isMainModule:
  main()
