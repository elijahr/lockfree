## Unbounded `Queue` generic.
##
##     Queue[T, ccProd, ccCons, ST, S, MaxThreads]
##
## Param order is LOAD-BEARING:
##   T, ccProd, ccCons, ST, S, MaxThreads
##
## The bounded surface lives in `bqueue.nim` (`BQueue[T, ccProd, ccCons,
## N, P, C]`). The `(ccSingle, ccSingle)` branch of the object body
## carries no debra integration (no `manager`, no `ownsManager`, no
## pin/retire wrappers) and uses the committed-flag-free linked-segment
## protocol from the legacy standalone unbounded-SPSC module. The other
## three cardinality combos (MPSC, SPMC, MPMC) carry debra integration.
##
## Cardinality-illegal direct-on-queue calls (multi-producer `push`
## or multi-consumer `pop` against `Queue` directly rather than via
## `QueueProducer` / `QueueConsumer`) are gated by compile-time
## `{.error.}` overloads. The error messages reference the user-visible
## alias type names — no `*Multi`/`*Single` leakage.
##
## **Queueable[T] concept hookup.** Bare
## `Queue[T, ...]` does NOT satisfy the `Queueable[T]` concept defined
## in `./typestates/with_bound` — unbounded push/pop always routes
## through a `Bound[T, Tag, Queue[T, ...]]` endpoint (no direct push/pop
## on bare `Queue`, even for SPSC). Users wanting an unbounded queue
## with the Queueable-style ergonomic surface use the typestate API
## (`getProducer().bindToThread()`) or the `withBoundProducer` /
## `withBoundConsumer` RAII templates in `./typestates/with_bound`.

import ./strategy
import ./reclamation
import ./internal/pinscope_stub
import ./internal/aligned_alloc
import ./internal/shared
import ./internal/typestates_dsl
import ./internal/path_c_admit
import ./internal/slot_encoding
import ./internal/path_c_wrap
import ./typestates/slot_state
# Upstream `typestates` package's `typestate` / `destructorTransition`
# / `transitionError` DSL macros pulled in via
# `./internal/typestates_dsl` for the same name-shadow reason documented
# in `bqueue.nim` — a direct `import typestates` from this file would
# resolve to the local sibling `./typestates.nim` re-export module.
import lockfree/atomics
import ./backoff
import options
import std/typetraits

import ./exceptions

# nebr 0.8.0 surface — used for non-spsc cardinality combos only.
# The `(ccSingle, ccSingle)` branch is debra-free (committed-flag-free
# linked-segment protocol absorbed from the standalone `UnboundedSpsc`
# type). The import set is intentionally maintained for the other three
# cardinalities; Nim's dead-code elimination strips the unused symbols
# from the spsc-only instantiation.
from lockfree/smr/nebr import
  DebraManager, ThreadHandle, PinnedScope, Destructor, initDebraManager, registerThread,
  bindClient, unbindClient, unpinned, pinScope, advanceEvery, reclaimNow,
  DebraRegistrationError, ThreadId, `==`

from lockfree/smr/nebr import retireOnCAS, retireOnPublish

import ./endpoint_types
import ./role_tags
from lockfree/smr/nebr import pinScope, unpinned, advanceEvery, reclaimNow

when defined(debug):
  import std/typedthreads

export exceptions

# `stManual`, `stEager`, `ccSingle`, `ccMulti` travel with their enum
# type; any module that imports `queue` sees them. The `rkNone` / `rkEbr`
# enum members are no longer needed by `Queue` itself (the reclamation
# axis was eliminated), but the enum is re-exported for bench-adapter /
# migration-shim compatibility.
export
  DeallocationStrategy, ReclamationKind, PinScopeCardinality, Manual, Eager,
  DefaultDeallocationStrategy

# `NoSlice` lives in `internal/shared.nim`  Re-exported
# here so existing callers that consume it via `lockfree/queue`
# continue to compile.
export NoSlice

const LockFreeQueuesAdvanceEvery* {.intdefine.}: int = 64
  ## Cadence for `advanceEvery` calls in the rkEbr Eager reclamation path.
  ## Override at compile time with `-d:LockFreeQueuesAdvanceEvery=N`.
static:
  assert LockFreeQueuesAdvanceEvery > 0,
    "LockFreeQueuesAdvanceEvery must be a positive integer"

const LockFreeQueuesMaxWaitForPublishSpins* {.intdefine.}: int = 1024
  ## Bounded-spin budget for an MPMC consumer waiting on a stalled
  ## producer that won the tail-CAS but has not yet `tryPublish`'d
  ## (LCRQ §4 / CRIT-1). After this many spins the consumer drives
  ## `tryCloseOnEmpty` on its reserved cell, surrendering the slot
  ## and falling through to the slow-path-style skip. Override at
  ## compile time with `-d:LockFreeQueuesMaxWaitForPublishSpins=N`.
  ## Smaller = faster forward progress under producer stalls but more
  ## close-on-empty traffic; larger = better steady-state throughput
  ## but worse tail latency when producers stall.
static:
  assert LockFreeQueuesMaxWaitForPublishSpins > 0,
    "LockFreeQueuesMaxWaitForPublishSpins must be a positive integer"

# ----------------------------------------------------------------------
# Strict-LCRQ cell alias + close sentinel.
#
# `LCRQCell[T]` is a *transparent* alias for `Atomic[Pair[uint, T]]`:
# a single 128-bit DWCAS-able cell whose first half is the seq counter
# (`Pair.first`, encoding empty=0 / filled=1 / closed=high-bit) and
# whose second half is the payload of type `T`. This replaces the
# v4.x `committed: Atomic[bool]` + `data[i]: T` overlay on the
# unbounded MPMC arm, unlocking the strict-LCRQ close-on-empty progress
# guarantee via DWCAS arbitration.
#
# `CLOSED_BIT` is the close sentinel: a cell with `seq == CLOSED_BIT`
# is permanently closed — no producer can publish into it and no
# consumer can claim it. The high bit is reserved for this purpose;
# the remaining 63 bits encode the empty/filled epoch counter.
#
# The three cell primitives (`tryPublish` / `tryClaim` /
# `tryCloseOnEmpty`) consume them; `Segment` / `newSegment` carry a
# `cells: array[S, LCRQCell[T]]` field on the MPMC arm.
#
# The width invariant (`sizeof(LCRQCell[T]) == 16` for any `T` with
# `sizeof(T) == 8`) and the `CLOSED_BIT` bit position are guarded by
# `tests/t_lcrq_cell_alias.nim`.
# ----------------------------------------------------------------------
const CLOSED_BIT* = 1'u shl (sizeof(uint) * 8 - 1)
  ## Strict-LCRQ close sentinel. A cell with `seq == CLOSED_BIT`
  ## is permanently closed: no producer can publish into it, no
  ## consumer can claim it.
  ##
  ## The sentinel occupies the high bit of the platform-native `uint`
  ## so that `LCRQCell[T]` stays at native double-word width on every
  ## target debra supports (16 bytes on 64-bit, 8 bytes on 32-bit).
  ## On 64-bit (uint == uint64) the value is identical to `1'u64 shl 63`.

type LCRQCell*[T] = Atomic[Pair[uint, T]]
  ## Strict-LCRQ cell: native double-word DWCAS-able pair of seq counter
  ## (`Pair.first`) and payload (`Pair.second`). Transparent alias
  ## for `Atomic[Pair[uint, T]]` — assigning a `LCRQCell[T]` to /
  ## from the spelled-out type requires no conversion. Using
  ## platform-native `uint` (rather than hardcoded `uint64`) keeps
  ## the cell at the platform's native DWCAS width, preserving the
  ## lock-free guarantee on every debra-supported target.

# ----------------------------------------------------------------------
# Strict-LCRQ cell primitives.
#
# Three pure DWCAS primitives on `LCRQCell[T]`. Each is a single
# `compareExchangeStrong` wrapped in `dwcasOrderRelaxedCAS` to silence
# the nebr `validCasFailureOrder` warning that fires for the
# `success=moRelease, failure=moRelaxed` pair on DWCAS sites where the
# seq_cst-upgrade would be a perf footgun.
#
# Memory ordering (C11-strict, no upgrades):
#   tryPublish:        success = moRelease,        failure = moRelaxed
#   tryClaim:          success = moAcquireRelease, failure = moRelaxed
#   tryCloseOnEmpty:   success = moRelease,        failure = moRelaxed
#
# `tryClaim`'s seq-load uses `moAcquire` to synchronise-with the
# producer's `moRelease` publish — the CAS-failure ordering only
# governs the failure-path re-read, which we discard.
#
# Default-value contract: `tryClaim` NEVER inspects `observed.second`. The
# CAS on the seq encoding is the SOLE authority on cell state. A
# short-circuit like `if observed.second == default(T): return none(T)`
# would silently drop legitimate `q.push(0)` / `q.push(nil)` publishes;
# the production primitive does not.
#
# `expectedSeq` is invariantly `0` at current call sites (linked-segment
# specialization, R degenerate); the parameter is retained on the
# primitive signatures for a future ring-segment variant.
# ----------------------------------------------------------------------

proc tryPublish*[T](
    cell: var LCRQCell[T], expectedSeq: uint, value: T
): bool {.inline.} =
  ## Producer publish via DWCAS into an empty cell.
  ## Returns true on success (cell now `(expectedSeq+1, value)`).
  ## Returns false if the cell is already filled, closed, or at a
  ## different epoch.
  ##
  ## Precondition for nullable T (`ptr`, `ref`, `pointer`, `cstring`,
  ## `proc`, closures): `value` MUST NOT be nil. The std/options
  ## transport used by `tryClaim` (`some(val)`) asserts `not val.isNil`
  ## at runtime for nullable types; forbidding nil here surfaces the
  ## contract violation at the producer rather than as a delayed
  ## AssertionDefect inside an unrelated consumer's `tryClaim` call.
  ## `doAssert` (not `assert`) so the guard
  ## survives `-d:danger` builds. `when compiles(value.isNil)` covers
  ## every nullable type Nim exposes (broader than `T is ptr or ref`).
  when compiles(value.isNil):
    doAssert not value.isNil,
      "Queue: cannot push nil for nullable T (Option transport restriction)"
  var prev: Pair[uint, T]
  prev.first = expectedSeq
  var desired: Pair[uint, T]
  desired.first = expectedSeq + 1
  when compiles(desired.second = value):
    desired.second = value
  else:
    copyMem(addr desired.second, unsafeAddr value, sizeof(T))
  # On CAS failure, debra writes the observed pair into `prev`; we don't
  # re-read it — escalation re-loads via fresh cell.load at the call site
  # (queue.nim push/pop). Required for the degenerate-R encoding.
  dwcasOrderRelaxedCAS:
    result = compareExchangeStrong(cell, prev, desired, moRelease, moRelaxed)

proc tryClaim*[T](cell: var LCRQCell[T], expectedSeq: uint): Option[T] {.inline.} =
  ## Consumer claim via DWCAS.
  ##
  ## CONTRACT: NEVER inspect `observed.second`. The CAS on the seq
  ## encoding is the sole authority on cell state. A filled cell with
  ## payload `default(T)` (e.g. `q.push(0)`, `q.push(nil)`) is a
  ## legitimate publish and MUST be returned via `some(observed.second)`.
  var prev = load(cell, moAcquire)
  if prev.first != expectedSeq + 1:
    return none(T)
  var desired: Pair[uint, T]
  desired.first = prev.first
  dwcasOrderRelaxedCAS:
    if compareExchangeStrong(cell, prev, desired, moAcquireRelease, moRelaxed):
      return some(move(prev.second))
  return none(T)

proc tryCloseOnEmpty*[T](cell: var LCRQCell[T], expectedSeq: uint): bool {.inline.} =
  ## Consumer close-on-empty via DWCAS. Atomically sets
  ## `CLOSED_BIT` on an empty cell so no producer can later publish
  ## into it. Returns false if the cell is already filled or closed.
  var prev: Pair[uint, T]
  prev.first = expectedSeq
  var desired: Pair[uint, T]
  desired.first = expectedSeq or CLOSED_BIT
  # On CAS failure, debra writes the observed pair into `prev`; we don't
  # re-read it — escalation re-loads via fresh cell.load at the call site
  # (queue.nim push/pop). Required for the degenerate-R encoding.
  dwcasOrderRelaxedCAS:
    result = compareExchangeStrong(cell, prev, desired, moRelease, moRelaxed)

## ----------------------------------------------------------------------
## Middle-axis Lifecycle typestate.
##
## Tracks `QueueInit -> QueueDestroyed` on the unbounded Queue value.
## Parallel to `BQueue`'s Lifecycle typestate in `bqueue.nim` — same
## structural pattern, distinct context / state types because typestate
## attachments are unique per type (TA-004) and the bqueue/queue split
## demands independent lifecycles. Mirrors nebr
## `pinned_scope.nim` verbatim in shape.
##
## State-preserving discipline: every Queue
## state-preserving op (`push`, `pop`, `getProducer`, `getConsumer`,
## `retireOnCAS`, `retireOnPublish`, batch variants) declares NO
## `{.transition.}` pragma. They live in this module (queue.nim) so
## the same-module discipline is satisfied without `{.notATransition.}`.
##
## The terminal `QueueInit -> QueueDestroyed` transition is emitted by
## `=destroy` (further below in the file) via `destructorTransition`.
## ----------------------------------------------------------------------

