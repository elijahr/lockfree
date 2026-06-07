# §4.6.2 type-vs-source drift investigation

Date: 2026-06-06
Repo: `/Users/eek/Development/lockfree` (branch `feat/v5.0.0-impl`)
Trigger: T-INTEGRATE-PRE-PRED halted on signature drift between design §4.6.2 (canonical doc lines 3351-3402) and the integration-tree source.

---

## 1. Verdict

**VERDICT C: Mixed — split by predicate family.**

Two halves of §4.6.2 land differently against the actual source substrate:

### 1.a Bounded-Vyukov half (`seqIsEmpty`, `seqIsFilled`, `seqIsClosed`, `seqIsClaimed`, `seqIsLive`)

**Drafted against a REAL type (`MPMCCell[T]` in the bounded-typestate layer), not an imagined one.** The drift the orchestrator observed is at the wrong cell-layer:

- `MPMCCell[T]` exists at `src/lockfree/typestates/mpmc_cell.nim:28-48` with `payload.seq: Atomic[uint64]` (mpmc_cell.nim:25). The `uint64` choice in §4.6.2 lines 3360-3388 matches verbatim.
- `LCRQCell[T]` at `src/lockfree/queue.nim:132` is a DIFFERENT type at a DIFFERENT layer — the integration tree's unbounded MPMC arm (strict-LCRQ Phase B substrate); see §1.b below.
- These two layers are NOT the same thing. The §4.6.2 predicates target the bounded-Vyukov layer (`MPMCCellArrayN[N, T]` at `mpmc_cell.nim:50-55`), used by bounded MPMC/MPSC/SPMC at `typestates/mpmc_push.nim:58`, `mpmc_pop.nim:56`, `mpsc_pop.nim:62`, `mpsc_push.nim:61`, `spmc_pop.nim:59`, `spmc_push.nim:64`.
- However, this layer has **zero current `CLOSED_BIT` references** (`grep -nE 'CLOSED_BIT' src/lockfree/typestates/*.nim` → no hits). The 5 inline `(seq and CLOSED_BIT) != 0'u` sites the impl plan T-INTEGRATE-PRE-PRED targets are all in `queue.nim` (lines 122, 225, 1258, 1568, 1656, 1711), which uses `LCRQCell[T]`, `Pair[uint, T]`, and platform `uint` — not `MPMCCell[T]` / `uint64`.

So §4.6.2's bounded-half signatures are correct for a layer that **has no CLOSED_BIT call sites**, and wrong for the layer that **has CLOSED_BIT call sites**. T-INTEGRATE-PRE-PRED as written cannot apply them as-is.

### 1.b Unbounded-committed-flag half (`slotIsCommittedAndUnread`)

**Drafted against the v5.0.0-source MPMCSegment, not against the integration-tree MPMC Segment.**

- `MPMCSegment[S, T]` with `committed*: array[S, Atomic[bool]]` exists in v5.0.0 source at `/Users/eek/Development/lockfreequeues/src/lockfree/typestates/unbounded_mpmc_push.nim:12-17`. §4.6.2 line 3395-3402 matches this verbatim.
- The integration tree `/Users/eek/Development/lockfree/src/lockfree/queue.nim:300-346` defines a different cardinality-parametric `Segment[T, ccProd, ccCons, S]` where the MPMC arm has `cells: array[S, LCRQCell[T]]` (queue.nim:325) and `committed` is present **only** on the MPSC arm (queue.nim:343).
- Cause: the integration tree has **already migrated** unbounded MPMC from committed-flag to strict-LCRQ DWCAS (Phase B substrate; queue.nim:1616-1628 fast-path uses `tryClaim[T](seg.cells[mySlot], 0'u)`).
- Design §4.5.1 (line 3178) and §4.5.1 notes (lines 3195-3201) say unbounded MPMC for v0.1.0 **stays committed-flag** ("Pop reads `committed[i]` to decide whether the slot is published, then claims via head-cursor CAS"). Design §1.5 (line 5669) and §7.1 (line 5316) reinforce: "Strict-LCRQ MPMC unbounded queue | NO | Stays committed-flag in v0.1.0". Design §4.5.1 line 3203-3212 explicitly defers strict-LCRQ to v0.2.0.
- **The integration substrate is already AHEAD of the v0.1.0 design's stated scope.** This is a strict superset of what the orchestrator initially diagnosed.

