# Associative Maps & Sets Benchmarks: Ctrie vs SkipListMap

Performance benchmarks comparing `Ctrie` (lock-free concurrent hash trie) and `SkipListMap` (lock-free concurrent sorted map) against standard library `Table` protected by synchronization locks.

## Workload Profiles

Associative benchmarks exercise the data structures under three standard concurrent workload profiles across **1, 2, 4, and 8 threads**:

1. **Read-Heavy (90% Reads / 10% Writes)**: Models caching layers, routing tables, and symbol resolution where lookups vastly dominate mutations.
2. **Balanced (50% Reads / 50% Writes)**: Models session registries, task trackers, and real-time state synchronization under equal read/write pressure.
3. **Write-Heavy (10% Reads / 90% Writes)**: Models high-frequency telemetry ingestion, metrics aggregation, and append-heavy workloads.

Each thread operates on a shared keyspace of 100,000 keys pre-populated with 50,000 entries.

---

## Architectural Comparison

| Dimension | `Ctrie[K, V]` | `SkipListMap[K, V]` | `Table[K, V] + Lock` |
| :--- | :--- | :--- | :--- |
| **Ordering** | Unordered (HAMT 32-way branch) | Sorted (Lock-free SkipList DAG) | Unordered (Open Addressing) |
| **Read Progress** | **Wait-Free Population** (at most 7 levels) | **Lock-Free** (CAS traversal) | **Blocking** (Serializing Mutex) |
| **Write Progress** | **Lock-Free** (CAS on INodes) | **Lock-Free** (CAS multi-level links) | **Blocking** (Serializing Mutex) |
| **Snapshots** | **O(1) Wait-Free Generational Copy** | In-flight atomic iterator | Global table clone under lock |
| **Reclamation** | NEBR (Safe Memory Reclamation) | NEBR (Safe Memory Reclamation) | GC / ARC immediate free |

> [!NOTE] Baseline Synchronization Details
> The `Table + Lock` baseline wraps Nim's standard hash table with an exclusive `std/locks.Lock` (`pthread_mutex_t`), reflecting the standard concurrent Nim idiom. While a reader-writer lock (`RWLock` / `pthread_rwlock_t`) would permit concurrent readers, in practice `RWLock` requires atomic read-lock counter increments and decrements (`fetch_add` / `fetch_sub`) that bounce cache lines across all reader cores on every lookup. In contrast, `Ctrie` lookups are truly wait-free: readers traverse immutable branch nodes without modifying any reader counters or invalidating remote core cache lines.

---

## Key Performance Findings

1. **Wait-Free Read Scaling**:
   Under the **Read-Heavy** workload, `Table + Lock` collapses as thread count scales due to mutex acquisition serialization (dropping from ~32,000 ops/ms at 1T down to ~11,000 ops/ms at 4T). In contrast, `Ctrie` exhibits near-linear read scaling, reaching over **52,000 ops/ms** at 8 threads (>4.5x faster than the locked baseline).
2. **Write Scalability & SMR Efficiency**:
   Under **Write-Heavy** contention, both `Ctrie` and `SkipListMap` scale with core count, leveraging NEBR epoch-based memory reclamation without global stop-the-world pauses. At 8 threads, `SkipListMap` achieves **13,500 ops/ms** and `Ctrie` achieves **10,700 ops/ms**, while the locked table remains bottlenecked at ~6,200 ops/ms.
3. **Sorted Iteration Trade-Off**:
   `SkipListMap` maintains strict key ordering at all times. While its single-threaded raw pointer-chasing overhead is higher than hash-based table lookups, its multi-threaded scalability outpaces mutex-guarded tables once contention exceeds 2 threads.

---

## Interactive Performance Visualizer

### Read-Heavy Workload (90% Lookup / 10% Update)

<div markdown="0">
  <div id="bench-maps-read-heavy" class="bench-panel"></div>
</div>

### Balanced Workload (50% Lookup / 50% Update)

<div markdown="0">
  <div id="bench-maps-balanced" class="bench-panel"></div>
</div>

### Write-Heavy Workload (10% Lookup / 90% Update)

<div markdown="0">
  <div id="bench-maps-write-heavy" class="bench-panel"></div>

  <script src="../../../assets/echarts-5.5.1.min.js"></script>
  <script src="../../../assets/bench-charts.js"></script>
</div>

---

## Methodology Caveats

- **Memory Reclamation**: Both `Ctrie` and `SkipListMap` use thread-local registration via NEBR (`src/lockfree/smr/nebr/`). Thread retirement is amortized across batches.
- **Hash Distribution**: `Ctrie` uses a 32-bit Murmur3 finalizer. Pathological hash collisions degrade to persistent collision lists (`LNode`).
- **Benchmarking Platform**: Benchmarks executed on GitHub-hosted `ubuntu-latest` x86_64 runners.
