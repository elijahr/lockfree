# 128-Bit DWCAS Bounded MPMC Queue (`BQueue128`)

`BQueue128[T, N]` is a high-performance bounded MPMC queue optimized for 64-bit scalar types and raw pointers (`uint64`, `int64`, `pointer`, `int`). It utilizes hardware **128-Bit Double-Word Compare-And-Swap** (`CMPXCHG16B` on x86_64, `CASP` on ARM64 / Apple Silicon) to eliminate intermediate partial-write states and drastically improve cache density.

## Key Properties

| Property | Value |
| :--- | :--- |
| **Topologies** | MPMC, MPSC, SPMC, SPSC (fully multi-producer multi-consumer safe) |
| **Capacity** | Compile-time fixed power of two `N` (`4 .. 65536`) |
| **Payload Constraints** | 64-bit POD or pointers (`sizeof(T) <= 8`) |
| **Atomic Word** | 128 bits (`Pair[uint64, T]`) aligned to 16 bytes |
| **Instruction Count** | 1 atomic DWCAS to claim & publish (vs 2-step write+store in classic Vyukov) |
| **Memory Reclamation** | Zero heap allocation on hot paths, zero SMR, in-place slot reuse |
| **Cache Density** | 16 bytes per slot (4 slots per 64B cache line, 8 slots per 128B Apple Silicon line) |

---

## Classical Vyukov vs. 128-Bit DWCAS

In Dmitry Vyukov's classical bounded queue (`BQueue`), enqueueing an element requires two distinct memory operations:

1. **Turn Claim**: Producer verifies slot sequence `== pos` and advances `tail`.
2. **Data Write & Turn Publish**: Producer writes payload non-atomically into slot memory, then executes an atomic store releasing the next turn sequence `pos + 1`.

### The Descheduling Vulnerability in Classical Queues
If the producer thread is preempted or interrupted between step 1 and step 2, the slot remains in a half-written intermediate state. Downstream consumers reaching this slot must spin-wait until the preempted producer is rescheduled and completes step 2.

### The DWCAS Solution in `BQueue128`
`BQueue128` fuses the sequence turn counter and the 64-bit payload into a single 16-byte atomic structure:

```nim
type
  Pair[A, B] {.bycopy.} = object
    first*: A   # uint64 monotonic sequence turn counter
    second*: B  # 64-bit payload (uint64, int64, pointer, int)

  BQueue128Slot[T] = Atomic[Pair[uint64, T]]
```

Because both fields reside within a single 128-bit aligned word:
- **Enqueue (`tryPush`)**: A single atomic 128-bit CAS simultaneously matches the expected sequence turn, increments it to `pos + 1`, and installs the new payload. There is **no intermediate state** where the slot is claimed but unwritten.
- **Dequeue (`tryPop`)**: A single atomic 128-bit CAS simultaneously matches the ready sequence, advances it to `pos + N` (recycling the slot for the next turn around the ring), and extracts the payload.

---

## Cache Density & Footprint

Classical bounded queues often pad each slot to `CacheLineBytes` (64 or 128 bytes) to prevent false sharing during separate sequence and data writes. For large queues, this introduces substantial memory overhead (e.g. 1024 slots require 64KB or 128KB of memory).

In `BQueue128`:
- Each slot occupies exactly **16 bytes**.
- 4 full slots fit inside a standard 64-byte x86_64 cache line.
- 8 full slots fit inside an Apple Silicon M-series 128-byte cache line.
- Memory footprint is reduced by **75% to 87.5%**, improving L1/L2 CPU cache residency for high-throughput messaging pipelines.

---

## Construction and Usage

### Nim API

```nim
import lockfree

# 1. Stack Allocation (Value Object)
var q = initBQueue128[uint64, 1024]()

# Push elements
doAssert q.tryPush(0xDEADBEEF'u64)
doAssert q.len == 1

# Pop elements
var val: uint64
if q.tryPop(val):
  echo "Dequeued: ", val

# 2. Cacheline-Aligned Heap Allocation
let heapQ = allocAlignedBQueue128[pointer, 4096]()
defer: freeAlignedBQueue128(heapQ)

doAssert heapQ[].tryPush(cast[pointer](0x1234))
```

> [!IMPORTANT]
> `BQueue128` is strictly non-copyable (`=copy {.error.}`). Copying a queue holding live atomic turn sequences mid-stream violates memory invariants. Always pass by `var` or `ptr`.

---

## C ABI / FFI Interoperability

`BQueue128` is fully accessible from C99/C11 via `include/lockfree_bqueue128.h` (or `#include <lockfree.h>`):

```c
#include <stdio.h>
#include <lockfree.h>

int main(void) {
    lf_bqueue128_t* q = NULL;
    lf_status_t st = lf_bqueue128_create(1024, NULL, NULL, &q);
    if (st != LF_OK) return 1;

    // Enqueue
    lf_bqueue128_push(q, (void*)0xCAFE);

    // Dequeue
    void* item = NULL;
    if (lf_bqueue128_pop(q, &item) == LF_OK) {
        printf("Popped: %p\n", item);
    }

    lf_bqueue128_destroy(q);
    return 0;
}
```

---

## Empirical Benchmarks & Architectural Trade-offs

Measured on macOS ARM64 Apple Silicon (Capacity = 4096, 200,000 operations per run):

| Topology | `BQueue128` (DWCAS) | `BQueue` (Classical Vyukov) | Speedup / Trade-off |
| :--- | :--- | :--- | :--- |
| **1P x 1C** | **114.8M ops/sec** (114,813 ops/ms) | **34.3M ops/sec** (34,283 ops/ms) | **+235% (3.35x faster)** |
| **2P x 2C** | **13.2M ops/sec** (13,179 ops/ms) | **13.7M ops/sec** (13,672 ops/ms) | **~1.0x (parity)** |
| **4P x 4C** | **5.9M ops/sec** (5,918 ops/ms) | **14.8M ops/sec** (14,847 ops/ms) | Padded cells isolate contention |
| **8P x 8C** | **3.9M ops/sec** (3,895 ops/ms) | **19.7M ops/sec** (19,662 ops/ms) | Padded cells isolate contention |

### Architectural Recommendations

1. **Use `BQueue128` when**:
   - Workload is SPSC, MPSC, or low-to-medium contention MPMC (1–2 producers/consumers).
   - Payloads are 64-bit scalars or raw pointers (`uint64`, `int64`, `pointer`, `int`).
   - Memory footprint is critical: packing 4–8 slots per cache line reduces memory consumption by up to 75–87%.
   - Preemption resilience is vital: eliminates producer descheduling / partial-write stall vulnerabilities.

2. **Use classical `BQueue` when**:
   - Heavy concurrent contention across many threads (4+ producers and 4+ consumers simultaneously).
   - Payloads require object semantics or destructors under Path C.
   - Dedicated cache-line padding per slot is desired to isolate high-frequency cross-thread write invalidations.

