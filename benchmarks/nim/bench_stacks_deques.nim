## Benchmarks for Concurrent Stacks & Work-Stealing Deques:
##   1. MPMC Stacks (`stack_mpmc` across 1p1c, 2p2c, 4p4c, 8p8c):
##      - `treiber_stack` (Nim Lock-Free TreiberStack with elimination backoff)
##      - `boost_lockfree_stack` (C++ boost::lockfree::stack)
##      - `locked_stack` (Nim seq + Lock baseline)
##   2. Work-Stealing Deques (`work_stealing` across 1w1t, 1w2t, 1w4t, 1w8t):
##      - `chase_lev_deque` (Nim ChaseLevDeque single `steal()`)
##      - `chase_lev_deque_batch` (Nim ChaseLevDeque bulk `stealBatch(32)`)
##      - `crossbeam_deque` (Rust crossbeam-deque single `steal()`)
##      - `crossbeam_deque_batch` (Rust crossbeam-deque bulk `steal_batch_with_limit(32)`)
##
## Emits BMF JSON format with `throughput_ops_ms`.

import std/[locks, monotimes, options, os, parseopt, strformat, times]
import ./bench_common
import lockfree/stack
import lockfree/deque
import lockfree/atomics

const
  BenchStackRuns* {.intdefine.} = 3
  BenchStackWarmup* {.intdefine.} = 1
  BenchStackMsgCount* {.intdefine.} = 500_000
  StealBatchLimit = 32

when defined(adapter_rust_ffi_available):
  import ./adapters/crossbeam_link
  proc cb_deque_init(numThieves: csize_t): pointer {.importc, cdecl.}
  proc cb_deque_push(d: pointer, item: uint64) {.importc, cdecl.}
  proc cb_deque_pop(d: pointer, outVal: ptr uint64): bool {.importc, cdecl.}
  proc cb_deque_steal(d: pointer, outVal: ptr uint64): bool {.importc, cdecl.}
  proc cb_deque_steal_batch(d: pointer, thiefIdx: csize_t, maxBatch: csize_t): csize_t {.importc, cdecl.}
  proc cb_deque_is_empty(d: pointer): bool {.importc, cdecl.}
  proc cb_deque_destroy(d: pointer) {.importc, cdecl.}

when defined(adapter_boost_lockfree_available) and defined(cpp):
  when defined(macosx) or defined(macos):
    {.passC: "-I/opt/homebrew/opt/boost/include".}
    {.passC: "-I/usr/local/include".}
  else:
    {.passC: "-I/usr/include".}
    {.passC: "-I/usr/local/include".}

  {.emit: """/*INCLUDESECTION*/
#include <boost/lockfree/stack.hpp>
#include <cstdint>

extern "C" {
  static inline void* bench_boost_stack_init(size_t cap) {
    return static_cast<void*>(new boost::lockfree::stack<uint64_t>(cap));
  }
  static inline bool bench_boost_stack_push(void* p, uint64_t v) {
    return static_cast<boost::lockfree::stack<uint64_t>*>(p)->push(v);
  }
  static inline bool bench_boost_stack_pop(void* p, uint64_t* out) {
    return static_cast<boost::lockfree::stack<uint64_t>*>(p)->pop(*out);
  }
  static inline void bench_boost_stack_destroy(void* p) {
    delete static_cast<boost::lockfree::stack<uint64_t>*>(p);
  }
}
""".}

  proc bench_boost_stack_init(cap: csize_t): pointer {.importc, cdecl, nodecl.}
  proc bench_boost_stack_push(p: pointer, v: uint64): bool {.importc, cdecl, nodecl.}
  proc bench_boost_stack_pop(p: pointer, outVal: ptr uint64): bool {.importc, cdecl, nodecl.}
  proc bench_boost_stack_destroy(p: pointer) {.importc, cdecl, nodecl.}

# -----------------------------------------------------------------------------
# Locked Stack Baseline
# -----------------------------------------------------------------------------
type
  LockedStack[T] = ref object
    lock: Lock
    items: seq[T]

proc newLockedStack[T](): LockedStack[T] =
  new(result)
  initLock(result.lock)
  result.items = newSeqOfCap[T](1024)

