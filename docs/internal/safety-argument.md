# nebr Safety Argument

> **PATHS UPDATED 2026-06-06 by T-INTEGRATE-RENAME**: `src/lockfreequeues/` references retargeted to `src/lockfree/`.

> Status: Phase 2 design deliverable. Canonical safety argument for
> the `nebr` SMR variant in `lockfree/smr/nebr`. Companion to
> Section 3 of the v0.1.0 design doc
> ([`design-sections/03-smr-architecture-and-nebr.md`](design-sections/03-smr-architecture-and-nebr.md)).
> The provenance of nebr (vs. Brown 2015 DEBRA+) is in
> [`debra-plus-provenance.md`](debra-plus-provenance.md).
>
> All file:line cites refer to the current nim-debra source tree at
> `imports/nim-debra/src/debra/`. After T-INTEGRATE.b these paths
> become `src/lockfree/smr/nebr/`; the line numbers are preserved by
> the pure file-move lift.

## 1. Scope and contract

This document derives the EBR safety property — *no thread observes a
freed object* — from nebr's actual implementation. The paper proof
(Brown 2015, §4) does not apply because nebr deviates from the paper
in five semantic ways (D1, D2, D3, D4, D7 in `debra-plus-provenance.md`).
This argument is fresh, grounded in nebr's properties.

### 1.1 What nebr guarantees

nebr provides safe-memory-reclamation for any data structure that
follows the **retire discipline**:

> A thread `T` retiring pointer `p` via `retire(p, dtor)` has already
> ensured that `p` is not reachable from any shared structure that
> threads might subsequently load from. In other words, the retire is
> the LAST publication of `p` by any thread.

Under this discipline, nebr guarantees:

- (S1) `dtor(p)` is called exactly once.
- (S2) `dtor(p)` is called only after every thread that could have
  observed `p` has either unpinned or been neutralized.
- (S3) Between retire and reclaim, `p` is unaltered (nebr does not
  walk or modify the retired objects array; see Section 6.3).

### 1.2 What nebr does NOT guarantee

- Memory bound. Per-thread bag list growth is unbounded under
  pin-stall (see Section 8 and Section 3.11.5 of the design doc).
- In-operation recovery from thread crash. A thread that dies inside
  `withPinscope` produces thread-level UB; nebr's `neutralizeStalled`
  is a *liveness* escape valve, not a *recovery* protocol (D3 omitted).
- Cross-thread retire safety. Cross-thread reclamation is forbidden;
  the bag list is owned by the registered thread (`reclaim.nim:6-7,
  247-249`).

## 2. The five state components

nebr's runtime state lives in these atomic and non-atomic fields
(`types.nim`, `limbo.nim:23-27`):

| Component | Type | Owner | Visibility |
|---|---|---|---|
| `manager.globalEpoch` | `Atomic[uint64]` | manager | shared |
| `manager.activeThreadMask` | `Atomic[uint64]` | manager | shared |
| `threads[i].pinned` | `Atomic[bool]` | slot i | shared |
| `threads[i].epoch` | `Atomic[uint64]` | slot i | shared |
| `threads[i].neutralized` | `Atomic[bool]` | slot i | shared (write by signal handler or self) |
| `threads[i].currentBag` | `ptr LimboBag` | slot i | thread-local (only slot owner reads/writes) |
| `threads[i].limboBagTail` | `ptr LimboBag` | slot i | thread-local |
| `bag.epoch` | `uint64` (in-allocation) | slot i (via bag chain) | thread-local |
| `bag.objects[k].data` / `.destructor` | `pointer / Destructor` | slot i | thread-local |

The shared/thread-local distinction is load-bearing: bag list state
is touched only by the owning thread (during retire and reclaim);
slot atomic flags are touched cross-thread (pin/unpin by owner,
SC-loads by reclaimers, signal handler writes during neutralize).

## 3. Invariants

The argument relies on four invariants. Each is established by a
specific implementation mechanism with a file:line cite.

