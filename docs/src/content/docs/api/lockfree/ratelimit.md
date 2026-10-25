---
title: "lockfree/ratelimit"
description: "API reference for lockfree/ratelimit"
---

<p>Concurrency Topology &amp; Mathematical Model:</p>
<table border="1" class="docutils"><tr><th>Dimension</th><th>Architectural Specification</th></tr>
<tr><td><strong>Primitives</strong></td><td><tt class="docutils literal"><span class="pre"><span class="Identifier">TokenBucket</span></span></tt> (Burst-tolerant) &amp; <tt class="docutils literal"><span class="pre"><span class="Identifier">LeakyBucket</span></span></tt> (GCRA virtual schedule)</td></tr>
<tr><td><strong>State Encoding</strong></td><td>Packed 128-bit: <tt class="docutils literal"><span class="pre"><span class="Identifier">uint64</span> <span class="Identifier">lastTimestampNs</span></span></tt> + <tt class="docutils literal"><span class="pre"><span class="Identifier">uint64</span> <span class="Identifier">tokensOrLevel</span></span></tt></td></tr>
<tr><td><strong>Atomic Substrate</strong></td><td>Hardware 128-bit DWCAS (<tt class="docutils literal"><span class="pre"><span class="Identifier">cmpxchg16b</span></span></tt> on x86_64, <tt class="docutils literal"><span class="pre"><span class="Identifier">casp</span></span></tt> on ARMv8.1-A/LSE)</td></tr>
<tr><td><strong>Memory Alignment</strong></td><td>16-Byte Aligned Structs, Cacheline-Isolated (<tt class="docutils literal"><span class="pre"><span class="Identifier">align</span><span class="Punctuation">:</span> <span class="Identifier">CacheLineBytes</span></span></tt>)</td></tr>
<tr><td><strong>Progress Guarantees</strong></td><td><tt class="docutils literal"><span class="pre"><span class="Identifier">tryAcquire</span></span></tt>: Lock-Free Speculative Probe</td></tr>
<tr><td></td><td><tt class="docutils literal"><span class="pre"><span class="Identifier">acquireWithTimeout</span></span></tt>: Bounded-Wait Lock-Free with Precise OS Sleep</td></tr>
<tr><td><strong>Arithmetic Precision</strong></td><td>Nanosecond Integer Fixed-Point (Nano-Tokens, S = 10^9); Zero Drift</td></tr>
<tr><td><strong>Burst Governance</strong></td><td>Configurable Burst Capacity C, Refill/Leak Rate R</td></tr>
<tr><td><strong>C ABI Interop</strong></td><td>C99 bindings declared in <tt class="docutils literal"><span class="pre"><span class="Keyword">include</span><span class="Operator">/</span><span class="Identifier">lockfree_ratelimit</span><span class="Operator">.</span><span class="Identifier">h</span></span></tt></td></tr>
</table><p>==============================================================================</p>


## Types

### `RateLimitState`

```nim
RateLimitState = Pair[uint64, uint64]
```

16-byte aligned pair storing:<ul class="simple"><li>first:  lastTimestampNs (Monotonic nanosecond timestamp)</li>
<li>second: tokensOrLevel (Available nano-tokens or GCRA virtual water level)</li>
</ul>

### `TokenBucket`

```nim
TokenBucket = object
  state* {.align: 128.}: Atomic[RateLimitState]
  capacity*: uint64          ## Maximum capacity in scaled nano-tokens
  refillRatePerSec*: uint64  ## Tokens refilled per second
  scaleFactor*: uint64       ## Scaling factor (default: 10^9 for nano-tokens)
```

Lock-free burst-tolerant token bucket using 128-bit hardware DWCAS. State transitions update timestamp and available tokens atomically.

### `TokenBucket128`

```nim
TokenBucket128 = TokenBucket
```

Explicit semantic alias for 128-bit hardware DWCAS token bucket.

### `LeakyBucket`

