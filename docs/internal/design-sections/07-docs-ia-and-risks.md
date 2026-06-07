# Section 7 — Documentation IA, Consolidated Open Questions, Risks & Phase 2 Completion

**Phase 2 design synthesis: final section of 7.**

Section 7 closes the umbrella design by (a) fixing the documentation
information architecture (IA) that T-DOCS-RETHINK will materialize,
(b) consolidating every open question (OQ) from Sections 1-6 into a
single Phase-2.2 / Phase-2.5 review backlog, (c) enumerating risks
with mitigations, (d) recording deferrals and what is intentionally
out of scope for v0.1.0, and (e) defining Phase 2 completion criteria.

Cross-references throughout: handoff
`/Users/eek/.local/spellbook/handoffs/2026-06-05-elijahr-lockfree-consolidation.md`,
Sections 1-6 in this directory, and
`/Users/eek/Development/lockfree/docs/internal/safety-argument.md`.

---

## 7.1 Documentation Information Architecture (target structure)

Per handoff T-DOCS-RETHINK, the v0.1.0 docs tree is a **coherent
umbrella narrative**, not a side-by-side stitching of the
lockfreequeues docs tree and the nim-debra docs tree. The mkdocs
config is rebuilt from scratch; the lifted source content is plundered
for material but its IA is discarded.

### 7.1.1 Full target tree

```
docs/
  guide/
    index.md                       # umbrella positioning
    getting-started.md             # 5-minute walkthrough
    concepts/
      lock-freedom.md              # what "lock-free" buys
      smr.md                       # what SMR is, why it exists
      memory-management.md         # arc/orc/atomicArc/refc/none under one lens
    smr/
      nebr.md                      # the v0.1.0 SMR
      # ebr.md          (reserved; comment-only stub in mkdocs nav)
      # debra_plus.md   (reserved; faithful Brown 2015 future work)
      # hazard.md       (reserved)
      # ibr.md          (reserved)
      # nbr.md          (reserved)
    queues/
      index.md                     # cardinality matrix + chooser
      strict-lcrq-mpmc.md          # strict-LCRQ impl for v0.1.0 (renamed from unbounded-mpmc.md per §7.9.1)
      bounded-vyukov.md            # Vyukov seq-counter bounded queue
      legacy.md                    # mpsc / spmc / spsc cardinalities
    managed-ref.md                 # ref T payload pattern (user-visible API)
    managed-slice.md               # string / seq[T] payload pattern
    typestates.md                  # dual-API surface (bare + RAII)
    nimony.md                      # nimony compat + experimental gaps
  api/                             # auto-generated via mkdocstrings-nim
  migrations/
    from-lockfreequeues-v5.md
    from-nim-debra.md       # covers BOTH nim-debra nimble pkg AND import debra
    # (from-debra-package.md was a draft-time placeholder; consolidated into
    # from-nim-debra.md per Phase 4.6.4 fact-check; no separate page ships.)
  examples/
    basic-queue.nim                # canonical 5-line intro
    ref-payload.nim                # ManagedRef pattern, user code
    slice-payload.nim              # ManagedSlice pattern, user code
    smr-only.nim                   # using nebr without a queue
    custom-types.nim               # POD struct payloads
    bounded-pipeline.nim           # BQueue producer/consumer pipeline
    nimony-compat.nim              # only included if Phase 1 confirms nimony port
    mm-none-audio.nim              # audio ringbuffer pattern under --mm:none
  internal/                        # preserved across releases; not in mkdocs nav
    2026-06-05-umbrella-v0.1.0-design.md   # canonical consolidated design doc
    design-sections/                       # raw section files (this directory)
    safety-argument.md
    debra-plus-provenance.md               # Q-FAITHFUL artifact
    q-dwcas-investigation.md               # Q-DWCAS artifact
    iterator-async-scoping.md              # per handoff
```

### 7.1.2 Per-file purpose, source inputs, T-DOCS-RETHINK sub-task

| File | Purpose | Source inputs | Sub-task |
|------|---------|---------------|----------|
| `guide/index.md` | Umbrella positioning: one paragraph each on queues + SMR + ManagedRef + typestates | Net-new | .a |
| `guide/getting-started.md` | 5-minute walkthrough: install, simplest BQueue, simplest Queue, when to reach for nebr | Net-new | .a |
| `guide/concepts/lock-freedom.md` | Lock-free vs wait-free vs blocking; what `{.lockFree.}` pragma means | Lifted phrasing from lockfreequeues `docs/concepts/`; consolidated | .b |
| `guide/concepts/smr.md` | What safe memory reclamation is; why EBR/HP/NEBR exist; reader-writer asymmetry | Lifted phrasing from nim-debra `docs/concepts/safe-memory-reclamation.md`; rewritten under umbrella voice | .b |
| `guide/concepts/memory-management.md` | One coherent narrative spanning arc/orc/atomicArc/refc/none — what each does, what changes for queue payloads | Net-new (Section 4 §4.3-4.10 distilled) | .b |
| `guide/smr/nebr.md` | The v0.1.0 SMR strategy: typestate machinery, manager lifecycle, neutralize, reclamation cadence policy | Lifted from nim-debra `docs/strategies/debra.md`; **renamed throughout** (debra → nebr); attribution softened per Q-FAITHFUL | .c |
| `guide/queues/index.md` | Cardinality chooser (mpmc / mpsc / spmc / spsc × bounded / unbounded) | Lifted from lockfreequeues `docs/queues/`; condensed | .d |
| `guide/queues/strict-lcrq-mpmc.md` | The strict-LCRQ MPMC impl in v0.1.0 (lifted from the lockfreequeues integration tree, verified at `src/lockfree/queue.nim:1616-1632` per §5.3). File renamed from `unbounded-mpmc.md` (early-draft name) per §7.9.1 reconciliation — the shipped impl IS strict-LCRQ, and naming it accordingly is more discoverable for readers grepping for the algorithm. | Lifted from lockfreequeues integration tree | .d |
| `guide/queues/bounded-vyukov.md` | Vyukov seq-counter BQueue | Lifted from lockfreequeues | .d |
| `guide/queues/legacy.md` | mpsc / spmc / spsc cardinalities; positioning vs mpmc | Lifted from lockfreequeues | .d |
| `guide/managed-ref.md` | `ref T` user-facing API (Path C); internal `ManagedRef[X]` slot mentioned only in passing | Net-new (Sections 2 §2.5-2.7 + 4 §4.4 distilled) | .e |
| `guide/managed-slice.md` | `string` / `seq[T]` user-facing API; POD-only T constraint inside `seq[T]` documented | Net-new (Sections 2 §2.8 + 4 §4.6 distilled) | .e |
| `guide/typestates.md` | Bare API vs RAII wrappers; when to use which; chronos integration teaser | Net-new (Section 5 §5.2-5.5 distilled) | .f |
| `guide/nimony.md` | nimony compatibility state; experimental flag set; partial-port acceptance; watch policy | Net-new (Section 6 §6.10 + handoff Phase 1.6 reconciliation) | .f |
| `api/` (entire tree) | Auto-generated symbol reference | mkdocstrings-nim on `src/lockfree/**.nim` | .g |
| `migrations/from-lockfreequeues-v5.md` | Package rename, `-d:allowNonLockFreeQueueItems` removal, `ref T` direct support, module path changes | Net-new | .h |
| `migrations/from-nim-debra.md` | Package rename, import path change, README attribution change, AND symbol-table mapping for direct `import debra` users (consolidated per Phase 4.6.4 fact-check) | Net-new | .h |
| `examples/*` | Eight runnable `.nim` files | Net-new; each compiles as part of CI examples cell | .a + .f |

