[![ci](https://github.com/elijahr/lockfree/actions/workflows/ci.yml/badge.svg)](https://github.com/elijahr/lockfree/actions/workflows/ci.yml)
[![docs](https://img.shields.io/badge/docs-latest-blue.svg)](https://elijahr.github.io/lockfree)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Nim](https://img.shields.io/badge/nim-%3E%3D2.2.10-orange.svg)](https://nim-lang.org)
[![Tests](https://img.shields.io/badge/tests-500%2B%20passing-brightgreen.svg)](tests/)
[![Sanitizers](https://img.shields.io/badge/sanitizers-TSAN%20%7C%20ASAN%20clean-success.svg)](tests/)

# lockfree

> **Ultra-high-performance lock-free queues, typestate-safe channels, and epoch-based memory reclamation (NEBR) for Nim, with native C ABI bindings.**  
> *Consolidated successor to `lockfreequeues` and `nim-debra`.*

`lockfree` delivers wait-free and lock-free concurrent data structures across the full single/multi-producer and single/multi-consumer matrix. Bounded queues operate as zero-allocation ring buffers; unbounded queues use linked segments with in-tree epoch-based memory reclamation (NEBR / DEBRA+).

Under heavy multi-producer multi-consumer contention, `lockfree` sustains **18,209 ops/ms** — **10.6x faster than Nim's standard library `Channel`**.

---

## Key Features

- **Full Cardinality Matrix**: SPSC, SPMC, MPSC, and MPMC topologies across both bounded (`BQueue`) and unbounded (`Queue`) variants.
- **Modern Channel Facade**: High-level `Channel[T]` providing CSP-style channels with split sender/receiver refcounts, bounded thread-local caching, and auto-close semantics.
- **Path-C GC Safety**: Store `ref T`, `string`, `seq`, pointers, and value types transparently across threads. Payloads are lowered to 8-byte tokens (`ManagedRef` / `ManagedSlice`), preventing GC refcount races on the queue slot array across `orc`, `arc`, `atomicArc`, and `refc`.
- **Strict LCRQ Unbounded MPMC**: Implements the Morrison-Afek LCRQ algorithm using Double-Word CAS (DWCAS) with close-CAS-on-empty progress rules.
- **NEBR Memory Reclamation**: Built-in Neutralization-Enhanced Bounded Reclamation (DEBRA+ algorithm with signal-based stalled-thread neutralization) — no external SMR dependencies required.
- **Batch Processing Primitives**: High-throughput `popBatch` and `popChunk` primitives for bulk operations with amortized atomic book-keeping.
- **Cross-Language C ABI**: First-class C headers (`include/lockfree.h`) and shared library symbols (`cabi.nim`) for zero-overhead integration with C, C++, Rust, Zig, and Python.
- **Verified Zero-Race Safety**: 500+ tests verified clean under Clang **ThreadSanitizer (TSAN)** and **AddressSanitizer (ASAN)**, with 23 negative compile-fail safety tripwires.

---

## Compatibility

| Requirement | Supported |
|-------------|-----------|
| **Nim Version** | `>= 2.2.10` |
| **Memory Managers** | `orc` (default), `arc`, `refc`, `atomicArc` |
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
| **MPMC** | `Queue` | `newUnboundedMpmcQueue[T, Strategy, S, MaxT]()` | Lock-free (LCRQ DWCAS) / Lock-free | Linked Segments | NEBR Epoch SMR |
| **CSP** | `Channel` | `newBoundedChannel[T](cap)` / `newChannel[T]` | Lock-free / Lock-free | Dynamic Tiers (64, 1024, 65536) | None (BQueue-backed) |
| **CSP** | `Channel` | `newUnboundedChannel[T](segSize)` | Lock-free / Lock-free | Linked Segments | NEBR Epoch SMR |
| **C ABI** | `lfq_queue_t` | `lfq_queue_create(&config, &queue)` | Topology-dependent | C Heap | NEBR / Internal |

### Sizing and Topology Guidance:
- **`BQueue` (Bounded)**: Ring buffers with compile-time or tiered runtime capacity. Ideal for embedded, real-time audio, and zero-allocation high-frequency packet loops.
- **`Queue` (Unbounded)**: Segmented queues that expand under burst loads without blocking producers. Multi-consumer variants employ Morrison-Afek LCRQ and NEBR epoch reclamation.
- **`Channel` (Actor Facade)**: Ergonomic `Sender[T]` / `Receiver[T]` handles with split refcounting, automatic thread registration via thread-local storage (`{.threadvar.}`), and clean shutdown semantics.
- **`lfq_*` (C ABI)**: Clean FFI surface (`include/lockfree.h`) exportable to C, C++, Rust, Zig, and Python.

---

## Performance Benchmarks

The benchmark suite tests throughput against Nim's standard library `system/Channel` across representative thread topologies (`ubuntu-latest`, 4 vCPU x86_64):

| Topology | Variant | Shape | Throughput (ops/ms) | vs `system/Channel` |
| :--- | :--- | :--- | :---: | :---: |
| **MPMC** | `BQueue` | 4 producers, 4 consumers | **18,209 ops/ms** | **10.6x faster** (1,723 ops/ms) |
| **SPMC** | `BQueue` | 1 producer, 2 consumers | **22,399 ops/ms** | — *(stdlib has no SPMC)* |
| **MPSC** | `BQueue` | 4 producers, 1 consumer | **13,667 ops/ms** | **3.7x faster** (3,667 ops/ms) |
| **SPSC** | `BQueue` | 1 producer, 1 consumer | **7,592 ops/ms** | — *(stdlib has no SPSC)* |

*Run benchmarks locally with `nimble benchmarks` or view the interactive chart at [elijahr.github.io/lockfree/latest/benchmarks/](https://elijahr.github.io/lockfree/latest/benchmarks/).*

---

## Verification & Testing Matrix

The codebase is protected by a continuous verification matrix executing on every commit:

```sh
nimble test          # Runs 23 compile-fail negative controls + 460 unit tests (0.20s)
nimble channel       # Runs 25 Channel facade lifecycle & worker tests (0.06s)
nimble cabi          # Runs 15 C ABI interop & checksum verification tests (0.07s)
nimble testStress    # Runs 21 100k-item high-volume contention sweeps (0.63s)
nimble testTSan      # Full matrix ThreadSanitizer sweep (0 data races)
nimble testASan      # Full matrix AddressSanitizer sweep (0 leaks, 0 use-after-free)
```

---

## Documentation

Full architectural guides, typestate diagrams, and API references are hosted at:  
👉 **<https://elijahr.github.io/lockfree>**

- [Getting Started & Core Concepts](https://elijahr.github.io/lockfree/guide/getting-started/)
- [Safety Model & Path-C ManagedRef](https://elijahr.github.io/lockfree/guide/safety-model/)
- [Typestate Slot-Ownership Machine](https://elijahr.github.io/lockfree/guide/slot-ownership-typestates/)
- [SMR & NEBR Lifecycle Guide](docs/guides/smr_nebr_lifecycle.md)
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