```nim
LeakyBucket = object
  state* {.align: 128.}: Atomic[RateLimitState]
  burstToleranceNs*: uint64  ## Burst tolerance tau in nanoseconds
  leakRatePerSec*: uint64    ## Tokens leaked per second
  scaleFactor*: uint64       ## Scaling factor (default: 1)
```

Lock-free GCRA (Generic Cell Rate Algorithm) traffic smoother. Enforces uniform spacing between events with bounded burst tolerance.

### `LeakyBucket128`

```nim
LeakyBucket128 = LeakyBucket
```

Explicit semantic alias for 128-bit hardware DWCAS leaky bucket.

### `TokenBucket64`

```nim
TokenBucket64 = object
  state* {.align: 128.}: Atomic[uint64]
  capacity*: uint32
  refillRatePerSec*: uint32
```

Universal 64-bit packed token bucket for architectures without 128-bit DWCAS or for minimal single-word cacheline footprints. State encoding: <a class="reference internal" href="#High 32 bits: Timestamp ms | Low 32 bits: Tokens">High 32 bits: Timestamp ms | Low 32 bits: Tokens</a>

### `LeakyBucket64`

```nim
LeakyBucket64 = object
  state* {.align: 128.}: Atomic[uint64]
  burstToleranceMs*: uint32
  leakRatePerSec*: uint32
```

Universal 64-bit packed GCRA leaky bucket for architectures without 128-bit DWCAS. State encoding: <a class="reference internal" href="#High 32 bits: TAT ms | Low 32 bits: Reserved/Sequence">High 32 bits: TAT ms | Low 32 bits: Reserved/Sequence</a>


## Constants

### `NanosPerSec`

```nim
NanosPerSec: uint64 = 1000000000'u64
```


## Procedures & Functions

### `rateLimitState`

```nim
proc rateLimitState(lastTimestampNs: uint64; tokensOrLevel: uint64): RateLimitState {.
    inline, raises: [], tags: [], forbids: [].}
```

### ``=copy``

```nim
proc `=copy`(dest: var TokenBucket; source: TokenBucket) {.error: "TokenBucket/LeakyBucket contains atomic state and cannot be copied. Pass by `var` or `ptr`.".}
```

### ``=copy``

```nim
proc `=copy`(dest: var LeakyBucket; source: LeakyBucket) {.error: "TokenBucket/LeakyBucket contains atomic state and cannot be copied. Pass by `var` or `ptr`.".}
```

### `getMonotonicTimeNs`

```nim
proc getMonotonicTimeNs(): uint64 {.inline, raises: [], tags: [TimeEffect],
                                    forbids: [].}
```

Returns current monotonic clock reading in nanoseconds.

### `sleepNanoseconds`

```nim
proc sleepNanoseconds(nanos: uint64) {.inline, raises: [], tags: [], forbids: [].}
```

High-precision OS sleeping for specified nanoseconds.

### `initTokenBucket`

```nim
proc initTokenBucket(capacityTokens: uint64; refillRatePerSec: uint64;
                     initialTokens: uint64 = uint64.high;
                     scaleFactor: uint64 = NanosPerSec): TokenBucket {.
    raises: [], tags: [TimeEffect], forbids: [].}
```

Initializes a TokenBucket with capacity, refill rate, and optional initial tokens. By default, tokens are scaled by 10^9 (nano-tokens) for zero-division, zero-drift refill.

### `capacity`

```nim
proc capacity(self: TokenBucket): uint64 {.inline, raises: [], tags: [],
    forbids: [].}
```

Returns total capacity in unscaled integer tokens.

### `capacityTokens`

```nim
proc capacityTokens(self: TokenBucket): uint64 {.inline, raises: [], tags: [],
    forbids: [].}
```

Returns total capacity in unscaled integer tokens (explicit alias).

### `capacityScaled`

```nim
proc capacityScaled(self: TokenBucket): uint64 {.inline, raises: [], tags: [],
    forbids: [].}
```

Returns total capacity in internal scaled nano-tokens.

### `refillRate`

```nim
proc refillRate(self: TokenBucket): uint64 {.inline, raises: [], tags: [],
    forbids: [].}
```