type
  QueueLifecycleCtx*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
  ] = object of RootObj ## Phantom context type for the Queue Lifecycle typestate.

  QueueInit*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
  ] = distinct QueueLifecycleCtx[T, ccProd, ccCons, ST, S, MaxThreads]
    ## Initial Lifecycle state for an unbounded Queue.

  QueueDestroyed*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
  ] = distinct QueueLifecycleCtx[T, ccProd, ccCons, ST, S, MaxThreads]
    ## Terminal Lifecycle state for an unbounded Queue.

typestate QueueLifecycle[
  T,
  ccProd: static PinScopeCardinality,
  ccCons: static PinScopeCardinality,
  ST: static DeallocationStrategy,
  S: static int,
  MaxThreads: static int,
]:
  inheritsFromRootObj = true
  consumeOnTransition = false
  strictTransitions = false
  states:
    QueueInit[T, ccProd, ccCons, ST, S, MaxThreads]
    QueueDestroyed[T, ccProd, ccCons, ST, S, MaxThreads]
  initial:
    QueueInit[T, ccProd, ccCons, ST, S, MaxThreads]
  terminal:
    QueueDestroyed[T, ccProd, ccCons, ST, S, MaxThreads]
  transitions:
    QueueInit[T, ccProd, ccCons, ST, S, MaxThreads] ->
      QueueDestroyed[T, ccProd, ccCons, ST, S, MaxThreads]

type
  Segment*[T; ccProd, ccCons: static PinScopeCardinality, S: static int] = object
    ## Unbounded-queue segment. One linked-segment payload, parameterized
    ## by `(ccProd, ccCons)` so each cardinality variant's field set
    ## matches its per-family analogue.
    ##
    ## Field set:
    ##   - `data: array[S, T]` — slot storage (non-MPMC variants).
    ##   - `cells: array[S, LCRQCell[T]]` — strict-LCRQ cells (MPMC only).
    ##     Replaces `committed + data` on the `ccMulti × ccMulti` arm.
    ##   - `next: Atomic[ptr Segment[...]]` — linked-list pointer.
    ##   - `tail: Atomic[int]` — producer write index. Atomic for
    ##     multi-producer coordination and for spsc-equiv (publish
    ##     via release).
    ##   - `head: int` — single-consumer non-atomic read position.
    ##     Present on `(ccProd × ccSingle)` shapes (mpsc-equiv and
    ##     the absorbed spsc-equiv). Only the single consumer ever
    ##     writes it.
    ##   - `committed: array[S, Atomic[bool]]` — multi-producer
    ##     publication flags. Present on `ccProd == ccMulti and
    ##     ccCons == ccSingle` (MPSC only — MPMC migrated to `cells`).
    ##   - `prevConsumerIdx: Atomic[int]` — multi-consumer CAS slot.
    ##     Present on `ccCons == ccMulti`.
    when ccProd == ccMulti and ccCons == ccMulti:
      # MPMC: strict-LCRQ cells. Replaces committed+data.
      cells* {.align: CacheLineBytes.}: array[S, LCRQCell[SlotEncoding(T)]]
    elif ccProd == ccMulti:
      # MPSC (ccMulti × ccSingle): committed+data overlay (symmetric
      # with BQueue). Cells hold the Path-C SlotEncoding(T) wire form;
      # the user-facing T is encoded at push and decoded at pop via
      # internal/path_c_wrap.
      data*: array[S, SlotEncoding(T)]
    else:
      # SPSC + SPMC: data only, SlotEncoding(T) wire form.
      data*: array[S, SlotEncoding(T)]
    next* {.align: CacheLineBytes.}: Atomic[ptr Segment[T, ccProd, ccCons, S]]
    tail* {.align: CacheLineBytes.}: Atomic[int]
    when ccCons == ccSingle:
      # mpsc-equiv + absorbed spsc-equiv: single-consumer
      # non-atomic read position.
      head* {.align: CacheLineBytes.}: int
    when ccProd == ccMulti and ccCons == ccSingle:
      # MPSC-only multi-producer publication flags. MPMC migrated to
      # `cells` (above) where the seq counter subsumes commit-bit.
      committed* {.align: CacheLineBytes.}: array[S, Atomic[bool]]
    when ccCons == ccMulti:
      # spmc-equiv + mpmc-equiv: multi-consumer CAS coordination.
      prevConsumerIdx* {.align: CacheLineBytes.}: Atomic[int]

  Queue*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
  ] {.QueueLifecycle: QueueInit.} = object
    ## Unbounded lock-free queue, parameterized by producer/consumer
    ## cardinality, deallocation strategy `ST`, segment size `S`, and
    ## the debra registry capacity `MaxThreads`.
    ##
    ## Body layout splits on `(ccProd, ccCons) is (ccSingle, ccSingle)`:
    ##
    ##   - **spsc-absorbed** (ccSingle × ccSingle): no debra
    ##     integration. Linked-segment with committed-flag-free
    ##     SPSC protocol absorbed verbatim from the legacy
    ##     `UnboundedSpsc[S, T]` type. `MaxThreads` is a type-uniform
    ##     phantom — no thread-registry capacity is consumed.
    ##   - **non-spsc** (mpsc-/spmc-/mpmc-equiv): debra-
    ##     integrated. Owns `manager`, walks pin/retire chains in
    ##     `push`/`pop`. `MaxThreads` sizes the debra registry.
    when ccProd == ccSingle and ccCons == ccSingle:
      # Absorbed `UnboundedSpsc` body — no manager, no debra.
      headSegment* {.align: CacheLineBytes.}: Atomic[ptr Segment[T, ccProd, ccCons, S]]
      tailSegment* {.align: CacheLineBytes.}: Atomic[ptr Segment[T, ccProd, ccCons, S]]
      itemCount*: Atomic[int]
      segments*: Atomic[int]
    else:
      # Debra-integrated body. Manager CC is gated on `ccCons`:
      # nebr `cardinality.nim` REQUIRES `ccMulti` for consumer
      # pins on multi-consumer queues.
      when ccCons == ccMulti:
        manager*: ptr DebraManager[MaxThreads, nebr.ccMulti]
      else:
        manager*: ptr DebraManager[MaxThreads, nebr.ccSingle]
      headSegment* {.align: CacheLineBytes.}: Atomic[ptr Segment[T, ccProd, ccCons, S]]
      tailSegment* {.align: CacheLineBytes.}: Atomic[ptr Segment[T, ccProd, ccCons, S]]
      itemCount*: Atomic[int]
      segments*: Atomic[int]
      ownsManager*: bool
      when ccProd == ccMulti:
        producerCount*: Atomic[int]
      when ccCons == ccMulti:
        consumerCount*: Atomic[int]

## ----------------------------------------------------------------------
## Param-coherence guards — unbounded subset of legacy
##
## The legacy 9 guards covered both rkNone (6 guards) and rkEbr (3
## guards). The 6 rkNone guards moved to `bqueue.nim`
## (`assertBQueueParams`); the 3 rkEbr guards remain here.
## ----------------------------------------------------------------------

template assertQueueParams*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
]() =
  static:
    assert S > 0, "Queue requires S > 0 (segment slot count)"
  static:
    assert MaxThreads > 0,
      "Queue requires MaxThreads > 0 (debra thread-registry capacity)"

proc validateQueueParams*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](_: typedesc[Queue[T, ccProd, ccCons, ST, S, MaxThreads]]) =
  ## Compile-time entry point for the 2 param-coherence guards. Has no
  ## runtime cost.
  assertQueueParams[T, ccProd, ccCons, ST, S, MaxThreads]()
  discard

## ----------------------------------------------------------------------
## Unbounded-queue body — SPSC implementation
## ----------------------------------------------------------------------

