# Concurrency Architecture & Taxonomy Guide

This guide provides the canonical architectural reference for selecting, composing, and reasoning about every concurrent data structure and synchronization primitive in `lockfree`. It classifies the library across **producer/consumer cardinality topologies**, **bounded zero-SMR vs. dynamic NEBR-reclaimed memory models**, **progress guarantees**, **hardware atomic instruction requirements**, and **Nim 2.x memory manager invariants**.

---

## 1. Master Concurrency Taxonomy Matrix

Every data structure in `lockfree` belongs to one of three architectural families:

1. **Bounded Zero-SMR Primitives (`BQueue`, `BStack`, `BPriorityQueue`, `BTable`)**: Preallocate 100% of their storage inside a cache-line-aligned core object at initialization time. Hot-path operations perform **zero heap allocations** and require **zero Safe Memory Reclamation (SMR)** thread registration.
2. **Dynamic NEBR-Managed Primitives (`Queue`, `TreiberStack`, `SkipListPriorityQueue`, `Ctrie`, `SkipListMap`, `SkipListSet`)**: Scale dynamically on the heap without fixed capacity limits, using **Neutralization-Enhanced Bounded Epoch Reclamation (`DebraManager` / NEBR)** to reclaim unlinked segments and nodes safely without use-after-free or ABA corruption.
3. **Specialized Synchronization & Communication Constructs (`FlatCombiner`, `BroadcastRing`, `TopicBus`, `RendezvousChannel`, `Channel`, `TaskPool`, `ChaseLevDeque`, `TokenBucket`, `LeakyBucket`, `StreamBuffer`, `AtomicArc`)**: Purpose-built engines for pub-sub multicast, synchronous handoff, flat combining, work-stealing scheduling, traffic shaping, and lock-free shared ownership.

### Complete Primitive Comparison Table

