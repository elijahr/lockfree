# Design Review: elijahr/lockfree v0.1.0 Umbrella Design

**Reviewer**: reviewing-design-docs skill (dispatched 2026-06-06)
**Document under review**: `docs/internal/2026-06-05-umbrella-v0.1.0-design.md` (5740 lines)
**Companion**: `docs/internal/safety-argument.md` (529 lines)
**Phase**: Phase 2.2 design review (gating Phase 2.5 fact-check and Phase 3 impl plan)

---

## Verdict

**NEEDS_WORK**

The design is unusually thorough for a Phase 2 deliverable: locked decisions are traceable, the 25-row Path C ref-composition matrix is concrete enough to drive implementation, the per-MM shim matrices name C-RTL symbols with file:line citations (verified against pinned Nim source), and the OQ inventory is honest about what defers to Phase 2.5 vs Phase 3 vs operator. Three issues prevent a READY verdict:

1. **CRITICAL #3 from Phase 1.6 devil's advocate is never referenced.** CRITICAL #1, #2, #4, #5 are each explicitly addressed and tagged in the doc; CRITICAL #3 is absent. Either the finding was rolled in under a different label and the doc should say so, or it was dropped silently — which is a Phase 1.6 → Phase 2 traceability gap. (HIGH; see Finding H1.)
2. **The Section 5 API surface cites `queue.nim:NNN` and `bqueue.nim:NNN` line numbers as if they were current source.** These files do not exist in `lockfreequeues/src/lockfree/` — they are *target* files produced by T-INTEGRATE.a–c. Many readers will mistake these for verifiable anchors; in this review one (`queue.nim:927-932` for the multi-consumer pop error) was on the operator's anchor-spot-check list specifically because the cite read as concrete. (HIGH; see Finding H2.)
3. **Section 5 API signatures reference `nebr.ccSingle` / `nebr.ccMulti` as the manager's cardinality parameter** while everywhere else `ccSingle` / `ccMulti` are introduced as the queue's producer/consumer cardinality (`PinScopeCardinality`). The dual use without a disambiguation note is a real ambiguity for an implementer writing the borrow-form smart constructors. (MEDIUM; see Finding M1.)

The remaining findings are MEDIUM and LOW: a leftover `docs/guides/` (plural) path typo in one place, a small set of "TBD" markers that map cleanly to OQs but are not always cross-linked, and a few cross-section cite drift items. None are blocking on their own.

After H1 and H2 are addressed, the doc is in shape to clear Phase 2.2.

---

## Summary count by severity

| Severity | Count |
|---|---|
| CRITICAL (blocks Phase 3 even with patching) | 0 |
| HIGH (significant gap; must address before Phase 2.2 sign-off) | 2 |
| MEDIUM (clarification benefits implementer / reviewer) | 5 |
| LOW (nit; cleanup) | 4 |
| **Total** | **11** |

---

## HIGH findings

### H1. CRITICAL #3 from Phase 1.6 devil's advocate is never named in the design

**Location**: cross-section — design doc as a whole (grep for `CRITICAL #3` returns zero matches).

**Description**: The handoff and the operator-supplied review brief both reference "all 5 CRITICAL devil's advocate findings." The design doc explicitly tags CRITICAL #1 (Path C composition — §2.5), CRITICAL #2 (mm:none drain — §1, §4.2, §4.8, §5.7), CRITICAL #4 (chronos hybrid — §1.5, §5.6), and CRITICAL #5 (rename / publication deferred — §1.2, §7.7). CRITICAL #3 has no corresponding tag.

This is a traceability hole, not necessarily a substantive design hole — CRITICAL #3 may in fact be resolved in the doc under different prose. But the reader cannot tell which.

**Recommended fix**: In §7.10 (Phase 2 design completion criteria) or §7.11 (Cross-references), add an explicit Phase-1.6-disposition table mapping CRITICAL #1 → #5 to the section that resolves each. CRITICAL #3 must either point to its resolving section (and that section must add a "Per Phase 1.6 CRITICAL #3 disposition" tag) or explicitly declare CRITICAL #3 as still-open with a Phase 2.5 / Phase 3 disposition path.

---

### H2. Section 5 cites `queue.nim:NNN` / `bqueue.nim:NNN` line numbers as if they were existing source

