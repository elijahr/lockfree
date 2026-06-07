# Nimony

[Nimony](https://github.com/nim-lang/nimony) is the next-generation Nim
compiler currently under development. `lockfree` is designed for
first-class nimony compatibility — the umbrella architecture, the
type-system arms, and the per-MM Path-C wrappers all account for
nimony's evolving semantics.

This page covers:

- The current portability state.
- The set of `experimental:` flags `lockfree` toggles for nimony.
- The "partial-port acceptance" policy.
- The watch policy for upstream nimony changes.

## Current status

As of v0.1.0, the umbrella's CI matrix includes a dedicated nimony
cell (Cell 14, `continue-on-error: true`). Pass/fail on the nimony
cell does **not** block PRs; the cell is informational. This is
deliberate per the Nimony scope policy below.

The bulk of `lockfree` compiles under nimony today, with a small set
of known divergences that are tracked and either:

- Patched in `lockfree` as MM-specific `when defined(nimony)` arms.
- Tracked upstream against nimony's `aufbruch` branch and accepted
  as partial-port gaps until upstream resolves.

For the latest portability state, see the nimony cell run on the
[CI dashboard](https://github.com/elijahr/lockfree/actions).

## Experimental flags

`lockfree` sets the following nimony `experimental:` flags by default
when nimony is detected (via `when defined(nimony)`):

- `arcInc`, `arcDec` — atomic refcount intrinsics. Used by the Path-C
  refcount wrappers for `ref T` payloads. The symbol names are
  pinned against nimony's `aufbruch` branch; see
  [internal: OQ4.2](https://github.com/elijahr/lockfree/blob/devel/docs/internal/design-sections/04-mm-compat-shim-and-cell-layouts.md)
  for the verification trail.
- (Additional flags get added as nimony stabilizes; the umbrella
  errs on the side of opt-in until the flag becomes stable.)

If you compile under nimony with `--mm:orc` and see "unknown experimental
flag", upstream nimony has likely renamed or removed the flag. File
an issue against `lockfree` with the version of nimony you are using
and the flag name reported.

## Partial-port acceptance

Per the umbrella scope policy, **`lockfree` accepts partial nimony
portability for v0.1.0**. Specifically:

- The bulk of the library compiles under nimony.
- Specific arms (e.g. the chronos adapter, certain Path-C edge cases
  involving closures) may not compile under nimony and are skipped
  with `when not defined(nimony)` guards.
- The nimony CI cell runs with `continue-on-error: true`; failures
  are informational.

This policy avoids blocking the umbrella on a moving upstream target.
As nimony stabilizes, the partial-port arms become full-port arms and
the `continue-on-error` flag is removed.

## Watch policy

Per the [AGENTS.md gotchas section](https://github.com/elijahr/lockfree/blob/devel/AGENTS.md),
the maintainers run a **weekly check** against nimony's `aufbruch`
branch:

- Run the nimony cell against the latest `aufbruch` commit.
- Compare against the last known-good run.
- File issues for new failures; close issues for fixed failures.
- Update the nimony commit pin in `lockfree.nimble` once a quarter
  or on operator request.

This is the same cadence used for upstream tracking on other
fast-moving dependencies. Operators who want nimony coverage at a
specific commit can override the pin via a `requires` line in their
own `.nimble`.

## What does NOT compile under nimony today

The known gaps as of v0.1.0:

- `chronos` adapter — chronos has not yet stabilized on nimony.
- Some closure-environment Path-C arms — pending nimony's heap-header
  layout finalization (tracked as OQ4.2 in the design doc).

Both of these compile under regular Nim across all four supported
MMs. The nimony gaps are isolated to specific `when` arms.

## Switching between Nim and nimony

If you maintain a codebase that targets both compilers, the
recommended pattern is to gate nimony-specific code on `when
defined(nimony)`:

```nim
when defined(nimony):
  # nimony-specific code
else:
  # regular Nim code
```

`lockfree` follows this pattern internally; the public API is
identical across compilers where both compile.

## Further reading

- [Nimony repository](https://github.com/nim-lang/nimony).
- Internal: [design-sections/06-ci-matrix-and-nimony-plan.md](https://github.com/elijahr/lockfree/blob/devel/docs/internal/design-sections/06-ci-matrix-and-nimony-plan.md) — the full nimony portability plan.
- [`AGENTS.md`](https://github.com/elijahr/lockfree/blob/devel/AGENTS.md) — the watch-policy gotchas section.
