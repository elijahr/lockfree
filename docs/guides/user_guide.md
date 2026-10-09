# Lock-Free Data Structures User Guide: From Colloquial Names to High-Performance Concurrency

Welcome to the definitive user guide for `lockfree`. Whether you are building an ultra-low latency financial order router, a high-throughput network service, a real-time audio pipeline, or a multi-threaded game engine in Nim, `lockfree` provides production-grade, non-blocking concurrent data structures designed for maximum scalability, deterministic latency, and zero mutual-exclusion overhead.

This guide bridges everyday, colloquial data structure names (like `Table`, `Set`, `Stack`, `Queue`, `Channel`, `Deque`, and `BroadcastRing`) to their high-performance lock-free implementations in `lockfree`. It breaks down algorithmic tradeoffs, provides copy-pasteable code examples, and details the memory management foundations (ARC/ORC and Debra/NEBR Safe Memory Reclamation) that keep your multi-threaded systems leak-free and crash-proof.

---

## 1. Quick Reference: The Colloquial-to-LockFree Bridge Matrix

When designing concurrent systems, you typically know what abstract data type you need. The matrix below maps standard colloquial types directly to their corresponding `lockfree` types, exported aliases, underlying algorithms, and concurrency topologies.

| Colloquial Name | Canonical LockFree Type | Ergonomic Aliases | Underlying Algorithm | Concurrency Topology | Progress Guarantee |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Table / Map / Dict** | `Ctrie[K, V]` | `Table[K, V]`, `ConcurrentTable[K, V]`, `ConcurrentMap[K, V]` | Aleksandar Prokopec Concurrent Hash Array Mapped Trie (HAMT) | MPMC (Multi-Producer Multi-Consumer) | Lookups: **Wait-Free**<br>Mutations: **Lock-Free**<br>Snapshots: **Wait-Free $O(1)$** |
| **SortedTable / OrderedTable** | `SkipListMap[K, V]` | `SortedTable[K, V]`, `OrderedTable[K, V]`, `ConcurrentSortedTable[K, V]` | Fraser & Herlihy Lock-Free SkipList with Harris Logical Marking | MPMC (Multi-Producer Multi-Consumer) | Lookups: **Wait-Free**<br>Mutations: **Lock-Free** |
| **Set / HashSet / OrderedSet** | `SkipListSet[T]` | `Set[T]`, `ConcurrentSet[T]`, `OrderedSet[T]` | Fraser & Herlihy Lock-Free SkipList with Harris Logical Marking | MPMC (Multi-Producer Multi-Consumer) | Contains: **Wait-Free**<br>Insert/Remove: **Lock-Free** |
| **Stack / LIFO Buffer** | `TreiberStack[T]` | `Stack[T]`, `ConcurrentStack[T]` | Treiber Stack with Hendler et al. Elimination-Backoff Array | MPMC (Multi-Producer Multi-Consumer) | **Lock-Free** (with direct exchange under contention) |
| **Bounded Queue / Ring Buffer** | `BQueue[T, ...]` | `BoundedQueue[T]`, `MpmcBoundedQueue[T]`, `SpscBoundedQueue[T]` | Dmitry Vyukov Bounded Ring Buffer with Per-Slot Sequence Counters | SPSC, MPSC, SPMC, MPMC | SPSC: **Wait-Free**<br>MPMC: **Lock-Free** |
| **Unbounded Queue / Dynamic FIFO** | `Queue[T, ...]` | `UnboundedQueue[T]`, `MpmcQueue[T]`, `SpscQueue[T]` | Morrison & Afek Linked Concurrent Ring Queue (LCRQ) with DWCAS | SPSC, MPSC, SPMC, MPMC | SPSC: **Wait-Free**<br>MPMC: **Lock-Free** |
| **Channel / CSP / Go-style chan** | `Channel[T]` | `Sender[T]`, `Receiver[T]` | Ergonomic Channel Facade over `BQueue` or `Queue` with TLS Auto-Registration | MPMC (Multi-Producer Multi-Consumer) | **Lock-Free** |
| **Synchronous Channel / Rendezvous** | `RendezvousChannel[T]` | `RendezvousChannel[T]` | Scherer & Scott Synchronous Dual Queue with Futex Wait/Wake | MPMC (Multi-Producer Multi-Consumer) | Match: **Lock-Free**<br>Wait: **OS Futex Park** |
| **Deque / Work-Stealing** | `ChaseLevDeque[T]` | `Deque[T]`, `ConcurrentDeque[T]` | Chase-Lev Dynamic Circular Deque with C11 Fences & Bulk Stealing | Single-Worker / Multi-Thief | Worker: **Lock-Free**<br>Thieves: **Lock-Free** |
| **Task Pool / Fork-Join Scheduler**| `TaskPool` | `ThreadPool`, `ConcurrentTaskPool` | Work-Stealing Scheduler over `ChaseLevDeque` and `TreiberStack` | Multi-Worker Work-Stealing | **Lock-Free Scheduling** |
| **Broadcast / Pub-Sub Ring Buffer**| `BroadcastRing[T]` | `BroadcastCursor[T]`, `TopicBus[T]` | Lock-Free Multicast Ring with Dynamic Reader Cursors & Slow-Consumer Policies | SPMC / MPMC Multicast Fan-Out | Readers: **Wait-Free / Lock-Free**<br>Writers: **Lock-Free** |