proc newSegment[T; ccProd, ccCons: static PinScopeCardinality, S: static int](): ptr Segment[
  T, ccProd, ccCons, S
] =
  ## Allocate a new segment on a CacheLineBytes boundary so the
  ## `{.align.}` pragmas on `next` / `tail` / `committed` /
  ## `prevConsumerIdx` land on distinct physical cache lines.
  result = allocAligned[Segment[T, ccProd, ccCons, S]]()
  result.next.store(nil, moRelaxed)
  result.tail.store(0, moRelaxed)
  when ccCons == ccSingle:
    # mpsc-equiv + absorbed spsc-equiv carry a `head: int` field.
    result.head = 0
  when ccProd == ccMulti and ccCons == ccMulti:
    # MPMC strict-LCRQ: each cell starts in the empty state
    # `(seq=0, default(T))`. While `allocAligned` already returns
    # zero-initialized memory (so this loop is observationally a
    # no-op for the cell-shape we ship), the explicit relaxed store
    # is the correct-by-construction publication of the design's
    # empty-cell encoding and pins the invariant against any future
    # change to the allocator or to `default(T)` for non-trivial T.
    # Synchronization: relaxed is sufficient — the segment is not
    # visible to other threads until the producer/consumer link it
    # into the queue chain via a release-store.
    # Cells hold LCRQCell[SlotEncoding(T)], so the empty-state Pair
    # second must be `SlotEncoding(T)`, not the raw user-facing T:
    # using `T` directly compiles only when T is POD identity. For
    # ref / string / seq T the encoded form is ManagedRef /
    # ManagedSlice (distinct uint).
    for i in 0 ..< S:
      store(
        result.cells[i],
        Pair[uint, SlotEncoding(T)](first: 0'u, second: default(SlotEncoding(T))),
        moRelaxed,
      )
  elif ccProd == ccMulti:
    # MPSC: legacy committed flags init (unchanged).
    for i in 0 ..< S:
      result.committed[i].store(false, moRelaxed)
  when ccCons == ccMulti:
    result.prevConsumerIdx.store(-1, moRelaxed)

## ----------------------------------------------------------------------
## Pre-retire foreclosure helper (push-10 race fix).
##
## Invariant being enforced: a segment may be retired off `headSegment`
## ONLY AFTER every cell in `[fromIdx, S-1]` is permanently CLOSED — i.e.,
## no producer can ever publish a value into it. This eliminates the
## "producer publishes into retired segment" orphan documented in
## `docs/internal/push-10-lcrq-race-investigation.md`.
##
## The pre-existing slow-path inline scan (queue.nim ~1631) only closes
## cells in `[mySlot, observed_tail)`. Cells in `[observed_tail, S-1]`
## may be tail-CAS-reserved by in-flight producers whose `tryPublish`
## has not yet executed; retiring while those reservations remain
## allows the producer's later `tryPublish` to land in an orphaned
## segment, and no consumer ever revisits it (data loss).
##
## `forecloseSegmentForRetire(seg, fromIdx)` closes the full
## `[fromIdx, S-1]` range. If any cell is FILLED (`seq == 1`, not
## CLOSED) at scan-time, foreclosure returns `false` — the caller MUST
## abort the retire and route back through the outer pop loop so the
## fast-path can claim the value via prevConsumerIdx-CAS.
##
## Race interactions:
##  - Producer P reserved tail at index k, has NOT yet `tryPublish`'d:
##    foreclose's `tryCloseOnEmpty(k, 0)` succeeds. P's eventual
##    `tryPublish` fails → P escalates to `seg.next`. No orphan.
##  - Producer P has `tryPublish`'d (cell at k is `seq=1`):
##    foreclose returns `false`. Caller aborts retire. Outer loop's
##    fast-path will reach k via prevConsumerIdx-CAS and claim. No orphan.
##  - Producer P `tryPublish`'s between foreclose's load and CAS at k:
##    CAS fails (expected `seq=0`, actual `seq=1`); recheck shows
##    FILLED → return `false`. Caller aborts retire. Outer loop claims.
##
## Livelock argument: every iteration of the outer pop loop either
## claims a value (forward progress) OR foreclose returns true and
## retire fires (segment advance, also progress) OR foreclose returns
## false and the next iteration's fast-path claims the discovered
## FILLED cell. There is no path that loops without progress.
##
## Memory-leak argument: every segment becomes foreclosable in finite
## time because producers can only reserve up to `S` tail slots and
## each slot will either be claimed (advancing prevConsumerIdx) or
## closed (foreclose succeeds on next attempt).
## ----------------------------------------------------------------------

proc forecloseSegmentForRetire[T; S: static int](
    seg: ptr Segment[T, ccMulti, ccMulti, S], fromIdx: int
): bool =
  ## NOTE: `T` is the user-facing payload type; `seg.cells` holds
  ## `LCRQCell[SlotEncoding(T)]`. The DWCAS primitives are invoked on
  ## the wire type via `SlotEncoding(T)` to stay aligned with the
  ## producer/consumer call sites in push/pop.
  ## Pre-retire scan. Closes cells `[fromIdx, S-1]`. Returns:
  ##   - `true` if all cells in range are CLOSED (safe to retire).
  ##   - `false` if a FILLED-not-yet-CLOSED cell is observed (retire
  ##     would orphan it; caller must abort and let the outer loop's
  ##     fast-path claim it via prevConsumerIdx-CAS).
  ##
  ## Cells in range `[fromIdx, S-1]` are unaccounted-for by the caller
  ## (caller is at a retire site where prevConsumerIdx points at
  ## `fromIdx - 1`). A `seq == 1, not CLOSED_BIT` reading there means
  ## a producer has published into the cell but no consumer has
  ## claimed it yet — retiring would lose the value.
  var i = fromIdx
  while i < S:
    let cur = load(seg.cells[i], moAcquire)
    if seqIsClosed(cur.first):
      inc i
      continue
    if cur.first == 0'u:
      # Empty (possibly tail-CAS-reserved by a producer who hasn't
      # tryPublish'd yet). Race for the close.
      if tryCloseOnEmpty[SlotEncoding(T)](seg.cells[i], 0'u):
        inc i
        continue
      # CAS failed — either CLOSED by a concurrent consumer, or
      # producer just published. Re-read to discriminate.
      let recheck = load(seg.cells[i], moAcquire)
      if seqIsClosed(recheck.first):
        inc i
        continue
      # Producer published during our CAS attempt. Abort retire.
      return false
    # Cell is FILLED (seq != 0, not CLOSED). Abort retire — there is
    # an unconsumed value the outer loop must claim.
    return false
  return true

## ----------------------------------------------------------------------
## Per-queue retire wrappers — + γ guard.
##
## Defined only for non-spsc cardinalities (debra-integrated). Spsc-
## absorbed (`(ccSingle, ccSingle)`) has no debra integration and thus
## no retire-bearing site; UFCS lookup of `q.retireOn*` on a spsc
## queue fails with method-not-defined, which is the desired guard.
##
## `retireOnCAS` is callable under any consumer cardinality (DR-S3).
## `retireOnPublish` is additionally gated on `ccCons == ccSingle`
## (DR-S4 single-writer foot-gun). The spsc exclusion is also
## structurally enforced: spsc's `(ccCons == ccSingle)` could match
## `retireOnPublish`'s gate, but the receiver `var Queue[..., ccSingle,
## ccSingle, ...]` body lacks the segment-pointer atomics the wrapper
## consumes — the guard fires before any harm is done, and the
## documented design is that spsc is debra-free.
## ----------------------------------------------------------------------

proc retireOnCAS*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    CC: static nebr.PinScopeCardinality,
    S, MaxThreads: static int,
    U;
](
    q: var Queue[T, ccProd, ccCons, ST, S, MaxThreads],
    scope: var PinnedScope[MaxThreads, CC],
    atomic: var Atomic[U],
    expected: var U,
    desired: U,
    dtor: Destructor,
): bool {.discardable.} =
  ## Per-queue `retireOnCAS` wrapper. Delegates to nebr's
  ## `pinned_scope.retireOnCAS`.
  discard q
  scope.retireOnCAS(atomic, expected, desired, dtor)

proc retireOnPublish*[
    T;
    ccProd: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    CC: static nebr.PinScopeCardinality,
    S, MaxThreads: static int,
    U;
](
    q: var Queue[T, ccProd, ccSingle, ST, S, MaxThreads],
    scope: var PinnedScope[MaxThreads, CC],
    atomic: var Atomic[U],
    desired: U,
    dtor: Destructor,
) =
  ## Per-queue `retireOnPublish` wrapper. **FOOT-GUN — single-writer
  ## required (DR-S4).** Delegates to nebr's
  ## `pinned_scope.retireOnPublish`.
  discard q
  scope.retireOnPublish(atomic, desired, dtor)

# ---------------------------------------------------------------------
# Segment destructor — monomorphic-per-(T, ccProd, ccCons, S).
# ---------------------------------------------------------------------

proc segmentDestructor[T; ccProd, ccCons: static PinScopeCardinality, S: static int](
    p: pointer
) {.nimcall, raises: [].} =
  when not supportsCopyMem(T):
    let seg = cast[ptr Segment[T, ccProd, ccCons, S]](p)
    when ccProd == ccMulti and ccCons == ccMulti:
      # Strict-LCRQ cells: `LCRQCell[SlotEncoding(T)]`. For ref / string /
      # seq T the encoded payload is a ManagedRef / ManagedSlice that
      # owns either a refcount or a heap box and MUST be disposed at
      # destroy-walk time (the destroy-walk is the ONLY library-managed
      # cleanup path; pop is a pure transfer).
      # For POD T the outer `when not supportsCopyMem(T)` arm does not
      # fire, so this branch is reachable only for ref / string / seq.
      when T is ref or T is string or T is seq:
        for i in 0 ..< S:
          let cellPair = load(seg.cells[i], moRelaxed)
          # Disposing on a zero-bits slot (never published or already
          # claimed) is a no-op per disposeSlotEncoded contract.
          disposeSlotEncoded[T](cellPair.second)
    elif ccProd == ccMulti:
      # MPSC: legacy committed+data overlay; data holds SlotEncoding(T).
      when T is ref or T is string or T is seq:
        for i in 0 ..< S:
          disposeSlotEncoded[T](seg.data[i])
      else:
        for i in 0 ..< S:
          reset(seg.data[i])
    else:
      # SPSC + SPMC: data holds SlotEncoding(T).
      when T is ref or T is string or T is seq:
        for i in 0 ..< S:
          disposeSlotEncoded[T](seg.data[i])
      else:
        for i in 0 ..< S:
          reset(seg.data[i])
  freeAligned(p)

## ----------------------------------------------------------------------
## Constructors.
##
## Three overloads, distinguished by signature:
##   1. **typedesc-only** — auto-create. Allocates a manager internally
##      (non-spsc) or just initializes the body (spsc). Works for
##      all 4 cardinality combos.
##   2. **typedesc + manager + handle** — manager-borrowed for
##      ccCons==ccSingle. The handle is consumed by mpsc-equiv only.
##   3. **typedesc + manager** — manager-borrowed for ccCons==ccMulti.
##
## A 4th overload `{.error.}`-gates the manager-borrowed signature on
## spsc-absorbed (`(ccSingle, ccSingle)`) since debra is not used
## there.
## ----------------------------------------------------------------------

proc newQueue*[
    T;
    ccProd: static PinScopeCardinality,
    ST: static DeallocationStrategy = DefaultDeallocationStrategy,
    S, MaxThreads: static int,
](
    _: typedesc[Queue[T, ccProd, ccSingle, ST, S, MaxThreads]],
    manager: ptr DebraManager[MaxThreads, nebr.ccSingle],
    handle: ThreadHandle[MaxThreads, nebr.ccSingle],
): Queue[T, ccProd, ccSingle, ST, S, MaxThreads] =
  ## Manager-borrowed unbounded `newQueue` overload — ccCons == ccSingle
  ## variants (mpsc-equiv only; the spsc-absorbed `(ccSingle,
  ## ccSingle)` shape is debra-free and uses a separate `{.error.}`
  ## overload below).
  ##
  ## Caller owns the `DebraManager`. Sets `ownsManager = false`. The
  ## handle is consumed by mpsc-equiv (`ccProd == ccMulti`) and stored
  ## on the queue. ccProd-ccSingle spsc-equiv would be type-uniformly
  ## constructable here, but is excluded by the dedicated spsc
  ## `{.error.}` overload further below.
  validateQueueParams(Queue[T, ccProd, ccSingle, ST, S, MaxThreads])
  # ccProd == ccSingle here means spsc-absorbed, which is debra-free
  # and routes through the dedicated `{.error.}` overload below — so by
  # the time we reach this body, ccProd is effectively ccMulti
  # (mpsc-equiv).
  result.manager = manager
  result.ownsManager = false
  result.itemCount.store(0, moRelaxed)
  when ccProd == ccMulti:
    result.producerCount.store(0, moRelaxed)
  discard handle
  let seg = newSegment[T, ccProd, ccSingle, S]()
  result.headSegment.store(seg, moRelaxed)
  result.tailSegment.store(seg, moRelaxed)
  result.segments.store(1, moRelaxed)
  bindClient(manager[])

proc newQueue*[
    T;
    ccProd: static PinScopeCardinality,
    ST: static DeallocationStrategy = DefaultDeallocationStrategy,
    S, MaxThreads: static int,
](
    _: typedesc[Queue[T, ccProd, ccSingle, ST, S, MaxThreads]],
    manager: ptr DebraManager[MaxThreads, nebr.ccSingle],
): Queue[T, ccProd, ccSingle, ST, S, MaxThreads] =
  ## Handle-free manager-borrowed unbounded `newQueue` overload for
  ## ccCons == ccSingle (mpsc-equiv). The single consumer's debra
  ## handle is NOT registered here; the consumer thread registers itself
  ## via `attachConsumer()` before its first `pop`. The handle-carrying
  ## overload above remains the escape hatch for callers who register
  ## on the consumer thread and supply the handle directly.
  validateQueueParams(Queue[T, ccProd, ccSingle, ST, S, MaxThreads])
  result.manager = manager
  result.ownsManager = false
  result.itemCount.store(0, moRelaxed)
  when ccProd == ccMulti:
    result.producerCount.store(0, moRelaxed)
  let seg = newSegment[T, ccProd, ccSingle, S]()
  result.headSegment.store(seg, moRelaxed)
  result.tailSegment.store(seg, moRelaxed)
  result.segments.store(1, moRelaxed)
  bindClient(manager[])

proc newQueue*[
    T;
    ccProd: static PinScopeCardinality,
    ST: static DeallocationStrategy = DefaultDeallocationStrategy,
    S, MaxThreads: static int,
](
    _: typedesc[Queue[T, ccProd, ccMulti, ST, S, MaxThreads]],
    manager: ptr DebraManager[MaxThreads, nebr.ccMulti],
    handle: ThreadHandle[MaxThreads, nebr.ccMulti],
): Queue[T, ccProd, ccMulti, ST, S, MaxThreads] =
  ## Manager-borrowed unbounded `newQueue` overload — ccCons == ccMulti
  ## variants (spmc-equiv + mpmc-equiv).
  validateQueueParams(Queue[T, ccProd, ccMulti, ST, S, MaxThreads])
  result.manager = manager
  result.ownsManager = false
  result.itemCount.store(0, moRelaxed)
  when ccProd == ccMulti:
    result.producerCount.store(0, moRelaxed)
  result.consumerCount.store(0, moRelaxed)
  discard handle
  let seg = newSegment[T, ccProd, ccMulti, S]()
  result.headSegment.store(seg, moRelaxed)
  result.tailSegment.store(seg, moRelaxed)
  result.segments.store(1, moRelaxed)
  bindClient(manager[])

proc newQueue*[
    T;
    ccProd: static PinScopeCardinality,
    ST: static DeallocationStrategy = DefaultDeallocationStrategy,
    S, MaxThreads: static int,
](
    _: typedesc[Queue[T, ccProd, ccMulti, ST, S, MaxThreads]],
    manager: ptr DebraManager[MaxThreads, nebr.ccMulti],
): Queue[T, ccProd, ccMulti, ST, S, MaxThreads] =
  ## Handle-free manager-borrowed unbounded `newQueue` overload for
  ## ccCons == ccMulti (spmc-equiv and mpmc-equiv).
  validateQueueParams(Queue[T, ccProd, ccMulti, ST, S, MaxThreads])
  result.manager = manager
  result.ownsManager = false
  result.itemCount.store(0, moRelaxed)
  when ccProd == ccMulti:
    result.producerCount.store(0, moRelaxed)
  result.consumerCount.store(0, moRelaxed)
  let seg = newSegment[T, ccProd, ccMulti, S]()
  result.headSegment.store(seg, moRelaxed)
  result.tailSegment.store(seg, moRelaxed)
  result.segments.store(1, moRelaxed)
  bindClient(manager[])

# Spsc-absorbed manager-borrowed `{.error.}` gate. The spsc-absorbed
# `(ccSingle, ccSingle)` body is debra-free; routing through a borrow
# overload would mis-shape the body. error string references
# user-visible alias names only.
proc newQueue*[
    T;
    ST: static DeallocationStrategy,
    CC: static nebr.PinScopeCardinality,
    S, MaxThreads: static int,
](
    _: typedesc[Queue[T, ccSingle, ccSingle, ST, S, MaxThreads]],
    manager: ptr DebraManager[MaxThreads, CC],
    handle: ThreadHandle[MaxThreads, CC],
): Queue[T, ccSingle, ccSingle, ST, S, MaxThreads] {.
    error:
      "Spsc-absorbed Queue (ccSingle × ccSingle) is debra-free. " &
      "Use the typedesc-only newQueue(Queue[..., ccSingle, ccSingle, ST, S, MaxThreads]) " &
      "overload instead."
.} =
  discard

proc newQueue*[
    T;
    ST: static DeallocationStrategy,
    CC: static nebr.PinScopeCardinality,
    S, MaxThreads: static int,
](
    _: typedesc[Queue[T, ccSingle, ccSingle, ST, S, MaxThreads]],
    manager: ptr DebraManager[MaxThreads, CC],
): Queue[T, ccSingle, ccSingle, ST, S, MaxThreads] {.
    error:
      "Spsc-absorbed Queue (ccSingle × ccSingle) is debra-free. " &
      "Use the typedesc-only newQueue(Queue[..., ccSingle, ccSingle, ST, S, MaxThreads]) " &
      "overload instead."
.} =
  discard

proc newQueue*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy = DefaultDeallocationStrategy,
    S, MaxThreads: static int,
](
    _: typedesc[Queue[T, ccProd, ccCons, ST, S, MaxThreads]]
): Queue[T, ccProd, ccCons, ST, S, MaxThreads] =
  ## Auto-create unbounded `newQueue` overload. For the spsc-absorbed
  ## `(ccSingle, ccSingle)` branch this skips manager allocation
  ## entirely. For the other three cardinality combos, allocates a
  ## private `DebraManager[MaxThreads, ...]` and sets `ownsManager =
  ## true`.
  ##
  ## **No thread is registered at construction.** `registerThread` is
  ## thread-affine (stamps the calling thread + installs a signal
  ## handler on the calling OS thread), so registering here would
  ## mis-route the handle when the queue is later operated on a
  ## different thread. Each operating thread registers itself at
  ## attach-time: producers/consumers via `getProducer().attach()` /
  ## `getConsumer().attach()`, and the mpsc-equiv single consumer via
  ## `attachConsumer()` before its first `pop`.
  validateQueueParams(Queue[T, ccProd, ccCons, ST, S, MaxThreads])
  when ccProd == ccSingle and ccCons == ccSingle:
    # Spsc-absorbed: no manager, no debra. Allocate initial segment
    # and zero the counters; that's it.
    let seg = newSegment[T, ccSingle, ccSingle, S]()
    result.headSegment.store(seg, moRelaxed)
    result.tailSegment.store(seg, moRelaxed)
    result.itemCount.store(0, moRelaxed)
    result.segments.store(1, moRelaxed)
  else:
    when ccCons == ccMulti:
      let mgr = allocAligned[DebraManager[MaxThreads, nebr.ccMulti]]()
    else:
      let mgr = allocAligned[DebraManager[MaxThreads, nebr.ccSingle]]()
    # `allocAligned`'s zero-fill is not tracked by ARC/ORC, so a later
    # `mgr[] = initDebraManager[...]()` would run the `DebraManager`
    # `=destroy` on uninitialized storage. Mark the slot moved-from
    # first to match the NRVO discipline applied in
    # benchmarks/nim/adapters/lockfree_unbounded_*_adapter.nim.
    wasMoved(mgr[])
    var ok = false
    try:
      when ccCons == ccMulti:
        mgr[] = initDebraManager[MaxThreads, nebr.ccMulti]()
        result = newQueue(Queue[T, ccProd, ccCons, ST, S, MaxThreads], mgr)
      else:
        mgr[] = initDebraManager[MaxThreads, nebr.ccSingle]()
        # mpsc-equiv: no consumer handle registered here. The single
        # consumer calls `attachConsumer()` on its own thread.
        result = newQueue(Queue[T, ccProd, ccCons, ST, S, MaxThreads], mgr)
      result.ownsManager = true
      ok = true
    finally:
      if not ok:
        reset(mgr[])
        freeAligned(mgr)