proc destroyLockedStack[T](ls: LockedStack[T]) =
  if ls != nil:
    deinitLock(ls.lock)

proc push[T](ls: LockedStack[T], val: T) {.inline.} =
  withLock(ls.lock):
    ls.items.add(val)

proc pop[T](ls: LockedStack[T]): (bool, T) {.inline.} =
  withLock(ls.lock):
    if ls.items.len > 0:
      return (true, ls.items.pop())
    return (false, default(T))

# -----------------------------------------------------------------------------
# 1. MPMC Stack Benchmark Harness (TreiberStack vs Boost vs LockedStack)
# -----------------------------------------------------------------------------
type
  StackKind = enum
    skTreiber
    skBoost
    skLocked

  StackWorkerCtx = object
    stackKind: StackKind
    treiberPtr: ptr TreiberStack[int]
    boostPtr: pointer
    lockedPtr: LockedStack[int]
    isProducer: bool
    count: int
    threadId: int

proc stackWorkerBody(ctxPtr: ptr StackWorkerCtx) {.thread.} =
  let ctx = ctxPtr[]
  if ctx.isProducer:
    for i in 0 ..< ctx.count:
      case ctx.stackKind
      of skTreiber:
        ctx.treiberPtr[].push(i)
      of skBoost:
        when defined(adapter_boost_lockfree_available) and defined(cpp):
          while not bench_boost_stack_push(ctx.boostPtr, uint64(i)):
            benchBackoffOnPeerWait()
      of skLocked:
        ctx.lockedPtr.push(i)
  else:
    var consumed = 0
    while consumed < ctx.count:
      case ctx.stackKind
      of skTreiber:
        let val = ctx.treiberPtr[].pop()
        if val.isSome:
          inc consumed
        else:
          benchBackoffOnPeerWait()
      of skBoost:
        when defined(adapter_boost_lockfree_available) and defined(cpp):
          var outVal = 0'u64
          if bench_boost_stack_pop(ctx.boostPtr, addr outVal):
            inc consumed
          else:
            benchBackoffOnPeerWait()
      of skLocked:
        let (ok, _) = ctx.lockedPtr.pop()
        if ok:
          inc consumed
        else:
          benchBackoffOnPeerWait()

proc runStackBenchmark(
    stackKind: StackKind,
    numProducers: int,
    numConsumers: int,
    messageCount: int
): float =
  var tStack: TreiberStack[int]
  var lStack: LockedStack[int]
  var bStack: pointer = nil

  case stackKind
  of skTreiber:
    tStack = initTreiberStack[int]()
  of skBoost:
    when defined(adapter_boost_lockfree_available) and defined(cpp):
      bStack = bench_boost_stack_init(csize_t(max(65536, messageCount)))
  of skLocked:
    lStack = newLockedStack[int]()

  defer:
    if stackKind == skLocked:
      destroyLockedStack(lStack)
    elif stackKind == skBoost:
      when defined(adapter_boost_lockfree_available) and defined(cpp):
        bench_boost_stack_destroy(bStack)

  let numThreads = numProducers + numConsumers
  var threads = newSeq[Thread[ptr StackWorkerCtx]](numThreads)
  var ctxs = newSeq[StackWorkerCtx](numThreads)

  let baseP = messageCount div numProducers
  let remP = messageCount mod numProducers
  let baseC = messageCount div numConsumers
  let remC = messageCount mod numConsumers

  for i in 0 ..< numProducers:
    let count = baseP + (if i < remP: 1 else: 0)
    ctxs[i] = StackWorkerCtx(
      stackKind: stackKind,
      treiberPtr: addr tStack,
      boostPtr: bStack,
      lockedPtr: lStack,
      isProducer: true,
      count: count,
      threadId: i
    )

  for i in 0 ..< numConsumers:
    let count = baseC + (if i < remC: 1 else: 0)
    let idx = numProducers + i
    ctxs[idx] = StackWorkerCtx(
      stackKind: stackKind,
      treiberPtr: addr tStack,
      boostPtr: bStack,
      lockedPtr: lStack,
      isProducer: false,
      count: count,
      threadId: idx
    )

  let t0 = getMonoTime()
  for i in 0 ..< numThreads:
    createThread(threads[i], stackWorkerBody, addr ctxs[i])
  for i in 0 ..< numThreads:
    joinThread(threads[i])
  let elapsedNs = float(inNanoseconds(getMonoTime() - t0))

  if elapsedNs <= 0.0:
    return 0.0
  result = float(messageCount) * 1_000_000.0 / elapsedNs

