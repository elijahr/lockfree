# Stacks, Deques & Priority Queues Benchmarks: Elimination Backoff, Work-Stealing & Bounded Heaps

Performance benchmarks evaluating `TreiberStack` (unbounded MPMC stack with elimination backoff array), `BStack` (preallocated zero-SMR bounded MPMC stack with elimination backoff), `ChaseLevDeque` (single-worker, multi-thief work-stealing deque with single and batch stealing), and `BPriorityQueue` / `SkipListPriorityQueue` against `locked_stack`, `locked_pq`, C++ `boost::lockfree::stack` (`boost_lockfree_stack`), and Rust `crossbeam_deque::Worker` / `Stealer` (`crossbeam_deque`, `crossbeam_deque_batch`).

---

## 1. TreiberStack & BStack vs Boost.LockFree & Locked Stack (MPMC Contention)

The classic Treiber stack algorithm suffers from extreme contention on its single top-pointer under high concurrency. Both `TreiberStack` (unbounded, NEBR-backed) and `BStack` (preallocated, zero-SMR bounded) incorporate an **Elimination-Backoff Array**: when threads collide attempting to CAS the stack top, they attempt to pair up in a randomized collision array. A concurrent `push` and `pop` exchange items directly in $O(1)$ time, eliminating the round-trip through the stack top and allowing throughput to scale beyond single-CAS hardware limits.

### Architectural Comparison

| Library Slug | Language | Implementation | Progress Guarantee | Contention Mitigation |
| :--- | :--- | :--- | :--- | :--- |
| `treiber_stack` | Nim | `lockfree/stack` (`TreiberStack[T]`) | Lock-Free (Push & Pop) | Elimination-backoff collision array + NEBR |
| `bstack` | Nim | `lockfree/bstack` (`BStack[T, Cap]`) | Lock-Free (Tagged slot CAS) | Preallocated slot pool + elimination-backoff array (Zero SMR) |
| `tagged_stack` | Nim | `lockfree/stack128` (`TaggedStack[T]`) | Lock-Free (128-bit DWCAS) | 128-bit hardware DWCAS + monotonic 64-bit ABA counter + freelist (Zero SMR) |
| `boost_lockfree_stack` | C++ | `boost::lockfree::stack<T>` | Lock-Free (Tagged pointer CAS) | Exponential backoff (no elimination array) |
| `locked_stack` | Nim | `seq[T]` + `std/locks.Lock` | Blocking (`pthread_mutex_t`) | OS mutex queue serialization |
| `chase_lev_deque` | Nim | `lockfree/deque` (`ChaseLevDeque[T]`) | Wait-Free Push / Lock-Free Steal | Cache-line isolated top/bottom indices |
| `chase_lev_deque_batch` | Nim | `ChaseLevDeque.stealBatch` | Wait-Free Push / Lock-Free Batch Steal | Single CAS amortizes up to $K$ stolen tasks |
| `crossbeam_deque` / `batch` | Rust | `crossbeam_deque::Worker` / `Stealer` | Lock-Free Work-Stealing | Epoch-reclaimed circular buffer + batch steal |
| `bpriority_queue` | Nim | `lockfree/bpriority_queue` (`BPriorityQueue[T, Cap]`) | Bounded Flat-Combining | Preallocated binary min-heap + combiner publication array (Zero SMR) |
| `skiplist_pq` | Nim | `lockfree/priority_queue` (`SkipListPriorityQueue[T]`) | Lock-Free (Lindén-Jonsson) | Logical deletion prefix + batch level-0 unlink + NEBR |
| `locked_pq` | Nim | `std/heapqueue.HeapQueue[T]` + `std/locks.Lock` | Blocking (`pthread_mutex_t`) | OS mutex queue serialization |

### Topographies Evaluated

- **1p1c**: 1 Producer, 1 Consumer
- **2p2c**: 2 Producers, 2 Consumers
- **4p4c**: 4 Producers, 4 Consumers
- **8p8c**: 8 Producers, 8 Consumers

### Interactive Performance Visualizer

<div markdown="0">
  <div id="bench-status" class="bench-status" hidden></div>
  <div id="bench-toolbar" class="bench-toolbar"></div>
</div>

### MPMC Stack Contention Visualizer

<div markdown="0">
  <div id="bench-stacks-mpmc" class="bench-panel"></div>
</div>

---

## 2. ChaseLevDeque Work-Stealing Scalability (Single & Batch Steal)

`ChaseLevDeque` is the canonical algorithmic building block for high-performance work-stealing schedulers (e.g. `lockfree`'s `TaskPool`, Go runtime, Rust Tokio/Rayon, Java ForkJoinPool).

### Concurrency Topology

- **Worker Thread (Owner)**: Pushes and pops tasks at the **bottom** in strict **LIFO** order (cache-hot local work).
- **Thief Threads (Thieves)**: Concurrent worker threads steal tasks from the **top** in **FIFO** order using atomic CAS (`steal` or `stealBatch`).

### Work-Stealing Shapes Evaluated

- **1w1t**: 1 Worker, 1 Thief
- **1w2t**: 1 Worker, 2 Thieves
- **1w4t**: 1 Worker, 4 Thieves
- **1w8t**: 1 Worker, 8 Thieves

### Work-Stealing Throughput Visualizer

<div markdown="0">
  <div id="bench-deques-work-stealing" class="bench-panel"></div>
</div>

---

## 3. Priority Queues: BPriorityQueue vs SkipListPriorityQueue & Locked Heap (MPMC Contention)

`BPriorityQueue[T, Cap]` provides a preallocated, zero-SMR bounded priority queue backed by a contiguous binary min-heap and a flat-combining publication array, whereas `SkipListPriorityQueue[T]` implements the unbounded Lindén-Jonsson lock-free skip-list priority queue with NEBR reclamation.

### Priority Queue Contention Visualizer

<div markdown="0">
  <div id="bench-pqueue-mpmc" class="bench-panel"></div>

  <script src="../../../assets/d3-7.9.0.min.js"></script>
  <script src="../../../assets/plot-0.6.17.umd.min.js"></script>
  <script src="../../../assets/bench-charts.js"></script>
</div>

---

## Key Performance Findings

1. **Elimination Backoff & Zero-SMR Bounded Stacks (`BStack` & `TreiberStack`)**:
   Under heavy MPMC contention (`4p4c` and `8p8c`), both `BStack` and `TreiberStack` sustain throughput via elimination-backoff pairing without lock starvation or unbounded priority inversion, with `BStack` eliminating all heap allocation and SMR epoch tracking on the hot path.
2. **Work-Stealing & Batch-Steal Peak Throughput**:
   `ChaseLevDeque` achieves over **35,000 ops/ms** at `1w1t` and sustained throughput of over **11,000 ops/ms** even when 4 thieves simultaneously contend on the steal head pointer. Using `stealBatch` (`chase_lev_deque_batch`) further multiplies effective steal bandwidth by transferring up to half of available tasks in a single atomic CAS on `top`.
3. **Bounded Contiguous Binary Heap vs Unbounded Skip-List Priority Queue**:
   `BPriorityQueue` leverages contiguous cache-friendly array indexing and flat-combining batching to outperform both `SkipListPriorityQueue` and mutex-guarded binary heaps (`locked_pq`) across all MPMC contention levels (`1p1c` through `8p8c`) with zero hot-path allocations.

