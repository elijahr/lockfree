# Phase 3.2 Impl Plan Review Report

**Date**: 2026-06-06
**Plan**: `/Users/eek/Development/lockfree/docs/internal/2026-06-06-umbrella-v0.1.0-impl-plan.md` (1238 lines)
**Design doc**: `/Users/eek/Development/lockfree/docs/internal/2026-06-05-umbrella-v0.1.0-design.md` (5874 lines)
**Reviewer**: reviewing-impl-plans skill (Claude Opus 4.7)
**Verdict**: **NEEDS_WORK** — 3 CRITICAL, 5 HIGH, 6 MEDIUM, 4 LOW findings.

The plan is well-structured and covers the locked design decisions at the right altitude. It is **not** ready for Phase 4 dispatch as-is because (a) every per-arm pop-clears task cites file paths and/or line numbers that do not exist in the working tree, (b) the underlying defect premise ("payload not cleared") appears to be contradicted by `move()` already being present at the cited sites, and (c) one interface contract that parallel agents need (managed_ref ↔ nimony-arms ↔ managed_slice co-edit on the same files) is left to the orchestrator to "serialize OR coordinate via a merge dispatch" without a written protocol.

The fix scope is bounded: re-anchor the 8 pop-clears tasks to verified file paths/line numbers, escalate the "is the slot actually leaked under `move()`?" question to fact-checking before Phase 4 begins, and write a 1-paragraph PG-5 race protocol. None of the design intent needs to change.

---

## Summary

- Parent design doc: **EXISTS** (5874 lines, in same internal/ directory)
- Work items: **47 tasks** total across 12 parallel groups
  - Parallel: 45 (within PG sets)
  - Sequential (solo): 2 (T-INTEGRATE-RENAME, T-INTEGRATE.f gate)
- Interfaces between parallel tracks: **9 identified**, **6 fully specified**, **3 MISSING or under-specified**
- Behavior verifications spot-checked: **7 cited**, **2 VERIFIED in source**, **5 UNVERIFIABLE or CONTRADICTED**
- Claims escalated to fact-checking: **3**
- Dependency graph: **VALID** (acyclic; PG ordering respects deps)
- Acceptance-criteria assessment: **40 of 47 PASS** (concrete + testable); **7 vague or untestable**

### Severity counts

| Severity | Count |
|----------|-------|
| CRITICAL | 3 |
| HIGH     | 5 |
| MEDIUM   | 6 |
| LOW      | 4 |
| **Total** | **18** |

---

## Critical Findings (block Phase 4)

### CRITICAL-1 — All 8 T-INTEGRATE-POP.* tasks cite paths that do not exist

**Location**: Plan lines 192-329 (all 8 `T-INTEGRATE-POP.*` tasks)
**Category**: Behavior Verification / Path coherence

**Current state**: Every pop-clears task names files under `src/lockfree/internal/`:
- `src/lockfree/internal/spsc_pop.nim:72`
- `src/lockfree/internal/mpsc_pop.nim:116-117`
- `src/lockfree/internal/spmc_pop.nim:98-99`
- `src/lockfree/internal/mpmc_pop.nim:99-100`
- `src/lockfree/internal/unbounded_spsc_pop.nim:120`
- `src/lockfree/internal/unbounded_mpsc_pop.nim:169`
- `src/lockfree/internal/unbounded_spmc_pop.nim:189`
- `src/lockfree/internal/unbounded_mpmc_pop.nim:216`

**Problem**: Spot-check against actual tree (`find /Users/eek/Development/lockfree/src/lockfree -name '*.nim'`):
- `src/lockfree/internal/` contains ONLY 4 files: `aligned_alloc.nim`, `pinscope_stub.nim`, `shared.nim`, `typestates_dsl.nim`. **None** of the cited `*_pop.nim` files live there.
- Bounded pop logic lives at `src/lockfree/typestates/{spsc,mpsc,spmc,mpmc}_pop.nim` (different directory).
- Unbounded pop logic does **not** have separate files at all — it is inlined in `src/lockfree/queue.nim` (verified via `grep -n "proc pop" src/lockfree/queue.nim` → lines 848, 898, 920, 936, 1328, 1401, 1425, 1484, 1794; verified via `grep "move(seg.data" queue.nim` → lines 874, 1360, 1380, 1475).

**What agent would guess**: Three plausible guesses, all different:
1. "Path typo — replace `internal/` with `typestates/`" (works for bounded; fails for unbounded).
2. "Create the missing files" (would unexpectedly split queue.nim and break everything else).
3. "Find the moral-equivalent site and patch it" (each subagent picks a different line; 8 incompatible patches land).

**Required**: For each of the 8 sub-tasks, replace the cited path/line with the verified path/line in `src/lockfree/` working tree as of 2026-06-06. Bounded arms point at `src/lockfree/typestates/{spsc,mpsc,spmc,mpmc}_pop.nim`. Unbounded arms point at the specific `move(seg.data[...])` sites in `src/lockfree/queue.nim` (lines 874, 1360, 1380, 1475, plus the strict-LCRQ pre-rework site near 1622 — to be re-verified by the fix author).