Two sub-cases for the predicate:
- For unbounded MPSC arm (which DID retain `committed` per queue.nim:343): `slotIsCommittedAndUnread` as specified maps onto it — replacing `MPMCSegment[S, T]` with `Segment[T, ccMulti, ccSingle, S]`. The `committed[slot].load(moRelaxed)` access is exact.
- For unbounded MPMC arm (which migrated to LCRQ cells): `slotIsCommittedAndUnread` as specified does NOT apply at all. The MPMC equivalent is now "slot has been published AND not yet claimed", which under the LCRQ encoding is `seqIsFilled(s, pos) and not seqIsClosed(s)` — i.e., the **bounded** `seqIsLive` predicate applies bit-for-bit to the unbounded MPMC `cells[i].payload.first` load (cell type aside).

### 1.c bqueue.nim clause

The plan's "parallel CLOSED_BIT sites in bqueue.nim" claim is **refuted**: `grep -nE 'CLOSED_BIT' src/lockfree/bqueue.nim` → zero hits. bqueue.nim only references `MPMCCellArrayN` (line 156, 165) and has no close-on-empty path. T-INTEGRATE-PRE-PRED's bqueue.nim modify-list and acceptance criterion "queue.nim + bqueue.nim use named predicates only" are vacuous on bqueue.nim. Drop it from the task.

---

## 2. Per-investigation-question findings

### Q1. Does design §4.6.2 itself state which types it's against?

**No explicit statement.** §4.6.2 (lines 3353-3402) introduces the predicate module without naming a target layer. Its in-module imports are `./virtual_values_n` and `./mpmc_cell` (line 3354-3356), which are bounded-typestate-layer modules (both exist at `src/lockfree/typestates/mpmc_cell.nim` and `virtual_values_n.nim`). The location text at §4.6.3 (lines 3404-3417) lists call-site consumers as `mpmc_pop.nim`, `mpsc_pop.nim`, `spmc_pop.nim`, `mpmc_push.nim`, `mpsc_push.nim`, `spmc_push.nim` (typestate layer) and `unbounded_*_pop.nim` (NOT in the integration tree — see Q2). No mention of `queue.nim` or `LCRQCell` or strict-LCRQ.

### Q2. Does the design doc indicate LCRQCell → MPMCCell rename during integration?

**No rename direction is documented.** Greps for "rename", "post-PG-5", "post-PG-6", "post-integration" in the canonical design return only PR-publication rename references (e.g., debra → nebr at line 137; package rename at lines 5346-5347), never a cell-type rename. The two cell types coexist in the design's mental model: `MPMCCell[T]` (bounded Vyukov) at §4.5.1 lines 3172-3174 and §4.5.1 notes lines 3182-3187; strict-LCRQ "DWCAS-with-seq layout (`Atomic[Pair[uint, payload]]` cell)" at §4.5.1 lines 3203-3212 explicitly marked **deferred to v0.2.0**.

**However:** the integration tree `queue.nim` has shipped strict-LCRQ for unbounded MPMC **early** (queue.nim:132 introduces `LCRQCell[T] = Atomic[Pair[uint, T]]`; queue.nim:1616-1632 uses `tryClaim` DWCAS in the MPMC pop fast-path). This was not part of the design's v0.1.0 plan.

### Q3. Does design specify MPMC unbounded should have a `committed` field post-integration?

**Yes — design intends `committed` for unbounded MPMC in v0.1.0:**
- §4.5.1 line 3178: "Unbounded MPMC (UnboundedMupmuc) | segment.data `array[S, T]` + segment.committed | …"
- §4.5.1 lines 3195-3201: "`{data: array[S, T]; next: Atomic[ptr Segment]; tail: Atomic[int]; prevConsumerIdx: Atomic[int]; committed: array[S, Atomic[bool]]}`. The protocol state is the `committed` flag array — a separate Atomic[bool] per slot. Pop reads `committed[i]` to decide whether the slot is published, then claims via head-cursor CAS."
- §4.7.2 lines 3494-3511 (destructor walk) calls `slotIsCommittedAndUnread(seg[], slot, seg.prevConsumerIdx.load(moRelaxed))` on `UnboundedMupmucBase[S, ManagedRef[X], MT]`.

