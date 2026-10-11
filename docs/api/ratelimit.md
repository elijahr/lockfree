# RateLimiter (TokenBucket & LeakyBucket)

`lockfree/ratelimit` implements non-blocking, lock-free rate limiters powered by
hardware 128-bit Double-Word Compare-And-Swap (DWCAS).

## Overview

- **`TokenBucket`**: Classic token bucket allowing bursts up to configured capacity with zero-drift nanosecond token replenishment.
- **`LeakyBucket`**: Generic Cell Rate Algorithm (GCRA) virtual scheduling traffic smoother enforcing strict cadence between events.
- **Progress Guarantee**: Lock-free under high concurrency; wait-free on uncontended paths. Zero locks, zero background timers.

## Example

```nim
import lockfree

var limiter = newTokenBucket(ratePerSec = 1000, burstCapacity = 50)

if limiter.tryAcquire(tokens = 1):
  # Event permitted
  discard
else:
  # Rate limit exceeded
  discard
```

::: lockfree/ratelimit