**Location**: §5.1.1 line 3803-3805 (queue.nim:368-405, queue.nim:1033-1038), §5.1.2 line 3809 (queue.nim:1046+), §5.1.2 line 3832 (queue.nim:710-741), §5.1.3 line 3855-3857 (queue.nim:191-193, queue.nim:920-949), §5.1.6 line 3904 (queue.nim:1001-1006), §5.2.1 line 3930 (bqueue.nim:180-198), §5.2.4 line 3966 (endpoint.nim:195-264), §5.9.3 line 4452 (queue.nim:927-932), §5.9.4 line 4463 (queue.nim:990), §5.9.7 line 4501 (bqueue.nim:182-185), §5.11 line 4562 (queue.nim:957-972, bqueue.nim:180-198), §2.7 line 1128-1129 (queue.nim:857, 1154, 1343, 1437, 1495).

**Description**: Spot-check from the operator anchor list — `src/lockfree/queue.nim:927-932`, supposedly the message text for "Direct pop on a multi-consumer Queue is not allowed":

```
$ ls /Users/eek/Development/lockfreequeues/src/lockfree/
atomic_dsl.nim  backoff.nim  exceptions.nim  internal  mupmuc.nim
mupsic.nim      sipmuc.nim   sipsic.nim      typestates  typestates.nim
unbounded_mupmuc.nim  unbounded_mupsic.nim  unbounded_sipmuc.nim
unbounded_sipsic.nim
```

There is no `queue.nim` and no `bqueue.nim`. They are *T-INTEGRATE target files* (§1.3 module layout). The line numbers cited are aspirational, not verifiable. A Phase 2.5 fact-checker reading these will burn time looking for files that don't exist; a Phase 3 implementer will treat the line numbers as ground truth and discover otherwise.

**Recommended fix**: Two patches in tension; either is acceptable:

- **Patch A (preferred)**: Replace every `queue.nim:NNN` / `bqueue.nim:NNN` cite with `<target> queue.nim` (or similar wording that flags the file as post-T-INTEGRATE). Where the v5.0.0 source carries the analogous content under a different filename, dual-cite both: `mupmuc.nim:NNN` (v5.0.0 source) → `queue.nim` MPMC arm (post-T-INTEGRATE target). This preserves the line-number information without misleading.
- **Patch B**: Leave the post-T-INTEGRATE cites but add a one-paragraph note at the head of Section 5 stating that all `queue.nim` / `bqueue.nim` line numbers are *post-T-INTEGRATE target* coordinates, derived from the planned consolidation of `mupmuc.nim`, `mupsic.nim`, etc. Reader knows to apply the offset.

Either patch must also revisit §2.7 line 1128-1129 which cites `src/lockfree/queue.nim:857, 1154, 1343, 1437, 1495` for the existing v5.0.0 `when T is ref:` reject pattern — those line numbers don't refer to anything in the current tree.

---

## MEDIUM findings

### M1. `nebr.ccSingle` / `nebr.ccMulti` vs queue-level `ccSingle` / `ccMulti` are not disambiguated

**Location**: §5.1.2 lines 3819-3827 — borrow-form smart constructor signatures.

**Description**: The smart-constructor signatures pass `manager: ptr DebraManager[MaxThreads, nebr.ccSingle]` for the MPSC borrow constructor and `nebr.ccMulti` for SPMC / MPMC. Everywhere else in §5 and §3 the bare names `ccSingle` and `ccMulti` are introduced as `PinScopeCardinality` values used as the queue's `ccProd` / `ccCons` axes.

`PinScopeCardinality` is itself defined in `nebr` (it tracks how many threads can pin under a single manager). So `nebr.ccSingle` and the queue's `ccSingle` *are* the same enum — but the design doc never says so explicitly, and the qualified-vs-unqualified divergence in §5.1.2 suggests they are distinct. An implementer writing the borrow constructors will (correctly) wonder whether the `MPSC` borrow demands `nebr.ccSingle` *because the manager is shared by ccSingle consumers* (true) or *because the queue's `ccCons` parameter is ccSingle* (also true, but a different framing).