**Source contradicts this for unbounded MPMC arm:** queue.nim:323-325 puts `cells: array[S, LCRQCell[T]]` on MPMC and `committed` on MPSC only (queue.nim:343). The MPSC arm still matches design (committed-flag preserved per queue.nim:327-330 comment: "MPSC (ccMulti × ccSingle): legacy committed+data overlay preserved verbatim (NOT migrating in Phase B; symmetric with BQueue staying unchanged)").

### Q4. What do PG-6 / PG-7 task specs assume about predicate signatures?

**Neither task references the predicates by name.** Plan line 258 ASSERTS "T-PATH-C-DISPATCH (PG-6) and T-DRAIN-HELPERS (PG-7) consume this module. Drift in predicate signatures breaks downstream integration." But:
- T-PATH-C-DISPATCH (plan lines 708-728) discusses `when T is ref:` / `when T is string|seq:` dispatch into push/pop. No `seqIsClosed` / `slotIsCommittedAndUnread` mentions.
- T-DRAIN-HELPERS (plan lines 732-752) describes drain + destroyAndDrain. References design §4.8, §5.7 — these sections cover the user-facing drain API, NOT the slot-state predicates.
- The actual consumer of the §4.6.2 predicates is **§4.7 destructor walk**, not §4.8 drain. Plan line 258 conflates them.

So PG-6 and PG-7 do **not** have a hard signature dependency on §4.6.2. The destructor walk (which IS the real consumer) is not currently assigned to a PG in the impl plan — `grep -nE 'destructor walk|walkLiveAndDecref|§4\.7' docs/internal/2026-06-06-umbrella-v0.1.0-impl-plan.md` shows no impl-plan task for §4.7 destructor walk integration. This is a separate scope gap.

### Q5. uint vs uint64 — what does the doc say about portability?

**Source treats this as DWCAS-portability-load-bearing:**
- `queue.nim:122` `const CLOSED_BIT* = 1'u shl (sizeof(uint) * 8 - 1)`
- `queue.nim:127-130`: "The sentinel occupies the high bit of the platform-native `uint` so that `LCRQCell[T]` stays at native double-word width on every target debra supports (16 bytes on 64-bit, 8 bytes on 32-bit). On 64-bit (uint == uint64) the value is identical to `1'u64 shl 63`."
- `queue.nim:137-139`: "Using platform-native `uint` (rather than hardcoded `uint64`) keeps the cell at the platform's native DWCAS width, preserving the lock-free guarantee on every debra-supported target."

**Design says nothing about 32-bit support in v0.1.0.** Greps for "32-bit", "32 bit", "i386" in the canonical design return no scope-defining hits. §6.3 CI matrix (lines around 5316 / 4757) is implicit 64-bit (ubuntu-latest, macos-latest, windows-latest — all amd64/arm64).

**Tension:** if v0.1.0 is implicitly 64-bit-only, the design's `uint64` is harmless (== uint on 64-bit). If 32-bit is in scope (deferred to v0.2.0 strict-LCRQ port? unclear from doc), the design's `uint64` would force `Atomic[Pair[uint64, T]]` to 16 bytes on 32-bit, breaking DWCAS. **Surface to operator: is 32-bit a v0.1.0 target?** If yes, predicate signatures must use platform `uint`. If no, `uint64` is fine for v0.1.0; revisit at v0.2.0 strict-LCRQ port.

Note: since §4.6.2's predicates as written target the **bounded-Vyukov** layer (`MPMCCell.payload.seq: Atomic[uint64]` — see mpmc_cell.nim:25), `uint64` is correct **for that layer**. The bounded Vyukov layer uses `uint64` unconditionally because there's no DWCAS pair-width constraint (the Vyukov seq is separately atomic, not packed into a DWCAS pair). So §4.6.2 `uint64` is RIGHT for the bounded layer, regardless of 32-bit decision. The integration-tree LCRQ layer's `uint` choice is a different (DWCAS-pair-width) concern.