## ----------------------------------------------------------------------
## len / segmentCount accessors.
## ----------------------------------------------------------------------

proc len*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](self: var Queue[T, ccProd, ccCons, ST, S, MaxThreads]): int =
  ## Number of items currently in the queue (atomic snapshot).
  result = self.itemCount.load(moRelaxed)

proc segmentCount*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](self: var Queue[T, ccProd, ccCons, ST, S, MaxThreads]): int =
  ## Number of segments currently allocated (atomic snapshot).
  result = self.segments.load(moRelaxed)

## ----------------------------------------------------------------------
## Push body — single-item.
##
## Per-cardinality dispatch via `when (ccProd, ccCons) is`:
##   - spsc-absorbed (ccSingle × ccSingle): no pin, no committed-flag;
##     simple tail/`next` linked-segment advance. Lifted verbatim from
##     the legacy `unbounded_spsc.nim` push.
##   - spmc-equiv (ccSingle × ccMulti): no pin (single producer),
##     simple tail advance.
##   - mpsc/mpmc-equiv (ccMulti × _): pin via
##     `pinScope(unpinned(self.handle))`, CAS slot claim with segment
##     growth on full.
## ----------------------------------------------------------------------

## ----------------------------------------------------------------------
## Pop body — single-item.
##
## carrier decision: pop lives on bare `Queue` for
## ccCons == ccSingle variants (spsc-absorbed + mpsc-equiv) and on
## `QueueConsumer` for ccCons == ccMulti variants (spmc-equiv,
## mpmc-equiv).
## ----------------------------------------------------------------------

# --- spsc-absorbed pop (ccSingle × ccSingle, direct on Queue, no pin) -----
proc pop*[T; ST: static DeallocationStrategy, S, MaxThreads: static int](
    self: var Queue[T, ccSingle, ccSingle, ST, S, MaxThreads]
): Option[T] =
  ## Spsc-absorbed pop — direct slot read + segment advance with
  ## `freeAligned(oldSeg)`. No pin (no retire-race; only one consumer
  ## ever runs, only one producer ever writes). Lifted verbatim from
  ## the unbounded SPSC pop path.
  # Path-C admission gate (25-row composition matrix + reject chain).
  # See internal/path_c_admit.nim for the verbatim REJECT messages
  # and the accept-arm dispatch (ref T / string / seq[U] / POD).
  pathCAdmit(T)

  var seg = self.headSegment.load(moAcquire)
  while true:
    let head = seg.head
    let tail = seg.tail.load(moAcquire)
    if head < tail:
      let value = move(seg.data[head])
      seg.head = head + 1
      discard self.itemCount.fetchSub(1, moRelaxed)
      # seg.data holds SlotEncoding(T).
      # Decode at the boundary so the returned Option[T] matches the
      # user-facing type. Legacy body returned `some(value)` directly,
      # which compiled only for POD T (where SlotEncoding(T) == T).
      # Non-POD T (string, seq, ref) requires the unwrap. Mirrors the
      # Bound-endpoint pop surface.
      return some(unwrapOrIdentity[T](value))
    let nextSeg = seg.next.load(moAcquire)
    if nextSeg == nil:
      return none(T)
    let oldSeg = seg
    self.headSegment.store(nextSeg, moRelease)
    seg = nextSeg
    discard self.segments.fetchSub(1, moRelaxed)
    freeAligned(oldSeg)



# --- batch pop (ccCons == ccSingle, direct on Queue) ----------------------
proc pop*[
    T;
    ccProd: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](self: var Queue[T, ccProd, ccSingle, ST, S, MaxThreads], count: int): Option[seq[T]] =
  ## Batch pop for ccCons == ccSingle. Thin loop over single-item pop.
  if unlikely(count <= 0):
    return none(seq[T])
  var items = newSeqOfCap[T](count)
  for _ in 0 ..< count:
    let v = self.pop()
    if v.isNone:
      break
    items.add(v.get)
  if items.len == 0:
    none(seq[T])
  else:
    some(items)

# --- spmc-equiv pop (ccSingle × ccMulti, via QueueConsumer, retireOnCAS) -
# alias name `QueueConsumer`.
proc pop*[
    T;
    ccProd: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](
    self: var Queue[T, ccProd, ccMulti, ST, S, MaxThreads]
): Option[T] {.
    error:
      "Direct pop on a multi-consumer Queue is not allowed. " &
      "Use q.getConsumerHere().pop() (same-thread sugar) or q.bindConsumer().pop() (one-shot SC consumer) to obtain a per-thread " &
      "Bound[T, Tag, Queue[...]] and pop through it."
.} =
  discard

# --- ccMulti-consumer compile-time gate on bare Queue batch pop ----------
proc pop*[
    T;
    ccProd: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](
    self: var Queue[T, ccProd, ccMulti, ST, S, MaxThreads], count: int
): Option[seq[T]] {.
    error:
      "Direct batch pop on a multi-consumer Queue is not allowed. " &
      "Use q.getConsumerHere().pop(count) (same-thread sugar) or q.bindConsumer().pop(count) (one-shot SC consumer) to obtain a per-thread " &
      "Bound[T, Tag, Queue[...]] and batch-pop through it."
.} =
  discard

## ----------------------------------------------------------------------
## ----------------------------------------------------------------------
## Destructors driving Lifecycle / Claim-state terminal transitions
##. Mirror BQueue's pattern.
## ----------------------------------------------------------------------

proc `=copy`*[
  T;
  ccProd, ccCons: static PinScopeCardinality,
  ST: static DeallocationStrategy,
  S, MaxThreads: static int,
](
  dst: var Queue[T, ccProd, ccCons, ST, S, MaxThreads],
  src: Queue[T, ccProd, ccCons, ST, S, MaxThreads],
) {.
  error:
    "Queue is non-copyable: it owns a `ptr Segment` chain and (for " &
    "non-spsc cardinalities) a `ptr DebraManager`. Copying would " &
    "alias these owned pointers and double-free / use-after-free at " &
    "`=destroy`. Move the Queue (it has `=destroy` move semantics) or " &
    "share it by `ptr`/`var` parameter instead."
.}
  ## Compile-time copy ban. A Queue owns heap state (segment chain +
  ## optionally the debra manager, recorded by `ownsManager`) that is
  ## reclaimed exactly once in `=destroy`. A field-wise copy would
  ## duplicate the owning `ptr`s and reclaim them twice. Move semantics
  ## (the implicit `=sink` synthesized alongside `=destroy`) remain
  ## available; only copies are rejected.

proc `=destroy`*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](
    self: var Queue[T, ccProd, ccCons, ST, S, MaxThreads]
) {.
    destructorTransition: QueueInit -> QueueDestroyed,
    transitionError:
      "Queue used after =destroy (lifecycle: QueueInit -> QueueDestroyed).",
    raises: []
.} =
  ## Destructor. Walks `headSegment` → `next` → ... freeing each
  ## segment. For non-spsc cardinalities, additionally unbinds the
  ## client refcount on the manager and (when `ownsManager`) runs the
  ## manager's destructor.
  ##
  ## Also drives the Lifecycle terminal transition
  ## (`QueueInit -> QueueDestroyed`) via `destructorTransition`.
  ##
  ## **Precondition:** all worker threads that attached to this queue
  ## must be joined before `=destroy` runs. debra 0.8.0 has no
  ## per-thread unregister; thread handles live until the manager is
  ## destroyed here. Destroying the queue while an attached worker is
  ## still pinning/popping is undefined. For shared-manager queues
  ## (`ownsManager == false`) the destructor only unbinds the client
  ## refcount; the manager is left intact for its owner to free.
  var seg = self.headSegment.load(moRelaxed)
  while seg != nil:
    let nextSeg = seg.next.load(moRelaxed)
    when not supportsCopyMem(T):
      when ccProd == ccMulti and ccCons == ccMulti:
        # Strict-LCRQ cells: `LCRQCell[SlotEncoding(T)]`. For ref /
        # string / seq T the encoded payload owns either a refcount or
        # a heap box and MUST be disposed at queue teardown: the
        # destroy-walk is the ONLY library-managed cleanup
        # path (pop is a pure transfer; abandoned items are caught
        # here).
        when T is ref or T is string or T is seq:
          for i in 0 ..< S:
            let cellPair = load(seg.cells[i], moRelaxed)
            disposeSlotEncoded[T](cellPair.second)
      elif ccProd == ccMulti:
        # MPSC: legacy committed+data overlay; data holds
        # SlotEncoding(T).
        when T is ref or T is string or T is seq:
          for i in 0 ..< S:
            disposeSlotEncoded[T](seg.data[i])
        else:
          for i in 0 ..< S:
            reset(seg.data[i])
      else:
        # SPSC + SPMC: data holds SlotEncoding(T).
        when T is ref or T is string or T is seq:
          for i in 0 ..< S:
            disposeSlotEncoded[T](seg.data[i])
        else:
          for i in 0 ..< S:
            reset(seg.data[i])
    freeAligned(seg)
    seg = nextSeg

  when not (ccProd == ccSingle and ccCons == ccSingle):
    if self.manager != nil:
      unbindClient(self.manager[])
      if self.ownsManager:
        reset(self.manager[])
        freeAligned(self.manager)

## ----------------------------------------------------------------------
## Family-named unbounded smart constructors — kept as thin wrappers.
##
## Every signature returns `Queue[...]`, never a backing type.
## ----------------------------------------------------------------------

proc newUnboundedSpscQueue*[
    T;
    ST: static DeallocationStrategy = DefaultDeallocationStrategy,
    S, MaxThreads: static int,
](): Queue[T, ccSingle, ccSingle, ST, S, MaxThreads] {.inline.} =
  ## Unbounded SPSC (`ccSingle × ccSingle`) auto-create
  ## smart-constructor. Skips manager allocation (SPSC has
  ## no debra integration).
  newQueue(Queue[T, ccSingle, ccSingle, ST, S, MaxThreads])

