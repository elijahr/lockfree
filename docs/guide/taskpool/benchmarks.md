# TaskPool Benchmarks: Work-Stealing Scheduler Scalability

Performance benchmarks evaluating `TaskPool` (lock-free work-stealing scheduler built on `ChaseLevDeque` and `TreiberStack`) against a mutex-guarded central task queue (`locked_task_queue`) and Rust's `rayon::ThreadPool` (`rayon_pool`).

---

## 1. Scheduler Architecture & Workloads

`TaskPool` combines three lock-free primitives to minimize scheduling overhead across heterogeneous task graphs:

- **Per-Worker LIFO Deque (`ChaseLevDeque[Task]`)**: Worker threads push and pop spawned sub-tasks at the bottom of their local deque in LIFO order with zero atomic RMW instructions on the push path, keeping divide-and-conquer working sets hot in L1/L2 cache.
- **MPMC External Injector (`TreiberStack[Task]`)**: External callers submit root tasks via a non-blocking `TreiberStack` with elimination backoff.
- **Batch Work-Stealing (`stealBatch`)**: Starving workers steal up to 8 tasks at once in FIFO order from peer deques, amortizing cross-core cache-line transfers and balancing recursive tree workloads automatically.

### Workloads Evaluated (`1t`, `2t`, `4t`, `8t`)

1. **`taskpool_parfor` (`parallelFor` Loop Throughput)**:
   Executes 500,000 loop iterations partitioned into 256-iteration chunks using SplitMix64 integer mixing. Throughput is reported in loop iterations per millisecond (`ops/ms`).
2. **`taskpool_forkjoin` (Recursive Divide-and-Conquer Tree)**:
   Recursively forks a binary task tree of depth 13 ($2^{14} - 1 = 16,383$ nodes) using `pool.forkJoin(left, right)` with active caller work-helping (`helpWork`). Throughput is reported in tree nodes executed per millisecond (`ops/ms`).
3. **`taskpool_spawnsync` (High-Churn `spawn` + `sync` Batch)**:
   Spawns 25,000 fine-grained `{.nimcall.}` tasks into the pool followed by a barrier `pool.sync()`. Measures raw task allocation, queuing, and barrier synchronization throughput (`ops/ms`).

---

## 2. Architectural Comparison

| Library Slug | Language | Scheduler Architecture | Local Task Path | Load Balancing |
| :--- | :--- | :--- | :--- | :--- |
| `taskpool` | Nim | `lockfree/taskpool` (`TaskPool`) | Lock-free LIFO `ChaseLevDeque` | FIFO `stealBatch` (up to 8 tasks) |
| `locked_task_queue` | Nim | Mutex + Condvar central work queue | Blocking `std/locks.Lock` acquisition | Central FIFO queue serialization |
| `rayon_pool` | Rust | `rayon::ThreadPool` (`join` / `par_iter`) | Crossbeam work-stealing deque | Adaptive half-deque stealing |

---

## 3. Key Performance Findings

1. **`parallelFor` Chunked Loop Throughput**:
   `TaskPool` sustains **418,000 to 533,000 ops/ms** (>500M iterations/sec) by executing local chunks directly and stealing remaining chunks without lock serialization, outperforming the mutex-guarded central task queue by **2.2x at 4 threads** (`516,745` vs `233,932` ops/ms) and **4.4x at 1 thread** (`533,618` vs `120,422` ops/ms).
2. **Recursive `forkJoin` Work-Stealing Advantage**:
   In recursive divide-and-conquer workloads (`taskpool_forkjoin`), `TaskPool` executes the left branch inline while pushing the right branch to the worker's local `ChaseLevDeque`, reaching **14,950 nodes/ms** at 2 threads (**11.5x faster** than `locked_task_queue` at `1,300` nodes/ms).
3. **High-Churn `spawn` + `sync`**:
   Using zero-closure `{.nimcall.}` task descriptors and active caller helping (`helpWork`) during `pool.sync()`, `TaskPool` achieves **25,563 tasks/ms** at 1T and **19,897 tasks/ms** at 4T (**1.7x–1.9x faster** than `locked_task_queue`).

---

## 4. Interactive Performance Visualizer

<div markdown="0">
  <div id="bench-status" class="bench-status" hidden></div>
  <div id="bench-toolbar" class="bench-toolbar"></div>
</div>

### Parallel Loop Throughput (`taskpool_parfor`)

<div markdown="0">
  <div id="bench-taskpool-parfor" class="bench-panel"></div>
</div>

### Recursive Divide-and-Conquer (`taskpool_forkjoin`)

<div markdown="0">
  <div id="bench-taskpool-forkjoin" class="bench-panel"></div>
</div>

### High-Churn Task Spawn & Sync (`taskpool_spawnsync`)

<div markdown="0">
  <div id="bench-taskpool-spawnsync" class="bench-panel"></div>

  <script src="../../../assets/echarts-5.5.1.min.js"></script>
  <script src="../../../assets/bench-charts.js"></script>
</div>