**Risk if not fixed**: Each of the 8 PG-1 dispatches fails on first probe (file not found), forcing the orchestrator into ad-hoc re-routing. Worst case: a subagent invents file paths to match the plan, producing skeleton files that compile but route around the actual pop logic — silent green-mirage.

---

### CRITICAL-2 — Pop-clears defect premise contradicted by source

**Location**: Plan lines 194 ("payload is currently leaked across pop boundary in all 8 cardinality arms"), 192-329 (all `T-INTEGRATE-POP.*`); inherited from design §4.5.2 lines 3193-3206
**Category**: Behavior Verification (fabrication anti-pattern)

**Current state**: The plan asserts the defect: "payload is currently leaked across pop boundary in all 8 cardinality arms" (line 194). The design doc §4.5.2 (table at line 3193) claims every arm reads `let value = queue.storage[op.slot]` and "**No clear. Slot retains the bits of the popped value.**"

**Problem**: Actual source contradicts this for every site I spot-checked:
- `src/lockfree/typestates/spsc_pop.nim:72`: `let value = move(queue.storage[op.slot])` — `move()`, not plain read.
- `src/lockfree/typestates/mpsc_pop.nim:116`: `let value = move(queue.cells.dataPtr(op.slot)[])` — `move()`, not plain read.
- `src/lockfree/typestates/spmc_pop.nim`: same `move()` pattern (lines 95-103).
- `src/lockfree/typestates/mpmc_pop.nim`: same `move()` pattern (lines 95-105).
- `src/lockfree/queue.nim:874, 1360, 1380, 1475`: all use `move(seg.data[...])`.

`move()` in Nim is a destructive read: it transfers ownership and leaves a moved-from value in the source. For POD T, the slot is bit-aliased to the value, so `move()` is observationally equivalent to a plain read (no zero-write). For `ref`/`string`/`seq` T, `move()` runs `=sink` which IS expected to leave the source in the moved-from sentinel (typically zeroed) — this is the language guarantee `bqueue.nim:997`'s own comment relies on ("after a pop returns the slot to default state").

**What agent would guess**: A subagent told to "insert `.reset()` after the read" will either:
1. Insert `.reset()` after a `move()` that already cleared the slot — a no-op that wastes an instruction, OR
2. Notice the contradiction, stop, AskUserQuestion, and stall the entire PG-1 group, OR
3. Reinterpret the task ("the read is via `move`, maybe `move` is insufficient on `distinct uint`"?), invent a justification, and ship code based on a fabricated rationale.

**Required**: Before Phase 4 dispatch, route this through `fact-checking` skill with the specific question: "Under arc/orc/atomicArc/refc and mm:none, does `move(slot[i])` where `slot[i]: T` already produce a destructor-walk-safe slot state for T in {POD, ref X, string, seq[U], ManagedRef[X], ManagedSlice[T]}? Cite Nim manual + emitted C/IR + the moved-from sentinel for each T." Then update the plan's task descriptions to reflect the actual gap (likely narrower than 8 sites — perhaps only the future `ManagedRef`/`ManagedSlice` slot type, which doesn't exist in the tree yet).

If fact-check confirms a real gap, the task scope likely narrows to "post-T-MANAGED-REF / post-T-MANAGED-SLICE: ensure the shim-wrapper pop site calls `decRefSlot` and zeroes the bits" — a different task family living downstream of PG-5, NOT in PG-1.

**Risk if not fixed**: The plan's premise drives 9 PG-1 tasks (`T-INTEGRATE-PRE-PRED` + 8 `T-INTEGRATE-POP.*`). If the premise is wrong, ~10% of plan effort is mis-targeted. Worse, parallel agents may insert `.reset()` on `move`-already-cleared slots, then write tests that pass for the wrong reason (the slot was zero before the insertion too) — green-mirage by construction, per `auditing-green-mirage` failure mode.

---

### CRITICAL-3 — PG-5 race protocol missing for managed_ref/slice ↔ nimony-arms

**Location**: Plan line 543 (T-NIMONY-ARMS dependency note): "parallel with T-MANAGED-REF + T-MANAGED-SLICE (race on managed_*.nim files — **orchestrator must serialize OR coordinate via a merge dispatch**)"
**Category**: Interface Contract (parallel work coordination)

**Current state**: The plan acknowledges the race but defers the resolution to the orchestrator without specifying which path or what the merge-dispatch protocol looks like. PG-5 has 3 tasks (T-MANAGED-REF, T-MANAGED-SLICE, T-NIMONY-ARMS), all of which co-edit `src/lockfree/managed_ref.nim` and `src/lockfree/managed_slice.nim`.

