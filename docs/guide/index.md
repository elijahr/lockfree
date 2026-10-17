# The lockfree umbrella

`lockfree` is a single Nim and C package collecting production-quality, non-blocking
concurrency primitives, data structures, and safe memory reclamation under one
consistent architecture.

## The Full Concurrency Suite

`lockfree` ships a complete suite of lock-free data structures and concurrency tools:

- **Bounded Zero-SMR Primitives (`BQueue`, `BStack`, `BPriorityQueue`, `BTable`)** —
  pre-allocated, cacheline-aligned collections with compile-time capacity:
  Vyukov ring buffers (`BQueue` across SPSC/SPMC/MPSC/MPMC), free-list indexed
  LIFO stacks (`BStack`), binary min-heaps (`BPriorityQueue`), and Robin Hood
  linear-probing hash tables (`BTable`). Zero runtime allocations in steady state.
- **Unbounded Queues (`Queue`)** — linked-segment queues that grow dynamically.
  MPMC uses the Morrison & Afek strict-LCRQ 128-bit DWCAS form; SPSC, SPMC, and
  MPSC use the committed-flag segment chain.
- **Channels & Synchronous Rendezvous (`Channel`, `RendezvousChannel`)** — Go-style
  CSP communication channels with thread-local automatic registration, and
  zero-capacity synchronous rendezvous handoffs using kernel futexes.
- **Concurrent Maps, Sets & Priority Queues (`Ctrie`, `SkipListMap`, `SkipListSet`, `SkipListPriorityQueue`)** —
  Aleksandar Prokopec's Concurrent Hash Array Mapped Trie with $O(1)$ wait-free
  snapshots, Fraser & Herlihy lock-free SkipLists with Harris logical deletion
  and ordered traversal, concurrent sets, and Lotan-Shavit / Sundell-Tsigas
  unbounded priority queues.
- **Concurrent Stacks & Deques (`TreiberStack`, `ChaseLevDeque`)** —
  Treiber stack with Hendler et al. Elimination-Backoff Array for linear scaling
  under contention, and Chase-Lev asymmetric work-stealing circular deques.
- **Broadcast & Topic Bus (`BroadcastRing`, `TopicBus`)** — lock-free
  multicast pub-sub fan-out with independent reader cursors and selectable
  overflow policies (`omDropOldest` lossy wrap-around vs `omBackpressure`).
- **Work-Stealing TaskPool & Flat Combiner (`TaskPool`, `FlatCombiner`)** —
  multi-threaded scheduler using pinned Chase-Lev deques and Treiber stack
  injection (`spawn`, `sync`, `parallelFor`), plus Hendler et al. Flat Combining
  for high-contention batch delegation.
- **Rate Limiting & Streaming (`RateLimiter`, `StreamBuffer`)** — hardware
  128-bit DWCAS Token Bucket and Leaky Bucket (GCRA) traffic shapers, and
  lock-free byte stream ring buffers.
- **C ABI Interoperability (`lockfree.h`, `libcabi`)** — canonical C99 / C++11
  FFI bindings, zero-copy pointer transport, and an exception firewall.
- **Safe Memory Reclamation (`lockfree/smr/nebr`)** — epoch-based reclamation
  with signal-driven thread neutralization (`SIGUSR1`). Backs unbounded queues,
  maps, sets, and priority queues; also exposed as a standalone reclaimer.
- **Hardware Atomics, AtomicArc & Typestates (`lockfree/atomics`, `lockfree/atomic_arc`, `lockfree/typestates`)** —
  Clang/GCC C11 hardware atomics, thread-safe atomic reference-counted smart
  pointers (`AtomicArc[T]` / `AtomicWeak[T]`), and compile-time
  `Unbound → Bound → Closed` lifecycle enforcement.

## When to reach for what

- **FIFO Pipelines**: Use `BQueue` when capacity bounds are known and latency must
  be strictly bounded without allocation. Use `Queue` for dynamic, bursty workloads.
- **Inter-Thread Communication**: Use `Channel[T]` for standard buffered worker
  communication. Use `RendezvousChannel[T]` when sender and receiver must pair
  synchronously with zero intermediate buffering.
- **Key-Value Storage & Caches**: Use `BTable[K, V, Cap]` for zero-allocation bounded
  caches, `Ctrie[K, V]` (or `Table`) for high-throughput dynamic unordered lookups
  and $O(1)$ snapshots, or `SkipListMap[K, V]` (or `SortedTable`) when sorted key
  iteration or range queries are required.
- **Priority Scheduling**: Use `BPriorityQueue[T, Cap]` for bounded min-heap task
  dispatch or `SkipListPriorityQueue[T]` for unbounded lock-free priority queues.
- **Sets**: Use `SkipListSet[T]` (or `Set`) for concurrent membership testing and deduplication.
- **LIFO Buffers & Work Sharing**: Use `BStack[T, Cap]` for bounded zero-SMR object
  pools, or `TreiberStack[T]` for dynamic pools with elimination backoff.
- **Work Stealing, Parallel Tasks & Delegation**: Use `ChaseLevDeque[T]` for custom
  divide-and-conquer algorithms, `TaskPool` for general-purpose parallel loops, or
  `FlatCombiner[T, Op, Res]` to convert sequential state machines into concurrent primitives.
- **Pub-Sub & Multicast**: Use `BroadcastRing[T]` for multi-reader telemetry, event
  distribution, and real-time market data fan-out.
- **C & Polyglot Integration**: Use `lockfree.h` to embed lock-free data structures into
  C, C++, Rust, Zig, or Go services.
- **Custom Lock-Free Algorithms**: Use `lockfree/smr/nebr` for safe memory reclamation,
  `lockfree/atomic_arc` for shared ownership, and `lockfree/atomics` for hardware
  atomics and adaptive backoff loops.

## What this guide covers

| Section | When to read |
|---------|--------------|
| [User Guide](user_guide.md) | Colloquial type matrix, algorithm comparison, and end-to-end examples. |
| [Architecture & Taxonomy](architecture_taxonomy.md) | Complete concurrency taxonomy matrix, Bounded Zero-SMR vs Dynamic NEBR SMR deep dive, and ARC/ORC + TSan safety invariants. |
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
