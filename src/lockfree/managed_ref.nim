## lockfree/managed_ref
##
## Internal slot encoding for ``ref T`` payloads under Path C
## (`Queue[ref Foo, ...]`). See design §2.2 (`ManagedRef[X]` internal
## type definition, Path C rationale, per-MM shim arms) and §4.3
## (`ManagedRef[X]` shim impl details, bit-cast guarantees) of
## ``docs/internal/2026-06-05-umbrella-v0.1.0-design.md``.
##
## NEVER user-facing
## -----------------
##
## ``ManagedRef[X]`` is the wire-format the queue stores in its slot
## array. The user-facing API is ``ref T``. ``ManagedRef`` MUST NOT
## leak into public docs, examples, or signatures — see §2.2 "Why
## NEVER user-facing".
##
## Why ``distinct uint`` and not ``distinct ptr X``
## ------------------------------------------------
##
## 1. ``Atomic[uint]`` and ``Atomic[Pair[uint, uint]]`` compile and
##    produce the right ``cmpxchg16b`` / ``ldxp+stxp`` instructions
##    across every atomics backend we target. ``Atomic[ptr X]`` is
##    less well-trodden and the strict-LCRQ DWCAS arm cannot tolerate
##    "may or may not compile" (§2.2 rationale 1).
## 2. ``distinct uint`` opacifies the slot at the compiler's lifecycle
##    pass — no implicit ``=destroy`` / ``=copy`` is emitted on the
##    slot value because the compiler sees POD bits. Refcount
##    operations happen at the EXPLICIT call sites in the queue
##    wrappers (push, pop, queue-destroy walk), never silently behind
##    the queue's back. (§2.2 rationale 2.)
## 3. ``cast[uint](myRef) ↔ cast[ManagedRef[X]](bits) ↔
##    cast[ref X](toBits(mref))`` is a no-op at runtime and preserves
##    pointer identity, which is the precondition for the per-MM
##    refcount calls to find the correct heap header. (§2.2
##    rationale 3; §4.3.6.)
##
## ABI stability (§2.10)
## ---------------------
##
## ``sizeof(ManagedRef[X])`` and ``alignof(ManagedRef[X])`` are equal
## to ``sizeof(uint)`` and ``alignof(uint)`` on every supported
## platform. This is the wire-format invariant the queue's atomic
## slot operations depend on, and it is asserted at compile time in
## the ``static:`` block below. Across-MM ABI promises (arc ↔ orc ↔
## atomicArc ↔ none) follow from this identity plus the same field
## layout in ``Queue[T, ...]`` — see §2.10 and §4.9 of the design
## doc for the full set of guarantees and what we explicitly do NOT
## promise (refc bit-compat, cross-Nim-version, cross-minor-version).
##
## Per-MM shim arms (§4.3.3)
## -------------------------
##
## The ``incRefSlot`` / ``decRefSlot`` templates dispatch on the
## compile-time MM define:
##
## * ``arc`` / ``orc`` / ``atomicArc`` — bump/drop the cell's
##   refcount via the same per-MM mechanism the compiler would emit
##   for a ``ref X``. The atomicArc arm collapses with arc in the
##   ``when`` because the C-RTL substitutes the atomic op
##   transparently (arc.nim:248-252).
## * ``refc`` — tracing GC: ``GC_ref`` / ``GC_unref``.
## * ``none`` — strict bit-transport contract (§2.8): no-op. The user
##   owns lifetime; the queue is pointer-bit transport only.
## * ``nimony`` — uses ``arcInc`` / ``arcDec`` from nimony's
##   ``std/system/arcops`` (verified at ``arcops.nim:5,10``). The
##   signature shape differs from Nim 2.x's ``nimIncRef`` family:
##   nimony's ``arcInc(memLoc: var int)`` and
##   ``arcDec(memLoc: var int): bool`` operate on the refcount field
##   directly (a ``var int`` lvalue), NOT a heap-pointer. The arm
##   below uses ``cast[ptr int](bits)[]`` to materialise a ``var int``
##   lvalue at the bits location. See partial-port boundary block
##   below for heap-header offset and dispose-symbol caveats.
##
## Implementation note: design §2.2/§4.3.3 names ``nimIncRef`` /
## ``nimDecRefIsLast`` / ``nimDestroyAndDispose`` as the symbol path.
## Those are ``compilerRtl`` and emitted ``static`` in their TU, so
## a cross-module call site requires a thin wrapper. ``GC_ref`` /
## ``GC_unref`` (arc.nim:265-272) are the exported wrappers around
## that exact path — under arc/orc/atomicArc they delegate to
## ``nimIncRef`` / ``=destroy`` (which in turn calls
## ``nimDecRefIsLast`` and ``nimDestroyAndDispose``); under refc they
## hit the tracing-GC path. The semantic is identical to what the
## design specifies; the symbol path differs only in being public.
## See §4.3.6 for the bit-cast guarantee that makes either choice
## equivalent.