| Primitive | Module | Topologies | Capacity | Steady-State Heap Alloc | Memory Reclamation | Progress Guarantee | Hardware Atomics |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **`BQueue`** | `lockfree/bqueue` | SPSC, MPSC, SPMC, MPMC | Compile-time `N` (or runtime tier) | **Zero** | None (Preallocated ring) | Wait-free (SPSC) / Lock-free (MPMC) | 64-bit CAS & FAA |
| **`BStack`** | `lockfree/bstack` | SPSC, MPSC, SPMC, MPMC | Compile-time `Cap` | **Zero** | None (Tagged index pool) | Lock-free (Elimination-backed) | 64-bit CAS & FAA |
| **`BPriorityQueue`** | `lockfree/bpriority_queue` | SPSC, MPSC, SPMC, MPMC | Compile-time `Cap` | **Zero** | None (Contiguous min-heap) | Flat-combined lock-handed | 64-bit CAS & FAA |
| **`BTable`** | `lockfree/btable` | SPSC, MPSC, SPMC, MPMC | Compile-time `Cap` (`2 * nextPow2(Cap)` slots) | **Zero** | None (Open-addressing + seq) | Wait-free (`len`/`isEmpty`/`isFull`) / Flat-combined (`tryGet`/`tryPut`/`remove`) | 64-bit CAS & SeqCounters |
| **`Queue` (SPSC)** | `lockfree/queue` | SPSC | Unbounded (`S`-slot segments) | On segment boundary | Inline segment recycling | Wait-free fast path | 64-bit load/store |
| **`Queue` (MPSC/SPMC)** | `lockfree/queue` | MPSC, SPMC | Unbounded (`S`-slot segments) | On segment boundary | NEBR Epoch SMR | Lock-free / Wait-free single side | 64-bit CAS & FAA |
| **`Queue` (MPMC)** | `lockfree/queue` | MPMC | Unbounded (`S`-slot LCRQ rings) | On ring exhaustion | NEBR Epoch SMR | Lock-free (Morrison-Afek LCRQ) | **128-bit DWCAS** + 64-bit FAA |
| **`TreiberStack`** | `lockfree/stack` | MPMC | Unbounded | Per `push` node | NEBR Epoch SMR + 3-state claim | Lock-free (Elimination-backed) | **128-bit DWCAS** |
| **`SkipListPriorityQueue`** | `lockfree/priority_queue` | MPMC | Unbounded (`MaxLevel`) | Per `push` node | NEBR Epoch SMR | Lock-free (Lindén-Jonsson) | 64-bit CAS & FAA |
| **`Ctrie`** | `lockfree/ctrie` | MPMC | Unbounded | Per `INode`/`CNode`/`SNode` | NEBR Epoch SMR | Lock-free + **$O(1)$ Wait-Free Snapshot** | 64-bit CAS |
| **`SkipListMap` / `Set`** | `lockfree/skiplist`, `set` | MPMC | Unbounded (`MaxLevel`) | Per tower node | NEBR Epoch SMR | Wait-free lookup / Lock-free mutation | 64-bit CAS |
| **`ChaseLevDeque`** | `lockfree/deque` | Single Owner + Multi-Thief | Dynamic circular array | On power-of-2 resize | Retired buffer chain | Lock-free (`pushBottom`/`popBottom`/`steal`) | 64-bit CAS & fences |
| **`FlatCombiner`** | `lockfree/flat_combiner` | MPMC | Dynamic state `T` + publication list | Once per thread TLS slot | Pruned publication list | Lock-handed batch combining | 64-bit CAS |
| **`BroadcastRing` / `TopicBus`** | `lockfree/broadcast` | SPMC, MPMC | Power-of-2 ring | **Zero** in steady state | Sequence-gated overwrite | Lock-free (`omDropOldest` / `omBackpressure`) | 64-bit CAS & FAA |
| **`RendezvousChannel`** | `lockfree/rendezvous` | MPMC | `0` (Synchronous handoff) | **Zero** via TLS node reuse | Intrusive refCount + epoch | Lock-free dual-queue + futex wake | 64-bit CAS + OS Futex |
| **`Channel`** | `lockfree/channel` | MPMC | Bounded (`64`/`1024`/`65536`) or Unbounded | Zero (Bounded) / Segment (Unbounded) | Automatic TLS NEBR handle | Lock-free | 64-bit / 128-bit DWCAS |
| **`TokenBucket` / `LeakyBucket`** | `lockfree/ratelimit` | MPMC | Configurable burst | **Zero** | None (16-byte state) | Lock-free | **128-bit DWCAS** |
| **`StreamBuffer`** | `lockfree/streambuffer` | SPSC, MPSC, SPMC, MPMC | Power-of-2 byte ring | **Zero** | None (Preallocated ring) | Wait-free (SPSC) / Lock-free (MPMC) | 64-bit CAS & FAA |
| **`TaskPool`** | `lockfree/taskpool` | MPMC submit + Work-stealing | Configurable worker count | Per task arena/future | Worker deque + injector | Lock-free work-stealing | 64-bit CAS + **128-bit DWCAS** |
| **`AtomicArc`** | `lockfree/atomic_arc` | MPMC | Single shared payload `T` | Once at construction | Intrusive atomic refcount | Wait-free clone/drop (`fetchAdd`/`fetchSub`) | 64-bit FAA & CAS |

---

## 2. Decision Flowchart: Choosing the Right Primitive

