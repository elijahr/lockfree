# Section 1: Architecture & Module Layout

> Status: v0.1.0 design — Section 1 of 7. Locked decisions per handoff
> Session updates (2026-06-05) and Phase 1.6 devil's advocate dispositions.
> Sibling sections cover types & payloads (2), SMR/nebr internals (3), MM
> compat shim (4), public APIs (5), CI + nimony (6), docs IA + risks (7).

## 1.1 Umbrella positioning

`lockfree` is a Nim umbrella package that gathers production-quality
lock-free building blocks under a single, coherent module tree. v0.1.0
is the first release under this name; it is built by lifting the
existing `lockfreequeues` v5.0.0 codebase and the `nim-debra` SMR work
into one repo and one package, while introducing the new payload
machinery (`ManagedRef[X]`, `ManagedSlice[T]`) and the Tier 3 async
adapter.

What's included / not included in v0.1.0:

| Component | v0.1.0 | Notes |
|---|---|---|
| Atomics primitives (incl. DWCAS) | YES | lifted from nim-debra |
| SMR layer: `nebr` (EBR + neutralization) | YES | renamed from "DEBRA+" per Q-FAITHFUL |
| SMR layer: Fraser EBR, hazard pointers, IBR, NBR | NO — stubs reserved | future strategies under `lockfree/smr/` |
| SMR layer: faithful Brown 2015 DEBRA+ | NO — name reserved | `lockfree/smr/debra_plus.nim` reserved for actually-faithful impl |
| Unbounded MPMC queue (strict-LCRQ) | YES | lifted from lockfreequeues |
| Legacy MPSC / SPMC / SPSC unbounded | YES | lifted from lockfreequeues |
| Bounded MPMC / MPSC / SPMC / SPSC (Vyukov) | YES | lifted from lockfreequeues |
| `ManagedRef[X]` refcounted payloads | YES | net-new; user-facing type is `ref T` (Path C) |
| `ManagedSlice[T]` (string / seq[T] payloads) | YES | net-new; same internal-only shape as ManagedRef |
| Typestate role tags + push/pop/bind/close FSMs | YES | lifted from lockfreequeues |
| Tier 3 async adapter (chronos) | YES — soft dep | optional, gated by `-d:lockfreeChronos` or auto-detect |
| Tier 1 (threads/locks) and Tier 2 (custom) adapters | NO (out of scope) | future work |

Out of scope for v0.1.0: changes to the algorithms themselves, new
queue topologies, new SMR strategies beyond `nebr`, MPSC- or SPMC-only
LCRQ variants.

## 1.2 Version, package identity, publication path

- **Package name on disk and on Nimble**: `lockfree`
- **Version**: `0.1.0` (fresh start under the new name)
- **Predecessor**: `lockfreequeues` v5.0.0 remains published on Nimble
  but is **frozen** for the duration of v0.1.0 work. Any decision to
  archive, tombstone, or continue `lockfreequeues` independently is
  deferred and not in scope for this design.
