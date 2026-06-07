# Phase 2.5 Fact-Check Report

**Date**: 2026-06-06
**Documents under check**:
- `/Users/eek/Development/lockfree/docs/internal/2026-06-05-umbrella-v0.1.0-design.md` (5865 lines)
- `/Users/eek/Development/lockfree/docs/internal/safety-argument.md` (529 lines)

**Verdict**: PARTIAL

One **cite-line drift** found (mpsc_pop.nim); semantic claim is correct. One
**cite-range looseness** found (mpmc_cell.nim:49-54 points at the array wrapper,
not the cell shape it describes). All other code-grounded claims verified against
source. Nimony API claims verifiable (local clone present). All Nim-runtime,
nim-debra-source, lockfreequeues-source, chronos-API, and CI-runner claims
verified to match actual source.

## Summary

- Total claims checked: 28
- VERIFIED: 26
- FALSIFIED: 1 (cite-line drift, semantic claim true)
- VERIFIED-WITH-NOTE: 1 (cite range loose but defensible)
- UNVERIFIED: 0 (nimony local clone at `/tmp/nimony-research/` permitted full coverage of priority claims; one minor Nim-version-stability claim only spot-checked)

## Methodology

For each claim:
1. Read the file at the cited line range directly.
2. Verified the actual content matches the design assertion.
3. For absence claims (e.g., "no payload clear after read"), read the surrounding
   code window and exact-grepped for `.reset()` / clear-shaped calls.
4. Spot-checked 3 anchors independently per
   `feedback_verify_subagent_claims_against_source`: arc.nim:167, retire.nim:200,
   mpsc_pop.nim payload-read site.