# Path C invariant: ``ManagedRef`` is an internal slot encoding. The
# only legal importers are the queue cores (``lockfree/queue``,
# ``lockfree/bqueue``) and the managed-payload tests under
# ``tests/managed_ref/``. User code uses ``ref T`` directly.

# Fix 1 (Phase 4.6.1 test infra): under ``-d:lockfreeRefcountTrace`` the
# refcount shims below call ``bumpInc`` / ``bumpDec`` from the test-only
# trace shim so ``tests/composition/t_refcount_use_patterns.nim`` can
# assert real inc/dec balance. The import is guarded by the define so it
# is NEVER pulled into release builds (zero-cost when the define is
# unset). The shim path is supplied by the ``testRefcountTrace`` nimble
# task (``--path:tests/composition``); it imports only ``std/atomics`` so
# there is no import cycle back into ``managed_ref``.
when defined(lockfreeRefcountTrace):
  import refcount_trace_shim

type
  ManagedRef*[X] = distinct uint
    ## Slot encoding for a ``ref X`` payload. Internal — see module
    ## doc-comment. Sized and aligned identically to ``uint`` (§2.10).

# ---------------------------------------------------------------------
# §2.10 ABI claim: bit-identity with ``uint``.
#
# This is the wire-format invariant the queue's atomic slot operations
# depend on. Asserted at compile time so a future Nim that changes
# ``distinct uint``'s layout fails to compile rather than silently
# corrupting cross-MM data exchange.
# ---------------------------------------------------------------------
static:
  assert sizeof(ManagedRef[int]) == sizeof(uint),
    "ManagedRef[X] must be sizeof(uint) for §2.10 ABI parity"
  assert alignof(ManagedRef[int]) == alignof(uint),
    "ManagedRef[X] must be alignof(uint) for §2.10 ABI parity"

# ---------------------------------------------------------------------
# §2.2 / §4.3.2: conversion functions (cast-based; codegen identity).
#
# CRITICAL invariant: none of these touch the refcount. Refcount
# operations are EXPLICIT call sites in the queue wrapper
# (``path_c_wrap.nim``).
#
# Lifecycle model (LOCKED — Wave C, 2026-06-06): library inc paired
# with library dec WITHIN library scopes. The queue wrapper
# (``wrapOrIdentity[ref X]`` in ``path_c_wrap.nim``) inserts an
# explicit ``incRefSlot`` after ``toManagedRef`` so the queue claims
# +1 of the cell's refcount lifetime; that +1 is released on the
# destroy-walk via ``disposeSlotEncoded[ref X]`` →
# ``decRefSlot``. Pop is destructive (``move`` on the slot bits) and
# transfers the +1 to the caller's binding without a library dec.
# The ``sink`` on ``toManagedRef`` ensures the caller's source binding
# is consumed; its scope-exit ``=destroy`` balances the queue's
# ``incRefSlot`` so the net within push is "+1 transferred to slot".
# See path_c_wrap.nim module doc and §4.3.2.
# ---------------------------------------------------------------------

proc toManagedRef*[X](r: sink ref X): ManagedRef[X] {.inline.} =
  ## Pack a ``ref X`` into the slot encoding. Pointer-bit transfer
  ## only — does NOT touch refcount. The queue wrapper
  ## (``path_c_wrap.nim:wrapOrIdentity``) is responsible for the
  ## paired ``incRefSlot`` that claims +1 of the cell's refcount
  ## lifetime for the slot. See §4.3.2 + path_c_wrap.nim.
  ManagedRef[X](cast[uint](r))