**Problem**: This is the canonical parallel-incompatibility failure mode. Two scenarios produce different valid code:
1. **Serialize** (T-MANAGED-REF → T-MANAGED-SLICE → T-NIMONY-ARMS): T-NIMONY-ARMS edits files that already have the arc/orc/atomicArc/refc/none arms in place. The nimony arm is appended; merge is clean.
2. **Parallel + merge**: T-MANAGED-REF and T-NIMONY-ARMS produce two diverging files. The merge dispatch must reconcile — but **the plan doesn't define what the merge dispatch reads, what conflicts look like, or who runs it**.

The orchestrator has no contract that says "in case of merge-dispatch path, T-MANAGED-REF MUST stub the `when defined(nimony):` branch with `{.error: "filled by T-NIMONY-ARMS".}` so T-NIMONY-ARMS knows exactly where its content lands."

**Required**: Add a paragraph to T-NIMONY-ARMS specifying ONE of:
1. **Hard serialize**: Move T-NIMONY-ARMS to PG-5b (after T-MANAGED-REF + T-MANAGED-SLICE complete). Each of MANAGED-REF and MANAGED-SLICE MUST emit a stub `when defined(nimony): {.error: "filled by T-NIMONY-ARMS".}` arm at the documented location. T-NIMONY-ARMS replaces those stubs.
2. **Worktree merge protocol**: T-NIMONY-ARMS produces a unified-diff against the post-PG-4 baseline; T-MANAGED-REF and T-MANAGED-SLICE produce unified-diffs likewise; a merge dispatch applies them in order, expecting only `when defined(nimony):` blocks to conflict, with the nimony block winning.

Both are valid; the plan must pick one and write it down. Without it, two parallel agents on T-MANAGED-REF and T-NIMONY-ARMS can both delete each other's edits with no conflict detection (Nim's `when` blocks at different defined-set values can silently overwrite if both touch the same module).

**Risk if not fixed**: Silent loss of nimony arms after T-MANAGED-REF completes second, or silent loss of arc/orc arms if T-NIMONY-ARMS does a full-file rewrite. Tests under the CI matrix would catch a complete loss, but a partial loss (one of 4 arms missing) might only fail in 1-2 of 16 CI cells and look like an unrelated flake.

---

## Important Findings (should fix)

### HIGH-1 — T-INTEGRATE.b ↔ T-INTEGRATE.c dependency edge is wrong direction

**Location**: Plan line 342 (T-INTEGRATE.b deps: "T-INTEGRATE.a"); line 368 (T-INTEGRATE.c deps: "PG-2 complete"); table at line 81-82
**Category**: Dependencies

**Current state**: PG-2 = {T-INTEGRATE.b, T-INTEGRATE.e}. PG-3 = {T-INTEGRATE.c, T-INTEGRATE.d}.

**Problem**: T-INTEGRATE.b lifts the nebr tree containing files that `import debra/...`. After T-INTEGRATE.b runs but BEFORE T-INTEGRATE.c rewrites imports, the lifted files reference `debra/atomics` paths — which no longer resolve because T-INTEGRATE.a has lifted atomics to `src/lockfree/atomics/`. T-INTEGRATE.b's acceptance criterion (line 348: "`nim check src/lockfree/smr/nebr.nim` compiles standalone (with `--path:src/lockfree`)") will FAIL because the lifted nebr files still say `import debra/atomics`.

Either:
- T-INTEGRATE.b must also do a minimal import rewrite (contradicting the "lifted source is unmodified except paths" claim on line 350), OR
- The `nim check` acceptance must be deferred to after T-INTEGRATE.c, OR
- T-INTEGRATE.c must be in PG-2 alongside T-INTEGRATE.b (not PG-3).

**Required**: Resolve by either (a) folding the import rewrite into T-INTEGRATE.b's deliverable and removing the standalone-compile acceptance from b, OR (b) reordering so T-INTEGRATE.c is parallel-with-b in PG-2. Option (a) is cleaner.

**Risk if not fixed**: PG-2 fails on the first acceptance check, orchestrator blocked, requires re-plan.

---

### HIGH-2 — T-INTEGRATE-PRE-PRED uses post-lift `ClosedBit` predicate signature that depends on §4.6.2 — never spelled out in the plan

**Location**: Plan lines 142-162 (T-INTEGRATE-PRE-PRED); design §4.6.2 (line 3282)
**Category**: Interface Contract / Behavior Verification

**Current state**: T-INTEGRATE-PRE-PRED says "Factor the 5 inline `(seq and CLOSED_BIT) != 0'u` sites into named predicates: `seqIsClosed`, `seqIsLive`, `seqIsEmpty`, `seqIsFull`, `seqIsCommitted` (exact set per design §4.6)."

**Problem**: The plan does not inline the predicate signatures, so an executing agent must read design §4.6.2 to know:
- Predicate parameter types (`seq: uint64` vs `slot: MpmcCell` vs `pos: uint64`)
- Whether `seqIsLive` and `seqIsClosed` are negations of each other or independent
- Whether `seqIsEmpty`/`seqIsFull` apply to bounded only or also unbounded
- Whether `seqIsCommitted` is the unbounded-MPMC committed-flag check (a different bit layout than the bounded-CLOSED_BIT)