### 3.1 Invariant I1: Pinning is publication-strong

**Statement:** While slot `i`'s `pinned` flag is `true`, no other
thread can advance `safeEpoch` past slot `i`'s captured `epoch`.

**Mechanism:**

In `pin` (`typestates/guard.nim:103-138`):

```nim
ctx.epoch = mgr.globalEpoch.load(moAcquire)                   # line 118
mgr.threads[idx].neutralized.store(false, moRelease)           # line 119
mgr.threads[idx].epoch.store(ctx.epoch, moRelease)             # line 120
# ... 12-line rationale comment for TSAN compatibility ...
discard mgr.threads[idx].pinned.exchange(true, moSequentiallyConsistent)  # line 136
```

The SC RMW on `pinned` is the publication point. It is semantically
equivalent to "Release store on `pinned` followed by an SC thread
fence" but uses RMW form for TSAN compatibility — TSAN does not model
standalone SC thread fences (rationale at `guard.nim:129-135`,
citing the relevant compiler-rt source location).

The RMW participates in C11 §29.3's single sequentially-consistent
total order S across **all** SC operations on **all** atomic
locations. The matching subscription point on the reclaimer side
(Section 3.3 / Invariant I3) is an SC load on the same `pinned`
location, which is totally ordered against this RMW in S.

In `unpin` (`typestates/guard.nim:140-170`):

```nim
mgr.threads[idx].pinned.store(false, moSequentiallyConsistent)  # line 165
```

The SC store ensures the modification order of `pinned` is fully
ordered with both the pin RMW and the reclaimer's SC load. Without
SC here, the reclaimer's SC load could read `pinned=false` while a
subsequent re-pin RMW is in flight, breaking the subscription
handshake.

**Why this establishes I1:** Suppose thread `T` is pinned at slot
`i` with `epoch[i] = E`. Any concurrent reclaimer `R` calling
`loadEpochs` (Section 3.3) issues an SC RMW (`reclaim.nim:189-195`),
then SC-loads `pinned[i]` (`reclaim.nim:215-216`). By C11 §29.3,
these SC ops are totally ordered in S with `T`'s pin RMW. Two cases:

- `T`'s RMW precedes `R`'s SC load in S → `R` reads `pinned=true`,
  acquire-loads `epoch[i] = E`, includes `E` in its `safeEpoch`
  minimum (`reclaim.nim:217-219`).
- `R`'s SC load precedes `T`'s RMW in S → `T`'s subsequent acquire
  reads of any shared structure happen-after `R`'s prior release
  writes; `T` cannot have observed a pointer to an object `R` is
  about to free, because `R` had not yet decided what to free at the
  S-position of `R`'s SC RMW.

So `R` cannot compute `safeEpoch > E` while `T` is pinned. ∎

### 3.2 Invariant I2: Retire is stamped with the current epoch

**Statement:** A pointer retired during pinscope is stamped with
`bag.epoch >= max(pinned thread epochs of any thread that could have
observed this pointer)`.

**Mechanism:**

In `retire` (`typestates/retire.nim:130-202`):

```nim
var subscribeBarrier: Atomic[uint64]
subscribeBarrier.store(0'u64, moRelaxed)
discard subscribeBarrier.fetchAdd(0'u64, moSequentiallyConsistent)  # line 167
let epoch = handle.manager.globalEpoch.load(moAcquire)              # line 168
# ... bag allocation / linkage ...
let bag = state.currentBag                                          # line 199
bag.epoch = epoch                                                   # line 200
bag.objects[bag.count] = RetiredObject(data: p, destructor: destructor)  # line 201
inc bag.count                                                       # line 202
```

The stack-local SC RMW (lines 165–167) participates in S. The
subsequent acquire-load of `globalEpoch` synchronizes-with the
release-stamping in `advance.nim:70` (the `fetchAdd(1, moRelease)`
on `globalEpoch`), yielding a value that dominates any predecessor
advance.

