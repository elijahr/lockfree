## Umbrella Test Aggregator (`tests/test.nim`)
## Delegates directly to the Tier 1 unit runner (`tests/unit/runner.nim`)
## and Tier 2 concurrency runner (`tests/concurrency/runner.nim`).

{.warning[UnusedImport]: off.}

import ./test_watchdog
import ./unit/runner as unit_runner
import ./concurrency/runner as concurrency_runner

export test_watchdog, unit_runner, concurrency_runner

# chronos adapter tests gated on chronos availability
# (chronos is NOT in lockfree.nimble requires). When chronos
# is on the Nim search path, the suite participates in the aggregator;
# otherwise it is silently skipped so the rest of the matrix continues
# to compile.
when (
  compiles do:
    import chronos/asyncsync
):
  discard
when (
  compiles do:
    import chronos/[asyncsync]
):
  import ./t_chronos
  export t_chronos