- **Publication path (per CRITICAL #5 deferral)**: v0.1.0 is developed
  in the `elijahr/lockfree-temp` private workspace repo. Publication
  to the public `elijahr/lockfree` repository and Nimble registration
  are **deferred decisions**; this design does not commit to a
  specific publication mechanism. The umbrella architecture is
  designed to be publication-mechanism-neutral.

## 1.3 Target module layout (post-T-INTEGRATE)

The layout below is what T-INTEGRATE.a–f produces. It is the canonical
target; any reference elsewhere in the design doc to "the lockfree
module tree" means this tree.

```
src/
  lockfree.nim                          # top-level: just `const Version`
  lockfree/
    atomics.nim                         # facade for atomics/
    atomics/
      backoff.nim                       # exponential backoff helper
      dsl.nim                           # atomic-op DSL (CAS, DWCAS, fences)
    smr/
      nebr.nim                          # facade re-exporting nebr/
      nebr/                             # multi-file: manager + typestates + helpers
        constants.nim
        convenience.nim
        limbo.nim
        manager.nim                     # central SMR manager / epoch tracking
        refptr.nim
        signal.nim
        thread_id.nim
        types.nim
        typestates/                     # per-step FSMs lifted from debra/
          advance.nim
          cardinality.nim
          guard.nim
          manager.nim
          neutralize.nim                # the "N" in nebr
          pinned_scope.nim
          reclaim.nim
          registration.nim
          retire.nim
          signal_handler.nim
          slot.nim
      # --- reserved for future SMR strategies (NOT shipped in v0.1.0) ---
      # ebr.nim                         # RESERVED: classic Fraser EBR
      # debra_plus.nim                  # RESERVED: actually-faithful Brown 2015 DEBRA+
      # hazard.nim                      # RESERVED: hazard pointers
      # ibr.nim                         # RESERVED: interval-based reclamation
      # nbr.nim                         # RESERVED: neutralization-based reclamation
    queue.nim                           # unbounded: strict-LCRQ MPMC + legacy MPSC/SPMC/SPSC
    bqueue.nim                          # bounded Vyukov MPMC/MPSC/SPMC/SPSC
    managed_ref.nim                     # NET-NEW: ManagedRef[X] internal + per-MM shim
    managed_slice.nim                   # NET-NEW: ManagedSlice[T] for string/seq[T]
    typestates.nim                      # facade for typestates/
    typestates/                         # role tags + push/pop/bind/close FSMs
      atomic_loaders.nim
      cas.nim
      fullness_checks.nim
      mpmc_cell.nim
      mpmc_pop.nim
      mpmc_push.nim
      mpsc_pop.nim
      mpsc_push.nim
      slot_seq_n.nim
      spmc_pop.nim
      spmc_push.nim
      spsc_pop.nim
      spsc_push.nim
      storage_n.nim
      storage_n1.nim
      virtual_values_n.nim
      virtual_values_n1.nim
    internal/                           # not for external import
      aligned_alloc.nim
      pinscope_stub.nim
      shared.nim
      typestates_dsl.nim
    backoff.nim                         # queue-level backoff (separate from atomics/backoff)
    endpoint.nim                        # endpoint type + helpers
    endpoint_types.nim
    exceptions.nim
    reclamation.nim                     # queue-level reclamation glue
    role_tags.nim                       # producer/consumer role typestate tags
    spawn.nim                           # endpoint spawn helpers
    strategy.nim                        # cardinality strategy tags (ccSingle / ccMulti)
    chronos.nim                         # NET-NEW: Tier 3 async adapter (soft dep)
```

One-line role per file is given inline above. The reserved future
files (`ebr.nim`, `debra_plus.nim`, `hazard.nim`, `ibr.nim`, `nbr.nim`)
are not shipped in v0.1.0 but their names are reserved: future SMR
strategies will land under `lockfree/smr/<strategy>.nim` and may have a
sibling `lockfree/smr/<strategy>/` directory if they need multi-file
internals (same shape as `nebr`).

Naming note (per Q-FAITHFUL + operator decision 2026-06-06): the SMR
module is `nebr` (Neutralizable EBR), NOT `debra_plus`. The name
`debra_plus` is reserved on disk for a future, faithfully-implemented
Brown 2015 DEBRA+. v0.1.0 ships nebr only.

## 1.4 Dependency boundaries (intra-package)

Arrows mean "imports". No cycles; no module imports a higher-level
module than itself.

```
                ┌──────────────────────────────┐
                │ lockfree/atomics             │ (atomics/, dsl, backoff)
                └──────────────┬───────────────┘
                               │
        ┌──────────────────────┼───────────────────────┐
        │                      │                       │
        ▼                      ▼                       ▼
┌────────────────┐   ┌────────────────────┐   ┌────────────────────┐
│ smr/nebr       │   │ managed_ref        │   │ managed_slice      │
└────────┬───────┘   └─────────┬──────────┘   └─────────┬──────────┘
         │                     │                        │
         │                     │                        │
         │            ┌────────┴────────────────────────┘
         │            │
         ▼            ▼
   ┌────────────────────────────┐         ┌──────────────────────────┐
   │ lockfree/queue (unbounded) │         │ lockfree/bqueue (bounded)│
   │  imports: atomics,         │         │  imports: atomics,       │
   │           smr/nebr,        │         │           typestates,    │
   │           typestates;      │         │           managed_ref,   │
   │           managed_ref,     │         │           managed_slice  │
   │           managed_slice    │         │  (NO smr/nebr — BQueue   │
   │                            │         │   doesn't need EBR;      │
   │                            │         │   pre-allocated slots)   │
   └─────────────┬──────────────┘         └─────────────┬────────────┘
                 │                                      │
                 └──────────────┬───────────────────────┘
                                ▼
                       ┌───────────────────┐
                       │ lockfree/chronos  │ (Tier 3 async adapter)
                       │  imports: queue,  │
                       │           bqueue; │
                       │  cond imports     │
                       │  chronos          │
                       └───────────────────┘
```

Table form:

| Module | Imports (in `lockfree/`) | External imports |
|---|---|---|
| `lockfree` (top-level) | — | — |
| `lockfree/atomics` | — | `std/atomics` |
| `lockfree/smr/nebr` | `lockfree/atomics` | `std/atomics`, OS signal API |
| `lockfree/managed_ref` | `lockfree/atomics` | per-MM arm: arc/orc/atomicArc refcount intrinsics, nimony arcInc/arcDec, refc internals; none for mm:none |
| `lockfree/managed_slice` | `lockfree/atomics` | same per-MM arms as managed_ref |
| `lockfree/typestates` | `lockfree/atomics` | nim-typestates |
| `lockfree/queue` | `lockfree/atomics`, `lockfree/smr/nebr`, `lockfree/typestates`; internally references `managed_ref` and `managed_slice` via `when T is ref:` / `when T is string \| seq:` dispatch | nim-typestates |
| `lockfree/bqueue` | `lockfree/atomics`, `lockfree/typestates`; internally references `managed_ref` and `managed_slice` via same dispatch (NO `smr/nebr` — bounded queues use pre-allocated slots) | nim-typestates |
| `lockfree/chronos` | `lockfree/queue`, `lockfree/bqueue` | conditionally `chronos` (soft dep — see Section 1.5) |

Key invariants:

1. **An atomics-only consumer does not pull in nebr.** A user who
   writes `import lockfree/atomics` to build their own lock-free data
   structure gets the atomics primitives and nothing else. This is the
   "module-as-feature" pattern (Section 1.6).
2. **BQueue does not import the SMR layer.** Bounded queues have
   pre-allocated slots; there is no deferred reclamation problem.
   Per the handoff Path C disposition, BQueue gets the same
   `ManagedRef`/`ManagedSlice` internal dispatch as Queue, but it does
   not require — and must not import — `lockfree/smr/nebr`.
3. **`chronos` is a SOFT dependency.** `lockfree/chronos` is the only
   module that touches chronos, and it does so conditionally (see
   Section 1.5).
4. **`managed_ref` and `managed_slice` are internal-only**. Per Path C,
   users never write `ManagedRef[X]` in their own code; the queue API
   accepts `ref T` and dispatches internally. The same holds for
   `ManagedSlice` and `string` / `seq[T]`. See Section 2 for the
   composition matrix.

## 1.5 External dependencies (`lockfree.nimble`)

Concrete requirement list:

```
# lockfree.nimble (v0.1.0)
version       = "0.1.0"
author        = "elijahr"
description   = "Lock-free queues, SMR, and refcounted-payload support for Nim"
license       = "MIT"
srcDir        = "src"

requires "nim >= 2.0.0"                  # see Q5 finding (Section 1.5.1)
requires "typestates >= 0.12.0"          # exact pin set at lift time

# chronos is NOT a hard requirement.
# Tier 3 async adapter activates if chronos is importable OR -d:lockfreeChronos.
# requires "chronos >= 4.0.0"            # <-- intentionally omitted
```

### 1.5.1 Nim version pin rationale

Per Phase 1.5 Q5 finding, `lockfree/managed_ref` uses Nim 2's
refcount intrinsics (`nimIncRef`, `nimIncRefCyclic`,
`nimDecRefIsLast*` and the orc cyclic variants) directly. These
symbols are runtime-internal and have evolved across Nim 2.x point
releases. The version pin must:

- Lower-bound on the first Nim release that exposes the full intrinsic
  set we use across arc/orc/atomicArc (TBD at lift time — see §7.4 OQ4.1
  / OQ4.5; expected to be Nim 2.0.x).
- Be **revisited at lift time**: the lift author must run the smoke
  test against `nim --version` to confirm the symbols resolve under
  arc, orc, and atomicArc before locking the pin.
- Be re-validated whenever the devel cell in CI catches symbol drift
  (per Section 6 CI matrix).

Recommended placeholder pin for the initial commit:
`requires "nim >= 2.0.0"`. The CI devel cell (Section 6) is the
canary for upper-bound regressions.

### 1.5.2 chronos soft-dep pattern (per CRITICAL #4)

`lockfree/chronos.nim` opens with the hybrid auto-detect / opt-in
guard:

```nim
when defined(lockfreeChronos) or (compiles do: import chronos):
  import chronos
  # ... Tier 3 adapter implementation ...
else:
  {.error: "lockfree/chronos requires either -d:lockfreeChronos with " &
           "chronos installed, OR chronos importable in your project. " &
           "Add `requires \"chronos >= 4.0.0\"` to your .nimble file or " &
           "pass -d:lockfreeChronos.".}
