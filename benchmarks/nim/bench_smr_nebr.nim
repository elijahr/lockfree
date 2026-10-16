## Benchmarks for NEBR Safe Memory Reclamation (DebraManager):
##   1. `smr_pin_unpin`: Critical-section pin/unpin guard overhead & read scaling
##      across 1t, 2t, 4t, 8t (`nebr` vs `arc_atomic_rc` vs `mutex_guard`, plus
##      optional Rust `crossbeam_epoch`).
##   2. `smr_retire_reclaim`: Node allocation, epoch retirement, reclamation
##      throughput, and stalled-thread neutralization tail latency across
##      1t, 2t, 4t, 8t (`nebr` vs `deferred_mutex_free`).
##
## Memory-Safety & Unregister Contract (CRIT-B02):
##   Every registered worker thread exits all `withEpoch` / `pinScope` guards,
##   synchronizes on an unpinned barrier so no peer holds a stale pinned epoch,
##   and drains `limboBagTail` and `currentBag` to `nil` via `manager.advance()`
##   + `reclaimNow(handle)` BEFORE invoking `unregisterThread(manager, handle)`.

import std/[locks, monotimes, os, parseopt, strformat, times]
import ./bench_common
import lockfree/smr/nebr
import lockfree/atomics

const
  BenchSmrRuns* {.intdefine.} = 3
  BenchSmrWarmup* {.intdefine.} = 1
  BenchPinOpsPerThread* {.intdefine.} = 250_000
  BenchRetireOpsPerThread* {.intdefine.} = 50_000

when defined(adapter_rust_ffi_available) or defined(adapter_crossbeam_epoch_available):
  import ./adapters/crossbeam_link
  proc cbe_pin_unpin_batch(iters: csize_t): uint64 {.importc, cdecl.}
  proc cbe_retire_reclaim_batch(iters: csize_t): uint64 {.importc, cdecl.}

type
  DummyNode = object
    val: uint64
    pad: array[56, byte]

proc freeDummyNode(p: pointer) {.nimcall.} =
  if p != nil:
    deallocShared(p)

# -----------------------------------------------------------------------------
# 1. Critical-Section Pin/Unpin Benchmark (`smr_pin_unpin`)
# -----------------------------------------------------------------------------
type
  PinGuardKind = enum
    pgNebr
    pgAtomicRc
    pgMutex
    pgCrossbeamEpoch

  PinWorkerCtx = object
    kind: PinGuardKind
    manager: ptr DebraManager[16, ccSingle]
    sharedPtr: ptr Atomic[ptr DummyNode]
    sharedRc: ptr Atomic[int64]
    sharedLock: ptr Lock
    opsCount: int
    threadId: int
    checksum: uint64