Returns refill rate in tokens per second.

### `scaleFactor`

```nim
proc scaleFactor(self: TokenBucket): uint64 {.inline, raises: [], tags: [],
    forbids: [].}
```

Returns internal scaling factor.

### `availableScaledAt`

```nim
proc availableScaledAt(self: var TokenBucket; now: uint64): uint64 {.raises: [],
    tags: [], forbids: [].}
```

Computes current available tokens in scaled units at reference timestamp <tt class="docutils literal"><span class="pre"><span class="Identifier">now</span></span></tt>.

### `availableAt`

```nim
proc availableAt(self: var TokenBucket; now: uint64): uint64 {.inline,
    raises: [], tags: [], forbids: [].}
```

Returns available unscaled tokens at reference timestamp <tt class="docutils literal"><span class="pre"><span class="Identifier">now</span></span></tt>.

### `available`

```nim
proc available(self: var TokenBucket): uint64 {.inline, raises: [],
    tags: [TimeEffect], forbids: [].}
```

Returns currently available unscaled tokens.

### `available`

```nim
proc available(self: TokenBucket): uint64 {.inline, raises: [],
    tags: [TimeEffect], forbids: [].}
```

### `tryAcquireAt`

```nim
proc tryAcquireAt(self: var TokenBucket; now: uint64; requested: uint64 = 1): bool {.
    raises: [], tags: [], forbids: [].}
```

Attempts to atomically acquire <tt class="docutils literal"><span class="pre"><span class="Identifier">requested</span></span></tt> tokens at reference timestamp <tt class="docutils literal"><span class="pre"><span class="Identifier">now</span></span></tt>. Lock-free: speculatively computes state transition and applies via 128-bit DWCAS.

### `tryAcquire`

```nim
proc tryAcquire(self: var TokenBucket; requested: uint64 = 1): bool {.inline,
    raises: [], tags: [TimeEffect], forbids: [].}
```

Attempts to atomically acquire <tt class="docutils literal"><span class="pre"><span class="Identifier">requested</span></span></tt> tokens at current monotonic time.

### `tryAcquire`

```nim
proc tryAcquire(self: ptr TokenBucket; requested: uint64 = 1): bool {.inline,
    raises: [], tags: [TimeEffect], forbids: [].}
```

### `acquireWithTimeout`

```nim
proc acquireWithTimeout(self: var TokenBucket; requested: uint64 = 1;
                        timeoutNs: int64 = -1): bool {.raises: [],
    tags: [TimeEffect], forbids: [].}
```

Bounded-timeout token acquisition. If insufficient tokens are available, calculates exact nanosecond refill deficit and sleeps via high-resolution timer. Fails fast if deficit exceeds remaining timeout.

### `acquireWithTimeout`

```nim
proc acquireWithTimeout(self: ptr TokenBucket; requested: uint64 = 1;
                        timeoutNs: int64 = -1): bool {.inline, raises: [],
    tags: [TimeEffect], forbids: [].}
```

### `resetAt`

```nim
proc resetAt(self: var TokenBucket; now: uint64; tokens: uint64 = uint64.high) {.
    raises: [], tags: [], forbids: [].}
```

Resets the TokenBucket state to specified timestamp and token level.

### `reset`

```nim
proc reset(self: var TokenBucket; tokens: uint64 = uint64.high) {.raises: [],
    tags: [TimeEffect], forbids: [].}
```

Resets the TokenBucket state to current monotonic time with specified tokens.

### `initLeakyBucket`

```nim
proc initLeakyBucket(burstToleranceNs: uint64; leakRatePerSec: uint64;
                     scaleFactor: uint64 = 1): LeakyBucket {.raises: [],
    tags: [], forbids: [].}
```

Initializes a LeakyBucket (GCRA) with burst tolerance in nanoseconds and leak rate.

### `initLeakyBucketWithBurst`

```nim
proc initLeakyBucketWithBurst(burstTokens: uint64; leakRatePerSec: uint64): LeakyBucket {.
    raises: [], tags: [], forbids: [].}
```