proc toRef*[X](mref: ManagedRef[X]): ref X {.inline.} =
  ## Unpack the slot encoding back to ``ref X``. Pointer-bit transfer
  ## only — does NOT touch refcount. Pop is destructive (``move``);
  ## the queue's +1 refcount share (claimed at push) is inherited by
  ## the caller's binding. See §4.3.2 + path_c_wrap.nim.
  cast[ref X](uint(mref))

proc toBits*[X](mref: ManagedRef[X]): uint {.inline.} =
  ## Expose the raw pointer bits. Used by the queue's atomic slot
  ## operations (``Atomic[uint]`` ops on the slot array). Identity
  ## codegen.
  uint(mref)

proc fromBits*[X](_: typedesc[ManagedRef[X]], bits: uint): ManagedRef[X] {.inline.} =
  ## Reconstruct a ``ManagedRef[X]`` from raw bits read out of the
  ## slot array. Identity codegen.
  ManagedRef[X](bits)

proc nilManagedRef*[X](_: typedesc[X]): ManagedRef[X] {.inline.} =
  ## The all-zero slot — semantically equivalent to a nil ``ref X``.
  ## A generic proc rather than a ``const`` because the generic
  ## ``ManagedRef[X]`` cannot be a top-level ``const`` without
  ## binding ``X``. Call as ``nilManagedRef(Foo)`` (typedesc passed
  ## explicitly) from generic queue code where ``X`` is bound by
  ## context.
  ManagedRef[X](0)

# ---------------------------------------------------------------------
# §4.3.3: per-MM refcount shims.
#
# Each arm is conditionally compiled on the active MM define. The arms
# are mutually exclusive; the queue wrappers call these unconditionally
# and the ``when`` collapses to either symbol calls or ``discard``.
# ---------------------------------------------------------------------

template incRefSlot*[X](mref: ManagedRef[X]) =
  ## Bump the refcount of the cell pointed at by ``mref``. No-op when
  ## ``mref`` is the nil slot. Per-MM dispatch per §4.3.3.
  when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc) or
       defined(gcRefc):
    let mrefBits = toBits(mref)
    if mrefBits != 0'u:
      # Fix 1 (Phase 4.6.1 test infra): trace hook fires exactly once
      # per real refcount inc, guarded by the define so release builds
      # are zero-cost (no symbol pulled, no shim imported). Placed inside
      # the non-nil guard so it counts only inc calls that actually
      # GC_ref a live cell.
      when defined(lockfreeRefcountTrace):
        bumpInc()
      # ``GC_ref`` on arc/orc/atomicArc delegates to ``nimIncRef``
      # (arc.nim:270-272); on refc it bumps the tracing-GC count. The
      # cyclic flag (orc) is handled inside ``nimIncRef`` /
      # ``=destroy`` for the slot's static type — we always pass the
      # ``ref X`` typed view so the compiler emits the right call.
      GC_ref(cast[ref X](mrefBits))
  else:
    # mm:none — strict bit-transport contract (§2.8). User owns
    # lifetime; queue is pointer-bit transport only. No-op.
    # nimony arm is added by T-NIMONY-ARMS at the dedicated
    # insertion-point stub below.
    discard

template decRefSlot*[X](mref: ManagedRef[X]) =
  ## Drop the refcount of the cell pointed at by ``mref``. No-op when
  ## ``mref`` is the nil slot. Per-MM dispatch per §4.3.3.
  when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc) or
       defined(gcRefc):
    let mrefBits = toBits(mref)
    if mrefBits != 0'u:
      # Fix 1 (Phase 4.6.1 test infra): trace hook fires exactly once
      # per real refcount dec, guarded by the define (zero-cost in
      # release). Counts only dec calls that actually GC_unref a live
      # cell.
      when defined(lockfreeRefcountTrace):
        bumpDec()
      # ``GC_unref`` on arc/orc/atomicArc calls ``=destroy`` on a
      # cursor view of the ref (arc.nim:265-268), which runs
      # ``nimDecRefIsLast`` + ``nimDestroyAndDispose`` if the count
      # reaches zero. The orc cyclic detector is consulted via the
      # cell's type-emitted destructor. On refc it drops the
      # tracing-GC count. Net semantic matches design §4.3.3.
      GC_unref(cast[ref X](mrefBits))
  else:
    # mm:none — strict bit-transport contract (§2.8). No-op.
    # nimony arm: see dedicated insertion-point stub below.
    discard