**Recommended fix**: In §3.1 or §5.1.2, add a one-sentence note: "The `ccSingle` / `ccMulti` axes used by Queue and BQueue as `ccProd` / `ccCons` parameters are the same `PinScopeCardinality` values defined in `lockfree/smr/nebr/cardinality.nim` (and re-exported as bare names from `lockfree/smr/nebr.nim`). Borrow-form constructors qualify as `nebr.ccSingle` / `nebr.ccMulti` purely as a readability cue that the manager's cardinality must match the queue's consumer cardinality." Then audit §5.1.2 to either keep the `nebr.` qualifier consistently or drop it (preferred: drop, since §5 already imports nebr conventionally).

---

### M2. Section 5.9 compile-error UX claims specific message strings but does not pin them to a single source of truth

**Location**: §5.9.3 line 4452 ("Message text from queue.nim:927-932"), §5.9.4 line 4463 ("Message text from queue.nim:990"), §5.9.7 line 4501 ("From `assertBQueueParams` (bqueue.nim:182-185)").

**Description**: The error-text examples in §5.9 are the user-facing UX surface. Section 5.12 self-check item 4 ("Compile-time error messages reference user-visible names only … Confirmed against queue.nim:927-932 + bqueue.nim:184") treats them as already-existing source. They aren't — see H2. Beyond the H2 fix, the text in §5.9 should explicitly state whether the prose is **prescriptive** (this is the message the implementer must emit) or **descriptive** (this is the message that v5.0.0 emits today and will survive T-INTEGRATE).

Interleaved with H2, this matters because a Phase 3 implementer reading §5.9.3 will not know whether the words "Direct pop on a multi-consumer Queue is not allowed. Use q.getConsumerHere().pop() …" are a verbatim spec or an approximation.

**Recommended fix**: Add a header to §5.9 stating that all message strings in the section are **prescriptive specs** for the post-T-INTEGRATE library; implementers must emit verbatim. (Or, if the design intent is "any equivalent text is fine," say that instead.) Tighten the wording in OQ5.7 to match.

---

### M3. The "TBD per Q4/Q5" markers (3 occurrences) need OQ cross-links

**Location**: §1.3 line 368 (atomics op-set TBD), §2.2 area line 824 ("nimony aufbruch atomic-arc equivalent; symbol name TBD per Q4/Q5"), §4.2.1 line 2603 (table cell "nimony's equivalent of `nimDestroyAndDispose` (TBD)"), §4.3.5 line 2766 (`nimonyDestroyAndDispose(cast[pointer](uint(mref))) # symbol TBD`).

**Description**: Each of these TBDs maps cleanly to an OQ (most map to §4 OQ4.2 — nimony heap header / symbol layout). But the inline `TBD` is not cross-linked to the OQ ID; a reader has to deduce which OQ resolves it. Per the skill's hand-waving criteria, a TBD without a named resolution path is borderline; with a clear OQ link it's a deferred decision (acceptable).

**Recommended fix**: Replace each bare `TBD` with `TBD — see §4.11 OQ4.2`, `TBD — see §4.11 OQ4.4`, etc. The text already cites Q4/Q5 in §1.3 line 368, but those are *handoff* questions; the doc's own OQ numbering should be the canonical pointer.

---

### M4. Section 4.5.1 "Q-DWCAS verdict" footnote mixes v0.1.0 cell shape with a v0.2 roadmap claim

**Location**: §4.5.1 lines 3089-3098.

**Description**: The matrix immediately above (§4.5.1 lines 3055-3066) describes v0.1.0 cell shapes — committed-flag MPMC, no DWCAS. The footnote then says "the strict-LCRQ DWCAS-with-seq layout (`Atomic[Pair[uint, payload]]` cell) is a *future* rework path, not v0.1.0 ship." Fine. But the footnote also says "the DWCAS substrate exists in `nim-debra/src/debra/atomics.nim` (Pair[A,B] at atomics.nim:414 plus dwcas* family at atomics.nim:1406-1700+)" with line-number cites that overlap with §2.11 OQ2-6 ("Verify that the atomics surface lifts `ManagedRef[X]` (a `distinct uint`) through `Atomic[Pair[uint, ManagedRef[X]]]` cleanly").