Initializes a LeakyBucket with burst capacity expressed in tokens.

### `burstTolerance`

```nim
proc burstTolerance(self: LeakyBucket): uint64 {.inline, raises: [], tags: [],
    forbids: [].}
```

### `leakRate`

```nim
proc leakRate(self: LeakyBucket): uint64 {.inline, raises: [], tags: [],
    forbids: [].}
```

### `waterLevelAt`

```nim
proc waterLevelAt(self: var LeakyBucket; now: uint64): uint64 {.raises: [],
    tags: [], forbids: [].}
```

Returns current virtual water level in nanoseconds at reference timestamp <tt class="docutils literal"><span class="pre"><span class="Identifier">now</span></span></tt>.

### `waterLevel`

```nim
proc waterLevel(self: var LeakyBucket): uint64 {.inline, raises: [],
    tags: [TimeEffect], forbids: [].}
```

### `waterLevel`

```nim
proc waterLevel(self: LeakyBucket): uint64 {.inline, raises: [],
    tags: [TimeEffect], forbids: [].}
```

### `tryConsumeAt`

```nim
proc tryConsumeAt(self: var LeakyBucket; now: uint64; weight: uint64 = 1): bool {.
    raises: [], tags: [], forbids: [].}
```

Evaluates GCRA conformance for arrival of weight <tt class="docutils literal"><span class="pre"><span class="Identifier">weight</span></span></tt> at timestamp <tt class="docutils literal"><span class="pre"><span class="Identifier">now</span></span></tt>. Conforms if scheduled arrival TAT &lt;= now + burstToleranceNs.

### `tryConsume`

```nim
proc tryConsume(self: var LeakyBucket; weight: uint64 = 1): bool {.inline,
    raises: [], tags: [TimeEffect], forbids: [].}
```

Evaluates GCRA conformance at current monotonic time.

### `tryConsume`

```nim
proc tryConsume(self: ptr LeakyBucket; weight: uint64 = 1): bool {.inline,
    raises: [], tags: [TimeEffect], forbids: [].}
```

### `consumeWithTimeout`

```nim
proc consumeWithTimeout(self: var LeakyBucket; weight: uint64 = 1;
                        timeoutNs: int64 = -1): bool {.raises: [],
    tags: [TimeEffect], forbids: [].}
```

Bounded-timeout GCRA consumption. If current burst limit is exceeded, calculates time until admission and sleeps.

### `consumeWithTimeout`

```nim
proc consumeWithTimeout(self: ptr LeakyBucket; weight: uint64 = 1;
                        timeoutNs: int64 = -1): bool {.inline, raises: [],
    tags: [TimeEffect], forbids: [].}
```

### `resetAt`

```nim
proc resetAt(self: var LeakyBucket; now: uint64) {.raises: [], tags: [],
    forbids: [].}
```

Resets LeakyBucket state to zero water level at specified timestamp.

### `reset`

```nim
proc reset(self: var LeakyBucket) {.raises: [], tags: [], forbids: [].}
```

Resets LeakyBucket state to zero water level.

### `available`

```nim
proc available(self: ptr TokenBucket): uint64 {.inline, raises: [],
    tags: [TimeEffect], forbids: [].}
```

### `waterLevel`

```nim
proc waterLevel(self: ptr LeakyBucket): uint64 {.inline, raises: [],
    tags: [TimeEffect], forbids: [].}
```

### ``=copy``

```nim
proc `=copy`(dest: var TokenBucket64; source: TokenBucket64) {.error: "TokenBucket64 contains atomic state and cannot be copied. Pass by `var` or `ptr`.".}
```

### ``=copy``

```nim
proc `=copy`(dest: var LeakyBucket64; source: LeakyBucket64) {.error: "LeakyBucket64 contains atomic state and cannot be copied. Pass by `var` or `ptr`.".}
```

### `getMonotonicTimeMs`

```nim
proc getMonotonicTimeMs(): uint32 {.inline, raises: [], tags: [TimeEffect],
                                    forbids: [].}
```

### `initTokenBucket64`