# ---------------------------------------------------------------------
# Nimony shim arm (§4.3.5; §6.7 first-class architecture; T-NIMONY-ARMS).
#
# **Experimental (nimony):** this arm is documented as `experimental` in
# `docs/guide/nimony.md` (per §6.7.1). The
# `experimental` marker here is a doc-marker convention — Nim's
# `{.experimental: "<feature>".}` pragma requires a compiler-whitelisted
# feature name, so the marker lives in the doc-comments below and in
# the user-facing nimony guide, not as a `{.experimental: ...}` pragma
# on the symbols. (Compiler-pragma feature names like "strictDefs" are
# not appropriate for "this codepath depends on a pre-release runtime".)
#
# Nimony arcops surface (lib/std/system/arcops.nim):
#
#   * `func arcInc*(memLoc: var int) {.inline.}` — arcops.nim:5.
#   * `func arcDec*(memLoc: var int): bool {.inline.}` — arcops.nim:10.
#
# Both take a `var int` lvalue (the rc *field*), NOT a heap pointer. The
# design code-block at §4.3.3 (design lines 823-825, 836-837) passed
# `cast[pointer](uint(mref))` which is a type mismatch. We take the
# lvalue path instead:
#   `arcInc(cast[ptr int](toBits(mref))[])`
# which produces the required `var int` lvalue without an extra
# wrapper layer.
#
# Partial-port boundary (per CRITICAL #5 disposition + §6.7.4):
#
#   * **Heap-header offset (unresolved)** — the design assumes the
#     rc field lives at `cast[ptr NimHeapHeader](bits -! sizeof(NimHeapHeader)).rc`
#     but the nimony `NimHeapHeader` layout is not yet verified. The
#     shim below treats the slot bits as pointing AT the rc field
#     directly. This is a partial-port simplification: under nimony's
#     current allocator the rc field may instead live at a fixed
#     negative offset from the payload. See `# TODO: nimony partial
#     port` markers in the templates. The Cell 14 CI run
#     (continue-on-error per §6.7.1) is the validator; correctness
#     here is tightened in v0.2 once the nimony heap-header layout is
#     verifiable.
#
#   * **Dispose symbol (unresolved)** — design line 850 marks
#     `nimonyDestroyAndDispose` as "symbol TBD". On `arcDec → true`
#     (last reference) the cell needs an explicit dispose call.
#     Pending resolution we OMIT the dispose call with a TODO: under
#     nimony's arcops model, dropping the rc to zero may auto-dispose
#     via the allocator hook chain, or may leak. Either way, the leak
#     is observable only under nimony (`continue-on-error` cell) and
#     does not affect any Nim 2.x MM (arc/orc/atomicArc/refc). v0.2
#     binds this to the verified symbol.
#
#   * **No silent `discard`** — partial-port unknowns are explicit
#     TODOs, not hidden behind no-ops. Per §6.7.4 disposition: "No
#     silent `discard`; no 'we hope this works' fingers-crossed."
#
# The block expands ONLY under `-d:nimony`; under arc/orc/atomicArc/refc
# the templates above (lines 155-192) own the dispatch and the arms
# below are inert.
# ---------------------------------------------------------------------

