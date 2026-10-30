## Comprehensive Unit, Concurrency, Pruning, and C ABI Tests for
## Hendler-Incze-Shavit-Tzafrir `FlatCombiner[T, Op, Res]`.

import std/[os, sets, tables]
import unittest2
import lockfree/atomics
import lockfree/atomics/backoff
import lockfree/flat_combiner

# ---------------------------------------------------------------------------
# 1. Typed Reducer State & Operations
# ---------------------------------------------------------------------------

type
  SeqStackOpKind = enum
    ssPush
    ssPop
    ssPeek
    ssLen

  SeqStackOp = object
    kind: SeqStackOpKind
    val: int

  SeqStackRes = object
    ok: bool
    val: int

  SeqStack = object
    items: seq[int]
    totalPushes: int
    totalPops: int

proc applySeqStack(state: var SeqStack, op: SeqStackOp): SeqStackRes {.gcsafe.} =
  case op.kind
  of ssPush:
    state.items.add(op.val)
    inc state.totalPushes
    SeqStackRes(ok: true, val: state.items.len)
  of ssPop:
    if state.items.len > 0:
      inc state.totalPops
      SeqStackRes(ok: true, val: state.items.pop())
    else:
      SeqStackRes(ok: false, val: 0)
  of ssPeek:
    if state.items.len > 0:
      SeqStackRes(ok: true, val: state.items[^1])
    else:
      SeqStackRes(ok: false, val: 0)
  of ssLen:
    SeqStackRes(ok: true, val: state.items.len)

# ---------------------------------------------------------------------------
# 2. Multi-Threaded Contention Worker Contexts
# ---------------------------------------------------------------------------

type
  CounterOpKind = enum
    coAdd
    coGet
    coSleep

  CounterOp = object
    kind: CounterOpKind
    delta: int64
    notifyFlag: ptr Atomic[bool]

  SeqCounter = object
    value: int64
    mutations: int64

proc applyCounter(state: var SeqCounter, op: CounterOp): int64 {.gcsafe.} =
  case op.kind
  of coAdd:
    let prev = state.value
    state.value += op.delta
    inc state.mutations
    prev
  of coGet:
    state.value
  of coSleep:
    if op.notifyFlag != nil:
      op.notifyFlag[].store(true, moRelease)
    os.sleep(int(op.delta))
    state.value

type
  MtCounterCtx = object
    fc: FlatCombiner[SeqCounter, CounterOp, int64]
    iters: int
    startFlag: ptr Atomic[bool]
    observedPrevSum: int64

