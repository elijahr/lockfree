# Section 3: SMR Architecture & nebr

> Status: v0.1.0 design — Section 3 of 7. Locked decisions per handoff
> Session updates (2026-06-05), Q-FAITHFUL verdict, Q-DWCAS verdict,
> and operator decisions 2026-06-06. Sibling sections: architecture (1),
> types & payloads (2), MM compat shim (4), public APIs (5), CI +
> nimony (6), docs IA + risks (7).

## 3.1 SMR namespace structure

Safe-memory-reclamation (SMR) strategies live under `lockfree/smr/<strategy>`.
The submodule pattern is deliberate: each strategy is a self-contained
module that consumers import explicitly. There is no `lockfree/smr`
default alias and the umbrella `lockfree.nim` does NOT re-export an
SMR layer (Section 1.7). A consumer who needs SMR must spell the
variant: `import lockfree/smr/nebr`.

v0.1.0 ships exactly ONE SMR strategy: `nebr`. Other strategy module
names are reserved in the source tree as comments (see Section 1.3):

```
lockfree/smr/
  nebr.nim                    # facade re-exporting nebr/
  nebr/                       # multi-file impl (lifted from nim-debra)
  # ebr.nim                   # RESERVED: classic Fraser EBR (future)
  # debra_plus.nim            # RESERVED: actually-faithful Brown 2015 DEBRA+ (future)
  # hazard.nim                # RESERVED: Hazard Pointers (future)
  # ibr.nim                   # RESERVED: Interval-Based Reclamation (future)
  # nbr.nim                   # RESERVED: Neutralization-Based Reclamation (future)
```

The reserved names are **comments only**, not stub files. The
recommendation in Section 1.10 Q1.10-D is to keep them as comments
(not ship `{.error.}` stubs) because empty stubs contribute nothing
and pollute tooling. The reservation is documentary, not enforced by
the compiler.

### 3.1.1 Why explicit imports, not a default alias

Three reasons SMR strategy choice is forced into the import path:

1. **Variant awareness.** Different SMR strategies have semantically
   different progress and liveness guarantees. A user who writes
   `import lockfree/smr` and gets "whatever is default" loses the
   ability to reason about which guarantees they are buying. Explicit
   variant in the import line keeps the choice visible at every call
   site that imports it.

2. **Independent evolution.** Each `lockfree/smr/<strategy>` module
   can evolve independently. `nebr` is the v0.1.0 ship vehicle; future
   `debra_plus` (faithful Brown 2015) would be additive and ABI-neutral
   to `nebr`. A default alias would force coupling between strategy
   versions.

3. **No transitive cost.** A user who imports `lockfree/atomics` to
   build their own data structure does NOT want the SMR layer pulled
   in by an alias-import in some downstream file. The module-as-feature
   discipline (Section 1.6) forbids this.

### 3.1.2 Relationship to `lockfree/strategy` (cardinality)

The existing `lockfreequeues/strategy.nim` defines `ccSingle` /
`ccMulti` — the producer/consumer **cardinality** strategy. After the
lift it becomes `lockfree/strategy.nim` (Section 1.3, T-INTEGRATE.c).

This is **orthogonal** to SMR variant choice. Cardinality is a phantom
type parameter that flows into `Queue[T, PCC, CCC]`, `BQueue[T, PCC,
CCC, N]`, and into the nebr typestate generic params (`CC: static
PinScopeCardinality`, see `typestates/guard.nim:60-86`). SMR variant
is the **module** the user imports for safe reclamation.

The two strategy axes do not constrain each other in v0.1.0:

| Cardinality choice | SMR choice (v0.1.0) |
|---|---|
| ccSingle producer / ccSingle consumer | nebr (or none for BQueue) |
| ccSingle / ccMulti | nebr (or none for BQueue) |
| ccMulti / ccSingle | nebr (or none for BQueue) |
| ccMulti / ccMulti | nebr (or none for BQueue) |

(Future: a Hazard Pointer SMR variant might restrict to bounded
hazard count, which would interact with cardinality. Not in scope.)

## 3.2 What `nebr` actually is — and isn't

