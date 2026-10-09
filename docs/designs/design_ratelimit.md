# Concurrency Architecture & Formal Invariants: 128-Bit DWCAS Rate Limiters

**Document ID**: `DESIGN-LOCKFREE-RATELIMIT-001`  
**Author**: Marcus Vance (`architect-horsetail`), Staff Systems Architect  
**Reviewers**: Caleb Thorne (`auditor-pegasus`), Elena Rostova (`implementer-kite`), Supreme Orchestrator (`orchestrator-whipbird`)  
**Status**: RATIFIED ARCHITECTURAL SPECIFICATION  
**Target Substrate**: `lockfree` (v0.1.0-consolidated)  
**Deliverable**: `docs/designs/design_ratelimit.md`  

---

## Concurrency Topology & Substrate Banner

```
====================================================================================================
Concurrency Topology: Hardware 128-Bit DWCAS Lock-Free Rate Limiters (Wave 4A)
====================================================================================================
| Dimension              | Architectural Specification                                             |
|:-----------------------|:------------------------------------------------------------------------|
| **Primitives**         | `TokenBucket` (Burst-tolerant metering) & `LeakyBucket` (GCRA smoothing)|
| **State Encoding**     | Packed 128-bit: `uint64 lastTimestampNs` + `uint64 availableTokens`     |
| **Atomic Substrate**   | Hardware 128-bit DWCAS (`cmpxchg16b` on x86_64, `casp` on ARMv8.1-A/LSE) |
| **Memory Alignment**   | 16-Byte Aligned Structs, Cacheline-Isolated (`align: 64` / `128`)        |
| **Progress Guarantees**| `tryAcquire`: Lock-Free / Wait-Free Speculative Probe                    |
|                        | `acquireWithTimeout`: Bounded-Wait Lock-Free with Precise OS Futex Sleep |
| **Arithmetic Precision**| Nanosecond Integer Fixed-Point (Q32.32 / Nanos-Scale); Zero Drift       |
| **Time Source**        | Monotonic OS Clock (`CLOCK_MONOTONIC_RAW` / Mach Absolute Time)          |
| **Burst Governance**   | Configurable Burst Capacity $C_{\text{burst}}$, Refill Rate $R_{\text{refill}}$ |
| **Memory Model**       | C11 / Weak-Memory Model: `moAcqRel` on DWCAS, `moAcquire` on Snapshots   |
| **Allocation Cost**    | Zero Dynamic Allocation on the Fast Path (Stack-allocatable value object)|
| **C ABI Interop**      | Full C99 foreign thread support via `include/lockfree_ratelimit.h`       |
====================================================================================================
```

---

## 1. Executive Summary & Problem Formulation

### 1.1 The High-Concurrency Rate-Limiting Challenge
Rate limiters and traffic shapers are fundamental components in high-throughput network stacks, RPC routers, distributed schedulers, and storage gateways. In modern multicore architectures (e.g. 64–128 hardware threads), traditional rate-limiting approaches suffer from catastrophic scalability bottlenecks:

1. **Mutex-Guarded State**:
   - Acquiring a lock to read a timestamp, calculate refilled tokens, and deduct a balance serializes all threads through a single cacheline.
   - Under heavy contention, lock overhead degrades throughput by orders of magnitude (lock convoys, OS context switches, and cache bounce).
2. **Split-Atomic Hazards (Separate Timestamps and Token Counters)**:
   - Attempting to avoid mutexes by using two 64-bit atomics (`Atomic[uint64]` timestamp and `Atomic[uint64]` tokens) introduces the classic **split-brain concurrency hazard**.
   - If Thread $A$ updates the timestamp while Thread $B$ concurrently deducts tokens, the calculations desynchronize. Schedulers either grant phantom tokens or starve threads due to race windows.
3. **Floating-Point Drift and Fractional Truncation**:
   - At microsecond scales, computing refilled tokens via naive floating-point division (`elapsed_sec * rate`) introduces floating-point non-determinism, rounding drift, and CPU floating-point unit register transitions.
   - Conversely, integer truncation (`elapsed_ns * rate / 1_000_000_000`) truncates fractional tokens to zero when polled at high frequency (e.g., 50 ns intervals), causing **token starvation** where the limiter never refills despite elapsed time!