proc mtCounterWorker(ctx: ptr MtCounterCtx) {.thread.} =
  while not ctx.startFlag[].load(moAcquire):
    cpuPause()
  var localSum = 0'i64
  for i in 0 ..< ctx.iters:
    let prev = ctx.fc.combine(CounterOp(kind: coAdd, delta: 1'i64))
    localSum += prev
  ctx.observedPrevSum = localSum

when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc):
  type
    MtTableCtx = object
      fc: FlatCombiner[Table[int, int]]
      tid: int
      iters: int
      startFlag: ptr Atomic[bool]

  proc mtTableWorker(ctx: ptr MtTableCtx) {.thread.} =
    while not ctx.startFlag[].load(moAcquire):
      cpuPause()
    let baseKey = ctx.tid * 1000
    for i in 0 ..< ctx.iters:
      let k = baseKey + (i and 31)
      ctx.fc.withCombined(tbl):
        tbl[k] = tbl.getOrDefault(k, 0) + 1

type
  PruneWorkerCtx = object
    fc: FlatCombiner[SeqCounter, CounterOp, int64]
    ops: int
    startFlag: ptr Atomic[bool]

  PruneBlockerCtx = object
    fc: FlatCombiner[SeqCounter, CounterOp, int64]
    holdMs: int
    startedFlag: ptr Atomic[bool]

proc pruneBlocker(ctx: ptr PruneBlockerCtx) {.thread.} =
  discard ctx.fc.combine(CounterOp(kind: coSleep, delta: int64(ctx.holdMs), notifyFlag: ctx.startedFlag))

proc pruneWorker(ctx: ptr PruneWorkerCtx) {.thread.} =
  if ctx.startFlag != nil:
    while not ctx.startFlag[].load(moAcquire):
      cpuPause()
  for _ in 0 ..< ctx.ops:
    discard ctx.fc.combine(CounterOp(kind: coAdd, delta: 1'i64))

# ---------------------------------------------------------------------------
# Test Suite
# ---------------------------------------------------------------------------

suite "FlatCombiner[T, Op, Res] — Hendler-Incze-Shavit-Tzafrir Adapter":

  test "Single-threaded typed reducer operations and telemetry":
    var fc = initFlatCombiner[SeqStack, SeqStackOp, SeqStackRes](
      SeqStack(items: @[]),
      applySeqStack
    )
    check fc.isInitialized()

    for i in 1 .. 10:
      let r = fc.combine(SeqStackOp(kind: ssPush, val: i * 10))
      check r.ok
      check r.val == i

    let peekRes = fc.combine(SeqStackOp(kind: ssPeek))
    check peekRes.ok
    check peekRes.val == 100

    for i in countdown(10, 1):
      let r = fc.combine(SeqStackOp(kind: ssPop))
      check r.ok
      check r.val == i * 10

    let emptyPop = fc.combine(SeqStackOp(kind: ssPop))
    check not emptyPop.ok
    check fc.totalCombinedOps() == 22'u64
    check fc.passCount() >= 1'u64

  test "Single-parameter FlatCombiner[T] closure and withCombined ergonomics":
    var fc = newFlatCombiner[Table[string, int]](initTable[string, int]())

    fc.withCombined(tbl):
      tbl["alpha"] = 10
      tbl["beta"] = 20

    let sum = fc.combine(proc(tbl: var Table[string, int]): int {.gcsafe.} =
      tbl["gamma"] = tbl["alpha"] + tbl["beta"]
      tbl["gamma"]
    )
    check sum == 30

    let length = fc.combine(proc(tbl: var Table[string, int]): int {.gcsafe.} =
      tbl.len
    )
    check length == 3

    # Verify handle copy & sink semantics preserve shared state
    var fcCopy = fc
    let betaVal = fcCopy.combine(proc(tbl: var Table[string, int]): int {.gcsafe.} =
      tbl["beta"]
    )
    check betaVal == 20

  test "Multi-threaded linearizability and contention-adaptive batching (8 threads)":
    const
      NumThreads = 8
      ItersPerThread = 10_000
      TotalOps = NumThreads * ItersPerThread

    var fc = initFlatCombiner[SeqCounter, CounterOp, int64](
      SeqCounter(value: 0, mutations: 0),
      applyCounter,
      maxCombiningRounds = 16,
      cleanupInterval = 64
    )

    var startFlag: Atomic[bool]
    startFlag.store(false, moRelaxed)

    var threads: array[NumThreads, Thread[ptr MtCounterCtx]]
    var ctxs: array[NumThreads, MtCounterCtx]

    for i in 0 ..< NumThreads:
      ctxs[i] = MtCounterCtx(
        fc: fc,
        iters: ItersPerThread,
        startFlag: addr startFlag,
        observedPrevSum: 0
      )
      createThread(threads[i], mtCounterWorker, addr ctxs[i])

    startFlag.store(true, moRelease)
    for i in 0 ..< NumThreads:
      joinThread(threads[i])

    let finalVal = fc.combine(CounterOp(kind: coGet))
    check finalVal == int64(TotalOps)

    # Every increment from 0 to TotalOps - 1 must have returned a distinct previous value
    var totalPrevSum = 0'i64
    for i in 0 ..< NumThreads:
      totalPrevSum += ctxs[i].observedPrevSum
    let expectedArithmeticSum = (int64(TotalOps) * int64(TotalOps - 1)) div 2
    check totalPrevSum == expectedArithmeticSum
    check fc.totalCombinedOps() == uint64(TotalOps + 1)
    check fc.avgBatchSize() > 0.0

  when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc):
    test "Multi-threaded std/tables.Table wrapper under contention":
      const
        NumThreads = 4
        ItersPerThread = 2_000

      var fc = initFlatCombiner[Table[int, int]](initTable[int, int]())
      var startFlag: Atomic[bool]
      startFlag.store(false, moRelaxed)

      var threads: array[NumThreads, Thread[ptr MtTableCtx]]
      var ctxs: array[NumThreads, MtTableCtx]

      for i in 0 ..< NumThreads:
        ctxs[i] = MtTableCtx(
          fc: fc,
          tid: i,
          iters: ItersPerThread,
          startFlag: addr startFlag
        )
        createThread(threads[i], mtTableWorker, addr ctxs[i])

      startFlag.store(true, moRelease)
      for i in 0 ..< NumThreads:
        joinThread(threads[i])

      let totalSum = fc.combine(proc(tbl: var Table[int, int]): int {.gcsafe.} =
        for v in tbl.values:
          result += v
      )
      check totalSum == NumThreads * ItersPerThread

  test "Periodic publication record pruning unlinks stale interior records safely":
    var fc = initFlatCombiner[SeqCounter, CounterOp, int64](
      SeqCounter(value: 0, mutations: 0),
      applyCounter,
      maxCombiningRounds = 4,
      cleanupInterval = 128
    )

    discard fc.combine(CounterOp(kind: coAdd, delta: 1))

    # Hold the combiner lock from a background blocker thread during worker startup
    # so all workers are guaranteed to experience contention, register publication
    # records, and publish into pubHead before the combiner sweeps them.
    # The blocker thread signals startedFlag from INSIDE the combiner critical section
    # (during applyCounter coSleep) so we guarantee the lock is held before releasing workers.
    var blockerStarted: Atomic[bool]
    blockerStarted.store(false, moRelaxed)
    var blockerCtx = PruneBlockerCtx(fc: fc, holdMs: 150, startedFlag: addr blockerStarted)
    var blockerThread: Thread[ptr PruneBlockerCtx]
    createThread(blockerThread, pruneBlocker, addr blockerCtx)
    while not blockerStarted.load(moAcquire):
      cpuPause()

    const NumTempWorkers = 6
    const WorkerOps = 10
    var startFlag: Atomic[bool]
    startFlag.store(false, moRelaxed)
    var threads: array[NumTempWorkers, Thread[ptr PruneWorkerCtx]]
    var ctxs: array[NumTempWorkers, PruneWorkerCtx]
    for i in 0 ..< NumTempWorkers:
      ctxs[i] = PruneWorkerCtx(fc: fc, ops: WorkerOps, startFlag: addr startFlag)
      createThread(threads[i], pruneWorker, addr ctxs[i])
    startFlag.store(true, moRelease)
    for i in 0 ..< NumTempWorkers:
      joinThread(threads[i])
    joinThread(blockerThread)

    let peakRecords = fc.activePublicationRecords()
    check peakRecords >= 1

    # Now drive >256 passes from a single worker thread so stale records age out past cleanupInterval
    var driverCtx = PruneWorkerCtx(fc: fc, ops: 300, startFlag: nil)
    var driverThread: Thread[ptr PruneWorkerCtx]
    createThread(driverThread, pruneWorker, addr driverCtx)
    joinThread(driverThread)

    let afterPruneRecords = fc.activePublicationRecords()
    check afterPruneRecords <= 1
    let finalCount = fc.combine(CounterOp(kind: coGet))
    check finalCount == int64(1 + NumTempWorkers * WorkerOps + 300)