```mermaid
flowchart TD
    Start["Select Concurrency Primitive"] --> Kind{"Workload Pattern?"}
    Kind -->|FIFO Queue| QCap{"Known Upper Bound?"}
    QCap -->|Yes: Zero-Alloc / Real-Time| BQueue["BQueue[T, ccProd, ccCons, N]"]
    QCap -->|No: Dynamic Bursts| UQueue["Queue[T, ccProd, ccCons] (LCRQ + NEBR)"]

    Kind -->|LIFO Stack| SCap{"Known Upper Bound?"}
    SCap -->|Yes: Zero-Alloc / Zero-SMR| BStack["BStack[T, Cap, ccProd, ccCons]"]
    SCap -->|No: Unbounded Depth| TStack["TreiberStack[T] (DWCAS + NEBR)"]

    Kind -->|Priority Queue| PQCap{"Known Upper Bound?"}
    PQCap -->|Yes: Preallocated Binary Heap| BPQ["BPriorityQueue[T, Cap, ccProd, ccCons]"]
    PQCap -->|No: Unbounded Skiplist| SLPQ["SkipListPriorityQueue[T] (Lindén-Jonsson + NEBR)"]

    Kind -->|Key-Value Map / Set| MapKind{"Ordering or Bounded?"}
    MapKind -->|Bounded Zero-Alloc| BTable["BTable[K, V, Cap, ccProd, ccCons]"]
    MapKind -->|Unbounded + O(1) Snapshot| Ctrie["Ctrie[K, V] (HAMT + NEBR)"]
    MapKind -->|Unbounded + Sorted Keys| SkipList["SkipListMap[K, V] / SkipListSet[T]"]

    Kind -->|Pub-Sub / Handoff / Sequential State| SpecKind{"Communication Mode?"}
    SpecKind -->|0-Buffer Sync Handoff| Rendezvous["RendezvousChannel[T]"]
    SpecKind -->|Multi-Reader Fan-Out| Broadcast["BroadcastRing[T] / TopicBus[T]"]
    SpecKind -->|Custom Sequential State| FC["FlatCombiner[T, Op, Res]"]
```

---

## 3. Deep-Dive: Bounded Zero-SMR Primitives

The bounded zero-SMR family (`BQueue`, `BStack`, `BPriorityQueue`, `BTable`) is engineered for real-time pipelines, embedded services, high-frequency trading/telemetry loops, and `--threads:off` single-threaded or interrupt-driven contexts where dynamic heap allocation and epoch reclamation are undesirable.

### 3.1 Common Design Invariants
- **Single Contiguous Allocation at Init**: Every bounded primitive allocates a single 64/128-byte-aligned `*Core` struct via `allocAligned` during `init*` / `new*`. All data slots, sequence numbers, elimination slots, and combiner publication slots reside inline inside that core struct.
- **Zero Hot-Path Heap Traffic**: Steady-state operations (`tryPush`, `tryPop`, `tryPopMin`, `tryPut`, `tryGet`, `remove`) perform zero `alloc`/`dealloc` calls.
- **Deterministic ARC/ORC Cleanup**: Whenever an element is popped, removed, or cleared from a preallocated slot, the implementation moves the value out and immediately invokes `reset(slot.data)` before returning the slot to the available pool. This guarantees that managed Nim payloads (`string`, `seq[T]`, `ref T`, or custom destructors) release their resources immediately rather than lingering in inactive array slots.
- **Uniform Cardinality Parameterization**: All four primitives accept `ccProd: static PinScopeCardinality` and `ccCons: static PinScopeCardinality` (`ccSingle` or `ccMulti`) and provide ergonomic topology aliases (`Spsc*`, `Mpsc*`, `Spmc*`, `Mpmc*`).

### 3.2 `BQueue[T, ccProd, ccCons, N, P, C]` (`lockfree/bqueue`)
- **Algorithm**: Dmitry Vyukov's bounded MPMC ring buffer with per-slot atomic sequence counters (`seq: Atomic[uint]`), paired with a wait-free Lamport circular ring specialization when `ccProd == ccSingle and ccCons == ccSingle`.
- **Contention Mitigation**: Producer `tail` and consumer `head` cursors are isolated on separate cache lines (`CacheLineBytes`). Each slot's sequence counter acts as an individual turnstile, preventing head/tail cache-line ping-pong during slot commits.

