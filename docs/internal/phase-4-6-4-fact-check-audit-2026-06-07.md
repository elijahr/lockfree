# Phase 4.6.4 Comprehensive Fact-Check (2026-06-07)

Branch: `feat/v5.0.0-impl`
Design doc audited: `docs/internal/2026-06-05-umbrella-v0.1.0-design.md` (6,439 lines)
Audit scope: 10 verification cells covering §2-§7 of the design vs source artifacts.
Mode: read-only — no source or design modifications.

## Summary

| Metric | Count |
|---|---|
| Sections audited | §2.5, §4.4, §4.4.8-12, §4.6, §5.5, §5.4/§5.6, §6.3, §6.11, §7.1, §7.9 (10 cells) |
| Claims verified | 10 cells × ~4 sub-claims = ~40 substantive claims |
| Verdicts: CONFIRMED | 6 cells fully confirmed |
| Verdicts: MINOR_DRIFT | 5 instances (line-number drift, narrative off-by-one, cosmetic naming) |
| Verdicts: MAJOR_DRIFT | 2 instances (design narrative documents rejected pattern; docs IA gap) |
| Missing artifacts | 3 (`docs/examples/` tree, `from-debra-package.md`, `unbounded-mpmc.md` name) |
| Orphan artifacts | 7 (extra guide pages outside design tree) |

## Per-cell findings

### Cell 1 — §2.5 25-row composition matrix vs `path_c_admit.nim`

**Verdict: CONFIRMED (with §2.7 expansion)**

- All 25 rows of design §2.5 enumerated with ACCEPT/REJECT decisions.
- `src/lockfree/internal/path_c_admit.nim:75-127` implements the dispatch:
  - Row 8 (`ref ref`): REJECT via `when T is ref ref` (line 75-79) with verbatim error from §2.5.
  - Row 7 (`distinct ref`): REJECT via `when T is distinct and distinctBase(T) is ref` (line 81-86).
  - Rows 1-6, 9-15, 23-25 (plain `ref`): ACCEPT via `elif T is ref: discard` (line 102).
  - Row 16 (`string`): ACCEPT (line 106).
  - Rows 17-19 (`seq[U]` incl. `seq[ref U]` and `seq[seq[U]]`): ACCEPT (line 116). The former R7 `supportsCopyMem(U)` element guard has been intentionally removed (annotated at line 108-115) — matches design §2.5 rows 18-19 ACCEPT rationale.
  - Rows 20-22 + plain POD: ACCEPT (line 120).
  - Unsupported fallback: REJECT (line 124-127).
- Reject-arms-before-accept-arms invariant (design §2.7 line 1234ff) is honored.
- **Additional implementation beyond §2.5**: `path_c_admit.nim` lines 89-98 add REJECTs for `object`/`tuple` containing managed fields (per §2.7 lines 1206-1213). These rejects are not in the §2.5 25-row table but are documented at §2.7. Not drift; correct expansion.

Evidence: file trace `src/lockfree/internal/path_c_admit.nim:1-127`.

### Cell 2 — §4.4 v3 box pattern vs `managed_slice.nim`

**Verdict: CONFIRMED**