The cross-module interface matters: T-INTEGRATE-PRE-PRED ships a public module that T-PATH-C-DISPATCH (PG-6) and T-DRAIN-HELPERS (PG-7) consume. If the predicate signatures drift between authors, the downstream tasks fail integration.

**Required**: Inline the exact 5 predicate signatures (proc name + parameter list + return type) into T-INTEGRATE-PRE-PRED's "Deliverable" section, citing design §4.6.2 line 3284-3335 verbatim. Add to acceptance: "Predicate signatures match design §4.6.2 verbatim."

---

### HIGH-3 — T-PATH-C-DISPATCH depends on T-NIMONY-ARMS but plan declares it doesn't

**Location**: Plan line 567 (T-PATH-C-DISPATCH deps: "T-MANAGED-REF, T-MANAGED-SLICE"); design §2.5 (25-row matrix); §5.1.4 (Path C internal dispatch)
**Category**: Dependencies

**Current state**: T-PATH-C-DISPATCH depends on T-MANAGED-REF + T-MANAGED-SLICE but NOT on T-NIMONY-ARMS.

**Problem**: T-PATH-C-DISPATCH's acceptance includes "Compile PASS under arc + orc + atomicArc + refc + none" (line 574) — but the 16-cell CI matrix (§6.3) includes a nimony cell. Either:
- Nimony coverage is deferred to PG-9 tests with `continue-on-error` (consistent with R4 mitigation), in which case T-PATH-C-DISPATCH compile under nimony is not its concern — OK, but should be stated, OR
- T-PATH-C-DISPATCH's `when T is ref:` branches need to compile under nimony too, which requires the nimony shim arms to exist — making T-NIMONY-ARMS a true dep.

**Required**: Add explicit note to T-PATH-C-DISPATCH: "nimony compile coverage is not gated on this task; T-NIMONY-ARMS produces the nimony branches independently and T-CI-NIMONY runs with `continue-on-error: true` per R4." OR add T-NIMONY-ARMS as a dep (preferred for thoroughness; consistent with `Develop = Thoroughness Mode`).

---

### HIGH-4 — T-CI-WALLCLOCK-BASELINE acceptance is unverifiable in current tree

**Location**: Plan lines 120-138
**Category**: Acceptance Criteria

**Current state**: Acceptance says "All 15 test cells (per §6.3) measured at least once cold; Lint cell measured." Cells include nimony, chronos, Valgrind, Helgrind — tests for which DO NOT YET EXIST (they ship via PG-9 tasks).

**Problem**: PG-0 runs before PG-9. The baseline measurement can only measure the EXISTING `lockfreequeues` test suite, not the lifted nebr suite (PG-2) and not the net-new tests (PG-9). The acceptance criterion as written is unsatisfiable at PG-0 time.

**Required**: Reword acceptance to: "Measure cold-state wall-clock for each of the 15 test cells using the existing lockfreequeues v5.0.0 suite as proxy; project to expected v0.1.0 scale (existing-suite × 1.6, per design §6.4.3 prediction); compare projected total to operator threshold (§6 O1)." OR move T-CI-WALLCLOCK-BASELINE to a re-measure step in PG-10 after PG-9 produces real tests (but this delays operator decision on §6 O1).

---

### HIGH-5 — T-CHRONOS Boolean expression in acceptance is impossible

**Location**: Plan line 670: "Adapter compiles WITH chronos installed; emits clear error WITHOUT chronos AND with `-d:lockfreeChronos`"
**Category**: Acceptance Criteria (logic error)

**Current state**: The acceptance has an `AND` where it must be a sub-state distinction.

**Problem**: As written, "WITHOUT chronos AND with `-d:lockfreeChronos`" is a single conjoint state — the test would only verify that exact combination. The intent per design §5.6.6 is three states:
- (a) chronos installed, no `-d:` flag: auto-detect, compiles.
- (b) chronos installed, `-d:lockfreeChronos` set: also compiles.
- (c) chronos NOT installed, `-d:lockfreeChronos` set: emits a specific compile-time error message (the OQ5.5 disposition).
- (d) chronos NOT installed, no `-d:`: AsyncQueue is invisible; user gets a normal "undeclared identifier" error.

**Required**: Replace acceptance with 4 explicit cases, each with a concrete pass criterion. Cite design §5.6.6.

---

## Medium Findings

### MEDIUM-1 — T-INTEGRATE.f acceptance vacuously satisfied

**Location**: Plan lines 446-454
**Current state**: Acceptance: "`imports/nim-debra/` does not exist; `nimble check` + `nimble test` PASS."
**Problem**: `nimble test` PASSING does NOT prove "nothing referenced the deleted path" if no test imports the deleted path. The grep check (line 449) is the stronger signal but is one of three bullets.
**Required**: Strengthen by making the grep the primary check and noting that compile/test passing is a necessary-but-not-sufficient secondary signal.