---

## 2. Algorithmic Tradeoffs & Architectural Selection

Choosing the optimal concurrent data structure requires understanding the underlying hardware and algorithmic tradeoffs. Below are comprehensive comparisons of complementary structures.

### 2.1 Associative Maps: `Ctrie[K, V]` vs `SkipListMap[K, V]`

Both `Ctrie` and `SkipListMap` provide thread-safe, lock-free key-value mapping with Debra Safe Memory Reclamation. However, their internal structures and operational profiles differ substantially:

| Dimension | `Ctrie[K, V]` (`Table`) | `SkipListMap[K, V]` (`SortedTable`) |
| :--- | :--- | :--- |
| **Core Architecture** | Aleksandar Prokopec 32-way Branching Hash Array Mapped Trie (HAMT) | Maurice Herlihy & Keir Fraser Multi-Level Probabilistic SkipList |
| **Key Ordering** | **Unordered** (partitioned by 32-bit Murmur3-finalized hash bits) | **Strict Total Key Order** (sorted ascending traversal via level 0) |
| **Lookup Traversal** | **Bounded Depth**: At most 7 levels for 32-bit hashes; lookup is **Wait-Free** | **Probabilistic $O(\log N)$**: Average $\log_2(N)$ skip steps; lookup is **Wait-Free** |
| **Point-in-Time Snapshots**| **$O(1)$ Time and Work**: Generational root swing creates an isolated read-only snapshot | **$O(N)$ Iterative Copy**: Requires traversing level-0 elements |
| **Key Requirements** | `hash(K): Hash` and `==` equality | `cmp(K, K): int` or `<` strict weak ordering |
| **Memory Footprint** | Dynamic node compression using 32-bit bitmasks (`countBits32`) | Tower nodes with array of atomic next pointers up to `MaxLevel` |
| **Best Used For** | General high-throughput associative caching, symbol tables, dictionary lookups, frequent snapshot queries | Sorted indexing, range queries, ordered iteration (`keys`, `pairs`), time-series keys |

#### Architectural Recommendation
- Use **`Ctrie` (or `Table`)** if you need an unordered, high-performance concurrent map with standard dictionary semantics, or if your application frequently takes point-in-time snapshots under concurrent mutations without blocking writers.
- Use **`SkipListMap` (or `SortedTable`)** if your application requires ordered traversal (`for (k, v) in tbl.pairs(): ...`), prefix scans, or range-bounded iterations.

---

### 2.2 FIFO Queues: `BQueue` (Vyukov Bounded) vs `Queue` (LCRQ Unbounded)

The two primary queue engines in `lockfree` represent two distinct architectural paradigms: static zero-allocation bounded ring buffers versus dynamic linked-segment unbounded queues.

