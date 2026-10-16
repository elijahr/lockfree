## Benchmarks for Hendler-Incze-Shavit-Tzafrir `FlatCombiner[T, Op, Res]`:
##   1. Sequential Stack Contention (`flat_combiner_stack` across 1t, 2t, 4t, 8t):
##      - `flat_combiner` (Nim FlatCombiner[SeqStack, StackOp, int64] with contention-adaptive leasing)
##      - `mutex_locked` (Nim OS `std/locks.Lock` + sequential stack baseline)
##   2. Sequential Counter / Accumulator (`flat_combiner_counter` across 1t, 2t, 4t, 8t):
##      - `flat_combiner` (Nim FlatCombiner[int64, int64, int64])
##      - `mutex_locked` (Nim OS `std/locks.Lock` + int64 baseline)
##
## Emits BMF JSON format with `throughput_ops_ms`.

import std/[locks, monotimes, os, parseopt, strformat, times]
import ./bench_common
import lockfree/atomics
import lockfree/atomics/backoff
import lockfree/flat_combiner

const
  BenchFcRuns* {.intdefine.} = 3
  BenchFcWarmup* {.intdefine.} = 1
  BenchFcTotalOps* {.intdefine.} = 200_000

type
  FcStackOpKind = enum
    fsoPush
    fsoPop

  FcStackOp = object
    kind: FcStackOpKind
    val: int64

  FcSeqStack = object
    data: seq[int64]

proc applyFcStack(state: var FcSeqStack, op: FcStackOp): int64 {.gcsafe.} =
  case op.kind
  of fsoPush:
    state.data.add(op.val)
    int64(state.data.len)
  of fsoPop:
    if state.data.len > 0:
      state.data.pop()
    else:
      0'i64

proc applyFcCounter(state: var int64, delta: int64): int64 {.gcsafe.} =
  state += delta
  state

type
  LockedSeqStack = object
    lock: Lock
    data: seq[int64]

  LockedCounter = object
    lock: Lock
    val: int64

  BenchTargetKind = enum
    btkFlatCombiner
    btkMutexLocked

  StackBenchCtx = object
    kind: BenchTargetKind
    fc: FlatCombiner[FcSeqStack, FcStackOp, int64]
    locked: ptr LockedSeqStack
    opsPerThread: int
    startFlag: ptr Atomic[bool]
    sink: int64

proc stackBenchWorker(ctx: ptr StackBenchCtx) {.thread.} =
  while not ctx.startFlag[].load(moAcquire):
    cpuPause()
  var acc = 0'i64
  let n = ctx.opsPerThread
  case ctx.kind
  of btkFlatCombiner:
    for i in 0 ..< n:
      if (i and 1) == 0:
        acc += ctx.fc.combine(FcStackOp(kind: fsoPush, val: int64(i)))
      else:
        acc += ctx.fc.combine(FcStackOp(kind: fsoPop, val: 0))
  of btkMutexLocked:
    for i in 0 ..< n:
      acquire(ctx.locked.lock)
      if (i and 1) == 0:
        ctx.locked.data.add(int64(i))
        acc += int64(ctx.locked.data.len)
      else:
        if ctx.locked.data.len > 0:
          acc += ctx.locked.data.pop()
      release(ctx.locked.lock)
  ctx.sink = acc

type
  CounterBenchCtx = object
    kind: BenchTargetKind
    fc: FlatCombiner[int64, int64, int64]
    locked: ptr LockedCounter
    opsPerThread: int
    startFlag: ptr Atomic[bool]
    sink: int64