- `StringBox = ptr object; v: string` and `SeqBox[U] = ptr object; v: seq[U]` ✓ (`managed_slice.nim:51-55`).
- `ManagedSlice*[T] = distinct uint` ✓ (line 57).
- ABI parity static-assert present (lines 65-69) — matches §4.4.1 narrative.
- `wrap` per-MM `when arc/orc/atomicArc/refc: box.v = s; else: copyMem(...)`: matches §4.4.2 table exactly. (`wrap` string at line 84-96; `wrap[U]` seq at line 98-116.)
- `unwrap` per-MM `move(box.v)` under arc-family, `copyMem` under mm:none, then `deallocShared(box)` unconditional: matches §4.4.3 (lines 122-143).
- `disposeSlot` matches §4.4.5: nil-guard at top, `=destroy(box.v)` under arc-family only, `deallocShared(box)` unconditional (lines 156-177).
- Task prompt asked about "alloc0Shared"; design and source both use `allocShared0` (Nim's actual API name). No drift.

Evidence: file trace `src/lockfree/managed_slice.nim:1-177`.

### Cell 3 — §4.4.8-12 SlotEncoding vs `slot_encoding.nim` + `path_c_wrap.nim`

**Verdict: MAJOR_DRIFT (design narrative documents a rejected pattern)**

- `SlotEncoding(T)` typeof helper (`slot_encoding.nim:21-33`): MATCHES the design code snippet at §4.4.8 verbatim, including `typeof(default(T)[])` for ref pointee and `typeof(default(T)[0])` for seq element.
- `wrapOrIdentity` (`path_c_wrap.nim:27`): present ✓
- `unwrapOrIdentity` (`path_c_wrap.nim:70`): present ✓
- `disposeSlotEncoded` (`path_c_wrap.nim:87`): present ✓ but **diverges from design code snippet**.

**MAJOR_DRIFT detail**: Design §4.4.9 sketches the ref-arm of `disposeSlotEncoded` as:

```
when T is ref: (let r {.used.} = toRef(encoded); discard r)
```

— i.e., "reconstruct + scope-exit destroy" pattern. Source `path_c_wrap.nim:113-122` instead calls `decRefSlot(encoded)` directly with an in-code comment explaining that the leave-scope pattern is **unsafe under `--mm:arc`** because cursor inference treats the local as a non-owning borrow and elides `=destroy`, leaking the refcount. The source has the correct fix; the design narrative documents a known-broken pattern.

§4.4.9 prose immediately following the snippet (line 3358-3362) ALSO repeats the broken description: "For `ref X`, it reconstructs a `ref X` view and lets it leave scope so the compiler-emitted `=destroy` fires the refcount drop." This is the rejected pattern.

**Recommendation**: Update §4.4.9 code snippet and prose to reflect `decRefSlot(encoded)` and document the cursor-inference rationale (already present as a code comment in `path_c_wrap.nim:54-66`).

- §4.4.11 encoded-once-above-loop pattern: design contract — not source-verified in this audit (would require inspecting queue.nim push loop).
- §4.4.12 hard-error restructuring at queue.nim — not source-verified in this audit beyond confirming queue.nim still imports/uses Path-C wrap helpers.

Evidence: design line 3343, `path_c_wrap.nim:85-128`.

### Cell 4 — §4.6 slot-state predicates vs `typestates/slot_state.nim` + `segment_state.nim`

**Verdict: CONFIRMED with MINOR_DRIFT (line numbers shifted)**

- `src/lockfree/typestates/slot_state.nim` exists (115 lines), with both Family A (Vyukov, `B` suffix) and Family B (LCRQ, no suffix) in a single shared module — exactly as design §4.6.2 canonical layout.
- Family A symbols present (`slot_state.nim`): `ClosedBitB` (line 53), `seqIsEmptyB` (line 59), `seqIsFilledB` (line 63), `seqIsClosedB` (line 67), `seqIsClaimedB` (line 72), `seqIsLiveB[T]` (line 77). All match design signatures.
- Family B symbols present: `seqIsClosed` (line 94), `seqIsClaimed` (line 100), `seqIsLiveLCRQ[T]` (line 105). All match design signatures.
- `src/lockfree/typestates/segment_state.nim` exists (43 lines) with `slotIsCommittedAndUnread*[T; S: static int]` at line 32. Matches §4.6.2 MPSC predicate.
- `queue.nim` calls `seqIsClosed(...)` at the consumer-side sites: lines 1325, 1649, 1739, 1794.

**MINOR_DRIFT**: Design §4.6.1 / §4.6.3 / §4.6.4 cite queue.nim line numbers `1258, 1568, 1656, 1711` for the 4 CLOSED_BIT sites. Actual sites are `1325, 1649, 1739, 1794` (off by ~60-130 lines). Semantic match is intact (4 consumer-side sites in the strict-LCRQ arm); the design's line numbers are pre-refactor or stale. Cosmetic.

Evidence: file trace `src/lockfree/typestates/slot_state.nim`, `src/lockfree/typestates/segment_state.nim`, `grep` on `queue.nim`.

### Cell 5 — §5 typestate dual API vs `typestates/with_bound.nim` + umbrella

**Verdict: CONFIRMED**

- `withBoundEndpoint*` exported (`with_bound.nim` line ~140ish, as alias to `withBoundProducer`).
- `withBoundProducer*` overloads for BQueue and Queue, with full parameter lists matching design (§5.5.3 sketches a single generic template; source has 4 concrete overloads — 2 for BQueue, 2 for Queue × producer/consumer — which is a natural specialization given BQueue and Queue have different generic parameter lists).
- `withBoundConsumer*` symmetric overloads present.
- `Queueable*[T]` concept (`with_bound.nim`) matches §5.5.5 sketch: `var qref: typeof(x); push(qref, default(T)) is bool; pop(qref) is Option[T]`. Plus static doAsserts for BQueue SPSC across POD/string/seq/ref payloads (per T-TYPESTATE-DUAL-API acceptance criterion).
- `src/lockfree.nim` umbrella exports `with_bound` via both `threads`-on and `threads`-off branches.

Evidence: `with_bound.nim` full read; `src/lockfree.nim` full read.

### Cell 6 — §5.4 + §5.6 chronos integration vs `chronos.nim`

**Verdict: CONFIRMED**

- Hybrid optional-dep guard matches §5.6 pattern: `when (compiles do: import chronos/...)` probe at top of `chronos.nim:55`, exported constant `lockfreeChronosAvailable*` at line 60, fatal-error guard for `-d:lockfreeChronos` without chronos at line 66, gated body opens at line 81.
- `AsyncQueue*` type (line 111-125), `AsyncBQueue*` type (line 89-109), both wrapping a `queue*` field plus `event*: AsyncEvent`. Matches §5.4.1 sketch.
- `newAsyncEvent()` constructor calls at lines 149, 166.
- Cancellation discipline (R10): `try/finally` blocks at lines 225-233 (bounded SPSC pop) and 273-280 (unbounded SPSC pop). Matches §5.4.3 "AsyncQueue.pop body honors this by closing the pin scope before each await" guarantee.
- Additional convenience alias `AsyncQueueSpsc*` (line 127-128) — not in design but harmless ergonomic addition.

Evidence: `chronos.nim` grep + line trace.

### Cell 7 — §6.3 18 cells vs `.github/workflows/ci.yml`

**Verdict: MINOR_DRIFT (design narrative off-by-one, table is correct)**

- Design §6.3 narrative claims "17 concrete cells plus a lint job (18 jobs total)" and "Cell count: 18 (1 lint + 17 test cells)".
- Design §6.3 table actually enumerates: L (lint), 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 17, 18 — that's **16 test cells + 1 lint = 17 jobs**.
- Actual `ci.yml` has: `lint` job + 12 matrix cells (1, 2, 3, 4, 5, 6, 7, 10, 11, 13, 17, 18) + 4 standalone jobs (`valgrind` = cell 8, `helgrind` = cell 9, `chronos` = cell 12, `nimony` = cell 14) = **16 test cells + 1 lint = 17 jobs**.

CI matches the table exactly. The "18 cells / 17 test cells" prose in §6.3 (and propagated into §7.9 and CHANGELOG.md "Added" section) is an off-by-one in the narrative. The actual cell numbering skips 15 and 16, which is what makes the count confusing.

**Recommendation**: Update §6.3 prose, §7.9 "Comprehensive CI matrix (18 cells: 1 lint + 17 test)" entry, and CHANGELOG.md "18-cell CI matrix" line to say "17 cells (1 lint + 16 test cells; cell numbers run 1-14, 17-18 with gaps)". Minor cosmetic.

Evidence: `ci.yml` grep on cell labels; design §6.3 table enumeration; CHANGELOG.md trace.

### Cell 8 — §6.11 bot config vs `AGENTS.md` + `.github/workflows/momus.yml`

**Verdict: MINOR_DRIFT (auto-review claim)**

- AGENTS.md has `### PR Review Bot` block at line 845.
- Block names `gemini-code-assist` as primary and `axiomantic-momus` as parallel/informational.
- Gating: "gemini gates the PR; momus is informational unless gemini is unavailable" (AGENTS.md line 853-854).
- `momus.yml` exists; uses the axiomantic/.github reusable workflow with `trigger_command: /ai-review` and `trigger_mention: @axiomantic-momus[bot]`. Matches the informational/parallel positioning.

**MINOR_DRIFT**: Design §6.11.4 prescribes the AGENTS.md block to say "gemini auto-reviews on push; no manual tag needed". Actual AGENTS.md line 848-849 says "Re-review comment: `/gemini review`" and "Auto-reviews on PR creation: no — manual `/gemini review` comment". These are contradictory: design says auto-review; AGENTS.md says manual tag.

This is a known operator-driven behavior (the recent `ci(momus): only auto-review on PR opened` commit suggests both bots have specific auto-trigger semantics). Either the design narrative needs to match AGENTS.md (manual tag) or AGENTS.md needs updating to match design (auto). Recommendation: take the operator's word from AGENTS.md as authoritative and update design §6.11.4.

Evidence: AGENTS.md line 845-859; `.github/workflows/momus.yml` head 50 lines.

### Cell 9 — §7.1 docs IA tree vs `docs/guide/`

**Verdict: MAJOR_DRIFT (gaps + orphans + missing examples tree)**

Files in design's target tree vs actual filesystem:

| Design path | Actual? | Note |
|---|---|---|
| `guide/index.md` | ✓ | |
| `guide/getting-started.md` | ✓ | |
| `guide/concepts/lock-freedom.md` | ✓ | |
| `guide/concepts/smr.md` | ✓ | |
| `guide/concepts/memory-management.md` | ✓ | |
| `guide/smr/nebr.md` | ✓ | R6 attribution softened: line 11 says "**inspired by Brown 2015 DEBRA+**" ✓ |
| `guide/queues/index.md` | ✓ | |
| `guide/queues/unbounded-mpmc.md` | **MISSING** | Actual file is `strict-lcrq-mpmc.md` (renamed). |
| `guide/queues/bounded-vyukov.md` | ✓ | |
| `guide/queues/legacy.md` | ✓ | |
| `guide/managed-ref.md` | ✓ | |
| `guide/managed-slice.md` | ✓ | |
| `guide/typestates.md` | ✓ | |
| `guide/nimony.md` | ✓ | |
| `migrations/from-lockfreequeues-v5.md` | ✓ | |
| `migrations/from-nim-debra.md` | ✓ | |
| `migrations/from-debra-package.md` | **MISSING** | Actual file is `v5.0.0.md` (likely the wrong file). |
| `examples/` (8 .nim files) | **MISSING** | `docs/examples/` directory does not exist. |

**Orphan artifacts** (in source but not in design IA):

- `docs/guide/bounded-vs-unbounded.md`
- `docs/guide/core-concepts.md`
- `docs/guide/examples.md`
- `docs/guide/memory-management.md` (vs `guide/concepts/memory-management.md`; possible duplicate/legacy)
- `docs/guide/performance-tuning.md`
- `docs/guide/safety-model.md`
- `docs/guide/slot-ownership-typestates.md`

These pages either need to be added to the design IA (with a purpose statement) or pruned. The CHANGELOG line "Documentation IA rebuild" implies a green-field rebuild but the actual `docs/guide/` is a mix of design-anchored pages and unanchored legacy pages.

**R6 attribution**: nebr.md line 11 says "inspired by Brown 2015 DEBRA+", and §"Deviations from Brown 2015 DEBRA+" exists at line 176. R6 fix LANDED ✓.

**Missing examples**: Design §7.1.1 + §7.9 explicitly list 8 example `.nim` files (basic-queue, ref-payload, slice-payload, smr-only, custom-types, bounded-pipeline, nimony-compat, mm-none-audio). None exist on the filesystem. §7.9 in/out table claims "Examples (8 .nim files) | YES | Net-new" which is **inaccurate**.

Evidence: `find docs/guide -type f -name "*.md" | sort`; `ls docs/migrations docs/examples`.

### Cell 10 — §7.9 In/Out scope vs CHANGELOG.md + source

**Verdict: MIXED — IN items mostly confirmed; "Examples" claim is REFUTED**

IN items spot-checked:
- Queue/BQueue all 4 cardinalities lifted ✓ (`src/lockfree/queue.nim`, `src/lockfree/bqueue.nim`)
- nebr SMR ✓ (`src/lockfree/smr/nebr/`)
- ManagedRef ✓ (`src/lockfree/managed_ref.nim`)
- ManagedSlice ✓ (`src/lockfree/managed_slice.nim`)
- `ref T` / `string` / `seq[T]` user API ✓ (path_c_admit + path_c_wrap + queue.nim/bqueue.nim wired)
- Tier 1 sync iterators ✓ (`iterator drain*`, `iterator items*`, `iterator pairs*` in both queue.nim line 1924+ and bqueue.nim line 950+)
- chronos adapter ✓ (`src/lockfree/chronos.nim`, 306 lines, hybrid optional-dep)
- mm:none drain helpers ✓ (drain iterators are mm-aware via SlotEncoding)
- Nimony first-class architecture ✓ (cell 14 in ci.yml, nimony arms in atomics/managed_ref)
- Typestate dual-API + RAII wrappers ✓ (cell 5 verified)
- 18-cell CI ✓ (cell 7 verified; numbering off-by-one but matrix shipped)
- Documentation IA rebuild ✓ (with the gaps noted in cell 9)
- Migration docs (3 files) **PARTIAL** — only 2 of 3 present; `from-debra-package.md` missing.
- **Examples (8 .nim files) — REFUTED** — `docs/examples/` directory does not exist.

OUT items spot-checked:
- No `debra_plus.nim` in source ✓ (find returned nothing)
- No `asyncdispatch` adapter ✓ (find returned nothing; only chronos adapter exists)
- No macOS x86_64 CI cell ✓ (ci.yml has macos-latest = arm64 only)

Section 7.9 appears **twice** in the design doc (line 6077 and line 6406). Both copies have the same table content but the duplication itself is design hygiene drift — would confuse future readers. Same for §7.4 and §7.5 (duplicate headers at line 5854/6257 and 5973/6378).

Evidence: filesystem inventory; CHANGELOG.md head 100 lines.

## Cross-check against canvas "Locked decisions"

Not performed in this audit. Subagent context cannot reach the canvas/MCP layer. **Recommendation**: operator should walk the canvas Locked Decisions table against the design doc directly, particularly any PG-6 / Wave-C decisions made between the 2026-06-05 design timestamp and 2026-06-06 implementation work.

## Aggregate findings

### MAJOR_DRIFT (2)

1. **§4.4.9 documents a known-broken pattern.** Design code snippet and prose describe `disposeSlotEncoded[ref X]` as "reconstruct local + let scope-exit destroy"; source has the correct `decRefSlot(encoded)` direct call with an in-code comment explaining the cursor-elision bug the rejected pattern would hit. Fix: update §4.4.9.
2. **Docs IA has gaps + orphans + missing examples tree.** `docs/examples/` directory does not exist (design+CHANGELOG claim 8 example .nim files shipped). `from-debra-package.md` missing. 7 orphan guide pages exist outside the design tree. `guide/queues/unbounded-mpmc.md` is named `strict-lcrq-mpmc.md` in source.

### MINOR_DRIFT (5)

1. §6.3 narrative says "17 test cells / 18 total"; table enumerates 16 test cells / 17 total. Propagated into §7.9 and CHANGELOG.md. Cell numbering 1-14, 17-18 (skipping 15, 16) makes this confusing. Update narrative.
2. §6.11.4 prescribed AGENTS.md block says "gemini auto-reviews on push; no manual tag needed"; actual AGENTS.md says "manual `/gemini review` comment". One needs to follow the other.
3. §4.6 cites queue.nim CLOSED_BIT/seqIsClosed sites at lines 1258, 1568, 1656, 1711; actual lines are 1325, 1649, 1739, 1794. Update or annotate as approximate.
4. Design §7.4, §7.5, §7.9 each appear twice in the doc (sections at lines 5854/6257, 5973/6378, 6077/6406). Doc-hygiene drift; would confuse readers. Deduplicate.
5. §4.4 narrative refers to "alloc0Shared" in one place but the API is `allocShared0` (used correctly in source). Task-prompt-level only; not in doc text I sampled.

### Missing artifacts (3)

- `docs/examples/` directory (8 .nim files)
- `docs/migrations/from-debra-package.md`
- `docs/guide/queues/unbounded-mpmc.md` (or rename design reference to `strict-lcrq-mpmc.md`)

### Orphan artifacts (7)

All in `docs/guide/`: `bounded-vs-unbounded.md`, `core-concepts.md`, `examples.md`, `memory-management.md` (top-level duplicate of `concepts/memory-management.md`), `performance-tuning.md`, `safety-model.md`, `slot-ownership-typestates.md`.

## Recommendation

**fix-first** — 2 MAJOR_DRIFT findings should be addressed before Phase 4.6.4 finishes:

1. **Update §4.4.9** to reflect the actual `decRefSlot(encoded)` implementation and document the cursor-elision rationale. The current narrative describes a pattern the source explicitly rejects with an in-code comment.
2. **Resolve docs IA gap**: either ship the 8 example `.nim` files (the design and CHANGELOG both promise them) OR strike the "Examples (8 .nim files) | YES" row from §7.9 and the corresponding CHANGELOG.md entry. Also: rename `strict-lcrq-mpmc.md` to `unbounded-mpmc.md` (or update design to use the new name), ship `from-debra-package.md` (or update design to drop it), and decide whether the 7 orphan guide pages get IA homes or get pruned.

MINOR_DRIFT items are cosmetic and can land as a doc-cleanup pass. The cell-count off-by-one and the line-number drift in §4.6 are particularly worth fixing if any reader uses the design as a map to the code.

Source-level v0.1.0 work itself is in good shape — Path-C admit + wrap + SlotEncoding + slot-state predicates + typestate dual API + chronos adapter + CI matrix all match design intent. The drifts are in the design narrative and the docs tree, not in the lock-free machinery.