when defined(nimony):
  # Import the nimony arcops surface. Wrapped in the
  # `when defined(nimony):` block so non-nimony builds never see
  # the import and do not require the module to exist.
  from std/system/arcops import arcInc, arcDec

  template incRefSlot*[X](mref: ManagedRef[X]) =
    ## Nimony arm of `incRefSlot`. Calls `arcInc(memLoc: var int)` on
    ## the cell's refcount. **Experimental** per §6.7.1.
    ##
    ## Partial-port note (OQ4.2): the rc field is assumed to live AT
    ## the slot bits address. The verified nimony heap-header offset
    ## is tracked at v0.2 — see module-level partial-port block.
    let mrefBits = toBits(mref)
    if mrefBits != 0'u:
      # Fix 1 (Phase 4.6.1 test infra): trace hook, guarded by the
      # define (zero-cost in release). Counts the nimony-arm inc.
      when defined(lockfreeRefcountTrace):
        bumpInc()
      # TODO: nimony partial port (OQ4.2) — once the nimony
      # NimHeapHeader layout is verified, replace the direct cast
      # with the heap-header offset computation from design §4.3.3.
      arcInc(cast[ptr int](mrefBits)[])

  template decRefSlot*[X](mref: ManagedRef[X]) =
    ## Nimony arm of `decRefSlot`. Calls `arcDec(memLoc: var int): bool`
    ## on the cell's refcount. **Experimental** per §6.7.1.
    ##
    ## Partial-port note (OQ4.4): the dispose-on-last-ref symbol is
    ## omitted pending resolution. See module-level partial-port block.
    let mrefBits = toBits(mref)
    if mrefBits != 0'u:
      # Fix 1 (Phase 4.6.1 test infra): trace hook, guarded by the
      # define (zero-cost in release). Counts the nimony-arm dec
      # regardless of last-ref outcome (it is a real dec call).
      when defined(lockfreeRefcountTrace):
        bumpDec()
      # TODO: nimony partial port (OQ4.2) — heap-header offset, as above.
      if arcDec(cast[ptr int](mrefBits)[]):
        # TODO: nimony partial port (OQ4.4) — invoke the nimony
        # dispose-on-last-ref symbol (`nimonyDestroyAndDispose` or
        # whatever the verified name is) here. Omitted in v0.1.0
        # pending OQ4.4 resolution. The leak is observable only
        # under -d:nimony (Cell 14, continue-on-error).
        discard

# ---------------------------------------------------------------------
# Atomic load / store helpers over ``Atomic[ManagedRef[X]]``.
#
# The slot itself is stored as ``Atomic[uint]`` in the queue (so the
# DWCAS pair surfaces — §4.3.1). These templates centralise the cast
# at the load/store boundary so callers in queue.nim / bqueue.nim do
# not repeat the pattern. They are pure cast wrappers; codegen is
# identical to a raw ``Atomic[uint]`` load/store.
#
# We deliberately do NOT define them as full ``Atomic[ManagedRef[X]]``
# because the queue's atomic surface is ``Atomic[uint]`` /
# ``Atomic[Pair[uint, uint]]`` (§4.3.1 rationale 1) — the cast is
# applied at the read/write site.
# ---------------------------------------------------------------------

import ./atomics

template loadManagedRef*[X](
    slot: var Atomic[uint], order: MemoryOrder): ManagedRef[X] =
  ## Atomic load + reinterpret to ``ManagedRef[X]``. The slot is
  ## stored as ``Atomic[uint]`` per §4.3.1; this is the typed-view
  ## helper for the queue's pop path.
  fromBits(ManagedRef[X], slot.load(order))

template storeManagedRef*[X](
    slot: var Atomic[uint], mref: ManagedRef[X], order: MemoryOrder) =
  ## Atomic store of the slot encoding. Symmetric to
  ## ``loadManagedRef``.
  slot.store(toBits(mref), order)

# ---------------------------------------------------------------------
# Reset helper used by the queue's destructor walk (§4.7.2).
#
# A single operation that zeroes the slot bits AND drops the cell's
# refcount, so the walk does not have to remember to do both. The
# order is "snapshot bits → zero the slot → dec the snapshot" so a
# concurrent reader sees either the live slot or the zeroed slot,
# never a slot whose refcount is dropping out from under it.
# ---------------------------------------------------------------------

proc reset*[X](mref: var ManagedRef[X]) {.inline.} =
  ## Zero the slot AND drop the refcount in one balanced operation.
  ## Used by the queue's destructor walk (§4.7.2) and by push-failure
  ## rollback (§4.3.4). No-op when ``mref`` is already nil.
  let snapshot = mref
  mref = nilManagedRef(X)
  decRefSlot(snapshot)
