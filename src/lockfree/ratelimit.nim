## ==============================================================================
## Hardware 128-Bit DWCAS Lock-Free Rate Limiters (Wave 4A)
## ==============================================================================
##
## Concurrency Topology & Mathematical Model:
## | Dimension               | Architectural Specification                                              |
## |:------------------------|:-------------------------------------------------------------------------|
## | **Primitives**          | `TokenBucket` (Burst-tolerant) & `LeakyBucket` (GCRA virtual schedule)   |
## | **State Encoding**      | Packed 128-bit: `uint64 lastTimestampNs` + `uint64 tokensOrLevel`        |
## | **Atomic Substrate**    | Hardware 128-bit DWCAS (`cmpxchg16b` on x86_64, `casp` on ARMv8.1-A/LSE) |
## | **Memory Alignment**    | 16-Byte Aligned Structs, Cacheline-Isolated (`align: CacheLineBytes`)     |
## | **Progress Guarantees** | `tryAcquire`: Lock-Free Speculative Probe                                |
## |                         | `acquireWithTimeout`: Bounded-Wait Lock-Free with Precise OS Sleep        |
## | **Arithmetic Precision**| Nanosecond Integer Fixed-Point (Nano-Tokens, S = 10^9); Zero Drift       |
## | **Burst Governance**    | Configurable Burst Capacity C, Refill/Leak Rate R                        |
## | **C ABI Interop**       | C99 bindings declared in `include/lockfree_ratelimit.h`                  |
## ==============================================================================

import lockfree/atomics
import lockfree/atomics/backoff
import lockfree/backoff
import lockfree/constants
import std/monotimes

const NanosPerSec*: uint64 = 1_000_000_000'u64

# ------------------------------------------------------------------------------
# 1. State Types & 128-Bit Layout
# ------------------------------------------------------------------------------

type
  RateLimitState* = Pair[uint64, uint64]
    ## 16-byte aligned pair storing:
    ## - first:  lastTimestampNs (Monotonic nanosecond timestamp)
    ## - second: tokensOrLevel (Available nano-tokens or GCRA virtual water level)

template lastTimestampNs*(s: RateLimitState): uint64 = s.first
template `lastTimestampNs=`*(s: var RateLimitState, val: uint64) = s.first = val

template tokensOrLevel*(s: RateLimitState): uint64 = s.second
template `tokensOrLevel=`*(s: var RateLimitState, val: uint64) = s.second = val

proc rateLimitState*(lastTimestampNs: uint64, tokensOrLevel: uint64): RateLimitState {.inline.} =
  Pair[uint64, uint64](first: lastTimestampNs, second: tokensOrLevel)

type
  TokenBucket* = object
    ## Lock-free burst-tolerant token bucket using 128-bit hardware DWCAS.
    ## State transitions update timestamp and available tokens atomically.
    state* {.align: CacheLineBytes.}: Atomic[RateLimitState]
    capacity*: uint64          ## Maximum capacity in scaled nano-tokens
    refillRatePerSec*: uint64  ## Tokens refilled per second
    scaleFactor*: uint64       ## Scaling factor (default: 10^9 for nano-tokens)

  TokenBucket128* = TokenBucket
    ## Explicit semantic alias for 128-bit hardware DWCAS token bucket.

  LeakyBucket* = object
    ## Lock-free GCRA (Generic Cell Rate Algorithm) traffic smoother.
    ## Enforces uniform spacing between events with bounded burst tolerance.
    state* {.align: CacheLineBytes.}: Atomic[RateLimitState]
    burstToleranceNs*: uint64  ## Burst tolerance tau in nanoseconds
    leakRatePerSec*: uint64    ## Tokens leaked per second
    scaleFactor*: uint64       ## Scaling factor (default: 1)

  LeakyBucket128* = LeakyBucket
    ## Explicit semantic alias for 128-bit hardware DWCAS leaky bucket.

proc `=copy`*(dest: var TokenBucket, source: TokenBucket) {.
    error: "TokenBucket/LeakyBucket contains atomic state and cannot be copied. Pass by `var` or `ptr`."
.}

proc `=copy`*(dest: var LeakyBucket, source: LeakyBucket) {.
    error: "TokenBucket/LeakyBucket contains atomic state and cannot be copied. Pass by `var` or `ptr`."
.}