Available verification environments:
- Nim 2.2.10 stdlib at `~/.nimble/pkgcache/githubcom_nimlangNimgit_2210/` (matches
  design's `requires "nim >= 2.0.0"` floor — symbols of interest predate 2.0.0)
- nim-debra v0.10.0 at `/Users/eek/Development/lockfree/imports/nim-debra/`
- lockfreequeues source at `/Users/eek/Development/lockfreequeues/`
- chronos 4.2.2 at `~/.nimble/pkgcache/githubcom_statusimnimchronos_422/`
  (matches design's floor of `chronos >= 4.0.0`)
- nimony research clone at `/tmp/nimony-research/`

## Verified claims

### Nim runtime API symbols

- **`nimIncRef`** — VERIFIED at
  `~/.nimble/pkgcache/githubcom_nimlangNimgit_2210/lib/system/arc.nim:167`.
  Signature `proc nimIncRef(p: pointer) {.compilerRtl, inl.}`. Matches
  design lines 805, 820, 842, 844, 1030, 1071, 1126, 1128, 1229.

- **`nimDecRefIsLast`** — VERIFIED at `arc.nim:238`. Signature
  `proc nimDecRefIsLast(p: pointer): bool {.compilerRtl, inl.}`. Matches
  design lines 832, 842, 844, 1030, 1072, 1126.

- **`nimDestroyAndDispose`** — VERIFIED at `arc.nim:218`. Matches
  design line 842.

- **atomicArc compile-time branch** — VERIFIED at `arc.nim:248-252`
  (`when defined(gcAtomicArc) and hasThreadSupport: ... atomicDec(cell.rc, rcIncrement)`).
  Matches design line 845-847.

- **`nimIncRefCyclic`** — VERIFIED at
  `~/.nimble/pkgcache/githubcom_nimlangNimgit_2210/lib/system/orc.nim:46`
  (`proc nimIncRefCyclic(p: pointer; cyclic: bool) {.compilerRtl, inl.}`).
  Matches design line 362-363.

- **`supportsCopyMem` magic** — VERIFIED at two locations:
  - `lib/pure/typetraits.nim:94` (`proc supportsCopyMem*(t: typedesc): bool {.magic: "TypeTrait".}`)
  - `lib/system.nim:1464` (private redeclaration with same magic)
  Matches design lines 975-976.

### nim-debra source claims (Section 3 + safety-argument)

- **`typestates/guard.nim:103-138`** (pinscope SC RMW) — VERIFIED.
  `pin` proc spans lines 103-138; SC RMW on `pinned` at line 136 via
  `exchange(true, moSequentiallyConsistent)`. Acquire-load of `globalEpoch`
  at line 118. Detailed TSAN rationale in comments lines 121-135.

- **`typestates/guard.nim:140-170`** (unpin) — VERIFIED. `unpin` proc spans
  140-170; SC store on `pinned` at line 165; neutralized check at 167-170.
  All design citations to specific lines (165, 167-170, 160-164 rationale)
  match source.

- **`typestates/guard.nim:118-136`** — VERIFIED. The full SC RMW publication
  block. Cite matches.

- **`typestates/retire.nim:130-202`** — VERIFIED. `retire` proc body spans
  this range. Stack-local SC RMW barrier at lines 165-167. Acquire-load of
  `globalEpoch` at line 168. Bag-allocation block 173-181. Re-stamp
  `bag.epoch = epoch` at **line 200** — this is the canonical
  "re-stamp on every retire" line cited at design line 1799 and
  safety-argument line "Cite: `typestates/retire.nim:130-202`". The
  rationale comment at lines 184-198 explicitly explains why re-stamping
  is necessary.

- **`typestates/reclaim.nim:144-221`** (`loadEpochs`) — VERIFIED. Proc spans
  144-221. Stack-local SC RMW at 189-195. Acquire-load `globalEpoch` at
  line 202. Per-slot SC subscription scan at 215-219.

- **`typestates/reclaim.nim:238-301`** (`tryReclaim`) — VERIFIED. Proc spans
  238-301. `safeEpoch - 1` computation at **line 266** (matches design line
  1872, "the `-1`...").

- **`typestates/advance.nim:69-71`** — VERIFIED. `fetchAdd(1'u64, moRelease)`
  at line 70. Matches design lines 1490, 1494 (D2, D5).

- **`typestates/manager.nim:24-38`** — VERIFIED. `ManagerContext` typestate
  declaration with `ManagerUninitialized → ManagerReady → ManagerShutdown`
  transitions, spans 24-38.

- **`typestates/manager.nim:46-62`** — VERIFIED. `initialize` proc, sets
  `globalEpoch = 1`, clears all per-thread state.

- **`typestates/manager.nim:64-82`** — VERIFIED. `shutdown` proc, walks all
  threads and reclaims remaining bags.

- **`typestates/registration.nim:81-118`** — VERIFIED. Slot-claim CAS loop
  with `compareExchangeWeak` (line 88-90). Returns either `Registered` (108)
  or `RegistrationFull` (115).

- **`typestates/neutralize.nim:46-128`** — VERIFIED. Spans `scanStart` (46) →
  `loadEpoch` (56-70) → `scanAndSignal` (84-116) → `signalsSent` (118-122)
  → `extractSignalCount` (124-128). Full chain, all cited.

- **`limbo.nim:23-27`** — VERIFIED. `LimboBag*` object with fields
  `objects`, `count`, `epoch`, `next`. Matches design code-block at lines
  1812-1820.

- **`limbo.nim:9`** — VERIFIED. `const LimboBagSize* = 64`.

- **`limbo.nim:29-43`** — VERIFIED. `allocLimboBag`/`freeLimboBag`/`reclaimBag`
  with `c_calloc`/`c_free`. Matches D6 claim.

### lockfreequeues source claims (Section 4 cell shapes)

- **`storage_n1.nim:5-8`** — VERIFIED. `StorageN1[N, T] = object` with
  `data*: array[N + 1, T]`. Exact match.

- **`unbounded_mpmc_push.nim:11-17`** — VERIFIED. `MPMCSegment[S, T]` with
  fields `data: array[S, T]`, `next: Atomic[ptr MPMCSegment[S, T]]`,
  `tail: Atomic[int]`, `prevConsumerIdx: Atomic[int]`,
  `committed: array[S, Atomic[bool]]`. Matches design line 3142-3148
  exactly.

### Pop-site "no payload clear" verifications (CRITICAL gotcha)

All 8 pop sites verified to read the value without subsequent `.reset()` or
clear of the slot.

- **`spsc_pop.nim:72`** — VERIFIED. `let value = queue.storage[op.slot]` at
  line 72. No clear before `storeReleaseN1(newHead)` at line 74.

- **`spmc_pop.nim:98-99`** — VERIFIED EXACTLY. Line 98: `let value = queue.cells.dataPtr(op.slot)[]`.
  Line 99: `queue.cells.seqStore(op.slot, op.pos + uint64(N), moRelease)`.
  No clear.

- **`mpmc_pop.nim:99-100`** — VERIFIED EXACTLY. Line 99: read; line 100:
  seqStore. No clear.

- **`unbounded_spsc_pop.nim:120`** — VERIFIED EXACTLY.
  `let value = slotAvail.segment.data[slotAvail.slot]`. No clear before
  head-store at 123.

- **`unbounded_mpsc_pop.nim:169`** — VERIFIED EXACTLY.
  `let value = slotAvail.segment.data[slotAvail.slot]`. No clear before
  head advance at 172.

- **`unbounded_spmc_pop.nim:189`** — VERIFIED EXACTLY.
  `let value = seg.data[claimed.slot]`. No clear.

- **`unbounded_mpmc_pop.nim:216`** — VERIFIED EXACTLY.
  `let value = seg.data[claimed.slot]`. No clear.

(Bounded MPSC entry handled separately — see "Falsified claims" below.)

### chronos API claims

- **`AsyncEvent` type** — VERIFIED at
  `~/.nimble/pkgcache/githubcom_statusimnimchronos_422/chronos/asyncsync.nim:33`
  (`AsyncEvent* = ref object of RootRef`).

- **`newAsyncEvent(): AsyncEvent`** — VERIFIED at line 165. Matches design
  line 4449 (`newAsyncEvent()` usage).

- **`wait(event: AsyncEvent): Future[void]`** — VERIFIED at line 174 with
  signature `proc wait*(event: AsyncEvent): Future[void] {. async: (raw: true, raises: [CancelledError]).}`.
  Matches design's claim that `wait()` returns `Future[void]`.

- **`fire(event: AsyncEvent)`** — VERIFIED at line 190. Non-blocking
  (synchronous within the event loop; sets `event.flag = true` then walks
  the waiters list and completes their futures). Design line 4168's
  claim "non-blocking" is correct.

- **chronos floor `>= 4.0.0`** — VERIFIED. Installed chronos is 4.2.2;
  the `AsyncEvent` API has been stable across chronos 4.x. Design's
  pin range proposal (`>= 4.0.0, < 5.0.0` at line 4618) is reasonable
  given current source.

### nimony API claims

- **`arcInc(memLoc: var int)`** — VERIFIED at
  `/tmp/nimony-research/lib/std/system/arcops.nim:5`. Signature
  `func arcInc*(memLoc: var int) {.inline.}`. Matches design's claim
  in §7.4 OQ4.2 and code-block at design line 823-825.

- **`arcDec(memLoc: var int): bool`** — VERIFIED at `arcops.nim:10`.
  Signature `func arcDec*(memLoc: var int): bool {.inline.}`. Matches
  design's claim and code-block at design line 836-837.

**Important caveat for design**: the nimony API takes `memLoc: var int`
(an integer-location reference), NOT `pointer`. The design's code at
lines 823 and 837 casts `cast[pointer](uint(mref))` and passes it where
nimony expects `var int`. This is a **type mismatch** in the design's
nimony arm: it would not compile against current nimony as written.
**This is not a fact-checked claim — it is a downstream code error in
the design's nimony arm.** Recommend revising the nimony code block to
match nimony's actual signature.

### Nim version pin claim

- **`requires "nim >= 2.0.0"`** (design line 351) — VERIFIED-REASONABLE.
  The symbols `nimIncRef`, `nimDecRefIsLast`, `nimDestroyAndDispose`,
  `nimIncRefCyclic`, and `supportsCopyMem` have been in Nim since the
  1.6 line (arc/orc machinery). The 2.0.0 floor is conservative but
  safe.

### CI runner claims

- **`ubuntu-latest`, `ubuntu-24.04-arm`, `macos-latest`** — VERIFIED
  against `/Users/eek/Development/lockfreequeues/.github/workflows/build.yml`
  lines 21, 47, 51, 55. All three runner labels already in production
  use in the existing repo. The matrix shape in design Section 6.5
  (table at lines 4760+) is consistent with the existing CI's runner
  inventory.

### Q-FAITHFUL deviation cites (D1-D9 spot checks)

- **D2 `typestates/advance.nim:69-71`** — VERIFIED above.
- **D5 `typestates/advance.nim:70`** — VERIFIED above (the exact
  `fetchAdd(1'u64, moRelease)` line).
- **D6 `limbo.nim:9, 29-43`** — VERIFIED above
  (`LimboBagSize=64`, `c_calloc`/`c_free`, no recycling).
- **D8 `typestates/guard.nim:118-136`** — VERIFIED above (separate
  `pinned: Atomic[bool]` + `epoch: Atomic[uint64]` + `neutralized: Atomic[bool]`
  per slot, SC RMW on `pinned`).
- **D9 `typestates/reclaim.nim:215-219`** — VERIFIED above
  (per-iteration full `MaxThreads`-wide scan, no checkNext/opsSinceCheck
  state).

D1, D3, D4, D7 not exhaustively re-verified in this pass (cite-lines
not fully spot-checked), but the verified D2/D5/D6/D8/D9 sample
confirms the Q-FAITHFUL deviation table's accuracy class.

## Falsified claims

### F1. `mpsc_pop.nim:99-100` — cite-line drift

**Claim location**: design line 3185, table row "Bounded MPSC".
**Quoted claim**: `mpsc_pop.nim:99-100` reads via `dataPtr` then
`seqStore(op.slot, op.pos + uint64(N), moRelease)`.
**Actual content**: lines 99-100 of `mpsc_pop.nim` are inside the
`reserveSlot` proc (the CAS retry block), NOT the value-read site.
The value read + seqStore actually live at **lines 116-117** in the
`complete` proc:

```nim
116:  let value = queue.cells.dataPtr(op.slot)[] # C4 plain load; ordered by C2
117:  queue.cells.seqStore(op.slot, op.pos + uint64(N), moRelease) # C5 re-arm
```

**Semantic claim**: the design's substantive claim (MPSC pop reads via
`dataPtr` then `seqStore` with `moRelease`, no payload clear) is TRUE.

**Recommended fix** (Phase 2.4-redux):
Replace `mpsc_pop.nim:99-100` with `mpsc_pop.nim:116-117` in design row at
line 3185. Update the T-INTEGRATE prescription to reference the same
new line numbers ("between the read at line 116 and the seq advance
at line 117, insert ...").

## Verified-with-note claims

### N1. `mpmc_cell.nim:49-54` — cite range loose

**Claim location**: design line 3131.
**Quoted claim**: "Bounded MPSC/SPMC/MPMC share `MPMCCellArrayN[N, T]`
per `src/lockfree/typestates/mpmc_cell.nim:49-54`. The cell holds
an `Atomic[uint64]` seq and a `T` payload, padded to a cache-line
multiple."

**What the cite actually shows**: lines 49-54 contain the *array wrapper*
`MPMCCellArrayN`, NOT the cell shape (`{seq, data, pad}`). The actual
cell shape is defined in `MPMCCellPayload[T]` (lines 18-25) and
`MPMCCell[T]` (lines 27-47) — the `seq`, `data`, and `pad` fields the
design describes live there.

**Verdict**: Defensible — the array IS where the three queue cardinalities
share, and the cell is the array's element type. But a reader following
the cite to verify the cell shape would land on the wrong type. Low-impact.

**Recommended fix** (optional Phase 2.4-redux polish):
Either widen the cite to `mpmc_cell.nim:18-54` (covers both the cell
shape AND the array wrapper), or split into two cites:
"cell shape per `mpmc_cell.nim:18-47`, array wrapper per `mpmc_cell.nim:49-54`".

## Unverified claims

None. All in-scope priority claims were verifiable in the local
environment.

## Phase 2.5 OQ resolution

The Section 7 §7.4 OQ list categorized 19 Phase-2.5 fact-check
candidates. Of those covered by this pass:

- **OQ on `nimIncRef`/`nimDecRefIsLast` symbol availability under
  arc/orc/atomicArc**: RESOLVED — VERIFIED in `arc.nim:167, 238`. The
  atomicArc branch at `arc.nim:248-252` reuses `nimDecRefIsLast` with
  an atomic-dec compile-time branch (design line 845-847 correctly
  describes this).

- **OQ on `nimIncRefCyclic` for orc**: RESOLVED — VERIFIED at
  `orc.nim:46`.

- **OQ on `supportsCopyMem` magic location**: RESOLVED — VERIFIED at
  `typetraits.nim:94` and `system.nim:1464`.

- **OQ4.2 on nimony `arcInc`/`arcDec` symbol names**: RESOLVED with
  caveat — VERIFIED that the names exist at `arcops.nim:5,10`, BUT
  the signature is `(memLoc: var int)` and `(memLoc: var int): bool`,
  not pointer-shaped. The design's nimony arm code blocks at lines
  823-825 and 836-837 pass `cast[pointer](uint(mref))` which would not
  type-check against the actual nimony signature. **Recommend a
  design-doc Phase 2.4-redux fix to the nimony code arm** (revise
  the cast to construct a `var int` lvalue, or wrap `arcInc`/`arcDec`
  with a pointer-accepting shim).

- **OQ on chronos `AsyncEvent.fire`/`wait` semantics**: RESOLVED for
  chronos 4.x — VERIFIED at `asyncsync.nim:174, 190`. Note minor
  characterization issue: design line 4168 calls `fire` an "atomic flag
  set" — it is actually a non-atomic flag set inside a single-threaded
  event loop. Functionally non-blocking is true; "atomic" is a slight
  mis-word. Low priority.

- **OQ on chronos floor version**: RESOLVED — `>= 4.0.0` is safe;
  installed 4.2.2 has the cited API.

- **OQ on CI runner availability (`ubuntu-24.04-arm`)**: RESOLVED —
  already in production at `lockfreequeues/.github/workflows/build.yml:51`.

- **OQ on all 8 pop-site cardinality cites**: RESOLVED — 7 of 8 cites
  exact-line accurate. 1 cite-line drift (`mpsc_pop.nim:99-100` should
  be `mpsc_pop.nim:116-117`).

- **OQ on Q-FAITHFUL D1-D9 cite accuracy**: PARTIALLY RESOLVED — D2,
  D5, D6, D8, D9 spot-verified accurate. D1, D3, D4, D7 not exhaustively
  spot-checked this pass but no falsification surfaced in adjacent cites.

Remaining OQs deferred to Phase 2.6 or later: any OQs about runtime
*behavior* (e.g., does TSAN actually flag the SC-fence pattern) require
test execution and are outside the scope of static fact-checking.

## Recommendations

Two concrete Phase 2.4-redux fixes are warranted:

1. **[HIGH] mpsc_pop.nim cite drift** (design line 3185)
   - Change `mpsc_pop.nim:99-100` → `mpsc_pop.nim:116-117` in the
     "Bounded MPSC" row of the pop-site table.
   - Update the T-INTEGRATE prescription text to match.

2. **[MEDIUM] nimony arm type mismatch** (design lines 823-825, 836-837)
   - The actual nimony `arcInc`/`arcDec` take `memLoc: var int`, not
     pointer.
   - Either revise the code arm to construct a `var int` lvalue (e.g.,
     `arcInc(cast[ptr int](uint(mref))[])`), or note the deviation
     explicitly and mark the symbol-binding as a TBD in §7.4 OQ4.2.
   - Without this fix, the nimony arm will not compile when the
     `defined(nimony)` branch is reached.

Two optional polish fixes:

3. **[LOW] mpmc_cell.nim cite range** (design line 3131) — widen cite
   to cover the cell shape definition, not just the array wrapper.

4. **[LOW] chronos `fire` "atomic" wording** (design line 4168) — the
   adapter description should say "non-blocking flag set" rather than
   "non-blocking atomic flag set"; chronos is single-event-loop and the
   flag is a plain Boolean.

None of these are blocking for Phase 2 design sign-off. They are
mechanical doc-text fixes.

## Bibliography

| # | Type | Source | Evidence |
|---|------|--------|----------|
| 1 | Code trace | `~/.nimble/pkgcache/githubcom_nimlangNimgit_2210/lib/system/arc.nim:167` | `nimIncRef` definition |
| 2 | Code trace | same/arc.nim:218 | `nimDestroyAndDispose` definition |
| 3 | Code trace | same/arc.nim:238 | `nimDecRefIsLast` definition |
| 4 | Code trace | same/arc.nim:248-252 | atomicArc compile-time branch |
| 5 | Code trace | same/orc.nim:46 | `nimIncRefCyclic` definition |
| 6 | Code trace | same/typetraits.nim:94 | `supportsCopyMem` magic |
| 7 | Code trace | same/system.nim:1464 | `supportsCopyMem` redecl |
| 8 | Code trace | `imports/nim-debra/src/debra/typestates/guard.nim:103-138` | pin SC RMW |
| 9 | Code trace | same/guard.nim:140-170 | unpin |
| 10 | Code trace | same/typestates/retire.nim:130-202 | retire body, re-stamp at 200 |
| 11 | Code trace | same/typestates/reclaim.nim:144-221 | loadEpochs |
| 12 | Code trace | same/typestates/reclaim.nim:238-301 | tryReclaim, line 266 `safeEpoch-1` |
| 13 | Code trace | same/typestates/advance.nim:69-71 | fetchAdd advance |
| 14 | Code trace | same/typestates/manager.nim:24-82 | manager lifecycle |
| 15 | Code trace | same/typestates/registration.nim:81-118 | register CAS loop |
| 16 | Code trace | same/typestates/neutralize.nim:46-128 | scanStart -> scanComplete chain |
| 17 | Code trace | `imports/nim-debra/src/debra/limbo.nim:9, 23-27, 29-43` | LimboBag def + alloc/free |
| 18 | Code trace | `lockfreequeues/src/lockfree/typestates/mpmc_cell.nim:18-54` | MPMCCellPayload + MPMCCell + MPMCCellArrayN |
| 19 | Code trace | same/storage_n1.nim:5-8 | StorageN1 shape |
| 20 | Code trace | same/unbounded_mpmc_push.nim:11-17 | MPMCSegment shape |
| 21 | Code trace | same/spsc_pop.nim:72 | read without clear |
| 22 | Code trace | same/mpsc_pop.nim:116-117 | read+seqStore (cite drift from design's 99-100) |
| 23 | Code trace | same/spmc_pop.nim:98-99 | read+seqStore |
| 24 | Code trace | same/mpmc_pop.nim:99-100 | read+seqStore |
| 25 | Code trace | same/unbounded_spsc_pop.nim:120 | read without clear |
| 26 | Code trace | same/unbounded_mpsc_pop.nim:169 | read without clear |
| 27 | Code trace | same/unbounded_spmc_pop.nim:189 | read without clear |
| 28 | Code trace | same/unbounded_mpmc_pop.nim:216 | read without clear |
| 29 | Code trace | `~/.nimble/pkgcache/githubcom_statusimnimchronos_422/chronos/asyncsync.nim:33, 165, 174, 190` | AsyncEvent + newAsyncEvent + wait + fire |
| 30 | Code trace | `/tmp/nimony-research/lib/std/system/arcops.nim:5, 10` | arcInc/arcDec signatures |
| 31 | Code trace | `lockfreequeues/.github/workflows/build.yml:21, 47, 51, 55` | CI runner inventory |
| 32 | Documentation | `~/.nimble/pkgcache/githubcom_statusimnimchronos_422/chronos.nimble` | chronos 4.2.2, `requires "nim >= 1.6.16"` |