```

Three user scenarios (CRITICAL #4 disposition):

| User has chronos installed? | `-d:lockfreeChronos` set? | `import lockfree/chronos` outcome |
|---|---|---|
| Yes | unset | Compiles and works (auto-detect) |
| Yes | set | Compiles and works (opt-in) |
| No | unset | Static error with actionable fix instructions |
| No | set | Static error: user opted in but chronos not installed |

Users who never `import lockfree/chronos` pay zero cost regardless.

## 1.6 Module-as-feature pattern

Each top-level module under `lockfree/` is independently consumable.
`import lockfree/atomics` does NOT transitively pull in `smr/nebr`,
`queue`, or `chronos`. `import lockfree/queue` pulls in atomics, nebr,
typestates, managed_ref, managed_slice (because Queue's `when T is ref:`
dispatch references them), but NOT chronos or bqueue.

This is enforced by the dependency boundaries in Section 1.4 (no
upstream module imports a downstream one) and verified by the CI
smoke matrix (Section 6): one matrix cell per top-level module
imports just that module and asserts a minimal compile.

## 1.7 `lockfree.nim` is intentionally near-empty

```nim
## lockfree umbrella — see lockfree/<module> for actual functionality.
##
## This top-level module deliberately does NOT auto-import the world.
## Choose what you need:
##   import lockfree/atomics      # primitives (CAS, DWCAS, fences, backoff)
##   import lockfree/smr/nebr     # EBR-with-neutralization SMR
##   import lockfree/queue        # unbounded MPMC/MPSC/SPMC/SPSC
##   import lockfree/bqueue       # bounded MPMC/MPSC/SPMC/SPSC
##   import lockfree/chronos      # Tier 3 async adapter (requires chronos)
const Version* = "0.1.0"
```

Rationale:

1. **No surprise transitive cost.** `import lockfree` should not drag
   chronos, the SMR layer, or the queue machinery into a project that
   only wanted to check the version constant or do a feature probe.
2. **Module-as-feature discoverability.** The doc-comment above
   serves as the entry-point index for the umbrella; the README
   mirrors it.
3. **Stable version surface for downstream packages.** Tools and
   nimble lockfiles can `import lockfree` to read `Version` without
   committing to any specific subsystem.

There is no plan to add re-exports here in v0.1.0. The umbrella is
explicitly NOT a "convenience module" that re-exports everything.

## 1.8 Pre-T-INTEGRATE vs post-T-INTEGRATE state

T-INTEGRATE.a–f is the code-lift sequence that produces the layout in
Section 1.3. The shape of the move:

| Pre-T-INTEGRATE (today) | Post-T-INTEGRATE (target) |
|---|---|
| `src/lockfree.nim` | `src/lockfree.nim` (rewritten; just `const Version`) |
| `src/lockfree/queue.nim` | `src/lockfree/queue.nim` |
| `src/lockfree/bqueue.nim` | `src/lockfree/bqueue.nim` |
| `src/lockfree/typestates/` | `src/lockfree/typestates/` |
| `src/lockfree/internal/` | `src/lockfree/internal/` |
| `src/lockfree/{backoff,endpoint,endpoint_types,exceptions,reclamation,role_tags,spawn,strategy}.nim` | `src/lockfree/<same>.nim` |
| `imports/nim-debra/src/debra/atomics.nim` + `atomics/` | `src/lockfree/atomics.nim` + `atomics/` |
| `imports/nim-debra/src/debra/{constants,convenience,limbo,manager,refptr,signal,thread_id,types}.nim` | `src/lockfree/smr/nebr/<same>.nim` |
| `imports/nim-debra/src/debra/typestates/` | `src/lockfree/smr/nebr/typestates/` |
| (none) | `src/lockfree/managed_ref.nim` (net-new) |
| (none) | `src/lockfree/managed_slice.nim` (net-new) |
| (none) | `src/lockfree/chronos.nim` (net-new) |
| `imports/nim-debra/` (whole staging tree) | DELETED in T-INTEGRATE.f |
| `lockfree.nimble` | `lockfree.nimble` (rewritten — see Section 1.5) |

T-INTEGRATE sub-tasks (cross-reference; full task definitions in the
impl plan, Section 7 of the design doc covers docs IA / migration):

1. **T-INTEGRATE.a** — move atomics: `imports/nim-debra/src/debra/atomics*` → `src/lockfree/atomics*`.
2. **T-INTEGRATE.b** — lift nebr internals: `imports/nim-debra/src/debra/{constants,convenience,limbo,manager,refptr,signal,thread_id,types}.nim` and `typestates/` → `src/lockfree/smr/nebr/`. Includes creating `src/lockfree/smr/nebr.nim` as facade. ALSO net-new: write `src/lockfree/managed_ref.nim` and `src/lockfree/managed_slice.nim`.
3. **T-INTEGRATE.c** — rewrite import paths repo-wide: `lockfreequeues/...` → `lockfree/...`; `debra/...` → `lockfree/smr/nebr/...`; `debra/atomics` → `lockfree/atomics`.
4. **T-INTEGRATE.d** — rewrite text references: `nim-debra` → `lockfree/smr/nebr`; `DEBRA+` → `nebr (EBR with manual neutralization, ancestrally derived from Brown 2015 DEBRA+ — arXiv:1712.01044)`. Bibliographic citations of Brown 2015 are preserved.
5. **T-INTEGRATE.e** — lift tests under `tests/smr/nebr/` (segregated subdir; rename test prefixes from `debra_` to `nebr_`).
6. **T-INTEGRATE.f** — delete `imports/nim-debra/` after all references resolved.

Additional scan added at handoff time:
- Sub-task in T-INTEGRATE.d scans for `debra` text references in
  comments/docs that should become `nebr` (excluding bibliographic
  citations of Brown 2015, which remain).

## 1.9 Implicit user-facing identity

What does a user actually type? Concrete import statements for the
four primary use cases:

### Case 1: Generic POD-payload unbounded MPMC queue

```nim
import lockfree/queue
import lockfree/strategy   # for ccMulti