```nim
proc initTokenBucket64(capacityTokens: uint32; refillRatePerSec: uint32;
                       initialTokens: uint32 = uint32.high): TokenBucket64 {.
    raises: [], tags: [TimeEffect], forbids: [].}
```

Initializes a 64-bit packed lock-free token bucket.

### `capacity`

```nim
proc capacity(self: TokenBucket64): uint32 {.inline, raises: [], tags: [],
    forbids: [].}
```

### `refillRate`

```nim
proc refillRate(self: TokenBucket64): uint32 {.inline, raises: [], tags: [],
    forbids: [].}
```

### `availableAt`

```nim
proc availableAt(self: var TokenBucket64; nowMs: uint32): uint32 {.raises: [],
    tags: [], forbids: [].}
```

### `available`

```nim
proc available(self: var TokenBucket64): uint32 {.inline, raises: [],
    tags: [TimeEffect], forbids: [].}
```

### `tryAcquireAt`

```nim
proc tryAcquireAt(self: var TokenBucket64; nowMs: uint32; requested: uint32 = 1): bool {.
    raises: [], tags: [], forbids: [].}
```

### `tryAcquire`

```nim
proc tryAcquire(self: var TokenBucket64; requested: uint32 = 1): bool {.inline,
    raises: [], tags: [TimeEffect], forbids: [].}
```

### `acquireWithTimeout`

```nim
proc acquireWithTimeout(self: var TokenBucket64; requested: uint32 = 1;
                        timeoutMs: int = -1): bool {.raises: [],
    tags: [TimeEffect], forbids: [].}
```

### `initLeakyBucket64`

```nim
proc initLeakyBucket64(burstToleranceMs: uint32; leakRatePerSec: uint32): LeakyBucket64 {.
    raises: [], tags: [TimeEffect], forbids: [].}
```

Initializes a 64-bit packed lock-free GCRA leaky bucket.

### `burstTolerance`

```nim
proc burstTolerance(self: LeakyBucket64): uint32 {.inline, raises: [], tags: [],
    forbids: [].}
```

### `leakRate`

```nim
proc leakRate(self: LeakyBucket64): uint32 {.inline, raises: [], tags: [],
    forbids: [].}
```

### `tryConsumeAt`

```nim
proc tryConsumeAt(self: var LeakyBucket64; nowMs: uint32; weight: uint32 = 1): bool {.
    raises: [], tags: [], forbids: [].}
```

### `tryConsume`

```nim
proc tryConsume(self: var LeakyBucket64; weight: uint32 = 1): bool {.inline,
    raises: [], tags: [TimeEffect], forbids: [].}
```

### `consumeWithTimeout`

```nim
proc consumeWithTimeout(self: var LeakyBucket64; weight: uint32 = 1;
                        timeoutMs: int = -1): bool {.raises: [],
    tags: [TimeEffect], forbids: [].}
```


## Templates

### `lastTimestampNs`

```nim
template lastTimestampNs(s: RateLimitState): uint64
```

### `lastTimestampNs=`

```nim
template lastTimestampNs=(s: var RateLimitState; val: uint64)
```

### `tokensOrLevel`

```nim
template tokensOrLevel(s: RateLimitState): uint64
```

### `tokensOrLevel=`

```nim
template tokensOrLevel=(s: var RateLimitState; val: uint64)
```

### `initTokenBucket128`

```nim
template initTokenBucket128(capacityTokens: uint64; refillRatePerSec: uint64;
                            initialTokens: uint64 = uint64.high;
                            scaleFactor: uint64 = NanosPerSec): TokenBucket128
```

Explicit constructor for 128-bit hardware DWCAS TokenBucket.

### `initLeakyBucket128`

```nim
template initLeakyBucket128(burstToleranceNs: uint64; leakRatePerSec: uint64;
                            scaleFactor: uint64 = 1): LeakyBucket128
```

Explicit constructor for 128-bit hardware DWCAS LeakyBucket.

### `capacity`

```nim
template capacity(self: LeakyBucket): uint64
```