### 7.1.3 mkdocs.yml configuration shape

Single new `mkdocs.yml` at repo root. Inherits theme from lockfreequeues
(`material` + dark mode default per user preference). Site name:
`lockfree`. Repo URL: TBD per CRITICAL #5 publication path deferral —
`mkdocs.yml` ships with placeholder URL that the rename step
(post-v0.1.0) updates. Navigation mirrors §7.1.1 exactly.

`mkdocstrings-nim` is wired per Section 6 §6.9 (nim source pinned per
`feedback_nimble_install_nim_no_longer_compiler_source.md`).

---

## 7.2 Migration documents (concrete content sketch)

### 7.2.1 `from-lockfreequeues-v5.md`

- **Package rename**: `nimble install lockfreequeues` → `nimble install
  lockfree`. (Actual rename choreography deferred per §7.7; this doc
  ships with placeholder name + publication-day patch.)
- **Removal of `-d:allowNonLockFreeQueueItems`**: the type-system arms
  in Section 2 §2.5-2.7 accept `ref T` directly; the escape hatch is no
  longer needed. Users who set the flag get a `{.deprecated.}` warning
  with link to `guide/managed-ref.md`.
- **`ref T` direct support**: code patterns that previously wrapped a
  `ref` in a POD `ptr` now declare `Queue[ref Foo]` directly.
- **Module path changes**:
  - `import lockfreequeues` → `import lockfree`
  - `import lockfreequeues/mpmc` → `import lockfree/queue` (cardinality
    auto-detected from generic params; explicit cardinality modules
    still available as `import lockfree/queues/mpmc`)
- **Behavior preservation**: bounded queue Vyukov-seq invariant
  unchanged; unbounded MPSC / SPMC / SPSC committed-flag invariants
  unchanged; unbounded MPMC ships the strict-LCRQ DWCAS form already
  resident in the integration tree (§7.9.1). (Section 4
  pop-clears-payload fix is internal; observable behavior unchanged.)

### 7.2.2 `from-nim-debra.md`

- **Package rename**: `nimble install nim-debra` → `nimble install
  lockfree` (nebr is now a submodule).
- **Import path change**:
  - `import debra/atomics` → `import lockfree/atomics`
  - `import debra` → `import lockfree/smr/nebr`
  - `import debra/typestates` → `import lockfree/typestates`
- **Symbol renames**: per Q-FAITHFUL, the `debra` algorithm name is
  retired for the v0.1.0 implementation. The reclamation strategy is
  documented as **nebr** (Nim Epoch-Based Reclamation). Public symbols
  retain functional names (`reclaim`, `pin`, `unpin`, `register`); the
  algorithm-family label changes only in doc strings and module names.
- **README attribution change**: the nim-debra README line 34
  ("faithful implementation of the algorithm from Brown 2015") is
  rewritten to "epoch-based reclamation inspired by Brown 2015 (DEBRA);
  see `internal/debra-plus-provenance.md` for fidelity analysis."

### 7.2.3 `from-debra-package.md`

For users who depended on `debra` directly without going through
`lockfreequeues`. Tabular symbol-table mapping:

| Old symbol (debra) | New symbol (lockfree) | Notes |
|---|---|---|
| `debra/atomics.Atomic[T]` | `lockfree/atomics.Atomic[T]` | API-identical |
| `debra.Manager` | `lockfree/smr/nebr.Manager` | API-identical |
| `debra.register` | `lockfree/smr/nebr.register` | API-identical |
| `debra.pin` / `debra.unpin` | `lockfree/smr/nebr.pin` / `unpin` | API-identical |
| `debra.retire` | `lockfree/smr/nebr.retire` | API-identical |
| `debra.reclaim` | `lockfree/smr/nebr.reclaim` | API-identical |
| `debra.neutralizeStalled` | `lockfree/smr/nebr.neutralizeStalled` | API-identical |
| `debra/typestates` | `lockfree/typestates` | API-identical for SMR-side; queue typestates new |

---

## 7.3 T-DOCS-RETHINK sub-task detail

