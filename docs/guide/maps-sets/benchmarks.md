# Associative Maps & Sets Benchmarks: Ctrie, BTable, SkipListMap & ConcurrentSet

Performance benchmarks comparing `Ctrie` (lock-free concurrent hash trie), `BTable` (preallocated zero-SMR bounded concurrent open-addressing hash table), `SkipListMap` (lock-free concurrent sorted map), and `ConcurrentSet` (`SkipListSet`) against standard library mutex-guarded tables/sets (`locked_table`, `locked_set`), Rust (`dashmap`, `flurry`, `crossbeam_skipmap`, `crossbeam_skipset`), and C++ (`boost::concurrent_flat_map`, `boost::concurrent_flat_set`).

## Workload Profiles

Associative benchmarks exercise the data structures under six concurrent workload profiles across **1, 2, 4, and 8 threads**:

1. **Read-Heavy (`read_heavy`, 90% Reads / 10% Writes)**: Models caching layers, routing tables, and symbol resolution where lookups vastly dominate mutations.
2. **Balanced (`balanced`, 50% Reads / 50% Writes)**: Models session registries, task trackers, and real-time state synchronization under equal read/write pressure.
3. **Write-Heavy (`write_heavy`, 10% Reads / 90% Writes)**: Models high-frequency telemetry ingestion, metrics aggregation, and append-heavy workloads.
4. **ConcurrentSet Mixed (`set_mixed`, 80% Contains / 10% Incl / 10% Excl)**: Evaluates lock-free sorted set membership and mutation throughput.
5. **ConcurrentSet Algebra (`set_algebra`, Union / Intersection / Difference)**: Evaluates bulk lock-free set algebra operations (`+`, `*`, `-`) across concurrent readers and writers.
6. **Wait-Free Snapshot Iteration (`snapshot_iter`)**: Evaluates `Ctrie.snapshot()` $O(1)$ generational root capture + traversal and `BTable.snapshotPairs()` per-slot sequence iteration vs `DashMap` shard-locked iteration and `LockedTable` under concurrent writer contention.

Each thread operates on a shared keyspace of 100,000 keys pre-populated with 50,000 entries.

---

## Architectural Comparison

| Library Slug | Language | Ordering | Read Progress | Write Progress | Reclamation |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `ctrie` | Nim | Unordered (HAMT 32-way) | **Wait-Free** ($O(\log_{32} N)$) | **Lock-Free** (CAS on INodes) | NEBR |
| `btable` | Nim | Unordered (Bounded Open-Addressing) | **Bounded Flat-Combining / Seqlock** | **Bounded Flat-Combining** (Tombstone-aware linear probe) | Preallocated (Zero SMR) |
| `skiplist` / `skiplist_set` | Nim | Sorted (SkipList DAG) | **Lock-Free** (CAS traversal) | **Lock-Free** (multi-level CAS) | NEBR |
| `locked_table` / `locked_set` | Nim | Unordered (Open Addressing) | **Blocking** (`std/locks.Lock`) | **Blocking** (`std/locks.Lock`) | GC / ARC |
| `dashmap` | Rust | Unordered (Sharded RwLock) | **Blocking** (Shard read lock) | **Blocking** (Shard write lock) | RAII |
| `flurry` | Rust | Unordered (Java ConcurrentHashMap port) | **Lock-Free** (Seize EBR) | **Blocking/CAS** (Bin lock) | Seize |
| `crossbeam_skipmap` / `crossbeam_skipset` | Rust | Sorted (Lock-free SkipList) | **Lock-Free** (`crossbeam-epoch`) | **Lock-Free** (CAS links) | Crossbeam Epoch |
| `boost_concurrent_flat_map` / `set` | C++ | Unordered (Bucket-group spinlock) | **Blocking** (Group spin/SIMD) | **Blocking** (Group spinlock) | RAII |

> [!NOTE] Baseline Synchronization Details
> The `locked_table` and `locked_set` baselines wrap Nim's standard `Table` / `HashSet` with an exclusive `std/locks.Lock` (`pthread_mutex_t`), reflecting the standard concurrent Nim idiom. While a reader-writer lock (`RWLock` / `pthread_rwlock_t`) would permit concurrent readers, in practice `RWLock` requires atomic read-lock counter increments and decrements (`fetch_add` / `fetch_sub`) that bounce cache lines across all reader cores on every lookup. In contrast, `Ctrie` lookups are truly wait-free: readers traverse immutable branch nodes without modifying any reader counters or invalidating remote core cache lines.

---

## Key Performance Findings

1. **Wait-Free Read Scaling**:
   Under the **Read-Heavy** workload, `locked_table` collapses as thread count scales due to mutex acquisition serialization (dropping from ~32,000 ops/ms at 1T down to ~11,000 ops/ms at 4T). In contrast, `Ctrie` exhibits near-linear read scaling, reaching over **52,000 ops/ms** at 8 threads (>4.5x faster than the locked baseline).
2. **Write Scalability & SMR Efficiency**:
   Under **Write-Heavy** contention, both `Ctrie` and `SkipListMap` scale with core count, leveraging NEBR epoch-based memory reclamation without global stop-the-world pauses. At 8 threads, `SkipListMap` achieves **13,500 ops/ms** and `Ctrie` achieves **10,700 ops/ms**, while the locked table remains bottlenecked at ~6,200 ops/ms.
3. **$O(1)$ Wait-Free Snapshots & Sorted Set Algebra**:
   `Ctrie.snapshot()` captures a consistent point-in-time read-only view in $O(1)$ time via generation-counted `INode` root duplication without blocking concurrent writers, while `SkipListSet` (`ConcurrentSet`) provides linearizable sorted set operations (`+`, `*`, `-`) without global locking.

---

## Interactive Performance Visualizer

<div markdown="0">
  <div id="bench-status" class="bench-status" hidden></div>
  <div id="bench-toolbar" class="bench-toolbar"></div>
</div>

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
</div>

### ConcurrentSet Mixed Workload (80% Contains / 10% Incl / 10% Excl)

<div markdown="0">
  <div id="bench-sets-mixed" class="bench-panel"></div>
</div>

### ConcurrentSet Algebra (Union / Intersection / Difference)

<div markdown="0">
  <div id="bench-sets-algebra" class="bench-panel"></div>
</div>

### Wait-Free Snapshot Iteration (`snapshot_iter`)

<div markdown="0">
  <div id="bench-maps-snapshot" class="bench-panel"></div>

  <script src="../../../assets/d3-7.9.0.min.js"></script>
  <script src="../../../assets/plot-0.6.17.umd.min.js"></script>
  <script src="../../../assets/bench-charts.js"></script>
</div>

---

## Methodology Caveats

- **Memory Reclamation**: `Ctrie`, `SkipListMap`, and `SkipListSet` use thread-local registration via NEBR (`src/lockfree/smr/nebr/`). Thread retirement is amortized across batches.
- **Hash Distribution**: `Ctrie` uses a 32-bit Murmur3 finalizer. Pathological hash collisions degrade to persistent collision lists (`LNode`).
- **Benchmarking Platform**: Benchmarks executed on GitHub-hosted `ubuntu-latest` x86_64 runners and local multi-core workstations.