# -----------------------------------------------------------------------------
# 2. Work-Stealing Deque Benchmark Harness (ChaseLevDeque vs Crossbeam Deque)
# -----------------------------------------------------------------------------
type
  DequeKind = enum
    dkChaseLevSingle
    dkChaseLevBatch
    dkCrossbeamSingle
    dkCrossbeamBatch

  DequeWorkerCtx = object
    dequeKind: DequeKind
    dequePtr: ptr ChaseLevDeque[int]
    cbPtr: pointer
    isWorker: bool
    thiefIdx: int
    count: int
    threadId: int
    doneFlag: ptr Atomic[bool]

proc dequeWorkerBody(ctxPtr: ptr DequeWorkerCtx) {.thread.} =
  let ctx = ctxPtr[]
  if ctx.isWorker:
    for i in 0 ..< ctx.count:
      case ctx.dequeKind
      of dkChaseLevSingle, dkChaseLevBatch:
        ctx.dequePtr[].pushBottom(i)
        if (i and 3) == 0:
          discard ctx.dequePtr[].popBottom()
      of dkCrossbeamSingle, dkCrossbeamBatch:
        when defined(adapter_rust_ffi_available):
          cb_deque_push(ctx.cbPtr, uint64(i))
          if (i and 3) == 0:
            var popped = 0'u64
            discard cb_deque_pop(ctx.cbPtr, addr popped)
    ctx.doneFlag[].store(true, moRelease)
  else:
    case ctx.dequeKind
    of dkChaseLevSingle:
      while not ctx.doneFlag[].load(moAcquire) or not ctx.dequePtr[].isEmpty:
        let item = ctx.dequePtr[].steal()
        if item.isNone:
          benchBackoffOnPeerWait()
    of dkChaseLevBatch:
      var batchBuf: array[StealBatchLimit, int]
      while not ctx.doneFlag[].load(moAcquire) or not ctx.dequePtr[].isEmpty:
        let n = ctx.dequePtr[].stealBatch(batchBuf, StealBatchLimit)
        if n == 0:
          benchBackoffOnPeerWait()
    of dkCrossbeamSingle:
      when defined(adapter_rust_ffi_available):
        var stolen = 0'u64
        while not ctx.doneFlag[].load(moAcquire) or not cb_deque_is_empty(ctx.cbPtr):
          if not cb_deque_steal(ctx.cbPtr, addr stolen):
            benchBackoffOnPeerWait()
    of dkCrossbeamBatch:
      when defined(adapter_rust_ffi_available):
        while not ctx.doneFlag[].load(moAcquire) or not cb_deque_is_empty(ctx.cbPtr):
          let n = cb_deque_steal_batch(ctx.cbPtr, csize_t(ctx.thiefIdx), csize_t(StealBatchLimit))
          if n == 0:
            benchBackoffOnPeerWait()