### 1.2 The Wave 4A Solution
Wave 4A introduces **hardware-accelerated 128-bit Double-Word Compare-And-Swap (DWCAS)** lock-free rate limiters:
- **`TokenBucket`**: Burst-tolerant token-accumulation model for bursty workloads.
- **`LeakyBucket`**: Generic Cell Rate Algorithm (GCRA) virtual scheduling model for smooth traffic shaping.

By packing the 64-bit nanosecond timestamp and the 64-bit token balance into a contiguous 128-bit word, the entire rate limiter state transitions **atomically in a single CPU instruction** (`lock cmpxchg16b` on x86_64, `casp` on ARMv8.1-A).

---

## 2. Hardware 128-Bit DWCAS Substrate & Memory Geometry

### 2.1 Hardware Instruction Mapping
The rate limiter substrate leverages the battle-tested 128-bit atomics engine defined in `src/lockfree/atomics.nim`:

```
+---------------------------------------------------------------------------------------------------+
| Architecture       | Hardware DWCAS Instruction        | Memory Ordering Semantics               |
+:-------------------|:-----------------------------------|:----------------------------------------+
| **x86_64**         | `lock cmpxchg16b (%rdi)`           | Full hardware memory barrier (SeqCst)   |
| **AArch64 (LSE)**  | `casp x0, x1, x2, x3, [x4]`        | Acquire-Release (`caspal`) or Relaxed   |
| **AArch64 (v8.0)** | `ldxp` / `stxp` loop               | Load-Linked / Store-Conditional pair    |
| **MSVC (Win64)**   | `_InterlockedCompareExchange128`   | Full memory barrier (maps to cmpxchg16b)|
+---------------------------------------------------------------------------------------------------+
```

### 2.2 128-Bit Packed State Geometry

```
                      128-Bit Packed RateLimitState
 0                               63 64                             127
+----------------------------------+----------------------------------+
|      lastTimestampNs (64-bit)    |       tokensOrLevel (64-bit)     |
+----------------------------------+----------------------------------+
| Monotonic nanoseconds of last    | Available tokens (TokenBucket)   |
| state evaluation / replenishment | or current water level (Leaky)   |
+----------------------------------+----------------------------------+
|<----------------------- 16 Bytes (128 Bits) ---------------------->|
```

```nim
type
  RateLimitState* {.bycopy, align: 16.} = object
    lastTimestampNs*: uint64  ## Monotonic nanosecond timestamp of last refill
    tokensOrLevel*: uint64    ## Scaled fractional tokens or leaky water level

  TokenBucket* = object
    state* {.align: CacheLineBytes.}: RateLimitState
    capacity*: uint64          ## Maximum burst capacity (scaled)
    refillRatePerSec*: uint64  ## Tokens refilled per second
    scaleFactor*: uint64       ## Fixed-point scaling factor (e.g. 10^9)

  LeakyBucket* = object
    state* {.align: CacheLineBytes.}: RateLimitState
    capacity*: uint64          ## Maximum queue depth / burst tolerance
    leakRatePerSec*: uint64    ## Tokens leaked per second
    scaleFactor*: uint64       ## Fixed-point scaling factor
```

#### Memory Alignment Invariants:
1. **16-Byte Hardware Alignment**: The 128-bit state MUST be aligned to at least a 16-byte boundary (`align: 16`). Misaligned 128-bit operations on x86_64 cause a General Protection Fault (`#GP`), while on ARMv8 they trigger an Alignment Fault (`SIGBUS`).
2. **Cacheline Isolation**: The `TokenBucket` and `LeakyBucket` structures are placed on independent `CacheLineBytes` boundaries (64 bytes on x86_64, 128 bytes on Apple Silicon) to eliminate false sharing between concurrent rate limiters.

---

## 3. Mathematical Foundations: Zero-Drift Nanosecond Arithmetic

### 3.1 The Fractional Truncation Dilemma
Let $R$ be the refill rate in tokens per second, and $\Delta t$ be the elapsed time in nanoseconds:
$$\Delta \text{Tokens} = \Delta t \times \frac{R}{10^9}$$

If an engine evaluates arrivals at intervals where $\Delta t < \frac{10^9}{R}$:
$$\left\lfloor \frac{\Delta t \times R}{10^9} \right\rfloor = 0$$

If the rate limiter updates `lastTimestampNs = now` on every evaluation, the elapsed time $\Delta t$ is discarded, resulting in **100% token starvation under high contention**!