proc newUnboundedMpscQueue*[
    T;
    ST: static DeallocationStrategy = DefaultDeallocationStrategy,
    S, MaxThreads: static int,
](
    manager: ptr DebraManager[MaxThreads, nebr.ccSingle]
): Queue[T, ccMulti, ccSingle, ST, S, MaxThreads] {.inline.} =
  ## Unbounded MPSC (`ccMulti × ccSingle`) borrow
  ## smart-constructor — manager-only form. The consumer thread calls
  ## `q.bindConsumer()` on its own thread to register and obtain its
  ## `Bound` endpoint.
  ##
  ## The consumer's debra handle is owned by `Bound` (opaque storage).
  ## `bindConsumer` wraps registration + binding in one call.
  newQueue(Queue[T, ccMulti, ccSingle, ST, S, MaxThreads], manager)

proc newUnboundedMpscQueue*[
    T;
    ST: static DeallocationStrategy = DefaultDeallocationStrategy,
    S, MaxThreads: static int,
](): Queue[T, ccMulti, ccSingle, ST, S, MaxThreads] {.inline.} =
  ## Unbounded mpsc-equivalent (`ccMulti × ccSingle`) auto-create
  ## smart-constructor. No thread is registered at construction: the
  ## consumer thread calls `attachConsumer()` and producer threads call
  ## `getProducer().attach()` on their own threads.
  newQueue(Queue[T, ccMulti, ccSingle, ST, S, MaxThreads])

proc newUnboundedSpmcQueue*[
    T;
    ST: static DeallocationStrategy = DefaultDeallocationStrategy,
    S, MaxThreads: static int,
](
    manager: ptr DebraManager[MaxThreads, nebr.ccMulti]
): Queue[T, ccSingle, ccMulti, ST, S, MaxThreads] {.inline.} =
  ## Unbounded spmc-equivalent (`ccSingle × ccMulti`) borrow
  ## smart-constructor.
  newQueue(Queue[T, ccSingle, ccMulti, ST, S, MaxThreads], manager)

proc newUnboundedSpmcQueue*[
    T;
    ST: static DeallocationStrategy = DefaultDeallocationStrategy,
    S, MaxThreads: static int,
](): Queue[T, ccSingle, ccMulti, ST, S, MaxThreads] {.inline.} =
  ## Unbounded spmc-equivalent (`ccSingle × ccMulti`) auto-create
  ## smart-constructor.
  newQueue(Queue[T, ccSingle, ccMulti, ST, S, MaxThreads])

proc newUnboundedMpmcQueue*[
    T;
    ST: static DeallocationStrategy = DefaultDeallocationStrategy,
    S, MaxThreads: static int,
](
    manager: ptr DebraManager[MaxThreads, nebr.ccMulti]
): Queue[T, ccMulti, ccMulti, ST, S, MaxThreads] {.inline.} =
  ## Unbounded mpmc-equivalent (`ccMulti × ccMulti`) borrow
  ## smart-constructor.
  newQueue(Queue[T, ccMulti, ccMulti, ST, S, MaxThreads], manager)

proc newUnboundedMpmcQueue*[
    T;
    ST: static DeallocationStrategy = DefaultDeallocationStrategy,
    S, MaxThreads: static int,
](): Queue[T, ccMulti, ccMulti, ST, S, MaxThreads] {.inline.} =
  ## Unbounded mpmc-equivalent (`ccMulti × ccMulti`) auto-create
  ## smart-constructor.
  newQueue(Queue[T, ccMulti, ccMulti, ST, S, MaxThreads])

## ----------------------------------------------------------------------
## Push / pop on Bound endpoints.
##
## QueueProducer/QueueConsumer push/pop bodies live on
## `Bound[T, Tag, Queue[T, ccProd, ccCons, ST, S, MaxThreads]]`
## receivers. The Bound endpoint carries opaque handle storage
## (`handleManager: pointer` + `handleIdx: int`); for the ccProd==ccMulti
## paths that need `pinScope(unpinned(handle))` the typed
## `ThreadHandle[MaxThreads, CC]` is reconstructed via cast at the call
## site (`when compiles(self.queue.manager)` gate + manager-pointer
## introspection — mirror of the onClose pattern in endpoint.nim).
##
## SPSC-absorbed and SPMC-equiv push paths are debra-free; they ignore
## the handle storage entirely.
## ----------------------------------------------------------------------

proc push*[
    T;
    Tag: SpscProducerTag | MpmcProducerTag | AnyThreadTag,
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](
    self: Bound[T, Tag, Queue[T, ccProd, ccCons, ST, S, MaxThreads]], item: sink T
) {.tags: [Tag, TypestateOp, RootEffect], raises: [], notATransition.} =
  ## Push a single item onto the unbounded queue (cardinality-dispatched).
  # Path-C admission gate (25-row composition matrix + reject chain).
  # Rejects: distinct ref alias (row 7), nested ref (row 8), value types
  # with managed fields, unsupported T. Accepts: ref T, string, seq[U]
  # (with R7 element guard), POD. See internal/path_c_admit.nim.
  pathCAdmit(T)
  when ccProd == ccMulti and ccCons == ccMulti:
    # Strict-LCRQ T-constraint enforcement. Unbounded MPMC publishes
    # via 128-bit DWCAS into `Atomic[Pair[uint, SlotEncoding(T)]]`; the
    # wire-form payload must fit alongside the 64-bit seq counter.
    #
    # ref T / string / seq[U] are lowered to ManagedRef /
    # ManagedSlice (sizeof(uint), POD via `distinct uint`) by
    # SlotEncoding, so the size+copyability constraint is satisfied
    # transparently. The static guard below applies only to the POD
    # identity arm (where T is neither ref / string / seq) — there
    # the user T must still fit in sizeof(uint). The legacy
    # ``not supportsCopyMem(T)`` hard error is subsumed by Path-C
    # admit (rejects unsupported value-types with managed fields).
    static:
      when not (T is ref or T is string or T is seq):
        when sizeof(T) > sizeof(uint):
          {.
            error: """
Queue[T, ccMulti, ccMulti, ...] requires sizeof(T) <= sizeof(uint) starting
in v5.0.0 (8 bytes on 64-bit targets, 4 bytes on 32-bit). The strict-LCRQ
migration uses double-word CAS (Atomic[Pair[uint, T]]); on 64-bit hardware
this is 128-bit DWCAS, on 32-bit it is 64-bit. T must fit alongside the
platform-native seq counter.
For wide T payloads, use BQueue[T] (bounded MPMC, Vyukov per-slot seq)
which preserves move-only T support. See CHANGELOG.md v5.0.0 BREAKING.
"""
          .}
  when defined(debug):
    assert self.attachedTid == getThreadId(),
      "push from wrong thread (must match bindToThread thread)"

  when ccProd == ccSingle and ccCons == ccSingle:
    # SPSC-absorbed — no pin, no committed flag, no debra.
    var seg = self.queue.tailSegment.load(moRelaxed)
    # Single load: `tail` doubles as the write index. The grow branch
    # sets `tail = 0` explicitly (mirroring the SPMC arm below) rather
    # than re-loading the fresh segment's tail. Single producer, so no
    # peer can advance `tail` between these statements.
    var tail = seg.tail.load(moRelaxed)
    if tail >= S:
      let newSeg = newSegment[T, ccProd, ccCons, S]()
      seg.next.store(newSeg, moRelease)
      self.queue.tailSegment.store(newSeg, moRelease)
      seg = newSeg
      tail = 0
      discard self.queue.segments.fetchAdd(1, moRelaxed)
    # data[] holds SlotEncoding(T); encode at the boundary.
    seg.data[tail] = wrapOrIdentity[T](item)
    seg.tail.store(tail + 1, moRelease)
    discard self.queue.itemCount.fetchAdd(1, moRelaxed)
  elif ccProd == ccSingle and ccCons == ccMulti:
    # spmc-equiv — single producer, no pin.
    var seg = self.queue.tailSegment.load(moRelaxed)
    var tail = seg.tail.load(moRelaxed)
    if tail >= S:
      let newSeg = newSegment[T, ccProd, ccCons, S]()
      seg.next.store(newSeg, moRelease)
      self.queue.tailSegment.store(newSeg, moRelease)
      seg = newSeg
      tail = 0
      discard self.queue.segments.fetchAdd(1, moRelaxed)
    # data[] holds SlotEncoding(T); encode at the boundary.
    seg.data[tail] = wrapOrIdentity[T](item)
    seg.tail.store(tail + 1, moRelease)
    discard self.queue.itemCount.fetchAdd(1, moRelaxed)
  else:
    # ccProd == ccMulti — mpsc/mpmc-equiv: pin claim required.
    type MgrT = typeof(self.queue.manager[])
    let mgr = cast[ptr MgrT](self.handleManager)
    type Handle = ThreadHandle[MgrT.MaxThreads, MgrT.CC]
    let h = Handle(idx: self.handleIdx, manager: mgr)
    # Encode `item` ONCE here so the retry loop below reuses
    # the same SlotEncoding(T) value across iterations. Moving `item`
    # inside the loop would leave it wasMoved on subsequent retries.
    # On success, `encoded`'s bits are transferred into the cell; on
    # all-fail paths the `encoded` local goes out of scope and its
    # ``=destroy`` drops the resource per managed_slice / managed_ref
    # contract.
    var encoded {.used.} = wrapOrIdentity[T](item)
    block:
      var scope {.used.} = pinScope(unpinned(h))
      var spins = InitialSpin
      while true:
        var seg = self.queue.tailSegment.load(moAcquire)
        var tail = seg.tail.load(moAcquire)
        if tail >= S:
          let nextSeg = seg.next.load(moAcquire)
          if nextSeg == nil:
            let newSeg = newSegment[T, ccProd, ccCons, S]()
            var expectedNext: ptr Segment[T, ccProd, ccCons, S] = nil
            if seg.next.compareExchange(expectedNext, newSeg, moRelease, moRelaxed):
              var expectedSeg = seg
              discard self.queue.tailSegment.compareExchange(
                expectedSeg, newSeg, moRelease, moRelaxed
              )
              discard self.queue.segments.fetchAdd(1, moRelaxed)
              continue
            else:
              freeAligned(newSeg)
              backoffOnRetry(spins)
              continue
          else:
            var expectedSeg = seg
            discard self.queue.tailSegment.compareExchange(
              expectedSeg, nextSeg, moRelease, moRelaxed
            )
            continue
        var expected = tail
        if seg.tail.compareExchange(expected, tail + 1, moAcquire, moRelaxed):
          when ccCons == ccMulti:
            # Strict-LCRQ MPMC publish via DWCAS into `cells[tail]`.
            # `expectedSeq = 0` is the invariant at current call sites
            # (linked-segment specialization, R degenerate).
            # cells hold `LCRQCell[SlotEncoding(T)]`; encode
            # done above the loop. ``encoded`` is reused across retries
            # because tryPublish takes ``value: T`` by-copy (NOT sink),
            # so failure paths preserve the local for the next attempt.
            if not tryPublish[SlotEncoding(T)](
              seg.cells[tail], 0'u, encoded
            ):
              # Close-CAS-on-empty arbitration.
              # tryPublish failed: the cell either holds `CLOSED_BIT`
              # (a peer consumer's slow-path `tryCloseOnEmpty` won the
              # DWCAS in the gap between our tail-CAS reservation and
              # this publish), or — defensively — is at some other
              # unexpected seq value. Re-load with moAcquire to
              # discriminate.
              let observed = load(seg.cells[tail], moAcquire)
              if seqIsClosed(observed.first):
                # Cell closed by consumer. The close is a permanent
                # contract, not a transient failure: the producer MUST
                # escalate to `seg.next`, allocating + linking if not
                # yet present. Re-uses the existing alloc-and-link
                # pattern from the `tail >= S` branch above. Tail
                # reservation stands as a skip-marker for any
                # consumer that visits this slot — they observe
                # CLOSED_BIT and inline-skip past it.
                let nextSeg = seg.next.load(moAcquire)
                if nextSeg == nil:
                  let newSeg = newSegment[T, ccProd, ccCons, S]()
                  var expectedNext: ptr Segment[T, ccProd, ccCons, S] = nil
                  if seg.next.compareExchange(
                    expectedNext, newSeg, moRelease, moRelaxed
                  ):
                    var expectedSeg = seg
                    discard self.queue.tailSegment.compareExchange(
                      expectedSeg, newSeg, moRelease, moRelaxed
                    )
                    discard self.queue.segments.fetchAdd(1, moRelaxed)
                    # No local `seg = newSeg`: the `continue` re-enters
                    # the loop head, which re-reads `seg` from
                    # `tailSegment` (the authoritative value). Escalation
                    # correctness rests on the tailSegment-CAS above, not
                    # on a carried-forward local.
                    continue
                  else:
                    # A peer linked seg.next first; free our
                    # speculative allocation and use what's there.
                    freeAligned(newSeg)
                    let linkedNext = seg.next.load(moAcquire)
                    var expectedSeg = seg
                    discard self.queue.tailSegment.compareExchange(
                      expectedSeg, linkedNext, moRelease, moRelaxed
                    )
                    continue
                else:
                  var expectedSeg = seg
                  discard self.queue.tailSegment.compareExchange(
                    expectedSeg, nextSeg, moRelease, moRelaxed
                  )
                  continue
              # Not CLOSED_BIT — should not occur given tail-CAS
              # reservation discipline (we hold the reservation;
              # only `tryCloseOnEmpty` competes for the DWCAS-empty
              # transition). Defensive fall-through: retry outer
              # loop.
              continue
          else:
            # MPSC: committed+data publish. data holds
            # SlotEncoding(T); store the encoded form. The MPSC retry
            # loop only re-enters this branch on a tail-CAS miss
            # ABOVE the publish — if we reach here, this is the
            # publish path and runs exactly once per push call. (The
            # MPSC retry happens at the `continue` near the tail-CAS,
            # not after publish.)
            seg.data[tail] = encoded
            seg.committed[tail].store(true, moRelease)
          discard self.queue.itemCount.fetchAdd(1, moRelaxed)
          break