proc runDequeBenchmark(dequeKind: DequeKind, numThieves: int, itemsCount: int): float =
  var deque: ChaseLevDeque[int]
  var cbPtr: pointer = nil

  case dequeKind
  of dkChaseLevSingle, dkChaseLevBatch:
    deque = initChaseLevDeque[int](16384)
  of dkCrossbeamSingle, dkCrossbeamBatch:
    when defined(adapter_rust_ffi_available):
      cbPtr = cb_deque_init(csize_t(numThieves))

  defer:
    if dequeKind in {dkCrossbeamSingle, dkCrossbeamBatch}:
      when defined(adapter_rust_ffi_available):
        cb_deque_destroy(cbPtr)

  var done = Atomic[bool]()
  done.store(false, moRelaxed)

  let totalThreads = 1 + numThieves
  var threads = newSeq[Thread[ptr DequeWorkerCtx]](totalThreads)
  var ctxs = newSeq[DequeWorkerCtx](totalThreads)

  ctxs[0] = DequeWorkerCtx(
    dequeKind: dequeKind,
    dequePtr: addr deque,
    cbPtr: cbPtr,
    isWorker: true,
    thiefIdx: 0,
    count: itemsCount,
    threadId: 0,
    doneFlag: addr done
  )

  for i in 1 .. numThieves:
    ctxs[i] = DequeWorkerCtx(
      dequeKind: dequeKind,
      dequePtr: addr deque,
      cbPtr: cbPtr,
      isWorker: false,
      thiefIdx: i - 1,
      count: itemsCount,
      threadId: i,
      doneFlag: addr done
    )

  let t0 = getMonoTime()
  for i in 0 ..< totalThreads:
    createThread(threads[i], dequeWorkerBody, addr ctxs[i])
  for i in 0 ..< totalThreads:
    joinThread(threads[i])
  let elapsedNs = float(inNanoseconds(getMonoTime() - t0))

  if elapsedNs <= 0.0:
    return 0.0
  result = float(itemsCount) * 1_000_000.0 / elapsedNs

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

  echo "Stacks & Deques Benchmark (Nim vs Rust vs C++)"
  echo "=============================================="

  var emitter = initBMFEmitter()

  # 1. Stacks MPMC Contention
  echo "\n--- MPMC Stacks Contention ---"
  let stackShapes = [(1, 1, "1p1c"), (2, 2, "2p2c"), (4, 4, "4p4c"), (8, 8, "8p8c")]
  var stackTargets = @[
    (skTreiber, "treiber_stack"),
    (skLocked, "locked_stack")
  ]
  when defined(adapter_boost_lockfree_available) and defined(cpp):
    stackTargets.insert((skBoost, "boost_lockfree_stack"), 1)

  for (np, nc, shape) in stackShapes:
    for (sKind, libSlug) in stackTargets:
      for _ in 0 ..< BenchStackWarmup:
        discard runStackBenchmark(sKind, np, nc, BenchStackMsgCount)
      var samples = newSeq[float](BenchStackRuns)
      for r in 0 ..< BenchStackRuns:
        samples[r] = runStackBenchmark(sKind, np, nc, BenchStackMsgCount)
      let m = mean(samples)
      let s = stddev(samples)
      let slug = &"{libSlug}/stack_mpmc/{shape}"
      emitter.addMeasure(slug, "throughput_ops_ms", m, m - s, m + s)
      echo &"{slug}: mean = {m:10.1f} ops/ms, stddev = {s:8.1f}"

  # 2. Work-Stealing Deques (Single steal vs Batch steal)
  echo "\n--- Work-Stealing Deques (1 Worker + N Thieves) ---"
  let dequeShapes = [(1, "1w1t"), (2, "1w2t"), (4, "1w4t"), (8, "1w8t")]
  var dequeTargets = @[
    (dkChaseLevSingle, "chase_lev_deque"),
    (dkChaseLevBatch, "chase_lev_deque_batch")
  ]
  when defined(adapter_rust_ffi_available):
    dequeTargets.insert((dkCrossbeamSingle, "crossbeam_deque"), 1)
    dequeTargets.add((dkCrossbeamBatch, "crossbeam_deque_batch"))

  for (numThieves, shape) in dequeShapes:
    for (dKind, libSlug) in dequeTargets:
      for _ in 0 ..< BenchStackWarmup:
        discard runDequeBenchmark(dKind, numThieves, BenchStackMsgCount)
      var samples = newSeq[float](BenchStackRuns)
      for r in 0 ..< BenchStackRuns:
        samples[r] = runDequeBenchmark(dKind, numThieves, BenchStackMsgCount)
      let m = mean(samples)
      let s = stddev(samples)
      let slug = &"{libSlug}/work_stealing/{shape}"
      emitter.addMeasure(slug, "throughput_ops_ms", m, m - s, m + s)
      echo &"{slug}: mean = {m:10.1f} ops/ms, stddev = {s:8.1f}"

  if outputPath.len > 0:
    emitter.emit(outputPath)
    echo &"\nEmitted results to {outputPath}"

when isMainModule:
  main()
