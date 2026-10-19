# Safe Memory Reclamation Benchmarks: NEBR vs Atomic RC & Crossbeam Epoch

Performance benchmarks evaluating **NEBR** (Neutralization-based Epoch-Based Reclamation, `lockfree/smr/nebr`) against shared atomic reference counting (`arc_atomic_rc`), mutex-guarded critical sections (`mutex_guard`, `deferred_mutex_free`), and Rust's `crossbeam-epoch` (`crossbeam_epoch`).

---

## 1. Why SMR Performance Matters

In lock-free data structures (`Queue` LCRQ, `Ctrie`, `SkipListMap`, `SkipListSet`), concurrent readers traverse pointers without holding locks. If a writer unlinks a node and frees it immediately, a concurrent reader dereferencing that pointer triggers a use-after-free segfault.

Safe Memory Reclamation (SMR) solves this by deferring physical deallocation until no reader can possibly observe the unlinked pointer:

- **Shared Atomic Reference Counting (`arc_atomic_rc`)**: Every read increments and decrements a shared atomic counter (`fetchAdd` / `fetchSub`). On multi-core CPUs, this causes severe cache-line ping-ponging across L1/L2 caches on **every single read**.
- **Epoch-Based Reclamation (`nebr`, `crossbeam_epoch`)**: Readers record the global epoch in a **cache-line-padded thread-local slot** (`withEpoch(handle)`). No shared memory is mutated on the read path, allowing read critical sections to scale linearly with core count.
- **Signal-Assisted Neutralization (`nebr`)**: Classical EBR (including `crossbeam-epoch`) suffers from unbounded memory growth if a single pinned thread stalls or is preempted by the OS scheduler. NEBR eliminates this pathology via POSIX signal neutralization (`SIGUSR1` + `sigsetjmp`/`siglongjmp`), forcibly unpinning stalled threads after a configurable epoch lag (`neutralizeStalled`).

---

## 2. Workloads Evaluated (`1t`, `2t`, `4t`, `8t`)

1. **`smr_pin_unpin` (Critical-Section Pin/Unpin Overhead & Scaling)**:
   Measures tight critical-section entry, atomic pointer load, and guard exit across 1, 2, 4, and 8 concurrent threads, plus single-thread critical-section latency percentiles (`p50`, `p95`, `p99`, `p999`, `max` in nanoseconds).
2. **`smr_retire_reclaim` (Node Allocation, Retirement, Epoch Advancement & Neutralization)**:
   Each worker thread allocates 64-byte cache-line-aligned nodes, retires them into thread-local limbo bags (`ready.retire`), advances epochs (`advanceEvery(32)`), reclaims limbo bags (`reclaimNow`), and periodically sweeps for stalled peers (`neutralizeStalled`).

---

## 3. Architectural Comparison

| Library Slug | Language | Reclamation Strategy | Read-Path Cost | Stalled-Thread Bound |
| :--- | :--- | :--- | :--- | :--- |
| `nebr` | Nim | `lockfree/smr/nebr` (`DebraManager`) | Thread-local epoch pin (wait-free) | **Bounded** (Signal neutralization) |
| `arc_atomic_rc` | Nim | Shared `Atomic[int64]` `fetchAdd`/`fetchSub` | Shared cache-line RMW bounce | Immediate (reference count = 0) |
| `mutex_guard` | Nim | `std/locks.Lock` critical section | Blocking mutex acquire/release | Blocks all peers if holder stalls |
| `deferred_mutex_free` | Nim | Mutex-guarded deferred free list | Blocking mutex batch free | Blocks all peers if holder stalls |
| `crossbeam_epoch` | Rust | `crossbeam_epoch::pin()` + `defer_destroy` | Thread-local epoch pin | **Unbounded** (stalled pin halts GC) |

---

## 4. Key Performance Findings

1. **12.4x Read-Path Advantage Over Shared Atomic Reference Counting at 8 Threads**:
   While `arc_atomic_rc` is fast on a single core (`260,264` ops/ms at `1t`), cache-line invalidation traffic causes its throughput to **collapse by 11.3x** as core count rises, dropping to just **23,098 ops/ms** at `8t`. In contrast, `nebr` scales linearly with thread count because each thread pins its own cache-line-isolated slot, rising from **67,848 ops/ms** at `1t` to **286,073 ops/ms** at `8t` (**12.4x faster** than `arc_atomic_rc` and **3.5x faster** than `mutex_guard`).
2. **Retire/Reclaim & Bounded Limbo Overhead**:
   Under continuous 64-byte node allocation, retirement, epoch advancement, and neutralization checks (`smr_retire_reclaim`), `nebr` reaches **67,355 ops/ms** at 4 threads (**1.75x faster** than `deferred_mutex_free` at `38,478` ops/ms) while guaranteeing zero leaked limbo bags on thread exit.

---

## 5. Interactive Performance Visualizer

<div markdown="0">
  <div id="bench-status" class="bench-status" hidden></div>
  <div id="bench-toolbar" class="bench-toolbar"></div>
</div>

### Critical-Section Pin/Unpin Throughput (`smr_pin_unpin`)

<div markdown="0">
  <div id="bench-smr-pin-unpin" class="bench-panel"></div>
</div>

### Retire/Reclaim & Neutralization Throughput (`smr_retire_reclaim`)

<div markdown="0">
  <div id="bench-smr-retire-reclaim" class="bench-panel"></div>
</div>

### Critical-Section Guard Latency (`ns`)

<div markdown="0">
  <div id="bench-smr-latency" class="bench-panel"></div>

  <script src="../../../assets/d3-7.9.0.min.js"></script>
  <script src="../../../assets/plot-0.6.17.umd.min.js"></script>
  <script src="../../../assets/bench-charts.js"></script>
</div>