| Sub-task | Deliverable | Depends on | Source files | Net-new vs lifted |
|----------|-------------|------------|--------------|-------------------|
| .a | `guide/index.md` + `guide/getting-started.md` + `examples/basic-queue.nim` | T-INTEGRATE.a (lift complete so examples compile) | none | net-new |
| .b | `guide/concepts/*` (3 files) | T-INTEGRATE.a + .b | `lockfreequeues/docs/concepts/`, `nim-debra/docs/concepts/safe-memory-reclamation.md` | lifted phrasing + rewritten |
| .c | `guide/smr/nebr.md` | T-INTEGRATE.b (nebr renamed in-tree) | `nim-debra/docs/strategies/debra.md` | lifted + renamed + attribution softened (Q-FAITHFUL) |
| .d | `guide/queues/*` (4 files) | T-INTEGRATE.c (queue lift + pop-clears-payload fix) | `lockfreequeues/docs/queues/` | lifted + condensed; `strict-lcrq-mpmc.md` (renamed from the early-draft `unbounded-mpmc.md`) documents the shipped strict-LCRQ form (§7.9.1) |
| .e | `guide/managed-ref.md` + `guide/managed-slice.md` + `examples/ref-payload.nim` + `examples/slice-payload.nim` | T-INTEGRATE.d (ManagedRef / ManagedSlice impl complete) | none | net-new |
| .f | `guide/typestates.md` + `guide/nimony.md` + `examples/nimony-compat.nim` + `examples/mm-none-audio.nim` | T-INTEGRATE.e (typestate wrappers complete) + T-INTEGRATE.f (mm:none drain helpers complete) | none | net-new |
| .g | `api/` auto-generation pipeline + mkdocs config | T-INTEGRATE.a-f (source tree stable) | `src/lockfree/**.nim` | tooling integration |
| .h | `migrations/*` (3 files) | T-INTEGRATE.a-f | none | net-new |

All eight sub-tasks run **in parallel where dependencies allow** during
Phase 4. Sub-task .b can begin as soon as .a lift is done; .c can begin
as soon as nebr is renamed; .d/.e/.f gate on their respective impl
work; .g and .h can land late in Phase 4.

Per `feedback_micro_dispatch_rhythm`, T-DOCS-RETHINK sub-tasks are
**tight-scoped sequential micro-dispatches** during cross-doc design
rework. Each sub-task gets its own subagent dispatch and review.

---

## 7.4 Consolidated open questions

This is the union of every OQ raised in Sections 1-6, deduplicated and
categorized by who resolves it and when. **No new OQs are introduced
in Section 7.**

### 7.4.1 Inventory by source section

| Section | Count | Source |
|---------|-------|--------|
| §1 (Architecture) | 5 | §1.10 Q1.10-A through Q1.10-E |
| §2 (Type system) | 7 | §2.11 items 1-7 (numbered, not Q-prefixed) |
| §3 (SMR / nebr) | 6 | §3.13 Q3.13-A through Q3.13-F |
| §4 (MM compat shim) | 9 | §4.11 OQ4.1 through OQ4.9 |
| §5 (API surfaces) | 10 | §5.10 OQ5.1 through OQ5.10 |
| §6 (CI matrix) | 10 | §6.13 O1 through O10 |
| safety-argument.md | 0 explicit OQs (claims framed as policy-dependent, not as open questions) | n/a |
| **Total raw** | **47** | |

After deduplication (see §7.4.3), **45 unique OQs** remain. Two
near-duplicates collapse:

- §3 Q3.13-E and §6 O7 both ask about negative-test runner scoping;
  collapsed under §6 O7's framing.
- §2 item 1 (`distinctBase` corner cases) and §5 OQ5.8 (concept
  overload resolution) are adjacent but distinct — both retained.

### 7.4.2 Category split

| Category | Count | Description | Phase to resolve |
|----------|-------|-------------|------------------|
| **A. Phase 2.2 design-doc review** | 18 | Operator/reviewer judgment, design-shape questions | Phase 2.2 |
| **B. Phase 2.5 fact-check** | 19 | Codebase verification, no design fork; "verify before code lands" | Phase 2.5 |
| **C. Phase 3 implementation plan** | 5 | Sequencing / per-arm task-list questions | Phase 3 |
| **D. Operator-only** | 3 | Explicit operator input required | Phase 2.2 surfaced via AskUserQuestion |
| **Total** | **45** | | |

### 7.4.3 Full consolidated list

Each row: ID (Section-OQ), category, one-line summary, recommended
resolution. Items in **category B** are spot-checks; items in
**category A** are design-shape judgment calls; items in **category
D** require explicit operator input.

