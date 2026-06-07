# Phase 3.2-redux: Re-review Report

**Date**: 2026-06-06
**Plan**: `/Users/eek/Development/lockfree/docs/internal/2026-06-06-umbrella-v0.1.0-impl-plan.md` (1360 lines)
**Original review**: `/Users/eek/Development/lockfree/docs/internal/impl-plan-review-2026-06-06.md` (444 lines)
**Reviewer**: reviewing-impl-plans skill (Claude Opus 4.7), abbreviated re-review form
**Scope**: CRITICAL (3) + HIGH (5) only. MEDIUM (6) + LOW (4) assumed fixed; not re-verified.
**Verdict**: **READY**

## Summary

- CRITICAL fixes holding: **3/3**
- HIGH fixes holding: **5/5**
- (MEDIUM and LOW assumed fixed; not re-verified in this focused re-review)
- Cross-doc reframe (design §4.5.2, §6.4 R2, §7.x R2 table, safety-argument §6.4) consistent and reciprocal — no orphan claims.

The fixes are tight, internally consistent, and verifiable against the working tree. The plan is ready to advance to Phase 3.3 (approval gate) and Phase 3.4.5 (execution mode analysis).

---

## Verifications

### CRITICAL-1 — Path coherence: PASS

**Methodology**: spot-checked 5 of 8 renamed `T-VERIFY-POP-CLEARS.*` tasks at impl plan lines 288-426; cross-validated each cited path against the working tree.

**Evidence**:
- `ls src/lockfree/typestates/` returns: `spsc_pop.nim`, `mpsc_pop.nim`, `spmc_pop.nim`, `mpmc_pop.nim` — all four bounded targets exist at the cited path.
- `grep -n 'move(' src/lockfree/typestates/spsc_pop.nim` confirms line 72 contains `let value = move(queue.storage[op.slot])` — exact match to the plan's cite at line 290 + 293.
- `grep -n 'move(seg.data' src/lockfree/queue.nim` returns hits at lines 874, 1360, 1380, 1475 — exact match to plan cites for `T-VERIFY-POP-CLEARS.unbounded-{mpsc,spsc,spmc,mpmc}` at plan lines 390/393, 372/375, 404/407, 418/421.
- The plan's narrative comment at line 372 ("unbounded pops are NOT in separate `unbounded_*_pop.nim` files — they are inlined in `queue.nim` in the lockfree integration tree") explicitly addresses the original CRITICAL-1 confusion about file existence. Path correction is acknowledged in-task, not just silently fixed.

**Residual**: None. All 8 cited paths/lines resolve to the actual source.

---

### CRITICAL-2 — Defect premise reframe: PASS

**Methodology**: spot-checked the four-document chain (impl plan §3.4 header + per-task descriptions; design §4.5.2 table; design §6.4 R2 risk row; safety-argument §6.4 update).

**Evidence**:
- Impl plan lines 28-54 ("Phase 3.4 investigation — pop-clears mechanism (CRITICAL-2 disposition)") cleanly states the reframe: 8 tasks renamed `T-INTEGRATE-POP.*` → `T-VERIFY-POP-CLEARS.*`, scoped to regression-test-only, because `move()` is already in the lockfree integration tree and is observationally equivalent to `.reset()`.
- Design §4.5.2 table (lines 3191-3221) explicitly carries a "**Phase 3.4 update (2026-06-06)**" preamble at line 3191 and reframes each of the 8 arm rows from "Plain read; no clear" to "uses `move(...)`; observationally equivalent to `.reset()`". Each row also names the new `T-VERIFY-POP-CLEARS.*` task in its mitigation column.
- Design §6.4 R2 row (line 5499) AND the duplicate R2 row at line 5851 BOTH carry the Phase 3.4 reframe: "the lockfree integration substrate has already wrapped each pop read in `move()`... v0.1.0 ships per-arm regression tests (T-VERIFY-POP-CLEARS.*) that lock in the existing behavior so a future refactor cannot silently revert." No drift between the two R2 occurrences.
- Safety-argument lines 443-458 carry a matching "Phase 3.4 update" reframe pointing back at design §4.5.2 and stating "the pop's destructive read (whether via `.reset()` or `move()`) is the mechanism that produces the 0-bit state."
- Per-task descriptions in the impl plan (e.g., T-VERIFY-POP-CLEARS.spsc at line 290) state the reframe inline, so an executing agent does not need to re-derive it from the cross-doc context.

**Residual**: None. The reframe is internally consistent across all four documents and is unlikely to confuse a downstream executor.

---

### CRITICAL-3 — PG-5 race protocol: PASS

**Methodology**: read PG-5 race protocol section (impl plan lines 126-153) and the per-task dependency declarations on T-MANAGED-REF, T-MANAGED-SLICE, T-NIMONY-ARMS (lines 583-656).

