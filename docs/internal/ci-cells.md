# CI cells — purpose, curated subsets, and update conditions

**Companion to:** `.github/workflows/ci.yml`
**Design cite:** `docs/internal/2026-06-05-umbrella-v0.1.0-design.md` §6
**Impl-plan cite:** `docs/internal/2026-06-06-umbrella-v0.1.0-impl-plan.md`
  T-CI-MATRIX (PG-10), T-CI-VALGRIND-HELGRIND, T-CI-CHRONOS, T-CI-NIMONY

This doc fills the gap between the YAML's per-cell comments (terse,
deployment-readable) and the design doc's per-cell rationale (verbose,
narrative). The four cells documented here — 8, 9, 12, 14 — diverged
substantially from the standard 18-cell matrix shape and were authored
out-of-band of T-CI-MATRIX. See `2026-06-05-umbrella-v0.1.0-design.md`
§6.6 / §6.7 / §6.8 for the design intent.

The 14 standard matrix cells (1-7, 10, 11, 13, 17, 18) are documented
inline in `ci.yml`'s `test:` job comments — they're cookie-cutter and
don't warrant prose.

---

## Cell 8 — Valgrind memcheck (curated subset)

**Purpose.** Catch use-after-free and definite/possible leaks that
ASAN (cell 7) may miss. Valgrind's dynamic binary translation sees
memory ops the compiler may have optimized away from ASAN's compile-time
instrumentation. Defense-in-depth on the highest-risk surface: the
queue cell-array lifecycle + nebr retire path.

**Why a subset, not the full suite.** Memcheck slows each test ~10-30×
(§6.6.2). A full-suite run would consume ~10× the cell-1 baseline,
blowing the §6.4 GREEN target (≤20 min). Cell-budget per §6.6.3:
~25 min worst-case for this subset, which is YELLOW per §6.4 — the
operator may move this cell to nightly after the wall-clock baseline.

**Curated subset (5 files):**

| File | Why in the subset |
|------|-------------------|
| `tests/t_drain.nim` | Bounded-queue drain helper — exercises bulk cell-array tear-down (the lifecycle hotspot most prone to definite-leaks). |
| `tests/t_destructor_walk.nim` | Explicit destructor coverage across MMs — catches per-arm leak regressions in `=destroy` paths. |
| `tests/t_queue_bounded_spsc.nim` | SPSC cardinality coverage (cheap, fast, catches simple regressions). |
| `tests/t_queue_bounded_mpsc.nim` | MPSC cardinality coverage. |
| `tests/t_queue_bounded_mpmc.nim` | MPMC cardinality coverage (the most cell-array-intensive). |

**Compile flags per §6.6.2:** `--debugger:native --opt:none -d:useMalloc`.
The `useMalloc` flag is load-bearing: without it Nim's GC-aware
allocator bypasses Valgrind's tracking and memcheck mis-classifies
legitimate allocations as leaks.

**Test invocation pattern** (per file in the subset):

```bash
nim c --threads:on --mm:orc --debugger:native --opt:none \
      -d:useMalloc -o:<bin> <test.nim>
valgrind --error-exitcode=1 --leak-check=full \
         --show-leak-kinds=all \
         --errors-for-leak-kinds=definite,possible \
         --track-origins=yes <bin>
```

**Gating policy.** Per-PR if the §6.4 wall-clock baseline classifies the
cell GREEN; otherwise per §6 O6 the operator decides per-PR vs nightly.

---

## Cell 9 — Helgrind race detector (curated subset)

**Purpose.** Lockset-based race detection. Catches a *different* class
of races than TSAN (cell 6): Helgrind's lockset analysis flags lock
acquisition ordering anomalies and pthreads-API misuse that TSAN's
happens-before tracking can miss. Per §6.6.1, this is defense-in-depth,
not redundancy.

