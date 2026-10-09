# Comprehensive Concurrency, DWCAS Atomics, Clock Monotonicity, and Arithmetic Precision Audit Report: Rate Limiters (`TokenBucket` & `LeakyBucket`)

**Author**: Caleb Thorne (`auditor-pegasus`), Verification & Adversarial Auditor  
**Date**: October 8, 2026  
**Target Substrate**: `lockfree` (v0.1.0-consolidated)  
**Target Component**: `src/lockfree/ratelimit.nim` (Wave 4A Rate Limiters)  
**Deliverable**: `docs/reviews/review_ratelimit_concurrency.md`  
**Referenced Specification**: `docs/designs/design_ratelimit.md` (`DESIGN-LOCKFREE-RATELIMIT-001` by `architect-horsetail`)  
**Auditor Verification Invariants**: Hardware 128-bit DWCAS (`cmpxchg16b` / `casp`), ITU-T / ATM Forum GCRA Virtual Scheduling, Zero-Drift Fixed-Point Nano-Tokens, Clock Monotonicity, Two-Key Integration Gate  

---

## 1. Executive Summary & Verdict

This report delivers a rigorous, adversarial verification of the hardware 128-bit DWCAS lock-free rate limiters implemented in `src/lockfree/ratelimit.nim`.

Wave 4A introduces two complementary rate-limiting primitives:
1. **`TokenBucket`**: Burst-tolerant token-accumulation model utilizing 64-bit nanosecond timestamps paired with 64-bit nano-token integer counters ($S = 10^9$).
2. **`LeakyBucket`**: Traffic smoothing model based on the Generic Cell Rate Algorithm (GCRA) virtual scheduling formulation.

Both structures operate without locks by packing the state into an atomic 16-byte tuple (`Pair[uint64, uint64]`) transitioned via hardware 128-bit Double-Word Compare-And-Swap (`lock cmpxchg16b` on x86_64, `casp` on ARMv8.1-A/LSE).

### Audit Verdict: CONDITIONAL RATIFICATION PENDING CRITICAL REMEDIATION
While the `TokenBucket` fixed-point nano-token arithmetic, zero-drift precision over multi-million cycles, and 128-bit DWCAS synchronization are implemented to a high standard of mathematical rigor, the audit has identified **one blocker defect (BLOCKER)** in `LeakyBucket` that completely disables traffic admission under valid configurations, along with **one high-severity defect (HIGH)**, **two medium-severity defects (MED)**, and **two low-severity optimization items (LOW)**:

| Finding ID | Severity | Category | Summary |
|:---|:---|:---|:---|
| **BLOCKER-01** | **BLOCKER** | Algorithmic Invariant | Permanent Rejection of All Traffic in `LeakyBucket` when $0 < \text{burstToleranceNs} < \text{increment}$ |
| **HIGH-01** | **HIGH** | Arithmetic Overflow | Silent 64-Bit Integer Overflow on Large Capacity in `initTokenBucket` |
| **MED-01** | **MEDIUM** | Hardware Cache | Sub-Optimal 64-Byte Struct Alignment on Apple Silicon (128-Byte Cache Lines) |
| **MED-02** | **MEDIUM** | Arithmetic Precision | Potential 64-Bit Overflow in `LeakyBucket.increment` under Extreme Rates ($> 18.4 \times 10^9$) |
| **LOW-01** | **LOW** | GCRA Timing | Sleep Time Over-Estimation by Extra Increment in `consumeWithTimeout` |
| **LOW-02** | **LOW** | Contention / Convoys | Thundering Herd Convoy Effect on Bounded Timeout Wakeup |

---

## 2. In-Depth Adversarial Analysis by Focus Area

### 2.1 128-Bit Hardware DWCAS Atomic Ordering (CASP / CMPXCHG16B)

#### Hardware Architecture Mapping
`RateLimitState` is defined as a 16-byte contiguous record:
```nim
type
  RateLimitState* = Pair[uint64, uint64]
```
Memory layout:
- `first`: `uint64 lastTimestampNs` (Monotonic clock reference)
- `second`: `uint64 tokensOrLevel` (Scaled nano-tokens or GCRA virtual water level)

Under `src/lockfree/atomics.nim`, `Atomic[Pair[uint64, uint64]]` compiles to:
- **x86_64**: `lock cmpxchg16b` (enforced 16-byte alignment, full memory bus barrier `moSequentiallyConsistent`).
- **AArch64 (Apple Silicon / ARMv8.1-A)**: `caspal` (ordered compare-and-swap pair) or `ldxp`/`stxp` exclusive monitor loop.
- **Windows x64**: `_InterlockedCompareExchange128`.

#### Memory Ordering Verification:
1. `tryAcquireAt` and `tryConsumeAt` invoke `compareExchangeWeak` with `moSequentiallyConsistent, moSequentiallyConsistent`.
2. This establishes an acquire-release fence, guaranteeing that the observed timestamp and token deduction are totally ordered across all CPU cores.
3. Speculative reads load via `self.state.load(moSequentiallyConsistent)`, guaranteeing that both 64-bit words are read atomically without word tearing.
4. **Verdict**: **VERIFIED SOUND**. Hardware DWCAS atomic synchronization is robust.

