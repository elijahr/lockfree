## ==============================================================================
## Tests for Hardware 128-Bit DWCAS Lock-Free Rate Limiters (Wave 4A)
## ==============================================================================
##
## Exhaustive verification covering:
## 1. TokenBucket unit semantics: capacity, refill, fractional tokens, reset
## 2. Zero-drift precision across multi-million cycles with non-power-of-two rates
## 3. High-concurrency multithreaded contention stress (zero double-spend/leak)
## 4. Bounded timeout acquisition: precise wakeups and immediate fail-fast
## 5. LeakyBucket GCRA virtual scheduling: burst limits and pacing
## 6. LeakyBucket timeout consumption
## 7. C ABI and C99 header syntax verification
## ==============================================================================

import unittest2
import lockfree/ratelimit
import lockfree/atomics
import std/os

const NanosPerSec: uint64 = 1_000_000_000'u64

suite "Wave 4A 128-Bit DWCAS Rate Limiters":

  test "TokenBucket basic acquisition and capacity bounds":
    var tb = initTokenBucket(capacityTokens = 10, refillRatePerSec = 5, initialTokens = 10)
    check tb.capacityTokens == 10
    check tb.capacityScaled == 10'u64 * NanosPerSec
    check tb.refillRate == 5
    check tb.available == 10

    # Acquire 3 tokens
    check tb.tryAcquire(3) == true
    check tb.available == 7

    # Acquire remaining 7 tokens
    check tb.tryAcquire(7) == true
    check tb.available == 0

    # Bucket is empty: acquire 1 fails
    check tb.tryAcquire(1) == false

    # Cannot acquire more than capacity even if full
    tb.reset(10)
    check tb.tryAcquire(11) == false

    # Acquire with zero requested is always true (no-op)
    check tb.tryAcquire(0) == true

  test "TokenBucket deterministic timestamp advance and remainder preservation":
    var tb = initTokenBucket(capacityTokens = 10, refillRatePerSec = 10) # 10 tokens/sec = 100ms per token
    let t0 = 1_000_000_000'u64 # 1.000s
    tb.resetAt(t0, 0) # Empty at t0

    # At t0, available = 0
    check tb.tryAcquireAt(t0, 1) == false

    # At t=50ms, elapsed = 50ms (0.5 tokens). Cannot acquire 1 token yet
    check tb.tryAcquireAt(t0 + 50_000_000'u64, 1) == false

    # At t=100ms, elapsed = 100ms (1.0 token). Should succeed!
    check tb.tryAcquireAt(t0 + 100_000_000'u64, 1) == true

    # Immediately at t=100ms, cannot acquire second token
    check tb.tryAcquireAt(t0 + 100_000_000'u64, 1) == false

    # At t=250ms, elapsed since last consumption is 150ms (1.5 tokens).
    # Consuming 1 token leaves 0.5 tokens (remainder preserved)
    check tb.tryAcquireAt(t0 + 250_000_000'u64, 1) == true

    # At t=300ms (50ms later), remaining 0.5 + 0.5 = 1.0 token refilled!
    check tb.tryAcquireAt(t0 + 300_000_000'u64, 1) == true

  test "TokenBucket saturation does not leak phantom tokens or overflow":
    var tb = initTokenBucket(capacityTokens = 5, refillRatePerSec = 10)
    let t0 = 1_000_000_000'u64
    tb.resetAt(t0, 0)

    # Advance time by 100 seconds (far beyond capacity of 5)
    let tFar = t0 + 100'u64 * NanosPerSec
    check tb.availableAt(tFar) == 5

    # Consume all 5
    check tb.tryAcquireAt(tFar, 5) == true
    check tb.availableAt(tFar) == 0

    # 10ms later, only 0.1 tokens have refilled, not previous excess
    check tb.tryAcquireAt(tFar + 10_000_000'u64, 1) == false

  test "TokenBucket zero-drift precision across 1,000,000 queries":
    # Rate: 3,333 tokens/sec over 60 seconds (expected: 199,980 tokens)
    var tb = initTokenBucket(capacityTokens = 5000, refillRatePerSec = 3333)
    tb.resetAt(0, 0)

    const totalNs = 60'u64 * NanosPerSec
    const steps = 1_000_000'u64
    let stepNs = totalNs div steps

    var acquired = 0'u64
    for i in 1 .. steps:
      let now = i * stepNs
      if tb.tryAcquireAt(now, 1):
        inc acquired

    let expected = (totalNs * 3333'u64) div NanosPerSec
    check acquired == expected

  test "TokenBucket multi-rate precision verification":
    for rate in [7777'u64, 13337'u64]:
      var tb = initTokenBucket(capacityTokens = 10000, refillRatePerSec = rate)
      tb.resetAt(0, 0)
      const totalNs = 30'u64 * NanosPerSec
      const steps = 500_000'u64
      let stepNs = totalNs div steps
      var acquired = 0'u64
      for i in 1 .. steps:
        let now = i * stepNs
        if tb.tryAcquireAt(now, 1):
          inc acquired
      let expected = (totalNs * rate) div NanosPerSec
      check acquired == expected

  test "TokenBucket acquireWithTimeout immediate success and fail-fast":
    var tb = initTokenBucket(capacityTokens = 10, refillRatePerSec = 100, initialTokens = 5)

    # Immediate success when tokens available
    check tb.acquireWithTimeout(2, timeoutNs = 1_000_000) == true
    check tb.available == 3

    # Requested > capacity: immediate fail-fast (returns false in <10us)
    let tStart = getMonotonicTimeNs()
    check tb.acquireWithTimeout(100, timeoutNs = 50_000_000) == false
    let elapsed = getMonotonicTimeNs() - tStart
    check elapsed < 20_000_000'u64

    # Timeout = 0: behaves like non-blocking tryAcquire
    tb.reset(0)
    check tb.acquireWithTimeout(1, timeoutNs = 0) == false

  test "TokenBucket acquireWithTimeout precise sleep refill":
    var tb = initTokenBucket(capacityTokens = 10, refillRatePerSec = 100) # 1 token per 10ms
    tb.reset(0)

    # Wait for 1 token with 50ms timeout (requires 10ms wait)
    let t0 = getMonotonicTimeNs()
    let ok = tb.acquireWithTimeout(1, timeoutNs = 50_000_000)
    let dur = getMonotonicTimeNs() - t0
    check ok == true
    # Should have waited at least ~8ms
    check dur >= 7_000_000'u64

  test "TokenBucket multithreaded contention stress":
    const NumThreads = 16
    const OpsPerThread = 2000
    const TotalTokens = 16000'u64

    var tb = initTokenBucket(capacityTokens = TotalTokens, refillRatePerSec = 0, initialTokens = TotalTokens)

    type WorkerArg = object
      tb: ptr TokenBucket
      acquired: ptr Atomic[int]

    proc worker(arg: WorkerArg) {.thread.} =
      var localAcquired = 0
      for _ in 1 .. OpsPerThread:
        if arg.tb[].tryAcquire(1):
          inc localAcquired
      discard arg.acquired[].fetchAdd(localAcquired)

    var totalAcquired: Atomic[int]
    totalAcquired.store(0)

    var threads: array[NumThreads, Thread[WorkerArg]]
    for i in 0 ..< NumThreads:
      createThread(threads[i], worker, WorkerArg(tb: addr tb, acquired: addr totalAcquired))

    for i in 0 ..< NumThreads:
      joinThread(threads[i])

    # Exactly TotalTokens should have been acquired, none lost, none duplicated
    check totalAcquired.load() == int(TotalTokens)
    check tb.available == 0

  test "LeakyBucket (GCRA) zero burst tolerance uniform pacing":
    # Rate: 10 tokens/sec = 100ms per cell
    var lb = initLeakyBucket(burstToleranceNs = 0, leakRatePerSec = 10)
    check lb.burstTolerance == 0
    check lb.leakRate == 10

    let t0 = 1_000_000_000'u64

    # First arrival at t0 conforms
    check lb.tryConsumeAt(t0, 1) == true

    # Second arrival immediately at t0 fails (no burst tolerance)
    check lb.tryConsumeAt(t0, 1) == false

    # Arrival at t0 + 50ms fails (only half interval elapsed)
    check lb.tryConsumeAt(t0 + 50_000_000'u64, 1) == false

    # Arrival at t0 + 100ms conforms!
    check lb.tryConsumeAt(t0 + 100_000_000'u64, 1) == true

    # Water level check
    check lb.waterLevelAt(t0 + 100_000_000'u64) == 100_000_000'u64

  test "LeakyBucket (GCRA) burst tolerance governance":
    # Rate: 10/sec (T = 100ms), burst tolerance: 300ms (permits 1 + tau/T = 4 cells burst)
    var lb = initLeakyBucket(burstToleranceNs = 300_000_000, leakRatePerSec = 10)
    let t0 = 1_000_000_000'u64

    # Concurrently burst 4 cells (1 initial + 3 tolerance)
    check lb.tryConsumeAt(t0, 1) == true # cell 1
    check lb.tryConsumeAt(t0, 1) == true # cell 2
    check lb.tryConsumeAt(t0, 1) == true # cell 3
    check lb.tryConsumeAt(t0, 1) == true # cell 4

    # 5th cell exceeds burst limit
    check lb.tryConsumeAt(t0, 1) == false

    # After 100ms, 1 cell leaked out: 5th cell can now be admitted
    check lb.tryConsumeAt(t0 + 100_000_000'u64, 1) == true
    check lb.tryConsumeAt(t0 + 100_000_000'u64, 1) == false

  test "LeakyBucket (GCRA) burst tolerance smaller than increment (tau < T)":
    # Rate: 10 tokens/sec => T = 100ms. burstToleranceNs = 50ms (tau < T).
    # Under buggy code, increment (100ms) > limit (50ms) caused permanent rejection of ALL arrivals.
    # Under canonical GCRA:
    # First arrival at t0 has TAT = t0 <= t0 + 50ms, so it MUST conform and set TAT = t0 + 100ms.
    var lb = initLeakyBucket(burstToleranceNs = 50_000_000, leakRatePerSec = 10)
    let t0 = 1_000_000_000'u64

    # 1. First arrival at t0 conforms
    check lb.tryConsumeAt(t0, 1) == true

    # 2. Immediate second arrival at t0 fails (TAT is t0 + 100ms > t0 + 50ms)
    check lb.tryConsumeAt(t0, 1) == false

    # 3. Arrival at t0 + 49ms fails (TAT t0 + 100ms > t0 + 49ms + 50ms = t0 + 99ms)
    check lb.tryConsumeAt(t0 + 49_000_000'u64, 1) == false

    # 4. Arrival at t0 + 50ms conforms (TAT t0 + 100ms <= t0 + 50ms + 50ms = t0 + 100ms)
    check lb.tryConsumeAt(t0 + 50_000_000'u64, 1) == true

  test "LeakyBucket consumeWithTimeout":
    var lb = initLeakyBucket(burstToleranceNs = 0, leakRatePerSec = 100) # 10ms per cell
    let t0 = getMonotonicTimeNs()

    # 1st cell conforms immediately
    check lb.consumeWithTimeout(1, timeoutNs = 50_000_000) == true

    # 2nd cell requires 10ms wait: succeeds with 50ms timeout
    let ok = lb.consumeWithTimeout(1, timeoutNs = 50_000_000)
    let elapsed = getMonotonicTimeNs() - t0
    check ok == true
    check elapsed >= 7_000_000'u64

  test "C ABI functions (include/lockfree_ratelimit.h)":
    # TokenBucket C ABI
    var tbStruct: lfq_token_bucket_t
    check lfq_token_bucket_init(addr tbStruct, 20, 50) == 0
    check lfq_token_bucket_available(addr tbStruct) == 20
    check lfq_token_bucket_try_acquire(addr tbStruct, 5) == true
    check lfq_token_bucket_available(addr tbStruct) == 15
    check lfq_token_bucket_acquire_timeout(addr tbStruct, 5, 1_000_000) == true
    check lfq_token_bucket_available(addr tbStruct) == 10

    # Nil pointer resilience
    check lfq_token_bucket_init(nil, 10, 10) == -1
    check lfq_token_bucket_try_acquire(nil, 1) == false
    check lfq_token_bucket_acquire_timeout(nil, 1, 100) == false
    check lfq_token_bucket_available(nil) == 0

    # LeakyBucket C ABI
    var lbStruct: lfq_leaky_bucket_t
    check lfq_leaky_bucket_init(addr lbStruct, 200_000_000, 10) == 0
    check lfq_leaky_bucket_try_consume(addr lbStruct, 1) == true
    check lfq_leaky_bucket_water_level(addr lbStruct) > 0
    check lfq_leaky_bucket_init(nil, 0, 0) == -1
    check lfq_leaky_bucket_try_consume(nil, 1) == false
    check lfq_leaky_bucket_consume_timeout(nil, 1, 100) == false
    check lfq_leaky_bucket_water_level(nil) == 0

  test "Direct C99 Header Interoperability":
    let includeDir = currentSourcePath().parentDir() / ".." / "include"
    let cmd = "clang -fsyntax-only -std=c99 -Wall -Wextra -Werror -pedantic -Wstrict-prototypes -I" & includeDir & " " & (includeDir / "lockfree_ratelimit.h")
    let code = execShellCmd(cmd)
    check code == 0