The cell-shape matrix is for v0.1.0; the DWCAS substrate is for v0.2.0; the OQ tied to `Atomic[Pair[uint, ManagedRef[X]]]` is for v0.1.0 if Strict-LCRQ is in v0.1.0, but the matrix says it isn't. So OQ §2-6 (line 1333-1338) appears to be researching a v0.2.0 substrate during Phase 2.5 of a v0.1.0 design. Either OQ §2-6 should be re-tagged as v0.2.0-prep-only (and so de-scoped from Phase 2.5), or the v0.1.0 matrix needs to admit at least one site where `Atomic[Pair[uint, ManagedRef[X]]]` is exercised.

**Recommended fix**: Clarify in §4.5.1 that OQ §2-6 is v0.2.0 substrate prep, *not* a v0.1.0 fact-check gate. Or move OQ §2-6 from Category B (Phase 2.5 fact-check) to a new "Category E — v0.2 prep" so it doesn't compete for Phase 2.5 budget.

---

### M5. The "managed_ref.nim" / "managed_slice.nim" public-internal surface is not gated against external import

**Location**: §4.1 line 2553 ("callable only from the cardinality wrappers — not from user code"), §1.3 line 234 (`internal/` directory listed but `managed_ref.nim` and `managed_slice.nim` are at the top level of `lockfree/`, not inside `internal/`).

**Description**: The shim is described as internal-only, but the module layout puts `managed_ref.nim` and `managed_slice.nim` at `src/lockfree/managed_ref.nim` (not `src/lockfree/internal/managed_ref.nim`). A user can `import lockfree/managed_ref` and get the `incRefSlot` / `decRefSlot` templates. There is no `{.private.}` or `{.deprecated.}` pragma, no documentation gate. The intent ("not for external import") is stated only in the design doc.

**Recommended fix**: Pick one and document it explicitly in §4.1 / §1.3:

- **Move under `internal/`** — `src/lockfree/internal/managed_ref.nim`, `src/lockfree/internal/managed_slice.nim`. The top-level surface re-exports only the user-facing types (`ManagedRef[X]` if even that, since the doc says it should be invisible to users). This is the strongest enforcement.
- **Keep at top level but mark every internal export with `{.deprecated: "internal — do not import directly".}`**. Weaker but doesn't require module relocation.
- **Document only**. Weakest; matches what the doc currently says.

Without an explicit pick, T-INTEGRATE.d ships an underspecified contract.

---

## LOW findings

### L1. Doc-path inconsistency: `docs/guide/` vs `docs/guides/`

**Location**: §5 line 4311 uses `docs/guides/memory-management.md` (plural). Every other reference uses `docs/guide/memory-management.md` (singular) — see lines 988, 1165, 1168, 1218, 3394.

**Recommended fix**: Pick one (the singular `docs/guide/` form is dominant) and replace the plural at line 4311.

---

### L2. Section 7.4 OQ-count arithmetic has a small inconsistency

**Location**: §7.4.1 (line 5260) totals 47 raw OQs. §7.4.2 (line 5278) totals 45. §7.4.3 (line 5337) says Category D totals 3 and Category C totals 5 after collapse, but the table at 5287-5335 lists only one Category C item (§2-7) and two more "Phase 3" items hinted at in 5341 ("plus two from sequencing of nimony cell caching and pop-clears per-arm refactor") — those two are not actually rows in the table.

The discrepancy is minor (2 untabled items) but a Phase 2.2 reviewer who counts rows by category gets 45 only if §7.4.3 lists every OQ; it doesn't quite.

**Recommended fix**: Add the two implied Category C items as table rows: a Phase 3 sub-item for nimony cell caching (currently referenced by §6 O9 in Category C) and one for pop-clears per-arm Phase 3 sequencing (currently §4 OQ4.8 in Category C). Or, drop the "plus two" prose at line 5341 if the items are already covered.

---

### L3. §2.7 declares the `when`/`elif` order is load-bearing but doesn't enumerate the case for ManagedSlice arm

**Location**: §2.7 line 1131-1166.

**Description**: The reject-then-accept ordering is correct and well-justified at line 1171-1176 ("If the POD arm matched first via `supportsCopyMem` returning true for some edge case, we would silently accept something that should reject"). But the chain shown puts `T is string or T is seq` ahead of `supportsCopyMem(T) and sizeof(T) <= 8` — fine — and the recently-introduced reject for `T is ref ref` and `T is distinct and distinctBase(T) is ref` ahead of `T is ref`. The implicit claim is that these rejects don't accidentally fire for legitimate `ref T` admit cases. The doc would benefit from a one-line confirmation that `ref Foo` does not match `ref ref` (it doesn't — `ref ref` means `ref (ref X)`, which is `ref Foo` only when Foo is `ref X`).