proc push*[
    T;
    Tag: SpscProducerTag | MpmcProducerTag | AnyThreadTag,
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](
    self: Bound[T, Tag, Queue[T, ccProd, ccCons, ST, S, MaxThreads]],
    items: openArray[T],
) {.tags: [Tag, TypestateOp, RootEffect], raises: [], notATransition.} =
  ## Batch push (thin loop).
  for item in items:
    self.push(item)

# --- SPSC / MPSC pop on Bound (ccCons == ccSingle: no pin) ----------------
proc pop*[
    T;
    Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag,
    ccProd: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](
    self: Bound[T, Tag, Queue[T, ccProd, ccSingle, ST, S, MaxThreads]]
): Option[T] {.tags: [Tag, TypestateOp, RootEffect], raises: [], notATransition.} =
  ## Pop for `ccCons == ccSingle` (SPSC + MPSC). Single consumer thread,
  ## no pin required. Body consolidates the two direct-on-Queue pop
  ## overloads with cardinality dispatch via the existing `when` arms.
  # Path-C admission gate (25-row composition matrix + reject chain).
  # Rejects: distinct ref alias (row 7), nested ref (row 8), value types
  # with managed fields, unsupported T. Accepts: ref T, string, seq[U]
  # (with R7 element guard), POD. See internal/path_c_admit.nim.
  pathCAdmit(T)
  when defined(debug):
    assert self.attachedTid == getThreadId(), "pop from wrong thread"

  var seg = self.queue.headSegment.load(moAcquire)
  when ccProd == ccSingle:
    # SPSC-absorbed: head advances on the consumer side; no committed flag.
    while true:
      let head = seg.head
      let tail = seg.tail.load(moAcquire)
      if head < tail:
        # data[] holds SlotEncoding(T); move out and decode.
        let encoded = move(seg.data[head])
        seg.head = head + 1
        discard self.queue.itemCount.fetchSub(1, moRelaxed)
        return some(unwrapOrIdentity[T](encoded))
      let nextSeg = seg.next.load(moAcquire)
      if nextSeg == nil:
        return none(T)
      let oldSeg = seg
      self.queue.headSegment.store(nextSeg, moRelease)
      seg = nextSeg
      discard self.queue.segments.fetchSub(1, moRelaxed)
      freeAligned(oldSeg)
  else:
    # MPSC: ccMulti producer × ccSingle consumer. The single consumer
    # owns the head walk but still pins the epoch via debra so
    # `retireOnPublish` knows a reader holds a segment. Single-consumer
    # cardinality avoids consumer-vs-consumer CAS coordination; it does
    # NOT avoid the epoch pin.
    type MgrT = typeof(self.queue.manager[])
    let mgr = cast[ptr MgrT](self.handleManager)
    type Handle = ThreadHandle[MgrT.MaxThreads, MgrT.CC]
    let h = Handle(idx: self.handleIdx, manager: mgr)
    block:
      var scope = pinScope(unpinned(h))
      while true:
        let tail = seg.tail.load(moAcquire)
        if seg.head < tail:
          if seg.committed[seg.head].load(moAcquire):
            # data[] holds SlotEncoding(T); decode on the way out.
            result = some(unwrapOrIdentity[T](move(seg.data[seg.head])))
            inc seg.head
            discard self.queue.itemCount.fetchSub(1, moRelaxed)
          # Deliberate transient-empty return: when `head < tail` but the
          # committed flag at `head` is not yet visible, a producer has
          # reserved the slot via tail-bump but has not finished
          # publishing. This is the producer-reserved-but-unpublished
          # window. Unlike the MPMC pop (which spins a bounded
          # `waitForPublish` budget for exactly this race, CRIT-1), the
          # non-blocking MPSC pop returns `none(T)` here rather than
          # waiting — matching the documented non-blocking contract. A
          # caller draining with `while pop().isNone: ...` may therefore
          # observe a spurious empty while an item is mid-publish; the
          # single-consumer drain contract assumes producers have joined
          # before the final drain, so the window is closed by the time a
          # genuine end-of-stream `none` is returned.
          break
        let nextSeg = seg.next.load(moAcquire)
        if nextSeg == nil:
          break
        self.queue[].retireOnPublish(
          scope,
          self.queue.headSegment,
          nextSeg,
          segmentDestructor[T, ccMulti, ccSingle, S],
        )
        when ST != stManual:
          discard self.queue.segments.fetchSub(1, moRelaxed)
        seg = nextSeg
    when ST == stEager:
      if h.advanceEvery(LockFreeQueuesAdvanceEvery):
        discard reclaimNow(h)

# --- Batch pop on Bound for ccCons == ccSingle (SPSC + MPSC) -------------
proc pop*[
    T;
    Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag,
    ccProd: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](
    self: Bound[T, Tag, Queue[T, ccProd, ccSingle, ST, S, MaxThreads]], count: int
): Option[seq[T]] {.tags: [Tag, TypestateOp, RootEffect], raises: [], notATransition.} =
  ## Batch pop for ccCons==ccSingle. Thin loop over single-item pop.
  if unlikely(count <= 0):
    return none(seq[T])
  var items = newSeqOfCap[T](count)
  for _ in 0 ..< count:
    let v = self.pop()
    if v.isNone:
      break
    items.add(v.get)
  if items.len == 0:
    none(seq[T])
  else:
    some(items)

# --- SPMC pop on Bound (ccSingle producer × ccMulti consumer) ------------
proc pop*[
    T;
    Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](
    self: Bound[T, Tag, Queue[T, ccSingle, ccMulti, ST, S, MaxThreads]]
): Option[T] {.tags: [Tag, TypestateOp, RootEffect], raises: [], notATransition.} =
  ## SPMC pop — retire-bearing site. Pin claim via reconstructed
  ## ThreadHandle from opaque Bound storage.
  ##
  ## DEBRA Pin–Claim Ordering Invariant (both topologies):
  ##
  ## 1. Pin opens BEFORE headSegment.load (this `pinScope` scope).
  ## 2. Pin covers slot reservation through readItem/extract window
  ##    (`prevConsumerIdx.compareExchange` -> `move(seg.data[mySlot])` in SPMC;
  ##    `prevConsumerIdx.compareExchange` -> `tryClaim` DWCAS in MPMC).
  ## 3. Segment under pin == segment under claim (pointer linearity).
  ## 4. headSegment advance (`retireOnCAS`) retires oldSeg via DEBRA; oldSeg is
  ##    not freed until all pins in its retire-epoch rotate.
  ## 5. Bulk variant acquires per-call pin satisfying (1)–(4).
  ## 6. Pin coverage (topology-conditional):
  ##
  ##    a. Consumer (both SPMC and MPMC): pin opens BEFORE the consumer's slot
  ##       claim / close-CAS in `pop`, and remains open THROUGH the claim/close
  ##       completion AND the subsequent item extraction or segment transition.
  ##       Same `pinScope` as the `headSegment.load` that produced the segment
  ##       pointer.
  ##
  ##    b. MPMC producer: push publish-CAS occurs within the same `pinScope`
  ##       as the `tailSegment.load` that produced the segment pointer.
  ##       Required because peer producers can retire the segment under us
  ##       via headSegment-advance (peer-producer retire race).
  ##       Implementation: MPMC push wraps the retry loop in `pinScope`.
  ##
  ##    c. SPMC producer: push does NOT require `pinScope`. Single-producer
  ##       immunity: no peer producer can retire the segment under us.
  ##       Implementation: SPMC push explicitly opts out of `pinScope`.
  ##
  ## DO NOT alter pinScope without re-establishing this invariant.
  # Path-C admission gate (25-row composition matrix + reject chain).
  # Rejects: distinct ref alias (row 7), nested ref (row 8), value types
  # with managed fields, unsupported T. Accepts: ref T, string, seq[U]
  # (with R7 element guard), POD. See internal/path_c_admit.nim.
  pathCAdmit(T)
  when defined(debug):
    assert self.attachedTid == getThreadId(), "pop from wrong thread"

  type MgrT = typeof(self.queue.manager[])
  let mgr = cast[ptr MgrT](self.handleManager)
  type Handle = ThreadHandle[MgrT.MaxThreads, MgrT.CC]
  let h = Handle(idx: self.handleIdx, manager: mgr)

  block:
    var scope = pinScope(unpinned(h))
    var seg = self.queue.headSegment.load(moAcquire)
    var spins = InitialSpin
    while true:
      # Producer payload publication HB rides on tail: producer stores
      # seg.data[tail] before tail.store(tail+1, moRelease). Acquire load
      # here establishes happens-before for all slots < tail.
      let tail = seg.tail.load(moAcquire)
      var prevIdx = seg.prevConsumerIdx.load(moAcquire)
      let mySlot = prevIdx + 1
      if mySlot >= tail:
        let nextSeg = seg.next.load(moAcquire)
        if nextSeg == nil:
          break
        if self.queue[].retireOnCAS(
          scope,
          self.queue.headSegment,
          seg,
          nextSeg,
          segmentDestructor[T, ccSingle, ccMulti, S],
        ):
          when ST != stManual:
            discard self.queue.segments.fetchSub(1, moRelaxed)
          seg = nextSeg
        else:
          seg = self.queue.headSegment.load(moAcquire)
        backoffOnRetry(spins)
        continue

      # Multi-consumer slot reservation. Acquire ordering on prevConsumerIdx-CAS
      # synchronizes among peer consumers so each slot is claimed at most once.
      # Note: payload publication HB does NOT ride on prevConsumerIdx; it rides
      # on the single producer's tail.store(moRelease) paired with tail.load(moAcquire)
      # above (mySlot < tail ensures seg.data[mySlot] is already published and visible).
      if seg.prevConsumerIdx.compareExchange(prevIdx, mySlot, moAcquire, moRelaxed):
        # data[] holds SlotEncoding(T); decode on the way out.
        result = some(unwrapOrIdentity[T](move(seg.data[mySlot])))
        discard self.queue.itemCount.fetchSub(1, moRelaxed)
        break

  when ST == stEager:
    if h.advanceEvery(LockFreeQueuesAdvanceEvery):
      discard reclaimNow(h)