### Q6. Phase 3.4 review artifacts — did they flag this drift?

**Partial flag, wrong remediation.**

- `impl-plan-review-2026-06-06.md:146-161` (HIGH-2): flagged that T-INTEGRATE-PRE-PRED's predicate signatures were not inline in the plan and that an executing agent would have to read §4.6.2 to learn them. The remediation was "inline the signatures verbatim from design §4.6.2 lines 3284-3335" — which is what the plan now does at lines 229-256. This **assumed** the design signatures were correct and source-aligned. The reviewer did NOT verify §4.6.2 signatures against the queue.nim CLOSED_BIT call sites.
- `impl-plan-review-2026-06-06.md:379`: "T-INTEGRATE-PRE-PRED | '5 inline `(seq and CLOSED_BIT) != 0'u` sites in queue.nim' | NOT VERIFIED in this review | Recommend grep before Phase 4."
- `impl-plan-review-2026-06-06.md:400`: priority remediation says "verify the '5 inline CLOSED_BIT sites' claim via grep before Phase 4 per `feedback_verify_subagent_claims_against_source`." This was the right instinct — but neither reviewer verified the **predicate types** against the call-site types.
- `design-review-2026-06-06.md:183, 264`: verified the bounded `MPMCCellArrayN[N, T]` cell-layout claim against `mpmc_cell.nim:49-54` — confirmed PASS. The reviewer recognized `MPMCCell[T]` is the bounded-Vyukov layer. Did NOT cross-check against `LCRQCell` in queue.nim or the §4.6.2 predicate target.

Bottom line: the reviewers caught the "verify CLOSED_BIT site count" sub-question but missed the "verify predicate types match call-site types" sub-question.

---

## 3. Downstream-consumer table