proc pinWorkerBody(ctx: ptr PinWorkerCtx) {.thread.} =
  var localSum = 0'u64
  case ctx.kind
  of pgNebr:
    let handle = ctx.manager[].registerThread()
    for i in 0 ..< ctx.opsCount:
      withEpoch(handle):
        let p = ctx.sharedPtr[].load(moAcquire)
        if p != nil:
          localSum = localSum xor p.val
      discard handle.advanceEvery(64)
    # CRIT-B02: Ensure unpinned and limbo drained before unregisterThread
    {.cast(gcsafe).}:
      while ctx.manager.threads[handle.idx].limboBagTail != nil or
            ctx.manager.threads[handle.idx].currentBag != nil:
        ctx.manager[].advance()
        discard reclaimNow(handle)
    ctx.manager[].unregisterThread(handle)
  of pgAtomicRc:
    for _ in 0 ..< ctx.opsCount:
      discard ctx.sharedRc[].fetchAdd(1'i64, moAcquire)
      let p = ctx.sharedPtr[].load(moAcquire)
      if p != nil:
        localSum = localSum xor p.val
      discard ctx.sharedRc[].fetchSub(1'i64, moRelease)
  of pgMutex:
    for _ in 0 ..< ctx.opsCount:
      acquire(ctx.sharedLock[])
      let p = ctx.sharedPtr[].load(moRelaxed)
      if p != nil:
        localSum = localSum xor p.val
      release(ctx.sharedLock[])
  else:
    when defined(adapter_rust_ffi_available) or defined(adapter_crossbeam_epoch_available):
      if ctx.kind == pgCrossbeamEpoch:
        localSum = cbe_pin_unpin_batch(csize_t(ctx.opsCount))
  ctx.checksum = localSum

proc runPinUnpinBenchmark(kind: PinGuardKind, numThreads: int, opsPerThread: int): float =
  var manager = initDebraManager[16]()
  setGlobalManager(addr manager)

  let rootNode = cast[ptr DummyNode](allocShared0(sizeof(DummyNode)))
  rootNode.val = 0xCAFEBABE_DEADBEEF'u64

  var sharedPtr = Atomic[ptr DummyNode]()
  sharedPtr.store(rootNode, moRelease)
  var sharedRc = Atomic[int64]()
  sharedRc.store(1'i64, moRelaxed)
  var sharedLock: Lock
  initLock(sharedLock)

  var threads = newSeq[Thread[ptr PinWorkerCtx]](numThreads)
  var ctxs = newSeq[PinWorkerCtx](numThreads)

  for i in 0 ..< numThreads:
    ctxs[i] = PinWorkerCtx(
      kind: kind,
      manager: addr manager,
      sharedPtr: addr sharedPtr,
      sharedRc: addr sharedRc,
      sharedLock: addr sharedLock,
      opsCount: opsPerThread,
      threadId: i,
      checksum: 0
    )

  let t0 = getMonoTime()
  for i in 0 ..< numThreads:
    createThread(threads[i], pinWorkerBody, addr ctxs[i])
  for i in 0 ..< numThreads:
    joinThread(threads[i])
  let elapsedNs = float(inNanoseconds(getMonoTime() - t0))

  deinitLock(sharedLock)
  deallocShared(rootNode)

  let totalOps = numThreads * opsPerThread
  if elapsedNs <= 0.0: return 0.0
  result = float(totalOps) * 1_000_000.0 / elapsedNs

proc measureSingleThreadPinLatency(kind: PinGuardKind, sampleCount: int = 20_000): LatencyMetrics =
  var manager = initDebraManager[16]()
  setGlobalManager(addr manager)
  let rootNode = cast[ptr DummyNode](allocShared0(sizeof(DummyNode)))
  rootNode.val = 42'u64
  var sharedPtr = Atomic[ptr DummyNode]()
  sharedPtr.store(rootNode, moRelease)
  var sharedRc = Atomic[int64]()
  sharedRc.store(1'i64, moRelaxed)
  var sharedLock: Lock
  initLock(sharedLock)

  var hist = initHistogram()
  const Batch = 16
  let batches = max(1, sampleCount div Batch)

  case kind
  of pgNebr:
    let handle = manager.registerThread()
    for _ in 0 ..< batches:
      let t0 = getMonoTime()
      for _ in 0 ..< Batch:
        withEpoch(handle):
          let p = sharedPtr.load(moAcquire)
          if p == nil: discard
        discard handle.advanceEvery(64)
      let perOpNs = float(inNanoseconds(getMonoTime() - t0)) / float(Batch)
      if perOpNs > 0.0: hist.record(perOpNs)
    while manager.threads[handle.idx].limboBagTail != nil or
          manager.threads[handle.idx].currentBag != nil:
      manager.advance()
      discard reclaimNow(handle)
    manager.unregisterThread(handle)
  of pgAtomicRc:
    for _ in 0 ..< batches:
      let t0 = getMonoTime()
      for _ in 0 ..< Batch:
        discard sharedRc.fetchAdd(1'i64, moAcquire)
        let p = sharedPtr.load(moAcquire)
        if p == nil: discard
        discard sharedRc.fetchSub(1'i64, moRelease)
      let perOpNs = float(inNanoseconds(getMonoTime() - t0)) / float(Batch)
      if perOpNs > 0.0: hist.record(perOpNs)
  of pgMutex:
    for _ in 0 ..< batches:
      let t0 = getMonoTime()
      for _ in 0 ..< Batch:
        acquire(sharedLock)
        let p = sharedPtr.load(moRelaxed)
        if p == nil: discard
        release(sharedLock)
      let perOpNs = float(inNanoseconds(getMonoTime() - t0)) / float(Batch)
      if perOpNs > 0.0: hist.record(perOpNs)
  else:
    when defined(adapter_rust_ffi_available) or defined(adapter_crossbeam_epoch_available):
      if kind == pgCrossbeamEpoch:
        for _ in 0 ..< batches:
          let t0 = getMonoTime()
          discard cbe_pin_unpin_batch(csize_t(Batch))
          let perOpNs = float(inNanoseconds(getMonoTime() - t0)) / float(Batch)
          if perOpNs > 0.0: hist.record(perOpNs)

  deinitLock(sharedLock)
  deallocShared(rootNode)

  let pcts = hist.percentiles([0.50, 0.95, 0.99, 0.999, 1.0])
  result = LatencyMetrics(
    p50_ns: pcts[0],
    p95_ns: pcts[1],
    p99_ns: pcts[2],
    p999_ns: pcts[3],
    max_ns: pcts[4],
    samples: hist.seenAll
  )

# -----------------------------------------------------------------------------
# 2. Retire/Reclaim & Stalled-Thread Neutralization (`smr_retire_reclaim`)
# -----------------------------------------------------------------------------
type
  RetireKind = enum
    rkNebr
    rkDeferredMutex
    rkCrossbeamEpoch

  RetiredMutexEntry = object
    ptrNode: pointer
    retireEpoch: uint64

  DeferredMutexPool = object
    lock: Lock
    globalEpoch: uint64
    activeMask: uint32
    threadEpochs: array[16, uint64]
    retired: seq[RetiredMutexEntry]

  RetireWorkerCtx = object
    kind: RetireKind
    manager: ptr DebraManager[16, ccSingle]
    mutexPool: ptr DeferredMutexPool
    activeWorkers: ptr Atomic[int]
    opsCount: int
    threadId: int

proc reclaimSafeMutexEntries(pool: var DeferredMutexPool) {.inline.} =
  var minActiveEpoch = high(uint64)
  if pool.activeMask != 0'u32:
    for tid in 0 ..< 16:
      if (pool.activeMask and (1'u32 shl uint32(tid))) != 0'u32:
        if pool.threadEpochs[tid] < minActiveEpoch:
          minActiveEpoch = pool.threadEpochs[tid]
  var writeIdx = 0
  for readIdx in 0 ..< pool.retired.len:
    let entry = pool.retired[readIdx]
    if entry.retireEpoch <= minActiveEpoch:
      deallocShared(entry.ptrNode)
    else:
      pool.retired[writeIdx] = entry
      inc writeIdx
  pool.retired.setLen(writeIdx)

proc retireWorkerBody(ctx: ptr RetireWorkerCtx) {.thread.} =
  case ctx.kind
  of rkNebr:
    {.cast(gcsafe).}:
      let handle = ctx.manager[].registerThread()
      for i in 0 ..< ctx.opsCount:
        let node = cast[ptr DummyNode](allocShared0(sizeof(DummyNode)))
        node.val = uint64(i)
        withEpoch(handle, ready):
          ready.retire(node, freeDummyNode)
        if handle.advanceEvery(32):
          discard reclaimNow(handle)
          if (i and 1023) == 0:
            discard ctx.manager[].neutralizeStalled(epochsBeforeNeutralize = 2)

      # CRIT-B02: Unpinned barrier — wait until all peers exit critical sections
      discard ctx.activeWorkers[].fetchSub(1, moAcquireRelease)
      while ctx.activeWorkers[].load(moAcquire) > 0:
        ctx.manager[].advance()
        discard reclaimNow(handle)
        benchBackoffOnPeerWait()

      # Drain both limboBagTail and currentBag to nil before unregisterThread
      var safetySpins = 0
      while ctx.manager.threads[handle.idx].limboBagTail != nil or
            ctx.manager.threads[handle.idx].currentBag != nil:
        ctx.manager[].advance()
        discard reclaimNow(handle)
        inc safetySpins
        if safetySpins > 16:
          discard ctx.manager[].neutralizeStalled(epochsBeforeNeutralize = 1)
      ctx.manager[].unregisterThread(handle)

  of rkDeferredMutex:
    let tBit = 1'u32 shl uint32(ctx.threadId and 15)
    acquire(ctx.mutexPool.lock)
    ctx.mutexPool.activeMask = ctx.mutexPool.activeMask or tBit
    ctx.mutexPool.threadEpochs[ctx.threadId and 15] = ctx.mutexPool.globalEpoch
    release(ctx.mutexPool.lock)

    var localBatch: array[32, pointer]
    var bLen = 0
    for i in 0 ..< ctx.opsCount:
      let node = cast[ptr DummyNode](allocShared0(sizeof(DummyNode)))
      node.val = uint64(i)
      localBatch[bLen] = node
      inc bLen
      if bLen == 32:
        acquire(ctx.mutexPool.lock)
        inc ctx.mutexPool.globalEpoch
        let curEpoch = ctx.mutexPool.globalEpoch
        ctx.mutexPool.threadEpochs[ctx.threadId and 15] = curEpoch
        for k in 0 ..< bLen:
          ctx.mutexPool.retired.add(RetiredMutexEntry(
            ptrNode: localBatch[k],
            retireEpoch: curEpoch
          ))
        reclaimSafeMutexEntries(ctx.mutexPool[])
        release(ctx.mutexPool.lock)
        bLen = 0

    acquire(ctx.mutexPool.lock)
    inc ctx.mutexPool.globalEpoch
    let finalEpoch = ctx.mutexPool.globalEpoch
    for k in 0 ..< bLen:
      ctx.mutexPool.retired.add(RetiredMutexEntry(
        ptrNode: localBatch[k],
        retireEpoch: finalEpoch
      ))
    ctx.mutexPool.activeMask = ctx.mutexPool.activeMask and (not tBit)
    reclaimSafeMutexEntries(ctx.mutexPool[])
    release(ctx.mutexPool.lock)
  else:
    when defined(adapter_rust_ffi_available) or defined(adapter_crossbeam_epoch_available):
      if ctx.kind == rkCrossbeamEpoch:
        discard cbe_retire_reclaim_batch(csize_t(ctx.opsCount))

proc runRetireReclaimBenchmark(kind: RetireKind, numThreads: int, opsPerThread: int): float =
  var manager = initDebraManager[16]()
  setGlobalManager(addr manager)

  var mutexPool = DeferredMutexPool(
    globalEpoch: 1'u64,
    activeMask: 0'u32,
    retired: newSeqOfCap[RetiredMutexEntry](256)
  )
  initLock(mutexPool.lock)

  var activeWorkers = Atomic[int]()
  activeWorkers.store(numThreads, moRelaxed)

  var threads = newSeq[Thread[ptr RetireWorkerCtx]](numThreads)
  var ctxs = newSeq[RetireWorkerCtx](numThreads)

  for i in 0 ..< numThreads:
    ctxs[i] = RetireWorkerCtx(
      kind: kind,
      manager: addr manager,
      mutexPool: addr mutexPool,
      activeWorkers: addr activeWorkers,
      opsCount: opsPerThread,
      threadId: i
    )

  let t0 = getMonoTime()
  for i in 0 ..< numThreads:
    createThread(threads[i], retireWorkerBody, addr ctxs[i])
  for i in 0 ..< numThreads:
    joinThread(threads[i])
  let elapsedNs = float(inNanoseconds(getMonoTime() - t0))

  while mutexPool.retired.len > 0:
    deallocShared(mutexPool.retired.pop().ptrNode)
  deinitLock(mutexPool.lock)

  let totalOps = numThreads * opsPerThread
  if elapsedNs <= 0.0: return 0.0
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

  var pinTargets = @[
    (pgNebr, "nebr"),
    (pgAtomicRc, "arc_atomic_rc"),
    (pgMutex, "mutex_guard")
  ]
  when defined(adapter_rust_ffi_available) or defined(adapter_crossbeam_epoch_available):
    pinTargets.add((pgCrossbeamEpoch, "crossbeam_epoch"))

  var retireTargets = @[
    (rkNebr, "nebr"),
    (rkDeferredMutex, "deferred_mutex_free")
  ]
  when defined(adapter_rust_ffi_available) or defined(adapter_crossbeam_epoch_available):
    retireTargets.add((rkCrossbeamEpoch, "crossbeam_epoch"))

  if filters.len > 0:
    var supported: seq[string] = @[]
    for (_, slug) in pinTargets:
      if slug notin supported: supported.add(slug)
    for (_, slug) in retireTargets:
      if slug notin supported: supported.add(slug)
    for f in filters:
      if f notin supported:
        echo &"Unknown target: {f} (supported: {supported})"
        quit 1

  echo "NEBR Safe Memory Reclamation Benchmark (Pin/Unpin & Retire/Reclaim)"
  echo "==================================================================="

  var emitter = initBMFEmitter()
  let threadCounts = [1, 2, 4, 8]

  echo "\n--- 1. Critical-Section Pin/Unpin Throughput (smr_pin_unpin) ---"
  for (kind, libSlug) in pinTargets:
    if not matchesFilter(libSlug, filters): continue
    for nw in threadCounts:
      for _ in 0 ..< BenchSmrWarmup:
        discard runPinUnpinBenchmark(kind, nw, BenchPinOpsPerThread)
      var samples = newSeq[float](BenchSmrRuns)
      for r in 0 ..< BenchSmrRuns:
        samples[r] = runPinUnpinBenchmark(kind, nw, BenchPinOpsPerThread)
      let m = mean(samples)
      let s = stddev(samples)
      let slug = &"{libSlug}/smr_pin_unpin/{nw}t"
      emitter.addMeasure(slug, "throughput_ops_ms", m, m - s, m + s)
      if nw == 1:
        let lat = measureSingleThreadPinLatency(kind)
        emitter.addMeasure(slug, "latency_p50_ns", lat.p50_ns)
        emitter.addMeasure(slug, "latency_p95_ns", lat.p95_ns)
        emitter.addMeasure(slug, "latency_p99_ns", lat.p99_ns)
        emitter.addMeasure(slug, "latency_p999_ns", lat.p999_ns)
        emitter.addMeasure(slug, "latency_max_ns", lat.max_ns)
      echo &"{slug}: mean = {m:10.1f} ops/ms, stddev = {s:8.1f}"

  echo "\n--- 2. Retire/Reclaim & Neutralization Throughput (smr_retire_reclaim) ---"
  for (kind, libSlug) in retireTargets:
    if not matchesFilter(libSlug, filters): continue
    for nw in threadCounts:
      for _ in 0 ..< BenchSmrWarmup:
        discard runRetireReclaimBenchmark(kind, nw, BenchRetireOpsPerThread)
      var samples = newSeq[float](BenchSmrRuns)
      for r in 0 ..< BenchSmrRuns:
        samples[r] = runRetireReclaimBenchmark(kind, nw, BenchRetireOpsPerThread)
      let m = mean(samples)
      let s = stddev(samples)
      let slug = &"{libSlug}/smr_retire_reclaim/{nw}t"
      emitter.addMeasure(slug, "throughput_ops_ms", m, m - s, m + s)
      echo &"{slug}: mean = {m:10.1f} ops/ms, stddev = {s:8.1f}"

  if outputPath.len > 0:
    emitter.emit(outputPath)
    echo &"\nEmitted results to {outputPath}"

when isMainModule:
  main()