| Dimension | `BQueue[T, ...]` (`BoundedQueue`) | `Queue[T, ...]` (`UnboundedQueue`) |
| :--- | :--- | :--- |
| **Algorithm** | Dmitry Vyukov Bounded MPMC with Per-Slot Sequence Counters | Morrison & Afek Linked Concurrent Ring Queue (LCRQ) |
| **Hardware Atomics** | Single-word atomic sequence loads and stores | 128-bit Double-Word Compare-And-Swap (DWCAS: `cmpxchg16b` / `casp`) |
| **Allocation Profile** | **Zero Runtime Allocations**: Ring buffer of size $N$ is preallocated once upfront | **Dynamic Linked Segments**: Allocates 64-element segments on demand; reclaims via Debra |
| **Capacity Handling** | **Bounded**: Returns `false` or raises when full (`push` rejects saturation) | **Unbounded**: Grows dynamically until physical memory exhaustion |
| **Latency Profile** | **Sub-Microsecond Deterministic Latency**: Optimal for real-time and audio systems | **High Throughput Burst Handling**: Absorbs massive bursts without dropping messages |
| **Cache Behavior** | Contiguous power-of-two array with cacheline padding between producer and consumer | Linked segments with cacheline-padded atomic head and tail pointers |
| **Direct Push/Pop API** | SPSC supports bare `q.push(x)` / `q.pop()`; MPMC uses `getProducer()` / `getConsumer()` | Always routes via thread-bound endpoints (`getProducer().bindToThread()`) |

#### Architectural Recommendation
- Use **`BQueue` (or `BoundedQueue`)** when your workload has known maximum throughput bounds, requires strict zero-allocation steady-state guarantees, or operates in hard real-time environments (e.g. audio rendering, network packet processing, financial market feeds).
- Use **`Queue` (or `UnboundedQueue`)** for general-purpose inter-thread worker pools where queue depth may surge unpredictably and producers must never be rejected due to capacity limits.

---

### 2.3 Channel Communication: `Channel[T]` vs `RendezvousChannel[T]`

| Feature | `Channel[T]` (`Sender[T]` / `Receiver[T]`) | `RendezvousChannel[T]` |
| :--- | :--- | :--- |
| **Buffer Geometry** | Bounded ring buffer (`ckBounded`) or unbounded linked segments (`ckUnbounded`) | **Strictly Zero Buffer** (Capacity = 0) |
| **Handoff Mechanism** | Asynchronous / buffered: producers push and return immediately if buffer has space | Synchronous: Sender and receiver must meet in real time |
| **Thread Suspension** | Non-blocking spin/backoff or try-based returns (`send` / `recv`) | Native OS Futex (`ulock_wait` on macOS, `WaitOnAddress` on Windows, Linux futex) |
| **Correlation Tracing**| FIFO stream ordering | Monotonic 64-bit correlation IDs shared bilaterally by sender and receiver |
| **Auto-Registration** | Yes: Thread-local storage (`{.threadvar.}`) caches thread endpoints automatically | Thread-safe direct object handles |
| **Typical Use Cases** | Actor systems, worker thread pools, asynchronous pipelines | Bilateral rendezvous, synchronous request-reply RPC handoff, CSP pipelines |

---

### 2.4 Work Distribution: `TreiberStack[T]` vs `ChaseLevDeque[T]` vs `TaskPool`

- **`TreiberStack[T]` (Centralized LIFO Work-Sharing)**:
  - Best for: Free-lists, memory node recycling, and thread pools where the newest work item is most likely hot in CPU cache.
  - Features an **Elimination-Backoff Array**: Under extreme multi-threaded contention, colliding pushers and poppers exchange items directly in backoff slots without touching the central top pointer, scaling throughput where traditional Treiber stacks collapse.
- **`ChaseLevDeque[T]` (Asymmetric Work-Stealing)**:
  - Best for: Divide-and-conquer parallelism (e.g. recursive tree search, quicksort, ray tracing).
  - The worker thread operates at the `bottom` using LIFO order (`pushBottom` / `popBottom`), keeping local cachelines hot. Starving thief threads operate at the `top` using FIFO order (`steal` / `stealBatch`), stealing the largest remaining grains of work.
- **`TaskPool` (Coordinated Scheduler)**:
  - A production work-stealing thread pool coordinating pinned `ChaseLevDeque` workers, TreiberStack external injection, `forkJoin` recursion, and `parallelFor` chunking.