**Re-stamping (load-bearing).** Line 200 sets `bag.epoch = epoch` on
**every** retire, not just on bag creation. The rationale comment
(`retire.nim:184-198`) explains why: a bag accumulates retires across
multiple calls until it fills `LimboBagSize = 64`, and the global
epoch may advance between them. If `bag.epoch` were left at the
creation-time value, an object retired at epoch K+2 could be
reclaimed once `safeEpoch >= K+2` even though readers pinned at K+2
might still observe it. Bumping to the current epoch is
over-conservative for earlier objects in the bag (they live longer
than strictly necessary) but restores I2 for later objects.

Since `globalEpoch` is monotonic (only ever incremented), re-stamping
to the current value is equivalent to `max(bag.epoch, epoch)`.

**Why this establishes I2:** Let `e_pub` be the maximum epoch at which
any pinned thread could have published or observed pointer `p` before
`p`'s retire. By the retire discipline (Section 1.1), retire is the
last publication, so all such observations happened-before this
retire call. The acquire-load on line 168 synchronizes-with any
prior release-advance, so `epoch >= globalEpoch_at_any_prior_advance
>= any prior pinned thread's captured epoch by I1`. Therefore
`bag.epoch >= e_pub`. ∎

### 3.3 Invariant I3: `safeEpoch` is the min over pinned epochs

**Statement:** Let `safeEpoch_R` be the value computed by `R`'s call
to `loadEpochs`. Then for every thread `T` that was pinned at any
moment during `R`'s `loadEpochs` execution at captured epoch `e_T`:
`safeEpoch_R <= e_T`.

**Mechanism:**

In `loadEpochs` (`typestates/reclaim.nim:144-221`):

```nim
var subscribeBarrier: Atomic[uint64]
subscribeBarrier.store(0'u64, moRelaxed)
discard subscribeBarrier.fetchAdd(0'u64, moSequentiallyConsistent)  # line 195
var ctx = ReclaimContext[MaxThreads, CC](s)
ctx.globalEpoch = ctx.manager.globalEpoch.load(moAcquire)            # line 202
ctx.safeEpoch = ctx.globalEpoch                                      # line 203
for i in 0 ..< MaxThreads:                                           # line 215
  if ctx.manager.threads[i].pinned.load(moSequentiallyConsistent):   # line 216
    let threadEpoch = ctx.manager.threads[i].epoch.load(moAcquire)   # line 217
    if threadEpoch < ctx.safeEpoch:                                  # line 218
      ctx.safeEpoch = threadEpoch                                    # line 219
```

The stack-local SC RMW (lines 189–195) participates in S. The
rationale comment (`reclaim.nim:159-188`) explains why a stack-local
location is used rather than an RMW on `globalEpoch` itself
(cache-line bouncing avoidance) and why standalone SC fences would
not work (TSAN limitation).

The per-slot SC load on `pinned` (line 216) is the subscription
point for I1's pin RMW. The rationale comment (`reclaim.nim:206-214`)
explains why SC, not Acquire, is required: SC ops on the *same*
atomic location are totally ordered in S, so an SC load reads from a
position in `pinned`'s modification order consistent with S relative
to every concurrent pin RMW. An Acquire load is not in S, so the
reclaimer could observe `pinned=false` for a thread that has already
published `pinned=true` — exactly the race TSAN reports as
use-after-free.

**Why this establishes I3:** Fix a thread `T` pinned at slot `i` with
captured `epoch[i] = e_T` at some moment during `R`'s `loadEpochs`
execution. By I1, the pin RMW is in S. By the SC chain above:

- If `T`'s pin RMW precedes `R`'s SC load on `pinned[i]` in S → `R`
  reads `pinned=true`, acquire-loads `epoch[i] = e_T` (released by
  line 120 of `pin`, synchronized-with by line 217 of `loadEpochs`),
  and updates `safeEpoch <= e_T`.