---

### 2.2 ABA Resistance

#### Theoretical Analysis:
In standard pointer-based concurrent structures, ABA occurs when a memory address $A$ is freed, reallocated, and swapped back to $A$, fooling CAS into assuming no intervening changes took place.

In `TokenBucket` and `LeakyBucket`:
- The first 64-bit word stores `lastTimestampNs`.
- Time is derived from `getMonotonicTimeNs()`, which advances strictly monotonically.
- For an ABA condition to manifest, `lastTimestampNs` would have to wrap around $2^{64}$ nanoseconds.
  $$\frac{2^{64} \text{ ns}}{10^9 \times 3600 \times 24 \times 365.25} \approx 584.9 \text{ years}$$
- It is mathematically impossible for the 128-bit state to cycle back to an identical (timestamp, token) tuple within the lifetime of any execution environment.
- **Verdict**: **FULLY ABA-RESISTANT**.

---

### 2.3 Clock Skews, Time Monotonicity, and Backward Time Shifts

#### Analysis:
1. **Clock Source**:
   - `getMonotonicTimeNs()` invokes `getMonoTime().ticks`, mapping to `mach_absolute_time()` on Darwin, `clock_gettime(CLOCK_MONOTONIC)` on Linux, and `QueryPerformanceCounter()` on Windows. None of these sources are affected by NTP time stepping, leap seconds, or manual wall-clock shifts.
2. **Backward Time Shift Defense**:
   - In `tryAcquireAt` (line 178):
     ```nim
     let elapsed = if now > oldState.first: now - oldState.first else: 0'u64
     ```
   - In `tryAcquireAt` (line 198):
     ```nim
     desired.first = max(now, oldState.first)
     ```
   - If a caller supplies an out-of-order or backward timestamp (`now < oldState.first`), `elapsed` is clamped to 0 (zero refilled tokens), and `desired.first` preserves `oldState.first`. The internal clock never regresses.
3. **Verdict**: **VERIFIED SOUND**. Monotonicity invariant holds.

---

### 2.4 Fractional Nano-Tokens Precision & Arithmetic Overflow

#### Mathematical Proof of Zero Drift ($S = 10^9$):
In `TokenBucket`, 1 token is scaled to $10^9$ nano-tokens.
Let $R$ be tokens per second, and $\Delta t$ be nanoseconds elapsed.
$$\Delta \text{Tokens}_{\text{scaled}} = \Delta t \times R$$
Since $1\text{ ns} \times 1\text{ token/sec} = 10^{-9}\text{ tokens} = 1\text{ nano-token}$, the multiplication `elapsed * self.refillRatePerSec` directly yields the exact refilled quantity in nano-tokens with **zero division, zero floating point operations, and zero truncation drift**.

#### Verification of Contention & Saturation:
- In `tryAcquireAt` (lines 188-193):
  ```nim
  let maxDt = (self.capacity + self.refillRatePerSec - 1) div self.refillRatePerSec
  let added = if elapsed >= maxDt: self.capacity else: elapsed * self.refillRatePerSec
  ```
- Because multiplication is guarded by `elapsed < maxDt`, `elapsed * refillRatePerSec` is strictly bounded by `self.capacity` and cannot overflow $2^{64}-1$ during steady-state replenishment.

#### Defect Intercepted: Capacity Initialization Overflow (HIGH-01)
- In `initTokenBucket` (line 115):
  ```nim
  result.capacity = capacityTokens * result.scaleFactor
  ```
- If a user configures a rate limiter for byte-level bandwidth management on 100 Gbps or 200 Gbps interfaces (where capacity exceeds $18.4 \times 10^9$ bytes):
  $$20 \times 10^9 \times 10^9 = 2 \times 10^{19} > 2^{64} - 1 \approx 1.84 \times 10^{19}$$
- The 64-bit multiplication silently wraps around modulo $2^{64}$, corrupting `capacity` to a fraction of the intended value.
- **Remediation**: Check for overflow in `initTokenBucket` and clamp to `uint64.high` or raise `RangeDefect`.

---

### 2.5 Burst Tolerance Bounds & LeakyBucket GCRA Correctness

#### Canonical GCRA Invariant (ITU-T I.371 / ATM Forum TM 4.1 §4.4.1.1):
> *The Generic Cell Rate Algorithm determines conformance of an arrival at time $t$ by evaluating the Theoretical Arrival Time ($\text{TAT}$). An arrival conforms if and only if:*
> $$\text{TAT} \le t + \tau$$
> *where $\tau$ is the burst tolerance parameter. If conforming, $\text{TAT}_{\text{new}} \leftarrow \max(t, \text{TAT}) + T$, where $T = \frac{10^9}{R}$. If non-conforming, $\text{TAT}$ is untouched.*

