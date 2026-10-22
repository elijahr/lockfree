# API Reference

`lockfree` provides a comprehensive suite of production-grade, non-blocking
concurrent data structures and synchronization primitives for Nim and C.

Most callers only need:

```nim
import lockfree
```

Below is the complete API reference categorized by architectural function.

---

## 1. FIFO Queues

- **[BQueue (Bounded Queue)](bqueue.md)** — Fixed-capacity circular ring buffer based on Dmitry Vyukov's per-slot sequence counter protocol. Covers SPSC (wait-free), SPMC, MPSC, and MPMC (lock-free). Zero runtime allocations in steady state.
- **[BQueue128 (128-Bit DWCAS Queue)](bqueue128.md)** — High-density bounded MPMC queue for 64-bit scalar types and pointers. Employs hardware 128-bit atomic DWCAS for instantaneous single-instruction publication without intermediate half-written states.
- **[Queue (Unbounded Queue)](queue.md)** — Dynamic-capacity linked-segment queue. MPMC uses the Morrison & Afek strict-LCRQ algorithm with 128-bit hardware DWCAS; SPSC, SPMC, and MPSC use committed-flag segment chains. Backed by in-tree Debra/NEBR safe memory reclamation.

---

## 2. Channels & Synchronization

- **[Channel](channel.md)** — Go-style CSP channel facade over `BQueue` or `Queue` with automatic thread-local endpoint registration (`Sender[T]` and `Receiver[T]`).
- **[RendezvousChannel](rendezvous.md)** — Synchronous zero-capacity dual-queue handoff based on Scherer & Scott's algorithm with kernel futex parking.

---

## 3. Concurrent Maps & Sets

- **[Ctrie](ctrie.md)** — Aleksandar Prokopec's lock-free Concurrent Hash Array Mapped Trie (HAMT) featuring $O(1)$ wait-free snapshots and wait-free lookups. Aliases: `Table`, `ConcurrentTable`, `ConcurrentMap`.
- **[SkipListMap](skiplist.md)** — Fraser & Herlihy multi-level lock-free SkipList with Harris logical marking and total key ordering. Aliases: `SortedTable`, `OrderedTable`.
- **[SkipListSet](set.md)** — Concurrent lock-free set with ordered iteration. Aliases: `Set`, `ConcurrentSet`.

---

## 4. Stacks & Deques

- **[TreiberStack](stack.md)** — High-throughput LIFO stack with Hendler et al. Elimination-Backoff Array for linear scalability under contention. Aliases: `Stack`, `ConcurrentStack`.
- **[ChaseLevDeque](deque.md)** — Asymmetric work-stealing circular deque with C11 fences. Lock-free LIFO worker operations and lock-free FIFO thief stealing. Aliases: `Deque`, `ConcurrentDeque`.

---

## 5. Multicast & Scheduling

- **[BroadcastRing & TopicBus](broadcast.md)** — Multicast fan-out ring buffer with independent reader cursors and selectable overflow policies (`omDropOldest` vs `omBackpressure`).
- **[TaskPool](taskpool.md)** — Production work-stealing task pool and scheduler coordinating worker Chase-Lev deques and Treiber stack injection (`spawn`, `sync`, `parallelFor`).

---

## 6. Rate Limiting & Streaming

- **[RateLimiter](ratelimit.md)** — Hardware 128-bit DWCAS Token Bucket and Leaky Bucket (GCRA) traffic shapers.
- **[StreamBuffer](streambuffer.md)** — Lock-free continuous byte streaming ring buffer for packet framing and audio streams.

---

## 7. C ABI Interoperability

- **[C ABI](cabi.md)** — C99 Foreign Function Interface (`include/lockfree.h`, `liblockfree`), opaque handles, status codes, zero-copy pointer transport, and an exception firewall.

---

## 8. SMR & Hardware Atomics

- **[nebr (Safe Memory Reclamation)](smr/nebr.md)** — Neutralizable Epoch-Based Reclamation with `SIGUSR1` thread neutralization.
- **[atomics](atomics.md)** — Strongly-typed C11 hardware atomics, 128-bit DWCAS, and adaptive contention backoff loops.

---

## 9. Managed Payloads & Typestates

- **[ManagedRef](managed_ref.md)** — Path-C zero-leak encapsulation for `ref T` payloads across all memory managers (`orc`, `arc`, `atomicArc`, `refc`, `none`).
- **[ManagedSlice](managed_slice.md)** — Path-C encapsulation for `string` and `seq[T]` payloads.
- **[Chronos](chronos.md)** — Async channel adapter for Status Chronos.
- **[Typestates](typestates.md)** — Compile-time endpoint state machine and `withBoundEndpoint` RAII wrapper.
- **[Compatibility Shim](compat.md)** — Drop-in backwards-compatibility layer for `lockfreequeues` v4/v5 callers.