---

### 2.5 Broadcast & Multicast: `BroadcastRing[T]` vs Queues

Traditional queues deliver each item to **exactly one** consumer (competing consumers). In contrast, `BroadcastRing[T]` delivers every message to **all active subscriber cursors** (1-to-N fan-out).

- **`BroadcastCursor[T]`**: Each subscriber thread registers its own independent cursor that reads monotonically forward through the shared ring.
- **Overflow Policies**:
  - `omDropOldest`: Lossy real-time ring. If a subscriber falls behind the writer by more than the ring capacity, its cursor automatically leaps forward to the oldest unread valid element and logs lag. Ideal for high-frequency telemetry, live audio streams, and financial market tickers.
  - `omBackoff`: Lossless backpressure. The publisher slows down and waits if it is about to overwrite the slowest registered subscriber cursor.
- **`TopicBus[T]`**: A topic multiplexer backed by `Ctrie` that dynamically instantiates and routes messages to dedicated broadcast rings identified by string keys.

---

## 3. Memory Management & Lifetime Guidelines

Writing lock-free data structures in modern Nim requires strict adherence to two critical memory models: **ARC/ORC Lifecycle Semantics** and **Safe Memory Reclamation (SMR)**.

### 3.1 Nim ARC/ORC Invariants & `SlotEncoding(T)`

Nim's ARC (Automatic Reference Counting) and ORC (Cyclic Garbage Collector) manage memory deterministically via compiler-injected hooks: `=copy`, `=dup`, and `=destroy`. In lock-free shared memory, naïve slot assignments would cause data races on reference count headers.

`lockfree` handles payload lifecycles via three distinct storage pathways:

1. **Path-A (Primitive Types)**:
   Scalar primitives (`int`, `uint64`, `float`, `pointer`, `ptr`) fit into machine words and are copied or CAS-exchanged directly with zero heap allocation.
2. **Path-B (Value Objects)**:
   Fixed-size value objects whose bitwise representations can be stored directly within slot records.
3. **Path-C (Managed Types: `ref T`, `string`, `seq[T]`)**:
   Managed objects require atomic ownership transfer. `lockfree` uses `wrapOrIdentity` and `unwrapOrIdentity` combined with Nim's `wasMoved()` primitive:
   - When pushing a `ref T` into a queue, ownership is transferred into the queue slot, and `wasMoved()` clears the local variable so the compiler-injected destructor does not decrement the reference count prematurely.
   - When popping, ownership is transferred back to the receiving thread.
   - In associative structures (`Ctrie`, `SkipListMap`, `SkipListSet`, `BroadcastRing`, `RendezvousChannel`), payloads are managed via an atomic reference-counted indirect container (`VBox[V]`). Memory is only released when all active threads have unpinned their epoch or dropped their references.

---

### 3.2 Debra / NEBR Safe Memory Reclamation (SMR)

#### The Problem: Use-After-Free in Lock-Free Structures
In a lock-free queue or skiplist, when thread $A$ unlinks node $N$, concurrent reader thread $B$ may already hold a pointer to $N$ and be about to read its fields. If thread $A$ frees $N$ immediately to the OS heap, thread $B$ will suffer a fatal **Use-After-Free (UAF)** or memory corruption.

#### The Solution: NEBR 3-Epoch Sliding Window
`lockfree` integrates **NEBR (Neutralization-Enhanced Bounded Reclamation)**, based on Trevor Brown's DEBRA+ algorithm:

```
       Global Epoch (E)
              │
  ┌───────────┼───────────┐
  ▼           ▼           ▼
Epoch E-2   Epoch E-1   Epoch E (Current)
 [RECLAIM]   [PENDING]   [ALLOC & RETIRE]
```