proc counterBenchWorker(ctx: ptr CounterBenchCtx) {.thread.} =
  while not ctx.startFlag[].load(moAcquire):
    cpuPause()
  var acc = 0'i64
  let n = ctx.opsPerThread
  case ctx.kind
  of btkFlatCombiner:
    for _ in 0 ..< n:
      acc += ctx.fc.combine(1'i64)
  of btkMutexLocked:
    for _ in 0 ..< n:
      acquire(ctx.locked.lock)
      ctx.locked.val += 1'i64
      acc += ctx.locked.val
      release(ctx.locked.lock)
  ctx.sink = acc

var gFcBenchSink*: int64

proc runStackBench(kind: BenchTargetKind, numThreads: int, totalOps: int): float =
  let opsPerThread = max(1, totalOps div numThreads)
  let actualOps = opsPerThread * numThreads

  var fc = initFlatCombiner[FcSeqStack, FcStackOp, int64](
    FcSeqStack(data: newSeqOfCap[int64](4096)),
    applyFcStack
  )
  var locked: LockedSeqStack
  initLock(locked.lock)
  locked.data = newSeqOfCap[int64](4096)
  defer:
    deinitLock(locked.lock)

  var startFlag: Atomic[bool]
  startFlag.store(false, moRelaxed)

  var threads = newSeq[Thread[ptr StackBenchCtx]](numThreads)
  var ctxs = newSeq[StackBenchCtx](numThreads)
  for i in 0 ..< numThreads:
    ctxs[i] = StackBenchCtx(
      kind: kind,
      fc: fc,
      locked: addr locked,
      opsPerThread: opsPerThread,
      startFlag: addr startFlag,
      sink: 0
    )
    createThread(threads[i], stackBenchWorker, addr ctxs[i])

  let t0 = getMonoTime()
  startFlag.store(true, moRelease)
  for i in 0 ..< numThreads:
    joinThread(threads[i])
  let elapsedNs = float(inNanoseconds(getMonoTime() - t0))

  for i in 0 ..< numThreads:
    gFcBenchSink = gFcBenchSink xor ctxs[i].sink

  if elapsedNs <= 0.0: return 0.0
  result = float(actualOps) * 1_000_000.0 / elapsedNs

proc runCounterBench(kind: BenchTargetKind, numThreads: int, totalOps: int): float =
  let opsPerThread = max(1, totalOps div numThreads)
  let actualOps = opsPerThread * numThreads

  var fc = initFlatCombiner[int64, int64, int64](0'i64, applyFcCounter)
  var locked: LockedCounter
  initLock(locked.lock)
  defer:
    deinitLock(locked.lock)

  var startFlag: Atomic[bool]
  startFlag.store(false, moRelaxed)

  var threads = newSeq[Thread[ptr CounterBenchCtx]](numThreads)
  var ctxs = newSeq[CounterBenchCtx](numThreads)
  for i in 0 ..< numThreads:
    ctxs[i] = CounterBenchCtx(
      kind: kind,
      fc: fc,
      locked: addr locked,
      opsPerThread: opsPerThread,
      startFlag: addr startFlag,
      sink: 0
    )
    createThread(threads[i], counterBenchWorker, addr ctxs[i])

  let t0 = getMonoTime()
  startFlag.store(true, moRelease)
  for i in 0 ..< numThreads:
    joinThread(threads[i])
  let elapsedNs = float(inNanoseconds(getMonoTime() - t0))

  for i in 0 ..< numThreads:
    gFcBenchSink = gFcBenchSink xor ctxs[i].sink

  if elapsedNs <= 0.0: return 0.0
  result = float(actualOps) * 1_000_000.0 / elapsedNs

proc matchesFilter(libSlug: string, filters: seq[string]): bool {.inline.} =
  filters.len == 0 or libSlug in filters

proc main*() =
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

  let targets = @[
    (btkFlatCombiner, "flat_combiner"),
    (btkMutexLocked, "mutex_locked")
  ]

  if filters.len > 0:
    var supported: seq[string] = @[]
    for (_, slug) in targets: supported.add(slug)
    for f in filters:
      if f notin supported:
        echo &"Unknown target: {f} (supported: {supported})"
        quit 1

  echo "Flat Combiner Benchmark (Hendler-Incze-Shavit-Tzafrir vs Mutex)"
  echo "==============================================================="

  var emitter = initBMFEmitter()
  let threadCounts = [(1, "1t"), (2, "2t"), (4, "4t"), (8, "8t")]

  echo "\n--- 1. Sequential Stack Combining (Push/Pop 50:50) ---"
  for (nt, shape) in threadCounts:
    for (kind, libSlug) in targets:
      if not matchesFilter(libSlug, filters): continue
      for _ in 0 ..< BenchFcWarmup:
        discard runStackBench(kind, nt, BenchFcTotalOps)
      var samples = newSeq[float](BenchFcRuns)
      for r in 0 ..< BenchFcRuns:
        samples[r] = runStackBench(kind, nt, BenchFcTotalOps)
      let m = mean(samples)
      let s = stddev(samples)
      let slug = &"{libSlug}/flat_combiner_stack/{shape}"
      emitter.addMeasure(slug, "throughput_ops_ms", m, m - s, m + s)
      echo &"{slug}: mean = {m:10.1f} ops/ms, stddev = {s:8.1f}"

  echo "\n--- 2. Sequential Accumulator Combining ---"
  for (nt, shape) in threadCounts:
    for (kind, libSlug) in targets:
      if not matchesFilter(libSlug, filters): continue
      for _ in 0 ..< BenchFcWarmup:
        discard runCounterBench(kind, nt, BenchFcTotalOps)
      var samples = newSeq[float](BenchFcRuns)
      for r in 0 ..< BenchFcRuns:
        samples[r] = runCounterBench(kind, nt, BenchFcTotalOps)
      let m = mean(samples)
      let s = stddev(samples)
      let slug = &"{libSlug}/flat_combiner_counter/{shape}"
      emitter.addMeasure(slug, "throughput_ops_ms", m, m - s, m + s)
      echo &"{slug}: mean = {m:10.1f} ops/ms, stddev = {s:8.1f}"

  if outputPath.len > 0:
    emitter.emit(outputPath)
    echo &"\nEmitted results to {outputPath}"

when isMainModule:
  main()