type Tick = object
  ts: int64
  value: float64

var q: Queue[Tick, ccMulti, ccMulti]
q.init()
discard q.push(Tick(ts: 1, value: 3.14))
let got = q.pop()
```

Pulls in: atomics, smr/nebr, typestates, managed_ref, managed_slice
(via internal dispatch tables, but the `when T is ref:` arm doesn't
fire for `Tick`). Does NOT pull in chronos or bqueue.

### Case 2: Bounded SPSC queue for an audio ringbuffer (`mm:none`)

```nim
# Compile with: nim c --mm:none --threads:on audio_app.nim
import lockfree/bqueue
import lockfree/strategy   # for ccSingle

type Sample = object
  l, r: float32

const RingCapacity = 1024
var ring: BQueue[Sample, ccSingle, ccSingle, RingCapacity]
ring.init()
# In the audio thread:
discard ring.push(Sample(l: 0.1, r: 0.1))
# In the GUI thread:
let s = ring.pop()
```

Pulls in: atomics, typestates, managed_ref, managed_slice (compile-time
no-ops under `mm:none` for POD payloads). Does NOT pull in smr/nebr,
queue, or chronos. mm:none compatibility is REQUIRED per the handoff
"mm:none added to MM compat matrix" decision; the BQueue path
compiles down to pure bit transport.

### Case 3: Refcounted-payload queue with async support

```nim
import lockfree/queue
import lockfree/chronos   # Tier 3 async adapter; requires chronos installed
import lockfree/strategy