---

### MEDIUM-2 — T-INTEGRATE-RENAME has no rollback plan

**Location**: Plan lines 458-481
**Current state**: Solo dispatch, atomic rename across the entire tree. No mention of what happens if `nimble test` fails after the rename (line 473).
**Required**: Add to acceptance: "If `nimble test` fails after rename, `git reset --hard` to pre-rename HEAD; do not attempt to fix in-place. Failure means a missed import path; re-plan T-INTEGRATE.c coverage and retry from clean."

---

### MEDIUM-3 — T-MANAGED-REF acceptance for "ABI stability per §2.10 documented inline" is checklist-shaped, not testable

**Location**: Plan line 499
**Required**: Replace with a concrete test: "`tests/managed_ref/t_managed_ref_abi.nim` (per T-TEST-MANAGED-REF) verifies `sizeof(ManagedRef[X]) == sizeof(uint)` and `alignof(ManagedRef[X]) == alignof(uint)` for X in {int, ref Object, string}." (This test already exists in T-TEST-MANAGED-REF line 789, so just cross-link.)

---

### MEDIUM-4 — T-TEST-NEBR depends on "T-INTEGRATE.e + T-INTEGRATE-RENAME" but the lifted suite was renamed in T-INTEGRATE.e

**Location**: Plan line 771
**Current state**: Acceptance: "Lifted suite + new underflow test PASS under arc + orc on all 3 OS."
**Problem**: After T-INTEGRATE-RENAME (PG-4), paths shift from `tests/smr/debra-legacy/` to a post-rename path. The plan says T-INTEGRATE-RENAME rewrites imports across `src/`, `tests/`, `examples/`, `docs/` (line 466), but doesn't promise to update test-file paths inside `tests/smr/debra-legacy/`.
**Required**: Clarify whether `tests/smr/debra-legacy/` keeps its name post-rename (yes, recommended; the name documents provenance) and whether its IMPORTS are rewritten (yes — they reference `lockfreequeues/smr/nebr` pre-rename, must become `lockfree/smr/nebr` post-rename).

---

### MEDIUM-5 — T-DOCS-RETHINK.h acceptance "mkdocs build PASS" depends on plugins not pinned

**Location**: Plan lines 1107-1125
**Current state**: Acceptance mentions `mkdocstrings-nim` workaround (R12). No mention of mkdocs version pin, theme version pin, or which plugins must be installed.
**Required**: Add to deliverable: "Update `pyproject.toml` or `requirements.txt` with pinned mkdocs + theme + mkdocstrings-nim versions inherited from lockfreequeues v5.0.0 docs CI." Add to acceptance: "Docs build matches lockfreequeues v5.0.0 plugin set verbatim except mkdocstrings-nim include-path patch."

---

### MEDIUM-6 — PG-D parallel-with-code claim is unverified

**Location**: Plan line 90: "All 8 docs sub-tasks run parallel-with-code (PG-1 through PG-9)"
**Current state**: T-DOCS-RETHINK.f (examples) explicitly gates on PG-7/PG-8 (line 1072). T-DOCS-RETHINK.h gates on PG-4 + DOCS.a-g (line 1115). That's NOT "parallel with PG-1 through PG-9" — that's "parallel with code phase EXCEPT f (gates on PG-7/PG-8) and h (gates on PG-4 + content)."
**Required**: Rewrite line 90 to enumerate the real gating: "PG-D.a-e and PG-D.g run parallel-with-code starting at PG-1. PG-D.f gates on PG-8. PG-D.h gates on PG-4 + the other PG-D outputs."

---

## Minor Findings

### LOW-1 — T-OQ-OPERATOR effort XS overstates "operator unavailable" risk

Operator unavailability is a runtime, not effort, factor. Either drop the risk callout (XS effort handles all paths) or split into "ask" (XS) and "block-and-wait" (variable).

### LOW-2 — Plan opening (line 12) references "16-cell CI matrix" but task table (PG-10) names 5 CI tasks — clarify the cell count vs task count distinction

A reader could conflate "16 cells" with "16 CI tasks." Add a one-liner: "PG-10 contains 5 CI tasks that together implement 16 matrix cells."

### LOW-3 — Risk register table (lines 1212-1227) is duplicative of per-task risk callouts; consider removing one source of truth

The per-task `Risk:` field already cites R1-R14. The summary table at the end is helpful as a reverse index but creates a maintenance hazard if the two drift.

### LOW-4 — `T-NIMBLE` should also list `version = "0.1.0"` as a deliverable line, not just an acceptance item

Currently in acceptance only (line 1142); promote to deliverable for symmetry with `name = "lockfree"`.

---

## Findings by Category

### Completeness

Spot-checked against design §7.9 "What lands in v0.1.0":