**Recommended fix**: Add one sentence to §2.7 after the chain: "Row order is verified safe: the `ref ref` arm does not match `ref Foo` for non-ref `Foo`, and the `distinct` arm does not match plain `ref` because non-distinct types fail `T is distinct`."

---

### L4. §5.4.3 cancellation-semantics paragraph cites §3.5.1 (pinscope sync-only) but §3.5 is named "Pin lifecycle protocol" — the §3.5.1 subsection is not separately numbered in the TOC

**Location**: §5.4.3 line 4071 cross-references "§3.5.1's `withPinscope`"; the TOC at line 37 lists §3.5 only, not §3.5.1.

**Recommended fix**: Either subsection §3.5 to expose §3.5.1 in the TOC, or change the §5.4.3 reference to point to §3.5 (since the §3.5 body covers the sync-only contract).

---

## Cross-section consistency findings

### CS1. Section 1.3 module layout vs Section 4 cell shapes vs Section 5 API signatures: ALIGNED

Section 1 lists `lockfree/queue.nim` and `lockfree/bqueue.nim` as the post-T-INTEGRATE target files. Section 4.5.1 matrix calls out `MPMCCellArrayN[N, T]` and `StorageN1[N, T]` from `src/lockfree/typestates/` — verified against the actual source files (`/Users/eek/Development/lockfreequeues/src/lockfree/typestates/mpmc_cell.nim:49-54` and `storage_n1.nim` exist; the cell-layout claim that `MPMCCellArrayN` is an array of MPMCCell with `{.align: CacheLineBytes.}` matches line 49-54 of mpmc_cell.nim). Section 5.1 imports the same cell types via the queue facade. Internally consistent.

The one wart is the H2 finding: Section 5 cites future-state line numbers in `queue.nim`/`bqueue.nim`. Once H2 is patched the cross-section consistency holds.

### CS2. Section 3 nebr characterization vs Section 4 cell layouts: PARTIALLY ALIGNED

Section 3.11 (memory model claims) and Section 4.5.1 (per-arm cell shape) both treat the slot's bit-state as governed by per-cell atomic ops (seq counter for bounded MPMC; committed flag for unbounded). Section 3.6 (retire/reclaim) speaks in terms of "objects retired BEFORE this epoch are safe" using `safeEpoch - 1` — verified against `imports/nim-debra/src/debra/typestates/reclaim.nim:266`:

```
let safeEpoch = ctx.safeEpoch - 1 # Objects retired BEFORE this epoch are safe
```

Doc claim matches source. Section 3.6's "re-stamping invariant" (bag.epoch = current epoch on every retire, not just on bag creation) is verified against `imports/nim-debra/src/debra/typestates/retire.nim:200`:

```
bag.epoch = epoch
```

with the preceding comment block (lines 185-198) matching the design's rationale almost verbatim. ALIGNED.

The "partially" is on a minor cross-link: Section 3.10 (typestate-encoded guards) references the nebr typestate FSMs by individual transition name (`retire` → `RetireReady` → `Retired`); Section 4.7 (destructor walk integration) references "the destructor walk under `-d:lockfreeRefcountAudit`" (§4.1 line 2577) without showing how the destructor walk interacts with the SMR pin state. The implementer needs to know: does `=destroy[Queue]` pin under nebr, or does it run only after all readers have unpinned? The doc says the latter implicitly (queue.nim:1001-1006 cite at line 3904: "Precondition: all attached workers joined"), but Section 4.7 should cross-link to that precondition.

**Recommended fix**: In §4.7, add a one-line precondition statement: "The destructor walk runs only after `unbindClient` for every attached worker has completed (see §5.1.6); no SMR pin is held during the walk because all workers have unpinned."

### CS3. Section 5 chronos pattern vs Section 6 chronos CI cell: ALIGNED