1. **Epoch Registration**: Threads register a slot with the `DebraManager` via `registerThread()`.
2. **Critical Section Pinning**: When accessing shared nodes, a thread enters a critical section (`pin()` or `withEpoch(manager)`).
3. **Deferred Retirement**: When a node is physically unlinked at epoch $E$, it is placed on the thread's local **limbo bag** tagged with epoch $E$.
4. **Safe Reclamation**: A node retired at epoch $E$ is only freed when all active threads have moved to epoch $E+1$ or are unpinned. At epoch $E+2$, it is guaranteed that no thread in the system holds a pointer to that node.
5. **Signal-Driven Neutralization (`SIGUSR1`)**: In standard EBR, if a thread stalls or sleeps while pinned, reclamation halts for the entire system, leading to memory exhaustion. NEBR solves this by sending a `SIGUSR1` signal to stalled threads, atomically neutralizing their pin state and allowing the global epoch to advance safely.

> [!TIP]
> High-level collections like `Ctrie`, `SkipListMap`, `SkipListSet`, `Channel`, and `Queue` handle Debra SMR automatically behind the scenes. You only need explicit SMR ceremonies if you are writing custom low-level lock-free algorithms.

---

## 4. Practical Cookbooks & Code Walkthroughs

All code snippets below are self-contained, idiomatic, and ready to run with `nim c --threads:on -r <file>.nim`.

### 4.1 Concurrent Table (`Table` / `Ctrie`)

High-throughput, lock-free key-value mapping with wait-free lookups and point-in-time snapshots:

```nim
import std/[options, os]
import lockfree

# Initialize a concurrent table (default 64 thread slots)
var users = newTable[int, string]()

# Put and index assignment syntax
users[101] = "Alice"
users[102] = "Bob"
discard users.put(103, "Charlie")

# Thread-safe lookups
echo "User 101: ", users[101] # "Alice"
if users.contains(102):
  echo "User 102 found: ", users.get(102).get()

# Atomic computeIfAbsent: closure runs only if key is not yet present
let score = users.computeIfAbsent(104, proc(id: int): string =
  "ComputedUser_" & $id
)
echo "User 104: ", score

# O(1) Wait-Free Generational Snapshot:
# Captures a frozen point-in-time view without blocking concurrent mutations
let snapshot = users.snapshot()

# Modify live table after snapshot
users[101] = "Alice Updated"
users.del(102)

# Snapshot retains original state!
echo "Snapshot len: ", snapshot.len # 4
echo "Snapshot 101: ", snapshot.get(101).get() # "Alice"
echo "Live table 101: ", users[101] # "Alice Updated"
```

---

### 4.2 Concurrent Sorted Table (`SortedTable` / `SkipListMap`)

Strictly ordered key-value storage with ascending range iterations:

```nim
import std/options
import lockfree

# Initialize a concurrent sorted table
var leaderboard = newSortedTable[int, string]()

# Insert scores in scrambled order
leaderboard[500] = "Player Five"
leaderboard[100] = "Player One"
leaderboard[800] = "Player Eight"
leaderboard[300] = "Player Three"

# Lookups
echo "Leader at 800: ", leaderboard.get(800).get()

# Strictly ascending traversal over level-0 skiplist chain
echo "--- Ascending Order ---"
for (score, player) in leaderboard.pairs():
  echo "Score: ", score, " -> ", player

# Iterate strictly ascending over keys
for score in leaderboard.keys():
  echo "Key: ", score
```

---

### 4.3 Concurrent Set (`Set` / `SkipListSet`)

Thread-safe unique membership and lock-free set algebra:

```nim
import lockfree

var setA = newSet[int]()
var setB = newSet[int]()

# Insert elements
setA.incl(10)
setA.incl(20)
setA.incl(30)

setB.incl(20)
setB.incl(30)
setB.incl(40)

echo "Contains 20 in A: ", setA.contains(20) # true

# Concurrent Set Algebra
let common = setA.intersect(setB)
echo "Intersection: ", common.toSeq() # @[20, 30]

let allItems = setA.union(setB)
echo "Union: ", allItems.toSeq() # @[10, 20, 30, 40]

let diff = setA.difference(setB)
echo "Difference (A - B): ", diff.toSeq() # @[10]

echo "Is common subset of A? ", common.isSubsetOf(setA) # true
```

---

### 4.4 Concurrent Stack (`Stack` / `TreiberStack`)

LIFO stack with elimination-backoff array for extreme contention:

