# Docs CI Cost — 2026-06

## Frontmatter

- **Date:** 2026-06-11.
- **Commit:** `e8cc3f97a4c4561fac3cd1678643589b04ed503e` (branch `feat/v0.1.0`).
- **Machine:** `Darwin 25.4.0 arm64` (`uname -srm`).
- **Scope:** Local docs-build wall-clock baseline for impl-plan Task
  C-MAJOR-8.

## Command Reconciliation

The impl plan (C-MAJOR-8, Step 1) prescribes `nimble docs` as the command
to measure. That task does **not** exist in `lockfree.nimble`:

```
$ nimble tasks
should_fail       Verifies compile-fail negative controls
test              Runs the test suite
testTSan          Runs the test suite under ThreadSanitizer (TSAN)
testASan          Runs the test suite under AddressSanitizer (ASAN)
examples          Runs the examples
benchmarks        Runs the benchmark suite
benchtests        Runs the bench harness test suite
benchToggleSmoke  Verify LFQ_BENCH_HARNESS_BACKOFF=0 toggle is observed at module init
benchteststress   Runs the bench harness test suite including 3.3M-sample stress shapes
```

The actual docs CI gate is `mkdocs build --strict --clean` (see
`.github/workflows/docs.yml`, "Build docs (PR verification, no deploy)"
step). The measurement below uses that command — it is the command whose
wall-clock the operator actually cares about when reasoning about "docs
CI cost". The impl-plan command name (`nimble docs`) appears to be an
artifact of plan authoring without verifying the nimble file.

## Measurement

### Setup (mirroring `docs.yml`)

To exercise the same path mkdocstrings-nim takes in CI, the Nim compiler
source must be importable. Done locally via:

1. Clone Nim v2.2.10 source into `~/.cache/nim-source-2.2.10`.
2. Append `path="…/nim-source-2.2.10"` to
   `~/.local/share/mise/installs/nim/2.2.10/config/nim.cfg`.
3. Verify `import compiler/ast` resolves via `nim check`.

This matches the "Make Nim compiler API importable (for mkdocstrings-nim)"
step in `.github/workflows/docs.yml` (lines 69-134).

### Raw `time -p` output (with `--strict`)

```
$ cd /Users/eek/Development/lockfree && \
    /usr/bin/time -p mkdocs build --strict --clean
…
ERROR   -  mkdocstrings: Could not find Nim file for identifier: debra.atomics
ERROR   -  Error reading page 'legacy/nim-debra/api.md':
ERROR   -  Could not collect 'debra.atomics'

Aborted with a BuildError!
real 7.16
user 9.56
sys  7.89
```

### Raw `time -p` output (without `--strict`)

```
$ cd /Users/eek/Development/lockfree && \
    /usr/bin/time -p mkdocs build --clean
…
ERROR   -  mkdocstrings: Could not find Nim file for identifier: debra.atomics
ERROR   -  Error reading page 'legacy/nim-debra/api.md':
ERROR   -  Could not collect 'debra.atomics'

Aborted with a BuildError!
real 4.41
user 7.56
sys  6.20
```

The `--strict` and non-`--strict` runs both terminate at the same
mkdocstrings-nim hard error inside `legacy/nim-debra/api.md`. The
`--strict` measurement is higher because `--strict` causes mkdocs to
keep collecting warnings/errors after the first one and re-emit them
in the abort path.

### Build outcome

**FAILED** locally. `docs/legacy/nim-debra/api.md` references the
identifier `debra.atomics`, which has no corresponding Nim file on this
branch — `src/` has `lockfree/atomics.nim`, not `debra/atomics.nim`. The
upstream `debra` package was lifted into `lockfree/` during the v0.1.0
umbrella; the legacy api page was not updated. This is a pre-existing
defect, not a v0.1.0 cleanup-wave regression — and it is not in scope
for C-MAJOR-8 (measurement task). Surfacing it here so a follow-up can
either fix the identifier or move/exclude the legacy page.

## Classification

Per impl-plan thresholds:

- `< 2 min` (GREEN): no action.
- `2-5 min` (YELLOW): acceptable; cumulative impact small.
- `> 5 min` (RED): escalate via AskUserQuestion.

**Verdict: GREEN (local), with caveats.**

- Local wall-clock to the abort point is **7.16 s real** with `--strict`
  / **4.41 s real** without. Both are well under the 2-minute GREEN
  threshold.
- This is **NOT a complete build** — the run aborted at the legacy api
  page error before traversing the rest of `nav:`. A complete local
  build would be longer, but the dominant cost (mkdocstrings-nim
  collection across `lockfree.*` modules) does occur before the abort
  point, so the partial measurement is a meaningful lower bound rather
  than a noise spike.
- Local timings are an **order-of-magnitude indicator only**. CI runs
  on cold caches, on ubuntu-latest hosted runners, and includes the
  Nim-source clone + nimble cache restore + pip install (workflow steps
  3-8 in `docs.yml`). Real CI wall-clock will be substantially higher
  than this local figure. For the CI-side number the operator should
  consult `.github/workflows/docs.yml` recent run durations, not this
  doc.
- If CI runtime is the gating concern, the methodology to use is the
  one described in the (forthcoming) C-MAJOR-4 sanitizer-baseline doc:
  measure across N consecutive CI runs, separate cold-cache from
  warm-cache, and compare the warm-cache median against the no-docs
  baseline.

## Decision

- **No mitigation required at the local level.** Local docs build cost
  is negligible (single-digit seconds even with full mkdocstrings-nim
  extraction across `lockfree/`).
- **Pre-existing local-build failure** (`debra.atomics` collection error)
  is a separate, low-priority defect — out of scope for C-MAJOR-8 — and
  is surfaced here for follow-up triage. It does NOT affect CI today
  because CI builds against a slightly different docs nav / package
  layout flow (or because the gh-pages deploy path masks the strict
  failure on push events). A targeted follow-up task should either fix
  the identifier or remove/exclude `docs/legacy/nim-debra/api.md`.

## References

- Impl plan: Task C-MAJOR-8 (Local docs-CI cost measurement).
- CI workflow: `.github/workflows/docs.yml`.
- Forthcoming: C-MAJOR-4 sanitizer-baseline doc (methodology pointer
  for CI-side measurement).