| Design feature | Plan task | Status |
|---|---|---|
| Queue (4 cardinalities, unbounded) | T-INTEGRATE.a-f + T-PATH-C-DISPATCH | COVERED |
| BQueue (4 cardinalities, bounded) | T-INTEGRATE.a-f + T-PATH-C-DISPATCH | COVERED |
| nebr SMR | T-INTEGRATE.b + T-INTEGRATE.e | COVERED |
| ManagedRef[X] + Path C | T-MANAGED-REF + T-PATH-C-DISPATCH | COVERED |
| ManagedSlice[T] + Path C | T-MANAGED-SLICE + T-PATH-C-DISPATCH | COVERED |
| `ref T` user-facing API | T-PATH-C-DISPATCH | COVERED |
| `string` / `seq[T]` user-facing | T-PATH-C-DISPATCH | COVERED |
| Tier 1 sync iterators | T-ITERATORS | COVERED |
| chronos adapter (Tier 3) | T-CHRONOS | COVERED |
| mm:none + drain helpers | T-DRAIN-HELPERS + T-TEST-MM-NONE | COVERED |
| Nimony first-class arch | T-NIMONY-ARMS + T-CI-NIMONY + T-TEST-NIMONY | COVERED |
| Typestate dual-API + RAII | T-TYPESTATE-DUAL-API | COVERED |
| 16-cell CI matrix | T-CI-MATRIX + 4 sister CI tasks | COVERED |
| Documentation IA rebuild | T-DOCS-RETHINK.a-h | COVERED |
| Migration docs (3 files) | T-DOCS-RETHINK.g | COVERED (file count matches) |
| Examples (8 .nim files) | T-DOCS-RETHINK.f | COVERED (file count matches) |
| Package metadata (nimble) | T-NIMBLE | COVERED |
| AGENTS.md | T-AGENTS-MD | COVERED |
| CHANGELOG | T-CHANGELOG | COVERED |
| Slot-state predicates (§4.6) | T-INTEGRATE-PRE-PRED | COVERED but signatures not inline (see HIGH-2) |
| Pop-clears (§4.5.2) | T-INTEGRATE-POP.* (8) | UNVERIFIABLE (see CRITICAL-1, CRITICAL-2) |

**Net**: 19 of 21 feature-rows COVERED; 1 covered-with-gap; 1 unverifiable.

### Dependencies

Graph traced (PG order): PG-0 → PG-1 → PG-2 → PG-3 → PG-4 → PG-5 → PG-6 → PG-7 → PG-8 → PG-9 → PG-10; PG-D parallel-with-code; PG-Z parallel-after-PG-4.

- **VALID**: no cycles.
- **MISSING edges**: HIGH-1 (b ↔ c), HIGH-3 (PATH-C ↔ NIMONY-ARMS).
- **Wrong-direction edges**: none.
- **Underspecified PG sets**: PG-5 (CRITICAL-3 — race protocol).

### Acceptance criteria

40 of 47 tasks have concrete + testable acceptance. Vague or untestable: T-OQ-OPERATOR (LOW-1), T-CI-WALLCLOCK-BASELINE (HIGH-4), T-CHRONOS (HIGH-5), T-MANAGED-REF ABI claim (MEDIUM-3), T-INTEGRATE.f (MEDIUM-1), T-DOCS-RETHINK.h plugin pins (MEDIUM-5), T-TEST-NEBR post-rename paths (MEDIUM-4).

### Effort consistency

Reviewed XS/S/M/L scale across the 47 tasks. Outliers:
- T-INTEGRATE.b is M but lifts the entire nebr tree (12+ files including `typestates/` subtree) — closer to L. Acknowledged by reviewer as a judgment call; not raising as separate finding.
- T-INTEGRATE-POP.* are XS each (8 of them, ~one-line edits) — internally consistent.

### Pre-flight / blockers

PG-0 contains the right two tasks (T-CI-WALLCLOCK-BASELINE + T-OQ-OPERATOR). Surfacing §6 O1, O4, O5 before any implementation is correct. T-INTEGRATE-PRE-PRED at PG-1 (before downstream typestate consumers) is correct placement.

Missing pre-flight: the fact-check escalation per CRITICAL-2 should also be PG-0 (or PG-(-1)) — without it, PG-1's pop-clears work is mis-targeted.

### Risk integration (5 spot-checks)

