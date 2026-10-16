## src/lockfree/chronos.nim
##
## Tier 3 chronos async adapter for `lockfree` queues. This is the only async
## tier shipping in v0.1.0, built on the hybrid optional-dep pattern.
##
## chronos is intentionally NOT listed unconditionally in `lockfree.nimble`
## `requires`. The library is flag-only opt-in: users who want the async adapter
## pass `-d:lockfreeChronos` AND install chronos themselves (or rely on
## `lockfree.nimble`'s `when defined(lockfreeChronos): requires "chronos >=
## 4.0.0, < 5.0.0"` conditional dep). The library never transitively pulls
## chronos in for users who do not need it, and chronos is never auto-detected
## at compile time.
##
## Activation matrix (flag-only opt-in):
##
##   `-d:lockfreeChronos` | chronos installed | outcome
##   -------------------- | ----------------- | -----------------------------
##   No | (irrelevant) | (d) import succeeds; module body skipped; AsyncQueue/
##   AsyncBQueue invisible. Yes | Yes | (b) opt-in path; module body activates;
##   types exported. Yes | No | (c) `{.error.}` fires with a precise install
##   hint referencing `docs/api/chronos.md`.
##
## The previous auto-detect arm — a public `lockfreeChronosAvailable*`
## constant that callers could `when`-branch on to silently enable the adapter
## without the flag — was removed: silent activation based on whether chronos
## happens to be installed in a user's package set violates the flag-only opt-in
## contract. An internal (non-exported) `chronosReachable` probe is retained
## ONLY to drive the precise install-hint `{.error.}` arm; the module body never
## activates without `-d:lockfreeChronos`, regardless of whether chronos is
## reachable.
##
## NOTE on chronos import form: the obvious `import chronos` self-shadows inside
## this module — our own file IS `src/lockfree/chronos.nim`, which Nim
## resolves first on the import search path, breaking the `compiles do:` probe
## used to emit the precise install-hint error. We import the chronos
## *submodule* `chronos/asyncsync` (which transitively re-exports asyncloop ->
## asyncfutures + asyncmacro, covering AsyncEvent, Future, async/await, waitFor,
## CancelledError) and we use the bracket-array form `chronos/[asyncsync]`. The
## bracket form is what makes the resolver locate the chronos package despite
## the local module's name. A leading throw-away `compiles do: import
## chronos/asyncsync` primes Nim's package resolver so the bracket form binds
## correctly on the next call — without that prime the bracket form returns
## false on the very first invocation in a module whose own name is "chronos".
## This priming probe is deliberate and is required to defeat the
## self-shadowing; it is NOT an auto-detect arm, and its result is discarded.

# Prime the package resolver. The result is intentionally discarded; the side
# effect is that Nim now knows the chronos package exists, so the bracket-form
# `compiles do:` probe below succeeds when chronos IS installed. Kept
# unconditional (not gated on `lockfreeChronos`) because the cost is zero when
# chronos is missing and it avoids two distinct probe shapes for the resolver to
# disagree about. The result of the `when (compiles do: ...)` is discarded.
when (compiles do:
  import chronos/asyncsync
):
  discard

# `chronosReachable` is the internal flag-only equivalent of the old public
# `lockfreeChronosAvailable` constant — but it is NOT exported and is
# consulted ONLY inside the `when defined(lockfreeChronos)` arm below. That
# keeps the activation contract flag-only: a user who has chronos in their
# package set but does NOT pass `-d:lockfreeChronos` still gets the no-op (d)
# outcome from the activation matrix.
const chronosReachable = compiles do:
  import chronos/[asyncsync]

when defined(lockfreeChronos) and not chronosReachable:
  {.
    error:
      "lockfree/chronos: -d:lockfreeChronos was set but the chronos " &
      "package is not installed. Run " &
      "`nimble install \"chronos >= 4.0.0, < 5.0.0\"` and re-build, " &
      "or remove -d:lockfreeChronos to disable the async adapter. " &
      "See docs/api/chronos.md for the full integration guide."
  .}

## --------------------------------------------------------------------
## (b) Module body — activates ONLY when `-d:lockfreeChronos` is set (the (c)
## guard above already ensured chronos is present in that case).
## --------------------------------------------------------------------

when defined(lockfreeChronos):
  import ./async_bridge
  export async_bridge