**Evidence**:
- Protocol picks **Option A: hard serialization with stub protocol** (line 129) — one of the two options the original review recommended (the cleaner one per Develop = Thoroughness Mode).
- PG-5a (line 132) specifies the exact stub form: `when defined(nimony): {.error: "filled by T-NIMONY-ARMS".}` — quoted verbatim, grep-able sentinel string.
- PG-5b (line 147) specifies what T-NIMONY-ARMS does: replaces the stubs in managed_ref.nim + managed_slice.nim AND adds nimony arms to atomics + smr/nebr. The non-overlap on atomics + smr/nebr files is called out so the only shared edit surface is the stub block.
- Verification grep (line 153): `grep -rn 'filled by T-NIMONY-ARMS' src/` MUST return zero hits after PG-5b. This is concretely added to T-NIMONY-ARMS acceptance (line 644's task body).
- Per-task placements: T-MANAGED-REF at PG-5a (line 602), T-MANAGED-SLICE at PG-5a (line 628), T-NIMONY-ARMS at PG-5b with deps `PG-5a complete` (line 644 + line 654). Concrete file paths (`src/lockfree/managed_ref.nim`, `src/lockfree/managed_slice.nim`) and stub markers are named.

**Residual**: None. Two parallel agents on PG-5a cannot race because they edit disjoint files (managed_ref.nim and managed_slice.nim are separate modules). PG-5b runs alone as a single-task PG. The "conflict-free invariant" claim at line 151 is sound.

---

### HIGH-1 — T-INTEGRATE.b ↔ .c dependency: PASS

**Methodology**: read T-INTEGRATE.b deliverable (line 441) and acceptance (line 444); read T-INTEGRATE.c description (line 457).

**Evidence**:
- T-INTEGRATE.b deliverable now explicitly folds the import rewrite for **lifted files only** (line 441): "T-INTEGRATE.b also rewrites the lifted files' internal imports (`debra/atomics` → `lockfreequeues/atomics`; `debra` self-refs → `lockfreequeues/smr/nebr`) so the standalone-compile acceptance can be satisfied at PG-2 time."
- T-INTEGRATE.b acceptance line 444 explicitly justifies satisfiability: "succeeds because T-INTEGRATE.b's import rewrite (per HIGH-1 fix) leaves the lifted files referencing the post-PG-1 atomics location".
- T-INTEGRATE.c (line 457) is correctly scoped to the **remaining** repo-wide rewrite ("Rewrite ALL OTHER internal import paths repo-wide... the lifted `smr/nebr/` files' OWN imports are already rewritten by T-INTEGRATE.b"). The "do not double-touch" note at line 463 makes the boundary explicit.

**Residual**: None. The acceptance is now actually satisfiable inside PG-2. The "minimal" import rewrite in .b is also concretely scoped (only the lifted files, only two import patterns) so the .b/.c boundary won't drift.

---

### HIGH-2 — T-INTEGRATE-PRE-PRED predicate signatures: PASS

**Methodology**: read T-INTEGRATE-PRE-PRED (impl plan lines 205-258).

**Evidence**:
- All 7 predicates (the original review called out 5; the design actually carries 7 once `seqIsClaimed` + `slotIsCommittedAndUnread` are counted) are inlined verbatim at lines 209-236 with proc names, parameter lists, and return types. The block is fenced as Nim code with the explicit file destination (`src/lockfree/typestates/slot_state.nim — NEW MODULE`).
- Acceptance line 253 adds: "**Predicate signatures match design §4.6.2 lines 3284-3335 verbatim** (HIGH-2 Phase 3.4 fix — cross-module consumers depend on signature stability)."
- Cross-module consumer warning at line 238 ("T-PATH-C-DISPATCH (PG-6) and T-DRAIN-HELPERS (PG-7) consume this module. Drift in predicate signatures breaks downstream integration.") preserves the original review's concern.
- The "verify the 5 inline CLOSED_BIT sites claim via grep before executing" check is also explicit at line 207 + the file-modify note at line 242 (`grep -cE '\(.*and.*CLOSED_BIT.*\).*!= *0' src/lockfree/queue.nim before edit`).

**Residual**: None. Executing agent doesn't need to leave the plan to learn the contract.

---

### HIGH-3 — T-PATH-C-DISPATCH nimony dep: PASS

**Methodology**: read T-PATH-C-DISPATCH (impl plan lines 660-680).

**Evidence**:
- Dependencies line 668 now explicitly adds T-NIMONY-ARMS as a true dep: "T-MANAGED-REF, T-MANAGED-SLICE, T-NIMONY-ARMS. (HIGH-3 Phase 3.4 fix: per `Develop = Thoroughness Mode`, T-NIMONY-ARMS is added as a true dep so nimony compile coverage is gated alongside the other MMs. The R4 `continue-on-error: true` mitigation in T-CI-NIMONY still applies for upstream nimony churn, but the plan-time dependency is explicit.)"
- Acceptance line 675 retains the explicit `continue-on-error` carve-out for the CI cell, so the dep is real but the CI cell still won't block if nimony upstream is broken.
- PG-6 placement (line 678) is consistent with PG-5b being a strict predecessor.

**Residual**: None. Thoroughness path picked, matches operator philosophy.

---

### HIGH-4 — T-CI-WALLCLOCK-BASELINE acceptance: PASS

**Methodology**: read T-CI-WALLCLOCK-BASELINE (impl plan lines 182-201).

**Evidence**:
- Acceptance at lines 190-196 is now framed as "(HIGH-4 Phase 3.4 fix — reworded to be satisfiable at PG-0 time)" and uses the proxy-then-project model the original review recommended: existing v5.0.0 suite × 1.6 multiplier, with explicit rationale.
- Cells that cannot be proxied (nimony, chronos) are handled by a "deferred to PG-10 re-measure" carve-out (line 196) — does not silently drop them.
- "No autonomous cuts" guardrail at line 195 ("surface to operator via AskUserQuestion") is correctly invoked per the project's `feedback_no_autonomous_scope_cuts` standing rule.

**Residual**: None. The acceptance is now actually executable at PG-0.

---

### HIGH-5 — T-CHRONOS 4-cell acceptance: PASS

**Methodology**: read T-CHRONOS (impl plan lines 757-781).

**Evidence**:
- Acceptance at lines 770-776 is rewritten as 4 explicit cells `(a)` through `(d)` matching the original review's required structure exactly:
  - (a) chronos installed + no `-d:` → auto-detect compile success.
  - (b) chronos installed + `-d:lockfreeChronos` → opt-in compile success.
  - (c) chronos NOT installed + `-d:lockfreeChronos` → emits the documented `{.error.}` message per §5.6.6 / OQ5.5.
  - (d) chronos NOT installed + no `-d:` → AsyncQueue/AsyncBQueue invisible.
- The cite to §5.6.6 (OQ5.5 disposition) preserves the design-level grounding.
- Pinscope unwind discipline (R10) is retained as a separate acceptance bullet, not collapsed into the 4 cells.

**Residual**: None. Logic-error (the original AND-conjunction) is replaced with an explicit 4-state table.

---

## Cross-doc consistency spot-check

For CRITICAL-2 in particular, the original review noted that an inconsistent reframe across the four docs would re-introduce the defect-premise confusion downstream. Re-verified that:

- Impl plan top-of-file Phase 3.4 disposition (lines 28-54) ↔ per-task descriptions (line 290 etc.) ↔ R2 row in §7.x risk register (line 1337). No drift.
- Design §4.5.2 (lines 3191-3221) ↔ §6.4 R2 (line 5499) ↔ §7.x duplicate R2 (line 5851). Same reframe text in both R2 occurrences. No drift.
- Safety-argument §6.4 (lines 443-458) explicitly back-references design §4.5.2 (Phase 3.4 update). No drift.

The reframe is reciprocal across documents; downstream consumers will not encounter conflicting framings.

---

## Residual concerns

None that block Phase 3.3 approval gate. Minor observations (not findings):

1. **MEDIUM/LOW assumed-fixed**: Per the re-review scope contract, MEDIUM (6) + LOW (4) were not re-verified. If any of those fixes were skipped or done poorly, a subsequent narrow re-review pass would be needed. The fixes I incidentally observed inline (MEDIUM-2 rollback contract at line 574; MEDIUM-3 cross-link at line 598; HIGH-2's verify-claim guardrail at line 207) all looked clean, which is a positive signal about the overall fix-pass quality.

2. **T-INTEGRATE-PRE-PRED predicate count was 5 → 7**: The HIGH-2 inline expansion landed 7 predicates (5 originally called out + `seqIsClaimed` + `slotIsCommittedAndUnread`). This is a positive change (more contract surface explicit) but is worth flagging in the Phase 3.3 narrative so the operator knows the PRE-PRED task slightly expanded scope. Not a blocker.

3. **PG-5a internal parallelism**: The protocol relies on T-MANAGED-REF and T-MANAGED-SLICE each writing **only** their own module file. If a future edit to either task description adds a cross-module helper write (e.g., a shared utility in `src/lockfree/internal/managed_common.nim`), the conflict-free invariant breaks. Not a current concern; flagging as a future-edit hazard.

---

## Recommendation

**READY** for Phase 3.3 approval gate + Phase 3.4.5 execution mode analysis.

All 3 CRITICAL and all 5 HIGH findings have concrete, verifiable fixes embedded in the plan with cross-document reciprocity. The plan is structurally sound, work items are correctly classified across PGs (PG-0 → PG-1 → ... → PG-10 with PG-D parallel-with-code and PG-Z parallel-after-PG-4), and the PG-5 race protocol is the only previously-underspecified interface contract — now fully specified.

No second-round fix pass needed. Proceed.

End of re-review.
