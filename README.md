[![ci](https://github.com/elijahr/lockfree/actions/workflows/ci.yml/badge.svg)](https://github.com/elijahr/lockfree/actions/workflows/ci.yml)
[![docs](https://img.shields.io/badge/docs-latest-blue.svg)](https://elijahr.github.io/lockfree)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Nim](https://img.shields.io/badge/nim-%3E%3D2.2.10-orange.svg)](https://nim-lang.org)
[![Tests](https://img.shields.io/badge/tests-500%2B%20passing-brightgreen.svg)](tests/)
[![Sanitizers](https://img.shields.io/badge/sanitizers-TSAN%20%7C%20ASAN%20clean-success.svg)](tests/)

# lockfree

Lock-free concurrent data structures, communication channels, and safe memory reclamation for Nim and C.

The `lockfree` library provides non-blocking concurrent programming primitives across single-producer, multi-producer, single-consumer, and multi-consumer topologies. It consolidates the implementations previously published under `lockfreequeues` and `nim-debra`.

The package provides:
- Bounded ring buffers (`BQueue`) with static memory allocation and cache-line padded cells.
- 128-bit hardware DWCAS bounded ring buffers (`BQueue128`) with single-instruction atomic publish and dense 16-byte slots.
- Unbounded dynamic-segment queues (`Queue`) using Morrison-Afek strict-LCRQ with 128-bit DWCAS.
- Communication channels (`Channel`) with automatic thread-local registration.
- Synchronous zero-buffer dual queues (`RendezvousChannel`) with kernel futex wait/wake.
- Associative maps (`Ctrie`, `SkipListMap`) and concurrent sets (`SkipListSet`).
- LIFO stacks (`TreiberStack`) with elimination backoff and work-stealing deques (`ChaseLevDeque`).
- Multicast fan-out rings (`BroadcastRing`, `TopicBus`) with configurable overflow policies.
- Work-stealing task pool and scheduler (`TaskPool`).
- Rate limiters (`TokenBucket`, `LeakyBucket`) and circular byte streaming (`StreamBuffer`).
- Safe memory reclamation via Neutralization-Enhanced Bounded Epoch Reclamation (`lockfree/smr/nebr`).
- Foreign function interface exports via C ABI headers (`include/lockfree.h` and `include/lockfree_bqueue128.h`).
- Verified safety with 500+ tests under ThreadSanitizer (TSAN) and AddressSanitizer (ASAN), with 32 negative compile-time rejection controls.

---

## Compatibility

| Requirement | Supported |
|-------------|-----------|
| **Nim Version** | `>= 2.2.10` |
| **Memory Managers** | `orc` (default), `arc`, `atomicArc` (`refc` retired) |
| **Backends** | C (`nim c`), C++ (`nim cpp`) |
| **Threading** | `--threads:on` required (default in Nim 2.2+) |
| **Platforms (CI-verified)** | Linux x86_64, Linux arm64, macOS Apple Silicon (arm64) |
| **Sanitizers (CI-verified)** | ThreadSanitizer (under `atomicArc`), AddressSanitizer |
| **Dependencies** | [`typestates`](https://github.com/elijahr/nim-typestates) `>= 0.12.0` |
| **License** | MIT |

---

## Installation

```sh
nimble install lockfree
```

---

## Quick Start

### 1. High-Level Channel Facade

The `Channel[T]` facade provides an ergonomic, Go/Rust-style communication channel built on top of the lock-free queue engines:

```nim
import std/options
import lockfree/channel

# Create a bounded channel with capacity 64
var chan = newBoundedChannel[int](64)

# Multi-producer, multi-consumer safe
var sender = chan.clone()
var receiver = chan.clone()

# Send values (returns false if full or closed)
assert sender.send(42)
assert sender.send(100)

# Receive values
let val = receiver.tryRecv()
assert val == some(42)

# When all senders drop, receivers unblock cleanly
sender.close()
assert receiver.isClosed()
```

### 2. Bounded Queues

Bounded queues are pre-allocated ring buffers with compile-time capacity. Single-cardinality sides push/pop directly on the queue; multi-cardinality sides operate through endpoint handles:

```nim
import std/options
import lockfree

# Bounded single-producer, single-consumer (SPSC) queue of capacity 16:
var spsc = newSpscQueue[int, 16]()
assert spsc.push(42)
assert spsc.pop() == some(42)

# Bounded multi-producer, multi-consumer (MPMC) queue:
var mpmc = newMpmcQueue[int, 64, 4, 4]() # Capacity 64, 4 producers, 4 consumers
var prod = mpmc.getProducer()
var cons = mpmc.getConsumer()

assert prod.push(101)
assert cons.pop() == some(101)

# 128-bit hardware DWCAS bounded queue (16-byte dense slots, single-instruction publish):
var dwcasQ = initBQueue128[int, 1024]()
assert dwcasQ.tryPush(200)
var poppedVal: int
assert dwcasQ.tryPop(poppedVal) and poppedVal == 200
```

### 3. Unbounded Queues (`Queue` + NEBR)

Unbounded queues allocate linked segments dynamically and use NEBR epoch-based memory reclamation for safe segment deallocation:

```nim
import std/options
import lockfree

# Unbounded MPMC queue: segment size 8, registry sized for up to 4 lifetime threads.
# An internal DebraManager is automatically provisioned.
var queue = newUnboundedMpmcQueue[int, stEager, 8, 4]()

var producer = queue.getProducer()
producer.attach()           # Call on the operating thread prior to first push
producer.push(42)           # Unbounded push never blocks on capacity

var consumer = queue.getConsumer()
consumer.attach()           # Call on the operating thread prior to first pop
assert consumer.pop() == some(42)
```

### 4. Cross-Language C ABI (`include/lockfree.h`)

`lockfree` exports a C-linkable ABI for high-performance cross-language messaging:

```c
#include "lockfree.h"
#include <assert.h>

int main() {
    lfq_queue_t* queue = NULL;
    lfq_config_t config = {
        .cardinality = LFQ_CARDINALITY_MPMC,
        .capacity = 1024,
        .elem_size = sizeof(int64_t),
        .max_producers = 4,
        .max_consumers = 4
    };
    
    assert(lfq_queue_create(&config, &queue) == LFQ_OK);
    
    lfq_producer_t* prod = NULL;
    lfq_consumer_t* cons = NULL;
    assert(lfq_producer_attach(queue, &prod) == LFQ_OK);
    assert(lfq_consumer_attach(queue, &cons) == LFQ_OK);
    
    int64_t val = 42;
    assert(lfq_push(prod, &val) == LFQ_OK);
    
    int64_t out = 0;
    assert(lfq_pop(cons, &out) == LFQ_OK);
    assert(out == 42);
    
    lfq_producer_release(prod);
    lfq_consumer_release(cons);
    lfq_queue_destroy(queue);
    return 0;
}
```

---

## 128-Bit Hardware Atomics Engine

At the core of `lockfree`'s Morrison-Afek LCRQ unbounded MPMC queue and NEBR reclaimer is a high-performance 128-bit (Double-Word CAS / DWCAS) hardware atomics engine (`lockfree/atomics`). Unlike naive implementations that downgrade to non-atomic spinlocks under contention, `lockfree` generates native, lock-free 16-byte CPU instructions across all primary compiler backends and architectures:

- **x86_64 (`cmpxchg16b`)**: Emits native `lock cmpxchg16b` with `-mcx16` via GCC/Clang builtins (`__sync_val_compare_and_swap` / `__atomic_compare_exchange_n`), providing hardware-level atomic verification on 16-byte pair cells (`Pair[uint, T]`).
- **AArch64 / ARM64 (ARMv8.1-A+ LSE & Apple Silicon)**: Emits native hardware `casp` / `caspal` (Large System Extensions). Objdump-verified on Apple Silicon (M1/M2/M3/M4) to produce zero spurious failures, with automated fallback to `ldxp`/`stxp` exclusive pairs on legacy ARMv8.0 cores.
- **Windows / MSVC (`vcc`)**: Leverages Microsoft `<intrin.h>` `_InterlockedCompareExchange128` intrinsics with sequentially-consistent hardware barrier semantics, synthesizing lock-free 128-bit load, store, exchange, and CAS primitives without external dependencies.
- **Static Alignment Guarantee**: Statically enforces 16-byte alignment (`alignof >= 16`) across all 128-bit atomic cells, guaranteeing zero hardware bus faults or split-lock performance degradation.

---

## Concurrency Topology & Collections

`lockfree` organizes collections across topologies, progress guarantees, and memory models. All collections share the Path-C zero-race memory model:

| Topology | Collection Type | Constructor / Alias | Progress (Push / Pop) | Allocation | Memory Reclamation |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **SPSC** | `BQueue` | `newSpscQueue[T, N]()` / `BoundedSpscQueue` | Wait-free / Wait-free | Zero-alloc (Ring buffer) | None (Static slots) |
| **SPSC** | `Queue` | `newUnboundedSpscQueue[T, S]()` | Wait-free / Wait-free | Linked Segments | Inline Segment Free |
| **SPMC** | `BQueue` | `newSpmcQueue[T, N, C]()` / `BoundedSpmcQueue` | Wait-free / Lock-free | Zero-alloc (Ring buffer) | None (Static slots) |
| **SPMC** | `Queue` | `newUnboundedSpmcQueue[T, Strategy, S, MaxT]()` | Wait-free / Lock-free | Linked Segments | NEBR Epoch SMR |
| **MPSC** | `BQueue` | `newMpscQueue[T, N, P]()` / `BoundedMpscQueue` | Lock-free / Wait-free | Zero-alloc (Ring buffer) | None (Static slots) |
| **MPSC** | `Queue` | `newUnboundedMpscQueue[T, Strategy, S, MaxT]()` | Lock-free / Wait-free | Linked Segments | NEBR Epoch SMR |
| **MPMC** | `BQueue` | `newMpmcQueue[T, N, P, C]()` / `BoundedMpmcQueue` | Lock-free / Lock-free | Zero-alloc (Ring buffer) | None (Static slots) |
| **MPMC / SPSC** | `BQueue128` | `initBQueue128[T, N]()` / `allocAlignedBQueue128[T, N]()` | Lock-free (DWCAS) / Lock-free (DWCAS) | Zero-alloc (Ring buffer) | None (Static 16B slots) |
| **MPMC** | `Queue` | `newUnboundedMpmcQueue[T, Strategy, S, MaxT]()` | Lock-free (LCRQ DWCAS) / Lock-free | Linked Segments | NEBR Epoch SMR |
| **MPMC** | `BStack` | `initBStack[T, Cap]()` / `BoundedStack` | Lock-free / Lock-free | Zero-alloc (Indexed pool) | None (64-bit ABA tag) |
| **MPMC** | `Stack` | `initTreiberStack[T]()` / `ConcurrentStack` | Lock-free / Lock-free | Dynamic Heap Nodes | NEBR Epoch SMR + Tagged DWCAS |
| **MPMC** | `BPriorityQueue` | `initBPriorityQueue[T, Cap]()` / `BoundedPriorityQueue` | Flat-Combined Delegation | Zero-alloc (Binary heap) | None (Static array) |
| **MPMC** | `SkipListPriorityQueue` | `newSkipListPriorityQueue[T]()` / `PriorityQueue` | Lock-free / Lock-free | Dynamically Unbounded | NEBR Epoch SMR |
| **Worker / Thief** | `Deque` | `initChaseLevDeque[T]()` / `ConcurrentDeque` | Lock-free (Bottom) / Lock-free (Top) | Dynamic Circular Buffer | Retired-Chain SMR |
| **MPMC** | `BTable` | `initBTable[K, V, Cap]()` / `BoundedTable` | Wait-free (`len`/`isEmpty`) / Flat-Combined (`tryGet`/`tryPut`) | Zero-alloc (Open address) | None (Per-slot seq counter) |
| **MPMC** | `Ctrie` | `newCtrie[K, V]()` / `Table` / `ConcurrentTable` | Lock-free / Wait-free ($O(1)$ Snapshot) | Dynamically Unbounded | NEBR Epoch SMR |
| **MPMC** | `SkipListMap` | `newSkipListMap[K, V]()` / `SortedTable` | Lock-free (Put/Del) / Wait-free (Get) | Dynamically Unbounded | NEBR Epoch SMR |
| **MPMC** | `SkipListSet` | `newSkipListSet[T]()` / `ConcurrentSet` | Lock-free (Ins/Rem) / Wait-free (Has) | Dynamically Unbounded | NEBR Epoch SMR |
| **MPMC** | `FlatCombiner` | `newFlatCombiner[T, Op, Res]()` | Flat-Combined Delegation | Static 64-Slot Array | Thread-Local Slot Reuse |
| **SPMC / MPMC** | `BroadcastRing` | `newBroadcastRing[T](cap)` / `TopicBus` | Wait-free (SPMC) / Lock-free (MPMC) | Zero-alloc (Ring buffer) | Sequence Overwrite |
| **MPMC** | `RateLimiter` | `initTokenBucket` / `initLeakyBucket` | Lock-free (128-bit DWCAS) | Zero-alloc (16B state) | None (In-place state) |
| **SPSC / MPSC** | `StreamBuffer` | `newStreamBuffer(cap)` | Lock-free | Zero-alloc (Byte ring) | None (In-place ring) |
| **CSP** | `Channel` | `newBoundedChannel[T](cap)` / `newChannel[T]` | Lock-free / Lock-free | Dynamic Tiers (64, 1024, 65536) | None (BQueue-backed) |
| **CSP** | `Channel` | `newUnboundedChannel[T](segSize)` | Lock-free / Lock-free | Linked Segments | NEBR Epoch SMR |
| **CSP (0-Buf)** | `RendezvousChannel` | `newRendezvousChannel[T]()` | Lock-free Fast Path + Futex | Dynamic Waiter Nodes | Refcounted / Wait-Queue |
| **Work-Stealing** | `TaskPool` | `newTaskPool(numThreads)` | Lock-free Work-Stealing | Pinned Deques + Stack | Task Arena / Retired Array |
| **Shared Ptr** | `AtomicArc` | `newAtomicArc[T](val)` / `AtomicWeak[T]` | Wait-free (Clone) / Lock-free (Upgrade) | ControlBlock Allocation | Split Strong/Weak Refcount |
| **C ABI** | `lf_*` / `lfq_*` | `lf_queue_*`, `lf_bqueue128_*`, `lf_stack_*`, `lf_deque_*`, `lf_table_*`, `lf_set_*`, `lf_pqueue_*`, `lf_flat_combiner_*`, `lf_atomic_arc_*` | Topology-dependent | C Heap (Cacheline Aligned) | NEBR / Internal |

### Sizing and Topology Guidance:
- **`BQueue128` (128-Bit DWCAS Bounded Zero-SMR)**: Uses single-instruction 128-bit hardware compare-and-swap (`cmpxchg16b` on x86_64, `casp` on ARM64/Apple Silicon) to atomically commit tag and payload in a dense 16-byte slot. Delivers **~129.4M ops/sec** (2.13x faster than classical `BQueue` on 1p1c workloads) and completely eliminates producer stalls. Recommended for 1p1c / 2p2c topologies or memory-constrained buffers; for 4+ threads under heavy contention, classical `BQueue` with cacheline-padded cells is recommended.
- **`BQueue`, `BStack`, `BPriorityQueue`, `BTable` (Bounded Zero-SMR)**: Pre-allocated structures with compile-time capacity and zero heap allocations in steady state. Enforce non-copyable invariants (`=copy {.error.}`) and strict cacheline alignment (`allocAligned` / `freeAligned`). Ideal for embedded, real-time audio, bounded caches, and high-frequency packet loops.
- **`Queue` (Unbounded)**: Segmented queues that expand under burst loads without blocking producers. Multi-consumer variants employ Morrison-Afek LCRQ and NEBR epoch reclamation.
- **`Stack` (Treiber LIFO)**: High-concurrency stack featuring an Elimination-Backoff Array where overlapping push/pop pairs exchange data directly without serializing on the stack top.
- **`Deque` (Chase-Lev Work-Stealing)**: Single-worker (bottom LIFO) and concurrent multi-thief (top FIFO) circular deque for fork-join parallelism, work-stealing schedulers, and task pools.
- **`Ctrie`, `SkipListMap`, `SkipListSet` & `SkipListPriorityQueue` (Dynamic Associative & Priority)**: Lock-free dynamic structures backed by NEBR epoch reclamation—`Ctrie` provides $O(1)$ linearizable snapshots, while SkipList variants maintain total key/priority ordering at level 0 with Harris-style logical deletion marking.
- **`FlatCombiner` (Batch Delegation)**: Converts sequential data structures into high-throughput concurrent primitives by electing a combiner thread to execute up to 64 thread-local publication-list requests per pass.
- **`Channel` & `RendezvousChannel` (Actor Facade)**: Ergonomic `Sender[T]` / `Receiver[T]` handles with split refcounting, automatic thread registration via thread-local storage (`{.threadvar.}`), and zero-buffer synchronous handoffs.
- **`lf_*` / `lfq_*` (C ABI)**: Clean C99 FFI surface (`include/lockfree.h` and `include/lockfree_bqueue128.h`) with standardized modern `lf_` prefix and 100% backward-compatible `lfq_` macro aliases, exportable to C, C++, Rust, Zig, and Python with cacheline-aligned allocation (`allocAligned`).

---

<!-- BENCHMARK_METRICS_START -->
## Performance Benchmarks

> Continuous verification measured on `Apple M4 Pro, 12 cores, macosx arm64`.
> Throughput numbers reflect 1,000,000 messages across active producer and consumer threads.

### High-Contention Throughput Matrix

| Topology | Engine | Shape | Throughput (ops/ms) | Throughput (ops/sec) | vs Nim stdlib `system/Channel` |
| :--- | :--- | :--- | :---: | :---: | :---: |
| **MPMC** | `BQueue` (Bounded) | 4 producers, 4 consumers | **19,371 ops/ms** | **19,370,590 ops/s** | **39.0x faster** (496 ops/ms) |
| **SPMC** | `BQueue` (Bounded) | 1 producer, 2 consumers | **19,475 ops/ms** | **19,475,346 ops/s** | — *(stdlib has no SPMC)* |
| **MPSC** | `BQueue` (Bounded) | 4 producers, 1 consumer | **15,913 ops/ms** | **15,912,587 ops/s** | **2.6x faster** (6,076 ops/ms) |
| **SPSC** | `Queue` (Unbounded) | 1 producer, 1 consumer | **26,922 ops/ms** | **26,922,405 ops/s** | — *(stdlib has no SPSC)* |

*Run benchmarks locally with `nimble benchmarks` or explore multi-language comparisons, interactive filters, and latency curves on the [Interactive Benchmarks Portal](https://elijahr.github.io/lockfree/latest/guide/queues/benchmarks/).*
<!-- BENCHMARK_METRICS_END -->

---

## Verification & Testing Matrix

The codebase is protected by a continuous verification matrix executing on every commit:

```sh
nimble test          # Runs 32 compile-fail negative controls + 480+ unit tests (0.20s)
nimble channel       # Runs 25 Channel facade lifecycle & worker tests (0.06s)
nimble cabi          # Runs 36 C ABI interop & checksum verification tests (0.07s)
nimble testStress    # Runs 21 100k-item high-volume contention sweeps (0.63s)
nimble testTSan      # Full matrix ThreadSanitizer sweep (0 data races)
nimble testASan      # Full matrix AddressSanitizer sweep (0 leaks, 0 use-after-free)
```

---

## Documentation

Full architectural guides, typestate diagrams, and API references are hosted at:  
👉 **<https://elijahr.github.io/lockfree>**

- [Concurrency Architecture & Taxonomy Guide](docs/guide/architecture_taxonomy.md)
- [Getting Started & Core Concepts](https://elijahr.github.io/lockfree/guide/getting-started/)
- [Safety Model & Path-C ManagedRef](https://elijahr.github.io/lockfree/guide/safety-model/)
- [Typestate Slot-Ownership Machine](https://elijahr.github.io/lockfree/guide/slot-ownership-typestates/)
- [SMR & NEBR Lifecycle Guide](docs/guide/smr_nebr_lifecycle.md)
- [NEBR Safe Memory Reclamation](https://elijahr.github.io/lockfree/api/smr/nebr/)
- [C ABI Specification & Header Guide](https://elijahr.github.io/lockfree/api/cabi/)
- [Migration Guide from lockfreequeues & nim-debra](https://elijahr.github.io/lockfree/migration/)

---

## References

- **LCRQ (Linked Concurrent Ring Queue)**: Adam Morrison and Yehuda Afek, *"Fast Concurrent Queues for x86 Processors"*, PPoPP 2013 ([DOI 10.1145/2442516.2442527](https://doi.org/10.1145/2442516.2442527)).
- **DEBRA+ (Epoch-Based Reclamation with Neutralization)**: Trevor Brown, *"Reclaiming Memory for Lock-Free Data Structures: There Has to Be a Better Way"*, PODC 2015 ([DOI 10.1145/2767386.2767436](https://doi.org/10.1145/2767386.2767436)).
- **Vyukov Bounded MPMC**: Dmitry Vyukov, *"Bounded MPMC queue"*, 1024cores, 2011.
- **Michael-Scott Queue**: Maged M. Michael and Michael L. Scott, *"Simple, Fast, and Practical Non-Blocking and Blocking Concurrent Queue Algorithms"*, PODC 1996 ([DOI 10.1145/248052.248106](https://doi.org/10.1145/248052.248106)).

---

## License

MIT © Elijah Shaw-Rutschman and contributors. See [LICENSE](LICENSE) for details.