### 3.3 `BStack[T, Cap, ccProd, ccCons]` (`lockfree/bstack`)
- **Algorithm**: Preallocated `array[Cap, BStackSlot[T]]` managed by two 64-bit tagged index stacks (`top: Atomic[uint64]` and `freeHead: Atomic[uint64]`), augmented with an 8-slot cache-line-aligned **Elimination-Backoff Array** (`BStackElimSlot[T]`).
- **64-Bit Tagged Index Encoding**: Both `top` and `freeHead` pack `[32-bit monotonic ABA tag | 32-bit slot index]` into a single `uint64`. Every CAS on `top` or `freeHead` increments the 32-bit tag, preventing ABA slot-recycling races using standard 64-bit hardware CAS without requiring 128-bit DWCAS or NEBR epoch tracking.
- **Per-Slot Claim Synchronization (`slotLock` + `inTop`)**: Each `BStackSlot[T]` includes an atomic `next: Atomic[int32]`, `inTop: Atomic[bool]`, and a lightweight per-slot spinlock `slotLock: Atomic[uint32]`. All reads (`peek`) and mutations (`tryPush`, `tryUnlinkTop`, `drainInto`, `clear`) of `slots[idx].data` acquire `slotLock`, guaranteeing zero data races between concurrent `peek()` and `tryPop()` -> `releaseFreeSlot()` -> `tryPush()` reuse under ThreadSanitizer.
- **Elimination Backoff**: Under `ccProd == ccMulti and ccCons == ccMulti`, when a `tryLinkTop` CAS fails due to contention on `top`, the pusher offers its payload in a randomly chosen cache-line-isolated elimination slot (`BStackEliminationCapacity = 8`). Concurrent poppers probe the elimination array when `tryUnlinkTop` misses, exchanging values in $O(1)$ without touching `top`.

### 3.4 `BPriorityQueue[T, Cap, ccProd, ccCons]` (`lockfree/bpriority_queue`)
- **Algorithm**: Preallocated binary min-heap (`heap: array[Cap, BHeapEntry[T]]`) paired with a preallocated 64-slot flat-combining publication array (`pubSlots: array[64, BPQPubSlot[T]]`, 128-byte aligned).
- **Strict FIFO Tie-Breaking**: Every inserted item is stamped with a monotonically increasing 64-bit `seqId` (`BHeapEntry[T] = object(key: T, seqId: uint64)`). The heap ordering predicate `heapEntryLess(a, b)` orders first by `a.key < b.key` and breaks ties via `a.seqId < b.seqId`, guaranteeing deterministic FIFO ordering for items with identical priority.
- **Flat-Combined Contention Scaling**: Under single-thread access (`SPSC` or uncontended `MPMC`), threads acquire `combinerLock` directly and execute binary heap `siftUp`/`siftDown` in-place. Under multi-thread contention, waiting threads publish their `bpqOpPush`, `bpqOpPopMin`, or `bpqOpPeekMin` request into their thread-owned `BPQPubSlot` and spin locally on their 128-byte-aligned `status` word while the active combiner sweeps up to `BPQMaxCombineRounds = 8` batches with warm L1 cache residency.

### 3.5 `BTable[K, V, Cap, ccProd, ccCons]` (`lockfree/btable`)
- **Algorithm**: Preallocated concurrent open-addressing hash table with `ProbeSlots = 2 * nextPowerOfTwo(Cap)` probe slots (enforcing a maximum load factor $\le 0.5$), per-slot sequence counters (`seq: Atomic[uint64]`), and a preallocated 64-slot flat-combining publication array.
- **Tombstone-Aware Bounded Linear Probing**:
  - Each slot transitions among `BTableSlotEmpty` (`0`), `BTableSlotOccupied` (`1`), and `BTableSlotTombstone` (`2`).
  - During insertion (`directTryPut`), the prober records the first encountered tombstone index (`firstTombstone`), but **never stops early at a tombstone**: it continues scanning up to `ProbeSlots` steps until it either locates an existing occupied slot with matching `hashVal` and `key` (updating it in-place) or reaches `BTableSlotEmpty` (or exhausts `ProbeSlots` steps). Only after confirming the key is absent does it reuse `firstTombstone` (if $\ge 0$) or the terminal `BTableSlotEmpty` slot.
  - This guarantees two critical invariants: (1) updating an existing key positioned behind an earlier tombstone never creates duplicate keys, and (2) table churn (repeated insert/remove cycles at capacity `Cap` where every slot becomes `Occupied` or `Tombstone`) terminates deterministically in at most `ProbeSlots` steps and reclaims tombstones without false overflow.