```nim
import std/options
import lockfree

var stack = initStack[string]()

# Push elements
stack.push("Item A")
stack.push("Item B")
stack.push("Item C")

echo "Stack length: ", stack.len # 3
echo "Peek top: ", stack.peek().get() # "Item C" (does not pop)

# LIFO Pop order
while not stack.isEmpty:
  echo "Popped: ", stack.pop().get()
# Output:
# Popped: Item C
# Popped: Item B
# Popped: Item A
```

---

### 4.5 Bounded Queue (`BoundedQueue` / `BQueue`)

Preallocated, zero-allocation ring buffer. Perfect for real-time streaming:

```nim
import std/options
import lockfree

# 1. Single-Producer Single-Consumer (Wait-Free SPSC)
var spsc = newSpscBoundedQueue[int, 16]()
check spsc.push(100)
check spsc.push(200)
echo "SPSC pop: ", spsc.pop().get() # 100

# 2. Multi-Producer Multi-Consumer (Lock-Free MPMC)
# Capacity = 64, Max 4 Producers, Max 4 Consumers
var mpmc = newMpmcBoundedQueue[string, 64, 4, 4]()

# Bind producer slot 0 and consumer slot 0 to current thread
var producer = mpmc.getProducer(0).bindToThread()
var consumer = mpmc.getConsumer(0).bindToThread()

check producer.push("Message 1")
check producer.push("Message 2")

echo "MPMC pop: ", consumer.pop().get() # "Message 1"
```

---

### 4.6 Channel Facade (`Channel[T]`)

Go/Rust-style channels with automatic thread-local registration and graceful shutdown:

```nim
import std/options
import lockfree

# Create a bounded channel with capacity 32
let (tx, rx) = newChannel[int](capacity = 32)

type WorkerCtx = object
  tx: Sender[int]
  rx: Receiver[int]

# Producer thread
proc producerThread(ctx: ptr WorkerCtx) {.thread.} =
  for i in 1 .. 10:
    discard ctx.tx.send(i * 100)
  ctx.tx.close() # Close channel when producer is done

# Consumer thread
proc consumerThread(ctx: ptr WorkerCtx) {.thread.} =
  while true:
    let item = ctx.rx.recv()
    if item.isSome:
      echo "Received: ", item.get()
    elif ctx.rx.isClosed:
      echo "Channel closed and drained. Exiting worker."
      break

var ctx = WorkerCtx(tx: tx, rx: rx)
var thProd, thCons: Thread[ptr WorkerCtx]

createThread(thCons, consumerThread, addr ctx)
createThread(thProd, producerThread, addr ctx)

joinThread(thProd)
joinThread(thCons)
```

---

### 4.7 Synchronous Rendezvous Channel (`RendezvousChannel[T]`)

Zero-buffer synchronous dual channel with OS futex parking and correlation IDs:

```nim
import lockfree

let syncChan = initRendezvousChannel[string]()

type SyncCtx = object
  ch: RendezvousChannel[string]

proc waiterThread(ctx: ptr SyncCtx) {.thread.} =
  var msg: string
  # Blocks until a sender delivers
  let correlationId = ctx.ch.recv(msg)
  echo "Receiver got: '", msg, "' with Correlation ID: ", correlationId

var ctx = SyncCtx(ch: syncChan)
var th: Thread[ptr SyncCtx]
createThread(th, waiterThread, addr ctx)

# Sender delivers directly to receiver with zero intermediate queueing
let sendCid = syncChan.send("Direct handoff payload")
echo "Sender delivered with Correlation ID: ", sendCid

joinThread(th)
```

---

### 4.8 Work-Stealing TaskPool (`TaskPool`)

Parallel fork-join recursion and parallel-for loops:

