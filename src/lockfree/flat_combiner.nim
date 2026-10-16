## ===========================================================================
## Concurrency Topology: Hendler-Incze-Shavit-Tzafrir Flat Combiner
## (`FlatCombiner[T, Op, Res]`)
## ===========================================================================
##
## A high-throughput synchronization adapter implementing **Flat Combining**
## (Hendler, Incze, Shavit, & Tzafrir, *"Flat Combining and the
## Synchronization-Parallelism Tradeoff"*, SPAA 2010).
##
## Flat Combining transforms any sequential data structure `T` into a
## linearizable, high-throughput concurrent data structure without fine-grained
## CAS retry storms or cache-line ping-pong on internal nodes:
##
## 1. **Cache-Line Isolated Publication Records (`PublicationRecord`)**:
##    Each participating thread owns a 64-byte aligned publication record in a
##    lock-free Treiber publication list (`pubHead`). Threads announce an
##    operation (`Op` or a custom callback) in their local record and spin on
##    their private cache line (`status`).
## 2. **Single-Combiner Batch Execution**:
##    One thread acquires the combiner lease (`combinerLock`), scans the active
##    publication list, and applies all pending operations sequentially to
##    `state: var T` while `state` remains hot in L1 cache.
## 3. **Contention-Adaptive Multi-Round Leasing**:
##    When peer contention is detected during a combining pass, the combiner
##    retains its lease for up to `maxCombiningRounds` consecutive sweeps so
##    newly submitted operations from awakened threads are combined immediately
##    without lock handoff overhead. Under uncontended single-thread access,
##    the combiner takes a zero-publication fast path and releases immediately.
## 4. **Periodic Publication-List Pruning**:
##    Every `cleanupInterval` combining passes, stale idle records are safely
##    unlinked from interior positions of `pubHead` via an atomic
##    `prsIdle -> prsUnlinking -> prsUnlinked` handshake that eliminates
##    list-traversal data races under C11 and ThreadSanitizer.

when not compileOption("threads"):
  {.error: "lockfree/flat_combiner requires --threads:on".}

import ./atomics
import ./atomics/backoff
import ./internal/aligned_alloc

const
  CacheLine* = aligned_alloc.CacheLineBytes
  DefaultCombiningRounds* = 16
    ## Default maximum number of consecutive combining sweeps per lease under contention.
  DefaultCleanupInterval* = 64
    ## Default number of combining passes between publication list pruning sweeps.
  DefaultAdaptiveSpinCount* = 24
    ## Brief pause iterations between multi-round sweeps when peers are active.
  TlsCacheCapacity = 64
    ## Power-of-two per-thread lookup cache capacity (zero heap allocation in TLS).
  TlsCacheMask = uint64(TlsCacheCapacity - 1)

  # PublicationRecord atomic status state machine:
  prsUnlinked* = 0'u32       ## Record is idle and NOT linked in `pubHead`.
  prsIdle* = 1'u32           ## Record is linked in `pubHead` and idle between requests.
  prsPendingTyped* = 2'u32   ## Record holds a pending typed `Op` request.
  prsPendingCustom* = 3'u32  ## Record holds a pending custom callback (`customFn`).
  prsDone* = 4'u32           ## Request executed by combiner; result ready for owner.
  prsUnlinking* = 5'u32      ## Transient state held by combiner while unlinking idle record.

