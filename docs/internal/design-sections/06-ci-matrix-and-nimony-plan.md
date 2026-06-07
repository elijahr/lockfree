# Section 6: CI Matrix and Nimony Plan

This section specifies the **GitHub Actions CI surface** for the consolidated `lockfree` library (v0.1.0 post-rename, formerly lockfreequeues v5.0.0): the concrete matrix of jobs, the smart-consolidation rationale that limits the cell count without sacrificing coverage, the sanitizer / Valgrind / Helgrind strategy, the nimony first-class cell (with `continue-on-error`), the chronos adapter cell, the release and docs workflows, the bot configuration, and the wall-clock baseline measurement protocol that gates the operator's "≤ 20 minutes end-to-end" target.

It is the **operational companion** to Sections 1–5. Where Sections 1–4 specify the implementation surface and Section 5 specifies the public API, Section 6 specifies *what the CI must exercise across that surface* and *what runs on every PR before merge*. Section 7 covers the docs IA and migration story; Section 6 only touches docs CI where it integrates with the existing mkdocs pipeline.

Cross-references throughout:
- `§1.x` … `§5.x` = the prior design sections in this directory.
- `handoff:QN` = research question N in the 2026-06-05 consolidation handoff brief at `/Users/eek/.local/spellbook/handoffs/2026-06-05-elijahr-lockfree-consolidation.md`.
- `handoff:Phase 1.5 Q4 / Q5` = the operator's Phase 1.5 Batch 2 directives on CI scope.
- `handoff:Phase 1.6 nimony reconciliation` = the MAJOR finding that nimony is first-class in the architecture but `continue-on-error` in CI only.
- `lfq:build.yml` = `/Users/eek/Development/lockfree/.github/workflows/build.yml` (lockfreequeues v5.0.0 CI baseline).
- `debra:ci.yml` = `/Users/eek/Development/lockfree/imports/nim-debra/.github/workflows/ci.yml` (nim-debra v0.10.0 CI baseline).

The v5.0.0 / nim-debra v0.10.0 CI workflows are the **starting point**. v0.1.0 of the consolidated `lockfree` repo inherits their shape and merges them, with explicit additions (Valgrind, Helgrind, nimony, chronos, mm:none) and explicit consolidations (sanitizers via env flag, not duplicated jobs; one full-MM-sweep × one OS, plus one-MM-on-every-OS).

---

## 6.1 CI matrix design philosophy

### 6.1.1 Operator directive (handoff Phase 1.5 Q4)

Q4 in Phase 1.5 Batch 2 asked: "comprehensive matrix or smart consolidation?". Operator answer was **"comprehensive coverage with smart consolidation"**:

- **Comprehensive**: every MM lane (`orc`, `arc`, `refc`, `atomicArc`, plus the `mm:none` lock-in from CRITICAL #2) must be exercised; every OS target (Linux x86_64, Linux arm64, macOS arm64) must be exercised; every sanitizer (TSAN, ASAN) must be exercised; Valgrind + Helgrind must run on the baseline lane; `chronos` must compile end-to-end with `-d:lockfreeChronos`; `nimony` must be exercised as a first-class architectural target.

- **Smart consolidation** ("kill two birds with one CI run"): do **not** run every MM × every OS. The combinatorial sweep is `4 MMs × 3 OSes × 2 backends × 2 sanitizers = 48 cells` and would blow well past the 20-minute wall-clock target. Instead:
  - One OS (the baseline lane, `ubuntu-latest`) runs the **full MM sweep** (`orc`, `arc`, `refc`, `atomicArc`, `mm:none`).
  - The non-baseline OSes (`ubuntu-24.04-arm`, `macos-latest`) run **one MM** (`orc`, the default) — they cover the *runner-architecture* axis (arm64 LSE atomics, macOS arm64 / Apple Clang), not the *MM* axis.
  - **Sanitizers are env-flag toggles on the baseline lane**, not duplicated cells. This is the v5.0.0 `lfq:build.yml` pattern (lines 73-101: `sanitize-threads: 'yes'` / `sanitize-address: 'yes'` matrix columns toggle the same job's behavior).
  - Valgrind + Helgrind get their own jobs (they require apt-installs and dramatically different timeout budgets — folding them into the matrix would over-amplify cell count and runtime).

The rule of thumb: **each additional cell must justify itself with unique coverage no other cell provides**.

### 6.1.2 Wall-clock target (handoff Phase 1.6 MAJOR — NOT auto-resolved)

Operator's target: **≤ 20 minutes end-to-end on the GitHub Actions free tier**.

Per Phase 1.6 MAJOR disposition, this target is **NOT** confirmed feasible until a baseline measurement is taken. Phase 2 design (this section) MUST specify how to baseline-measure and MUST surface the result to the operator BEFORE committing the matrix shape. Per operator standing rule "no autonomous scope cuts" (memory: never-recommend-defer-to-followup; v5.0.0 wave thorough-over-speed contract), Phase 2 design cannot autonomously cut coverage to fit a 20-minute budget if the baseline shows the comprehensive matrix overruns it. The choice between "extend the budget" and "cut coverage" is the operator's, not the design's.

§6.4 specifies the baseline measurement protocol in concrete detail.

### 6.1.3 No-stones-unturned (handoff Phase 1.5 Q4 lock-in)

Every MM lane, every OS target, every sanitizer, every Tier-1/Tier-3 integration point (chronos adapter, ManagedRef / ManagedSlice round-trip) must be touched **somewhere** in the matrix. Smart consolidation collapses combinatorial *overlap*, not coverage. If a cell is the only one exercising a capability and the operator has explicitly asked for that capability to be covered, it stays — even if it costs minutes.

---

## 6.2 Coverage requirements (must hit, somewhere)

The matrix must explicitly cover every cell in this checklist. The §6.3 enumeration cross-references each row back to one or more of these items.

| # | Coverage requirement | Source / Rationale |
|---|----------------------|--------------------|
| C1 | MM `orc` exercised on each OS | Default MM; runner-arch sweep. `lfq:build.yml` baseline. |
| C2 | MM `arc` exercised on at least one cell | Full-MM sweep, baseline lane. |
| C3 | MM `refc` exercised on at least one cell | Full-MM sweep, baseline lane. Legacy support contract. |
| C4 | MM `atomicArc` exercised on at least one cell | Full-MM sweep; required because Section 4 cell layouts diverge under `atomicArc` (§4.x). |
| C5 | MM `none` exercised on at least one cell | CRITICAL #2 lock-in. `--mm:none` is the embedded / OS-kernel use case; if it ever stops compiling we want to know in CI, not in user bug reports. |
| C6 | Linux x86_64 exercised | `ubuntu-latest`. Baseline lane. |
| C7 | Linux arm64 exercised | `ubuntu-24.04-arm` (Graviton2-class; LSE `caspal` atomics path, mirroring `debra:ci.yml` line 48). |
| C8 | macOS arm64 exercised | `macos-latest` (Apple Silicon; Apple Clang; `ldaxp` / `stlxp` LL/SC pair, or LSE `casp`). |
| C9 | C backend `gcc` on Linux | Default. `lfq:build.yml` line 126 (`apt install clang` available but gcc is implicit default). |
| C10 | C backend `clang` on macOS | Apple Clang is the default toolchain on `macos-latest`. |
| C11 | TSAN on baseline lane | `lfq:build.yml` `sanitize-threads: 'yes'` (env-flag pattern). TSAN slowdown ~5-15×; runs only on `ubuntu-latest / orc` per current shape. |
| C12 | ASAN on baseline lane | `lfq:build.yml` `sanitize-address: 'yes'` (env-flag pattern). |
| C13 | Valgrind memcheck on baseline lane | NEW (not in `lfq:build.yml` or `debra:ci.yml` per handoff Q8). Catches lifecycle leaks Section 3 / Section 4 might regress on. |
| C14 | Helgrind race detection on baseline lane | NEW. Alternative race-detector to TSAN; orthogonal coverage (different algorithm, different false-positive profile). Runs a *representative subset* of tests, not the full suite (Helgrind is ~30-50× slower than baseline). |
| C15 | Nim devel cell on baseline lane | `lfq:build.yml` lines 86-101 pattern (`continue-on-error: true` for devel rows). Early-warning for upstream Nim API drift. |
| C16 | Nimony cell on baseline lane | NEW (handoff Phase 1.6 reconciliation). First-class architectural target; `continue-on-error: true` because nimony is pre-release. |
| C17 | chronos cell on baseline lane | NEW. Installs `chronos` and compiles with `-d:lockfreeChronos`, verifying the Tier 3 adapter (§5 chronos adapter section). |
| C18 | Lint / typestates verify | `lfq:build.yml` lines 26-54 + `debra:ci.yml` lines 13-34. Runs once on `ubuntu-latest`. |
| C19 | Windows OS coverage (per O4 resolution 2026-06-06) | NEW. Windows + MSVC backend exercises the Windows arm of the atomics shim (`_InterlockedCompareExchange128` per existing nim-debra `atomics.nim`). Cell 17. |
| C20 | `nim cpp` backend coverage (per O5 resolution 2026-06-06) | NEW. C++ backend coverage verifies the queue surface compiles under `nim cpp` (catches C-only constructs that would silently break C++ users). Cell 18. |

Items C1-C20 together define "comprehensive coverage" in the operator's sense. §6.3 below enumerates the concrete cells that satisfy them.

---

## 6.3 Proposed concrete matrix (FULL ENUMERATION)

The matrix has **17 concrete cells** plus a lint job (18 jobs total) after the O4 + O5 resolutions on 2026-06-06 added Windows (cell 17) and `nim cpp` (cell 18). Each row carries the coverage-requirement IDs it satisfies in the `Covers` column.

| # | OS | Nim ver | MM | Backend | Sanitizer env | Extras | continue-on-error | Covers | Purpose |
|---|----|---------|----|---------|---------------|--------|-------------------|--------|---------|
| L | ubuntu-latest | stable | n/a | n/a | none | typestates verify, nph --check | false | C18 | **Lint** lane: typestates pragma audit + nph format check. |
| 1 | ubuntu-latest | stable | orc | gcc | none | (none) | false | C1, C6, C9 | **Baseline lane**: orc + gcc + Linux x86_64. The reference cell every other cell is "deviating from". |
| 2 | ubuntu-latest | stable | arc | gcc | none | (none) | false | C2 | **arc** coverage on baseline lane. |
| 3 | ubuntu-latest | stable | refc | gcc | none | (none) | false | C3 | **refc** coverage on baseline lane. Legacy MM. |
| 4 | ubuntu-latest | stable | atomicArc | gcc | none | (none) | false | C4 | **atomicArc** coverage on baseline lane. Section 4 cell-layout divergence path. |
| 5 | ubuntu-latest | stable | none | gcc | none | (none) | false | C5 | **mm:none** coverage. CRITICAL #2 lock-in. |
| 6 | ubuntu-latest | stable | orc | gcc | TSAN=yes | (none) | false | C11 | **TSAN** on baseline lane. `lfq:build.yml` env-flag pattern. |
| 7 | ubuntu-latest | stable | orc | gcc | ASAN=yes | (none) | false | C12 | **ASAN** on baseline lane. |
| 8 | ubuntu-latest | stable | orc | gcc | none | Valgrind memcheck (representative test subset) | false | C13 | **Valgrind** memcheck. Apt-installs `valgrind`; runs a curated subset (see §6.6). |
| 9 | ubuntu-latest | stable | orc | gcc | none | Helgrind (representative test subset) | false | C14 | **Helgrind** race detector. Subset, same job-shape as Valgrind cell. |
| 10 | ubuntu-24.04-arm | stable | orc | gcc | none | (none) | false | C1, C7 | **arm64** atomics path (LSE `caspal` / `casp`). Mirrors `debra:ci.yml` line 48. |
| 11 | macos-latest | stable | orc | clang | none | (none) | false | C1, C8, C10 | **macOS arm64 / Apple Clang**. Per handoff Q8: no macOS x86_64 (Rosetta cell from `debra:ci.yml` lines 312-427 is debra-specific DWCAS validation; not needed for lockfree's atomics surface). |
| 12 | ubuntu-latest | stable | orc | gcc | none | `nimble install chronos`, `-d:lockfreeChronos`, run `tests/t_chronos_*.nim` | false | C17 | **chronos** Tier 3 adapter verification. |
| 13 | ubuntu-latest | devel | orc | gcc | none | (none) | true | C15 | **Nim devel** API-drift early warning. `continue-on-error: true` per `lfq:build.yml` lines 86-101 pattern. |
| 14 | ubuntu-latest | (aufbruch nimony) | atomicArc | gcc | none | nimony build from source (~10 min), full test suite under nimony | **true** | C16 | **Nimony first-class** cell. The architecture is nimony-aware (Sections 3, 4); CI is `continue-on-error` because nimony itself is pre-release (handoff Q2). |
| 17 | windows-latest | stable | orc | MSVC (default `cc`) | none | (none; sanitizers don't run cleanly on Windows) | false | C19 | **Windows baseline** lane (per O4 resolution 2026-06-06). Exercises the Windows arm of the atomics shim: DWCAS via `_InterlockedCompareExchange128` (already present in nim-debra `atomics.nim`). Verifies the Windows arm of the MM compat shim compiles + runs under `orc`. Sanitizers (TSAN/ASAN/Valgrind/Helgrind) deliberately omitted — they do not run cleanly on Windows. Wall-clock estimate TBD via T-CI-WALLCLOCK-BASELINE. |
| 18 | ubuntu-latest | stable | orc | nim cpp (C++ backend) | none | (none) | false | C20 | **`nim cpp` backend coverage** (per O5 resolution 2026-06-06). Same source tree compiled with `nim cpp` instead of `nim c`. Catches C-only constructs (e.g. C99 designated initializers, restrict qualifiers) that would silently break C++ users of the queue surface. Wall-clock estimate TBD via T-CI-WALLCLOCK-BASELINE; expected ~baseline since the C++ backend's compile-time delta is modest. |

**Cell count: 17 actual jobs (1 lint + 16 test cells); 18 cell numbers with 15 and 16 reserved.** Cell numbering runs 1-14 + 17-18 — cells 15 and 16 are reserved slots not currently assigned a workload (preserved for future MM-lane expansions). Cells 17 (Windows + MSVC) and 18 (`nim cpp` backend) were added by the O4 + O5 resolutions on 2026-06-06; the original §6.3 enumeration shipped with 14 cells before that scope expansion. The earlier "17 test cells / 18 jobs" framing in pre-2026-06-07 drafts conflated the cell-number range (1-18) with the actual job count (17) and was corrected per Phase 4.6.4 fact-check.

### 6.3.1 Per-cell rationale (why each cell exists, why smaller alternatives don't suffice)

**Cell 1 (baseline).** This is the reference. Every other cell is documented as a *delta* from cell 1: cell 2 changes MM, cell 6 adds TSAN, cell 10 changes OS+arch, etc. Without cell 1 the deltas have no anchor; with it, a regression localizes immediately. Cannot be subsumed.

**Cells 2-5 (full MM sweep on baseline lane).** A single "matrix MM cell" approach (where the MM is matrixed across the same job-shape) is the smallest viable representation; running all four MMs (orc/arc/refc/atomicArc) plus the lock-in (`mm:none`) on **only** the baseline lane is the smart-consolidation move. Spreading the MM sweep across OSes (e.g. arc-on-linux + refc-on-mac) creates one-off cells that don't reproduce locally and obscure the OS-axis vs MM-axis distinction. Keeping the MM sweep on one OS keeps "what does MM X look like" easy to read.

**Cell 5 (mm:none).** CRITICAL #2 mandates `--mm:none` compile (Section 4 documents the GC-free path). The cell only needs to compile + run the smoke-test subset; it does NOT need to run on every OS. One cell is the smart-consolidated form.

**Cell 6 (TSAN).** TSAN catches the data-race class of bugs that `--mm:orc` + the full test suite would miss. Runs *only* on `orc` because the queue's lock-free invariants are MM-orthogonal at the atomics level, and adding TSAN × 4 MMs is 4× wall-clock for ~0× additional unique findings. Slowdown is 5-15× (handoff Q13 historical data); §6.5 specifies the test-subset strategy.

**Cell 7 (ASAN).** Catches use-after-free, double-free, heap-OOB. Like TSAN, gated to `orc` only.

**Cell 8 (Valgrind memcheck).** Independent leak / use-after-free check. Orthogonal to ASAN (different instrumentation: Valgrind uses dynamic binary translation, ASAN uses compile-time instrumentation). Catches things ASAN misses, especially in Nim-runtime code paths and FFI boundaries.

**Cell 9 (Helgrind).** Orthogonal race detector to TSAN. Different algorithm (Helgrind uses a happens-before model with lockset analysis), different false-positive profile. Phase 1 Q9 confirmed both Valgrind + Helgrind are absent from the current `lfq:build.yml` and `debra:ci.yml` workflows — adding them is *new work*, justified by the lock-free invariants Section 3 / nebr promises.

**Cell 10 (arm64).** Linux arm64 exercises the LSE atomics path (`caspal`, `casp`). Critical because Section 3's atomic shim (`§3.x`) emits different code on arm64 than x86_64, and the `mno-outline-atomics` flag (`debra:ci.yml` line 88) ensures inline atomics rather than libatomic fallback. Cannot be subsumed by macOS-arm64 (cell 11): different toolchain (gcc vs Apple Clang), different libc, different syscall ABI.

**Cell 11 (macOS arm64).** Apple Silicon + Apple Clang. Catches macOS-specific footguns (Mach-O linker, weak-symbol behavior, Apple Clang's slightly divergent `__atomic_*` lowering). Cannot be subsumed by linux/arm64: different toolchain + different OS.

**Cell 12 (chronos).** §5's `lockfree/chronos` Tier 3 adapter is the only place the public API depends on a non-stdlib package. CRITICAL #4 (hybrid sync/async pattern) is verified end-to-end only here. Without this cell, the chronos adapter could silently rot — `nimble install` works locally, no one notices, breaks at user-discovery time. One cell, on baseline lane (chronos is platform-independent), runs `tests/t_chronos_*.nim` (the existing v5.0.0 chronos integration tests; handoff Q3).

**Cell 13 (Nim devel).** `continue-on-error: true` matches the `lfq:build.yml` pattern (lines 86-101 commentary: "Nim devel is informational — it surfaces upstream breakage before it lands in stable but does NOT gate merge"). Without this cell, an upstream Nim change can break us a week before stable release with no warning.

**Cell 17 (Windows + MSVC).** Added per O4 resolution 2026-06-06 (operator-approved scope expansion). Exercises the Windows arm of the atomics shim end-to-end on real Windows hardware. The DWCAS substrate already carries a `_InterlockedCompareExchange128` arm (inherited from nim-debra `atomics.nim`); without a Windows runner cell, that arm has no CI coverage and silently drifts. MSVC's cl.exe is the default Nim `cc` on Windows; the cell does not pin a backend flag. Sanitizers are deliberately omitted: TSAN, ASAN, Valgrind, and Helgrind do not run cleanly on Windows under the Nim toolchain (TSAN/ASAN require clang-cl + special instrumentation that the default `setup-nim-action` does not provide; Valgrind/Helgrind don't run on Windows at all). The Windows arm runs `orc` only — the same smart-consolidation rationale as cells 10 and 11. If wall-clock-baseline shows the Windows cell is excessively slow (Windows GitHub Actions runners are historically 1.5-2× slower than Linux), the operator decides whether to keep the full test suite or move to a smoke-test subset; no autonomous trim.

**Cell 18 (`nim cpp`).** Added per O5 resolution 2026-06-06 (operator-approved scope expansion). The queue surface, nebr, ManagedRef, and ManagedSlice all target the Nim C backend by default. `nim cpp` is a supported Nim backend that emits C++ code; users who embed the queues in C++-using Nim projects (e.g. games, audio engines linking against C++ libraries) compile via `nim cpp`. Without a CI cell, C-only constructs (designated-initializer braces, certain pragma forms, restrict-qualified pointers, identifier collisions with C++ keywords like `class`/`template`) silently break those users. The cell compiles + runs the standard test suite under `nim cpp` on the baseline lane. Wall-clock delta vs cell 1 is small (C++ compile is modestly slower than C; runtime is identical because the emitted code is functionally equivalent). Section 4's MM compat shim is expected to compile under `nim cpp` without modification because the C atomics builtins (`__atomic_*`) are available in C++ as well; any C-specific construct surfaced by this cell is flagged as a Phase 4 OQ.

**Cell 14 (nimony).** **The architectural reconciliation cell** (handoff Phase 1.6 MAJOR). Sections 3, 4 specify `when defined(nimony)` arms in atomics / smr / nebr / ManagedRef / ManagedSlice. CI verifies those arms exist and compile under aufbruch mode. `continue-on-error: true` because nimony is pre-release and partial-port behavior is expected: per handoff Q4, ManagedRef / ManagedSlice under `atomicArc`-only may not fully port until nimony's ref semantics catch up. The cell's *purpose* is the long-run watch: if nimony ever stops compiling our code, we see it on the next PR. Discussed in detail in §6.7.

### 6.3.2 What this matrix deliberately does NOT include (and why)

- **Windows IS included as of O4 resolution 2026-06-06.** Cell 17 covers Windows + MSVC + orc. Earlier drafts of §6.3 deferred Windows to v0.2 backlog citing handoff Q8 (neither lockfreequeues v5.0.0 nor nim-debra carries Windows in `lfq:build.yml`); the operator decision on 2026-06-06 (per O4) reversed that deferral and added Windows to v0.1.0 scope. See §6.13 O4 disposition.
- **No macOS x86_64.** `debra:ci.yml` lines 312-427 cross-compile via Apple Clang + Rosetta to validate `cmpxchg16b` emit on x86_64-darwin. That's a debra DWCAS-objdump regression-gate concern, not a queues concern. The `lockfree` queue surface does not use DWCAS directly (debra wraps it for SMR retirement); macOS x86_64 coverage of the queue API would duplicate cell 1's x86_64 + cell 11's macOS clang coverage with no unique findings. Still excluded per O10 (RESOLVED — still excluded; v0.2 backlog).
- **`nim cpp` backend axis IS included as of O5 resolution 2026-06-06.** Cell 18 covers `nim cpp` on the baseline lane (orc, ubuntu-latest). Earlier drafts deferred `nim cpp` to v0.2 backlog (citing the fact that lockfreequeues v5.0.0 exercises only `c` while debra's `cpp` cells exist for DWCAS-`__int128` ABI reasons); the operator decision on 2026-06-06 (per O5) reversed that deferral and added one `nim cpp` cell to v0.1.0 scope. See §6.13 O5 disposition. The matrix does NOT expand to a full `cpp`-on-every-MM cross-product; the smart-consolidation principle still applies (one cell catches the common-case regressions).
- **No MM × OS cross-product on non-baseline OSes.** Cells 10, 11, and 17 are `orc`-only. Spreading other MMs across OSes adds many more cells (4 MMs × 3 extra OSes = 12 cells) for marginal value — the MM-specific Nim runtime is OS-agnostic.

---

## 6.4 Wall-clock baseline measurement (MAJOR — Phase 1.6 not auto-resolved)

The operator's "≤ 20 minutes end-to-end" target is **a goal, not a confirmed budget**. Phase 2 implementation must baseline-measure before committing.

### 6.4.1 Why baseline first (not "design assumes feasible")

Per memory `feedback_validation_global_timeout`: multi-gate validation runs need wall-clock budgets, not just per-test timeouts. And per the operator's standing rule: "no autonomous scope cuts to fit a budget". If the baseline shows the 16-cell matrix takes 35 minutes, we surface 35 minutes — we do NOT silently drop Helgrind or the macOS cell to hit 20.

Apple Silicon thermal-throttling lessons (memory `feedback_thermal_throttling_validation`) apply to **local** benchmarks. GitHub Actions runners do not throttle the same way (shared-tenant cold-state per job), but the parallel-job billing model means *wall-clock* end-to-end (the longest cell) is what the operator's 20-minute target refers to — not aggregate CI minutes.

### 6.4.2 Measurement protocol

The baseline measurement runs once, after Phase 2 implementation drafts the workflow YAML, before the PR is opened against the consolidated repo. Steps:

1. **Implement the matrix from §6.3 in `.github/workflows/build.yml`** in a draft branch (NOT merged).
2. **Push to a CI-enabled branch and trigger the workflow.** Read the per-job duration from the GitHub Actions Checks UI (or `gh run view <run-id> --json jobs`).
3. **Identify the longest cell.** The wall-clock end-to-end is approximately `max(cell duration)`, modulo job-scheduling overhead (~30s per job; ~1 min for runner cold-start). On GitHub Actions free tier, up to 20 jobs can run in parallel for public repos, so all 16 cells launch effectively concurrently — wall-clock is dominated by the slowest cell, NOT the sum.
4. **Cross-check against prior-art baselines.** From `lfq:build.yml` (6 cells, sanitize=yes everywhere): empirically ~10-15 min per cell on `ubuntu-latest`, ~25-40 min on `ubuntu-24.04-arm` and `macos-latest` (timeouts set to 25 and 45 respectively). From `debra:ci.yml` (32 cells + Rosetta 8 cells): the longest cell is typically Windows (~20 min); without Windows, ~12-18 min per cell.
5. **Predict longest cell in §6.3 matrix:** likely candidate is **cell 9 (Helgrind)** or **cell 14 (nimony)**:
   - Helgrind: ~30-50× slowdown on a representative subset; if the subset is calibrated to ~30 sec baseline, Helgrind cell is ~15-25 min.
   - Nimony: build-from-source step is ~10 min (handoff Q2), plus a full-suite run under nimony at unknown speed (nimony is interpreted-mode for some constructs); likely 20-30 min total.
6. **Surface the result to the operator** as one of:
   - **GREEN: longest cell ≤ 20 min.** Proceed with §6.3 matrix as-is.
   - **YELLOW: longest cell 20-30 min.** Surface to operator with options: (a) accept the overrun explicitly; (b) cut Helgrind subset further; (c) move Helgrind / Valgrind to a nightly scheduled job (NOT per-PR). **Do not pick autonomously.**
   - **RED: longest cell > 30 min.** Surface to operator with the same options + (d) drop nimony cell from per-PR to nightly. **Do not pick autonomously.**

### 6.4.3 Pre-baseline expectation (this design's prediction, NOT a commitment)

Based on Phase 1 research (lfq + debra timings, TSAN/Helgrind slowdown factors): the §6.3 matrix's wall-clock end-to-end is likely **20-25 minutes**, with the nimony cell or the Helgrind cell as the long pole. This is *informational only* — the actual decision waits on §6.4.2 measurement.

---

## 6.5 Sanitizer strategy

### 6.5.1 TSAN (cell 6)

**Pattern:** env-flag toggle on a baseline-shape cell, NOT a duplicate matrix job. Mirrors `lfq:build.yml` lines 73-90 (`sanitize-threads: 'yes'` matrix column toggles `SANITIZE_THREADS=yes` env, which the test runner reads to add `--passC:-fsanitize=thread --passL:-fsanitize=thread`).

**MM:** orc only. TSAN runs are 5-15× slower than baseline (handoff Q13 historical timings + LLVM TSAN docs). Running TSAN × 4 MMs is 4× the wall-clock for ~0× additional unique findings: TSAN instruments memory access at the C-level, MM-independent.

**TSAN runner hang concern (handoff context):** the v5.0.0 `lfq:build.yml` has had intermittent TSAN runner hangs on the full test suite. Phase 2 must validate the hang is no longer reproducible on the consolidated repo. If it is, the cell-6 test runner switches to a **targeted subset** (a curated set of `tests/t_*.nim` files that exercise the concurrent paths most likely to surface races: `t_queue_mpmc.nim`, `t_nebr_retire.nim`, equivalents). Phase 2 must enumerate the subset explicitly in the workflow YAML; this design does not pre-bake the list because the test layout is finalized in §1 / §5.

**TSAN suppressions:** if any unsuppressed races appear, Phase 2 must triage them per the debra `tests/tsan.supp` pattern (`debra:ci.yml` line 271). > 5 suppressions = tripwire (per debra design §7.3; same principle here): if we need 5+ entries in `tsan.supp`, something architectural is wrong and the design must be re-examined.

### 6.5.2 ASAN (cell 7)

**Pattern:** identical to TSAN — env flag, baseline-shape cell, orc only. ASAN slowdown is ~2-3× (much lighter than TSAN); ASAN is the cheapest sanitizer to keep on. No subset needed — ASAN can run the full test suite.

**ASAN + GC interaction:** orc + ASAN is well-tested on Nim 2.x (handoff Q2 confirms Nim 2.0+ orc compatibility with ASAN). No special handling needed.

### 6.5.3 What TSAN + ASAN together do NOT catch

- **Suppressed races in libc / Nim runtime allocator paths.** Hence cell 8 (Valgrind memcheck) and cell 9 (Helgrind).
- **Compile-time invariants.** Hence the lint job (typestates verify).
- **Lock-free correctness under specific weak-memory orderings.** Hence the production test suite includes stress tests that randomize timing; sanitizers are necessary but not sufficient.

---

## 6.6 Valgrind + Helgrind cells (cells 8, 9)

### 6.6.1 Why new (handoff Q8)

Neither `lfq:build.yml` nor `debra:ci.yml` runs Valgrind or Helgrind. Adding them is new work, justified by:

- **Lock-free invariants are subtle.** TSAN catches most races; Helgrind's lockset analysis catches a different class (false-positive profile inverted from TSAN). Defense-in-depth.
- **nebr retire correctness.** Section 3's hazard-pointer / epoch-based retirement is the highest-risk lifecycle surface. Memcheck on the baseline lane catches use-after-free regressions ASAN may miss (Valgrind's dynamic binary translation sees memory ops the compiler optimized away from ASAN's instrumentation).

### 6.6.2 Job shape

**Preflight:**
```yaml
- name: Install Valgrind
  run: sudo apt-get update -q -y && sudo apt-get install -y valgrind
```

(One-line apt-install. Adds ~30s. Cached via `actions/cache@v4` on `/var/cache/apt`.)

**Compile flags:** `--debugger:native --opt:none -d:useMalloc` (Nim's GC-aware allocator interferes with Valgrind; `useMalloc` routes through the C `malloc` so Valgrind can track properly). Per the Nim docs and Phase 1 Q9.

**Test subset (representative, not full suite):**
- Valgrind memcheck slowdown: ~10-30× per test
- Helgrind slowdown: ~30-50× per test

A full-suite run under Helgrind would consume 30-50× the cell-1 baseline = 50-100 min, blowing the 20-min target. Subset strategy:

| Cell | Subset |
|------|--------|
| 8 (Valgrind memcheck) | `t_queue_spsc.nim`, `t_queue_mpsc.nim`, `t_queue_mpmc.nim`, `t_bqueue_mpmc.nim`, `t_nebr_lifecycle.nim` |
| 9 (Helgrind) | `t_queue_mpmc.nim`, `t_bqueue_mpmc.nim`, `t_nebr_concurrent_retire.nim` |

(File names are illustrative — Phase 2 must finalize against the actual test layout from §1 / §5 file inventories.)

**Rationale for subset choice:** MPMC stress is where races materialize; SPSC + MPSC catch the simpler regressions cheaply. The subset must cover (a) all four cardinalities at least once, (b) the nebr retire path explicitly. Adding bounded-queue MPMC catches BQueue-specific lifecycle bugs.

### 6.6.3 Wall-clock budget per cell

| Cell | Subset wall-clock estimate |
|------|----------------------------|
| 8 (Valgrind memcheck) | 5 subset tests × baseline ~10 sec × 30× = ~25 min worst-case. **YELLOW per §6.4 thresholds.** May need narrower subset. |
| 9 (Helgrind) | 3 subset tests × baseline ~10 sec × 50× = ~25 min worst-case. **YELLOW per §6.4 thresholds.** May need narrower subset. |

Phase 2 baseline measurement (§6.4.2) determines actual subset feasibility. If §6.4 shows YELLOW, the operator-facing options surface these cells specifically as nightly candidates.

---

## 6.7 Nimony cell — first-class architecture treatment

### 6.7.1 Phase 1.6 reconciliation summary

The MAJOR reconciliation in Phase 1.6: **nimony is first-class in the architecture, `continue-on-error` in CI**. This means:

| Surface | Treatment |
|---------|-----------|
| Architecture (Sections 3, 4) | Real `when defined(nimony):` arms in atomics shim, smr / nebr, ManagedRef / ManagedSlice. NOT hand-waved. NOT stubbed. NOT `{.error: "not yet ported".}`. |
| Public API (Section 5) | The `experimental:` nim-doc pragma marks nimony-specific codepaths as experimental. Documented in `docs/guide/nimony.md` (Section 7). |
| Tests | Full test suite runs under nimony (no test-skipping based on `when defined(nimony)` except where a test exercises a Nim runtime API nimony doesn't yet have — those are explicitly enumerated in §6.7.4). |
| CI gating | `continue-on-error: true` on the nimony cell, so a nimony breakage does NOT block PR merge. |
| Watch | Dedicated nimony status badge in README; AGENTS.md says "verify nimony cell weekly; treat sustained red as v0.2 blocker". |

### 6.7.2 Nimony cell job shape

```yaml
- name: test-nimony
  runs-on: ubuntu-latest
  continue-on-error: true
  timeout-minutes: 30
  steps:
    - uses: actions/checkout@v4
    - name: Install Nim stable (for bootstrap)
      uses: jiro4989/setup-nim-action@v2
      with:
        nim-version: 'stable'
    - name: Build nimony from source
      run: |
        git clone https://github.com/nim-lang/nimony.git /tmp/nimony
        cd /tmp/nimony && nimble install -y
    - name: Install lockfree deps
      run: nimble install -dy && nimble setup
    - name: Run test suite under nimony (aufbruch mode)
      run: |
        # Aufbruch is the nimony compilation mode that emits Nim code
        # the Nim compiler then processes — per handoff Q4 this is the
        # supported mode for cross-compiling existing Nim code.
        nim c --mm:atomicArc -d:nimony tests/test.nim
```

(Concrete invocation finalized in Phase 2 against the nimony tool's actual CLI surface — handoff Q4 confirms aufbruch exists, but the exact flag may differ.)

### 6.7.3 Why `atomicArc` and not `orc` on the nimony cell

Per handoff Q4 + Q2: nimony's ref semantics under `orc` are not yet stable enough for the full ManagedRef / ManagedSlice surface (Section 4 cell layouts). `atomicArc` is the closest MM with stable nimony support. The nimony cell uses `atomicArc` deliberately to maximize the chance of green-status; if `orc` support stabilizes in nimony, the cell migrates to `orc` for symmetry with the baseline lane.

### 6.7.4 Expected partial-port gaps (documented, not silently failing)

Per handoff Q4, the following are KNOWN to not yet work under nimony as of 2026-06:

- Some Nim runtime API calls (`getStackTrace`, `repr` on generic types) — used only in test error-reporting; the test files use `when not defined(nimony)` guards to skip those assertions, keeping the test green.
- Some `seq[T]` operations with closure-captured `T` — used in one stress-test; same guard pattern.

The guards are **explicit and enumerated in `docs/guide/nimony.md`** (Section 7). No silent `discard`; no "we hope this works" fingers-crossed. Each guard has a comment pointing at the upstream nimony issue or the handoff disposition that justifies it.

### 6.7.5 Watch / escalation

- **Badge:** README shows a "nimony" badge linking to the nimony cell's latest run. Green = the cell passed; yellow = `continue-on-error` saved it; red = nimony cell is broken (`continue-on-error: true` makes the *job* green from the PR-merge perspective, but the badge surfaces the actual status).
- **AGENTS.md note (lockfree repo):** "Verify nimony cell status weekly. Sustained red for 4+ weeks = escalate to a v0.2 blocker. Sustained green for 12+ weeks = consider removing `continue-on-error: true` (i.e., promote nimony to gating)."
- **Migration target:** the v0.2 design re-evaluates `continue-on-error: true` based on nimony stability data accumulated during v0.1.x.

---

## 6.8 chronos CI cell (cell 12)

### 6.8.1 Why a dedicated cell

§5's `lockfree/chronos` Tier 3 adapter is the only piece of the public API that depends on a non-stdlib package. CRITICAL #4 (hybrid sync/async pattern, queue + chronos `AsyncEvent`) is verified end-to-end only here. Without this cell, the chronos adapter can rot silently between releases.

### 6.8.2 Job shape

```yaml
- name: test-chronos
  runs-on: ubuntu-latest
  timeout-minutes: 10
  steps:
    - uses: actions/checkout@v4
    - uses: jiro4989/setup-nim-action@v2
      with: { nim-version: 'stable' }
    - name: Install chronos
      run: nimble install -y chronos
    - name: Compile with -d:lockfreeChronos
      run: |
        nim c -d:lockfreeChronos --threads:on --mm:orc tests/t_chronos_smoke.nim
        nim c -r -d:lockfreeChronos --threads:on --mm:orc tests/t_chronos_mpmc.nim
```

(Test file names per §5's enumeration of chronos-specific tests.)

### 6.8.3 Coverage delta vs baseline

Cell 12 differs from cell 1 only in: (a) chronos dep installed, (b) `-d:lockfreeChronos` enabled, (c) only chronos-marked tests run. Wall-clock ~3-5 min. Cheap, high-value.

---

## 6.9 Release CI job (release.yml)

### 6.9.1 Tag-on-CI policy (user CLAUDE.md global rule)

Per user's CLAUDE.md `Release tagging: NEVER direct, ALWAYS via CI`: the release job is the **only** path that produces a `git tag vX.Y.Z`. No developer, no agent, no subagent runs `git tag` from a shell. Period.

### 6.9.2 Trigger and gating

- **Trigger:** push to `devel` with a `nimble`-version bump (or push to `main` post-merge — Phase 2 finalizes the trigger ref per the repo's branching model).
- **Pre-condition:** PR-dance must have completed (per memory: bot approval on the latest commits; ALL bot feedback addressed). The release job assumes operator-driven merge after PR-dance — it does NOT itself verify approval (that's the PR-merge gate's job).

### 6.9.3 Job shape (inherits from `lfq:release.yml` + `debra:release.yml`)

Both source repos already have working `release.yml` workflows. The consolidated repo's `release.yml` is a near-direct merge:

- `version` step: extracts version from `lockfree.nimble`.
- `tag` step: `git tag v$(version)` and `git push origin v$(version)`. Idempotent (skips if tag already exists).
- `nimble publish` step: registers the new version with the nimble registry.
- `gh release create` step: produces a GitHub release with auto-generated notes (or hand-written notes if `CHANGELOG.md` has a matching version entry — per CHANGELOG-discipline rule in user memory).

### 6.9.4 Post-rename validation (deferred per CRITICAL #5)

CRITICAL #5 defers post-rename validation of `release.yml` to Phase 4. Phase 2 / Phase 3 design this section's job shape; Phase 4 runs the actual rename-aware dry-run.

---

## 6.10 Docs CI job (docs.yml)

### 6.10.1 Inherits from `lfq:docs.yml` + `debra:docs.yml`

Both source repos have working mkdocs deployment workflows. The consolidated docs.yml is a merge with the following tweaks per handoff `T-DOCS-RETHINK.h`:

- **mkdocs theme:** reconcile between lockfreequeues' theme and nim-debra's theme. Per Section 7 (docs IA), the chosen theme is mkdocs Material (matching nim-debra v0.10.0; lockfreequeues v5.0.0 uses the same).
- **mkdocs extensions:** union of both repos' extensions. Phase 2 enumerates the union; Phase 7 (docs section) ratifies it.
- **mkdocstrings-nim autodoc:** covers `src/lockfree/**/*.nim`. Already in `lfq:docs.yml`; just needs the path update post-rename.

### 6.10.2 Trigger

- `push` to `devel` (preview deployment to `gh-pages` branch under a `preview/` prefix).
- `push` to `main` (production deployment to `gh-pages` root).

### 6.10.3 Wall-clock

mkdocs build is fast (~2-3 min including mkdocstrings-nim Nim-source parsing). Not on the critical path of the 20-min target; runs independent of the build matrix.

---

## 6.11 Bot configuration

### 6.11.1 Primary reviewer: gemini-code-assist

Per handoff Phase 1.5 Q1: **gemini-code-assist** is the primary PR review bot. Auto-reviews on PR open and on every push to the PR branch. Findings are gating (must be addressed before merge).

### 6.11.2 Parallel reviewer: axiomantic-momus (informational)

Per memory `feedback_momus_dance_after_iteration`: **axiomantic-momus** runs in parallel as a fallback for when gemini is unavailable (out of credits / quota / no response). When gemini reviews normally, **gemini alone gates the PR; momus is informational only**. The momus workflow (`lfq:momus.yml`, `debra:momus.yml`, both 30 lines) is unchanged; it just runs in parallel.

### 6.11.3 Re-review tag (project-specific)

Per user CLAUDE.md `PR Review Bot`: bot username is `styleseatbot[bot]`; re-review tag is `@styleseatbot@pre`; bot does NOT auto-review on PR open (must be tagged every cycle). **HOWEVER** — that's the user's global default. For lockfree specifically (open-source, not styleseat-internal), the bot configuration is gemini + momus per handoff Phase 1.5 Q1, NOT styleseatbot. **The lockfree repo's AGENTS.md must override the global default** with a local `### PR Review Bot` block reflecting gemini + momus (Phase 7 Section, AGENTS.md propagation).

### 6.11.4 AGENTS.md PR Review Bot block (lockfree repo, override of user global)

```markdown
### PR Review Bot (lockfree)
- Primary: gemini-code-assist (auto-reviews on PR open + every push)
- Fallback: axiomantic-momus (parallel, informational unless gemini unavailable)
- Gating: gemini findings are gating; momus alone is NOT gating
- Re-review trigger: gemini auto-reviews on push; no manual tag needed
```

---

## 6.12 Test selection per cell

| Cell | Test selection |
|------|----------------|
| 1-5 (baseline + MM sweep) | Full `nimble test` suite. The full suite is the contract. |
| 6 (TSAN) | Full suite if it fits the time budget AND no TSAN-hang regressions; else a curated subset (§6.5.1). Phase 2 decides per §6.4 baseline. |
| 7 (ASAN) | Full suite (ASAN slowdown is mild). |
| 8 (Valgrind memcheck) | Subset per §6.6.2 table. |
| 9 (Helgrind) | Subset per §6.6.2 table. |
| 10, 11 (arm64, macOS) | Full suite. Runner-arch coverage is the point; can't be subset. |
| 12 (chronos) | Only `tests/t_chronos_*.nim`. |
| 13 (Nim devel) | Full suite. `continue-on-error` makes any regression visible without blocking. |
| 14 (nimony) | Full suite under nimony, with the enumerated `when not defined(nimony)` guards from §6.7.4. |

### 6.12.1 "Every cardinality × every payload type" coverage across the matrix

Section 2's payload-type sweep (`object`, `ref`, `string`, `seq[T]`, `tuple`, distinct etc.) and Section 5's cardinality sweep (SPSC, MPSC, SPMC, MPMC; bounded and unbounded) generate the test-file matrix in `tests/`. Each test file should be cardinality- and payload-parameterized internally (the test file iterates the relevant axes), so the matrix doesn't need separate cells per (cardinality, payload). One full-suite run = full (cardinality × payload) coverage on the cell's MM. Cells 1-5 collectively cover (cardinality × payload × MM); cells 10-11 add OS-arch.

---

## 6.13 Open questions for Phase 2.2 review

These are genuine uncertainties surfaced by Section 6 that the operator (or Phase 2.2 reviewer) should resolve before workflow-YAML drafting begins.

| # | Question | Owner | Default if unresolved |
|---|----------|-------|-----------------------|
| O1 | Does the wall-clock baseline (§6.4) come in GREEN, YELLOW, or RED? | RESOLVED 2026-06-06 (operator) | **Thresholds pinned: GREEN ≤ 20 min / YELLOW 20-30 min / RED > 30 min.** Gate: T-CI-WALLCLOCK-BASELINE classifies the §6.3 matrix into one band and surfaces to operator per §6.4.2. |
| O2 | TSAN runner-hang reproducibility on consolidated repo — still an issue? | Phase 2 | If yes, fall back to curated subset (§6.5.1); if no, keep full-suite TSAN. |
| O3 | Nimony install reliability — does `nimble install` from the nimony GitHub repo succeed reproducibly? | Phase 2 | If unreliable, pin to a known-good commit SHA in the workflow YAML. |
| O4 | Add Windows in v0.2? | RESOLVED 2026-06-06 (operator) | **Windows ADDED to v0.1.0 (scope expansion approved).** Cell 17 (windows-latest + stable Nim + orc + MSVC backend) lands in §6.3. Sanitizers omitted (don't run cleanly on Windows). Wall-clock estimate TBD via T-CI-WALLCLOCK-BASELINE. |
| O5 | Add `nim cpp` backend axis? | RESOLVED 2026-06-06 (operator) | **`nim cpp` ADDED to v0.1.0 (scope expansion approved).** Cell 18 (ubuntu-latest + stable Nim + orc + nim cpp) lands in §6.3. Single cell; not expanded into a full `cpp`-on-every-MM cross-product (smart-consolidation still applies). Wall-clock estimate TBD via T-CI-WALLCLOCK-BASELINE. |
| O6 | Are Helgrind / Valgrind cells per-PR or nightly-only? | Operator decision (informed by §6.4) | Per-PR if §6.4 GREEN; surface to operator otherwise. |
| O7 | Does `mm:none` build need a smoke-test subset, or just compile-only? | Phase 2 | Compile + smoke-test subset (the smoke tests that don't require GC); full suite under `mm:none` likely fails (test framework allocates). |
| O8 | Should the lint cell also run on macOS / arm64? | Phase 2 | No — lint is OS-independent; one cell suffices. |
| O9 | Caching strategy for nimony build-from-source (~10 min) — cache the built nimony binary across runs? | Phase 2 | Cache via `actions/cache@v4` keyed on the nimony repo commit SHA. Brings cell 14 from ~30 min to ~20 min on cache hit. |
| O10 | The "comprehensive" matrix excludes Windows and macOS x86_64 — is this the right "comprehensive" interpretation? | RESOLVED 2026-06-06 (operator) — **Windows ADDED per O4** (cell 17). | Windows now in scope. macOS x86_64 still excluded; v0.2 backlog. |

---

## 6.14 Section 6 summary

- **Cell count: 17 jobs** (1 lint + 16 test cells), enumerated in §6.3 under cell numbers 1-14 + 17-18 (numbers 15-16 are reserved slots, not assigned). Cells 17 (Windows + MSVC) and 18 (`nim cpp`) added by operator-approved scope expansion on 2026-06-06 (per O4, O5 resolutions). Earlier "18 cells" framing conflated the cell-number range with the job count; corrected per Phase 4.6.4 fact-check.
- **Coverage requirements C1-C20** all hit by at least one cell.
- **Wall-clock thresholds (per O1 resolution 2026-06-06):** GREEN ≤ 20 min / YELLOW 20-30 min / RED > 30 min. §6.4 specifies the baseline measurement protocol; T-CI-WALLCLOCK-BASELINE classifies the §6.3 matrix into one band and surfaces to operator per §6.4.2.
- **Smart consolidation principles:** full MM sweep on one OS; one MM (`orc`) on the other OSes; sanitizers as env flags on the baseline lane (not duplicate jobs); Valgrind / Helgrind as dedicated jobs with curated test subsets.
- **Nimony cell:** first-class architecture (Sections 3, 4 carry real `when defined(nimony):` arms), `continue-on-error: true` in CI (handoff Phase 1.6 reconciliation), dedicated status badge, AGENTS.md watch policy.
- **chronos cell:** dedicated Tier 3 adapter verification.
- **mm:none cell:** CRITICAL #2 lock-in.
- **Release tagging:** CI-only, per user CLAUDE.md global rule.
- **Bot configuration:** gemini-code-assist gating + axiomantic-momus parallel-informational, with an AGENTS.md override block.
- **Open questions O1-O10** (§6.13) surface to Phase 2.2 reviewer for explicit resolution; no autonomous answers.

Section 6 is **operationally complete** modulo the baseline measurement (§6.4) and the open questions (§6.13). Phase 2 workflow-YAML drafting can proceed once those are addressed.
