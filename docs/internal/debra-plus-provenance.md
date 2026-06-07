# DEBRA+ Provenance: nim-debra vs. Brown 2015/2017

**Research question (Q-FAITHFUL):** Did `nim-debra` modify Trevor Brown's
DEBRA+ algorithm in any way, or is the implementation faithful to the paper?

**Scope:** Algorithm-level fidelity (mechanisms, invariants, complexity
bounds). Engineering choices (memory ordering, padding, typestate API
shape) are catalogued separately.

---

## 1. Summary verdict

**Faithful in mechanism, divergent in structure.** nim-debra implements
the same DEBRA+ control flow (announce / advance / retire / reclaim /
signal-based neutralize) but with **deliberate structural redesigns**
that change implementation-level invariants the paper relies on. None of
the deviations change the EBR safety contract (no use-after-free), but
several change what counts as a *correctness argument* and what the
constant factors look like.

**Deviation summary (severity ranked):**

| # | Deviation | Severity | What changes |
|---|-----------|----------|--------------|
| D1 | Limbo: paper uses **3 fixed bags** indexed by `epoch mod 3`; nim-debra uses an **unbounded FIFO linked list of bags** stamped with the retire-time epoch | **Semantic (structural)** | Memory bound (paper: O(mn²); nim-debra: bounded by retire rate × time-to-advance) |
| D2 | Paper advances epoch by **+1** (DEBRA+) or **+2** (DEBRA); nim-debra also advances by **+1** but **without** the "all processes announced / quiescent / neutralized" precondition CAS gate | **Semantic (precondition)** | Advance is unconditional; safety is recovered via the bag-epoch stamp + min-pinned-epoch check at reclaim time |
| D3 | Paper's quiescent/non-quiescent + `sigsetjmp`/`siglongjmp` recovery code is **absent**; nim-debra ships only the "neutralize → force-unpin → caller acknowledges" half | **Semantic (omitted)** | nim-debra does NOT implement neutralizable in-operation recovery. Critical sections must be sigsetjmp-free and the caller chooses whether to handle `Neutralized` |
| D4 | Paper's neutralize-from-`leaveQstate` (auto-suspect when own bag exceeds threshold) replaced by **explicit operator-driven** `neutralizeStalled(manager, epochsBeforeNeutralize)` | **Semantic (policy)** | Fault-tolerance is opt-in and external; no implicit suspicion |
| D5 | Paper's epoch-advance CAS (idempotent retry on `epoch == readEpoch`) replaced by `fetchAdd(1)` (unconditional increment) | **Engineering** | Multiple concurrent advancers each bump; same monotonicity, different cadence |
| D6 | No object pool / blockbag / 256-record blocks / shared-bag handoff. nim-debra uses `c_calloc`/`c_free` per limbo bag (64 objects) and never recycles | **Engineering** | Constant-factor; not in paper's algorithm contract |
| D7 | No hazard-pointer integration (`RProtect` / `isRProtected` / scan-and-swap-to-front in `rotateAndReclaim`) | **Semantic (omitted)** | Tied to D3 — HPs in DEBRA+ exist *only* to protect descriptors during sigsetjmp recovery, which nim-debra omits |
| D8 | Quiescent-bit-in-LSB packing absent; nim-debra uses a separate `pinned: Atomic[bool]` per slot | **Engineering** | Two atomics published per pin/unpin instead of one; SC RMW restores ordering |
| D9 | Per-thread `checkNext` / `opsSinceCheck` incremental cross-thread announcement scan **absent**; reclaim instead does a full `MaxThreads`-wide scan each time | **Engineering** | Reclaim-side cost; not pin-side |

**Severity reading:** D1, D2, D3, D4, D7 are *semantic* — the paper
describes them as core algorithm features. D5, D6, D8, D9 are
*engineering* — different code, same algorithm.

**Bottom line:** nim-debra is best described as an **EBR variant
inspired by DEBRA+** that retains DEBRA+'s distinguishing
signal-neutralization mechanism but **replaces the fixed-3-bag + CAS-gated
advance + quiescent-bit + sigsetjmp-recovery + HP** machinery with a
**linked-list-of-stamped-bags + unconditional-advance + separate-flags +
operator-driven-neutralize** design. The `+` (fault tolerance) is
**partially** preserved: the slot can be force-unpinned from outside,
but the in-operation recovery path that lets a neutralized thread
complete its work safely is absent.