- **R1** (T-INTEGRATE volume): claimed at T-INTEGRATE.a/.b/.c/.d/.e/.f. Mitigation "per-task dispatch + review gate". ✓ Embedded — each T-INTEGRATE.* task is a separate row.
- **R2** (pop-clears 8-arm): claimed at all T-INTEGRATE-POP.*. Mitigation "per-arm regression test in every MM cell". ✓ Embedded — each task has a `tests/internal/t_*_pop_clears_payload.nim` deliverable. (But see CRITICAL-2 — the underlying defect may not exist.)
- **R6** (DEBRA+ overclaim): claimed at T-INTEGRATE.d + T-DOCS-RETHINK.c. Mitigation "Sweep + provenance cross-link". ✓ Embedded — T-INTEGRATE.d line 385 calls out the nim-debra README line 34 fix; T-DOCS-RETHINK.c line 1003 calls out the cross-link.
- **R7** (seq[non-POD T]): claimed at T-MANAGED-SLICE + T-TEST-MANAGED-SLICE. Mitigation "Compile-time reject + should_fail test". ✓ Embedded — T-MANAGED-SLICE line 510 has `static assert T is PodType`; T-TEST-MANAGED-SLICE line 809 has the should_fail test.
- **R10** (pinscope unwind on cancel): claimed at T-CHRONOS + T-TEST-CHRONOS. Mitigation "try/finally + dedicated regression test". ✓ Embedded — T-CHRONOS line 673 calls out try/finally; T-TEST-CHRONOS line 732 has `t_chronos_cancellation_pinscope.nim`.

All 5 spot-checks PASS. Risk integration is solid.

### Standing rules compliance