§5.6 hybrid pattern (`when defined(lockfreeChronos) or (compiles do: import chronos):`) matches §6.3 cell 12 (chronos Tier 3 adapter verification, runs `tests/t_chronos_*.nim` with `nimble install chronos` and `-d:lockfreeChronos`). Section 5.10 OQ5.4 (chronos version cap) is acknowledged in Section 6 implicitly (cell 12 is pinned to the chronos version installed by `nimble install chronos`). ALIGNED.

### CS4. Section 2 Path C dispatch vs Section 4 MM shim arms: ALIGNED

§2.5 row 1-25 dispositions (ACCEPT or REJECT) correspond to §4.2 per-MM shim ops. ACCEPT rows route through ManagedRef arm; REJECT rows hit the `{.error.}` overload in §2.7. The `mm:none` arm in §4.2.1 (line 2598) is `discard` (no-op), consistent with §2.8's "pure bit transport" framing. ALIGNED.

### CS5. Section 7 risk register vs earlier section mitigations: ALIGNED with one cross-link gap

§7.5 R7 (ManagedSlice for arbitrary T's `seq[T]` leak concern) is mitigated by "Type-system reject of non-POD T inside `seq[T]` via `static: assert T is PodType`-style guard." Section 2.3 (ManagedSlice type definition) is the place this guard should appear — verified at line 944 area; the design says "ManagedSlice[T] for `seq[T]` where T satisfies supportsCopyMem(T)" but the guard itself is described as conceptual, not concretely placed in any code sample. R7 mitigates the risk in concept; an implementer needs the actual `static: assert` text.

**Recommended fix**: Add the guard wording (`static: assert supportsCopyMem(T), "ManagedSlice[T] requires T to satisfy supportsCopyMem (POD-like)"`) as a code sample in §2.3.

---

## Hand-waving findings

The doc has 8 hand-waving markers (per grep `TBD|TODO|to be determined|to be decided|future work|will be (decided|determined)`):

| Location | Marker | Defensible? |
|---|---|---|
| Line 147 "Tier 1 (threads/locks) and Tier 2 (custom) adapters — future work" | Future work | YES — in-scope cuts per handoff Q6. |
| Line 368 "atomics op-set we use across arc/orc/atomicArc (TBD at lift time…)" | TBD | PARTIAL — should cross-link to an OQ; see M3. |
| Line 824 "nimony aufbruch atomic-arc equivalent; symbol name TBD per Q4/Q5" | TBD | PARTIAL — cross-link should be to OQ4.2, not Q4/Q5 (handoff Q4/Q5 was the input, OQ4.2 is the disposition); see M3. |
| Line 2396 "CI; future work." | Future work | YES — context is a paragraph about CI cells beyond v0.1.0 scope. |
| Line 2603 "nimony's equivalent of `nimDestroyAndDispose` (TBD)" | TBD | PARTIAL — same as line 824; see M3. |
| Line 2766 "nimonyDestroyAndDispose(cast[pointer](uint(mref))) # symbol TBD" | TBD | PARTIAL — same as line 824; see M3. |
| Line 5088 "debra_plus.md (reserved; faithful Brown 2015 future work)" | Future work | YES — explicitly reserved name; not a gap. |
| Line 5152 "Repo URL: TBD per CRITICAL #5 publication path deferral" | TBD | YES — deferred per CRITICAL #5 disposition; correctly cross-linked. |

**Summary**: 4 of 8 markers are defensible. The remaining 4 (lines 368, 824, 2603, 2766) all collapse to the same root cause — nimony symbol names not yet verified — and need a cross-link to OQ4.2 / OQ4.4. M3 captures the patch.

**No "scope cut order" appears in the doc.** §7.6 explicitly states the operator's standing rule that no contingency-cut-order list is preprovided. Per the operator's MEMORY.md rule `feedback_no_autonomous_scope_cuts`. Verified compliant.

---

## OQ quality assessment

The 45-item consolidated OQ list (§7.4.3) is **high quality overall**:

- **Category B (Phase 2.5 fact-check) = 19 items**: every Category B item is a concrete, verifiable codebase question. Examples: §2-2 ("nimony `arcInc`/`arcDec` symbol names — verify against nimony aufbruch source"), §4 OQ4.5 ("`NimStringV2.cap` tag-bit layout under arc/orc — verify against pinned Nim source"). These are *real* fact-checks, not decisions in disguise.
- **Category A (Phase 2.2 design-doc review) = 18 items**: design-shape judgment calls. Examples: §1 Q1.10-D ("Reserved SMR module names — comment-only or `{.error.}` stubs?" with recommendation "Comment-only"), §5 OQ5.1 ("Default callback on `destroyAndDrain` for POD" with recommendation "Provide the zero-arg overload only for POD"). Each carries a recommendation, so Phase 2.2 reviews against an explicit default rather than a true open fork.
- **Category C (Phase 3 plan) = 5 items**: sequencing questions appropriate to deferral.
- **Category D (operator-only) = 3 items**: §6 O1 (wall-clock GREEN/YELLOW/RED), O4 (Windows in v0.2?), O5 (`nim cpp` axis?). All three correctly require operator input.

**One OQ is borderline-decision-in-disguise**: §5 OQ5.3 ("AsyncQueue vs explicit endpoint async") with recommendation "ship both" — this is effectively a scope expansion (ship both surfaces). The doc could either lock the recommendation in §5.4 or surface it as a genuine fork to operator. Lean toward locking, since the cost of both surfaces is small and the doc has already invested in both.

**Verdict**: OQ list is well-curated. No spurious decisions disguised as questions. No question is unanswerable by the targeted phase.

---

## Verification anchor results (operator-supplied 5-cite spot check)

| # | Cite | Doc claim | Source | Verdict |
|---|---|---|---|---|
| 1 | `imports/nim-debra/src/debra/typestates/retire.nim:130-202` | Section 3's re-stamping invariant: `bag.epoch = epoch` on every retire, not just on bag creation. | Lines 199-202: `let bag = state.currentBag; bag.epoch = epoch; bag.objects[bag.count] = …; inc bag.count`. Preceding comment (lines 185-198) gives the re-stamping rationale verbatim. | **PASS** — exact match. |
| 2 | `src/lockfree/typestates/mpmc_cell.nim:49-54` | Section 4's cell-layout claim: `MPMCCellArrayN[N, T]` with `{.align: CacheLineBytes.}` on `cells`. | Lines 49-54: `MPMCCellArrayN*[N: static int, T] = object … cells* {.align: CacheLineBytes.}: array[N, MPMCCell[T]]`. | **PASS** — exact match. |
| 3 | `~/.nimble/pkgcache/githubcom_nimlangNimgit_2210/lib/system/arc.nim:167` | Section 4's mapping: `nimIncRef(p: pointer)` is the per-MM inc op for arc / atomicArc. | Line 167-175: `proc nimIncRef(p: pointer) {.compilerRtl, inl.} = … increment head(p) …`. The symbol unconditionally increments; the design's note about the shim guarding nil before the call is consistent. | **PASS** — exact match. Also verified line 238 (`nimDecRefIsLast`), 218 (`nimDestroyAndDispose`), 248-252 (atomicArc dec branch). |
| 4 | `src/lockfree/queue.nim:927-932` | Section 5.9.3's "Direct pop on a multi-consumer Queue is not allowed" error text. | **FILE DOES NOT EXIST** in `src/lockfree/`. The file is a post-T-INTEGRATE target. | **FAIL** — anchor is unverifiable because the file is aspirational. See finding H2. |
| 5 | `imports/nim-debra/src/debra/typestates/reclaim.nim:266` | Section 3's safeEpoch-1 bound claim: objects retired before `safeEpoch - 1` are reclaimable. | Line 266: `let safeEpoch = ctx.safeEpoch - 1 # Objects retired BEFORE this epoch are safe`. | **PASS** — exact match. |

**4 of 5 anchors pass.** The fifth fails because it cites a file that does not yet exist; this is exactly the issue captured by H2.

The pass-rate is encouraging: the design's claims about *existing source* (nim-debra, lockfreequeues v5.0.0 typestate substrate, Nim 2.2.10 system module) are accurate where they cite line numbers. The failure mode is purely the post-T-INTEGRATE projection.

---

## Cross-decision integrity

| Decision | Sections | Consistency |
|---|---|---|
| mm:none contract | §1.9 (1-line summary), §2.8 (full spec), §4.2.1 mm:none row (`discard` for all ops), §5.7.3 (mm:none drain contract) | **CONSISTENT** — all four sections agree the queue is a pure bit transport, and the user is responsible for drain. §1.9 cross-references §2.8 + §4.8 + §5.7. |
| nebr naming (no `debra_plus` leakage) | §1.3 module layout (line 207, 251, 258-260), §3 throughout, §7.5 R6 mitigation | **CONSISTENT** — all `debra_plus` references are either reserved-future-name comments or explicit contrast with nebr. No accidental survivors. |
| Path C: ref T user-facing, ManagedRef internal-only | §2.2, §2.5 (matrix), §5.1.4 (dispatch), §5.12 self-check item 3 | **CONSISTENT** — user types `Queue[ref Foo, ...]`, never `Queue[ManagedRef[Foo], ...]`. The `when T is ref:` arm routes internally. M5 captures a small enforcement gap (managed_ref.nim is at top-level not under `internal/`). |
| chronos hybrid | §1.5 (soft-dep gate), §5.6 (the `when defined(lockfreeChronos) or (compiles do: import chronos):` pattern), §6.3 cell 12 (CI verifies the gate), handoff CRITICAL #4 | **CONSISTENT** — three places repeat the same gate predicate; cell 12 exercises it end-to-end. |

---

## Recommendations for Phase 2.4 fix work

Priority order:

1. **H1** — Add a Phase-1.6-disposition table in §7.10 mapping CRITICAL #1 → #5 to resolving sections. CRITICAL #3 either gets resolved-here pointer or explicit still-open disposition. (~1 hour.)
2. **H2** — Section 5-wide `queue.nim:NNN` / `bqueue.nim:NNN` cite review. Apply Patch A (preferred) or Patch B from the H2 description. Also touch §2.7 line 1128-1129. (~2-3 hours; involves either renaming all cites or adding a single header note.)
3. **M1** — Add the `nebr.ccSingle` / queue-level `ccSingle` disambiguation note in §3.1 or §5.1.2. (~15 min.)
4. **M2** — Add the prescriptive-vs-descriptive header to §5.9. (~10 min.)
5. **M3** — Cross-link 4 inline `TBD` markers (lines 368, 824, 2603, 2766) to OQ4.2 / OQ4.4. (~10 min.)
6. **M4** — Clarify OQ §2-6's v0.2-substrate-prep status; either re-tag or accept as v0.1.0 fact-check. (~15 min.)
7. **M5** — Pick an internal-shim enforcement strategy (move under `internal/`, deprecate, or document-only) and apply. (~30 min.)
8. **CS2** — Add the destructor-walk precondition cross-link in §4.7. (~5 min.)
9. **CS5** — Add the `static: assert` ManagedSlice guard wording as a code sample in §2.3. (~5 min.)
10. **L1-L4** — Quick cleanups; ~15 min total.

**Total**: ~5 hours of focused fix work. Achievable in a single Phase 2.4 dispatch.

After fixes land, no Phase 2.2 re-review needed; the changes are spot fixes, not structural. Phase 2.5 (fact-check) and Phase 3 (impl plan) can begin in parallel with the fix dispatch, since the fact-check work is OQ-list-driven and the impl plan keys off the (correct) module layout in §1.3.

---

## Skill self-check

- [x] Full document inventory complete (Sections 1–7 + 3 appendices + safety-argument.md companion).
- [x] Every CRITICAL devil's advocate finding tracked (CRITICAL #3 missing — H1).
- [x] Composition matrix (25 rows) checked for completeness and concreteness — concrete.
- [x] Cell-shape matrix (8 arms × 3 payload types) checked — concrete.
- [x] Per-MM shim matrix (6 MMs × 4 ops) checked — concrete; cites verified against Nim source for arc/orc.
- [x] All 5 verification anchors spot-checked against source (4 pass, 1 fail per H2).
- [x] Hand-waving inventory: 8 markers; 4 defensible, 4 need OQ cross-links (M3).
- [x] OQ quality assessment: 45 items, all properly categorized except OQ §2-6 ambiguity (M4) and OQ5.3 borderline decision-in-disguise.
- [x] Cross-decision integrity: 4 decisions checked, all consistent.
- [x] Every finding carries severity, location (section + line), description, and concrete fix.
- [x] Prioritized remediation plan provided.
- [x] No AI attribution / emojis / commits in artifact.