**Why a subset, not the full suite.** Helgrind slows each test ~30-50×
(§6.6.2). A full-suite run would be far over the GREEN target. Per
§6.6.3: ~25 min worst-case for this subset, also YELLOW.

**Curated subset (3 files):**

| File | Why in the subset |
|------|-------------------|
| `tests/t_queue_bounded_mpmc.nim` | MPMC stress on the bounded path — where the bulk of CAS-based race surface lives. |
| `tests/t_unbounded_mpmc.nim` | MPMC stress on the unbounded path — different cell-allocation strategy, different race surface. |
| `tests/smr/debra-legacy/t_nebr_retire.nim` | DEBRA / nebr retire path — the highest-risk SMR race surface. Cross-thread retire-then-reclaim is the canonical lock-free correctness hazard. |

**Subset rationale.** MPMC + nebr retire is where races are likeliest to
materialize. SPSC/MPSC under Helgrind would be expensive and low-yield
(those cardinalities have one writer or one reader, so the lockset
surface is thin).

**Test invocation pattern** (per file in the subset):

```bash
nim c --threads:on --mm:orc --debugger:native --opt:none \
      -d:useMalloc -o:<bin> <test.nim>
valgrind --tool=helgrind --error-exitcode=1 <bin>
```

**Gating policy.** Same as cell 8 — per-PR if §6.4 GREEN, otherwise
per §6 O6.

---

## Cell 12 — chronos Tier 3 adapter (`-d:lockfreeChronos`)

**Purpose.** Validate the §5.6 Tier 3 chronos adapter
(`AsyncQueue` / `AsyncBQueue` + `AsyncEvent`-based wakeup) end-to-end.
Per CRITICAL #4 the hybrid sync/async pattern (queue + chronos
`AsyncEvent`) is verified *only* here; without cell 12 the chronos
adapter can rot silently between releases.

