## Negative control — unbounded MPMC `Queue[T]` rejects wide T at
## compile time.
##
## Per v5.0.0 BREAKING (design §11.2): the strict-LCRQ migration
## publishes via 128-bit DWCAS into `Atomic[Pair[uint64, T]]`, which
## constrains T to `supportsCopyMem(T) and sizeof(T) <= 8` on the
## `ccMulti × ccMulti` arm of `Queue`. Compiling a queue with
## `sizeof(T) > 8` MUST fail.
##
## Concretely: `array[3, int]` is 24 bytes on a 64-bit target — well
## over the 8-byte ceiling.
##
## Two layered guards reject wide T (either is sufficient; in
## practice (1) fires first at construction):
##   1. debra's `enforceDwcasConstraints` static assertion fires from
##      `Atomic[Pair[uint64, T]].store` inside `newSegment`:
##      "sizeof(B) <= 8 Pair half-type ... must be <= 8 bytes".
##   2. The v5.0.0 `{.error.}` block in `proc push` (queue.nim):
##      "requires sizeof(T) <= 8".
##
## The runner pins debra's substring ("Pair half-type") — the OUTER
## enforcement layer that fires at construction. If the narrowing is
## ever removed from the unbounded MPMC arm, BOTH layers stop firing
## and the test fails — the tripwire is sound either way.
##
## LAYER-ATTRIBUTION CAVEAT (T2-011): this single negative-control does
## NOT independently pin the queue.nim `proc push` `{.error.}` ("requires
## sizeof(T) <= 8"). Because construction trips the OUTER "Pair half-type"
## guard first, a maintainer who loosened ONLY the queue.nim layer would
## leave "Pair half-type" still firing and this test still green —
## masking that inner-guard regression. The two layers are not separately
## tripwired here; a dedicated control exercising a T that passes the
## Pair-half-type layer but trips the sizeof(T) layer would be needed to
## pin the inner guard on its own. Treated as a known doc-attribution
## limitation, not a behavioral defect (both guards are verified present).
##
## This is the structural twin of
## `tests/t_bqueue_mpmc_wide_T_accepted.nim` (the positive control):
## together they form the tripwire against accidental
## cross-queue constraint extension.

import lockfree/queue
import lockfree/endpoint
import lockfree/role_tags

proc main() =
  var q = newUnboundedMpmcQueue[array[3, int], stEager, 16, 4]()
  var producer = q.getProducerHere()
  let item: array[3, int] = [1, 2, 3]
  # Wide T (24 bytes) on the ccMulti × ccMulti arm must fail with the
  # pinned substring "requires sizeof(T) <= 8".
  producer.push(item)

main()