- **Flat-Combined Operations & Wait-Free Metadata (`tryGet` / `contains` / `len` / `isEmpty`)**: `tryGet`, `contains`, `tryPut`, `remove`, and atomic RMW callbacks route through `submitBTableOp`—taking the direct combiner fast path when uncontended or delegating via a thread-local 128-byte-aligned `BTablePubSlot` under contention—while maintaining per-slot sequence counters (`slot.seq: Atomic[uint64]`) and wait-free atomic metadata queries (`len`, `isEmpty`, `isFull`).

---

## 4. Deep-Dive: Dynamic NEBR SMR Primitives

Unbounded and dynamically resized structures cannot recycle heap nodes immediately upon unlinking because concurrent readers may still hold raw pointers loaded prior to the unlink CAS. `lockfree` solves this uniformly via **NEBR (`lockfree/smr/nebr`)**.

### 4.1 Neutralization-Enhanced Bounded Epoch Reclamation (NEBR)
- **3-Epoch Limbo Bags**: Threads enter a critical section by pinning the global epoch (`pin()` / `enterQuiescent()`), which records the current global epoch in the thread's cache-line-isolated `ThreadState` slot. Unlinked nodes are retired to the thread's current epoch limbo bag (`retire(ptr, destructor)`). Once all active threads have observed at least two epoch advances, nodes from epoch $E - 2$ are guaranteed unreachable and freed in batch.
- **Signal-Assisted Neutralization (`SIGUSR1`)**: Classic Epoch-Based Reclamation can suffer unbounded memory growth if an OS-preempted thread stalls inside a pinned read section. NEBR installs a POSIX `SIGUSR1` handler (`lockfree/smr/nebr/signal.nim`) that checks whether a signaled thread is blocked inside an interruptible read section and, if so, unwinds it to a safe recovery point via `siglongjmp`, allowing global epoch advancement and bounding worst-case limbo memory.

### 4.2 Unbounded `Queue` (`lockfree/queue`)
- **MPMC (Morrison-Afek Strict-LCRQ)**: Chains fixed-size ring segments (`LCRQSegment`), where each cell is a 16-byte aligned `Pair[uint, T]` updated via hardware **128-bit DWCAS**. Producers and consumers advance ticket indices via `fetchAdd(1)` rather than contending on a single CAS loop, falling back to segment allocation and NEBR retirement only when a ring closes.
- **SPSC / MPSC / SPMC**: Uses cache-line-aligned segment chains with per-slot committed flags, achieving wait-free SPSC operation and lock-free multi-side scaling.