- If `T`'s pin RMW follows `R`'s SC load → `T`'s pin is not yet
  visible to `R` and not yet a constraint. But `R`'s SC load
  preceded `T`'s pin in S, so `R`'s previously-loaded `globalEpoch`
  (line 202) satisfies `globalEpoch <= globalEpoch_at_T_pin = e_T`
  (since the latter was loaded by `T` after `R`'s SC RMW). So
  `safeEpoch_R <= globalEpoch <= e_T` trivially.

Either case: `safeEpoch_R <= e_T`. ∎

### 3.4 Invariant I4: Reclaim guard is `bag.epoch < safeEpoch - 1`

**Statement:** `tryReclaim` frees only bags whose stamp is strictly
less than `safeEpoch - 1`.

**Mechanism:**

In `tryReclaim` (`typestates/reclaim.nim:238-301`):

```nim
let ctx = ReclaimContext[MaxThreads, CC](r)
if ctx.idx < 0 or ctx.idx >= MaxThreads:                # line 263-265
  return 0
let safeEpoch = ctx.safeEpoch - 1                       # line 266
var count = 0
let state = addr ctx.manager.threads[ctx.idx]           # line 268
var bag = state.limboBagTail                            # line 276
while bag != nil:                                       # line 278
  if bag.epoch >= safeEpoch:                            # line 279
    break                                               # line 282
  # ... iterate objects, call destructors, free bag ...
```

The `-1` provides one full epoch of margin. The `checkSafe`
transition (`reclaim.nim:228-236`) guards `safeEpoch > 1` before
`ReclaimReady` is returned, so the underflow case at epoch 0 produces
`ReclaimBlocked` instead of unsigned wraparound. The post-T-INTEGRATE
test suite asserts this gate (Section 3.13 Q3.13-F).

**Why the `-1` margin is needed:** Suppose `bag.epoch = e_b` and
`safeEpoch_R = e_b`. Without the `-1` margin, `bag.epoch >=
safeEpoch` would be `e_b >= e_b`, the walk would stop, and the bag
would not be freed. With the `-1`, `bag.epoch >= safeEpoch - 1`
becomes `e_b >= e_b - 1`, still true, still not freed. The margin
ensures that we only free bags whose stamp is strictly less than
any currently-pinned thread's epoch by at least one full epoch.

The rationale: I2 says `bag.epoch >= e_pub` (max pinned epoch at
retire time). I3 says `safeEpoch <= e_T` (min pinned epoch now). If
we freed a bag with `bag.epoch == safeEpoch`, we could free an
object retired exactly when a thread now-pinned-at-`safeEpoch` could
have observed it. The `-1` enforces strict inequality.

## 4. Theorem (Safety)

**Claim:** Any pointer `p` freed by `tryReclaim` was retired at an
epoch strictly less than `safeEpoch - 1`, and no currently-pinned
thread holds a reference to `p`.

**Proof:**

Let `p` be a pointer freed by `tryReclaim` at wall-clock moment
`t_free`. Let `B` be the bag containing `p` at `t_free`; let
`e_retire = B.epoch` (the bag's stamp). By I4, `e_retire <
safeEpoch_R - 1`, where `safeEpoch_R` was computed by the same
`tryReclaim` call's preceding `loadEpochs`.

Suppose for contradiction that some thread `R'` (distinct from the
reclaimer's running thread `R`) is pinned at epoch `e_R'` at `t_free`
and holds a reference to `p`.

For `R'` to hold a reference to `p`, `R'` must have observed `p` via
some shared load during a pinscope at some thread epoch `e_R'_obs <= e_R'`.

**Case A: `R'` was pinned during `loadEpochs`.** Then by I3,
`safeEpoch_R <= e_R'_obs`. By I4, `e_retire < safeEpoch_R - 1 <
e_R'_obs - 1`, so `e_retire + 1 < e_R'_obs`. But by I2, `e_retire >=
e_R'_obs` (since `R'` could have observed `p`, so `R'`'s captured
epoch is in the set whose max is `<= e_retire`). Combined:
`e_R'_obs <= e_retire < e_R'_obs - 1`, i.e. `e_R'_obs < e_R'_obs -
1`, contradiction.

**Case B: `R'` was NOT pinned during `loadEpochs`.** Then `R'`'s
current pin happened-after `loadEpochs`. By I1, `R'`'s pin RMW is
publication-strong. `R'`'s captured `e_R' = globalEpoch.load(moAcquire)`
at `R'`'s pin time. Since `R'`'s pin RMW followed `R`'s SC ops in
S, `R'`'s subsequent acquire-load of `globalEpoch` reads a value
`>= globalEpoch_at_R's_loadEpochs >= safeEpoch_R > e_retire + 1`.
So `R'`'s pin epoch satisfies `e_R' > e_retire + 1`.

For `R'` to hold `p`, `R'` must have observed `p` after `R'`'s pin
— i.e., AFTER `p` was retired (because `p`'s retire happens-before
`R'`'s pin in this case). But by the retire discipline (Section 1.1),
the thread that retires `p` has already detached `p` from all shared
structures BEFORE calling `retire`. So `p` is not reachable from any
shared structure observable by `R'` at the time of `R'`'s pin. So
`R'` cannot observe `p` post-retire. Contradiction.

Both cases contradict the assumption. Therefore no pinned thread
holds `p` at `t_free`, and `tryReclaim`'s call to `destructor(p)`
is safe. ∎

### 4.1 Caveat: the retire discipline is the caller's contract

The proof of Case B relies on the retire discipline being honored
by the caller. nebr does NOT mechanically enforce this — there is
no compile-time or runtime check that pointer `p` is unreachable
from shared structures before `retire(p, dtor)` is called. This is
the user's responsibility, identical to every other EBR / HP / SMR
library (crossbeam-epoch, folly's hazptr, Brown's own DEBRA+ impl
all require the same discipline).

For the consumers in lockfreequeues (Queue, BQueue), the retire
discipline is satisfied by the algorithm-level CAS sequence:
`retireOnCAS(scope, expected, new, dtor)` retires only after the
CAS succeeds (publishing `new` and unlinking `expected`). The
unlinking and the retire are encapsulated in the typestate API
(`pinned_scope.nim`'s `retireOnCAS` / `retireOnPublish` helpers).

## 5. The EBR subscription handshake (informal)

The SC ordering machinery in Sections 3.1 and 3.3 implements what
the literature calls the "subscription handshake" between readers
(pinners) and reclaimers. Three properties make the handshake work:

1. **Hardware StoreLoad barrier.** A plain SC load is too weak — on
   x86 it lowers to a bare `mov` and loses the `mfence` that an SC
   fence would provide. An SC RMW lowers to a `lock`-prefixed
   instruction on x86 and an `ldaxr`/`stlxr` seq-cst loop on ARM,
   both of which are full StoreLoad barriers. (Cite: rationale
   comment in `reclaim.nim:165-188`.)

2. **Participation in C11's SC total order S.** The SC loads on each
   thread's `pinned` flag (line 216) are in S. For the proof of EBR
   safety to go through, the subscription point itself must be in S
   so that pin RMWs published before our subscription are visible.
   C11 §29.3 makes S a single total order across **every** SC op,
   regardless of which atomic location it touches.

3. **TSAN vector-clock modelling.** Standalone SC fences are not
   modelled by TSAN's vector clocks (cite: compiler-rt source at
   `tsan_interface_atomic.cpp`, `OpFence::Atomic` → `// FIXME: not
   implemented`). SC RMWs are modelled correctly on every atomic
   location, so the analyser sees the synchronisation.

Properties (1) and (3) are properties of the *instruction*, not the
operand location; property (2) is location-independent by C11
construction. So a stack-local `Atomic[uint64]` gives the same
subscription point with no cross-thread cache traffic. This is the
exact pattern crossbeam-epoch uses (crossbeam packs pin+epoch into a
single SC-accessed word; nebr uses separate SC-RMW publication + SC
load).

## 6. Race-freedom analysis (the three layers)

A second informal cross-check: even granting Invariants I1–I4, are
there races at the implementation level we missed? The Phase 1
backfill EBR + pop race-freedom analysis (handoff Session updates
2026-06-05) identified three layers; each is addressed.

### 6.1 Layer 1: DWCAS atomic-level race-freedom

nebr's algorithm does NOT use DWCAS — confirmed by Q-DWCAS
investigation (`docs/internal/q-dwcas-investigation.md`). The DWCAS
machinery lives in `atomics.nim` and is used by downstream queue code
(lockfreequeues' strict-LCRQ), not by the EBR algorithm itself.

The single-word atomics nebr does use (`Atomic[bool]` on `pinned`/`neutralized`,
`Atomic[uint64]` on `epoch`/`globalEpoch`, `Atomic[uint64]` for
`activeThreadMask`, `Atomic[ThreadId]` for `threadId`) all have
hardware atomicity on x86_64 and aarch64. The `__atomic_always_lock_free`
C-level assertion in `atomics.nim` checks this at compile time.

### 6.2 Layer 2: pinscope guards via SC subscription

Covered by Invariants I1 and I3. The pin/unpin/reclaim handshake is
SC-ordered; any reclaimer either sees the pin or precedes the pin in
S. No race between pin publication and reclaim subscription.

### 6.3 Layer 3: retire-doesn't-walk-bits

The reclaimer reads `bag.epoch` (a `uint64` field set non-atomically
by the same thread that runs reclaim — no cross-thread race) and
`safeEpoch` (a local variable). It does NOT walk a freelist, a
liveset bitmap, or any structure mutated by other threads. The
only cross-thread reads are the per-slot `pinned` and `epoch`
atomics, which are SC-loaded (Layer 2).

The bag list (`currentBag`, `limboBagTail`, `bag.next`) is
thread-local to the slot owner. Both `retire` and `tryReclaim` run
on the slot owner's thread; no synchronization is needed between
them, but ordering is: `retire` is called from inside `withPinscope`,
`tryReclaim` is called from outside (typically by the same worker
in its periodic reclamation pass). There is no concurrent retire
and reclaim on the same slot.

### 6.4 Decref timing (the fourth concern from handoff)

The handoff Session updates note "decref timing — only at
queue-destroy walk; not at pop, not at EBR reclaim." This is a
downstream queue concern (managed_ref.nim / managed_slice.nim), not
a nebr concern. nebr's `destructor(p)` call is opaque to the EBR
layer — the destructor pointer is supplied by the caller at retire
time. For `ManagedRef`/`ManagedSlice` payloads, the destructor that
nebr calls does NOT do the final decref; the final decref is owed
to the queue-destroy walk. Section 4 of the design doc covers this.

**Phase 3.4 update (2026-06-06)**: pop-side correctness for the
destructor walk requires that already-popped slots present default
bits to the walk so the `seqIsLive` / `slotIsCommittedAndUnread`
predicates correctly skip them. The lockfree integration substrate
satisfies this by wrapping each pop read in `move(...)`, which leaves
the slot at `default(T) = 0` for `distinct uint` payload types
(ManagedRef[X] / ManagedSlice[T]). This is observationally equivalent
to the `slot.reset()` mechanism described in design §4.5.3 family (1)
and does NOT introduce any new safety obligation on the nebr layer.
The destructor walk's correctness argument is unchanged: it sees
0-bit slots for popped slots (skip) and live-bit slots for not-yet-
popped slots (decref). The pop's destructive read (whether via
`.reset()` or `move()`) is the mechanism that produces the 0-bit
state. See design §4.5.2 (Phase 3.4 update) for the full equivalence
discussion. The safety argument here is unchanged — only the
implementation mechanism (move() vs explicit reset()) is clarified.

## 7. What this argument does NOT prove

The argument above proves Safety (S2 from Section 1.1) under the
assumption that the retire discipline is honored. It does NOT prove:

- **Memory bound.** Per Section 8.
- **Lock-free progress.** Section 3.11 of the design doc summarizes
  the progress claims; they follow from the operation-level
  analysis (no retries, finite atomic operation counts).
- **Wait-free reclaim.** `tryReclaim` is bounded-walk over the local
  bag list, not wait-free in the strict sense.
- **Recovery from in-operation neutralization (D3).** Out of scope
  for nebr; documented as known limitation.
- **Cross-manager safety.** A thread registered with manager A
  using a handle against manager B is UB (the `threadLocalManager`
  guard in `reclaimStart(addr manager)` short-circuits the most
  common cases but does not enforce it for the handle form). This
  is the user's contract.

## 8. Memory bound discussion

Under bounded retirement rate `r` (objects/second) and bounded time
`Δt` between successive `reclaimNow` calls when `safeEpoch` advances
past at least one bag's stamp, per-thread bag memory is bounded by
roughly `r × Δt × sizeof(LimboBag) / LimboBagSize` plus one tail
bag. For typical hot-path queues with `advanceEvery(32)` and
`reclaimNow` once per ~1024 retires, this is on the order of
kilobytes per thread.

Under adversarial scheduling (one thread pinned and never unpinning),
`safeEpoch` is pinned at that thread's captured epoch and no
reclamation makes progress. Bag memory grows linearly with retire
rate until either:

- the operator calls `neutralizeStalled` to force-unpin the stuck
  thread, OR
- the process exits and the OS reclaims the heap.

The paper claims O(mn²) records waiting to be freed (Brown 2015 §5).
**nebr does NOT inherit this bound.** The proof in §5 relies on the
3-bag structure (D1) and the CAS-gated advance precondition (D2),
both of which nebr lacks. A defensible analog for nebr would be:

> "Under the assumption that the operator calls `reclaimNow` and
> advances the global epoch at frequencies that keep all per-thread
> bag-list lengths below some application-chosen bound `L`, total
> waiting-to-be-freed memory is bounded by `L × MaxThreads ×
> LimboBagSize × sizeof(retired-object-pointer-plus-destructor)`."

This is operator-policy-dependent, not a pure algorithmic property.
The design doc Section 3.11.5 documents this.

## 9. Cross-references

- **Design doc, Section 3** (`design-sections/03-smr-architecture-and-nebr.md`)
  — algorithm description, FSM diagrams, operational considerations,
  condensed safety argument.
- **Q-FAITHFUL** (`debra-plus-provenance.md`) — provenance analysis,
  D1–D9 deviation table from Brown 2015 DEBRA+.
- **Q-DWCAS** (`q-dwcas-investigation.md`) — confirmation that the
  EBR algorithm does not use DWCAS.
- **nim-debra source tree** (`imports/nim-debra/src/debra/`) — current
  location; becomes `src/lockfree/smr/nebr/` after T-INTEGRATE.b.

## 10. Confidence

**Invariants I1–I4: HIGH.** Each is established by a specific code
mechanism with file:line cites; the SC RMW pattern is documented in
rationale comments at the implementation sites.

**Theorem (Safety): HIGH.** Case analysis is complete; both cases
reach contradiction under I1–I4 + retire discipline.

**Race-freedom layers (§6): HIGH.** Layer 1 confirmed by Q-DWCAS;
Layer 2 follows from I1/I3; Layer 3 is a structural property of the
bag-list ownership model.

**Memory bound (§8): MEDIUM.** The "under operator policy" framing
is correct but not tight. A future analysis could give a quantitative
bound assuming bounded pin durations and bounded inter-reclaim
intervals. Out of scope for v0.1.0.

**TSAN validation: HIGH (pending CI cell).** The SC RMW choices in
`pin`, `retire`, and `loadEpochs` are specifically chosen for TSAN
compatibility per the rationale comments. The post-T-INTEGRATE CI
matrix (Section 6 of the design doc) includes a TSAN cell that runs
the full nebr test suite.