**Why dedicated.** chronos is the only non-stdlib dependency in the
public API surface (§5). It is NOT in `lockfree.nimble`'s `requires`
(per CRITICAL #4 — the Tier 3 adapter must remain optional). Cell 12
installs chronos at the CI step with a pinned version range and
exercises the adapter under `-d:lockfreeChronos`.

**Test entry point:** `tests/t_chronos.nim` (the §5.6 adapter test —
exercises acceptance cells (a) `chronos installed, no `-d:lockfreeChronos`,
auto-detect` and (b) `chronos installed, `-d:lockfreeChronos` set,
opt-in path`).

**Version pin per R3:** `chronos@>= 4.0.0`. Lower bound is the chronos
v4 API surface required by the §5.6 adapter. No upper bound — chronos
releases are expected to remain backwards-compatible; if a future
chronos breaks the adapter, the version range is bumped here AND the
adapter is rev'd in lockstep.

**Test invocation:**

```bash
nim c --threads:on --mm:arc -d:lockfreeChronos -r tests/t_chronos.nim
```

**Gating policy.** Per-PR, gating. PR fails on adapter regression. No
`continue-on-error` — this is a Tier 3 adapter the library publicly
exports; it must not rot.

---

## Cell 14 — nimony aufbruch (informational)

**Purpose.** Validate that the §6.7 "first-class nimony architecture"
(real `when defined(nimony):` arms in atomics shim, smr/nebr,
ManagedRef) actually compiles and runs under nimony. Per §6.7.4 a
documented set of partial-port gaps is acceptable (e.g., `getStackTrace`
not yet supported); the cell exists to surface the boundary between
"working under nimony" and "intentionally guarded".

**Why `continue-on-error: true`.** Per R4 and the user's policy
(`feedback_no_autonomous_scope_cuts` does NOT apply here — this is a
documented partial-port acceptance per CRITICAL #5, not a scope cut):
nimony is pre-release and its upstream churn must never block a PR. A
sustained red on this cell escalates per the §6.7.5 watch policy
(sustained red for 4+ weeks = v0.2 blocker).

**Pinned nimony commit SHA (§6 O3):**
`751121f9ee0fc7584015fc03f5326fe521029d84` — `nim-lang/nimony@master`
HEAD observed 2026-06-06. The `NIMONY_SHA` env var in cell 14 carries
this pin. Bumping the SHA is the documented mechanism for absorbing
nimony upstream fixes; the cache key (see below) is keyed on this SHA
so a bump cleanly invalidates the cache.

**Cache (§6 O9):** `actions/cache@v4` keyed on `NIMONY_SHA`. Cache hit
rate expectation: **~95% steady-state** (cache misses only on SHA bump
or weekly GitHub Actions cache eviction). Cold rebuild ~10 min; cache
hit reduces cell wall-clock from ~30 min to ~20 min per §6 O9.

**Test entry point:** `tests/nimony/t_nimony_arc_baseline.nim`. This is
the impl-plan T-TEST-NIMONY arc-baseline smoke test — it exercises
nimony's `arc` MM as a baseline before broader coverage rolls in.

**Compilation mode (aufbruch).** `-d:nimony` activates the
nimony-conditional code paths. The cell uses `--mm:arc` per the task
spec (the broader §6.7.3 cell uses `atomicArc` for ManagedRef /
ManagedSlice coverage; the arc-baseline smoke test specifically
validates arc semantics under nimony).

**Test invocation:**

```bash
nim c --threads:on --mm:arc -d:nimony -r tests/nimony/t_nimony_arc_baseline.nim
```

**Gating policy.** Informational. `continue-on-error: true` at the job
level; status surfaces via the §6.7.5 nimony badge.

---

## Update conditions

Re-evaluate the curated subsets for cells 8 + 9 when ANY of:

1. **Wall-clock baseline.** §6.4.2 baseline run reports cell 8 or 9 in
   the YELLOW or RED band. Either narrow the subset (drop the lowest-
   yield file) OR move the cell to nightly per §6 O6.
2. **New cardinality.** A new queue cardinality is added to the public
   API surface. Add it to the cell 8 subset (cardinality coverage is
   load-bearing).
3. **New lifecycle hotspot.** A new shared-state lifecycle path lands
   (e.g., a new SMR mechanism, a new ref/slice container). Add a
   representative test to whichever of cells 8 / 9 is more diagnostic
   for the new path.
4. **Subset regression bypassed real bug.** A bug surfaces in production
   (or in another CI cell) that cell 8 or 9 *should* have caught but
   didn't. Add a regression test to the relevant subset.

Re-evaluate cell 12 when:

1. chronos releases a major version. Bump the `>= 4.0.0` lower bound
   if the new major is incompatible with the §5.6 adapter; otherwise
   leave the range open.
2. The §5.6 adapter surface grows (new adapter shape, new sync
   primitive). Add a corresponding test file to the invocation.

Re-evaluate cell 14 (nimony SHA bump policy):

1. **Sustained green for 12+ weeks** at the pinned SHA → bump to a
   newer SHA (or consider promoting nimony to gating per §6.7.5).
2. **Sustained red for 4+ weeks** at the pinned SHA → either bump
   forward (if upstream has fixed the issue) or escalate to a v0.2
   blocker per §6.7.5.
3. **Cache hit rate degrades** below ~85% steady-state → investigate
   GitHub Actions cache eviction policy; do NOT raise the eviction
   pressure by adding unrelated entries to the same cache key.

---

## Why this lives in `docs/internal/` and not AGENTS.md §3

AGENTS.md §3 ("Build, test, and run") is operator-facing — it tells a
human or agent how to invoke local tests. CI cell internals (curated
subsets, valgrind flag choices, nimony SHA pin policy) are
deployment-config, not local-workflow. Folding this content into
AGENTS.md §3 would either bloat the local-workflow section or hide
deployment-config behind a "for CI maintainers" sub-heading. A
dedicated `ci-cells.md` is the right altitude.