### 3.2 The Remainder-Preserving Time Advance Protocol
Wave 4A eliminates drift and starvation without floating-point arithmetic through the **Remainder-Preserving Protocol**.

Instead of advancing `lastTimestampNs` directly to `now`, `lastTimestampNs` is advanced ONLY by the exact duration that accounts for the refilled integer tokens:

$$\Delta t = \text{now} - \text{lastTimestampNs}$$
$$\text{refilledTokens} = \left\lfloor \frac{\Delta t \times R}{10^9} \right\rfloor$$
$$\Delta t_{\text{consumed}} = \frac{\text{refilledTokens} \times 10^9}{R}$$
$$\text{newTimestampNs} = \text{lastTimestampNs} + \Delta t_{\text{consumed}}$$

```
Time Timeline:
lastTimestampNs                                                now
      |------------------------- Delta t ----------------------->|
      |--------------------|------------------------------------>|
      |   Delta t_consumed |             Remainder               |
      v                    v                                     v
  Previous              Updated                             Preserved for
  Timestamp            Timestamp                             Next Refill
```

#### Mathematical Proof of Zero Drift:
$$\text{Remainder} = \text{now} - \text{newTimestampNs} = \Delta t - \Delta t_{\text{consumed}} < \frac{10^9}{R} \text{ ns}$$
- The remainder is strictly less than the duration of a single token.
- No nanosecond is ever discarded. Any fractional credit remains in the bucket and automatically compounds into the next arrival!

### 3.3 The Fixed-Point Scaled Token Substrate (Q32.32 / Nano-Tokens)
For ultra-low latency paths where division must be avoided on every request, Wave 4A provides the **Fixed-Point Nano-Token Representation**:
- 1 Token is represented as $10^9$ "nano-tokens" ($S = 10^9$).
- Refill calculation:
  $$\Delta \text{NanoTokens} = \Delta t_{\text{ns}} \times R$$
  Notice: This is a **pure 64-bit integer multiplication with ZERO division**!
- Token deduction: To consume $K$ tokens, deduct $K \times 10^9$ nano-tokens.
- New state:
  $$\text{newTimestampNs} = \text{now}$$
  $$\text{newTokens} = \min(C \times 10^9, \text{currentTokens} + \Delta \text{NanoTokens}) - (K \times 10^9)$$

---

## 4. Algorithmic State Machines

### 4.1 TokenBucket: `tryAcquire` (Lock-Free)

```
                     TokenBucket tryAcquire(k)
                                |
                                v
               [1. Atomic 128-Bit Load of State]
               oldState = (lastTimeNs, curTokens)
                                |
                                v
                   [2. Read Current Monotonic Time]
                         now = getMonotonicNs()
                                |
                                v
               [3. Compute Elapsed Time & Refill]
                   dt = max(0, now - oldState.lastTimeNs)
                   refill = (dt * refillRate) / 10^9
                   newTokens = min(capacity, curTokens + refill)
                                |
                                v
                 +------------------------------+
                 | Is newTokens >= requested?   |
                 +--------------+---------------+
                                |
                   YES          |          NO
                    |           |           |
                    v           |           v
   [4. Compute Desired State]   |      Return FALSE
   desired.tokens = newTokens - k
   desired.time = oldState.time + (refill * 10^9) / rate
                    |
                    v
    [5. Hardware 128-Bit DWCAS]
    dwcas(state, oldState, desired)
                    |
         +----------+----------+
         |                     |
      SUCCESS               FAILURE (Contention)
         |                     |
         v                     v
    Return TRUE          [Backoff & Retry Step 1]
```

#### Nim Implementation Blueprint:
```nim
proc tryAcquire*(self: var TokenBucket, requested: uint64 = 1): bool =
  var backoff = Backoff()
  while true:
    var oldState: RateLimitState
    dwcasLoad(self.state, oldState, moAcquire)
    
    let now = getMonotonicTimeNs()
    let elapsed = if now > oldState.lastTimestampNs: now - oldState.lastTimestampNs else: 0'u64
    let refilled = (elapsed * self.refillRatePerSec) div 1_000_000_000'u64
    let available = min(self.capacity, oldState.tokensOrLevel + refilled)
    
    if available < requested:
      return false
      
    var desired: RateLimitState
    desired.tokensOrLevel = available - requested
    let timeConsumed = (refilled * 1_000_000_000'u64) div self.refillRatePerSec
    desired.lastTimestampNs = oldState.lastTimestampNs + timeConsumed
    
    if dwcasCasWeak(self.state, oldState, desired, moAcqRel, moAcquire):
      return true
    backoff.pause()
```