### 4.3 `TreiberStack[T]` (`lockfree/stack`)
- **128-Bit Tagged Top Pointer**: Represents `top` as `Atomic[Pair[uint64, uint64]]` (`[ptr: uint64, tag: uint64]`) updated via 128-bit DWCAS (`cmpxchg16b` / `caspal`), paired with an 8-slot Elimination-Backoff Array.
- **NEBR Epoch Protection & Exclusive 3-State Node Claim Protocol**:
  - Every `tryPopTreiber`, `peek`, `drain`, and `drainInto` pins the NEBR epoch via `unpinned(handle).pin()` and advances reclamation via `retireReady(pinned)` on exit so no `StackNode[T]` pointer loaded from `top` can be freed while a thread inspects `node.next` or `node.data`.
  - Because `tryPopTreiber()` (as well as `drain()` and `drainInto()`) moves `node.data` out and resets the slot (`outVal = move(node.data); reset(node.data)`) before retiring `node` to `DebraManager`, `StackNode[T]` enforces an **exclusive 3-state `claim: Atomic[int32]` word** (`NodeClaimFree = 0'i32`, `NodeClaimPeek = 1'i32`, `NodeClaimPopped = -1'i32`):
    1. `peek()` pins the NEBR epoch, transitions `node.claim` from `NodeClaimFree (0) -> NodeClaimPeek (1)` via CAS, verifies `self.top == oldTop`, copies `node.data` under exclusive ownership (preventing concurrent `peek()` calls from racing on Nim's non-atomic `--mm:orc`/`--mm:arc` string/seq refcount header), and releases `node.claim -> NodeClaimFree (0)`.
    2. `tryPopTreiber()` (and `drain` / `drainInto` on every node in the detached chain) wins the `top` DWCAS, calls `claimNodeForPop(node)` (spinning until `node.claim` transitions `NodeClaimFree (0) -> NodeClaimPopped (-1)`), moves `node.data` out, and retires `node` to `DebraManager`.

### 4.4 `SkipListPriorityQueue[T]` (`lockfree/priority_queue`)
- **Lindén-Jonsson Algorithm**: Minimizes pop contention on the minimum element by logically deleting nodes along level 0 (`node.deleted` CAS `false -> true`) without modifying `head.next[0]` on every `popMin`.
- **Batch Physical Restructuring**: Once the prefix of logically deleted nodes reaches `DefaultRestructureThreshold = 32` (or when the queue drains empty), the winning thread marks the deleted prefix towers from top level down to level 0, splices the entire batch out of `head.next[0]` in a single CAS, and retires the unlinked nodes to `DebraManager`.
- **Strict FIFO Tie-Breaking**: Assigns a 64-bit monotonic `seqId` (`nextSeqId.fetchAdd(1)`) on every `push`, ensuring duplicate keys are popped in exact insertion order.

### 4.5 Associative Maps & Sets (`Ctrie`, `SkipListMap`, `SkipListSet`)
- **`Ctrie[K, V]` (`lockfree/ctrie`)**: Lock-free Concurrent Hash Array Mapped Trie (Prokopec et al.) using generation-stamped indirection nodes (`INode`) and compressed bitmap branch nodes (`CNode`). Supports **$O(1)$ wait-free linearizable snapshots** (`snapshot()`, `readOnlySnapshot()`, `snapshotPairs()`) via double-compare-single-swap (`RDCSS`) generation increments.
- **`SkipListMap[K, V]` & `SkipListSet[T]` (`lockfree/skiplist`, `lockfree/set`)**: Multi-level lock-free skip lists (Fraser / Herlihy) maintaining sorted key order at level 0 with pointer-bit logical deletion marking (`MarkBit = 1'u`) and NEBR retirement.
- **Atomic Associative Operations**: `Ctrie`, `SkipListMap`, and `BTable` share a uniform associative RMW surface: `computeIfAbsent`, `atomicUpdate`, `upsert`, `take`, and `snapshotPairs` / `snapshotKeys` / `snapshotValues`.

---

## 5. Specialized Concurrency Constructs

### 5.1 `FlatCombiner[T, Op, Res]` (`lockfree/flat_combiner`)
- Turns any sequential state `T` and reducer `proc(state: var T, op: var Op): Res` into a cache-friendly concurrent state machine.
- Each calling thread lazily acquires a 128-byte-aligned `PublicationRecord[T, Op, Res]` linked into `pubHead` and stored in thread-local storage.
- The thread holding `combinerLock` executes up to `DefaultCombiningRounds = 8` sweeps over active publication records, amortizing synchronization overhead and keeping `state: T` hot in L1 cache. Periodically (`DefaultCleanupInterval = 64` passes), inactive records are unlinked from `pubHead`.
- Also exported over the C99 ABI (`include/lockfree_flat_combiner.h`, `lfq_flat_combiner_*`).

### 5.2 `BroadcastRing[T]` & `TopicBus[T]` (`lockfree/broadcast`)
- Lock-free single-producer/multi-producer to multi-subscriber fan-out ring buffer where every subscriber (`Subscriber[T]`) advances an independent 64-bit sequence cursor.
- Supports two overflow modes:
  - `omDropOldest`: Producers never block; lagging subscribers detect sequence overwrite (`lagged` count) and fast-forward to the oldest retained slot.
  - `omBackpressure`: Producers inspect the minimum cursor across registered subscribers and return `false` (`tryPublish`) when advancing would overwrite an unread slot.

### 5.3 `TokenBucket` & `LeakyBucket` (`lockfree/ratelimit`)
- Pack their entire mutable state (`(tokens_ns: int64, last_refill_ns: int64)` for `TokenBucket`; `(tat_ns: int64, acquired_count: uint64)` for `LeakyBucket` GCRA) into a single 16-byte aligned struct updated via **128-bit DWCAS**, eliminating floating-point drift and spinlocks.

### 5.4 `RendezvousChannel[T]` (`lockfree/rendezvous`) & `Channel[T]` (`lockfree/channel`)
- **`RendezvousChannel[T]`**: Zero-buffer synchronous handoff built on a Michael-Scott dual queue (`NodeKind = {nkSender, nkReceiver}`) with intrusive reference counting (`refCount`) and OS futex parking (`ulock` on macOS, `SYS_futex` on Linux) after adaptive spin-backoff.
- **`Channel[T]`**: High-level `Sender[T]` / `Receiver[T]` facade with split reference counting (`senderCount`, `receiverCount`), automatic thread-local SMR registration, and `select` / async bridge (`Chronos` and `std/asyncdispatch`) integration.

---

## 6. Memory Model, Runtime Matrix & Safety Invariants

### 6.1 Nim 2.x Memory Manager Matrix

| Memory Manager | Flag | Characteristics & `lockfree` Support |
| :--- | :--- | :--- |
| **ORC** *(Default)* | `--mm:orc` | Reference counting with cycle collector. Fully supported across all primitives. |
| **ARC** | `--mm:arc` | Deterministic scope-based reference counting without cycle collector. Lowest latency overhead for non-cyclic payloads. |
| **Atomic ARC** | `--mm:atomicArc` | Uses atomic reference count adjustments on managed strings/seqs/refs. **Required when running ThreadSanitizer (`-fsanitize=thread`)** so compiler-generated refcount updates are atomic. |
| **Refc** *(Legacy)* | `--mm:refc` | Thread-local mark-and-sweep GC. Supported for primitive scalar/value types. |

### 6.2 Path-C Payload & Destructor Safety Rules
1. **Immediate Slot Reset on Eviction**: Every bounded and unbounded container in `lockfree` moves the payload out of its slot/node (`outVal = move(slot.data)`) and calls `reset(slot.data)` before releasing the slot or retiring the node. This guarantees that ARC/ORC destructors (`=destroy`) run deterministically on the consuming/clearing thread and prevents cross-thread double-free or memory leaks.
2. **Shared Reference Payloads (`AtomicArc[T]` & `ManagedRef[T]`)**: Standard Nim `ref T` under `--mm:arc` uses non-atomic reference count increments when copied across threads. When multiple threads concurrently read or clone a shared heap object (e.g., via `Ctrie.get`, `SkipListMap.get`, or `BroadcastRing.tryRecv`), wrap the payload in `AtomicArc[T]` (`lockfree/atomic_arc`) or `ManagedRef[T]` to guarantee atomic reference counting.
3. **128-Bit Alignment Invariant**: All structures using 128-bit hardware DWCAS (`Queue` MPMC segments, `TreiberStack` top, `TokenBucket`, `LeakyBucket`, `DebraManager` descriptors) enforce 16-byte alignment (`{.align: 16.}` / `allocAligned`) so `cmpxchg16b` (x86_64) and `caspal` (ARM64 LSE) never fault or split cache lines.
4. **Sanitizer & Watchdog Verification**: All concurrency primitives are verified under both `--mm:orc` and `--mm:atomicArc --passC:-fsanitize=thread --passL:-fsanitize=thread`, guarded by the per-test sentinel watchdog (`tests/test_watchdog.nim`) to catch both data races and livelocks.