type Job = ref object
  id: int
  payload: string

var q: Queue[ref Job, ccMulti, ccMulti]   # user writes `ref Job`, NOT ManagedRef
q.init()

proc producer() {.async.} =
  await q.pushAsync(Job(id: 1, payload: "hi"))

proc consumer() {.async.} =
  let job = await q.popAsync()
  echo job.id, " ", job.payload
```

The user types `ref Job`. Internally, Queue's `when T is ref:` arm
dispatches through `lockfree/managed_ref` to bit-transport the ref via
the `ManagedRef` slot type and the per-MM compat shim. Per Path C
(handoff Phase 1.6 disposition), `ManagedRef` is internal-only and
never appears in user code.

### Case 4: Standalone SMR layer for a user's own lock-free data structure

```nim
import lockfree/smr/nebr
import lockfree/atomics

# user implements their own Treiber stack, Michael-Scott queue, etc.,
# using nebr.guard / nebr.retire / nebr.pinnedScope for safe reclamation.
```

Pulls in: atomics, smr/nebr. Does NOT pull in queue, bqueue, managed_ref,
managed_slice, or chronos. This is the "module-as-feature" payoff:
the SMR layer is independently consumable.

## 1.10 Open questions for Phase 2.2 review

Items where Section 1 surfaces ambiguity rather than inventing an
answer; these need resolution before T-INTEGRATE begins.

1. **Q1.10-A — `lockfree/typestates.nim` facade contents.**
   The current `src/lockfree/typestates.nim` re-exports the
   subdir. After the lift, is `lockfree/typestates.nim` still needed
   as a facade, or do users `import lockfree/typestates/<file>`
   directly? Section 1.3 keeps the facade for layout symmetry with
   `atomics.nim` and `smr/nebr.nim`. Confirm in Section 5 (API surface).

2. **Q1.10-B — `lockfree/queue.nim` internal references to managed_ref.**
   Section 1.4 states `queue.nim` "internally references managed_ref
   and managed_slice via `when T is ref:` / `when T is string \| seq:`
   dispatch." The exact import mechanism (top-of-file unconditional
   import vs. `when` block at the dispatch point) affects what shows
   up in the dependency graph of a POD-only consumer. Recommendation:
   unconditional import (small compile-time cost only); confirm in
   Section 2 when the Path C composition matrix is finalized.

3. **Q1.10-C — `lockfree/backoff.nim` vs `lockfree/atomics/backoff.nim`.**
   Section 1.3 keeps both: a queue-level backoff (lifted from
   lockfreequeues) and an atomics-level backoff (lifted from
   nim-debra). They have different call sites. Confirm in Section 5
   that this is the right split, or consolidate to one module.

4. **Q1.10-D — Reserved SMR module names: comment-only or stub files?**
   Section 1.3 leaves `ebr.nim`, `debra_plus.nim`, `hazard.nim`,
   `ibr.nim`, `nbr.nim` as comments in the tree, not as real files.
   An alternative is to ship stub files that `{.error.}` with "not
   implemented in v0.1.0" to make the reservation visible in tooling.
   Recommendation: comment-only (don't ship stubs that contribute
   nothing); confirm in Section 7.

5. **Q1.10-E — Top-level `lockfree.nim` doc-comment scope.**
   Section 1.7 shows a doc comment with five recommended imports. If
   future SMR strategies land, this list grows. Decide whether the
   doc comment should be the source of truth (and maintained) or
   redirect to the README (and stay minimal). Recommendation: keep
   minimal, link to README in Section 7's docs IA.

---

End of Section 1. Next: Section 2 — Type System & Payload Types
(Path C composition matrix, POD vs `ref T` vs `string`/`seq[T]`
dispatch, `ManagedRef`/`ManagedSlice` slot layouts).