- **No autonomous scope cuts** (`feedback_no_autonomous_scope_cuts`): ✓ Line 26 + line 132 + line 1235 all reaffirm.
- **No defer-to-followup** (`feedback_never_recommend_defer_to_followup`): ✓ No "defer to v0.2" recommendations in the body; the "NO" rows in §7.9 are operator-locked decisions, not in-plan deferrals.
- **Phase non-fungibility** (one row per dispatch): ✓ Line 40 + line 1231 enforce.
- **No direct git tagging**: N/A (plan doesn't touch release tagging).
- **Per-arm pop-clears NOT cut to fewer arms**: ✓ All 8 arms present.

### Path coherence

- PRE-rename paths used in T-INTEGRATE.a-f: cited as `src/lockfree/*`. ✓ Consistent.
- POST-rename paths used in T-MANAGED-REF onward: cited as `src/lockfree/*`. ✓ Consistent.
- Switchover task: T-INTEGRATE-RENAME (PG-4, SOLO). ✓ Clearly identified.
- Test paths: `tests/internal/`, `tests/composition/`, `tests/drain/`, `tests/chronos/`, `tests/mm_none/`, `tests/smr/debra-legacy/`, `tests/smr/`, `tests/managed_ref/`, `tests/managed_slice/`, `tests/nimony/`. ✓ Consistent (no `imports/nim-debra/tests/` references after PG-2).

**One inconsistency**: T-INTEGRATE-POP.* (lines 192-329) cite `src/lockfree/internal/*_pop.nim` — but actual lockfreequeues v5.0.0 puts these files at `src/lockfree/typestates/*_pop.nim`. This is **CRITICAL-1**, raised above.

### Execution mode

Recommendation: DELEGATED. Rationale (lines 32-46) holds for 47 tasks with heavy PG-1 (10-way) and PG-9 (8-way) parallelism. Worktree strategy (single tree at `~/Development/lockfree`, no per-track worktrees) is consistent with serial dispatch within a PG when files race (CRITICAL-3 case is the one exception that needs explicit handling).

### Open questions integration

- Operator-only OQs (§6 O1, O4, O5): mapped to T-OQ-OPERATOR (PG-0). ✓
- Phase 3 category-C OQs (5): each pointed at a task. ✓ Table at line 62 cross-references.
- Phase 2.2 cat-A (18) + Phase 2.5 cat-B (19): declared RESOLVED upstream of Phase 3. ✓ Plan does not re-litigate.

### Verification anchors (5 spot-checks against actual codebase)

| Task | Citation | Verified? | Notes |
|---|---|---|---|
| T-INTEGRATE-PRE-PRED | "5 inline `(seq and CLOSED_BIT) != 0'u` sites in queue.nim" | NOT VERIFIED in this review | Recommend grep before Phase 4. |
| T-INTEGRATE.a | `imports/nim-debra/src/debra/atomics.nim` + `atomics/{backoff,dsl}.nim` | ✓ VERIFIED — `ls imports/nim-debra/src/debra/atomics/` returns `backoff.nim`, `dsl.nim`. |
| T-INTEGRATE.b | nebr internals tree | ✓ VERIFIED — `ls imports/nim-debra/src/debra/` returns the cited file set + typestates/ subdir. |
| T-INTEGRATE-POP.spsc | `src/lockfree/internal/spsc_pop.nim:72` | ✗ CONTRADICTED — file at `src/lockfree/typestates/spsc_pop.nim`. Line 72 exists but uses `move()`. CRITICAL-1 + CRITICAL-2. |
| T-INTEGRATE-POP.unbounded-spsc | `src/lockfree/internal/unbounded_spsc_pop.nim:120` | ✗ FILE DOES NOT EXIST. Logic inlined in `src/lockfree/queue.nim` (verified `move(seg.data[...])` at lines 874, 1360, 1380, 1475). CRITICAL-1. |

---

## Remediation Plan

### Priority 1: Interface Contracts (blocks parallel execution)

1. **CRITICAL-1**: Replace cited paths/lines in all 8 `T-INTEGRATE-POP.*` tasks with verified working-tree paths (bounded → `src/lockfree/typestates/`; unbounded → specific `move(seg.data[...])` sites in `src/lockfree/queue.nim`).
2. **CRITICAL-2**: Route the "is `move()` already sufficient?" question through `fact-checking` skill BEFORE Phase 4 dispatch. Update plan based on result; the 8-arm fix scope likely narrows substantially.
3. **CRITICAL-3**: Add PG-5 race protocol — pick "hard serialize T-NIMONY-ARMS to PG-5b" (recommended) or write the merge-dispatch contract.
4. **HIGH-1**: Resolve T-INTEGRATE.b ↔ T-INTEGRATE.c — fold import rewrite into b OR move c into PG-2.
5. **HIGH-2**: Inline the 5 slot-state predicate signatures from design §4.6.2 into T-INTEGRATE-PRE-PRED.
6. **HIGH-3**: State T-PATH-C-DISPATCH nimony-coverage policy (deferred-to-CI vs gates-on-T-NIMONY-ARMS).

### Priority 2: Behavior Verification (prevents debugging loops)

1. Verify T-INTEGRATE-PRE-PRED's "5 inline CLOSED_BIT sites" claim via grep before Phase 4 (per `feedback_verify_subagent_claims_against_source`).
2. Update T-INTEGRATE-POP.* acceptance to specify whether the regression test must FAIL on pre-fix tree (red → green). Per CRITICAL-2, the answer may be "the test never reds because `move()` already cleared the slot" — in which case the entire task family is reshaped.

### Priority 3: QA/Testing

1. **HIGH-4**: Reword T-CI-WALLCLOCK-BASELINE acceptance to be satisfiable at PG-0 time (proxy with existing v5.0.0 suite + projection multiplier).
2. **HIGH-5**: Rewrite T-CHRONOS acceptance as 4 explicit (chronos × `-d:`) cells.
3. **MEDIUM-3**: Cross-link T-MANAGED-REF ABI acceptance to the test in T-TEST-MANAGED-REF.

### Priority 4: Completeness

1. **MEDIUM-1**: Strengthen T-INTEGRATE.f acceptance to make the grep primary.
2. **MEDIUM-2**: Add T-INTEGRATE-RENAME rollback step ("`git reset --hard` on test failure; do not fix in-place").
3. **MEDIUM-4**: Clarify T-TEST-NEBR post-rename path handling.
4. **MEDIUM-5**: Pin mkdocs plugin versions in T-DOCS-RETHINK.h.
5. **MEDIUM-6**: Rewrite plan line 90 (PG-D parallelism description) to enumerate actual gating.
6. **LOW-1 through LOW-4**: Optional polish.

### Fact-Checking Required

1. **Claim**: "v5.0.0 reads `let value = queue.storage[op.slot]` and advances head. No clear." (design §4.5.2, propagated to plan T-INTEGRATE-POP.spsc)
   **Category**: Behavior Verification (existing code)
   **Depth**: Spot-check + Nim language manual + emitted C inspection. **CRITICAL** — gates all 8 pop-clears tasks.

2. **Claim**: "5 inline `(seq and CLOSED_BIT) != 0'u` sites in `src/lockfree/queue.nim`" (plan T-INTEGRATE-PRE-PRED)
   **Category**: Behavior Verification (existing code)
   **Depth**: Grep + count + arm-by-arm review. Low effort; high payoff.

3. **Claim**: "typestates 0.10.0 generic-context match-macro defect — mitigated by `>= 0.10.0` pin" (plan T-TYPESTATE-DUAL-API line 628)
   **Category**: Library behavior
   **Depth**: Cross-reference `project_typestates_0.10.0_ast_verifier` memory + verify upstream v0.10.0 actually ships the AST verifier fix (not just the v0.7.1 buildMatchCase fix). The memory tags two separate bugs at adjacent versions; verify which one v0.10.0 closes.

---

## Final Notes for Phase 3.4 (fix gate)

The plan is structurally sound and at the right altitude for delegated dispatch. The CRITICAL findings are concentrated in one task family (T-INTEGRATE-POP.* + their PRE-PRED sibling) and one missing PG-5 protocol — both are tractable in a single Phase 3.4 fix pass.

If the CRITICAL-2 fact-check reveals that `move()` already handles all 8 arms correctly, the plan loses 8 tasks (good — less work) and the dependency graph simplifies (T-INTEGRATE-PRE-PRED still stands as a §4.6 cleanup; T-INTEGRATE-POP.* either disappear or shift to a single post-PG-5 "shim-wrapper pop site zeroes the bits" task).

The HIGH findings are independent of each other and can be addressed in parallel.

After Phase 3.4 fixes land, recommend a second `reviewing-impl-plans` pass focused only on the changed tasks; the rest of the plan is already audited green.

End of review.