type
  FlatCombinerApplyFn*[T, Op, Res] = proc(state: var T, op: Op): Res {.gcsafe.}
    ## Typed operation reducer applied by the combiner to `state`.

  FlatCombinerCustomFn*[T] = proc(state: var T, ctx: pointer) {.nimcall, gcsafe.}
    ## Low-level type-erased operation callback applied by the combiner to `state`.

  FlatCombinerConfig* = object
    maxCombiningRounds*: int
    cleanupInterval*: int
    adaptiveSpinCount*: int

  PublicationRecord*[T, Op, Res] = object
    status* {.align: 128.}: Atomic[uint32]
    age*: Atomic[uint64]
    ownerTid*: uint64
    next*: Atomic[pointer]     ## Next `ptr PublicationRecord[T, Op, Res]` in `pubHead`
    allNext*: pointer          ## Next `ptr PublicationRecord[T, Op, Res]` in `allRecordsHead`
    customFn*: FlatCombinerCustomFn[T]
    customCtx*: pointer
    op*: Op
    res*: Res

  FlatCombinerCore*[T, Op, Res] = object
    combinerLock* {.align: CacheLine.}: Atomic[uint64]
    passCount* {.align: CacheLine.}: Atomic[uint64]
    totalCombinedOps*: Atomic[uint64]
    activeRecords*: Atomic[int]
    pubHead* {.align: CacheLine.}: Atomic[pointer]
    allRecordsHead* {.align: CacheLine.}: Atomic[pointer]
    combinerId*: uint64
    maxCombiningRounds*: int
    cleanupInterval*: int
    adaptiveSpinCount*: int
    rc*: Atomic[int]
    applyFn*: FlatCombinerApplyFn[T, Op, Res]
    state* {.align: CacheLine.}: T

  FlatCombiner*[T; Op = pointer; Res = pointer] = object
    ## Concurrent Flat-Combining wrapper around sequential data structure `T`.
    ## Can be instantiated as `FlatCombiner[T, Op, Res]` for typed operation
    ## dispatch or `FlatCombiner[T]` for closure/callback dispatch.
    core*: ptr FlatCombinerCore[T, Op, Res]

  TlsCacheEntry = object
    combinerId: uint64
    record: pointer

var
  gNextCombinerId: Atomic[uint64]
  gNextThreadId: Atomic[uint64]
  gMyThreadId {.threadvar.}: uint64
  gTlsCache {.threadvar.}: array[TlsCacheCapacity, TlsCacheEntry]

