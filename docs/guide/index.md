# The lockfree umbrella

`lockfree` is a single Nim and C package collecting production-quality, non-blocking
concurrency primitives, data structures, and safe memory reclamation under one
consistent architecture.

## The Full Concurrency Suite

`lockfree` ships a complete suite of lock-free data structures and concurrency tools:

- **Bounded Queues (`BQueue`)** — ring buffers with compile-time capacity, the
  Vyukov per-slot sequence-counter protocol covering all four cardinalities
  (SPSC, SPMC, MPSC, MPMC). Zero runtime allocations in steady state.
- **Unbounded Queues (`Queue`)** — linked-segment queues that grow dynamically.
  MPMC uses the Morrison & Afek strict-LCRQ 128-bit DWCAS form; SPSC, SPMC, and
  MPSC use the committed-flag segment chain.
- **Channels & Synchronous Rendezvous (`Channel`, `RendezvousChannel`)** — Go-style
  CSP communication channels with thread-local automatic registration, and
  zero-capacity synchronous rendezvous handoffs using kernel futexes.
- **Concurrent Maps & Sets (`Ctrie`, `SkipListMap`, `SkipListSet`)** —
  Aleksandar Prokopec's Concurrent Hash Array Mapped Trie with $O(1)$ wait-free
  snapshots, Fraser & Herlihy lock-free SkipLists with Harris logical deletion
  and ordered traversal, and concurrent sets.
- **Concurrent Stacks & Deques (`TreiberStack`, `ChaseLevDeque`)** —
  Treiber stack with Hendler et al. Elimination-Backoff Array for linear scaling
  under contention, and Chase-Lev asymmetric work-stealing circular deques.
- **Broadcast & Topic Bus (`BroadcastRing`, `TopicBus`)** — lock-free
  multicast pub-sub fan-out with independent reader cursors and selectable
  overflow policies (`omDropOldest` lossy wrap-around vs `omBackpressure`).
- **Work-Stealing TaskPool (`TaskPool`)** — multi-threaded scheduler using
  pinned Chase-Lev deques and Treiber stack injection, supporting `spawn`,
  `sync`, and `parallelFor`.
- **Rate Limiting & Streaming (`RateLimiter`, `StreamBuffer`)** — hardware
  128-bit DWCAS Token Bucket and Leaky Bucket (GCRA) traffic shapers, and
  lock-free byte stream ring buffers.
- **C ABI Interoperability (`lockfree.h`, `libcabi`)** — canonical C99 / C++11
  FFI bindings, zero-copy pointer transport, and an exception firewall.
- **Safe Memory Reclamation (`lockfree/smr/nebr`)** — epoch-based reclamation
  with signal-driven thread neutralization (`SIGUSR1`). Backs unbounded queues,
  maps, and sets; also exposed as a standalone reclaimer.
- **Hardware Atomics & Typestates (`lockfree/atomics`, `lockfree/typestates`)** —
  Clang/GCC C11 hardware atomics, adaptive backoff, and compile-time
  `Unbound → Bound → Closed` lifecycle enforcement.

## When to reach for what

- **FIFO Pipelines**: Use `BQueue` when capacity bounds are known and latency must
  be strictly bounded without allocation. Use `Queue` for dynamic, bursty workloads.
- **Inter-Thread Communication**: Use `Channel[T]` for standard buffered worker
  communication. Use `RendezvousChannel[T]` when sender and receiver must pair
  synchronously with zero intermediate buffering.
- **Key-Value Storage & Caches**: Use `Ctrie[K, V]` (or `Table`) for high-throughput
  unordered dictionary lookups and fast point-in-time snapshots. Use `SkipListMap[K, V]`
  (or `SortedTable`) when sorted key iteration or range queries are required.
- **Sets**: Use `SkipListSet[T]` (or `Set`) for concurrent membership testing and deduplication.
- **LIFO Buffers & Work Sharing**: Use `TreiberStack[T]` for memory recycling and
  free-lists under heavy contention.
- **Work Stealing & Parallel Tasks**: Use `ChaseLevDeque[T]` for custom divide-and-conquer
  algorithms, or `TaskPool` for general-purpose parallel loops and task scheduling.
- **Pub-Sub & Multicast**: Use `BroadcastRing[T]` for multi-reader telemetry, event
  distribution, and real-time market data fan-out.
- **C & Polyglot Integration**: Use `lockfree.h` to embed lock-free data structures into
  C, C++, Rust, Zig, or Go services.
- **Custom Lock-Free Algorithms**: Use `lockfree/smr/nebr` for safe memory reclamation,
  and `lockfree/atomics` for hardware atomics and adaptive backoff loops.

## What this guide covers

| Section | When to read |
|---------|--------------|
| [User Guide](../guides/user_guide.md) | Colloquial type matrix, algorithm comparison, and end-to-end examples. |
| [Getting started](getting-started.md) | Installation, minimal queue/channel examples, and compilation flags. |
| [Concepts](concepts/lock-freedom.md) | Vocabulary: lock-free vs wait-free vs blocking, what SMR is, memory managers. |
| [Queues](queues/index.md) | Cardinality chooser, bounded Vyukov substrate, strict-LCRQ MPMC. |
| [Channels](channels.md) | Ergonomic `Channel[T]` facade, `RendezvousChannel[T]`, and async bridges. |
| [Maps & Sets](maps-sets.md) | `Ctrie` (HAMT), `SkipListMap` (sorted map), and `SkipListSet`. |
| [Stacks & Deques](stacks-deques.md) | `TreiberStack` with elimination backoff, `ChaseLevDeque` work stealing. |
| [Broadcast](broadcast.md) | `BroadcastRing`, `TopicBus`, and lossy/lossless overflow policies. |
| [TaskPool](taskpool.md) | Work-stealing scheduler, `spawn`, `sync`, and `parallelFor`. |
| [C ABI](cabi.md) | C99 interface (`lockfree.h`), opaque handles, error codes, and thread registration. |
| [SMR / nebr](smr/nebr.md) | Manager lifecycle, neutralize protocol, and reclamation cadence. |
| [Hardware Atomics](atomics.md) | Memory ordering, hardware 128-bit DWCAS, and adaptive backoff. |
| [Rate Limiting & Streaming](ratelimit-streambuffer.md) | Token Bucket, Leaky Bucket, and `StreamBuffer`. |
| [ManagedRef](managed-ref.md) | `ref T` payloads, ARC/ORC lifecycle safety, and box patterns. |
| [ManagedSlice](managed-slice.md) | `string` / `seq[T]` payloads and memory management. |
| [Typestates](typestates.md) | Compile-time endpoint state machines and RAII wrappers. |
| [Migrations](../migrations/from-lockfreequeues-v5.md) | Migrating from `lockfreequeues` and `nim-debra`. |

## Design Philosophy

`lockfree` is a comprehensive, production-grade lock-free concurrency toolkit for
Nim and C. Every data structure guarantees lock-freedom or wait-freedom, zero
mutual-exclusion locks on hot paths, and strict memory safety under ARC/ORC and
NEBR epoch-based reclamation.