| Task | PG | Cited consumer? | Actual dependency | Risk if §4.6.2 signatures shift |
|------|----|-----------------|-------------------|----------------------------------|
| T-INTEGRATE-PRE-PRED | PG-1 | self-referential (creates the predicates) | queue.nim:1258/1568/1656/1711 close-bit sites | HIGH — task halted exactly here |
| T-PATH-C-DISPATCH | PG-6 | plan L258 asserts dependency | NO direct predicate references; dispatches on `T is ref` / `T is string\|seq` | NONE found |
| T-DRAIN-HELPERS | PG-7 | plan L258 asserts dependency | drain + destroyAndDrain API surface; design §4.8, §5.7 | NONE found (design §5.7 doesn't invoke §4.6.2 predicates) |
| §4.7 destructor walk | **UNASSIGNED** | not in plan task table | calls `seqIsLive` (bounded) and `slotIsCommittedAndUnread` (unbounded MPSC; unbounded MPMC needs different predicate) | HIGH — but no task currently dispatches this; gap |
| T-VERIFY-POP-CLEARS.mpmc-unbounded | PG-1 | references queue.nim:1475 site (which is actually SPMC, not MPMC — separate cite bug) | reads `seg.data[mySlot]` for SPMC; MPMC pop is at queue.nim:1627-1632 via `tryClaim` | NONE (predicate-independent) |

---

## 4. Recommended T-INTEGRATE-PRE-PRED revised signatures

The 5 inline CLOSED_BIT sites in queue.nim operate on `LCRQCell[T] = Atomic[Pair[uint, T]]` and use platform-native `uint`. Two reasonable factoring choices:

### Option 4.a — Two predicate families, layer-segregated

Place predicates in two files matching their layer:

```nim
# Family 1 — bounded Vyukov layer (NEW, design §4.6.2 verbatim):
# src/lockfree/typestates/slot_state.nim

import ./virtual_values_n
import ./mpmc_cell

const ClosedBit* = high(uint64) shr 1  # NOT YET USED — bounded layer has no
                                       # CLOSED_BIT sites today. Provided for
                                       # future bounded-MPMC close-on-empty.

proc seqIsEmpty*(s: uint64; pos: uint64): bool {.inline.} = s == pos
proc seqIsFilled*(s: uint64; pos: uint64): bool {.inline.} = s == pos + 1'u64
proc seqIsClosed*(s: uint64): bool {.inline.} = (s and ClosedBit) != 0'u64
proc seqIsClaimed*(s: uint64; pos: uint64): bool {.inline.} =
  s > pos + 1'u64 and not seqIsClosed(s)
proc seqIsLive*[T](slot: var MPMCCell[T]; pos: uint64): bool {.inline.} =
  let s = slot.payload.seq.load(moRelaxed)
  seqIsFilled(s, pos) and not seqIsClosed(s)

# Family 2 — strict-LCRQ integration layer (NEW, derived from queue.nim
# inline sites, matches actual cell shape):
# src/lockfree/lcrq_predicates.nim   (sibling of queue.nim)

# CLOSED_BIT already defined at queue.nim:122; re-export here OR move
# the const into this new module and import it from queue.nim.

proc lcrqSeqIsClosed*(s: uint): bool {.inline.} =
  ## Replaces the 5 inline (s and CLOSED_BIT) != 0'u sites in queue.nim
  ## at lines 1258, 1568, 1656, 1711 (publish-failure-CLOSED discriminator)
  ## and the symmetric site for the close-on-empty CAS.
  (s and CLOSED_BIT) != 0'u

proc lcrqCellIsClosed*[T](cell: var LCRQCell[T]; order: static MemoryOrder): bool {.inline.} =
  ## Atomic-load-and-test convenience for queue.nim:1258/1568/1656.
  lcrqSeqIsClosed(load(cell, order).first)

# Family 3 — unbounded MPSC committed-flag layer (NEW):
# src/lockfree/segment_predicates.nim   (sibling of queue.nim)

proc slotIsCommittedAndUnread*[T; S: static int](
    seg: var Segment[T, ccMulti, ccSingle, S];
    slot: int;
    consumerHead: int
): bool {.inline.} =
  ## True iff producer published slot AND single consumer hasn't consumed yet.
  ## Unbounded MPSC only — MPMC migrated to LCRQ encoding (use seqIsLive
  ## on the lcrq layer instead).
  slot >= consumerHead and seg.committed[slot].load(moRelaxed)
```

**Note** for unbounded MPMC: there is currently no §4.7 destructor walk path that uses MPMC `cells`. When that path is built, use the lcrq layer's `lcrqCellIsClosed` plus a `seqIsFilled`-style check on the LCRQ seq half. See §6 below.

### Option 4.b — Single uniform layer using platform `uint`

Force the bounded `MPMCCell.payload.seq` to `uint` (currently `uint64`) and unify. Cost: changes mpmc_cell.nim:25, breaks the ABI baseline cited by `tests/t_lcrq_cell_alias.nim` (queue.nim:120), forces a re-audit of all bounded-typestate seq sites. NOT RECOMMENDED for v0.1.0 — too disruptive, and the bounded layer doesn't actually need platform-width DWCAS.

**Recommendation: Option 4.a (layer-segregated families).**

---

## 5. Recommended design §4.6.2 edits

1. **Title clarification**: rename §4.6 from "Slot state predicates" to "Slot state predicates per layer", with three subsections:
   - §4.6.2.A bounded-Vyukov layer (current §4.6.2 content; signatures stay as-is — they are CORRECT for `MPMCCell[T]`)
   - §4.6.2.B strict-LCRQ integration layer (NEW; signatures over `LCRQCell[T]` and platform `uint`)
   - §4.6.2.C unbounded committed-flag layer (NEW; signatures over `Segment[T, ccMulti, ccSingle, S]`, NOT `MPMCSegment[S, T]`)

2. **§4.6.2.A**: Add doc-comment line: "These predicates target the bounded-Vyukov cell layer (`MPMCCellArrayN[N, T]` from `typestates/mpmc_cell.nim`). The bounded layer has **no current CLOSED_BIT call sites** in v0.1.0 — the `seqIsClosed` and `seqIsClaimed` predicates are forward-looking for the eventual bounded-MPMC close-on-empty integration (deferred to v0.2.0+). The destructor walk (§4.7) uses `seqIsLive` only."

3. **§4.6.2.B (NEW)**: Document the 5 inline CLOSED_BIT sites in queue.nim and factor them via `lcrqSeqIsClosed(s: uint)`. Use platform `uint` per queue.nim:122 rationale.

4. **§4.6.2.C (NEW)**: Rename `MPMCSegment[S, T]` → `Segment[T, ccMulti, ccSingle, S]` (the actual integration-tree type). Restrict `slotIsCommittedAndUnread` to the **MPSC** arm — clearly NOT applicable to MPMC (which is LCRQ in the integration tree).

5. **§4.5.1 reconciliation block (NEW or note appended to §4.5.1)**: Acknowledge the integration-tree drift — unbounded MPMC has migrated to strict-LCRQ ahead of design's stated v0.1.0 scope. Either:
   - (a) accept the migration and update §4.5.1 line 3178 + §1 line 5669 + §7.1 line 5316 to reflect MPMC-via-LCRQ in v0.1.0, OR
   - (b) revert queue.nim's MPMC arm to committed-flag for v0.1.0 ship and re-defer LCRQ to v0.2.0.

   This is an operator decision, not a subagent decision. It's a scope reconciliation that affects design + source + tests + docs (§7.1 line 5316 user-facing doc explicitly says "v0.1.0 retains committed-flag form pending strict-LCRQ rework").

6. **§4.7.2 reconciliation**: If 5.(a) chosen, drop `slotIsCommittedAndUnread` from the unbounded-MPMC walk path; use the LCRQ `seqIsLive`-style predicate. If 5.(b) chosen, the design as written is consistent (after the type-name fix in §4.6.2.C).

7. **§4.6.3 location**: drop `unbounded_*_pop.nim` from the call-site list — those files do not exist in the integration tree (the unbounded pops are inlined into `queue.nim`; see impl plan line 392 / 1475). Replace with explicit `queue.nim` line citations.

8. **§4.6.4 refactor scope**: update "parallel sites in unbounded_*_{push,pop}.nim" to "parallel sites inlined in queue.nim" with explicit line numbers, and drop the bqueue.nim clause entirely (no CLOSED_BIT sites there per `grep -c CLOSED_BIT src/lockfree/bqueue.nim` → 0).

---

## 6. Open questions (cannot resolve from doc alone)

1. **MPMC scope decision (§5.5 reconciliation)**: Did the integration tree's MPMC-via-LCRQ migration get explicit operator sign-off, or did it slip in ahead of plan? Design v0.1.0 says committed-flag MPMC; source already has LCRQ MPMC. Operator must decide: (a) lock in LCRQ for v0.1.0 ship and update design + docs, or (b) revert source for v0.1.0 and defer LCRQ to v0.2.0. This is **not in T-INTEGRATE-PRE-PRED's scope**; it's a separate scope-reconciliation question that touches §4.5.1, §1 SCOPE matrix, §7.1 docs, and the v0.1.0 ship surface.

2. **32-bit target scope for v0.1.0**: Does v0.1.0 ship support 32-bit hosts? If yes, `lcrqSeqIsClosed(s: uint)` (platform-width) is mandatory at the integration layer. If no, `uint64` would be acceptable across the board (but Option 4.a still preferred because the bounded-Vyukov layer is `uint64` by `MPMCCellPayload.seq` definition, regardless).

3. **§4.7 destructor walk task assignment**: The §4.6.2 predicates' real consumer is the §4.7 destructor walk, which has **no impl-plan task assignment**. Greps for "walkLiveAndDecref" / "destructor walk" / "§4.7" against the impl plan return no Task lines. Either it's implicitly bundled into T-INTEGRATE.* (which is not stated) or it's a scope gap. Operator should resolve.

4. **Was §4.6.2 written before or after the integration-tree MPMC LCRQ migration?** Git-history archaeology on the design doc + queue.nim would resolve whether the design author knew about the source-ahead-of-design state. Not blocking — the predicates are correctable either way.

---

## 7. Bibliography

| # | Source | Finding |
|---|--------|---------|
| 1 | `/Users/eek/Development/lockfree/docs/internal/2026-06-05-umbrella-v0.1.0-design.md:3351-3402` | §4.6.2 predicate signatures over `uint64`, `MPMCCell[T]`, `MPMCSegment[S, T]` |
| 2 | `/Users/eek/Development/lockfree/docs/internal/2026-06-05-umbrella-v0.1.0-design.md:3170-3201` | §4.5.1 matrix: bounded uses `MPMCCellArrayN`; unbounded MPMC uses `committed: array[S, Atomic[bool]]` |
| 3 | `/Users/eek/Development/lockfree/docs/internal/2026-06-05-umbrella-v0.1.0-design.md:3203-3212` | strict-LCRQ explicitly deferred to v0.2.0 |
| 4 | `/Users/eek/Development/lockfree/docs/internal/2026-06-05-umbrella-v0.1.0-design.md:3494-3511` | §4.7.2 walk calls `slotIsCommittedAndUnread` on `UnboundedMupmucBase[S, ManagedRef[X], MT]` |
| 5 | `/Users/eek/Development/lockfree/docs/internal/2026-06-05-umbrella-v0.1.0-design.md:5316,5669` | "v0.1.0 retains committed-flag form pending strict-LCRQ rework" / "Stays committed-flag in v0.1.0" |
| 6 | `/Users/eek/Development/lockfree/src/lockfree/queue.nim:122-140` | `CLOSED_BIT* = 1'u shl (sizeof(uint) * 8 - 1)`; platform `uint` rationale (DWCAS portability) |
| 7 | `/Users/eek/Development/lockfree/src/lockfree/queue.nim:132` | `type LCRQCell*[T] = Atomic[Pair[uint, T]]` (integration-tree LCRQ cell) |
| 8 | `/Users/eek/Development/lockfree/src/lockfree/queue.nim:300-346` | `Segment[T, ccProd, ccCons, S]` with `cells` on MPMC (L325) and `committed` on MPSC only (L343) |
| 9 | `/Users/eek/Development/lockfree/src/lockfree/queue.nim:1249-1300, 1568, 1656, 1711` | 5 CLOSED_BIT inline call sites in queue.nim |
| 10 | `/Users/eek/Development/lockfree/src/lockfree/queue.nim:1616-1632` | MPMC fast-path uses `tryClaim[T](seg.cells[mySlot], 0'u)` — strict-LCRQ already live |
| 11 | `/Users/eek/Development/lockfree/src/lockfree/bqueue.nim` | zero CLOSED_BIT occurrences (grep) |
| 12 | `/Users/eek/Development/lockfree/src/lockfree/typestates/mpmc_cell.nim:19-55` | `MPMCCell[T].payload.seq: Atomic[uint64]`; bounded-Vyukov layer |
| 13 | `/Users/eek/Development/lockfreequeues/src/lockfree/typestates/unbounded_mpmc_push.nim:12-17` | v5.0.0 source `MPMCSegment[S, T]` with `committed: array[S, Atomic[bool]]` (NOT in integration tree) |
| 14 | `/Users/eek/Development/lockfree/docs/internal/2026-06-06-umbrella-v0.1.0-impl-plan.md:225-278` | T-INTEGRATE-PRE-PRED task spec with inlined predicate signatures |
| 15 | `/Users/eek/Development/lockfree/docs/internal/2026-06-06-umbrella-v0.1.0-impl-plan.md:708-752` | T-PATH-C-DISPATCH (PG-6) and T-DRAIN-HELPERS (PG-7) — no §4.6.2 predicate references |
| 16 | `/Users/eek/Development/lockfree/docs/internal/impl-plan-review-2026-06-06.md:146-161, 379, 400` | HIGH-2 inlined signatures; flagged grep verification but missed type-match verification |
| 17 | `/Users/eek/Development/lockfree/docs/internal/design-review-2026-06-06.md:183, 264` | bounded `MPMCCellArrayN` PASS; LCRQ layer not cross-checked |

---

**Methodological note (per `feedback_verify_subagent_claims_against_source`):** every claim above carries file:line evidence read directly via Read/grep in this session. No reliance on prior subagent summaries.