proc getFcThreadId(): uint64 {.inline.} =
  var tid = gMyThreadId
  if unlikely(tid == 0'u64):
    tid = gNextThreadId.fetchAdd(1'u64, moRelaxed) + 1'u64
    gMyThreadId = tid
  result = tid

# ---------------------------------------------------------------------------
# ARC/ORC Lifecycle Management (`FlatCombiner`)
# ---------------------------------------------------------------------------

proc destroyCore[T, Op, Res](core: ptr FlatCombinerCore[T, Op, Res]) {.gcsafe.} =
  {.cast(gcsafe).}:
    if core == nil:
      return
    var curr = cast[ptr PublicationRecord[T, Op, Res]](core.allRecordsHead.load(moAcquire))
    while curr != nil:
      let nextRec = cast[ptr PublicationRecord[T, Op, Res]](curr.allNext)
      when not (Op is SomeNumber or Op is bool or Op is char or Op is pointer or Op is ptr or Op is enum):
        `=destroy`(curr.op)
      when not (Res is SomeNumber or Res is bool or Res is char or Res is pointer or Res is ptr or Res is enum):
        `=destroy`(curr.res)
      freeAligned(curr)
      curr = nextRec
    `=destroy`(core.applyFn)
    `=destroy`(core.state)
    freeAligned(core)

proc `=destroy`*[T, Op, Res](self: FlatCombiner[T, Op, Res]) =
  if self.core != nil:
    if self.core.rc.fetchSub(1, moRelease) == 1:
      threadFence(moAcquire)
      destroyCore(self.core)

proc `=copy`*[T, Op, Res](dest: var FlatCombiner[T, Op, Res], src: FlatCombiner[T, Op, Res]) =
  if dest.core == src.core:
    return
  if src.core != nil:
    discard src.core.rc.fetchAdd(1, moRelaxed)
  if dest.core != nil:
    if dest.core.rc.fetchSub(1, moRelease) == 1:
      threadFence(moAcquire)
      destroyCore(dest.core)
  dest.core = src.core

proc `=sink`*[T, Op, Res](dest: var FlatCombiner[T, Op, Res], src: FlatCombiner[T, Op, Res]) =
  if dest.core != nil and dest.core != src.core:
    if dest.core.rc.fetchSub(1, moRelease) == 1:
      threadFence(moAcquire)
      destroyCore(dest.core)
  dest.core = src.core

# ---------------------------------------------------------------------------
# Constructors
# ---------------------------------------------------------------------------

proc defaultFlatCombinerConfig*(
    maxCombiningRounds: int = DefaultCombiningRounds,
    cleanupInterval: int = DefaultCleanupInterval,
    adaptiveSpinCount: int = DefaultAdaptiveSpinCount
): FlatCombinerConfig {.inline.} =
  FlatCombinerConfig(
    maxCombiningRounds: max(1, maxCombiningRounds),
    cleanupInterval: max(8, cleanupInterval),
    adaptiveSpinCount: max(0, adaptiveSpinCount)
  )

proc initFlatCombiner*[T, Op, Res](
    initialState: sink T,
    applyFn: FlatCombinerApplyFn[T, Op, Res],
    maxCombiningRounds: int = DefaultCombiningRounds,
    cleanupInterval: int = DefaultCleanupInterval,
    adaptiveSpinCount: int = DefaultAdaptiveSpinCount
): FlatCombiner[T, Op, Res] =
  ## Initializes a typed `FlatCombiner[T, Op, Res]` with an initial sequential
  ## `state` and reducer `applyFn`.
  let core = allocAligned[FlatCombinerCore[T, Op, Res]]()
  core.combinerLock.store(0'u64, moRelaxed)
  core.passCount.store(0'u64, moRelaxed)
  core.totalCombinedOps.store(0'u64, moRelaxed)
  core.activeRecords.store(0, moRelaxed)
  core.pubHead.store(nil, moRelaxed)
  core.allRecordsHead.store(nil, moRelaxed)
  core.combinerId = gNextCombinerId.fetchAdd(1'u64, moRelaxed) + 1'u64
  core.maxCombiningRounds = max(1, maxCombiningRounds)
  core.cleanupInterval = max(8, cleanupInterval)
  core.adaptiveSpinCount = max(0, adaptiveSpinCount)
  core.rc.store(1, moRelaxed)
  core.applyFn = applyFn
  core.state = initialState
  result.core = core

proc newFlatCombiner*[T, Op, Res](
    initialState: sink T,
    applyFn: FlatCombinerApplyFn[T, Op, Res],
    maxCombiningRounds: int = DefaultCombiningRounds,
    cleanupInterval: int = DefaultCleanupInterval,
    adaptiveSpinCount: int = DefaultAdaptiveSpinCount
): FlatCombiner[T, Op, Res] {.inline.} =
  initFlatCombiner[T, Op, Res](
    initialState, applyFn, maxCombiningRounds, cleanupInterval, adaptiveSpinCount
  )

proc initFlatCombiner*[T](
    initialState: sink T,
    maxCombiningRounds: int = DefaultCombiningRounds,
    cleanupInterval: int = DefaultCleanupInterval,
    adaptiveSpinCount: int = DefaultAdaptiveSpinCount
): FlatCombiner[T, pointer, pointer] =
  ## Initializes a single-parameter `FlatCombiner[T]` for closure, callback, or
  ## `withCombined` block execution.
  initFlatCombiner[T, pointer, pointer](
    initialState, nil, maxCombiningRounds, cleanupInterval, adaptiveSpinCount
  )

proc newFlatCombiner*[T](
    initialState: sink T,
    maxCombiningRounds: int = DefaultCombiningRounds,
    cleanupInterval: int = DefaultCleanupInterval,
    adaptiveSpinCount: int = DefaultAdaptiveSpinCount
): FlatCombiner[T, pointer, pointer] {.inline.} =
  initFlatCombiner[T](
    initialState, maxCombiningRounds, cleanupInterval, adaptiveSpinCount
  )

proc initFlatCombiner*[T](): FlatCombiner[T, pointer, pointer] {.inline.} =
  ## Initializes a `FlatCombiner[T]` with `default(T)`.
  initFlatCombiner[T](default(T))

proc newFlatCombiner*[T](): FlatCombiner[T, pointer, pointer] {.inline.} =
  initFlatCombiner[T](default(T))

# ---------------------------------------------------------------------------
# Thread-Local Publication Record Lookup & Registration
# ---------------------------------------------------------------------------

proc getOrCreateRecord[T, Op, Res](
    core: ptr FlatCombinerCore[T, Op, Res]
): ptr PublicationRecord[T, Op, Res] {.inline.} =
  let cid = core.combinerId
  let slotIdx = int(cid and TlsCacheMask)
  if likely(gTlsCache[slotIdx].combinerId == cid):
    return cast[ptr PublicationRecord[T, Op, Res]](gTlsCache[slotIdx].record)

  let myTid = getFcThreadId()
  # Check if this thread already allocated a record for `core` (in case of TLS cache collision)
  var scan = cast[ptr PublicationRecord[T, Op, Res]](core.allRecordsHead.load(moAcquire))
  while scan != nil:
    if scan.ownerTid == myTid:
      gTlsCache[slotIdx].combinerId = cid
      gTlsCache[slotIdx].record = cast[pointer](scan)
      return scan
    scan = cast[ptr PublicationRecord[T, Op, Res]](scan.allNext)

  # Allocate a new 64-byte aligned PublicationRecord owned by `core`
  let rec = allocAligned[PublicationRecord[T, Op, Res]]()
  rec.status.store(prsUnlinked, moRelaxed)
  rec.age.store(0'u64, moRelaxed)
  rec.ownerTid = myTid
  rec.next.store(nil, moRelaxed)

  var oldAll = core.allRecordsHead.load(moAcquire)
  while true:
    rec.allNext = oldAll
    if core.allRecordsHead.compareExchange(oldAll, cast[pointer](rec), moAcquireRelease, moAcquire):
      break

  gTlsCache[slotIdx].combinerId = cid
  gTlsCache[slotIdx].record = cast[pointer](rec)
  return rec

proc linkRecord[T, Op, Res](
    core: ptr FlatCombinerCore[T, Op, Res],
    rec: ptr PublicationRecord[T, Op, Res]
) {.inline.} =
  ## Prepends `rec` (whose status has already been set to `prsPending*` from
  ## `prsUnlinked`) onto `core.pubHead`.
  var oldHead = core.pubHead.load(moAcquire)
  while true:
    rec.next.store(oldHead, moRelaxed)
    if core.pubHead.compareExchange(oldHead, cast[pointer](rec), moAcquireRelease, moAcquire):
      discard core.activeRecords.fetchAdd(1, moRelaxed)
      break

proc publishRecord[T, Op, Res](
    core: ptr FlatCombinerCore[T, Op, Res],
    rec: ptr PublicationRecord[T, Op, Res],
    reqStatus: uint32
) {.inline.} =
  ## Transitions `rec.status` to `reqStatus` and guarantees `rec` is linked in
  ## `core.pubHead` without racing against combiner cleanup.
  var st = rec.status.load(moAcquire)
  while true:
    if likely(st == prsIdle):
      # Fast path: record is already linked in `pubHead`; transition atomically.
      if rec.status.compareExchange(st, reqStatus, moAcquireRelease, moAcquire):
        return
      # CAS failed: combiner transitioned `prsIdle -> prsUnlinking` or `prsUnlinked`.
    elif st == prsUnlinked:
      # Record is unlinked; set age & status to `reqStatus` and prepend to `pubHead`.
      rec.age.store(core.passCount.load(moRelaxed), moRelaxed)
      rec.status.store(reqStatus, moRelease)
      linkRecord(core, rec)
      return
    elif st == prsUnlinking:
      # Combiner is mid-unlink; wait a few cycles for `prsUnlinked`.
      cpuPause()
      st = rec.status.load(moAcquire)
    else:
      # Should not happen on single owner thread, but recover safely.
      rec.status.store(reqStatus, moRelease)
      return

# ---------------------------------------------------------------------------
# Combiner Execution Engine & Contention-Adaptive Leasing
# ---------------------------------------------------------------------------

proc executeSingleSweep[T, Op, Res](
    core: ptr FlatCombinerCore[T, Op, Res],
    pass: uint64
): int {.inline, gcsafe.} =
  ## Scans `core.pubHead` once, executing all pending operations on `core.state`.
  ## Returns the number of operations combined in this sweep.
  {.cast(gcsafe).}:
    var combined = 0
    let doCleanup = (pass mod uint64(core.cleanupInterval)) == 0'u64
    let head = cast[ptr PublicationRecord[T, Op, Res]](core.pubHead.load(moAcquire))
    var prev: ptr PublicationRecord[T, Op, Res] = nil
    var curr = head

    while curr != nil:
      let nextRec = cast[ptr PublicationRecord[T, Op, Res]](curr.next.load(moAcquire))
      let st = curr.status.load(moAcquire)

      if st == prsPendingTyped:
        if core.applyFn != nil:
          curr.res = core.applyFn(core.state, curr.op)
        curr.age.store(pass, moRelaxed)
        curr.status.store(prsIdle, moRelease)
        inc combined
        prev = curr
      elif st == prsPendingCustom:
        if curr.customFn != nil:
          curr.customFn(core.state, curr.customCtx)
        curr.age.store(pass, moRelaxed)
        curr.status.store(prsIdle, moRelease)
        inc combined
        prev = curr
      elif doCleanup and st == prsIdle:
        let recAge = curr.age.load(moRelaxed)
        if pass > recAge and (pass - recAge) >= uint64(core.cleanupInterval):
          var expectedIdle = prsIdle
          if curr.status.compareExchange(expectedIdle, prsUnlinking, moAcquireRelease, moAcquire):
            if prev != nil:
              prev.next.store(cast[pointer](nextRec), moRelease)
              discard core.activeRecords.fetchSub(1, moRelaxed)
              curr.status.store(prsUnlinked, moRelease)
              # `prev` remains unchanged since `curr` was removed
            else:
              # `curr` is currently at head; attempt CAS on `core.pubHead`
              var expectedHead = cast[pointer](curr)
              if core.pubHead.compareExchange(expectedHead, cast[pointer](nextRec), moAcquireRelease, moAcquire):
                discard core.activeRecords.fetchSub(1, moRelaxed)
                curr.status.store(prsUnlinked, moRelease)
                # `prev` remains `nil`; `nextRec` is the new head
              else:
                # Another thread prepended a new head; keep `curr` linked for next pass
                curr.status.store(prsIdle, moRelease)
                prev = curr
          else:
            # Owner concurrently transitioned `prsIdle -> prsPending*`! Serve it immediately!
            let newSt = expectedIdle
            if newSt == prsPendingTyped:
              if core.applyFn != nil:
                curr.res = core.applyFn(core.state, curr.op)
              curr.age.store(pass, moRelaxed)
              curr.status.store(prsIdle, moRelease)
              inc combined
            elif newSt == prsPendingCustom:
              if curr.customFn != nil:
                curr.customFn(core.state, curr.customCtx)
              curr.age.store(pass, moRelaxed)
              curr.status.store(prsIdle, moRelease)
              inc combined
            prev = curr
        else:
          prev = curr
      else:
        prev = curr

      curr = nextRec

    return combined

proc runCombiningPass[T, Op, Res](
    core: ptr FlatCombinerCore[T, Op, Res],
    directOps: uint64 = 0'u64
) {.inline, gcsafe.} =
  ## Runs up to `core.maxCombiningRounds` sweeps while holding `combinerLock`.
  ## Keeps `core.state` hot in the combiner's L1 cache across rounds while
  ## active peers turn around their next requests in their local `PublicationRecord`s.
  let maxRounds = core.maxCombiningRounds
  var pass = core.passCount.load(moRelaxed)
  var totalCombined = directOps
  var round = 0
  while round < maxRounds:
    inc round
    inc pass
    let combined = executeSingleSweep(core, pass)
    totalCombined += uint64(combined)

    if combined == 0:
      break

  core.passCount.store(pass, moRelaxed)
  if totalCombined > 0'u64:
    core.totalCombinedOps.store(
      core.totalCombinedOps.load(moRelaxed) + totalCombined,
      moRelaxed
    )

proc isRequestDone[T, Op, Res](
    rec: ptr PublicationRecord[T, Op, Res]
): bool {.inline.} =
  let st = rec.status.load(moAcquire)
  st != prsPendingTyped and st != prsPendingCustom

proc awaitOrCombine[T, Op, Res](
    core: ptr FlatCombinerCore[T, Op, Res],
    rec: ptr PublicationRecord[T, Op, Res]
) {.inline, gcsafe.} =
  ## Hendler-Incze-Shavit-Tzafrir waiter protocol:
  ## Spins strictly on the thread-local `rec.status` cache line while an active
  ## combiner holds `combinerLock`, avoiding cross-core cache invalidation
  ## storms on `combinerLock` and allowing the active combiner to retain L1
  ## locality on `core.state`.
  while true:
    if isRequestDone(rec):
      return

    if core.combinerLock.load(moRelaxed) == 0'u64:
      var expected = 0'u64
      if core.combinerLock.compareExchange(expected, 1'u64, moAcquire, moRelaxed):
        try:
          runCombiningPass(core, 0'u64)
        finally:
          core.combinerLock.store(0'u64, moRelease)
        if isRequestDone(rec):
          return

    # Spin strictly on our private PublicationRecord cache line while the
    # active combiner executes its sweeps.
    for _ in 0 ..< 256:
      if isRequestDone(rec):
        return
      cpuPause()

# ---------------------------------------------------------------------------
# Public Combining Operations
# ---------------------------------------------------------------------------

proc combine*[T, Op, Res](
    self: FlatCombiner[T, Op, Res],
    op: Op
): Res {.gcsafe.} =
  ## Submits a typed operation `op` to the `FlatCombiner` and returns its `Res`.
  ##
  ## Fast path: if `combinerLock` is free, acquires the combiner lease directly,
  ## executes `op` in L1 cache, and sweeps `pubHead` if any peers have published
  ## requests.
  ## Contended path: publishes `op` in the thread's 128-byte aligned
  ## `PublicationRecord` and awaits completion by the active combiner (or takes
  ## over as combiner if the lock becomes free).
  doAssert self.core != nil, "FlatCombiner is uninitialized"
  let core = self.core
  doAssert core.applyFn != nil, "FlatCombiner.combine(op) requires a non-nil applyFn"

  # Direct combiner acquisition when lock is free (preserves L1 locality)
  if core.combinerLock.load(moRelaxed) == 0'u64:
    var expected = 0'u64
    if core.combinerLock.compareExchange(expected, 1'u64, moAcquire, moRelaxed):
      try:
        {.cast(gcsafe).}:
          result = core.applyFn(core.state, op)
        if unlikely(core.pubHead.load(moAcquire) != nil):
          runCombiningPass(core, 1'u64)
        else:
          core.passCount.store(core.passCount.load(moRelaxed) + 1'u64, moRelaxed)
          core.totalCombinedOps.store(
            core.totalCombinedOps.load(moRelaxed) + 1'u64,
            moRelaxed
          )
      finally:
        core.combinerLock.store(0'u64, moRelease)
      return result

  let rec = getOrCreateRecord(core)
  rec.op = op
  publishRecord(core, rec, prsPendingTyped)
  awaitOrCombine(core, rec)
  result = rec.res

proc combineRaw*[T, Op, Res](
    self: FlatCombiner[T, Op, Res],
    fn: FlatCombinerCustomFn[T],
    ctx: pointer
) {.gcsafe.} =
  ## Executes a low-level callback `fn(state, ctx)` under the combiner lease.
  doAssert self.core != nil, "FlatCombiner is uninitialized"
  doAssert fn != nil, "combineRaw callback cannot be nil"
  let core = self.core

  # Direct combiner acquisition when lock is free (preserves L1 locality)
  if core.combinerLock.load(moRelaxed) == 0'u64:
    var expected = 0'u64
    if core.combinerLock.compareExchange(expected, 1'u64, moAcquire, moRelaxed):
      try:
        {.cast(gcsafe).}:
          fn(core.state, ctx)
        if unlikely(core.pubHead.load(moAcquire) != nil):
          runCombiningPass(core, 1'u64)
        else:
          core.passCount.store(core.passCount.load(moRelaxed) + 1'u64, moRelaxed)
          core.totalCombinedOps.store(
            core.totalCombinedOps.load(moRelaxed) + 1'u64,
            moRelaxed
          )
      finally:
        core.combinerLock.store(0'u64, moRelease)
      return

  let rec = getOrCreateRecord(core)
  rec.customFn = fn
  rec.customCtx = ctx
  publishRecord(core, rec, prsPendingCustom)
  awaitOrCombine(core, rec)

type
  ClosureExecCtx[T, R] = object
    fn: proc(state: var T): R {.gcsafe.}
    res: R

  VoidClosureExecCtx[T] = object
    fn: proc(state: var T) {.gcsafe.}

proc invokeClosureCtx[T, R](state: var T, rawCtx: pointer) {.nimcall, gcsafe.} =
  let ctx = cast[ptr ClosureExecCtx[T, R]](rawCtx)
  {.cast(gcsafe).}:
    ctx.res = ctx.fn(state)

proc invokeVoidClosureCtx[T](state: var T, rawCtx: pointer) {.nimcall, gcsafe.} =
  let ctx = cast[ptr VoidClosureExecCtx[T]](rawCtx)
  {.cast(gcsafe).}:
    ctx.fn(state)

proc combine*[T, Op, Res, R](
    self: FlatCombiner[T, Op, Res],
    fn: proc(state: var T): R {.gcsafe.}
): R {.gcsafe.} =
  ## Executes an arbitrary closure `fn(state): R` via Flat Combining and returns `R`.
  var ctx = ClosureExecCtx[T, R](fn: fn)
  self.combineRaw(invokeClosureCtx[T, R], addr ctx)
  result = ctx.res

proc combine*[T, Op, Res](
    self: FlatCombiner[T, Op, Res],
    fn: proc(state: var T) {.gcsafe.}
) {.gcsafe.} =
  ## Executes a void mutating closure `fn(state)` via Flat Combining.
  var ctx = VoidClosureExecCtx[T](fn: fn)
  self.combineRaw(invokeVoidClosureCtx[T], addr ctx)

template withCombined*[T, Op, Res](
    self: FlatCombiner[T, Op, Res],
    stateSym: untyped,
    body: untyped
): untyped =
  ## Executes `body` with mutable access to the sequential state bound to `stateSym`
  ## inside a flat-combining critical section.
  self.combine(proc(stateSym: var T) {.gcsafe.} =
    body
  )

# ---------------------------------------------------------------------------
# Telemetry & Introspection
# ---------------------------------------------------------------------------

proc isInitialized*[T, Op, Res](self: FlatCombiner[T, Op, Res]): bool {.inline.} =
  self.core != nil

proc passCount*[T, Op, Res](self: FlatCombiner[T, Op, Res]): uint64 {.inline.} =
  ## Returns the total number of combining passes executed so far.
  if self.core == nil: 0'u64
  else: self.core.passCount.load(moAcquire)

proc totalCombinedOps*[T, Op, Res](self: FlatCombiner[T, Op, Res]): uint64 {.inline.} =
  ## Returns the total number of individual operations executed across all passes.
  if self.core == nil: 0'u64
  else: self.core.totalCombinedOps.load(moAcquire)

proc activePublicationRecords*[T, Op, Res](self: FlatCombiner[T, Op, Res]): int {.inline.} =
  ## Returns the number of thread publication records currently linked in `pubHead`.
  if self.core == nil: 0
  else: max(0, self.core.activeRecords.load(moAcquire))

proc avgBatchSize*[T, Op, Res](self: FlatCombiner[T, Op, Res]): float {.inline.} =
  ## Returns the average number of operations combined per pass.
  if self.core == nil: return 0.0
  let passes = self.core.passCount.load(moAcquire)
  let ops = self.core.totalCombinedOps.load(moAcquire)
  if passes == 0'u64: 0.0
  else: float(ops) / float(passes)
