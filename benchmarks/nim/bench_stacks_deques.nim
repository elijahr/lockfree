## Benchmarks for Concurrent Stacks & Deques: TreiberStack vs Locked Stack vs ChaseLevDeque.
##
## Evaluates:
##   1. TreiberStack (MPMC stack with elimination backoff) vs LockedStack (seq + Lock)
##      Shapes: 1p1c, 2p2c, 4p4c, 8p8c.
##   2. ChaseLevDeque (Work-Stealing Deque: 1 worker + N thieves)
##      Shapes: 1w1t, 1w2t, 1w4t, 1w8t.
##
## Emits BMF JSON format with `throughput_ops_ms`.

import std/[locks, monotimes, os, parseopt, strformat, times]
import ./bench_common
import lockfree/stack
import lockfree/deque
import lockfree/atomics

const
  BenchStackRuns* {.intdefine.} = 3
  BenchStackWarmup* {.intdefine.} = 1
  BenchStackMsgCount* {.intdefine.} = 500_000

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

proc push[T](ls: LockedStack[T], val: T) {.inline.} =
  withLock(ls.lock):
    ls.items.add(val)

proc pop[T](ls: LockedStack[T]): (bool, T) {.inline.} =
  withLock(ls.lock):
    if ls.items.len > 0:
      return (true, ls.items.pop())
    return (false, default(T))

# -----------------------------------------------------------------------------
# TreiberStack MPMC Benchmark Harness
# -----------------------------------------------------------------------------
type
  StackKind = enum
    skTreiber
    skLocked

  StackWorkerCtx = object
    stackKind: StackKind
    treiberPtr: ptr TreiberStack[int]
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

  case stackKind
  of skTreiber:
    tStack = initTreiberStack[int]()
  of skLocked:
    lStack = newLockedStack[int]()

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
# ChaseLevDeque Work-Stealing Benchmark Harness
# -----------------------------------------------------------------------------
type
  DequeWorkerCtx = object
    dequePtr: ptr ChaseLevDeque[int]
    isWorker: bool
    count: int
    threadId: int
    doneFlag: ptr Atomic[bool]

proc dequeWorkerBody(ctxPtr: ptr DequeWorkerCtx) {.thread.} =
  let ctx = ctxPtr[]
  if ctx.isWorker:
    # Worker pushes items then pops remaining
    for i in 0 ..< ctx.count:
      ctx.dequePtr[].pushBottom(i)
      if (i and 3) == 0:
        # Every 4th item, worker pops from bottom
        discard ctx.dequePtr[].popBottom()
    ctx.doneFlag[].store(true, moRelease)
  else:
    # Thief thread steals items until worker is done and deque is empty
    while not ctx.doneFlag[].load(moAcquire) or not ctx.dequePtr[].isEmpty:
      let item = ctx.dequePtr[].steal()
      if item.isNone:
        benchBackoffOnPeerWait()

proc runDequeBenchmark(numThieves: int, itemsCount: int): float =
  var deque = initChaseLevDeque[int](16384)
  var done = Atomic[bool]()
  done.store(false, moRelaxed)

  let totalThreads = 1 + numThieves
  var threads = newSeq[Thread[ptr DequeWorkerCtx]](totalThreads)
  var ctxs = newSeq[DequeWorkerCtx](totalThreads)

  # Worker
  ctxs[0] = DequeWorkerCtx(
    dequePtr: addr deque,
    isWorker: true,
    count: itemsCount,
    threadId: 0,
    doneFlag: addr done
  )

  # Thieves
  for i in 1 .. numThieves:
    ctxs[i] = DequeWorkerCtx(
      dequePtr: addr deque,
      isWorker: false,
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

  echo "Stacks & Deques Benchmark (TreiberStack vs LockedStack vs ChaseLevDeque)"
  echo "========================================================================"

  var emitter = initBMFEmitter()

  # 1. Stacks MPMC Contention
  echo "\n--- TreiberStack vs LockedStack MPMC Contention ---"
  let stackShapes = [(1, 1, "1p1c"), (2, 2, "2p2c"), (4, 4, "4p4c"), (8, 8, "8p8c")]
  for (np, nc, shape) in stackShapes:
    # TreiberStack
    var tSamples = newSeq[float](BenchStackRuns)
    for r in 0 ..< BenchStackRuns:
      tSamples[r] = runStackBenchmark(skTreiber, np, nc, BenchStackMsgCount)
    let tm = mean(tSamples)
    let ts = stddev(tSamples)
    let tSlug = &"treiber_stack/stack_mpmc/{shape}"
    emitter.addMeasure(tSlug, "throughput_ops_ms", tm, tm - ts, tm + ts)
    echo &"{tSlug}: mean = {tm:10.1f} ops/ms, stddev = {ts:8.1f}"

    # LockedStack
    var lSamples = newSeq[float](BenchStackRuns)
    for r in 0 ..< BenchStackRuns:
      lSamples[r] = runStackBenchmark(skLocked, np, nc, BenchStackMsgCount)
    let lm = mean(lSamples)
    let ls = stddev(lSamples)
    let lSlug = &"locked_stack/stack_mpmc/{shape}"
    emitter.addMeasure(lSlug, "throughput_ops_ms", lm, lm - ls, lm + ls)
    echo &"{lSlug}: mean = {lm:10.1f} ops/ms, stddev = {ls:8.1f}"

  # 2. ChaseLevDeque Work-Stealing
  echo "\n--- ChaseLevDeque Work-Stealing Scalability ---"
  let dequeShapes = [(1, "1w1t"), (2, "1w2t"), (4, "1w4t"), (8, "1w8t")]
  for (thieves, shape) in dequeShapes:
    var dSamples = newSeq[float](BenchStackRuns)
    for r in 0 ..< BenchStackRuns:
      dSamples[r] = runDequeBenchmark(thieves, BenchStackMsgCount)
    let dm = mean(dSamples)
    let ds = stddev(dSamples)
    let dSlug = &"chase_lev_deque/work_stealing/{shape}"
    emitter.addMeasure(dSlug, "throughput_ops_ms", dm, dm - ds, dm + ds)
    echo &"{dSlug}: mean = {dm:10.1f} ops/ms, stddev = {ds:8.1f}"

  if outputPath.len > 0:
    emitter.emit(outputPath)
    echo &"\nEmitted results to {outputPath}"

when isMainModule:
  main()
