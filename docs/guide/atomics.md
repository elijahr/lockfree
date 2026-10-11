# Hardware Atomics & Memory Ordering

`lockfree/atomics` provides the hardware-level synchronization foundation for
all lock-free data structures in `lockfree`.

---

## 1. Atomics Model & Memory Orderings

`lockfree` wraps native compiler atomic builtins (C11 / GCC / Clang) through
a strongly-typed API:

```nim
import lockfree/atomics

var counter: Atomic[int]
counter.store(0, moRelaxed)

discard counter.fetchAdd(1, moSeqCst)
let current = counter.load(moAcquire)
```

### Memory Ordering Enum (`MemoryOrder`)

- `moRelaxed`: No ordering constraints; guarantees only atomicity of the single access.
- `moAcquire`: Acquire barrier; guarantees subsequent reads and writes cannot be reordered before this operation.
- `moRelease`: Release barrier; guarantees preceding reads and writes cannot be reordered after this operation.
- `moAcqRel`: Combines acquire and release semantics (common on RMW / CAS operations).
- `moSeqCst`: Sequential consistency; establishes a single total global order across all threads.

---

## 2. Hardware 128-bit Double-Word CAS (DWCAS)

Certain advanced lock-free structures (such as `strict-LCRQ` in `Queue`, and
the `TokenBucket` and `LeakyBucket` rate limiters) require atomic manipulation of
16-byte values (e.g. pointer + counter, or timestamp + token balance).

`lockfree` leverages native 128-bit hardware atomics:
- **x86_64**: `cmpxchg16b` instruction.
- **arm64**: `casp` / `ldxp` / `stxp` instructions.

Static compiler assertions ensure that `Atomic[T]` instantiations never silently
fall back to emulated spinlocks in `libatomic`.

---

## 3. Adaptive Backoff (`lockfree/atomics/backoff`)

When a thread encounters contention during an atomic loop, immediately retrying
the CAS burns memory bus bandwidth and causes cacheline bouncing.

`lockfree` employs adaptive backoff with graduated tiers:
1. **CPU Spin / Pause**: Executes CPU-specific pause instructions (`_mm_pause` on x86, `yield` on ARM) to reduce pipeline power and pipeline stalls.
2. **OS Thread Yield**: Yields execution quantum (`sched_yield()` / `SwitchToThread()`) to allow the contending thread to finish its operation.
3. **OS Sleep**: In prolonged wait states, briefly sleeps to allow high-load spikes to subside.

See the [Atomics API Reference](../api/atomics.md).