# --- MPMC pop on Bound (ccMulti producer × ccMulti consumer) --------------
proc pop*[
    T;
    Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](
    self: Bound[T, Tag, Queue[T, ccMulti, ccMulti, ST, S, MaxThreads]]
): Option[T] {.tags: [Tag, TypestateOp, RootEffect], raises: [], notATransition.} =
  ## MPMC pop — retire-bearing site.
  ##
  ## DEBRA Pin–Claim Ordering Invariant (both topologies):
  ##
  ## 1. Pin opens BEFORE headSegment.load (this `pinScope` scope).
  ## 2. Pin covers slot reservation through readItem/extract window
  ##    (`prevConsumerIdx.compareExchange` -> `move(seg.data[mySlot])` in SPMC;
  ##    `prevConsumerIdx.compareExchange` -> `tryClaim` DWCAS in MPMC).
  ## 3. Segment under pin == segment under claim (pointer linearity).
  ## 4. headSegment advance (`retireOnCAS`) retires oldSeg via DEBRA; oldSeg is
  ##    not freed until all pins in its retire-epoch rotate.
  ## 5. Bulk variant acquires per-call pin satisfying (1)–(4).
  ## 6. Pin coverage (topology-conditional):
  ##
  ##    a. Consumer (both SPMC and MPMC): pin opens BEFORE the consumer's slot
  ##       claim / close-CAS in `pop`, and remains open THROUGH the claim/close
  ##       completion AND the subsequent item extraction or segment transition.
  ##       Same `pinScope` as the `headSegment.load` that produced the segment
  ##       pointer.
  ##
  ##    b. MPMC producer: push publish-CAS occurs within the same `pinScope`
  ##       as the `tailSegment.load` that produced the segment pointer.
  ##       Required because peer producers can retire the segment under us
  ##       via headSegment-advance (peer-producer retire race).
  ##       Implementation: MPMC push wraps the retry loop in `pinScope`.
  ##
  ##    c. SPMC producer: push does NOT require `pinScope`. Single-producer
  ##       immunity: no peer producer can retire the segment under us.
  ##       Implementation: SPMC push explicitly opts out of `pinScope`.
  ##
  ## DO NOT alter pinScope without re-establishing this invariant.
  # Path-C admission gate (25-row composition matrix + reject chain).
  # Rejects: distinct ref alias (row 7), nested ref (row 8), value types
  # with managed fields, unsupported T. Accepts: ref T, string, seq[U]
  # (with R7 element guard), POD. See internal/path_c_admit.nim.
  pathCAdmit(T)
  when defined(debug):
    assert self.attachedTid == getThreadId(), "pop from wrong thread"

  type MgrT = typeof(self.queue.manager[])
  let mgr = cast[ptr MgrT](self.handleManager)
  type Handle = ThreadHandle[MgrT.MaxThreads, MgrT.CC]
  let h = Handle(idx: self.handleIdx, manager: mgr)

  block:
    var scope = pinScope(unpinned(h))
    var seg = self.queue.headSegment.load(moAcquire)
    # Exponential CAS-retry backoff budget. Reset to `InitialSpin` on
    # every segment-advance (each `seg = nextSeg` / `seg = headSegment`
    # site below) so a pop() that crosses several contended segments does
    # not carry a saturated spin count forward and degrade into a yield
    # storm on a fresh segment. The inner publish-wait uses its own
    # independent `waitBackoff` (see the `waitForPublish` block).
    var spins = InitialSpin
    # Per-pop-call close counter that accumulates closes across
    # outer-loop iterations within a SINGLE pop() call. Reset to 0 on
    # every segment-advance (every `seg = nextSeg` site below). When it
    # reaches the segment size `S`, the consumer falls through to the
    # nextSeg advance path even if cells remain unclosed — this prevents
    # low-throughput consumers from livelocking on a partially-closed
    # segment. (`S` is the starvation cutoff; there is no separate
    # `StarvingThreshold` constant — the threshold is fixed to segment
    # capacity.)
    var closesSeenThisSegment = 0
    while true:
      let tail = seg.tail.load(moAcquire)
      var prevIdx = seg.prevConsumerIdx.load(moAcquire)
      var mySlot = prevIdx + 1
      if mySlot >= tail:
        # Strict-LCRQ slow-path: tail may have raced past mySlot
        # between the two loads. Drive tryCloseOnEmpty on the empty
        # cell so a stalled producer cannot strand this consumer, and
        # inline-skip closed cells within the same pop() call.
        if mySlot < S and seg.tail.load(moAcquire) > mySlot:
          # Nested inline-skip scan. `mySlot` advances monotonically
          # past closed cells until we either (a) hit a publishable
          # cell — break out to retry outer loop where the fast-path
          # will claim it; (b) exhaust the starvation budget (the
          # segment size `S`) — break out to fall through to the
          # nextSeg-advance path
          # below; or (c) run off the end of the segment (mySlot >= S)
          # — same fall-through. Bounded by S iterations per outer
          # invocation.
          # The slow-path inner scan uses a LOCAL counter, not the
          # segment-wide `closesSeenThisSegment`. Rationale: the slow
          # path does NOT advance `prevConsumerIdx`, so a subsequent
          # outer-loop iteration that re-enters this scan walks the
          # same `mySlot` range and would re-observe the same already-
          # CLOSED cells. Folding those re-observations into the
          # segment-wide counter would inflate it across iterations
          # and trip the starvation threshold prematurely — causing
          # `retireOnCAS` to fire on a segment that still has
          # publishable cells past mySlot, orphaning them (data
          # loss). The local counter is reset on every outer iter, so
          # the threshold-hit decision below reflects only THIS
          # scan's closes.
          var publishableSeen = false
          var localScanCloses = 0
          while mySlot < S and seg.tail.load(moAcquire) > mySlot:
            # cells hold LCRQCell[SlotEncoding(T)]; the close-on-empty
            # CAS operates on the cell's wire form.
            if tryCloseOnEmpty[SlotEncoding(T)](seg.cells[mySlot], 0'u):
              # We won the close-on-empty CAS. Inline-skip past it.
              inc localScanCloses
              if localScanCloses >= S:
                break
              inc mySlot
              continue
            # tryCloseOnEmpty failed. Distinguish:
            #   (a) cell now CLOSED (a peer consumer closed first) —
            #       inline-skip, same as our own close-success branch.
            #   (b) cell now FILLED (producer published into it) —
            #       leave the scan; the fast-path will claim it on a
            #       subsequent outer-loop iteration once mySlot
            #       realigns with prevConsumerIdx+1.
            let recheck = load(seg.cells[mySlot], moAcquire)
            if seqIsClosed(recheck.first):
              inc localScanCloses
              if localScanCloses >= S:
                break
              inc mySlot
              continue
            # Case (b): producer published. Exit scan; let outer loop
            # re-derive mySlot from prevConsumerIdx and route to the
            # fast-path.
            publishableSeen = true
            break
          if publishableSeen:
            # A publishable cell exists at or past `mySlot`. The
            # fast-path on the next outer iteration will claim it once
            # prevConsumerIdx-CAS aligns. Backoff briefly so a
            # concurrent peer consumer making the same observation
            # gets a fair chance.
            backoffOnRetry(spins)
            continue
          if localScanCloses < S and mySlot < S and seg.tail.load(moAcquire) <= mySlot:
            # We closed some cells but the tail caught back up (no
            # more empty cells past mySlot in the race-window). Retry
            # outer to re-evaluate the fast-path; prevConsumerIdx may
            # have been advanced by peer consumers in the meantime.
            backoffOnRetry(spins)
            continue
          # Either the starvation cutoff `S` was reached, or we walked
          # off the end of the segment with all-closed cells. Fall
          # through to the nextSeg advance path below.
        let nextSeg = seg.next.load(moAcquire)
        if nextSeg == nil:
          break
        # push-10 race fix: foreclose the full unconsumed cell range
        # `[prevConsumerIdx+1, S-1]` BEFORE retiring so an in-flight
        # producer cannot publish into a retired segment. If
        # foreclosure reports a FILLED cell, abort retire and let the
        # outer loop's fast-path claim it.
        let
          curPrevIdx = seg.prevConsumerIdx.load(moAcquire)
          forecloseFrom = max(curPrevIdx + 1, 0)
        if not forecloseSegmentForRetire[T, S](
          seg, forecloseFrom
        ):
          backoffOnRetry(spins)
          continue
        if self.queue[].retireOnCAS(
          scope,
          self.queue.headSegment,
          seg,
          nextSeg,
          segmentDestructor[T, ccMulti, ccMulti, S],
        ):
          when ST != stManual:
            discard self.queue.segments.fetchSub(1, moRelaxed)
          seg = nextSeg
          closesSeenThisSegment = 0
          spins = InitialSpin
        else:
          seg = self.queue.headSegment.load(moAcquire)
          closesSeenThisSegment = 0
          spins = InitialSpin
        backoffOnRetry(spins)
        continue
      # Strict-LCRQ MPMC fast-path consumer claim.
      # Two-tier coordination:
      #   1. `prevConsumerIdx.compareExchange` reserves ownership of
      #      `mySlot` against peer consumers.
      #   2. `tryClaim(seg.cells[mySlot], expectedSeq=0)` extracts the
      #      value via DWCAS (subsumes the legacy published-bit gate
      #      and the `move(seg.data[mySlot])` of the pre-strict-LCRQ
      #      code path).
      # Both layers are required: the cell DWCAS extracts the value
      # but does not coordinate ownership; the prevConsumerIdx CAS
      # coordinates ownership but does not extract the value.
      #
      # Happens-Before (HB) Rationale:
      # Payload publication HB rides on the cell DWCAS transaction:
      # producer's tryPublish uses moRelease on compareExchangeStrong,
      # which synchronizes-with consumer's tryClaim using moAcquire on
      # load and moAcquireRelease on compareExchangeStrong.
      # prevConsumerIdx CAS coordinates slot reservation among peer
      # consumers (preventing duplicate claims), but does NOT carry
      # payload HB from producer to consumer.
      if seg.prevConsumerIdx.compareExchange(prevIdx, mySlot, moAcquire, moRelaxed):
        # cells hold LCRQCell[SlotEncoding(T)]; DWCAS extracts
        # the encoded form, which is decoded back to user-facing T.
        var claimed = tryClaim[SlotEncoding(T)](seg.cells[mySlot], 0'u)
        if claimed.isSome:
          result = some(unwrapOrIdentity[T](move(claimed.get)))
          discard self.queue.itemCount.fetchSub(1, moRelaxed)
          break
        # tryClaim returned none. Distinguish via fresh acquire-load:
        #   (a) CLOSED_BIT set — a peer consumer drove close-on-empty
        #       on our reserved slot between the prevConsumerIdx-CAS
        #       and the tryClaim. The cell is PERMANENTLY closed.
        #       CRIT-2: retiring the whole segment here would orphan
        #       filled cells at indices > mySlot inside the retired
        #       segment. Instead fall through to the slow-path
        #       semantics: count this as a skipped-closed cell, advance
        #       past it, and retire only when `closesSeenThisSegment >= S`
        #       (the starvation threshold) or when we run past the
        #       segment tail with nothing publishable.
        #
        #       Invariant: `prevConsumerIdx` advances monotonically on
        #       BOTH successful claims AND
        #       skipped-closed cells. Reading code that reasons about
        #       `prevConsumerIdx == claim_count` must instead read
        #       `prevConsumerIdx == claim_count + close_count` within
        #       the segment.
        #   (b) cell empty (seq == 0) — producer raced our tail-load
        #       and has not yet published. Retry on the next outer
        #       loop iteration.
        let recheck = load(seg.cells[mySlot], moAcquire)
        if seqIsClosed(recheck.first):
          # CRIT-2: fall through to slow-path-style skip.
          # `prevConsumerIdx` is already advanced to `mySlot` by the
          # successful CAS above; the next outer iteration will see
          # mySlot' = mySlot+1 and route to whichever path applies
          # (fast-path claim if slot+1 is filled; slow-path scanner
          # if past tail).
          inc closesSeenThisSegment
          if closesSeenThisSegment >= S:
            # Starvation threshold reached. Retire the segment.
            let nextSeg = seg.next.load(moAcquire)
            if nextSeg == nil:
              break
            # push-10 race fix: foreclose `[mySlot+1, S-1]` before
            # retire. `mySlot` was just processed (skipped-closed via
            # the recheck above); cells beyond may still be tail-CAS-
            # reserved by in-flight producers.
            if not forecloseSegmentForRetire[T, S](
              seg, mySlot + 1
            ):
              backoffOnRetry(spins)
              continue
            if self.queue[].retireOnCAS(
              scope,
              self.queue.headSegment,
              seg,
              nextSeg,
              segmentDestructor[T, ccMulti, ccMulti, S],
            ):
              when ST != stManual:
                discard self.queue.segments.fetchSub(1, moRelaxed)
              seg = nextSeg
              closesSeenThisSegment = 0
              spins = InitialSpin
            else:
              seg = self.queue.headSegment.load(moAcquire)
              closesSeenThisSegment = 0
              spins = InitialSpin
          backoffOnRetry(spins)
          continue
        # Case (b): producer mid-publish. We have already reserved
        # `mySlot` via the prevConsumerIdx CAS; that reservation is
        # ours until the producer publishes (or the cell is closed).
        # Spin on the SAME mySlot until publication. Returning to the
        # outer loop would re-derive mySlot from prevConsumerIdx (now
        # == our reserved mySlot), advancing the consumer PAST the
        # reservation and orphaning the value the producer eventually
        # publishes — a latent data-loss bug fixed by this inner spin.
        # CRIT-1: bounded spin + close-on-empty
        # escalation. A producer that won the tail-CAS but stalls
        # before tryPublish would otherwise leave us spinning
        # forever on `inner.first == 0`. After
        # `LockFreeQueuesMaxWaitForPublishSpins` iterations (~ms on modern
        # hardware with backoff), the consumer drives
        # `tryCloseOnEmpty` on its reserved cell:
        #   * close-success → treat the cell as closed (see below);
        #     the stalled producer's eventual `tryPublish` will
        #     fail and it will escalate to nextSeg.
        #   * close-fail (producer raced and published during our
        #     budget) → retry tryClaim and exit.
        var fellThroughOnClose = false
        block waitForPublish:
          var waitSpins = 0
          # Independent backoff budget for the inner publish-wait. Using
          # the outer-loop `spins` here would inherit the accumulated
          # (often saturated) backoff from prior contended iterations,
          # collapsing this short in-flight-publisher wait into an
          # immediate schedYield storm. A fresh `InitialSpin` keeps the
          # publish-wait's escalation independent of outer-loop history.
          var waitBackoff = InitialSpin
          while true:
            backoffOnRetry(waitBackoff)
            let inner = load(seg.cells[mySlot], moAcquire)
            if seqIsClosed(inner.first):
              # Cell was closed while we waited (close-on-empty raced
              # the producer). CRIT-2: do NOT retire the
              # segment here — fall through to slow-path-style skip
              # so filled cells at indices > mySlot are not orphaned.
              fellThroughOnClose = true
              break waitForPublish
            if inner.first != 0'u:
              # Producer published. Claim the value.
              # cells hold LCRQCell[SlotEncoding(T)]; decode.
              var claimed = tryClaim[SlotEncoding(T)](seg.cells[mySlot], 0'u)
              if claimed.isSome:
                result = some(unwrapOrIdentity[T](move(claimed.get)))
                discard self.queue.itemCount.fetchSub(1, moRelaxed)
                when ST == stEager:
                  if h.advanceEvery(LockFreeQueuesAdvanceEvery):
                    discard reclaimNow(h)
                return
              # tryClaim raced a CLOSED transition (defensive — the
              # reservation makes peer-consumer interference
              # impossible). Re-inspect on next iteration.
              continue
            # Still empty. Bounded-spin budget for stalled producer.
            inc waitSpins
            if waitSpins >= LockFreeQueuesMaxWaitForPublishSpins:
              # CRIT-1: producer reserved tail but never published.
              # Drive close-on-empty on our reserved cell.
              # cells hold LCRQCell[SlotEncoding(T)].
              if tryCloseOnEmpty[SlotEncoding(T)](seg.cells[mySlot], 0'u):
                # Successfully closed. Treat identically to "cell was
                # already closed when we observed it" (the CLOSED branch
                # above): fall through to the slow-path-style skip so
                # the outer loop scans the rest of the segment. Items
                # published at indices > mySlot must not be orphaned
                # regardless of whether `seg.next == nil` at this
                # moment — if scanning past tail eventually finds the
                # segment truly empty, the slow path returns `none(T)`
                # cleanly. The producer (if it resumes) will
                # tryPublish-fail on the closed cell and escalate to
                # nextSeg.
                fellThroughOnClose = true
                break waitForPublish
              # tryCloseOnEmpty failed — producer published during
              # our budget exhaustion. Loop iterates and the
              # `inner.first != 0'u` branch above will claim the
              # value on the next acquire-load.
              continue
        if fellThroughOnClose:
          # CRIT-2: cell at mySlot is closed; advance via
          # slow-path-style skip rather than retiring the segment.
          # `prevConsumerIdx` is already at `mySlot`; next outer
          # iteration reads mySlot' = mySlot+1.
          inc closesSeenThisSegment
          if closesSeenThisSegment >= S:
            # Starvation threshold reached. Retire the segment.
            let nextSeg = seg.next.load(moAcquire)
            if nextSeg == nil:
              break
            # push-10 race fix: foreclose `[mySlot+1, S-1]` before
            # retire. See site-1 / site-2 rationale above.
            if not forecloseSegmentForRetire[T, S](
              seg, mySlot + 1
            ):
              backoffOnRetry(spins)
              continue
            if self.queue[].retireOnCAS(
              scope,
              self.queue.headSegment,
              seg,
              nextSeg,
              segmentDestructor[T, ccMulti, ccMulti, S],
            ):
              when ST != stManual:
                discard self.queue.segments.fetchSub(1, moRelaxed)
              seg = nextSeg
              closesSeenThisSegment = 0
              spins = InitialSpin
            else:
              seg = self.queue.headSegment.load(moAcquire)
              closesSeenThisSegment = 0
              spins = InitialSpin
          backoffOnRetry(spins)
          continue
        continue
      # prevConsumerIdx CAS lost to a peer consumer. Retry the outer
      # loop to re-read prevIdx and recompute mySlot.
      backoffOnRetry(spins)
      continue

  when ST == stEager:
    if h.advanceEvery(LockFreeQueuesAdvanceEvery):
      discard reclaimNow(h)

# --- Batch pop on Bound for ccCons == ccMulti ----------------------------
proc pop*[
    T;
    Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag,
    ccProd: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](
    self: Bound[T, Tag, Queue[T, ccProd, ccMulti, ST, S, MaxThreads]], count: int
): Option[seq[T]] {.tags: [Tag, TypestateOp, RootEffect], raises: [], notATransition.} =
  if unlikely(count <= 0):
    return none(seq[T])
  var items = newSeqOfCap[T](count)
  for _ in 0 ..< count:
    let v = self.pop()
    if v.isNone:
      break
    items.add(v.get)
  if items.len == 0:
    none(seq[T])
  else:
    some(items)

## Same-thread shortcut helpers (`getProducerHere` / `getConsumerHere`)
## and `bindConsumer` live in `endpoint.nim` next to `getProducer` /
## `getConsumer` so the templates bind against the endpoint module's
## factories rather than any locally-shadowing `getProducer` /
## `getConsumer` proc at the expansion site.

## ----------------------------------------------------------------------
## Drain helpers — `iterator drain*` and `proc destroyAndDrain*`
##
## Mirrors the BQueue side: single-consumer arms (ccCons == ccSingle)
## drain directly on Queue; multi-consumer arms (ccCons == ccMulti)
## drain via Bound consumer endpoint.
##
## Drain is a loop over the existing `pop` primitive, which already
## performs Path-C unwrap. The contract is single-threaded — caller
## owns the queue exclusively during drain. MPMC unbounded pop's
## defensive CAS-loop always wins on the first try under that
## contract (no contention), so drain proceeds linearly through the
## segment chain.
## ----------------------------------------------------------------------

# --- drain iterator: SPSC absorbed (direct on Queue) ---------------------
iterator drain*[
    T;
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](self: var Queue[T, ccSingle, ccSingle, ST, S, MaxThreads]): T =
  ## Drain SPSC-absorbed unbounded Queue. Bare-Queue pop is available
  ## for SPSC only (the only arm where direct-on-Queue pop survived
  ## v5.0.0); other cardinalities route drain through Bound endpoints.
  while true:
    let opt = self.pop()
    if opt.isNone:
      break
    yield opt.get()

# --- drain iterator: MPSC / SPMC / MPMC via Bound consumer endpoint ------
# MPSC, SPMC, and MPMC route through `Bound[T, Tag, Queue[..., ccCons, ...]]`.
iterator drain*[
    T;
    Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](self: Bound[T, Tag, Queue[T, ccMulti, ccSingle, ST, S, MaxThreads]]): T =
  ## Drain MPSC unbounded Queue via Bound consumer endpoint.
  while true:
    let opt = self.pop()
    if opt.isNone:
      break
    yield opt.get()

iterator drain*[
    T;
    Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](self: Bound[T, Tag, Queue[T, ccSingle, ccMulti, ST, S, MaxThreads]]): T =
  ## Drain SPMC unbounded Queue via Bound consumer endpoint.
  while true:
    let opt = self.pop()
    if opt.isNone:
      break
    yield opt.get()

iterator drain*[
    T;
    Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](self: Bound[T, Tag, Queue[T, ccMulti, ccMulti, ST, S, MaxThreads]]): T =
  ## Drain MPMC unbounded Queue via Bound consumer endpoint. The MPMC
  ## consumer-CAS pop succeeds on the first try under the single-
  ## consumer drain contract (no contention).
  while true:
    let opt = self.pop()
    if opt.isNone:
      break
    yield opt.get()

# --- items iterators ----------------------------------------------------
# `items` is the Nim-convention alias for `drain`. `pairs`
# is BQueue-only — unbounded Queue ships `items` (and `drain`) only.

# items: SPSC absorbed (bare Queue).
iterator items*[
    T;
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](self: var Queue[T, ccSingle, ccSingle, ST, S, MaxThreads]): T =
  while true:
    let opt = self.pop()
    if opt.isNone:
      break
    yield opt.get()

# items: MPSC via Bound consumer endpoint.
iterator items*[
    T;
    Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](self: Bound[T, Tag, Queue[T, ccMulti, ccSingle, ST, S, MaxThreads]]): T =
  while true:
    let opt = self.pop()
    if opt.isNone:
      break
    yield opt.get()

# items: SPMC via Bound consumer endpoint.
iterator items*[
    T;
    Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](self: Bound[T, Tag, Queue[T, ccSingle, ccMulti, ST, S, MaxThreads]]): T =
  while true:
    let opt = self.pop()
    if opt.isNone:
      break
    yield opt.get()

# items: MPMC via Bound consumer endpoint.
iterator items*[
    T;
    Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](self: Bound[T, Tag, Queue[T, ccMulti, ccMulti, ST, S, MaxThreads]]): T =
  while true:
    let opt = self.pop()
    if opt.isNone:
      break
    yield opt.get()

# --- destroyAndDrain: SPSC absorbed + callback ---------------------------
proc destroyAndDrain*[
    T;
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](
    self: sink Queue[T, ccSingle, ccSingle, ST, S, MaxThreads],
    cleanup: proc(item: T) {.gcsafe, raises: [].},
) =
  ## Drain SPSC unbounded Queue, run `cleanup` per item, then destroy.
  ## Takes `sink` of the queue so the caller's binding is moved-from
  ## (preventing scope-end double-destroy). Under mm:none this is the
  ## ONLY safe teardown path for a non-empty queue with ref / string /
  ## seq payloads.
  var localSelf = self
  for item in drain(localSelf):
    cleanup(item)
  # `localSelf` goes out of scope here → `=destroy` fires once.

# --- destroyAndDrain: POD discard overload --------------------------------
proc destroyAndDrain*[
    T;
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](self: sink Queue[T, ccSingle, ccSingle, ST, S, MaxThreads]) =
  ## SPSC POD discard overload. Takes `sink` to prevent caller-side
  ## scope-end double-destroy.
  var localSelf = self
  for item in drain(localSelf):
    discard item

## NOTE: ``destroyAndDrain`` is intentionally NOT provided on Bound
## endpoints for ``ccCons == ccMulti`` arms (and likewise for MPSC,
## whose pop also lives on Bound). The bare ``var q: Queue[...]``
## remains in scope behind the Bound endpoint, and its scope-end
## ``=destroy`` would conflict with an explicit destructor call from
## inside ``destroyAndDrain`` (double-destroy at the typestate level).
## For multi-consumer / MPSC arms, the canonical pattern is:
##   for item in drain(myBoundConsumer):
##     cleanup(item)
##   # myQueue's scope-end `=destroy` walks any residual slots

## ----------------------------------------------------------------------
## Test-only introspection helpers for the unbounded Segment layout.
## ----------------------------------------------------------------------

when defined(testing):
  proc headSegmentForTest*[
      T;
      ccProd, ccCons: static PinScopeCardinality,
      ST: static DeallocationStrategy,
      S, MaxThreads: static int,
  ](self: var Queue[T, ccProd, ccCons, ST, S, MaxThreads]): pointer =
    ## Test-only accessor: returns the queue's current head-segment
    ## pointer so the cache-line padding audit can verify base alignment.
    result = cast[pointer](self.headSegment.load(moRelaxed))

  proc segmentTailOffsetForTest*[
      T; ccProd, ccCons: static PinScopeCardinality, S: static int
  ](_: typedesc[Segment[T, ccProd, ccCons, S]]): int =
    ## Test-only accessor: returns offset of the cache-line-padded `tail`
    ## field within the unified Segment for any cardinality.
    offsetOf(Segment[T, ccProd, ccCons, S], tail)

  proc segmentHeadOffsetForTest*[
      T; ccProd, ccCons: static PinScopeCardinality, S: static int
  ](_: typedesc[Segment[T, ccProd, ccCons, S]]): int =
    ## Test-only accessor: returns offset of `head` for cardinality
    ## combos that carry it (`ccCons == ccSingle`). For shapes that
    ## lack `head` Nim's `offsetOf` will compile-fail at the call site.
    offsetOf(Segment[T, ccProd, ccCons, S], head)

  proc segmentCommittedOffsetForTest*[
      T; ccProd, ccCons: static PinScopeCardinality, S: static int
  ](_: typedesc[Segment[T, ccProd, ccCons, S]]): int =
    ## Test-only accessor: returns offset of `committed` for cardinality
    ## combos that carry it (`ccProd == ccMulti and ccCons == ccSingle`,
    ## i.e. MPSC only). MPMC carries `cells`; use
    ## `segmentCellsOffsetForTest` on the MPMC arm. Calling this with an
    ## MPMC cardinality fails at the `offsetOf` site (field absent).
    offsetOf(Segment[T, ccProd, ccCons, S], committed)

  proc segmentCellsOffsetForTest*[
      T; ccProd, ccCons: static PinScopeCardinality, S: static int
  ](_: typedesc[Segment[T, ccProd, ccCons, S]]): int =
    ## Test-only accessor: returns offset of the strict-LCRQ `cells` array
    ## for the MPMC arm (`ccProd == ccMulti and ccCons == ccMulti`). Other
    ## cardinality combos lack the field; calling there compile-fails at
    ## the `offsetOf` site.
    offsetOf(Segment[T, ccProd, ccCons, S], cells)

  proc segmentPrevConsumerIdxOffsetForTest*[
      T; ccProd, ccCons: static PinScopeCardinality, S: static int
  ](_: typedesc[Segment[T, ccProd, ccCons, S]]): int =
    ## Test-only accessor: returns offset of `prevConsumerIdx` for
    ## cardinality combos that carry it (`ccCons == ccMulti`).
    offsetOf(Segment[T, ccProd, ccCons, S], prevConsumerIdx)
