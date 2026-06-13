## lockfree/backoff
##
## CAS-retry backoff policy for lockfree' typestate retry loops.
## Built on debra's `cpuPause` and `schedYield` primitives. Two helpers:
##
##   * `backoffOnRetry`     - exponential backoff on CAS-failure retry.
##                            Doubles spin count each call up to MaxSpin;
##                            once spins reach YieldThreshold, also calls
##                            `schedYield` to release the CPU quantum.
##                            Use at every `continue` after a failed
##                            `tryClaim` / `compareExchange` in a
##                            retry-until-success loop.
##
##   * `backoffOnPeerWait`  - cpuPause-only stateless backoff for short
##                            peer-completion waits (e.g. spinning on a
##                            committed flag set by a peer thread). No
##                            syscall, no state: peer publication latency
##                            is typically shorter than `sched_yield`'s
##                            ~200ns-1us cost on Linux.
##
## State-passing pattern: `backoffOnRetry` callers declare
## `var spins = InitialSpin` BEFORE entering the retry loop and pass it
## by `var` reference; the helper mutates in place. `backoffOnPeerWait`
## takes no arguments (stateless). The caller's success path adds zero
## instructions (helpers are only called on the failure edge, not per
## loop iteration unconditionally).
##
## Constants are tunable via `-d:LockfreeQueuesInitialSpin=N` etc. if a
## downstream user needs to retune for a specific workload, but defaults
## are chosen from lock-free literature (Mellor-Crummey/Scott, Anderson)
## and validated by Bencher gates.
##
## NOTE: `cpuPause` is named so (not `cpuRelax`) in debra to avoid a
## collision with `system.cpuRelax` (re-exported from `std/sysatomics`).
## The stdlib version is a compiler-barrier-only fallback on non-x86;
## debra's `cpuPause` emits the real `pause`/`yield` instruction.

import lockfree/atomics/backoff

const
  InitialSpin* {.intdefine.} = 4
    ## Initial spin count for `backoffOnRetry`. Caller initializes
    ## `var spins = InitialSpin` before the retry loop. Doubles each
    ## failed iteration.

  MaxSpin* {.intdefine.} = 256
    ## Upper bound on `spins` after exponential growth. Prevents runaway
    ## spin counts on pathologically contended workloads. 256 is aligned
    ## with Anderson/MCS exponential-cap norms (typical range 64-256):
    ## permissive enough to absorb high contention bursts without
    ## unbounded spin time, low enough that a worst-case spin completes
    ## in single-digit microseconds on modern x86/aarch64.

  YieldThreshold* {.intdefine.} = 16
    ## When `spins >= YieldThreshold`, `backoffOnRetry` also calls
    ## `schedYield` after the cpuPause burst. Below this threshold,
    ## stays in cpuPause-only mode (no syscall cost).

static:
  # Reject pathological `-d:LockfreeQueuesMaxSpin` overrides at compile
  # time. A spin budget above this ceiling makes no operational sense
  # (worst-case spin already completes in single-digit microseconds at
  # MaxSpin=256) and the growth step's `spins * 2` guard relies on a sane
  # ceiling well below `int.high`. 1 shl 20 (~1M) is far beyond any
  # useful backoff yet leaves >2000x headroom under int32.high.
  doAssert MaxSpin <= (1 shl 20),
    "MaxSpin (-d:LockfreeQueuesMaxSpin) is unreasonably large: " & $MaxSpin
  doAssert InitialSpin >= 1, "InitialSpin must be >= 1, got " & $InitialSpin
  doAssert MaxSpin >= InitialSpin,
    "MaxSpin (" & $MaxSpin & ") must be >= InitialSpin (" & $InitialSpin & ")"

proc backoffOnRetry*(spins: var int) {.inline.} =
  ## Called on the failure path of a CAS-retry loop. Burns `spins`
  ## cpuPause cycles, optionally yields the OS quantum if contention
  ## is escalating, then doubles `spins` (capped at `MaxSpin`).
  ##
  ## Caller pattern:
  ##   var spins = InitialSpin
  ##   while true:
  ##     ...
  ##     if not tryClaim(...):
  ##       backoffOnRetry(spins)
  ##       continue
  ##     ...
  for _ in 0 ..< spins:
    cpuPause()
  if spins >= YieldThreshold:
    schedYield()
  # Grow toward `MaxSpin` without ever evaluating `spins * 2` when it
  # could overflow `int`. Doubling first and capping after (the obvious
  # `min(spins * 2, MaxSpin)`) is unsafe when a pathological
  # `-d:LockfreeQueuesMaxSpin` is set near `int.high`: `spins * 2` would
  # raise OverflowDefect (checks on) or wrap negative (checks off,
  # silently disabling backoff). Comparing against `MaxSpin div 2` first
  # bounds the multiply: it only runs when `spins < MaxSpin div 2`, so
  # `spins * 2 < MaxSpin <= int.high`.
  spins =
    if spins >= MaxSpin div 2:
      MaxSpin
    else:
      spins * 2

proc backoffOnPeerWait*() {.inline.} =
  ## Called inside a tight `while peer-flag-not-set: ...` loop.
  ## Single cpuPause per call (no syscall, no state, no exponential
  ## growth). Stateless by design: peer publication latency is short
  ## enough that exponential growth and syscall escalation would
  ## overshoot.
  ##
  ## Caller pattern (e.g. unbounded segment-local committed flag):
  ##   while not seg.committed[i].load(moAcquire):
  ##     backoffOnPeerWait()
  cpuPause()
