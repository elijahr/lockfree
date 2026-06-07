# T-NIMCPP-VERIFY — Result Report (2026-06-06)

**Branch:** `feat/v5.0.0-impl`
**Workspace:** `/Users/eek/Development/lockfree`
**Plan task:** T-NIMCPP-VERIFY (PG-9, NEW per O5 2026-06-06)
**Design cites:** §4.2.4 (cross-backend notes); §6.3 cell 18; §6.13 O5 resolution 2026-06-06; R16
**Toolchain:** Nim 2.2.10 (mise), clang (Apple); host darwin arm64

## Scope

Verify the v0.1.0 queue surface (lockfree.nim) + nebr + ManagedRef/ManagedSlice
compiles and runs under `nim cpp --threads:on --mm:orc` against the standard
PG-9 representative test subset. Establishes the substrate for CI matrix
cell 18 (`nim cpp` + orc).

Per AGENTS.md §3.5 slim-verify protocol: compile + run 4 representative tests;
do not run the full PG-9 suite.

## Library compile status

```
nim cpp --threads:on --mm:orc --path:src -c src/lockfree.nim
```

Result: **PASS** ([SuccessX], 96414 lines, 0.645s, 175 MiB peak).

Diagnostics observed (all pre-existing, none `nim cpp`-specific):
- Typestate `User` warnings (typestates 0.12.0 same-name attachment-pragma
  limitation; tracked, not blocking).
- `[DuplicateModuleImport]` hint for nebr re-import in
  `src/lockfree/queue.nim` (pre-existing hygiene item, not C++-specific).
- `[UnusedImport]` warnings for `constants`, `typedthreads` (pre-existing).

No C++-specific errors. No `restrict`/`nullptr`/`extern "C"`/keyword-collision
issues surfaced. Section 4 §4.2.4 prediction held: no shim-level edits needed.

## Per-test results under `nim cpp --threads:on --mm:orc`

| Test | Compile | Runtime | Tests run | Pass | Fail | Skip |
|---|---|---|---|---|---|---|
| `tests/t_drain.nim` | OK | OK | 16 | 16 | 0 | 0 |
| `tests/composition/t_path_c_matrix.nim` | OK | OK | 24 | 24 | 0 | 0 |
| `tests/t_destructor_walk.nim` | OK | OK | 39 | 39 | 0 | 0 |
| `tests/t_wave_c_smoke.nim` | OK | OK | 16 | 16 | 0 | 0 |
| **Total** | **4/4** | **4/4** | **95** | **95** | **0** | **0** |

All four representative tests across the v0.1.0 axis (drain, composition
25-row Path-C matrix, destructor walk, wave-c bqueue smoke) compile and
pass identically under `nim cpp` to their known `nim c` baselines.

## C++-specific findings

### Finding 1: Benign `-Warray-bounds` from Nim seq codegen (NOT a defect)

Every `nim cpp` build of these test files emits clang `-Warray-bounds`
warnings against Nim's generated sequence-payload struct:

```c++
struct tySequence__...Content { NI cap; NI data[SEQ_DECL_SIZE]; };
// SEQ_DECL_SIZE == 1; codegen then writes data[0..len-1] by design.
```

This is Nim runtime's standard flexible-array-member idiom (declare
size-1 trailing array, allocate with computed size, index past 1). clang's
`-Warray-bounds` flags it because the declared bound is 1, but the
allocation is correctly sized. The C frontend silently accepts the same
pattern (no `-Warray-bounds` because Nim's C output uses `data[]` flexible
arrays in C99 mode).

- Root cause: Nim runtime codegen targets C99 flexible arrays under
  `nim c` but falls back to size-1 trailing arrays under `nim cpp`
  (C++ has no standardized flexible-array-member).
- Severity: **noise**, not a defect. No miscompile; runtime executes
  correctly (95/95 tests pass).
- Disposition: ignore. Suppress in CI cell 18 via `--warning[Cgen]:off`
  or just accept the warning band. Do NOT attempt to "fix" by touching
  Nim runtime.
- Project impact: none.

### Finding 2: No project-side C++ incompatibilities

- Atomics shim (`src/lockfree/atomics/`): builds clean under `nim cpp`.
  GCC/Clang `__atomic_*` builtins are equally available in C++ and C;
  no `extern "C"` wrappers needed.
- DWCAS path: unchanged behavior; no signature mismatch.
- `nebr`, `ManagedRef`, `ManagedSlice`: all build clean and tests pass.
- Typestates 0.12.0 codegen: compatible with `nim cpp`.

## CI cell 18 recommendation

**GREEN** — Enable cell 18 (`ubuntu-latest + stable + orc + nim cpp`)
in the 18-cell matrix per §6.3 with no project-side blockers.

Recommended cell knobs:
- Backend: `nim cpp`
- MM: `--mm:orc`
- Threads: `--threads:on`
- Optional: `--warning[Cgen]:off` to silence the benign Nim-runtime
  `-Warray-bounds` noise from clang; or accept warning output and
  pass only on exit code (preferred — keeps signal visible if Nim
  runtime codegen ever changes).
- Sanitizers: per §6.3 cell-18 row (none required for the smoke axis).

No acceptance-criterion remediation needed for v0.1.0. T-CI-MATRIX
(PG-10) can wire cell 18 in directly with no preceding fixup task.

## Notes / surprises

- The plan acceptance criterion mentions `nim cpp --threads:on --mm:orc
  tests/test.nim` (nimble-test entry point). The slim-verify dispatch
  used the 4 representative test files instead per AGENTS.md §3.5. The
  4 files exercise the queue surface, nebr, ManagedRef/Slice, and Path-C
  composition — broader coverage than `tests/test.nim` alone, and the
  spec's "PG-9 test subset" criterion is satisfied.
- Compile times under `nim cpp` are comparable to `nim c` (0.6s lib,
  1.5–5.6s per test on host); no concerning wall-clock blowup that would
  push cell 18 over §6.4 thresholds.
- Local host is darwin arm64 / clang; the CI target is ubuntu-latest /
  gcc. Both compilers support the same `__atomic_*` builtins and Nim
  runtime patterns. The `-Warray-bounds` finding is clang-specific in
  its surface text; gcc will likely emit `-Warray-bounds` or stay
  silent depending on version. Behavior identical; warning text may
  differ.

## Artifacts

- This report: `/Users/eek/Development/lockfree/docs/internal/t-nimcpp-verify-2026-06-06.md`
- No source changes.
- No commits.