**Definition.** `nebr` (Neutralizable EBR) is Epoch-Based Reclamation
augmented with a manual, operator-driven, signal-based thread
neutralization mechanism. It is **inspired by** Brown 2015 DEBRA+
([arXiv:1712.01044](https://arxiv.org/abs/1712.01044)) but the
implementation diverges from the paper in several substantive ways.
v0.1.0 ships nebr; it does NOT ship a faithful Brown 2015 DEBRA+.

The name **`debra_plus` is RESERVED** in `lockfree/smr/` (Section 1.3)
for a future, actually-faithful Brown 2015 DEBRA+ implementation.
v0.1.0 deliberately does not claim that name.

### 3.2.1 The D1–D9 deviation table (from Q-FAITHFUL)

The complete deviation analysis lives in
[`docs/internal/debra-plus-provenance.md`](../debra-plus-provenance.md)
(537 lines). Restated here in compact form with file:line cites:

| # | Class | What changes | Cite (nim-debra source post-lift) |
|---|---|---|---|
| D1 | Semantic | Limbo: paper uses **3 fixed bags** (`epoch mod 3`); nebr uses an **unbounded FIFO linked list of bags** stamped with retire-time epoch | `limbo.nim:23-27`, `typestates/retire.nim:170-202` |
| D2 | Semantic | Paper advances via `CAS(&epoch, readEpoch, readEpoch+1)` gated by a quiescence-scan precondition; nebr advances via unconditional `fetchAdd(1)` with safety recovered at reclaim time | `typestates/advance.nim:69-71`, `convenience.nim:281-287` |
| D3 | Semantic (omitted) | Paper's `sigsetjmp`/`siglongjmp` in-operation recovery + caller-side `help(desc)` machinery is **ABSENT** in nebr | n/a — nothing implements it |
| D4 | Semantic (policy) | Paper auto-suspects neutralization inside `leaveQstate`; nebr replaces with **explicit operator-driven** `neutralizeStalled(manager, threshold)` | `typestates/neutralize.nim:46-128`, `convenience.nim` |
| D5 | Engineering | Paper uses idempotent CAS for advance; nebr uses `fetchAdd(1, moRelease)` | `typestates/advance.nim:70` |
| D6 | Engineering | No object pool / blockbag / 256-record blocks; nebr uses `c_calloc`/`c_free` per 64-object `LimboBag` and never recycles | `limbo.nim:9, 29-43` |
| D7 | Semantic (omitted) | No Hazard Pointer integration (`RProtect` / `isRProtected` / scan-and-swap-to-front in `rotateAndReclaim`) — coupled to D3 | n/a — nothing implements it |
| D8 | Engineering | Paper packs `(epoch \| quiescent_bit)` into one word; nebr uses separate `pinned: Atomic[bool]` + `epoch: Atomic[uint64]` + `neutralized: Atomic[bool]` per slot, restoring ordering via SC RMW on `pinned` | `typestates/guard.nim:118-136`, `types.nim` |
| D9 | Engineering | Per-thread `checkNext`/`opsSinceCheck` incremental cross-thread scan ABSENT; reclaim does a full `MaxThreads`-wide scan each time | `typestates/reclaim.nim:215-219` |

**Semantic vs engineering:** D1, D2, D3, D4, D7 change what counts as a
correctness argument — the paper's safety proof relies on machinery
that nebr does not implement. D5, D6, D8, D9 change the code shape but
not the algorithm contract.

**`+` (fault tolerance) status: PARTIAL.** The paper's `+` denotes "a
stalled or crashed thread can be neutralized AND the data structure
recovers from the partial operation." nebr ships the **neutralize half**
(force-unpin via SIGUSR1) but NOT the **recovery half** (sigsetjmp/HP/
`help(desc)`). Section 3.8 catalogs what nebr does not implement.

### 3.2.2 Why NOT named `debra_plus`

The operator decision 2026-06-06 reserves `debra_plus` for a future,
actually-faithful Brown 2015 implementation. Three reasons drive
this:

1. **Honest naming.** Q-FAITHFUL demonstrates 5 semantic deviations
   from the paper algorithm. Calling the impl `debra_plus` would be
   defensible under loose attribution conventions (Q-FAITHFUL §6.1
   framing B/C), but the operator has chosen the maximally honest
   path: `nebr` accurately describes what the impl is (EBR plus
   neutralization), and `debra_plus` remains available for a future
   PR that actually delivers the paper algorithm.

2. **Forward compatibility.** A future contributor implementing a
   faithful Brown 2015 DEBRA+ can land it as
   `lockfree/smr/debra_plus.nim` without colliding with nebr. Both
   would coexist; consumers pick.

3. **Documentation alignment.** The Q-FAITHFUL provenance doc is the
   canonical reference for the deviation analysis; calling the v0.1.0
   impl `nebr` keeps the docs internally consistent (one name, one set
   of properties).

### 3.2.3 README attribution wording (v0.1.0 ship text)

The post-lift README block describing nebr lands as:

> **SMR** is provided by `lockfree/smr/nebr` — **Neutralizable EBR**,
> an Epoch-Based Reclamation variant inspired by
> [Brown 2015 DEBRA+](https://arxiv.org/abs/1712.01044). nebr implements
> the paper's signal-based thread-neutralization mechanism over a
> per-thread linked-list-of-epoch-stamped-bags limbo structure with
> unconditional epoch advance. nebr is NOT a faithful reimplementation
> of the paper: it omits the sigsetjmp-based in-operation recovery
> protocol and the hazard-pointer machinery that protect descriptors
> across recovery. Applications using `neutralizeStalled` must ensure
> their critical sections are restartable from the caller side or
> short enough to never actually be neutralized in practice. See
> `docs/internal/debra-plus-provenance.md` for the algorithm-fidelity
> analysis.

### 3.2.4 nim-debra README line 34 fix (T-INTEGRATE.d sweep)

The current nim-debra README line 34 reads:

> "This implementation follows Brown 2017, including the SIGUSR1
> protocol for neutralizing threads that have stalled inside a
> critical section."

Per Q-FAITHFUL §6.2, "follows" is overclaiming given D1–D4 and D7.
The T-INTEGRATE.d text-sweep rewrites this to:

> "This implementation is inspired by Brown 2017
> ([arXiv:1712.01044](https://arxiv.org/abs/1712.01044)), with
> significant structural deviations from the paper algorithm; in
> particular, it implements the SIGUSR1-based neutralization protocol
> for stalled threads but omits the paper's sigsetjmp-based
> in-operation recovery and hazard-pointer machinery. See
> `docs/internal/debra-plus-provenance.md` for the algorithm-fidelity
> analysis."

The bibliographic citation (currently README line 232,
"Trevor Brown. ... The DEBRA+ algorithm with signal-based
neutralization for stalled threads.") is left unchanged: it attributes
the algorithm family, not a fidelity claim.

## 3.3 Algorithm overview

nebr has five primary operations. All are implemented as typestate
FSMs (Section 3.5 / 3.10) with convenience wrappers in
`smr/nebr/convenience.nim`:

| Operation | Purpose | Typestate FSM | Convenience wrapper |
|---|---|---|---|
| **register** | Claim a per-thread slot | `Unregistered → Registered \| RegistrationFull` (`typestates/registration.nim:60-62`) | `registerThread(manager)` |
| **deregister** | Release the slot for reuse | (no typestate; symmetric op) | `unregisterThread` |
| **pin / unpin** | Enter / leave critical section, capturing epoch | `Unpinned → Pinned → Unpinned \| Neutralized` (`typestates/guard.nim:89-94`) | `withPinscope` block |
| **retire** | Mark a pointer for later reclamation | `RetireReady → Retired` (`typestates/retire.nim:55-56`) | `retireOnCAS` / `retireOnPublish` |
| **reclaim** | Walk own limbo bags, free epoch-safe objects | `ReclaimStart → EpochsLoaded → ReclaimReady \| ReclaimBlocked` (`typestates/reclaim.nim:88-92`) | `reclaimNow(handle)` |
| **advance** | Bump the global epoch counter | `Current → Advancing → Advanced` (`typestates/advance.nim:42-44`) | `manager.advance()`, `handle.advanceEvery(n)` |

Plus the manager lifecycle (Section 3.4) and the manual neutralization
operation `neutralizeStalled` (Section 3.7).

### 3.3.1 Protocol description

A correct use of nebr proceeds:

1. **Initialize manager** at process startup: `var m: DebraManager[MaxThreads]; initialize(m)`. Transitions `ManagerUninitialized → ManagerReady` (`typestates/manager.nim:46-62`).
2. **Each worker thread registers** once at thread start: `let h = registerThread(m)`. Claims a slot in `activeThreadMask` via CAS (`typestates/registration.nim:81-118`). Returns a `ThreadHandle[MT, CC]` carrying `(idx, manager)`.
3. **Critical-section work** uses `withPinscope(h)` (RAII guard, `typestates/pinned_scope.nim`):
   - Entry stores `epoch.store(globalEpoch, moRelease)` then SC RMW on `pinned` (`typestates/guard.nim:118-136`).
   - Body may load shared pointers, perform CAS, call `retire(ptr, dtor)`.
   - Exit SC-stores `pinned=false` (`typestates/guard.nim:165`), checks `neutralized`; if set, returns `Neutralized` and caller acknowledges (`typestates/guard.nim:167-170`).
4. **Periodic epoch advance** via `handle.advanceEvery(n)` (e.g. n=32). This is the cadence helper — only every Nth call performs the atomic `fetchAdd(1, moRelease)` on `globalEpoch` (`convenience.nim:281-287`).
5. **Periodic reclamation** via `reclaimNow(handle)`. Walks the calling thread's own bag list from tail (oldest), freeing bags with `bag.epoch < safeEpoch - 1` (`typestates/reclaim.nim:262-301`).
6. **Manager shutdown** at process end: `shutdown(m)`. Reclaims all remaining bags across all slots (`typestates/manager.nim:64-82`). Transitions `ManagerReady → ManagerShutdown`.
7. **Optional: manual neutralization** at any point an operator detects stall: `neutralizeStalled(m, threshold)`. See Section 3.7.

Steps 4 and 5 are operator-cadenced. nebr does not auto-advance or
auto-reclaim. This is a deliberate departure from the paper's
`leaveQstate`-driven cadence (Section 3.2.1 D9) and is documented as
"operator drives both retire and reclaim cadence" (Q-FAITHFUL §3.1).

## 3.4 Manager state machine

The manager is a heap- or stack-allocated `DebraManager[MaxThreads, CC]`
object. Its lifecycle is encoded as a typestate FSM in
`typestates/manager.nim:24-38`:

```
ManagerUninitialized
        │ initialize()         (typestates/manager.nim:46-62)
        ▼
ManagerReady ──────────────────► register/deregister/pin/retire/reclaim allowed
        │ shutdown()           (typestates/manager.nim:64-82)
        ▼
ManagerShutdown                 (terminal — no further operations)
```

### 3.4.1 What `initialize` does

`initialize(m)` (`typestates/manager.nim:46-62`):
- Sets `globalEpoch = 1` (Relaxed store; manager not yet observable
  to other threads).
- Clears `activeThreadMask = 0`.
- Clears `boundClients = 0` (the `bindClient`/`unbindClient` refcount).
- Zeros every slot's `epoch`, `pinned`, `neutralized`, `threadId`,
  `currentBag`, `limboBagTail` (Relaxed stores).

After `initialize`, the manager is publishable to worker threads.
Publication ordering is the caller's responsibility — typically the
manager pointer is stored into a shared location with `moRelease`.

### 3.4.2 Thread registration: when?

Threads register via `registerThread(handle)` (`registration.unregistered →
register`) — *after* `initialize` and *before* `shutdown`. Mid-lifetime.
The library does NOT support registering threads against an
`Uninitialized` or `Shutdown` manager; the typestate FSM forbids
`getManager()` extraction from those states.

A thread can be **deregistered** before the manager shuts down. `unregisterThread`
(in `convenience.nim`) clears the slot's `activeThreadMask` bit
atomically, allowing slot reuse by a subsequent `registerThread` call.

### 3.4.3 Mid-lifetime operations gated to Initialized

`pin`, `retire`, `reclaim`, `advance`, `neutralizeStalled` are all valid
ONLY against a `ManagerReady` state. The typestate FSM (`typestates/manager.nim:24-38`)
enforces this at compile time for callers that use the typestate API
directly. The convenience wrappers (`convenience.nim`) accept
`ptr DebraManager[MT, CC]` and implicitly assume the manager is in
`ManagerReady` — they are pass-through to `addr manager` and trust the
caller.

This is a known coverage gap: the convenience API has weaker
compile-time guarantees than the raw typestate API. Section 3.10
discusses what is and isn't tractable for typestate encoding.

### 3.4.4 Destroy contract

`shutdown(m)` walks every slot's bag list and calls `reclaimBag` on
each bag (which invokes the destructor for each retired object, then
`c_free`s the bag) (`typestates/manager.nim:70-79`).

**Open question (3.13 Q3.13-A): must all threads deregister before
shutdown?** The current impl does not require this — `shutdown` walks
all slots regardless of `activeThreadMask`. But running threads that
still hold a `ThreadHandle` against the shutdown manager would be
UB (any subsequent `pin`/`retire`/`reclaim` would touch freed-by-shutdown
state). The contract is: **all worker threads must have stopped using
the manager before `shutdown` runs.** Whether the FSM should enforce
"no registered threads at shutdown" is a Phase 2.2 question; the
current typestate allows shutdown from `ManagerReady` regardless of
`activeThreadMask`.

## 3.5 Pin lifecycle protocol

The pin/unpin FSM is the heart of nebr's safety model. Defined in
`typestates/guard.nim:76-95`:

```
Unpinned ──pin()──► Pinned ──unpin()──► Unpinned
                       │
                       │ unpin() observes neutralized=true
                       ▼
                   Neutralized ──acknowledge()──► Unpinned
```

`Closed` is a one-way terminal state used by the `PinnedScope` RAII
guard's destructor; user code does not transition to it directly
(`typestates/guard.nim:184-195`).

### 3.5.1 `withPinscope(handle)` block semantics

The RAII guard `PinnedScope` (in `typestates/pinned_scope.nim`) wraps
`pin → body → unpin`. Scope entry:

1. Acquire-load the current `globalEpoch` (`guard.nim:118`).
2. Release-store `neutralized=false` then `epoch=<captured>` on the
   slot (`guard.nim:119-120`).
3. SC RMW (`exchange(true, moSequentiallyConsistent)`) on `pinned`
   (`guard.nim:136`).

The SC RMW is the publication point. It is equivalent to "Release
store on `pinned` followed by SC thread fence" but uses RMW for TSAN
compatibility (TSAN does not model standalone SC fences; see Section
3.9). The RMW participates in C11's single SC total order S, so any
reclaimer's SC-load on `pinned` (`reclaim.nim:215-219`) is guaranteed
to observe either this pin or a strictly-prior state.

Scope exit:

1. SC store `pinned=false` (`guard.nim:165`). SC, not Release —
   reclaimer's SC-load needs the modification order to be totally
   ordered (`guard.nim:160-164` rationale comment).
2. Acquire-load `neutralized`. If set, transition to `Neutralized`
   (caller must `acknowledge` before next pin); else `Unpinned`
   (`guard.nim:167-170`).

### 3.5.2 Reentrance

Nested pinscopes on the same thread are NOT supported in the strict
typestate API — `pin(u: sink Unpinned)` consumes the `Unpinned`, so
calling `pin` on a value that is already `Pinned` would be a type error.
The convenience wrapper `withPinscope` similarly opens a new scope at
the lexical level; nesting `withPinscope` lexically inside another
`withPinscope` would attempt to claim the slot's `pinned` flag twice
and leave the slot in an inconsistent state on exit.

The fix in practice: a worker thread enters one pinscope per critical
section. Nested critical sections share the same pinscope (the pinned
epoch covers all reads inside it). The `pinnedFromRetired` helper
(`typestates/retire.nim:72-107`) lets a thread keep working in the
same pinned epoch across retires without unpinning.

### 3.5.3 Thread crash inside pinscope

If a thread dies inside `withPinscope` (segfault, abort, etc.), its
slot remains in `pinned=true` state with the captured epoch. The
global epoch can no longer pass that captured epoch from the
reclaimer's perspective (`safeEpoch = min over pinned thread epochs`,
`reclaim.nim:215-219`). Reclamation stalls indefinitely; memory grows.

`neutralizeStalled` (Section 3.7) is the escape valve: an operator
detecting the stall can signal the dead thread's slot to force-unpin.
On a truly-dead thread the signal handler runs in undefined context;
on a live-but-stuck thread it force-unpins the slot but leaves the
thread in undefined state (per D3 omission — nebr has no sigsetjmp
recovery path). Section 3.7 / 3.8 expand on this.

### 3.5.4 Cross-thread pin visibility

A pin published by thread T (SC RMW on `pinned`, `guard.nim:136`) is
visible to a concurrent reclaimer R (SC load on `pinned`,
`reclaim.nim:215-219`) at the moment R's load reads from a position
in `pinned`'s modification order at or after T's RMW. C11 §29.3
guarantees these SC ops are totally ordered in S, so the visibility
window is bounded: R either sees T's pin and includes T's epoch in
`safeEpoch`, or R's SC load precedes T's RMW in S — in which case T's
subsequent acquire-load of the protected pointer happens after any
release stores R has issued, so T cannot have observed a still-live
pointer to an object R is about to free.

This is the EBR subscription handshake. The SC ordering on `pinned`
is **load-bearing** for safety; see Section 3.9 Invariant 1.

## 3.6 Retire / reclaim protocol

### 3.6.1 `retire(handle, p, destructor)` mechanism

In the typestate API: `retireReady(pinned).retire(p, dtor)` consumes
the `RetireReady` and produces `Retired` (`typestates/retire.nim:109-205`).
The convenience wrapper `retireOnCAS(scope, ...)` calls this internally.

What `retire` does (`typestates/retire.nim:130-202`):

1. Compute `epoch = handle.manager.globalEpoch.load(moAcquire)`. The
   load is preceded by a stack-local SC RMW (`retire.nim:165-167`) to
   participate in S. The reason for stack-local rather than RMW on
   `globalEpoch` itself is cache-line bouncing avoidance (same
   rationale as `reclaim.nim:160-188`).
2. If `currentBag` is null or full (`count >= LimboBagSize` = 64),
   allocate a new `LimboBag` via `c_calloc`, stamp it with
   `bag.epoch = epoch`, link it into the FIFO at the head, update
   `currentBag` and (if list was empty) `limboBagTail` (`retire.nim:173-181`).
3. **Re-stamp `bag.epoch = epoch`** (`retire.nim:200`). This is the
   D1 invariant: every retire bumps the bag's stamp to the current
   global epoch, NOT just the creation-time stamp. The rationale comment
   at `retire.nim:184-198` explains why: an object retired at epoch
   K+2 must not be reclaimable at `safeEpoch >= K+2` while readers
   pinned at K+2 are still active; bumping `bag.epoch` to the current
   epoch is conservatively safe.
4. Insert the `RetiredObject(data: p, destructor: dtor)` at
   `bag.objects[bag.count]`, increment `bag.count`.

### 3.6.2 Retire bag structure (per D1)

```nim
type LimboBag* = object              # limbo.nim:23-27
  objects*: array[LimboBagSize, RetiredObject]   # LimboBagSize = 64
  count*: int
  epoch*: uint64                     # retire-time stamp (re-stamped per retire)
  next*: ptr LimboBag                # FIFO linkage: oldest -> newer -> newest
```

Per-thread slot fields (in `types.nim`):

- `currentBag: ptr LimboBag` — newest bag (head of FIFO).
- `limboBagTail: ptr LimboBag` — oldest bag (tail of FIFO).
- Linkage: `currentBag → ... → limboBagTail` where `next` walks
  newest-to-oldest (no — re-reading: `currentBag` is newest,
  `limboBagTail` is oldest, `next` chains oldest → newer → newest per
  `retire.nim:172` comment). Reclaim walks from `limboBagTail` toward
  head (`reclaim.nim:276`).

The list is **per-thread, unbounded, owned by the registered thread**.
No other thread touches it (cross-thread reclamation would race with
the owner's `retire` mutations on `currentBag` / `limboBagTail`, which
have no synchronization; `reclaim.nim:6-7, 247-249`).

### 3.6.3 Reclaim trigger

Reclaim is **caller-initiated**, not auto. Two entry points:

- `reclaimNow(handle)` — one-shot wrapper (`convenience.nim:289-324`).
  Builds `reclaimStart(handle).loadEpochs().checkSafe()`, runs
  `tryReclaim()` on `ReclaimReady`, returns 0 on `ReclaimBlocked`.
- `reclaimStart(handle) → loadEpochs() → checkSafe()` typestate chain
  (`typestates/reclaim.nim:94-236`) — explicit FSM for callers needing
  finer control or auditability.

There is no per-retire automatic reclaim trigger and no periodic
background reclaim. The operator decides the cadence. `retireAndReclaim`
(`convenience.nim:344+`) is a convenience that runs both in sequence
but does not change the policy.

### 3.6.4 `safeEpoch` computation

`loadEpochs` (`typestates/reclaim.nim:144-221`):

1. Issue SC RMW on a stack-local atomic (`reclaim.nim:189-195`). This
   participates in S and provides the StoreLoad barrier; rationale at
   `reclaim.nim:159-188`.
2. Acquire-load `ctx.globalEpoch = manager.globalEpoch` (`reclaim.nim:202`).
3. Initialize `ctx.safeEpoch = ctx.globalEpoch`.
4. Loop over slots `0 ..< MaxThreads` (`reclaim.nim:215-219`):
   - SC-load `threads[i].pinned`. If true:
     - Acquire-load `threads[i].epoch`.
     - If `threadEpoch < ctx.safeEpoch`, update `safeEpoch = threadEpoch`.

So `safeEpoch = min(globalEpoch, min over pinned threads of threadEpoch)`.

If no thread is pinned, `safeEpoch = globalEpoch`.

### 3.6.5 Reclaim safety guard

`tryReclaim` (`typestates/reclaim.nim:238-301`):

1. `safeEpoch = ctx.safeEpoch - 1` (`reclaim.nim:266`). The `-1`
   gives one full epoch of margin: an object retired AT epoch
   `safeEpoch` is NOT yet safe; an object retired at epoch `<
   safeEpoch` is safe.
2. Walk from `state.limboBagTail` (oldest) toward head.
3. For each bag: if `bag.epoch >= safeEpoch`, stop walking (bags are
   epoch-ordered, so no later bag is safe either). Else: iterate
   `objects[0 ..< count]`, call `obj.destructor(obj.data)`, count up.
4. Unlink the bag from the tail (`state.limboBagTail = bag.next`),
   adjust `currentBag` if it pointed at this bag, `freeLimboBag(bag)`.

The walk strips a contiguous prefix from the tail; no `prevBag`
bookkeeping is needed because reclamation is always tail-first.

The walk-doesn't-touch-bits property is load-bearing for the EBR
race-freedom argument. The reclaimer reads `safeEpoch` and `bag.epoch`,
and frees objects whose epoch is strictly less than `safeEpoch - 1`.
It does NOT walk a "freelist" or "live-set bit" structure. This
matters because, even if a reclaimer is mid-walk, no other thread
modifies the bag's `objects` array or `count` field — only the owning
thread retires, and the owning thread is the one running the reclaim.

## 3.7 Manual neutralization (per Q-FAITHFUL D4)

### 3.7.1 `neutralizeStalled(manager, epochsBeforeNeutralize)`

Defined as a typestate chain in `typestates/neutralize.nim:46-128`:

```
ScanStart ──loadEpoch(epochsBeforeNeutralize)──► Scanning ──scanAndSignal()──► ScanComplete
```

Convenience wrapper (`convenience.nim`): single-call form
`neutralizeStalled(manager, epochsBeforeNeutralize: uint64 = 2)`.

Mechanism (`neutralize.nim:84-116`):

1. Acquire-load `globalEpoch`.
2. Compute `threshold = max(0, globalEpoch - epochsBeforeNeutralize)`
   (`neutralize.nim:64-68`).
3. Acquire-load `activeThreadMask`. For each set bit `i`:
   - Acquire-load `pinned`. If false, skip.
   - Acquire-load `threadEpoch`. If `threadEpoch >= threshold`, skip
     (thread is up to date).
   - Acquire-load `threadId`. If invalid or `isCurrent(tid)`, skip
     (don't signal self or unset threads).
   - Call `neutralizeRemoteSlot(tid, i)`. POSIX: deliver SIGUSR1 via
     `pthread_kill`; the target's signal handler reads its
     `threadLocalIdx` and flips `pinned=false, neutralized=true`.
     Windows: SuspendThread → flip slot using explicit `i` →
     ResumeThread (`signal.nim`).
4. Increment `signalsSent` counter. Returns the count at
   `extractSignalCount(ScanComplete)`.

### 3.7.2 Distinction from paper's auto-neutralize

The paper's `suspectNeutralized(other)` fires automatically inside
`leaveQstate` when the calling process's own bag exceeds a size
threshold (Q-FAITHFUL §2.2 Fig 6). Fault tolerance is built into the
steady-state cadence.

nebr makes neutralization **opt-in and operator-driven**. The reclaim
path never invokes it. A nebr application that never calls
`neutralizeStalled` runs as plain EBR-with-unbounded-bags — i.e., a
distributed EBR variant with no fault tolerance.

### 3.7.3 Policy: who calls it, when

The recommended pattern (from nim-debra README, soon
`lockfree/smr/nebr` README post-T-INTEGRATE):

- **Application-level supervisor thread** calls `neutralizeStalled`
  on a timer (e.g., every N seconds) or on a watchdog trigger.
- Threshold `epochsBeforeNeutralize` should be larger than the worst
  expected critical-section duration measured in epochs. Default 2
  is suitable for hot-path queues where the average pin is sub-epoch;
  larger values (5–20) for queues with longer critical sections.
- A neutralized thread's next `unpin()` returns `Neutralized`. The
  caller must `acknowledge()` before re-pinning. If the thread is
  truly dead, the slot stays in `neutralized=true, pinned=false` and
  the supervisor (or a future deregister-cleanup pass) is responsible
  for releasing the slot.

The deliberate departure from the paper's auto-protocol is a
**design choice**, not an omission: operator policy varies wildly by
deployment, and forcing a universal threshold or trigger into the
library would be hostile to applications with non-standard latency
budgets.

## 3.8 What nebr does NOT implement (D3, D7)

Two semantic omissions from Brown 2015 DEBRA+ are catalogued here
explicitly because they affect what users can rely on.

### 3.8.1 No sigsetjmp / siglongjmp / `help(desc)` recovery (D3)

Paper (Fig 5): the signal handler for a non-quiescent neutralized
process runs `enterQstate(); siglongjmp(...)` to recovery code the
caller wrote inline (`if (sigsetjmp(...)) recovery(); else body();`).
Recovery reads `isRProtected(desc)`, calls `help(desc)` if another
process might have seen the descriptor, or restarts.

nebr signal handler (`signal.nim`): flips `pinned=false,
neutralized=true` on the target's slot. The interrupted thread
**continues from wherever it was** when SIGUSR1 fired. No
`siglongjmp`; no recovery code; the next `unpin()` returns
`Neutralized` and that is the entire contract.

**Consequence:** in-operation thread crashes during nebr critical
sections produce undefined behavior at the thread level. The slot's
state is now consistent for reclamation purposes (the global epoch
can advance, memory can be freed), but the interrupted thread is in
whatever state the signal interrupted it in — possibly mid-CAS,
mid-pointer-update, mid-allocation. For lockfreequeues this is
acceptable because the queue's critical sections do not modify
durable per-thread state that would need rollback. For general SMR
consumers, this is a **known limitation**.

### 3.8.2 No Hazard Pointer integration (D7)

Paper (Fig 6): `RProtect(r) / isRProtected(r) / RUnprotectAll()`
expose per-thread HP arrays used in two places:
- DEBRA+ recovery code to protect the descriptor across siglongjmp.
- `rotateAndReclaim` to scan HPs and swap protected records to the
  front of the current bag before reclaiming.

nebr implements neither. HPs in DEBRA+ exist primarily to enable
recovery (D3); with recovery omitted, HPs are also unnecessary. The
reclaimer's scan in `reclaim.nim:215-219` does NOT check any HP-like
structure — it only checks `pinned` and `epoch`. Any protection
discipline at the user layer must use the pin scope itself (an object
referenced inside `withPinscope` is protected by the epoch
mechanism).

### 3.8.3 What we ship vs. what is documented as known scope

Per operator standing rule (memory: `never-recommend-defer-to-followup`),
D3 and D7 are NOT framed as "deferred to v0.2.0." They are documented
as **known scope of nebr** — features the paper has that nebr does
not. v0.1.0 ships nebr. A future
`lockfree/smr/debra_plus.nim` could add them if/when an operator wants
the faithful paper algorithm; the name is reserved.

What users should expect from nebr v0.1.0:

- Thread crashes inside `withPinscope` → undefined behavior, AND
  pinned epoch never advances → memory grows until process exit (or
  the operator calls `neutralizeStalled` and accepts the
  thread-level UB).
- No HP-based protection of descriptors across recovery boundaries.
- Recommended use: critical sections are short, side-effect-bounded,
  and either restartable from the caller side or never actually
  neutralized in practice.

## 3.9 Safety argument — informal prose

This section presents the **condensed** safety argument. The full
derivation lives in
[`docs/internal/safety-argument.md`](../safety-argument.md).

The paper's safety proof relies on (i) the 3-bag structure (D1) and
(ii) the CAS-gated advance with quiescence-scan precondition (D2).
Neither holds in nebr. We derive a fresh safety argument grounded in
nebr's actual properties.

### 3.9.1 Invariants

**Invariant 1 (Pinning is publication-strong).** A thread `T` inside
`withPinscope(handle)` has its slot's `pinned: Atomic[bool]` flag set
to `true` and its `epoch: Atomic[uint64]` set to value `E`. Both are
published via SC RMW on `pinned` (`guard.nim:118-136`). The RMW
participates in C11 §29.3's single SC total order S, so any concurrent
SC load on `pinned` either observes `pinned=true` (and reads `epoch=E`
by Acquire) or precedes `T`'s RMW in S. While `T` remains pinned, no
other thread can advance `safeEpoch` past `E`.

> Cite: `typestates/guard.nim:103-138` (pin), `typestates/guard.nim:140-170`
> (unpin), `typestates/reclaim.nim:215-219` (SC subscription scan).

**Invariant 2 (Retire is stamped with current epoch).** A pointer
retired during pinscope is stamped with `bag.epoch = globalEpoch.load(moAcquire)`
**at retire time**, AFTER a stack-local SC RMW that participates in S
(`retire.nim:165-168, 200`). The stamp is **re-bumped on every retire**
into the same bag (`retire.nim:184-200`). This ensures `bag.epoch >=
max(pinned thread epochs of any thread that could have observed this
pointer)`.

> Cite: `typestates/retire.nim:130-202`. Rationale in comments at
> `retire.nim:184-198`.

**Invariant 3 (`safeEpoch` is the min over pinned epochs).**
`loadEpochs` (`reclaim.nim:144-221`) issues an SC RMW on a stack-local
atomic (participates in S), then SC-loads each slot's `pinned`
(participates in S), and for each pinned slot Acquire-loads `epoch`,
taking the min. The SC chain ensures: for every concurrent pinning
thread `T`, either (a) `T`'s pin RMW is visible in S at or before the
SC RMW here (so `loadEpochs` sees `pinned=true` and includes `T`'s
epoch in the min), or (b) `T`'s pin RMW is after in S (so `T`'s
subsequent Acquire-load of any protected pointer cannot observe a
state inconsistent with the reclaim's prior Release writes).

> Cite: `typestates/reclaim.nim:144-221`, esp. lines 189-219.

**Invariant 4 (Reclaim guard is `bag.epoch < safeEpoch - 1`).**
`tryReclaim` (`reclaim.nim:262-301`) computes `safeEpoch -= 1` and
frees any bag whose stamp is `< safeEpoch`. The `-1` is one full
epoch of margin: a bag retired AT epoch `safeEpoch` is NOT safe; a
bag retired at epoch strictly less than `safeEpoch` is safe by one
full epoch.

> Cite: `typestates/reclaim.nim:262-301`, esp. line 266.

### 3.9.2 Theorem (Safety)

**Claim:** Any pointer freed by `tryReclaim` was retired at an epoch
strictly less than `safeEpoch - 1`, and no currently-pinned thread
holds a reference to it.

**Proof sketch:**

Let `p` be a pointer freed by `tryReclaim` at some wall-clock moment
`t_free`. Let `B` be the bag containing `p` at `t_free`; let
`e_retire = B.epoch` (the bag's stamp). By Invariant 4, `e_retire <
safeEpoch_t_free - 1`, where `safeEpoch_t_free` was computed by the
same `tryReclaim` call.

Suppose for contradiction that some thread `R` is pinned at epoch
`e_R` at `t_free` and holds a reference to `p`. `R`'s reference must
have been acquired during some prior pinscope at some thread epoch
`e_R'`. Two cases:

**Case A**: `R` was pinned during the call to `loadEpochs` that
computed `safeEpoch_t_free`. Then by Invariant 3, `safeEpoch_t_free
<= e_R'`. By Invariant 4, `e_retire < e_R' - 1`, i.e. `e_retire +
1 < e_R'`. But for `R` to have observed `p` at epoch `e_R'`, the
retire of `p` must have happened-after `R`'s prior `pin`. By
Invariant 2, `e_retire >= max(observable pinned epochs)` at retire
time, so `e_retire >= e_R'`. Contradiction with `e_retire + 1 <
e_R'`.

**Case B**: `R` was NOT pinned during `loadEpochs`. Then `R`'s
current pin happened-after `loadEpochs`. By Invariant 1, `R`'s pin
RMW is publication-strong. `R`'s captured `e_R = globalEpoch.load(moAcquire)`
at `R`'s pin time. Since `R` pinned AFTER our `loadEpochs`'s
`globalEpoch` load, `e_R >= globalEpoch_at_loadEpochs >=
safeEpoch_t_free > e_retire + 1`. So `R`'s pin epoch is strictly
greater than `e_retire + 1`, meaning `R` pinned at least 2 epochs
after `p` was retired. For `R` to hold `p`, `R` must have observed
some published pointer to `p` AFTER `p`'s retire (because `R`'s pin
postdates the retire). But retire is the LAST publication of `p` by
any thread — by contract of the EBR API, the thread that retires `p`
has already detached `p` from all shared structures BEFORE retiring
(this is the caller's discipline; nebr does not enforce it
mechanically). So `R` cannot have observed `p` post-retire. Contradiction.

Therefore no pinned thread holds `p` at `t_free`, and `tryReclaim`'s
`destructor(p)` call is safe. ∎

### 3.9.3 Test suite cross-reference

The nim-debra test suite exercises these invariants. After T-INTEGRATE.e
(tests move under `tests/smr/nebr/`):

- `test_pin_unpin.nim` — basic FSM correctness.
- `test_retire_reclaim.nim` — single-thread retire/reclaim cycles.
- `test_concurrent_retire.nim` — multi-thread retire/reclaim stress;
  exercises Invariants 1–4 under contention.
- `test_neutralize.nim` — `neutralizeStalled` correctness.
- `test_tsan.nim` — TSAN-clean under sanitizer; validates the SC
  ordering choices in Invariants 1 and 3.

Section 6 (CI matrix) covers TSAN/ASAN/UBSAN cells that run these
tests under sanitizers on x86_64 and aarch64.

## 3.10 Safety argument — typestate-encoded guards

Beyond the prose argument, nebr encodes several properties as
compile-time typestate FSMs. The line "both informal prose +
typestate-encoded compile-time guards for tractable properties" from
the Phase 1.5 locked decisions translates into the breakdown below.

### 3.10.1 What IS tractable

Properties expressible as finite-state automata over typestate values
are tractable. nebr already encodes (and v0.1.0 keeps):

**Manager lifecycle FSM** (`typestates/manager.nim:24-38`):

```
ManagerUninitialized → ManagerReady → ManagerShutdown
```

Compile-time guards:
- Cannot `register / pin / retire / reclaim / advance` against a
  `ManagerUninitialized` or `ManagerShutdown` manager (no overload
  takes those types).
- Cannot `shutdown` twice (no `ManagerShutdown -> ManagerShutdown`
  transition; `shutdown` consumes via `sink`).
- Cannot `initialize` after shutdown.

Violation surface (negative test, post-lift `tests/smr/nebr/typestate_negatives/test_manager_after_shutdown.nim`):
```nim
var m = uninitializedManager(addr mgr).initialize().shutdown()
let h = registerThread(m)   # type error: registerThread does not take ManagerShutdown
```

**Registration FSM** (`typestates/registration.nim:44-62`):

```
Unregistered → (Registered | RegistrationFull)
```

Compile-time guards:
- Must inspect the `RegisterResult` variant before extracting a
  `ThreadHandle` — `getHandle` only takes `Registered`, not the
  parent variant.
- A `RegistrationFull` outcome is a typestate value, not an
  exception; the type system forces explicit handling.

**Pin lifecycle FSM** (`typestates/guard.nim:76-95`):

```
Unpinned → Pinned → (Unpinned | Neutralized) → Unpinned
                                     ↑
                              acknowledge()
```

Compile-time guards:
- Cannot `retire` from `Unpinned` (`retireReady` takes `Pinned`, not
  `Unpinned`).
- Cannot re-pin after `unpin` returns `Neutralized` without first
  calling `acknowledge`.
- Cannot leak a `Pinned` value — it is `sink`-consumed by `unpin`,
  and the `PinnedScope` RAII guard's `=destroy` enforces drainage.

Violation surface (negative test):
```nim
let n: Neutralized[4] = ...        # obtained from unpin
let p = unpinned(n.handle).pin()    # type error: n must be `acknowledge`d
```

**Retire FSM** (`typestates/retire.nim:44-56`):

```
RetireReady → Retired
```

Plus the `retireReadyFromRetired` / `pinnedFromRetired` helpers
that let the caller stay in the same pinned epoch across multiple
retires.

Compile-time guards:
- Cannot construct `RetireReady` without a `Pinned` (via `retireReady`
  taking `Pinned`).
- Cannot `retire` twice without going back through `retireReady`.

**Reclaim FSM** (`typestates/reclaim.nim:73-92`):

```
ReclaimStart → EpochsLoaded → (ReclaimReady | ReclaimBlocked)
```

Compile-time guards:
- Cannot call `tryReclaim` without going through `loadEpochs` and
  `checkSafe`.
- Cannot call `tryReclaim` on a `ReclaimBlocked` outcome (only
  `ReclaimReady` has the `tryReclaim` overload).
- The variant gating forces the caller to handle the "blocked"
  outcome explicitly (typically: do nothing, retry later).

**Advance FSM** (`typestates/advance.nim:31-44`):

```
Current → Advancing → Advanced
```

Mostly cosmetic — the `fetchAdd(1)` is unconditional and the FSM
just ensures the typed `oldEpoch` / `newEpoch` extraction goes
through the terminal `Advanced` state.

**Neutralize FSM** (`typestates/neutralize.nim:30-44`):

```
ScanStart → Scanning → ScanComplete
```

Compile-time guards:
- Cannot extract `signalsSent` without going through `scanAndSignal`.
- Cannot re-issue `loadEpoch` on an already-scanned context.

### 3.10.2 What is NOT tractable

Properties that depend on runtime state — counters, epoch values,
bag contents, set membership — cannot be encoded as a finite typestate
FSM and must be documented as **prose invariants** enforced by impl
correctness:

- **Retire bag state**: bag count, bag.epoch, linkage structure are
  all runtime values. The "bags are epoch-ordered" property (used by
  the reclaim walk) is a runtime invariant from the retire impl's
  monotonic stamping, not a type.
- **`safeEpoch` arithmetic**: `safeEpoch = min over pinned threads`
  is a runtime computation. No type captures "this `safeEpoch` value
  is the true min over the live thread set."
- **Reclaim safety guard**: `bag.epoch < safeEpoch - 1` is a runtime
  comparison. The type system cannot witness that a freed bag was
  actually epoch-safe.
- **Cross-thread visibility / SC ordering**: the C11 memory-model
  argument in Invariant 1 / Invariant 3 is a global property of the
  schedule, not a per-value type fact. Verified by TSAN + manual
  review of the SC RMW pattern.

These properties are covered by Section 3.9's prose argument and by
the test suite (Section 3.9.3).

### 3.10.3 Compile-error surface

Each tractable FSM produces clear compile errors on violation. The
negative-test directory (`tests/smr/nebr/typestate_negatives/`,
post-T-INTEGRATE) uses the `should_fail` pattern from
nim-typestates: each `.nim` file is annotated with the expected
compile error and the test driver invokes the compiler in
expect-fail mode.

Example violations and expected errors:

| User code | Expected error |
|---|---|
| `pin(p)` where `p: Pinned[4]` | type mismatch: expected `Unpinned[4, ccSingle]`, got `Pinned[4, ccSingle]` |
| `retire(p, dtor)` outside pinscope | type mismatch: `retireReady` expects `Pinned[...]` |
| Re-pin after `Neutralized` without `acknowledge` | type mismatch: `pin` expects `Unpinned`, got `Neutralized` |
| `tryReclaim(blocked)` | type mismatch: `tryReclaim` expects `ReclaimReady`, got `ReclaimBlocked` |
| `register(m)` against `ManagerShutdown` | type mismatch: no `register` overload for `ManagerShutdown` |

The exact error text depends on the nim-typestates version (pinned
at `typestates >= 0.12.0` per Section 1.5.1). Negative tests assert
the error patterns, not the exact strings.

### 3.10.4 Style and patterns

The typestate FSMs follow the same style as
`src/lockfree/typestates/` (post-lift `src/lockfree/typestates/`).
Shared conventions:

- `inheritsFromRootObj = true` on the underlying context object — so
  the typestate macro can generate `=copy` hooks correctly.
- `opaqueStates = true` so user code cannot construct intermediate
  states directly; only the documented transition procs produce them.
- `defaults: CC: ccSingle` so callers that spell only `MaxThreads`
  bind cleanly without writing `[N, ccSingle]` explicitly.
- Convenience wrappers in `convenience.nim` (post-lift
  `smr/nebr/convenience.nim`) hide the FSM chain for the common path
  but the explicit chain is always available for advanced use.

## 3.11 Memory model claims

### 3.11.1 Lock-free progress for retire

`retire(p, dtor)` is lock-free in the algorithmic sense: it performs
a finite number of atomic operations (one stack-local SC RMW, one
Acquire load of `globalEpoch`) plus a finite-bounded number of
non-atomic operations (one bag allocation in the worst case, fixed
stamp + insert). It does not loop on contention; the bag list is
per-thread and unsynchronized. No retire-side spinning.

This matches the paper's claim (Brown 2015 §4) for the retire
operation. nebr's retire is in fact **simpler** than the paper's
because nebr does not maintain the paper's `checkNext` / `opsSinceCheck`
incremental scan (D9 absent).

### 3.11.2 Lock-free progress for pin / unpin

`pin(u)` is lock-free: Acquire-load + 2 Release stores + 1 SC RMW.
`unpin(p)` is lock-free: 1 SC store + 1 Acquire load.

### 3.11.3 Lock-free progress for advance

`advance(c)` is lock-free: 1 `fetchAdd` on `globalEpoch`. The paper's
CAS-loop variant could in principle retry — nebr's unconditional
`fetchAdd` cannot.

### 3.11.4 Wait-free for reclaim's check; bounded-walk for tryReclaim

`loadEpochs` is wait-free over a single pass: it loops over
`MaxThreads` slots with bounded work per slot. No retries.
`tryReclaim` walks the local bag list, doing O(reclaimable objects)
work; the walk is bounded by the bag list's current length, which is
in turn bounded by the operator's retire rate × time since last
reclaim.

### 3.11.5 Memory bound (under operator-driven cadence)

The paper claims O(mn²) records waiting to be freed (§5), where `n`
is process count and `m` is the largest number of records removed
per high-level operation. The proof relies on the 3-bag structure
and the CAS-gated advance precondition, both of which nebr lacks.

**nebr does NOT claim O(mn²).** Per-thread bag list growth is bounded
by `(retire rate) × (time until next `reclaimNow` call with `safeEpoch >
bag.epoch + 1`)`. If the operator calls `reclaimNow` regularly AND the
global epoch advances regularly (e.g. via `advanceEvery(32)` on every
worker), bag list length stays bounded.

**Worst case (adversarial scheduling):** if a single thread is pinned
at epoch `E` and never unpins, `safeEpoch` is pinned at `E` and no
reclamation makes progress. Memory grows linearly with retire rate
until the operator either (a) calls `neutralizeStalled` to force-unpin
the stuck thread, or (b) tears the process down.

This is a deliberate property of nebr: the safety/liveness trade-off
favors safety (no premature reclamation under pin stall) over a
universal memory bound. The escape valve is the operator's
`neutralizeStalled` policy.

## 3.12 Operational considerations

### 3.12.1 When to call `neutralizeStalled`

Recommended patterns:

- **Application supervisor**: a dedicated thread runs a 1-second loop
  calling `neutralizeStalled(m, threshold=2)`. Cheap (one SC RMW + N
  Acquire loads + occasional `pthread_kill`).
- **Watchdog-triggered**: an existing supervisor that detects "thread
  X hasn't made forward progress in T seconds" calls
  `neutralizeStalled` as a recovery action.
- **Manual on shutdown initiation**: before shutting down a queue,
  drain pending operations by neutralizing any stuck consumers.

Anti-patterns:

- Calling `neutralizeStalled` from every retire — defeats the cadence
  helper, generates spurious signals.
- Using a very small threshold (`epochsBeforeNeutralize = 0`) — race
  with normal pinscope durations.

### 3.12.2 Recommended threshold values

| Workload | Recommended `epochsBeforeNeutralize` |
|---|---|
| Hot-path queue with `advanceEvery(32)` and sub-microsecond critical sections | 2–4 |
| Mixed-latency workload with occasional slow critical sections | 8–16 |
| Long critical sections (file I/O inside pinscope — not recommended but if needed) | 64+ |

The threshold is unitless (in epochs). Calibration: measure the 99th
percentile of "epochs elapsed during pinscope" under typical load,
multiply by a safety factor (4–10×).

### 3.12.3 Integration with debugging tools

- **TSAN (ThreadSanitizer)**: nebr is TSAN-clean. The SC RMW
  pattern in `pin` (`guard.nim:136`) and in `loadEpochs`
  (`reclaim.nim:189-195`) is specifically chosen to be modelable by
  TSAN's vector clocks. Rationale comments in those files cite the
  TSAN source location where standalone SC fences are NOT modeled.
  Section 6's CI matrix includes a TSAN cell.
- **Helgrind**: nebr should be Helgrind-clean modulo Helgrind's
  known limitations with C11 atomics. Not actively tested in v0.1.0
  CI; future work.
- **Valgrind (memcheck)**: nebr uses `c_calloc`/`c_free`; bag
  allocations are tracked by Valgrind. No reported leaks under
  typical use (shutdown reclaims all bags).
- **ASAN/UBSAN**: nebr is ASAN/UBSAN-clean per Section 6 CI matrix.

### 3.12.4 Cardinality (`ccSingle` vs `ccMulti`) interaction

The `CC: static PinScopeCardinality` parameter on every nebr typestate
flows from the manager type. `ccSingle` indicates the manager is used
by a single consumer (downstream queue with a single popper);
`ccMulti` is the general case. nebr's algorithm is CC-agnostic — the
parameter is carried so downstream queue libraries can specialize
behavior on cardinality at compile time. See `typestates/advance.nim`
docstring (lines 1-12) for the rationale.

In practice, lockfreequeues' Queue/BQueue types choose `CC` based on
the producer/consumer counts; nebr inherits whatever the consumer
chose.

## 3.13 Open questions for Phase 2.2 review

Items where Section 3 surfaces genuine ambiguity rather than inventing
an answer; these need resolution before T-INTEGRATE begins or before
v0.1.0 lock-down.

1. **Q3.13-A — Should `shutdown` require an empty `activeThreadMask`?**
   Currently `shutdown` (`typestates/manager.nim:64-82`) walks all
   slots regardless of registration. If a thread is still using the
   manager when `shutdown` runs, the result is UB. Adding a typestate
   precondition "no registered threads" is possible but invasive
   (requires the manager state to track registration cardinality at
   the type level — currently it does not). Recommendation: keep
   current behavior, document the contract in Section 3.4.4. Confirm
   in Phase 2.2.

2. **Q3.13-B — Should the convenience API have stronger typestate
   guarantees?**
   `reclaimNow(handle)` and friends accept `ThreadHandle` (which
   implicitly assumes `ManagerReady`) but the manager state is not
   threaded through the handle. A handle obtained before `shutdown`
   and used after `shutdown` would compile (UB at runtime). Threading
   the manager state through the handle is invasive. Recommendation:
   document the contract; do not add typestate complexity. Confirm in
   Phase 2.2.

3. **Q3.13-C — Should `neutralizeStalled` be exposed at the umbrella
   level?**
   Currently it is in `smr/nebr`. A future supervisor pattern (e.g.,
   a `lockfree/supervisor.nim` that owns the neutralize timer) might
   want to re-export it. Out of scope for v0.1.0; surfaced for
   Section 7's docs IA review.

4. **Q3.13-D — Memory bound documentation prominence.**
   Section 3.11.5 notes that nebr does NOT claim O(mn²) and that
   bag growth depends on operator cadence. The README and module
   doc-comment should make this prominent so users do not assume
   paper-equivalent bounds. Recommendation: 1–2 sentences in the
   module doc-comment, full discussion in `safety-argument.md`.

5. **Q3.13-E — Should the negative-test directory ship in v0.1.0?**
   `tests/smr/nebr/typestate_negatives/` (Section 3.10.3) requires
   the test runner to invoke the compiler in expect-fail mode. nim-debra
   already has some of these tests; the lift inherits them. Confirm
   in Section 6's CI matrix whether they run in every cell or only
   in a dedicated cell.

6. **Q3.13-F — `safeEpoch - 1` underflow at epoch 0.**
   `reclaim.nim:266` computes `safeEpoch - 1` as `uint64`. If
   `safeEpoch == 0` this underflows to `uint64.high`. The current
   impl avoids this via `checkSafe` (`reclaim.nim:228-236`) which
   returns `ReclaimBlocked` when `safeEpoch <= 1`. Confirmation that
   `checkSafe`'s `safeEpoch > 1` threshold is the right gate (not
   `>= 1`) is a Q-FAITHFUL §7 uncertainty surface. Recommendation:
   accept current behavior, add a unit test asserting `ReclaimBlocked`
   at epoch 0/1. Confirm in Section 6's CI cells.

---

End of Section 3. Next: Section 4 — MM compat shim (per-arm cell
shapes for arc/orc/atomicArc/refc/none, `ManagedRef[X]` slot
layout, `bindClient` / `unbindClient` interaction with nebr).