| ID | Cat | Summary | Recommendation |
|----|-----|---------|----------------|
| §1 Q1.10-A | A | `lockfree/typestates.nim` facade contents | Keep facade for symmetry; confirm in §5 review |
| §1 Q1.10-B | A | Queue.nim imports managed_ref/managed_slice unconditionally or under `when`? | Unconditional (small compile-time only) |
| §1 Q1.10-C | A | `backoff.nim` split: queue-level vs atomics-level | Keep both; different call sites |
| §1 Q1.10-D | A | Reserved SMR module names — comment-only or `{.error.}` stubs? | Comment-only; Section 7 confirms |
| §1 Q1.10-E | A | Top-level `lockfree.nim` doc-comment scope | Keep minimal, link to README |
| §2-1 | B | `distinctBase(int)` and `distinctBase(T) is ref` short-circuit | Spot-check; restructure `when` if needed |
| §2-2 | B | nimony `arcInc`/`arcDec` symbol names | Verify against nimony aufbruch source |
| §2-3 | B | `ref array[N, T]` with large N | Verify nimIncRef/nimDecRefIsLast OK |
| §2-4 | B | Closure environment refs (matrix row #13) | Spot-check with captured-managed-type closure |
| §2-5 | B | `Queue[ref Foo]` where Foo is `{.acyclic.}` under orc | Document perf note if cycle-collector skipped |
| §2-6 | B | Strict-LCRQ DWCAS `Atomic[Pair[uint, ManagedRef[X]]]` lift | Verify distinct-uint transparency to atomics templates |
| §2-7 | C | Drain helper signatures finalised in §5 | Phase 3 task; §5 carries placeholders |
| §3 Q3.13-A | A | `shutdown` empty `activeThreadMask` typestate enforcement? | Keep current; document contract |
| §3 Q3.13-B | A | Convenience API stronger typestate? | Document contract; no added complexity |
| §3 Q3.13-C | A | Expose `neutralizeStalled` at umbrella level? | Out of scope for v0.1.0; revisit |
| §3 Q3.13-D | A | Memory bound documentation prominence | 1-2 sentences in module doc-comment; full discussion in safety-argument.md |
| §3 Q3.13-E | A | Negative-test directory ships in v0.1.0? | **Collapsed with §6 O7** |
| §3 Q3.13-F | B | `safeEpoch - 1` underflow at epoch 0 | Accept current; add unit test asserting `ReclaimBlocked` at epoch 0/1 |
| §4 OQ4.1 | B | refc refcount symbol name at pinned Nim version | Verify against pinned Nim source |
| §4 OQ4.2 | B | nimony heap header layout for arcInc/arcDec adapter | Verify against nimony aufbruch source |
| §4 OQ4.3 | B | refc slice copy semantics | Verify against pinned Nim source |
| §4 OQ4.4 | B | nimony string/seq representation | Verify against nimony aufbruch source |
| §4 OQ4.5 | B | `NimStringV2.cap` tag-bit layout under arc/orc | Verify against pinned Nim source |
| §4 OQ4.6 | B | `sink string` destroy ordering for slice extraction | Verify against pinned Nim source |
| §4 OQ4.7 | B | v5.0.0 SPMC push facade cell shape | Verify against lockfreequeues v5 source |
| §4 OQ4.8 | C | Pop-clears refactor sequence-of-edits per arm (8 arms) | Phase 3 sub-task per arm |
| §4 OQ4.9 | B | Destructor walk + nebr ordering for unbounded | Verify against pinned Nim source + nebr impl |
| §5 OQ5.1 | A | Default callback on `destroyAndDrain` for POD | Add default `discard` overload for POD-only |
| §5 OQ5.2 | A | `pairs` semantics on multi-consumer drain | Phase 2.2 to confirm shape |
| §5 OQ5.3 | A | AsyncQueue vs explicit endpoint async | Phase 2.2 to confirm |
| §5 OQ5.4 | A | chronos version cap (5.x semantics) | Track in Phase 2.2; pin range, no upper cap at v0.1.0 |
| §5 OQ5.5 | A | Custom error for `-d:lockfreeChronos` without chronos | Phase 2.2 — standard error likely sufficient |
| §5 OQ5.6 | A | Default cleanup callback overload | Add for POD-only |
| §5 OQ5.7 | A | Friendly typestate violation messages | Phase 2.2 — bounded by upstream nim-typestates |
| §5 OQ5.8 | B | Concept overload resolution priority | Spot-check generic-instantiation behavior |
| §5 OQ5.9 | A | Tier 1 iterator on multi-consumer bare queue | Phase 2.2 to confirm |
| §5 OQ5.10 | A | Iterator name `items` vs Nim convention | Phase 2.2 stylistic confirmation |
| §6 O1 | D | Wall-clock baseline GREEN / YELLOW / RED? | Operator decision after baseline measure (per `feedback_thermal_throttling_validation` — cold-state measurement) |
| §6 O2 | B | TSAN runner-hang reproducibility on consolidated repo | Phase 2 verify |
| §6 O3 | B | Nimony install reliability from GitHub | Phase 2 verify; pin commit SHA if unreliable |
| §6 O4 | D | Add Windows in v0.2? | Operator decision; not v0.1.0 |
| §6 O5 | D | Add `nim cpp` backend axis? | Operator decision informed by §6.4 baseline |
| §6 O6 | A | Helgrind / Valgrind cells per-PR or nightly-only? | Per-PR if §6.4 GREEN; surface otherwise |
| §6 O7 | A | `mm:none` smoke-test subset or compile-only? | Compile + smoke-test subset (test framework allocates → full suite likely fails) |
| §6 O8 | A | Lint cell on macOS / arm64 too? | No; OS-independent |
| §6 O9 | C | Caching strategy for nimony build-from-source | `actions/cache@v4` keyed on nimony commit SHA |
| §6 O10 | A | "Comprehensive" excludes Windows + macOS x86_64? | Phase 6 interpretation: yes; v0.2 revisits |

**Category D (operator-only) totals 3**: §6 O1, O4, O5. These surface
via AskUserQuestion at Phase 2.2 entry.

**Category C (Phase 3 plan) totals 5 after collapse**: §2-7, §4 OQ4.8,
§6 O9, plus two Phase 3 sub-items tracked inside §4 OQ4.8's per-arm
expansion (the nimony cell-caching sequence and the per-arm
pop-clears refactor are each a distinct Phase 3 work item under the
same parent OQ). The category-C count of 5 is the total number of
distinct Phase 3 work items, not the number of table rows above.

### 7.4.4 What is NOT in the OQ list

- **Q-FAITHFUL D3/D7 backfill** (sigsetjmp + hazard pointers): not an
  OQ — explicitly **out of v0.1.0 scope** (§7.9). Documented as future
  work in `internal/debra-plus-provenance.md`.
- **Q-DWCAS resolution**: not an OQ — resolved in
  `internal/q-dwcas-investigation.md` and Section 3 §3.11; matrix
  retained current single-CAS form for v0.1.0.
- **Publication path / rename choreography**: not an OQ — deferred per
  CRITICAL #5 (§7.7).
- **Formal safety proof for memory bound**: not an OQ — documented as
  policy-dependent in `safety-argument.md` §7.

---

## 7.5 Risks and mitigations

Risks below are surfaced from Sections 1-6 plus Phase 1.6 devil's
advocate dispositions. Each row: risk, source, mitigation, residual.

| # | Risk | Source | Mitigation | Residual risk |
|---|------|--------|------------|---------------|
| R1 | T-INTEGRATE volume — 6 sub-tasks (.a-.f) need tight coordination | Handoff Phase 4 plan | Per-sub-task review gate (standard Phase 4 dispatch + review rhythm); micro-dispatch rhythm per `feedback_micro_dispatch_rhythm` | Coordination overhead absorbed into Phase 4 timeline; no schedule slip expected |
| R2 | Pop-clears-payload behavior across 8 cardinality arms (mpmc/mpsc/spmc/spsc × bounded/unbounded) | Section 4 §4.7 | Phase 3.4 disposition: the lockfree integration substrate has already wrapped each pop read in `move()`, which is observationally equivalent to the §4.5.3 family (1) `.reset()` mechanism. v0.1.0 ships per-arm regression tests (T-VERIFY-POP-CLEARS.*) that lock in the existing behavior so a future refactor cannot silently revert. | Regression test must run under every MM cell to catch arm-specific regression. |
| R3 | chronos version drift (4.x vs 5.x semantics on `AsyncEvent.fire`/`wait`) | Section 5 §5.6, OQ5.4 | Version pin range in `lockfree.nimble` (`chronos >= 4.0.0`); dedicated chronos CI cell exercises pinned version | If chronos 5.x ships before v0.1.0 with breaking semantics, adapter needs version-conditional code path |
| R4 | Nimony moving upstream (rapid breakage in nimony aufbruch) | Handoff Q2 + Phase 1.6 first-class reconciliation | `continue-on-error: true` on nimony cell; weekly watch policy in AGENTS.md; partial-port acceptance per CRITICAL #5 disposition | Nimony cell may show red without blocking PRs; operator-visible only |
| R5 | CI wall-clock > 20 min | Phase 1.6 MAJOR + Section 6 §6.4 baseline-measurement requirement | Baseline-measure FIRST (cold-state per `feedback_thermal_throttling_validation`); if > 20 min, surface to operator via AskUserQuestion (§6 O1) | Operator may need to trim cells; no autonomous cut per operator scope-cut rule |
| R6 | nim-debra README overclaim (line 34 "faithful implementation") | Q-FAITHFUL | T-INTEGRATE.d sweep fixes README line 34 + softens attribution to "inspired by Brown 2015 (DEBRA)"; full fidelity analysis in `internal/debra-plus-provenance.md`; future `debra_plus.nim` slot reserved for a faithful port | Provenance doc must be linked from `guide/smr/nebr.md` to avoid attribution drift |
| R7 | ManagedSlice for arbitrary T's `seq[T]` — non-POD T inside seq leaks lifetime through queue boundary | Section 2 §2.3 T-constraint | Type-system reject of non-POD T inside `seq[T]` via `static: assert T is PodType`-style guard; documented in `guide/managed-slice.md` | User error caught at compile-time; no runtime risk |
| R8 | `distinctBase` corner cases (non-distinct T, ref-distinct, deep distinct chains) | Section 2 OQ §2-1 | Phase 2.5 fact-check resolves; restructure `when` chain if needed | Low — `distinctBase` is well-tested in Nim stdlib |
| R9 | Publication path deferred — symbol churn on rename day | CRITICAL #5 | Deferred per `feedback_no_direct_tagging` discipline; revisit AFTER v0.1.0 ships in lockfree-temp; not blocking Phase 4 | Migration docs (§7.2) ship with placeholder URLs that the rename PR updates |
| R10 | pinscope unwind on thread-crash / chronos cancellation — bag may grow unboundedly if scopes don't close | Phase 1.6 MAJOR | Section 5 §5.4 chronos cancellation discipline (try/finally around pinscope); thread-crash documented as **undefined behavior** per Section 3 §3.8; supervisor pattern surfaced as future work (§3 Q3.13-C) | Documented limitation; user education in `guide/smr/nebr.md` |
| R11 | Examples may not compile after T-INTEGRATE if API drift | Section 7 §7.3 | `examples/` directory included in CI as compile-only cell (per Section 6); CI fails if examples don't compile | Low — caught at PR time |
| R12 | mkdocstrings-nim broken-include-path defect | `project_nimble_compiler_pkg_broken_include` + `project_nimble_install_nim_no_longer_compiler_source` | Pinned Nim source clone + `nim.cfg` path patch per memory; smoke-test in docs CI cell | Memory-tagged workaround; doc build will break visibly if memory advice becomes stale |
| R13 | `nph` version-banner unreliability — formatter check may use wrong baseline | `project_nph_version_banner_unreliable` | Discriminate format drift by baseline-file cleanliness under `nph --check`, not the banner; per memory | Documented in AGENTS.md gotcha section |
| R14 | typestate macro 0.10.0+ AST verifier — combined pragma forms must work in generic contexts | `project_typestates_0.10.0_ast_verifier` + `project_typestates_0.7.0_match_generic_context_bug` | Lock typestates dep to `>= 0.10.0`; CI lint cell exercises generic-context match macro | Low — fixed upstream; pinned via nimble |
| R15 | Windows atomics arm under-tested — `_InterlockedCompareExchange128` path exists in inherited nim-debra `atomics.nim` but has no CI gate before O4 resolution | Section 6 cell 17 (per O4 resolution 2026-06-06) | Section 6 cell 17 (windows-latest + MSVC + orc) verifies compile + runtime under Windows. Sanitizers omitted (don't run cleanly on Windows under default Nim toolchain). OQ for Phase 4: confirm `nimble test` passes under Windows; if any test fails Windows-specifically, triage at finding time (no autonomous cell-drop). | Runtime behavior under MSVC is not exercised by sanitizers; relies on the deterministic test suite catching regressions. |
| R16 | `nim cpp` may surface C++-specific incompatibilities — designated initializers, restrict qualifiers, identifier collisions with C++ keywords | Section 6 cell 18 (per O5 resolution 2026-06-06) | Section 6 cell 18 (ubuntu-latest + nim cpp + orc) catches the regression class at compile time. Any C-only construct surfaced is flagged as a Phase 4 OQ and resolved against the specific call site. | Low — cell 18 fails fast on incompatibility; fix is localized to the offending construct. |

---

## 7.6 Scope-cut contingency

**Per Phase 1.6 CRITICAL #3 — operator standing rule, no autonomous
scope cuts** (memory: `feedback_no_autonomous_scope_cuts`).

Per operator standing rule:
**no contingency-cut-order list is preprovided.** If real blockers
emerge during Phase 4 implementation, surface to operator via
AskUserQuestion at that moment, with the specific blocker, the
attempted resolutions, and the proposed cut.

This is the durable operator preference. Section 7 records it
explicitly so future review-passes don't manufacture a cut-order
table. It is the design's resolution of Phase 1.6 CRITICAL #3 (see
the Phase-1.6-disposition table in §7.10): no autonomous scope
cuts, no pre-baked contingency ordering, every cut surfaces to the
operator at the point of decision.

---

## 7.7 Rename and publication path

Per Phase 1.6 CRITICAL #5 disposition: **the v0.1.0 design doc does
NOT cover rename / archive / transfer choreography.**

- `lockfreequeues` (the existing published package) stays **frozen**
  at v5.x.
- v0.1.0 ships in the `lockfree-temp` workspace repo.
- After v0.1.0 ships and is operator-rated as solid + polished, a
  separate session decides the publication strategy: rename
  `lockfree-temp` → `lockfree`, archive `lockfreequeues`, transfer
  nim-debra, update nimble registry, etc.

Phase 2 design captures **only the things that affect code or CI
structure** (per CRITICAL #5 disposition):

- CI release-job structure (per Section 6 §6.11) — release tagging is
  CI-driven per global rule.
- Bot configuration on `lockfree-temp` (per Section 6 §6.12) —
  gemini-code-assist gating + axiomantic-momus informational.
- Nimble package metadata shape in `lockfree.nimble` (per Section 1
  §1.5) — name field is `lockfree`; URL/owner placeholders.

The actual rename + transfer + archive choreography revisits in a
future session, gated on a published v0.1.0 in `lockfree-temp`.

---

## 7.8 Implementation phasing summary

| Phase / task | Status | Owner | Notes |
|--------------|--------|-------|-------|
| T0 — `lockfree-temp` workspace created | DONE | Operator | Per handoff |
| T-INTEGRATE.a — repo skeleton lift | Phase 4 | Subagent dispatch | Section 1 layout |
| T-INTEGRATE.b — nebr lift + rename | Phase 4 | Subagent dispatch | Section 3 |
| T-INTEGRATE.c — queue lift; pop-clears-payload behavior locked in via T-VERIFY-POP-CLEARS.* per arm (Phase 3.4 disposition — code-edit already done in integration substrate; 8 regression tests ship) | Phase 4 | 8 subagent dispatches (one per arm, regression-test only) | Section 4; impl plan T-VERIFY-POP-CLEARS.* |
| T-INTEGRATE.d — ManagedRef + ManagedSlice impl | Phase 4 | Subagent dispatch | Section 2 + Section 4 |
| T-INTEGRATE.e — typestate dual-API + RAII wrappers | Phase 4 | Subagent dispatch | Section 5 |
| T-INTEGRATE.f — mm:none drain helpers | Phase 4 | Subagent dispatch | Section 5 + Section 4 |
| T-DOCS-RETHINK.a-h — docs IA rebuild | Phase 4 parallel | 8 sub-task dispatches | This section §7.3 |
| T-NIMONY-PORT — nimony first-class architecture | Phase 4 | Subagent dispatch | Section 6 §6.10 |
| T-CI-BASELINE — wall-clock baseline measure | Phase 2 (before §6.3 lock-in) | Subagent dispatch | Section 6 §6.4; cold-state per memory |
| T-CI-MATRIX-YAML — workflow YAML drafting | Phase 4 (after T-CI-BASELINE + O1-O10 resolution) | Subagent dispatch | Section 6 |
| T-EXAMPLES — 8 example files | Phase 4 (alongside docs sub-tasks) | Subagent dispatch | §7.1.1 + §7.3 |
| T-MIGRATION-DOCS — 3 migration files | Phase 4 (late) | Subagent dispatch | §7.2 |
| T-RELEASE — CI release-job wiring | Phase 4 | Subagent dispatch | Section 6 §6.11 |
| Rename choreography | DEFERRED (post-v0.1.0) | Future session | §7.7 |

T1-T17 from the handoff map onto T-INTEGRATE.a-.f + T-NIMONY-PORT +
T-CI-MATRIX-YAML + T-DOCS-RETHINK.a-.h plus the T-INTEGRATE-specific
work surfaced by Section 4 (pop-clears-payload behavior locked-in
across all 8 cardinality arms = 8 sub-dispatches as
T-VERIFY-POP-CLEARS.* regression tests in the impl plan; the
code-edit substrate was already in place via the lockfree integration
tree's prior `move()` wraps, per Phase 3.4 investigation).

---

## 7.9 What lands in v0.1.0 vs what doesn't

| Feature | In v0.1.0? | Source |
|---------|------------|--------|
| Queue (all 4 cardinalities, unbounded) | YES | Lifted from lockfreequeues |
| BQueue (all 4 cardinalities, bounded) | YES | Lifted from lockfreequeues |
| nebr SMR | YES | Lifted + renamed from nim-debra |
| `ManagedRef[X]` internal type + Path C | YES | Net-new |
| `ManagedSlice[T]` internal type + Path C | YES | Net-new (per Q3 in-scope) |
| `ref T` user-facing API | YES | Net-new (Path C) |
| `string` / `seq[T]` user-facing API | YES | Net-new (Path C) |
| Tier 1 sync iterators | YES | Net-new (~30 lines per queue) |
| chronos adapter (Tier 3) | YES | Net-new (optional dep, `-d:lockfreeChronos`) |
| mm:none support + drain helpers | YES | Net-new (per CRITICAL #2) |
| Nimony first-class architecture | YES | Net-new (per Phase 1.6 reconciliation) |
| Typestate dual-API + RAII wrappers | YES | Net-new wrappers around lifted typestate machinery |
| Comprehensive CI matrix (17 jobs: 1 lint + 16 test; cell numbers 1-14 + 17-18 with 15-16 reserved) | YES | Per Section 6 (cell count updated 2026-06-06 per O4, O5 resolutions; nomenclature reconciled 2026-06-07 per Phase 4.6.4 fact-check) |
| Windows OS support (cell 17, MSVC + orc) | YES | Per Section 6 O4 resolution 2026-06-06 (scope expansion approved) |
| `nim cpp` C++ backend support (cell 18, orc on baseline lane) | YES | Per Section 6 O5 resolution 2026-06-06 (scope expansion approved) |
| Documentation IA rebuild | YES | Per T-DOCS-RETHINK (§7.1-7.3) |
| Migration docs (3 files) | YES | Net-new (§7.2) |
| Examples (8 .nim files) | YES | Net-new |
| Strict-LCRQ MPMC unbounded queue | YES | Already lives in the lockfreequeues integration tree (`src/lockfree/queue.nim:1616-1632`, CLOSED_BIT close-on-empty + DWCAS `tryClaim`/`tryPublish` on `LCRQCell[T] = Atomic[Pair[uint, T]]`); v0.1.0 ships it as lifted. The earlier "NO — stays committed-flag" framing was stale and is corrected per the 2026-06-06 §4.6.2 source verification (see §7.9.1 reconciliation note). |
| Tier 2 raw notify primitive | NO | Per Q6 + Phase 1.6 lock-in |
| `std/asyncdispatch` adapter | NO | Per Q6 lock-in (chronos-only async) |
| Other SMR strategies (Fraser EBR, hazard pointers, IBR, NBR) | NO | Future stubs only; comment-only reservations per §1 Q1.10-D |
| Rename + archive choreography | NO | Per CRITICAL #5 defer (§7.7) |
| `debra_plus.nim` (faithful Brown 2015 port) | NO | Name reserved; future work; provenance documented |
| Q-FAITHFUL D3/D7 backfill (sigsetjmp + hazard pointers) | NO | Documented as known scope in `internal/debra-plus-provenance.md` |
| Formal safety proof for memory bound | NO | Per `safety-argument.md` §7 — operator-policy-dependent |
| Other lock-free data structures (hashes, sets, skiplists, channels) | NO | Out of scope per axiomantic positioning |
| macOS x86_64 CI cell | NO | Per §6 O10 — v0.2 backlog (Windows ADDED per O4 2026-06-06; macOS x86_64 still excluded) |

### 7.9.1 Strict-LCRQ MPMC reconciliation note (2026-06-06)

Earlier drafts of §7.9 listed "Strict-LCRQ MPMC unbounded queue" as
**NO — stays committed-flag in v0.1.0**. Phase 4 source verification on
2026-06-06 (driven by the §4.6.2 predicate factoring task) revealed
that the lockfreequeues integration tree at `feat/v5.0.0-impl` HEAD
**already ships strict-LCRQ MPMC**:

- `src/lockfree/queue.nim:122` declares
  `const CLOSED_BIT* = 1'u shl (sizeof(uint) * 8 - 1)` (high-bit close
  sentinel per design §2.2).
- `src/lockfree/queue.nim:132` declares
  `type LCRQCell*[T] = Atomic[Pair[uint, T]]` (native double-word DWCAS
  cell per §2.1).
- `src/lockfree/queue.nim:1616-1632` implements the strict-LCRQ
  fast-path consumer claim with `prevConsumerIdx.compareExchange` +
  `tryClaim[T](seg.cells[mySlot], 0'u)` (two-tier coordination per §5.3).
- 4 consumer-side `(... and CLOSED_BIT) != 0` test sites at
  queue.nim:1258, 1568, 1656, 1711 are exactly the close-bit reads the
  §4.6 predicates replace.
- `grep -c CLOSED_BIT src/lockfree/bqueue.nim` returns **0**:
  bqueue.nim is the Vyukov bounded substrate and has no close-bit logic;
  the earlier "stays committed-flag" framing was not referring to
  bqueue.nim either.

The stale "NO" rows therefore reflect a pre-integration design
intention that the integration tree subsequently overtook. v0.1.0
**ships strict-LCRQ MPMC** as lifted; the §4.6 predicate refactor
replaces the 4 inline close-bit literals in queue.nim with named
Family-B (LCRQ-integration) predicates. The bounded-Vyukov family (§4.6.2
Family A) is a placeholder for any future close-on-empty extension to
the bounded substrate; it has zero current call sites.

Downstream consequences of this correction:

- §1 module-layout comment for `queue.nim` already correctly said
  "unbounded: strict-LCRQ MPMC + legacy MPSC/SPMC/SPSC" — no change.
- §1 documentation IA: `guide/queues/strict-lcrq-mpmc.md` description
  updated to drop the "committed-flag form pending strict-LCRQ rework"
  clause; the page now documents the shipped strict-LCRQ form.
- §4.5.2 (per-arm pop-clears table) row for "Unbounded MPMC" still
  carries a legacy parenthetical referring to the committed-flag
  arm's head-CAS publish protocol. The shipped substrate is
  strict-LCRQ (DWCAS publish + close-bit), so that parenthetical is
  out-of-date in *describing the mechanism*, but the pop-clears
  regression test (T-VERIFY-POP-CLEARS.unbounded-mpmc) still
  correctly locks in the `move(seg.data[mySlot])` observable
  behavior. The Phase 4 §4.5.2 update is tracked separately under
  T-DOCS-RETHINK.d, not in this Phase 2.4 reconciliation.

---

## 7.10 Phase 2 design completion criteria

### 7.10.1 Phase 1.6 CRITICAL devil's-advocate dispositions

The Phase 1.6 devil's advocate red-team produced 5 CRITICAL findings.
Each is resolved by a specific section of this design doc; the table
below is the canonical traceability map (per design-review-2026-06-06
finding H1).

| CRITICAL # | Topic | Resolving section(s) | Disposition |
|---|---|---|---|
| #1 | Path C `when T is ref:` composition matrix — 25 ref-of-X shapes need explicit ACCEPT/REJECT | §2.5 (25-row matrix), §2.6 (admit rules), §2.7 (reject rules) | RESOLVED — matrix is concrete; every row carries an ACCEPT or REJECT verdict |
| #2 | mm:none drain contract — queue is pure bit transport; user owns per-item drain | §1.9 (1-line summary), §2.8 (full spec), §4.2.1 mm:none row (`discard` for all ops), §4.8 (drain helpers), §5.7.3 (mm:none strict drain contract) | RESOLVED — four sections cross-reference the same `discard`-on-no-op contract; §5.7 ships `destroyAndDrain` as the strict-contract user-facing API |
| #3 | No autonomous scope cuts — operator standing rule against pre-baked contingency-cut-order tables | §7.6 (Scope-cut contingency), this section §7.10 (no autonomous Phase 2 completion criteria that pre-bake cuts) | RESOLVED — §7.6 explicitly records the operator standing rule (`feedback_no_autonomous_scope_cuts`) and refuses to ship a cut-order list; cuts surface via AskUserQuestion at the point of blocker |
| #4 | chronos hybrid soft-dep — auto-detect via `compiles do: import chronos` OR opt-in via `-d:lockfreeChronos`, never a hard `requires` | §1.5 (chronos soft-dep section), §5.6 (the hybrid pattern), §6.3 cell 12 (chronos CI cell exercises the gate) | RESOLVED — three sections repeat the same `when defined(lockfreeChronos) or (compiles do: import chronos):` predicate; chronos is NOT in `lockfree.nimble`'s `requires` |
| #5 | Publication path / rename / archive choreography — must NOT be designed in Phase 2 (operator-policy decision, post-v0.1.0) | §1.2 (rename note, deferred), §7.7 (Rename and publication path) | RESOLVED — §7.7 explicitly defers the rename choreography to a post-v0.1.0 session; v0.1.0 ships in `lockfree-temp`, design captures only the CI-release-job structure + nimble metadata shape (not the rename itself) |

### 7.10.2 Completion checklist

Phase 2 design synthesis is complete when **all** the following hold:

- [x] All 7 design sections drafted in
      `docs/internal/design-sections/`:
      - [x] §1 Architecture & module layout (511 lines)
      - [x] §2 Type system & payload types (720 lines)
      - [x] §3 SMR architecture & nebr (1126 lines)
      - [x] §4 MM compat shim & cell layouts (1275 lines)
      - [x] §5 API surfaces (820 lines)
      - [x] §6 CI matrix & Nimony plan (463 lines)
      - [x] §7 Docs IA & risks (this file)
- [x] `safety-argument.md` drafted (529 lines)
- [x] Q-FAITHFUL resolved (artifact:
      `internal/debra-plus-provenance.md`)
- [x] Q-DWCAS resolved (artifact:
      `internal/q-dwcas-investigation.md`; matrix retains current
      single-CAS form for v0.1.0)
- [x] All CRITICAL Phase 1.6 devil's advocate findings addressed (see
      §7.10.1 disposition table: CRITICAL #1 → §2.5-2.7; CRITICAL #2 →
      §2.8 + §4.2.1 + §4.8 + §5.7.3; CRITICAL #3 → §7.6 no-autonomous-
      scope-cuts; CRITICAL #4 → §1.5 + §5.6 + §6.3 chronos hybrid;
      CRITICAL #5 → §7.7 publication-path deferral)
- [x] All open questions consolidated for Phase 2.2 + 2.5 review (§7.4,
      45 unique OQs across 4 categories)
- [ ] **Phase 2.4.5 coherence audit gate** — design vs handoff
      alignment confirmed (pending; Task #50)
- [ ] **Phase 2.2 design-doc review** — operator/reviewer walk-through
      with OQ resolution (pending)
- [ ] **Phase 2.5 fact-check / assumption verification** — codebase
      spot-checks on category-B OQs (pending; Task #49)

When the three pending boxes are checked, Phase 2 transitions to Phase
3 (implementation plan covering T1-T17, T-INTEGRATE.a-.f,
T-DOCS-RETHINK.a-.h, T-NIMONY-PORT, T-CI-*, T-EXAMPLES,
T-MIGRATION-DOCS, T-RELEASE — per §7.8).

---

## 7.11 Cross-references

- Handoff brief:
  `/Users/eek/.local/spellbook/handoffs/2026-06-05-elijahr-lockfree-consolidation.md`
- Sections 1-6:
  `/Users/eek/Development/lockfree/docs/internal/design-sections/01..06-*.md`
- Safety argument:
  `/Users/eek/Development/lockfree/docs/internal/safety-argument.md`
- Q-FAITHFUL artifact (planned):
  `docs/internal/debra-plus-provenance.md`
- Q-DWCAS artifact (planned):
  `docs/internal/q-dwcas-investigation.md`
- Iterator/async scoping (planned):
  `docs/internal/iterator-async-scoping.md`
- Operator preferences referenced:
  `feedback_no_direct_tagging`,
  `feedback_no_autonomous_scope_cuts`,
  `feedback_micro_dispatch_rhythm`,
  `feedback_thermal_throttling_validation`,
  `feedback_verify_subagent_claims_against_source`,
  `feedback_develop_for_scope_expansions`
- Project memory referenced:
  `project_two_publication_protocols`,
  `project_typestates_0.10.0_ast_verifier`,
  `project_typestates_0.7.0_match_generic_context_bug`,
  `project_nph_version_banner_unreliable`,
  `project_nimble_compiler_pkg_broken_include`,
  `project_nimble_install_nim_no_longer_compiler_source`

---

End of Section 7. End of Phase 2 design synthesis.
