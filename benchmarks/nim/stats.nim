## Statistical functions for benchmark analysis.
##
## `mean` and `stddev` re-export std/stats' `mean` / `standardDeviationS`
## (sample stddev with N-1 divisor) so the bench harness has a single
## canonical implementation rather than a divergent local copy. The
## remaining procs (`percentile`, `minVal`, `maxVal`) are kept local
## because std/stats does not expose equivalents (std/stats focuses on
## running statistics over `RunningStat`; percentile/min/max over a
## pre-collected `openArray[float]` are not in its surface area).
## Per gemini PR feat/v0.1.0 review, 2026-06-07.

import std/[algorithm, stats]

proc mean*(data: openArray[float]): float =
  if data.len == 0:
    return 0.0
  stats.mean(data)

proc stddev*(data: openArray[float]): float =
  ## Sample standard deviation (N-1 divisor). Matches the prior local
  ## impl's denominator; backed by `std/stats.standardDeviationS`.
  if data.len < 2:
    return 0.0
  stats.standardDeviationS(data)

proc percentile*(data: openArray[float], p: float): float =
  ## Calculate percentile (p in 0.0..1.0).
  ## NOTE: not in std/stats; kept here because std/stats only exposes
  ## running-statistics moments, not order-statistics on an openArray.
  if data.len == 0:
    return 0.0
  var sorted = @data
  sorted.sort()
  let idx = int(float(data.len - 1) * p)
  sorted[idx]

proc minVal*(data: openArray[float]): float =
  ## NOTE: not in std/stats; the stdlib `min`/`max` (from `system`) would
  ## work but kept here for symmetry with `maxVal` and to preserve the
  ## empty-input → 0.0 sentinel the bench harness depends on (stdlib
  ## `min` raises on empty input).
  if data.len == 0:
    return 0.0
  result = data[0]
  for x in data:
    if x < result:
      result = x

proc maxVal*(data: openArray[float]): float =
  ## NOTE: not in std/stats; same rationale as `minVal`.
  if data.len == 0:
    return 0.0
  result = data[0]
  for x in data:
    if x > result:
      result = x