# ------------------------------------------------------------------------------
# 2. Time & High-Resolution Sleep Utilities
# ------------------------------------------------------------------------------

proc getMonotonicTimeNs*(): uint64 {.inline.} =
  ## Returns current monotonic clock reading in nanoseconds.
  uint64(getMonoTime().ticks)

when defined(posix):
  type
    Timespec {.importc: "struct timespec", header: "<time.h>".} = object
      tv_sec: clong
      tv_nsec: clong
  proc c_nanosleep(req: ptr Timespec, rem: ptr Timespec): cint {.importc: "nanosleep", header: "<time.h>".}

  proc sleepNanoseconds*(nanos: uint64) {.inline.} =
    ## High-precision OS sleeping for specified nanoseconds.
    if nanos == 0: return
    if nanos < 2000'u64:
      for _ in 0 ..< 8: cpuPause()
      return
    var ts: Timespec
    ts.tv_sec = clong(nanos div NanosPerSec)
    ts.tv_nsec = clong(nanos mod NanosPerSec)
    discard c_nanosleep(addr ts, nil)
elif defined(windows):
  import std/os
  proc sleepNanoseconds*(nanos: uint64) {.inline.} =
    if nanos == 0: return
    let ms = int((nanos + 999_999'u64) div 1_000_000'u64)
    if ms > 0: os.sleep(ms)
    else: cpuPause()
else:
  import std/os
  proc sleepNanoseconds*(nanos: uint64) {.inline.} =
    if nanos == 0: return
    let ms = int((nanos + 999_999'u64) div 1_000_000'u64)
    os.sleep(max(1, ms))

# ------------------------------------------------------------------------------
# 3. TokenBucket Implementation (Zero-Drift Nano-Tokens)
# ------------------------------------------------------------------------------

proc initTokenBucket*(
    capacityTokens: uint64,
    refillRatePerSec: uint64,
    initialTokens: uint64 = uint64.high,
    scaleFactor: uint64 = NanosPerSec
): TokenBucket =
  ## Initializes a TokenBucket with capacity, refill rate, and optional initial tokens.
  ## By default, tokens are scaled by 10^9 (nano-tokens) for zero-division, zero-drift refill.
  result.refillRatePerSec = refillRatePerSec
  result.scaleFactor = if scaleFactor == 0: NanosPerSec else: scaleFactor

  # Guard against 64-bit integer multiplication overflow (HIGH-01)
  if capacityTokens > uint64.high div result.scaleFactor:
    result.capacity = uint64.high
  else:
    result.capacity = capacityTokens * result.scaleFactor

  let initTokens =
    if initialTokens == uint64.high:
      result.capacity
    else:
      min(result.capacity, initialTokens * result.scaleFactor)
  let now = getMonotonicTimeNs()
  result.state.store(Pair[uint64, uint64](first: now, second: initTokens))

template initTokenBucket128*(
    capacityTokens: uint64,
    refillRatePerSec: uint64,
    initialTokens: uint64 = uint64.high,
    scaleFactor: uint64 = NanosPerSec
): TokenBucket128 =
  ## Explicit constructor for 128-bit hardware DWCAS TokenBucket.
  initTokenBucket(capacityTokens, refillRatePerSec, initialTokens, scaleFactor)

proc capacity*(self: TokenBucket): uint64 {.inline.} =
  ## Returns total capacity in unscaled integer tokens.
  self.capacity div self.scaleFactor

proc capacityTokens*(self: TokenBucket): uint64 {.inline.} =
  ## Returns total capacity in unscaled integer tokens (explicit alias).
  self.capacity div self.scaleFactor

proc capacityScaled*(self: TokenBucket): uint64 {.inline.} =
  ## Returns total capacity in internal scaled nano-tokens.
  self.capacity

proc refillRate*(self: TokenBucket): uint64 {.inline.} =
  ## Returns refill rate in tokens per second.
  self.refillRatePerSec

proc scaleFactor*(self: TokenBucket): uint64 {.inline.} =
  ## Returns internal scaling factor.
  self.scaleFactor

proc availableScaledAt*(self: var TokenBucket, now: uint64): uint64 =
  ## Computes current available tokens in scaled units at reference timestamp `now`.
  let st = self.state.load(moSequentiallyConsistent)
  let elapsed = if now > st.first: now - st.first else: 0'u64
  if self.refillRatePerSec == 0:
    return st.second
  let maxDt = (self.capacity + self.refillRatePerSec - 1) div self.refillRatePerSec
  let added = if elapsed >= maxDt: self.capacity else: elapsed * self.refillRatePerSec
  min(self.capacity, st.second + added)

proc availableAt*(self: var TokenBucket, now: uint64): uint64 {.inline.} =
  ## Returns available unscaled tokens at reference timestamp `now`.
  self.availableScaledAt(now) div self.scaleFactor

proc available*(self: var TokenBucket): uint64 {.inline.} =
  ## Returns currently available unscaled tokens.
  self.availableAt(getMonotonicTimeNs())

proc available*(self: TokenBucket): uint64 {.inline.} =
  var copy = self
  copy.available()

proc tryAcquireAt*(self: var TokenBucket, now: uint64, requested: uint64 = 1): bool =
  ## Attempts to atomically acquire `requested` tokens at reference timestamp `now`.
  ## Lock-free: speculatively computes state transition and applies via 128-bit DWCAS.
  if unlikely(requested == 0):
    return true
  let reqScaled = requested * self.scaleFactor
  if reqScaled > self.capacity:
    return false

  var spins = InitialSpin
  var oldState = self.state.load(moSequentiallyConsistent)
  while true:
    let elapsed = if now > oldState.first: now - oldState.first else: 0'u64
    let maxDt =
      if self.refillRatePerSec > 0:
        (self.capacity + self.refillRatePerSec - 1) div self.refillRatePerSec
      else:
        0'u64

    let added =
      if self.refillRatePerSec == 0:
        0'u64
      elif elapsed >= maxDt:
        self.capacity
      else:
        elapsed * self.refillRatePerSec

    let available = min(self.capacity, oldState.second + added)
    if available < reqScaled:
      return false

    var desired: Pair[uint64, uint64]
    desired.first = max(now, oldState.first)
    desired.second = available - reqScaled

    if self.state.compareExchangeWeak(oldState, desired, moSequentiallyConsistent, moSequentiallyConsistent):
      return true
    backoffOnRetry(spins)

proc tryAcquire*(self: var TokenBucket, requested: uint64 = 1): bool {.inline.} =
  ## Attempts to atomically acquire `requested` tokens at current monotonic time.
  self.tryAcquireAt(getMonotonicTimeNs(), requested)

proc tryAcquire*(self: ptr TokenBucket, requested: uint64 = 1): bool {.inline.} =
  self[].tryAcquire(requested)

proc acquireWithTimeout*(
    self: var TokenBucket,
    requested: uint64 = 1,
    timeoutNs: int64 = -1
): bool =
  ## Bounded-timeout token acquisition.
  ## If insufficient tokens are available, calculates exact nanosecond refill deficit
  ## and sleeps via high-resolution timer. Fails fast if deficit exceeds remaining timeout.
  if unlikely(requested == 0):
    return true
  let reqScaled = requested * self.scaleFactor
  if reqScaled > self.capacity:
    return false

  let startNs = getMonotonicTimeNs()
  while true:
    let nowNs = getMonotonicTimeNs()
    if self.tryAcquireAt(nowNs, requested):
      return true

    if timeoutNs == 0:
      return false

    if timeoutNs > 0:
      let elapsedTotal = int64(nowNs - startNs)
      if elapsedTotal >= timeoutNs:
        return false
      let remainingTimeout = uint64(timeoutNs - elapsedTotal)

      if self.refillRatePerSec == 0:
        return false # Cannot refill without rate

      let curAvail = self.availableScaledAt(nowNs)
      if curAvail < reqScaled:
        let deficitScaled = reqScaled - curAvail
        let waitNs = (deficitScaled + self.refillRatePerSec - 1) div self.refillRatePerSec
        if waitNs > remainingTimeout:
          return false
        sleepNanoseconds(min(waitNs, remainingTimeout))
      else:
        sleepNanoseconds(1000'u64)
    else:
      # Infinite wait
      if self.refillRatePerSec == 0:
        return false
      let curAvail = self.availableScaledAt(nowNs)
      if curAvail < reqScaled:
        let deficitScaled = reqScaled - curAvail
        let waitNs = (deficitScaled + self.refillRatePerSec - 1) div self.refillRatePerSec
        sleepNanoseconds(waitNs)
      else:
        sleepNanoseconds(1000'u64)

proc acquireWithTimeout*(self: ptr TokenBucket, requested: uint64 = 1, timeoutNs: int64 = -1): bool {.inline.} =
  self[].acquireWithTimeout(requested, timeoutNs)

proc resetAt*(self: var TokenBucket, now: uint64, tokens: uint64 = uint64.high) =
  ## Resets the TokenBucket state to specified timestamp and token level.
  let setTokens =
    if tokens == uint64.high:
      self.capacity
    else:
      min(self.capacity, tokens * self.scaleFactor)
  self.state.store(Pair[uint64, uint64](first: now, second: setTokens))

proc reset*(self: var TokenBucket, tokens: uint64 = uint64.high) =
  ## Resets the TokenBucket state to current monotonic time with specified tokens.
  self.resetAt(getMonotonicTimeNs(), tokens)

# ------------------------------------------------------------------------------
# 4. LeakyBucket Implementation (GCRA Virtual Scheduling)
# ------------------------------------------------------------------------------

proc initLeakyBucket*(
    burstToleranceNs: uint64,
    leakRatePerSec: uint64,
    scaleFactor: uint64 = 1
): LeakyBucket =
  ## Initializes a LeakyBucket (GCRA) with burst tolerance in nanoseconds and leak rate.
  result.burstToleranceNs = burstToleranceNs
  result.leakRatePerSec = leakRatePerSec
  result.scaleFactor = if scaleFactor == 0: 1'u64 else: scaleFactor
  result.state.store(Pair[uint64, uint64](first: 0'u64, second: 0'u64))

template initLeakyBucket128*(
    burstToleranceNs: uint64,
    leakRatePerSec: uint64,
    scaleFactor: uint64 = 1
): LeakyBucket128 =
  ## Explicit constructor for 128-bit hardware DWCAS LeakyBucket.
  initLeakyBucket(burstToleranceNs, leakRatePerSec, scaleFactor)

proc initLeakyBucketWithBurst*(
    burstTokens: uint64,
    leakRatePerSec: uint64
): LeakyBucket =
  ## Initializes a LeakyBucket with burst capacity expressed in tokens.
  let burstToleranceNs =
    if leakRatePerSec > 0:
      (burstTokens * NanosPerSec) div leakRatePerSec
    else:
      0'u64
  initLeakyBucket(burstToleranceNs, leakRatePerSec)

proc burstTolerance*(self: LeakyBucket): uint64 {.inline.} =
  self.burstToleranceNs

template capacity*(self: LeakyBucket): uint64 =
  self.burstToleranceNs

proc leakRate*(self: LeakyBucket): uint64 {.inline.} =
  self.leakRatePerSec

proc waterLevelAt*(self: var LeakyBucket, now: uint64): uint64 =
  ## Returns current virtual water level in nanoseconds at reference timestamp `now`.
  let st = self.state.load(moSequentiallyConsistent)
  if st.first > now: st.first - now else: 0'u64

proc waterLevel*(self: var LeakyBucket): uint64 {.inline.} =
  self.waterLevelAt(getMonotonicTimeNs())

proc waterLevel*(self: LeakyBucket): uint64 {.inline.} =
  var copy = self
  copy.waterLevel()

proc tryConsumeAt*(self: var LeakyBucket, now: uint64, weight: uint64 = 1): bool =
  ## Evaluates GCRA conformance for arrival of weight `weight` at timestamp `now`.
  ## Conforms if scheduled arrival TAT <= now + burstToleranceNs.
  if unlikely(weight == 0):
    return true
  if unlikely(self.leakRatePerSec == 0):
    return false

  let weightWhole = weight div self.leakRatePerSec
  let weightRem = weight mod self.leakRatePerSec
  let increment = weightWhole * NanosPerSec + (weightRem * NanosPerSec) div self.leakRatePerSec

  var spins = InitialSpin
  var oldState = self.state.load(moSequentiallyConsistent)
  while true:
    let tat = max(now, oldState.first)
    # Canonical GCRA check: TAT must not exceed current time plus burst tolerance
    if tat > now + self.burstToleranceNs:
      return false

    var desired: Pair[uint64, uint64]
    desired.first = tat + increment
    desired.second = if desired.first > now: desired.first - now else: 0'u64

    if self.state.compareExchangeWeak(oldState, desired, moSequentiallyConsistent, moSequentiallyConsistent):
      return true
    backoffOnRetry(spins)

proc tryConsume*(self: var LeakyBucket, weight: uint64 = 1): bool {.inline.} =
  ## Evaluates GCRA conformance at current monotonic time.
  self.tryConsumeAt(getMonotonicTimeNs(), weight)

proc tryConsume*(self: ptr LeakyBucket, weight: uint64 = 1): bool {.inline.} =
  self[].tryConsume(weight)

proc consumeWithTimeout*(
    self: var LeakyBucket,
    weight: uint64 = 1,
    timeoutNs: int64 = -1
): bool =
  ## Bounded-timeout GCRA consumption.
  ## If current burst limit is exceeded, calculates time until admission and sleeps.
  if unlikely(weight == 0):
    return true
  if unlikely(self.leakRatePerSec == 0):
    return false

  let startNs = getMonotonicTimeNs()
  while true:
    let nowNs = getMonotonicTimeNs()
    if self.tryConsumeAt(nowNs, weight):
      return true

    if timeoutNs == 0:
      return false

    let st = self.state.load(moSequentiallyConsistent)
    let tat = max(nowNs, st.first)
    let waitNs = if tat > nowNs + self.burstToleranceNs: (tat - self.burstToleranceNs) - nowNs else: 1000'u64

    if timeoutNs > 0:
      let elapsedTotal = int64(nowNs - startNs)
      if elapsedTotal >= timeoutNs:
        return false
      let remainingTimeout = uint64(timeoutNs - elapsedTotal)
      if waitNs > remainingTimeout:
        return false
      sleepNanoseconds(min(waitNs, remainingTimeout))
    else:
      sleepNanoseconds(waitNs)

proc consumeWithTimeout*(self: ptr LeakyBucket, weight: uint64 = 1, timeoutNs: int64 = -1): bool {.inline.} =
  self[].consumeWithTimeout(weight, timeoutNs)

proc resetAt*(self: var LeakyBucket, now: uint64) =
  ## Resets LeakyBucket state to zero water level at specified timestamp.
  self.state.store(Pair[uint64, uint64](first: now, second: 0'u64))

proc reset*(self: var LeakyBucket) =
  ## Resets LeakyBucket state to zero water level.
  self.resetAt(0'u64)

# ------------------------------------------------------------------------------
# 5. C ABI Functions (include/lockfree_ratelimit.h)
# ------------------------------------------------------------------------------

type
  lf_rate_limit_state_t* {.exportc: "lf_rate_limit_state_t", bycopy.} = object
    last_timestamp_ns*: uint64
    tokens_or_level*: uint64
  lfq_rate_limit_state_t* = lf_rate_limit_state_t

  lf_token_bucket_t* {.exportc: "lf_token_bucket_t", bycopy.} = object
    state* {.align: CacheLineBytes.}: RateLimitState
    capacity*: uint64
    refill_rate_per_sec*: uint64
    scale_factor*: uint64
  lfq_token_bucket_t* = lf_token_bucket_t

  lf_leaky_bucket_t* {.exportc: "lf_leaky_bucket_t", bycopy.} = object
    state* {.align: CacheLineBytes.}: RateLimitState
    burst_tolerance_ns*: uint64
    leak_rate_per_sec*: uint64
    scale_factor*: uint64
  lfq_leaky_bucket_t* = lf_leaky_bucket_t

proc lf_token_bucket_init*(
    bucket: ptr lf_token_bucket_t,
    capacity: uint64,
    refill_rate: uint64
): cint {.exportc: "lf_token_bucket_init", cdecl, gcsafe, raises: [].} =
  if unlikely(bucket == nil):
    return -1
  try:
    let tb = cast[ptr TokenBucket](bucket)
    tb[] = initTokenBucket(capacity, refill_rate)
    0
  except:
    -1

proc lfq_token_bucket_init*(
    bucket: ptr lf_token_bucket_t,
    capacity: uint64,
    refill_rate: uint64
): cint {.exportc: "lfq_token_bucket_init", cdecl, gcsafe, raises: [].} =
  lf_token_bucket_init(bucket, capacity, refill_rate)

proc lf_token_bucket_try_acquire*(
    bucket: ptr lf_token_bucket_t,
    tokens: uint64
): bool {.exportc: "lf_token_bucket_try_acquire", cdecl, gcsafe, raises: [].} =
  if unlikely(bucket == nil):
    return false
  try:
    let tb = cast[ptr TokenBucket](bucket)
    tb.tryAcquire(tokens)
  except:
    false

proc lfq_token_bucket_try_acquire*(
    bucket: ptr lf_token_bucket_t,
    tokens: uint64
): bool {.exportc: "lfq_token_bucket_try_acquire", cdecl, gcsafe, raises: [].} =
  lf_token_bucket_try_acquire(bucket, tokens)

proc available*(self: ptr TokenBucket): uint64 {.inline.} =
  self[].available()

proc waterLevel*(self: ptr LeakyBucket): uint64 {.inline.} =
  self[].waterLevel()

proc lf_token_bucket_acquire_timeout*(
    bucket: ptr lf_token_bucket_t,
    tokens: uint64,
    timeout_ns: int64
): bool {.exportc: "lf_token_bucket_acquire_timeout", cdecl, gcsafe, raises: [].} =
  if unlikely(bucket == nil):
    return false
  try:
    let tb = cast[ptr TokenBucket](bucket)
    tb[].acquireWithTimeout(tokens, timeout_ns)
  except:
    false

proc lfq_token_bucket_acquire_timeout*(
    bucket: ptr lf_token_bucket_t,
    tokens: uint64,
    timeout_ns: int64
): bool {.exportc: "lfq_token_bucket_acquire_timeout", cdecl, gcsafe, raises: [].} =
  lf_token_bucket_acquire_timeout(bucket, tokens, timeout_ns)

proc lf_token_bucket_available*(
    bucket: ptr lf_token_bucket_t
): uint64 {.exportc: "lf_token_bucket_available", cdecl, gcsafe, raises: [].} =
  if unlikely(bucket == nil):
    return 0'u64
  try:
    let tb = cast[ptr TokenBucket](bucket)
    tb[].available()
  except:
    0'u64

proc lfq_token_bucket_available*(
    bucket: ptr lf_token_bucket_t
): uint64 {.exportc: "lfq_token_bucket_available", cdecl, gcsafe, raises: [].} =
  lf_token_bucket_available(bucket)

proc lf_leaky_bucket_init*(
    bucket: ptr lf_leaky_bucket_t,
    burst_tolerance_ns: uint64,
    leak_rate: uint64
): cint {.exportc: "lf_leaky_bucket_init", cdecl, gcsafe, raises: [].} =
  if unlikely(bucket == nil):
    return -1
  try:
    let lb = cast[ptr LeakyBucket](bucket)
    lb[] = initLeakyBucket(burst_tolerance_ns, leak_rate)
    0
  except:
    -1

proc lfq_leaky_bucket_init*(
    bucket: ptr lf_leaky_bucket_t,
    burst_tolerance_ns: uint64,
    leak_rate: uint64
): cint {.exportc: "lfq_leaky_bucket_init", cdecl, gcsafe, raises: [].} =
  lf_leaky_bucket_init(bucket, burst_tolerance_ns, leak_rate)

proc lf_leaky_bucket_try_consume*(
    bucket: ptr lf_leaky_bucket_t,
    weight: uint64
): bool {.exportc: "lf_leaky_bucket_try_consume", cdecl, gcsafe, raises: [].} =
  if unlikely(bucket == nil):
    return false
  try:
    let lb = cast[ptr LeakyBucket](bucket)
    lb[].tryConsume(weight)
  except:
    false

proc lfq_leaky_bucket_try_consume*(
    bucket: ptr lf_leaky_bucket_t,
    weight: uint64
): bool {.exportc: "lfq_leaky_bucket_try_consume", cdecl, gcsafe, raises: [].} =
  lf_leaky_bucket_try_consume(bucket, weight)

proc lf_leaky_bucket_consume_timeout*(
    bucket: ptr lf_leaky_bucket_t,
    weight: uint64,
    timeout_ns: int64
): bool {.exportc: "lf_leaky_bucket_consume_timeout", cdecl, gcsafe, raises: [].} =
  if unlikely(bucket == nil):
    return false
  try:
    let lb = cast[ptr LeakyBucket](bucket)
    lb[].consumeWithTimeout(weight, timeout_ns)
  except:
    false

proc lfq_leaky_bucket_consume_timeout*(
    bucket: ptr lf_leaky_bucket_t,
    weight: uint64,
    timeout_ns: int64
): bool {.exportc: "lfq_leaky_bucket_consume_timeout", cdecl, gcsafe, raises: [].} =
  lf_leaky_bucket_consume_timeout(bucket, weight, timeout_ns)

proc lf_leaky_bucket_water_level*(
    bucket: ptr lf_leaky_bucket_t
): uint64 {.exportc: "lf_leaky_bucket_water_level", cdecl, gcsafe, raises: [].} =
  if unlikely(bucket == nil):
    return 0'u64
  try:
    let lb = cast[ptr LeakyBucket](bucket)
    lb[].waterLevel()
  except:
    0'u64

proc lfq_leaky_bucket_water_level*(
    bucket: ptr lf_leaky_bucket_t
): uint64 {.exportc: "lfq_leaky_bucket_water_level", cdecl, gcsafe, raises: [].} =
  lf_leaky_bucket_water_level(bucket)

# ------------------------------------------------------------------------------
# 5. TokenBucket64 & LeakyBucket64 (Universal 64-Bit Packed Single-Word Atomics)
# ------------------------------------------------------------------------------

type
  TokenBucket64* = object
    ## Universal 64-bit packed token bucket for architectures without 128-bit DWCAS
    ## or for minimal single-word cacheline footprints.
    ## State encoding: [High 32 bits: Timestamp ms | Low 32 bits: Tokens]
    state* {.align: CacheLineBytes.}: Atomic[uint64]
    capacity*: uint32
    refillRatePerSec*: uint32

  LeakyBucket64* = object
    ## Universal 64-bit packed GCRA leaky bucket for architectures without 128-bit DWCAS.
    ## State encoding: [High 32 bits: TAT ms | Low 32 bits: Reserved/Sequence]
    state* {.align: CacheLineBytes.}: Atomic[uint64]
    burstToleranceMs*: uint32
    leakRatePerSec*: uint32

proc `=copy`*(dest: var TokenBucket64, source: TokenBucket64) {.
    error: "TokenBucket64 contains atomic state and cannot be copied. Pass by `var` or `ptr`."
.}

proc `=copy`*(dest: var LeakyBucket64, source: LeakyBucket64) {.
    error: "LeakyBucket64 contains atomic state and cannot be copied. Pass by `var` or `ptr`."
.}

proc getMonotonicTimeMs*(): uint32 {.inline.} =
  uint32((getMonoTime().ticks div 1_000_000'i64) and 0xFFFF_FFFF'i64)

proc packRateLimit64(highWord: uint32, lowWord: uint32): uint64 {.inline.} =
  (uint64(highWord) shl 32) or uint64(lowWord)

proc unpackRateLimit64(val: uint64): (uint32, uint32) {.inline.} =
  (uint32(val shr 32), uint32(val and 0xFFFF_FFFF'u64))

proc initTokenBucket64*(
    capacityTokens: uint32,
    refillRatePerSec: uint32,
    initialTokens: uint32 = uint32.high
): TokenBucket64 =
  ## Initializes a 64-bit packed lock-free token bucket.
  result.capacity = capacityTokens
  result.refillRatePerSec = refillRatePerSec
  let initTokens = if initialTokens == uint32.high: capacityTokens else: min(capacityTokens, initialTokens)
  let now = getMonotonicTimeMs()
  result.state.store(packRateLimit64(now, initTokens), moRelaxed)

proc capacity*(self: TokenBucket64): uint32 {.inline.} = self.capacity
proc refillRate*(self: TokenBucket64): uint32 {.inline.} = self.refillRatePerSec

proc availableAt*(self: var TokenBucket64, nowMs: uint32): uint32 =
  let st = self.state.load(moAcquire)
  let (lastTs, tokens) = unpackRateLimit64(st)
  let diff = int32(nowMs - lastTs)
  let elapsedMs = if diff > 0: uint32(diff) else: 0'u32
  if self.refillRatePerSec == 0:
    return tokens
  let added = uint32((uint64(elapsedMs) * uint64(self.refillRatePerSec)) div 1000'u64)
  uint32(min(uint64(self.capacity), uint64(tokens) + uint64(added)))

proc available*(self: var TokenBucket64): uint32 {.inline.} =
  self.availableAt(getMonotonicTimeMs())

proc tryAcquireAt*(self: var TokenBucket64, nowMs: uint32, requested: uint32 = 1): bool =
  if requested == 0: return true
  if requested > self.capacity: return false

  var spins = InitialSpin
  var oldVal = self.state.load(moAcquire)
  while true:
    let (lastTs, tokens) = unpackRateLimit64(oldVal)
    let diff = int32(nowMs - lastTs)
    let elapsedMs = if diff > 0: uint32(diff) else: 0'u32
    let added = if self.refillRatePerSec == 0: 0'u32 else: uint32((uint64(elapsedMs) * uint64(self.refillRatePerSec)) div 1000'u64)
    let avail = min(uint64(self.capacity), uint64(tokens) + uint64(added))
    if avail < uint64(requested):
      return false
    # Advance timestamp only by the duration that was converted to tokens,
    # or to nowMs if at capacity, preserving fractional milliseconds.
    let consumedMs =
      if self.refillRatePerSec > 0 and avail < uint64(self.capacity):
        (uint64(added) * 1000'u64) div uint64(self.refillRatePerSec)
      else:
        uint64(elapsedMs)
    let nextTs = lastTs + uint32(consumedMs)
    let nextTokens = uint32(avail - uint64(requested))
    let newVal = packRateLimit64(nextTs, nextTokens)
    if self.state.compareExchangeWeak(oldVal, newVal, moAcquireRelease, moAcquire):
      return true
    backoffOnRetry(spins)

proc tryAcquire*(self: var TokenBucket64, requested: uint32 = 1): bool {.inline.} =
  self.tryAcquireAt(getMonotonicTimeMs(), requested)

proc acquireWithTimeout*(
    self: var TokenBucket64,
    requested: uint32 = 1,
    timeoutMs: int = -1
): bool =
  if requested == 0: return true
  if requested > self.capacity: return false
  let startMs = getMonotonicTimeMs()
  while true:
    let nowMs = getMonotonicTimeMs()
    if self.tryAcquireAt(nowMs, requested):
      return true
    if timeoutMs == 0:
      return false
    if timeoutMs > 0:
      let elapsed = int(if nowMs >= startMs: nowMs - startMs else: (uint32.high - startMs) + nowMs + 1'u32)
      if elapsed >= timeoutMs:
        return false
    sleepNanoseconds(500_000)

proc initLeakyBucket64*(burstToleranceMs: uint32, leakRatePerSec: uint32): LeakyBucket64 =
  ## Initializes a 64-bit packed lock-free GCRA leaky bucket.
  result.burstToleranceMs = burstToleranceMs
  result.leakRatePerSec = leakRatePerSec
  let now = getMonotonicTimeMs()
  result.state.store(packRateLimit64(now, 0), moRelaxed)

proc burstTolerance*(self: LeakyBucket64): uint32 {.inline.} = self.burstToleranceMs
proc leakRate*(self: LeakyBucket64): uint32 {.inline.} = self.leakRatePerSec

proc tryConsumeAt*(self: var LeakyBucket64, nowMs: uint32, weight: uint32 = 1): bool =
  if weight == 0: return true
  if self.leakRatePerSec == 0: return false
  let costMs = uint32((uint64(weight) * 1000'u64) div uint64(self.leakRatePerSec))
  var spins = InitialSpin
  var oldVal = self.state.load(moAcquire)
  while true:
    let (tatMs, _) = unpackRateLimit64(oldVal)
    let newTat = max(nowMs, tatMs) + costMs
    let maxTat = nowMs + self.burstToleranceMs + costMs
    if newTat > maxTat:
      return false
    let newVal = packRateLimit64(newTat, 0)
    if self.state.compareExchangeWeak(oldVal, newVal, moAcquireRelease, moAcquire):
      return true
    backoffOnRetry(spins)

proc tryConsume*(self: var LeakyBucket64, weight: uint32 = 1): bool {.inline.} =
  self.tryConsumeAt(getMonotonicTimeMs(), weight)

proc consumeWithTimeout*(
    self: var LeakyBucket64,
    weight: uint32 = 1,
    timeoutMs: int = -1
): bool =
  if weight == 0: return true
  let startMs = getMonotonicTimeMs()
  while true:
    let nowMs = getMonotonicTimeMs()
    if self.tryConsumeAt(nowMs, weight):
      return true
    if timeoutMs == 0:
      return false
    if timeoutMs > 0:
      let elapsed = int(if nowMs >= startMs: nowMs - startMs else: (uint32.high - startMs) + nowMs + 1'u32)
      if elapsed >= timeoutMs:
        return false
    sleepNanoseconds(500_000)