```nim
import lockfree

# Initialize a work-stealing pool with 4 worker threads
var pool = initTaskPool(4)

# 1. Fire-and-forget asynchronous spawn
pool.spawn(proc() =
  echo "Running background task on work-stealing pool!"
)

# 2. Parallel For loop: processes slices concurrently across workers
var numbers = newSeq[int](1000)
let arrPtr = cast[ptr UncheckedArray[int]](addr numbers[0])

pool.parallelFor(0 .. 999, proc(i: int) =
  arrPtr[i] = (i + 1) * 2
, chunkSize = 64)

# 3. Two-way and Recursive Fork-Join
var leftResult = 0
var rightResult = 0

pool.forkJoin(
  proc() =
    leftResult = 42 * 2,
  proc() =
    rightResult = 100 * 3
)

echo "Fork-join results: ", leftResult, ", ", rightResult

# Sync all work and clean shutdown
pool.sync()
pool.shutdown(wait = true)
```

---

### 4.9 Broadcast Ring & Topic Bus (`BroadcastRing[T]`)

1-to-N fan-out pub-sub where every message reaches all registered subscribers:

```nim
import lockfree

# Create a broadcast ring with capacity 64
let bus = initBroadcastRing[string](capacity = 64, overflowMode = omDropOldest)

# Register two independent reader cursors
var cursorA = bus.subscribe(soFromLatest)
var cursorB = bus.subscribe(soFromLatest)

# Publish messages to the ring
bus.publish("Event 1: System Boot")
bus.publish("Event 2: Network Ready")

# Both subscribers read all messages independently
var msgA, msgB: string
if cursorA.tryRead(msgA):
  echo "Cursor A: ", msgA # "Event 1: System Boot"
if cursorB.tryRead(msgB):
  echo "Cursor B: ", msgB # "Event 1: System Boot"

cursorA.unsubscribe()
cursorB.unsubscribe()
```

---

## 5. Performance Tuning & Best Practices

1. **Enable Threads & Release Optimization**:
   Always compile with:
   ```bash
   nim c -d:release --threads:on -r app.nim
   ```
   For maximum performance where assertion overhead is eliminated, use `-d:danger`.
2. **False Sharing Elimination**:
   `lockfree` aligns all central counters, root pointers, and thread slots to `CacheLineBytes` (64 bytes on x86_64, 128 bytes on Apple Silicon M-series). When designing your own structs to pass through channels, avoid packing hot mutable counters in the same cache line.
3. **Power-of-Two Sizing**:
   Bounded queues (`BQueue`, `BroadcastRing`, `ChaseLevDeque`) require capacities that are powers of two ($2^k$). This allows the internal pointer arithmetic to use blazing-fast bitwise masking (`idx and mask`) instead of expensive integer modulo division (`idx mod cap`).
4. **Choose the Right Backoff Strategy**:
   Under high thread contention, tight busy-waiting burns CPU cycles and saturates memory interconnects. All `lockfree` structures integrate adaptive exponential backoff (`lockfree/backoff`) utilizing CPU pause hints (`pause` on x86, `isb`/`yield` on ARM) before falling back to OS scheduler yields.

---

## 6. Summary Checklist: Which Structure Should I Use?

- Need an **unordered key-value dictionary** with $O(1)$ snapshots? $\rightarrow$ **`Table[K, V]` / `Ctrie`**
- Need a **sorted key-value map** with ordered iteration and range queries? $\rightarrow$ **`SortedTable[K, V]` / `SkipListMap`**
- Need a **concurrent set** with intersection, union, and difference? $\rightarrow$ **`Set[T]` / `SkipListSet`**
- Need a **LIFO stack** that scales linearly under contention? $\rightarrow$ **`Stack[T]` / `TreiberStack`**
- Need a **bounded FIFO queue** with deterministic zero-allocation latency? $\rightarrow$ **`BoundedQueue[T]` / `BQueue`**
- Need an **unbounded FIFO queue** that dynamically handles surges? $\rightarrow$ **`UnboundedQueue[T]` / `Queue`**
- Need **idiomatic Go/Rust channels** with `tx.send` / `rx.recv`? $\rightarrow$ **`Channel[T]`**
- Need **synchronous zero-buffer handoff** with futex parking? $\rightarrow$ **`RendezvousChannel[T]`**
- Need **work-stealing divide-and-conquer** task parallelism? $\rightarrow$ **`Deque[T]` / `ChaseLevDeque` or `TaskPool`**
- Need **1-to-N broadcast messaging** where every consumer sees every event? $\rightarrow$ **`BroadcastRing[T]` / `TopicBus[T]`**