**Confidence: HIGH** for impl claims (verified against source with line
cites). **MEDIUM** for paper claims (verified against `arXiv:1712.01044`
PDF text-extracted via `pdftotext`; figures 4 and 6 transcribed
verbatim from extracted text, but I did not re-verify pseudocode
against the rendered PDF).

---

## 2. Paper summary (Brown 2015 / arXiv 2017)

### 2.1 Provenance of the paper itself

- **Title:** "Reclaiming Memory for Lock-Free Data Structures: There Has
  to Be a Better Way"
- **Author:** Trevor Brown
- **Venue:** ACM PODC 2015 (conference). The arXiv preprint
  [arXiv:1712.01044](https://arxiv.org/abs/1712.01044) (Dec 2017) is the
  "full version of paper published at PODC 2015" per the arXiv abstract
  — same algorithm, more detail. nim-debra's README cites the 2017
  arXiv version; the question prompt cites "2015 PODC". **Both refer to
  the same DEBRA+ algorithm.** No version skew on the algorithm itself.

### 2.2 Algorithm components (verbatim from Figures 4 and 6)

**Per-process local state (DEBRA):**

```
long pid
long checkNext              // next process to scan
blockbag * bags[0..2]       // limbo bags for the last three epochs
blockbag * currentBag       // bag for the current epoch
long index                  // index of currentBag in bags[0..2]
long opsSinceCheck
```

**Shared state:**

```
long epoch                  // current epoch
long announce[n]            // per-process announced epoch + quiescent bit (LSB)
```

**`retire(p)`:** `currentBag->add(p)` — single line, paper §4 Fig 4.

**`leaveQstate()`** (DEBRA, paper Fig 4 lines 23–42):

```
readEpoch = epoch
if (! isEqual(readEpoch, announce[pid])):     // epoch changed since last leaveQstate
    rotateAndReclaim()                        // index = (index+1)%3; move full blocks
    result = true
// incrementally scan one announcement per CHECK_THRESH leaveQstate calls
if (++opsSinceCheck >= CHECK_THRESH):
    if isEqual(readEpoch, announce[other]) || quiescent(other):
        if ++checkNext >= n && >= INCR_THRESH:
            CAS(&epoch, readEpoch, readEpoch+2)   // advance by +2
announce[pid] = readEpoch
```

**`rotateAndReclaim()`** (DEBRA, paper Fig 4 lines 43–47):

```
index = (index+1) % 3              // oldest bag becomes new current
currentBag = bags[index]
pool->moveFullBlocks(currentBag)   // reclaim full blocks of bag retired 2 epochs ago
```

**DEBRA+ additions (paper Fig 6):**

- `RProtected[n]`: per-process arraystack of hazard pointers.
- `RProtect(r)` / `isRProtected(r)` / `RUnprotectAll()`: O(1) HP ops.
- `leaveQstate` (Fig 6, lines 9–28): same as DEBRA but with
  `suspectNeutralized(other)` added to the OR test, and the CAS advances
  by `readEpoch+1` (not +2) (line 24).
- `suspectNeutralized(other)` (Fig 6, lines 56–58):
  ```
  return (currentBag->size_in_blocks() >= SUSPECT_THRESHOLD_IN_BLOCKS)
      && (!pthread_kill(getPthreadID(other), SIGQUIT))
  ```
- `signalhandler` (Fig 6, lines 1–7):
  ```
  if (! isQuiescent()):
      enterQstate()
      siglongjmp(...)
  // else: return normally, resume operation
  ```
- `rotateAndReclaim()` augmented (Fig 6, lines 29–55): hash all HPs into
  a `scanning` table, swap HP-protected records to the front of
  `currentBag`, move the trailing full blocks to the pool.

**Memory bound (paper §5):** O(mn²) records waiting to be freed, where
`n` is process count and `m` is the largest number of records removed
per high-level operation. Derived from the bag-size threshold `c +
O(nm)` per process.

### 2.3 Algorithm component table (paper side)

| Component | Paper specifies |
|---|---|
| Announce | LSB-packed (epoch \| quiescent) word per process; written in `leaveQstate` |
| Epoch advance | CAS(epoch, readEpoch, readEpoch+2) for DEBRA, +1 for DEBRA+. Precondition: ALL `n` processes are either quiescent, have announced `readEpoch`, or have been successfully signaled |
| Limbo structure | Exactly 3 bags per process, indexed by `epoch mod 3`; bags are blockbags (linked list of 256-record blocks) |
| Reclaim trigger | `leaveQstate` detects `announce[pid] != epoch` → calls `rotateAndReclaim()` |
| Reclaim safety | Bag at `(index+1) % 3` is the one retired 2 epochs ago; safe by virtue of the advance precondition (all processes saw at least 2 epochs ago) |
| Registration | Implicit — `pid` is a process-local long, `announce[]` is sized to `n` at compile time |
| Neutralize | `pthread_kill(target, SIGQUIT)`; target's `signalhandler` checks `isQuiescent`, if non-quiescent does `enterQstate + siglongjmp` to recovery code |
| Recovery | Caller-side `sigsetjmp` at operation start; on `siglongjmp` the operation re-checks descriptor via `isRProtected(desc)` and either `help(desc)` or restarts |
| Memory bound | O(mn²) records waiting to be freed |

---

## 3. Implementation summary (nim-debra)

### 3.1 Component table (impl side)

| Component | nim-debra implements | File:line |
|---|---|---|
| Announce | Separate atomics: `pinned: Atomic[bool]` + `epoch: Atomic[uint64]` + `neutralized: Atomic[bool]` per slot. Published by SC RMW on `pinned` after Release stores on `epoch`/`neutralized` | `typestates/guard.nim:118-136` |
| Epoch advance | `globalEpoch.fetchAdd(1, moRelease)` — unconditional, no precondition check, no CAS | `typestates/advance.nim:69-71`, `convenience.nim:285` |
| Limbo structure | Per-thread singly-linked FIFO of `LimboBag` (each 64 objects, `c_calloc`). Each bag stamped with retire-time epoch. Unbounded list length | `limbo.nim:23-27`, `typestates/retire.nim:173-181` |
| Reclaim trigger | Caller invokes `reclaimNow(handle)` or full `reclaimStart → loadEpochs → checkSafe → tryReclaim` chain. No automatic trigger on epoch change | `convenience.nim:289-324`, `typestates/reclaim.nim:94-301` |
| Reclaim safety | `safeEpoch = min(globalEpoch, min over pinned threads of threadEpoch)`; bag freed iff `bag.epoch < safeEpoch - 1` | `typestates/reclaim.nim:189-219, 266-282` |
| Registration | Explicit: bitmask `activeThreadMask` of `MaxThreads` slots; thread claims slot via CAS in `register`. `unregisterThread` releases slot for reuse | `typestates/registration.nim:81-118`, README §"Release a registration slot" |
| Neutralize | Operator-driven `neutralizeStalled(manager, epochsBeforeNeutralize)`. Scans active slots; if `threadEpoch < globalEpoch - threshold` and `pinned`, calls `neutralizeRemoteSlot(tid, i)` which delivers `SIGUSR1` (POSIX) or SuspendThread/flip/ResumeThread (Windows) | `typestates/neutralize.nim:84-116`, `constants.nim:24` |
| Recovery | **None.** The slot's `pinned`/`neutralized` flags are flipped by the signal handler; the next `unpin` returns `Neutralized` and the caller must `acknowledge`. No `sigsetjmp` / `siglongjmp` / `help(desc)` machinery exists | `typestates/guard.nim:140-182` |
| Memory bound | Not claimed. Per-thread bag list grows until `tryReclaim` is called and finds `bag.epoch < safeEpoch - 1`. Operator drives both retire and reclaim cadence | n/a |

### 3.2 Engineering refinements present in nim-debra but not in paper

These are not deviations *from* the algorithm — the paper is silent on
them — but they are present and worth noting for v0.1.0 framing:

- **Cache-line padding** of `ThreadState` to `CacheLineBytes`
  (default 64, `-d:CacheLineBytes=128` for Apple Silicon); per-slot
  array padding sized at compile time via sibling-type drift check
  (`types.nim:14-60, 105-120`).
- **Custom atomics module** with `__atomic_always_lock_free` C-level
  assertion, refusing `Atomic[ref T]` and non-`Trivial` types
  (`atomics.nim`, `safety-model.md`).
- **Typestate-checked API** (nim-typestates library) — `pin → retire →
  unpin` enforced at compile time. Calling `retire` outside a pinned
  scope is a type error.
- **TSAN-friendly fence encoding:** stack-local SC RMW
  (`Atomic[uint64].fetchAdd(0, moSequentiallyConsistent)`) instead of
  `threadFence(moSequentiallyConsistent)` because TSAN does not model
  standalone SC fences (`reclaim.nim:189-195`, `retire.nim:165-167`).
- **`Atomic[ptr T]` + `retain`/`release` bridge** for `ref` types in
  atomic slots (`refptr.nim`, `safety-model.md`).
- **DWCAS (16-byte atomics)** for downstream queue use; not part of
  DEBRA+ proper (`atomics.nim`, README §Attribution).
- **`ccSingle`/`ccMulti` `PinScopeCardinality`** phantom param —
  enables compile-time discrimination between single-consumer and
  multi-consumer pin scopes for downstream queue libraries
  (`types.nim:62-93`).
- **`bindClient` / `unbindClient` refcount** with `=destroy` assert,
  preventing client-outlives-manager UB (`types.nim:74-78, 168-173`).
- **`advanceEvery(n)` cadence helper** — amortizes the global-epoch
  atomic store over `n` calls (`convenience.nim:236-287`).

---

## 4. Fidelity table

| Algorithm component | Paper specifies | nim-debra implements | Deviation class |
|---|---|---|---|
| Announce flag | LSB-packed `announce[pid]` word (epoch \| quiescent bit) | Separate `pinned: Atomic[bool]` + `epoch: Atomic[uint64]` per slot | **Engineering (D8)** |
| Announce write | Plain store in `leaveQstate` | SC RMW (`pinned.exchange(true, moSequentiallyConsistent)`) preceded by Release stores | **Engineering** (stronger ordering than paper requires; deliberate TSAN compat) |
| Epoch advance — mechanism | `CAS(&epoch, readEpoch, readEpoch+1)` (DEBRA+) | `globalEpoch.fetchAdd(1, moRelease)` | **Engineering (D5)** |
| Epoch advance — precondition | ALL n processes quiescent / announced `readEpoch` / `suspectNeutralized` returned true. Gated by `checkNext >= n && >= INCR_THRESH` | **None** — unconditional. Safety recovered at reclaim time | **Semantic (D2)** |
| Limbo bag count | Fixed **3** per process, indexed `epoch mod 3` | **Unbounded linked list** of bags per thread | **Semantic (D1)** |
| Limbo bag size | Blockbag of B=256-record blocks (paper's experiments) | Fixed `LimboBagSize = 64` objects per bag | **Engineering (D6)** |
| Bag epoch identity | Implicit from `index = epoch mod 3` | Explicit `bag.epoch: uint64`, **re-stamped on every retire** to current global epoch (max-monotonic) | **Semantic (D1)** |
| Reclaim trigger | Automatic, inline in `leaveQstate` when announcement changes | Explicit `reclaimNow(handle)` / `tryReclaim()` call by caller | **Semantic (D9 + reframed)** |
| Reclaim safety check | "Bag is 2 epochs old" (structural invariant from `(index+1)%3`) | `bag.epoch < safeEpoch - 1` where `safeEpoch = min(globalEpoch, min over pinned threads of threadEpoch)` | **Semantic** — different invariant, same guarantee |
| Per-thread scan cadence | Incremental, 1 announcement per `CHECK_THRESH` leaveQstate calls | Full `MaxThreads`-wide scan inside `loadEpochs()` on every reclaim attempt | **Engineering (D9)** |
| Neutralize trigger | Auto, inside `leaveQstate` when own bag exceeds `SUSPECT_THRESHOLD_IN_BLOCKS` and target hasn't announced | Manual: operator calls `neutralizeStalled(manager, epochsBeforeNeutralize)` | **Semantic (D4)** |
| Neutralize signal | `SIGQUIT` via `pthread_kill` | `SIGUSR1` via `pthread_kill` (POSIX); SuspendThread/flip/ResumeThread (Windows) | **Engineering** (signal choice + Windows port) |
| Signal handler action | If non-quiescent: `enterQstate()` + `siglongjmp(...)` to recovery code | Force-unpin: sets `pinned=false`, `neutralized=true` on caller's slot. No `siglongjmp` | **Semantic (D3)** |
| Recovery code | Caller's `sigsetjmp` + `if (sigsetjmp) recovery else body`; recovery checks `isRProtected(desc)`, calls `help(desc)` or restarts | **None.** Next `unpin()` returns `Neutralized`; caller must `acknowledge()` before re-pinning | **Semantic (D3)** |
| Hazard pointers (`RProtect` / `isRProtected` / `RUnprotectAll`) | Used in DEBRA+ recovery and in `rotateAndReclaim` (scan-and-swap) | **Not implemented** | **Semantic (D7)** |
| Memory bound claim | O(mn²) (proved in §5) | **Not claimed.** Bag list grows until operator calls `reclaimNow` | **Semantic** |
| Object pool / blockbag | Per-process pool bag + shared lock-free bag; B=256 records/block; ~99.9% block recycling | None; `c_calloc`/`c_free` per `LimboBag`. No recycling | **Engineering (D6)** |
| Thread registration | Implicit: compile-time-sized `announce[n]`, `pid` is a `long` known to each process | Explicit: CAS-claimed slot in `activeThreadMask` bitmask; up to `MaxThreads` (default 64) slots; `unregisterThread` releases | **Engineering** (explicit lifecycle; paper assumes long-lived processes) |
| Quiescent state | Separate from epoch-not-announced; LSB bit in `announce[pid]` | **Not modeled.** Either pinned (in critical section) or unpinned. No separate quiescent state | **Semantic (D3 corollary)** |
| Per-thread reclamation isolation | Each process reclaims from its own bags; no cross-thread bag mutation | Same: `tryReclaim` walks only `manager.threads[idx]` for the calling thread's slot | **Faithful** |
| Cross-thread reclaim safety | "All processes have moved past this epoch" via announce-scan | "All currently-pinned threads have `threadEpoch >= safeEpoch`" via SC-load scan | **Semantic** (different invariant, equivalent guarantee under nim-debra's unconditional-advance model) |

---

## 5. Deviation analysis

### D1 — Limbo: 3 fixed bags → unbounded linked list of stamped bags (semantic)

**Paper:** `bags[0..2]`, current bag is `bags[index]`, oldest bag is
`bags[(index+1) % 3]`. The structural invariant "bag at `(index+1)%3`
was retired exactly 2 epochs ago" is what makes reclaim safe. Reclaim
moves *all full blocks* of the oldest bag to the pool in O(1).

**nim-debra:** Per-thread singly-linked list, `currentBag` (newest) →
... → `limboBagTail` (oldest), each bag a `c_calloc`'d 64-object array
stamped with `bag.epoch`. On retire: if `currentBag` is full, allocate a
new bag and link it; **stamp `bag.epoch = global epoch at retire
time`** (re-stamped on every retire — `typestates/retire.nim:199-202`).
On reclaim: walk from tail, free bags whose `epoch < safeEpoch - 1`.

**Why this is semantic, not cosmetic:** The paper's safety proof
(`§4 Correctness`, paper lines 794–807) is structural — it relies on
"currentBag must be changed at least 3 times between t1 and t2", which
requires the 3-bag rotation discipline. nim-debra's safety argument is
different: it relies on the bag's *value-tagged* epoch and the
runtime-computed `safeEpoch = min over pinned threads`. Both arguments
are sound, but they are different arguments. The paper does not
authorize the linked-list-of-stamped-bags structure.

**Consequence:** Paper's O(mn²) memory bound does not transfer. Under
nim-debra, the bag count grows until the operator calls `reclaimNow`
*and* the safe-epoch frontier has advanced past at least one bag's
stamp. If the operator never reclaims, the list grows without bound.
This is *acceptable* (it is the operator's contract) but it is **not a
DEBRA+ memory bound**.

### D2 — Unconditional epoch advance, no quiescence-scan precondition (semantic)

**Paper (Fig 6 lines 18–24):** Advance only happens inside `leaveQstate`,
only after the calling process has incrementally checked every other
process's `announce[]` and confirmed each is quiescent / announced
`readEpoch` / `suspectNeutralized(other)` returned true. Only then does
it `CAS(&epoch, readEpoch, readEpoch+1)`.

**nim-debra:** `globalEpoch.fetchAdd(1, moRelease)` — anybody can
advance, anytime, with no precondition (`advance.nim:70`,
`convenience.nim:285`). `advanceEvery(n)` is the recommended cadence
helper.

**Why this works without the paper's precondition:** nim-debra defers
the safety check to *reclaim time*. The `loadEpochs()` pass
(`reclaim.nim:189-219`) computes `safeEpoch = min over pinned threads
of threadEpoch`, and the reclaim filter is `bag.epoch < safeEpoch - 1`.
A thread pinned at an old epoch *prevents* its retire-stamped bags from
being freed regardless of how far `globalEpoch` has advanced. So the
EBR safety invariant ("no thread can still observe a freed object")
holds, but it holds via a *different mechanism*: the paper's
advance-time precondition vs. nim-debra's reclaim-time filter.

**Consequence:** The two designs reclaim at the same rate under the
same workload (modulo constant factors), but nim-debra's `globalEpoch`
value is no longer a meaningful "all threads have passed this point"
witness — it is just a monotonic counter, and the witness is computed
on demand. This is the same trick crossbeam-epoch uses.

### D3 — No sigsetjmp/siglongjmp recovery; only force-unpin half of fault tolerance (semantic, **omitted**)

**Paper (§5, Fig 5):** A neutralized process's signal handler runs
`enterQstate(); siglongjmp(...)`. The `siglongjmp` target is recovery
code that the caller wrote inline (`if (sigsetjmp(...)) alternate();
else usual();`). Recovery reads `isRProtected(desc)`, either invokes
`help(desc)` if some other process might have seen the descriptor, or
restarts the operation. HPs (`RProtect`/`RUnprotectAll`) exist *only*
to protect the descriptor record across this siglongjmp.

**nim-debra (`signal.nim`, `guard.nim:140-170`):** The signal handler
flips the slot's `pinned=false, neutralized=true`. There is no
`siglongjmp`. The interrupted thread continues from wherever it was
when SIGUSR1 fired. The next `unpin()` returns `Neutralized` (via the
`UnpinResult` variant), the caller calls `acknowledge()`, and that's
the entire recovery contract.

**Why this is a semantic omission:** The paper's `+` (fault tolerance)
specifically means "a stalled or crashed thread can be neutralized AND
the data structure can recover from the partial operation." nim-debra
delivers only the *neutralize* half. The data structure must either (a)
guarantee its critical sections are short enough that they never
*actually* get neutralized in practice (the `neutralizeStalled` threshold
of `epochsBeforeNeutralize` defaults to 2 epochs, which is "stalled for
real"), or (b) the data structure's critical sections must be designed
to be either restartable from the caller side or already-committed at
any point the signal could fire. nim-debra's neutralization is not a
*recovery* protocol; it is a *liveness escape valve*.

**Consequence:** For lockfreequeues (which is what nim-debra was
built for), this is *sufficient* — the queue's critical sections do
not modify per-thread durable state that would need rollback. But
calling this "DEBRA+ fault tolerance" overstates what is delivered.
"Brown 2015 DEBRA+ neutralization signal protocol" is accurate;
"Brown 2015 DEBRA+ fault tolerance" is not.

### D4 — Manual neutralize trigger (semantic policy change)

**Paper (Fig 6 lines 56–58, §5):** `suspectNeutralized(other)` fires
*automatically* inside `leaveQstate` when the calling process's own bag
exceeds `SUSPECT_THRESHOLD_IN_BLOCKS`. Fault tolerance is built into
the steady-state cadence.

**nim-debra:** `neutralizeStalled(manager, epochsBeforeNeutralize)` is
an explicit operator call (`typestates/neutralize.nim:46-128`). README
example shows it being called by application code, not by the EBR
runtime. The reclaim path never invokes it.

**Consequence:** A nim-debra application that never calls
`neutralizeStalled` is back to DEBRA (without `+`) plus the
linked-list-bag-list and unconditional-advance modifications — i.e., a
distributed EBR variant with no fault tolerance. The `+` is an
*available* mechanism, not an *active* one.

### D5 — `fetchAdd` instead of CAS for advance (engineering)

Same end state (monotonic increment), different code shape. Multiple
concurrent advancers each succeed (vs. only one winning the CAS in the
paper). Bag-stamp epochs may skip values, but the reclaim safety
check is `<` not `==` so this is fine.

### D6 — `c_calloc`/`c_free` per 64-object bag, no pool (engineering)

Constant-factor; paper notes 99.9% block recycling via pool. nim-debra
optimizes the slow path (only matters on `currentBag.count >=
LimboBagSize` boundaries, which is once per 64 retires) over
implementation complexity.

### D7 — No hazard pointers (semantic, omitted)

Follows from D3: the paper's HPs exist *only* to protect descriptor
records during sigsetjmp recovery. With recovery omitted, HPs are also
unnecessary.

### D8 — Three atomic flags instead of one packed word (engineering)

Paper packs `(epoch | quiescent_bit)` into one word so it can be read
atomically. nim-debra has three fields: `epoch`, `pinned`,
`neutralized`. Publication ordering is restored via SC RMW on `pinned`
after Release stores on `epoch`/`neutralized` (`guard.nim:118-136`).

### D9 — Full scan instead of incremental scan (engineering)

Paper's `checkNext`/`opsSinceCheck` amortizes the cross-thread scan
over many `leaveQstate` calls. nim-debra's `loadEpochs()` scans all
`MaxThreads` slots once per reclaim attempt. Different cost model: paper
amortizes scan cost across pin-side calls; nim-debra concentrates it on
the reclaim-side call.

---

## 6. Recommendation for v0.1.0 framing

This section answers the operator's framing question for README +
CHANGELOG of the lockfreequeues v0.1.0 wave.

### 6.1 What "DEBRA+" can defensibly mean here

Three usable framings, from most-to-least restrictive:

**A. "Brown 2015 DEBRA+" (strict):** Implies the full paper algorithm
including: 3 fixed bags, CAS-gated advance with quiescence-scan
precondition, hazard pointers, sigsetjmp recovery, automatic
neutralization, O(mn²) bound. **nim-debra does NOT satisfy this.** Five
semantic deviations (D1, D2, D3, D4, D7).

**B. "DEBRA+ variant" or "Brown-style DEBRA+" (loose):** Implies the
*spirit* of DEBRA+ — distributed EBR with signal-based thread
neutralization — but leaves room for structural redesign. **nim-debra
satisfies this**, with the caveat that the `+` (fault tolerance) is
partial (D3: neutralize without in-operation recovery).

**C. "EBR with neutralization, inspired by Brown 2015 DEBRA+"
(accurate):** No claim of paper fidelity, just provenance of the
*idea*. **nim-debra clearly satisfies this.**

### 6.2 Recommended README / CHANGELOG language

**For lockfreequeues v0.1.0 (the umbrella consuming this):**

The umbrella shipping name `debra_plus` for the SMR module is
**defensible** under framing B or C, *not* under framing A.

Recommended README sentence:

> SMR is provided by **nim-debra**, an EBR variant inspired by
> [Brown 2015 DEBRA+](https://arxiv.org/abs/1712.01044). nim-debra
> implements DEBRA+'s signal-based thread-neutralization mechanism over
> a per-thread linked-list-of-epoch-stamped-bags limbo structure. The
> fault-tolerance fork of DEBRA+ — sigsetjmp-based in-operation
> recovery and hazard-pointer-protected descriptors — is not provided;
> applications using `neutralizeStalled` must ensure their critical
> sections are restartable from the caller side.

Recommended CHANGELOG language (lockfreequeues v0.1.0):

> Adopts nim-debra (an EBR variant inspired by Brown 2015 DEBRA+
> [arXiv:1712.01044]) as the safe-memory-reclamation backend. nim-debra
> ships DEBRA+'s signal-neutralization escape valve but not the
> sigsetjmp-based recovery protocol; lockfreequeues' critical sections
> are designed to be safe under partial neutralization (see
> `docs/internal/debra-plus-provenance.md` for the algorithm-fidelity
> analysis).

**For nim-debra's own README** (separate project, but flagged for the
operator since the README currently overclaims):

Current README sentence (line 199): *"The Brown 2017 SIGUSR1 protocol on
POSIX..."* — this is accurate.

Current README sentence (line 34): *"This implementation follows Brown
2017, including the SIGUSR1 protocol for neutralizing threads that have
stalled inside a critical section."* — "follows" is **arguably
overclaiming** given D1–D4, D7. Recommend softening to "is inspired by
Brown 2017" or "implements an EBR variant in the spirit of Brown 2017,
including the SIGUSR1 protocol for neutralizing stalled threads."

The README's References section (line 232) is correctly worded:
"Trevor Brown. [...] The DEBRA+ algorithm with signal-based
neutralization for stalled threads." This is an attribution of the
*algorithm family*, not a claim of fidelity.

### 6.3 The naming question: is `debra_plus` defensible?

**Yes, with disclosure.** The trait/concept name `debra_plus` is
defensible as long as the docstring or accompanying prose makes clear
this is the *signal-neutralization-bearing variant of EBR* and not a
literal reimplementation of Figures 4 and 6. Many published systems
call their reclaimer "DEBRA+" or "epoch+signals" without bit-for-bit
fidelity to the paper; the term has shifted slightly toward "EBR with
neutralization."

If the v0.1.0 wave wants maximum precision, `debra_plus_like` or
`ebr_with_neutralization` would be more accurate. The cost is
discoverability — `debra_plus` matches what readers will search for.

---

## 7. Confidence

**Overall: HIGH.**

- Impl claims: HIGH — verified against source with file:line cites.
  Every Fidelity-table row for the nim-debra column was opened and
  read; cites are exact.
- Paper claims: MEDIUM-HIGH — verified against `arXiv:1712.01044` PDF
  extracted via `pdftotext -layout` (1490 lines). Figures 4 and 6
  pseudocode transcribed verbatim from extracted text (§2.2 above) and
  spot-checked against surrounding prose (§4–§5 of paper). I did not
  re-verify the pseudocode against the *rendered* PDF figures, so if
  `pdftotext` mangled a token (unlikely given the regularity of the
  extracted output) I would not have caught it.
- Cross-reference / verdict reasoning: HIGH — the deviations are
  large-scale structural, not subtle. Each is either present or absent;
  there is no judgment call about "did they implement this faithfully
  enough."

**Uncertainty surfaces:**

- The paper's `INCR_THRESH` / `CHECK_THRESH` / `SUSPECT_THRESHOLD_IN_BLOCKS`
  constants are workload-tunable; the paper picks 100 / small / unspecified.
  nim-debra has no analog (D9 is not parameterized). This is a
  consequence of D2 (unconditional advance) and not independently
  interesting.
- I did not investigate whether nim-debra's `safeEpoch - 1` boundary
  (`reclaim.nim:266`) is *exactly* equivalent to the paper's
  "retired 2 epochs ago" structural rule. They are equivalent under
  the paper's model where the advance precondition forces "all
  threads have passed `readEpoch`" before `epoch+1` is published; under
  nim-debra's unconditional-advance model they are equivalent under
  the runtime-computed `safeEpoch = min over pinned threadEpoch`
  invariant. The `-1` is what makes "bag retired AT epoch `safeEpoch`
  is not yet safe; bag retired at epoch `< safeEpoch` is safe by one
  full epoch of margin." This is sound; it is just sound for a
  different reason than the paper's structural argument.

---

## Bibliography

- Brown, Trevor. *Reclaiming Memory for Lock-Free Data Structures:
  There Has to Be a Better Way.* arXiv:1712.01044, Dec 2017. (Full
  version of paper published at PODC 2015.)
  https://arxiv.org/abs/1712.01044 — algorithm pseudocode in Figures
  4 (DEBRA) and 6 (DEBRA+). Fault-tolerance discussion in §5. Memory
  bound proof in §5 (O(mn²)). Verified via `pdftotext -layout`,
  1490 lines extracted.
- nim-debra source tree at
  `/Users/eek/Development/lockfree/imports/nim-debra/src/debra/`.
  All file:line cites in this report verified by direct `Read`.
- nim-debra README.md (lines 8–35, 199, 232) for self-described
  attribution. Source:
  `/Users/eek/Development/lockfree/imports/nim-debra/README.md`.
- nim-debra `docs/safety-model.md` for the `Atomic[ref T]` rationale.
- Fraser, Keir. *Practical Lock-Freedom.* UCAM-CL-TR-579, 2004.
  Original EBR work that DEBRA+ builds on. Cited by nim-debra README
  but not verified in this report (out of scope; question is about
  DEBRA+ fidelity, not the EBR lineage).