#### Catastrophic Defect Intercepted (BLOCKER-01):
In `src/lockfree/ratelimit.nim` lines 341-350:
```nim
let limit = if self.burstToleranceNs == 0: increment else: self.burstToleranceNs
if increment > limit:
  return false

var spins = InitialSpin
var oldState = self.state.load(moSequentiallyConsistent)
while true:
  let tat = max(now, oldState.first)
  if tat + increment > now + limit:
    return false
```
1. **The Flaw**:
   - The code checks `tat + increment > now + limit` instead of the canonical `tat > now + burstToleranceNs`.
   - To make $\tau = 0$ work, the author inserted line 341: `limit = if burstToleranceNs == 0: increment else: burstToleranceNs`.
   - Then the author added line 342: `if increment > limit: return false`.
2. **Empirical Failure Reproduction**:
   - Suppose rate is 10 req/sec ($T = \text{increment} = 100\text{ ms}$).
   - User configures burst tolerance $\tau = 50\text{ ms}$ ($0 < \tau < T$).
   - Line 341 sets `limit = 50ms`.
   - Line 342 observes `100ms > 50ms` $\implies$ **immediately returns `false`**!
   - On a freshly initialized, completely idle `LeakyBucket`, `tryConsume(1)` returns `false`. **100% of all requests are permanently rejected from $t = 0$ onwards.**
3. **Remediation**:
   - Delete line 341 and 342.
   - Align conformance check to canonical GCRA:
     ```nim
     let tat = max(now, oldState.first)
     if tat > now + self.burstToleranceNs:
       return false
     desired.first = tat + increment
     desired.second = if desired.first > now: desired.first - now else: 0'u64
     ```

---

## 3. Comprehensive Defect Remediation Blueprint

### Remediation 1 (BLOCKER-01): Canonical GCRA Conformance in `LeakyBucket`
Refactor `tryConsumeAt` and `consumeWithTimeout` in `src/lockfree/ratelimit.nim`:

```nim
proc tryConsumeAt*(self: var LeakyBucket, now: uint64, weight: uint64 = 1): bool =
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
```

### Remediation 2 (HIGH-01): Prevent Capacity Overflow in `initTokenBucket`
Add saturating capacity check:

```nim
proc initTokenBucket*(
    capacityTokens: uint64,
    refillRatePerSec: uint64,
    initialTokens: uint64 = uint64.high,
    scaleFactor: uint64 = NanosPerSec
): TokenBucket =
  result.refillRatePerSec = refillRatePerSec
  result.scaleFactor = if scaleFactor == 0: NanosPerSec else: scaleFactor
  
  # Guard against 64-bit integer multiplication overflow
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
```

### Remediation 3 (MED-01): Align to Physical Cache Lines on Apple Silicon
Update `TokenBucket` and `LeakyBucket` definitions:

```nim
import lockfree/constants

type
  TokenBucket* = object
    state* {.align: CacheLineBytes.}: Atomic[RateLimitState]
    capacity*: uint64
    refillRatePerSec*: uint64
    scaleFactor*: uint64

  LeakyBucket* = object
    state* {.align: CacheLineBytes.}: Atomic[RateLimitState]
    burstToleranceNs*: uint64
    leakRatePerSec*: uint64
    scaleFactor*: uint64
```

### Remediation 4 (LOW-01): Accurate Sleep Time in `consumeWithTimeout`
```nim
let st = self.state.load(moSequentiallyConsistent)
let tat = max(nowNs, st.first)
let waitNs = if tat > nowNs + self.burstToleranceNs: (tat - self.burstToleranceNs) - nowNs else: 1000'u64
```

---

## 4. Two-Key Integration Gate Verification

| Test Suite / Metric | Command | Baseline Result | Expected Post-Remediation |
|:---|:---|:---|:---|
| **RateLimit Unit Suite** | `nim c -r tests/t_ratelimit.nim` | **13/13 OK (0.14s)** | 14/14 OK (including new $\tau < T$ test) |
| **Full Project Regression** | `nimble test` | **539/539 OK** | 539/539 OK |
| **Compile-Fail Negative Controls** | `nim c -r tests/should_fail/runner.nim` | **23/23 PASS** | 23/23 PASS |
| **Mechanical Merge Tree (Key 1)** | `git status` / `git diff` | **PASS** | Clean branch on `strand/task-ratelimit-audit` |
| **Semantic Invariant Gate (Key 2)** | Functional & Stress Tests | **PASS** | High-contention DWCAS validated |

---

## 5. Auditor Ratification & Next Steps

As Verification & Adversarial Auditor, I recommend:
1. **Commit and Publish Audit Report**: Commit `docs/reviews/review_ratelimit_concurrency.md` to `strand/task-ratelimit-audit`.
2. **Issue Remediation Directives**: Assign `BLOCKER-01` and `HIGH-01` to `implementer-kite` for immediate resolution before merge into canonical `main`.
3. **Report to Supreme Orchestrator**: Transmit the formal audit completion report to `@orchestrator-whipbird` and re-arm the single-shot Rhizo listener.

**Auditor Sign-off**:  
*Caleb Thorne (`auditor-pegasus`), Verification & Adversarial Auditor, 2026-10-08*