---

### 4.2 LeakyBucket: GCRA (Generic Cell Rate Algorithm) Traffic Smoothing

While `TokenBucket` permits immediate consumption of up to `capacity` tokens (burst tolerance), `LeakyBucket` enforces **uniform spacing** between events.

In Wave 4A, `LeakyBucket` is architected using the **Virtual Scheduling / GCRA (Generic Cell Rate Algorithm)** model:
- Rather than maintaining an actual water queue, the bucket maintains a single 64-bit value: the **Theoretical Arrival Time (TAT)**.
- If arrivals arrive evenly spaced by interval $T = \frac{10^9}{\text{rate}}$, each arrival advances $\text{TAT} \leftarrow \text{TAT} + T$.
- A burst tolerance parameter $\tau$ (burst capacity expressed in time) permits arrivals to arrive slightly ahead of $\text{TAT}$, up to a limit:

$$\text{TAT} \le \text{now} + \tau$$

```
Timeline:
       now           TAT                                   now + tau
--------|-------------|----------------------------------------|--------->
                      ^                                        ^
                  Expected Arrival                          Maximum
                     Threshold                           Burst Boundary
```

#### LeakyBucket DWCAS Transition:
```nim
proc tryConsume*(self: var LeakyBucket, weight: uint64 = 1): bool =
  let increment = (weight * 1_000_000_000'u64) div self.leakRatePerSec
  var backoff = Backoff()
  while true:
    var oldState: RateLimitState
    dwcasLoad(self.state, oldState, moAcquire)
    
    let now = getMonotonicTimeNs()
    let tat = max(now, oldState.lastTimestampNs)
    
    # Check if new TAT exceeds maximum burst tolerance
    if tat + increment > now + self.capacity:
      return false # Rate limit exceeded (would cause overflow)
      
    var desired: RateLimitState
    desired.lastTimestampNs = tat + increment
    desired.tokensOrLevel = (desired.lastTimestampNs - now) # Current virtual water level
    
    if dwcasCasWeak(self.state, oldState, desired, moAcqRel, moAcquire):
      return true
    backoff.pause()
```

---

## 5. Bounded Timeout Acquisition: `acquireWithTimeout`

When `tryAcquire` fails because insufficient tokens are available, callers may elect to wait up to a specified timeout rather than spinning or dropping requests.

### 5.1 The Bounded Sleeping Protocol
Instead of polling the bucket in a tight spin loop, `acquireWithTimeout` calculates the **exact nanoseconds until sufficient tokens will be refilled**:

$$\text{deficit} = \text{requested} - \text{availableTokens}$$
$$\Delta t_{\text{wait}} = \left\lceil \frac{\text{deficit} \times 10^9}{\text{refillRate}} \right\rceil$$

```
Algorithm acquireWithTimeout(requested, timeoutNs):
1. startTime = getMonotonicNs()
2. Loop:
   a. Success = tryAcquire(requested)
   b. if Success: return true
   c. now = getMonotonicNs()
   d. elapsed = now - startTime
   e. if elapsed >= timeoutNs: return false
   f. remainingTimeout = timeoutNs - elapsed
   g. Calculate sleepTime = computeWaitDuration(requested)
   h. if sleepTime > remainingTimeout: return false
   i. Sleep for min(sleepTime, remainingTimeout) via OS Futex / High-Res Timer
3. Repeat Loop
```

**Benefits**:
- Zero CPU burn during wait periods.
- Precise wakeups synchronized to hardware token replenishment.
- Immediate fail-fast: if the required wait exceeds the caller's timeout, the procedure returns `false` without sleeping a single microsecond!

---

## 6. C ABI & Interoperability Layer

Wave 4A exports full C99 bindings for high-performance foreign thread integration:

### Header Specification: `include/lockfree_ratelimit.h`
```c
#ifndef LOCKFREE_RATELIMIT_H
#define LOCKFREE_RATELIMIT_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque 128-bit aligned structure handle
typedef struct {
    uint64_t last_timestamp_ns;
    uint64_t tokens_or_level;
} lfq_rate_limit_state_t;

typedef struct {
    alignas(64) lfq_rate_limit_state_t state;
    uint64_t capacity;
    uint64_t refill_rate_per_sec;
    uint64_t scale_factor;
} lfq_token_bucket_t;

typedef struct {
    alignas(64) lfq_rate_limit_state_t state;
    uint64_t burst_tolerance_ns;
    uint64_t leak_rate_per_sec;
    uint64_t scale_factor;
} lfq_leaky_bucket_t;

// TokenBucket API
int lfq_token_bucket_init(lfq_token_bucket_t* bucket, uint64_t capacity, uint64_t refill_rate);
bool lfq_token_bucket_try_acquire(lfq_token_bucket_t* bucket, uint64_t tokens);
bool lfq_token_bucket_acquire_timeout(lfq_token_bucket_t* bucket, uint64_t tokens, int64_t timeout_ns);
uint64_t lfq_token_bucket_available(const lfq_token_bucket_t* bucket);

// LeakyBucket (GCRA) API
int lfq_leaky_bucket_init(lfq_leaky_bucket_t* bucket, uint64_t burst_tolerance_ns, uint64_t leak_rate);
bool lfq_leaky_bucket_try_consume(lfq_leaky_bucket_t* bucket, uint64_t weight);
bool lfq_leaky_bucket_consume_timeout(lfq_leaky_bucket_t* bucket, uint64_t weight, int64_t timeout_ns);
uint64_t lfq_leaky_bucket_water_level(const lfq_leaky_bucket_t* bucket);

#ifdef __cplusplus
}
#endif

#endif // LOCKFREE_RATELIMIT_H
```

---

## 7. Formal Memory Ordering & Synchronization Proofs

### 7.1 Memory Ordering Invariant Table

| Operation | Atomic Target | Order | Formal Justification |
|:---|:---|:---|:---|
| `state` DWCAS Success | `RateLimitState` (128-bit) | `moAcqRel` | Establishes a total synchronization order across all competing acquiring threads. Guarantees linearizability of token deduction and time advances. |
| `state` DWCAS Failure | `RateLimitState` (128-bit) | `moAcquire` | Reloads freshest state on CAS failure, preventing stale reads during retry loops. |
| `state` Snapshot Load | `RateLimitState` (128-bit) | `moAcquire` | Guarantees atomic 128-bit observation of consistent (timestamp, token) tuple without torn reads. |
| Monotonic Time Read | OS Timer (`CLOCK_MONOTONIC`) | Compiler Barrier | Precludes instruction reordering of the timer probe across the atomic transition. |

### 7.2 Linearization Points
1. **Successful Acquisition (`tryAcquire` returns `true`)**:
   - Linearizes at the hardware DWCAS instruction (`cmpxchg16b` / `casp`) that successfully swaps `desired` into `state`.
2. **Failed Acquisition (`tryAcquire` returns `false`)**:
   - Linearizes at the atomic 128-bit load of `state` that proved `available < requested`.
3. **Leaky Bucket Consumption (`tryConsume`)**:
   - Linearizes at the DWCAS updating `lastTimestampNs` to the new Theoretical Arrival Time (TAT).

---

## 8. Verification Strategy & Two-Key Gate Criteria

Wave 4A requires exhaustive verification across concurrency, precision, and hardware portability dimensions:

1. **Precision & Zero-Drift Verification (`tests/t_ratelimit_drift.nim`)**:
   - Sustained 10,000,000 acquisition cycle test at non-power-of-two rates (e.g. 3,333 tokens/sec).
   - Assert that total tokens granted over a 60-second window equals $\text{rate} \times \text{elapsed} \pm 1$ token. Zero cumulative drift.
2. **High-Concurrency Contention Stress (`tests/t_ratelimit_stress.nim`)**:
   - 64 threads hammering a single `TokenBucket` concurrently via `tryAcquire(1)`.
   - Assert zero lost tokens, zero split-brain state transitions, and zero race conditions under ThreadSanitizer (`-fsanitize=thread`).
3. **Burst & Smoothing Profiling (`tests/t_ratelimit_gcra.nim`)**:
   - Measure inter-arrival intervals under `LeakyBucket` GCRA.
   - Confirm variance $\sigma^2 \to 0$ as burst capacity is lowered.
4. **Two-Key Integration Gate**:
   - Key 1 Mechanical Gate: Clean merge-tree SHA against `main`.
   - Key 2 Semantic Gate: 100% green compilation and test suite execution via `nimble test`.
