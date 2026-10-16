# Implementation Plan: Lockfree v0.3.1 Remediation & v0.4.0 Roadmap Primitives

> **Authority**: Ratified under Garden / Rhizo / Vine Swarm Governance
> **Lead Orchestrator**: `@lockfree-orchestrator` (Canonical Trunk / Non-implementing Conductor)
> **Active Fleet**: 4 Sovereign Worker Sessions (`auditor-pegasus`, `architect-lynx`, `bench-falcon`, `implementer-starling`)

---

## 1. Swarm Roster & Role Mapping

| Worker Name | Role & Persona | Assigned Subsystems & Responsibilities |
| :--- | :--- | :--- |
| **`@architect-lynx`** | Systems & SMR Architect | Core concurrency, SMR, SPSC/MPMC async bridges, spinlock elimination, dual queue memory leaks, and `AtomicArc[T]` / `AtomicSharedPtr[T]` |
| **`@auditor-pegasus`** | Adversarial QA & Purist Auditor | Test suite wiring, unreferenced dead code purging, negative controls, TSan assertions, and `SkipListPriorityQueue[T]` |
| **`@bench-falcon`** | Benchmarks & FFI Lead | Subsystem benchmark parity, CLI argument filters, Rust/C++ FFI asymmetry fixes, BMF snapshotting, and CI pipeline unification |
| **`@implementer-starling`** | DevEx & Integration Lead | C ABI surface expansion (`liblockfree`), public header sync, docs restructuring, and `FlatCombiner[T]` |

---

## 2. Distributed Locking & Concurrency Schedule

Before modifying any shared header or configuration file, workers must acquire an atomic fencing lease:
- **Lock Target**: `file:src/lockfree.nim`
  - *Owner*: `@architect-lynx`
  - *Command*: `rhizo lock file:src/lockfree.nim 600 --fencing`
- **Lock Target**: `file:src/lockfree/cabi.nim`
  - *Owner*: `@implementer-starling`
  - *Command*: `rhizo lock file:src/lockfree/cabi.nim 600 --fencing`
- **Lock Target**: `file:.github/workflows/bench.yml`
  - *Owner*: `@bench-falcon`
  - *Command*: `rhizo lock file:.github/workflows/bench.yml 600 --fencing`

---

## 3. Vine Strand Lifecycle & Verification Matrix

For all parallel tasks:
1. **Provision Strand**:
   ```bash
   vine new <task_id> --branch strand/<task_id>
   ```
2. **Execute Work Inside Strand**:
   - Implement code changes.
   - Run local unit tests and formatters (`nimble testUnit`, `nimble testThreaded`).
3. **Two-Key Gate Verification**:
   ```bash
   vine gate --json
   ```
   *Must verify exit code 0: Key 1 (in-memory merge-tree) PASS + Key 2 (compiler/test suite) PASS.*
4. **Trunk Weaving**:
   *Orchestrator fast-forwards verified branch into main:*
   ```bash
   vine weave
   ```

---

## 4. Phase-by-Phase Task Checklist

### Phase 1: v0.3.1 Adversarial Red-Team Remediation Fleet (19 Items)

#### Wave 1A: Core Concurrency, Async Spinlocks & Memory Leaks (`@architect-lynx`)
- [x] **Task 1.1: Fix Chronos/Async Bridge Split-Brain & Umbrella Export** (`CRIT-WIRE-01`, `CRIT-WIRE-02`)
  - *Strand*: `strand/fix-chronos-split-brain`
  - *Lock*: `rhizo lock file:src/lockfree.nim 600 --fencing`
  - *Provider*: `src/lockfree/chronos.nim`, `src/lockfree.nim`
  - *Consumer*: Export `async_bridge` when `defined(lockfreeChronos)` as well as `defined(lockfreeAsyncdispatch)`; sync `LockfreeVersion` with `lockfree.nimble`.
  - *Replacement Deletion*: Replace legacy SPSC-only `chronos.nim` body with re-export of `async_bridge`.
  - *Weave Gate*: `vine gate --json` (Woven @ `ead0a8d`)

- [x] **Task 1.2: Eliminate Spinlocks & Data Races in AsyncBridge** (`CRIT-LOCK-01`, `HIGH-RACE-01`)
  - *Strand*: `strand/fix-async-spinlocks`
  - *Provider*: `src/lockfree/async_bridge.nim`, `src/lockfree/broadcast.nim`
  - *Consumer*: Make `AsyncSignal` use an atomic lock-free waiter stack; route `AsyncTopicBus` via `TopicBus`'s lock-free `Ctrie` (removing spinlock & $O(N)$ `seq` scan); replace `AsyncBroadcastRing.cursors` with lock-free slot table; delegate `AsyncRendezvousChannel` to `RendezvousChannel`.
  - *Replacement Deletion*: Delete `acquireLock(Atomic[bool])` and linear `seq` scans.
  - *Weave Gate*: `vine gate --json` (Woven @ `d5c8aa2`)

- [ ] **Task 1.3: Fix Unbounded Memory Leak in RendezvousChannel & Optimize Hot Paths** (`CRIT-MEM-01`, `HIGH-PERF-01`, `HIGH-PERF-02`, `MED-MEM-02`)
  - *Strand*: `strand/fix-rendezvous-leak-and-perf`
  - *Provider*: `src/lockfree/rendezvous.nim`, `src/lockfree/broadcast.nim`, `src/lockfree/taskpool.nim`, `src/lockfree/ctrie.nim`, `src/lockfree/skiplist.nim`
  - *Consumer*: Recycle `RendezvousWaiter[T]` nodes (free-list/slab); eliminate `allocShared0` and 64-cursor hazard scan in `BroadcastRing.publish`; fix `tryPublish` TOCTOU race in `omBackoff`; replace `os.sleep(1)` in `TaskPool` with `Parker` eventcount; fix 32-entry TLS handle cache eviction leak in `Ctrie` and `SkipListMap`.
  - *Weave Gate*: `vine gate --json`

#### Wave 1B: C ABI Surface Expansion & Documentation Consolidation (`@implementer-starling`)
- [ ] **Task 1.4: Expand C ABI & Reorganize C Headers** (`HIGH-WIRE-03`, `HIGH-WIRE-04`)
  - *Strand*: `strand/expand-cabi-and-headers`
  - *Lock*: `rhizo lock file:src/lockfree/cabi.nim 600 --fencing`
  - *Provider*: `src/lockfree/cabi.nim`, `include/lockfree_rendezvous.h`, `include/lockfree.h`, `include/lockfree_streambuffer.h`
  - *Consumer*: Add C ABI bindings for `TopicBus` (`lfq_topic_bus_*`) and `MPMCStreamRing` (`lfq_mpmc_stream_ring_*`); turn `lockfree_rendezvous.h` into a standalone header; deduplicate `lfq_rendezvous_*` and `lf_rendezvous_*`.
  - *Replacement Deletion*: Delete circular `#include "lockfree.h"` stub in `include/lockfree_rendezvous.h`.
  - *Weave Gate*: `vine gate --json`

- [ ] **Task 1.5: Consolidate Documentation & Purge Swarm Litter** (`MED-DEAD-02`)
  - *Strand*: `strand/consolidate-docs`
  - *Provider*: `docs/`
  - *Consumer*: Merge `docs/designs/` $\to$ `docs/design/`, `docs/guides/` $\to$ `docs/guide/`, update `mkdocs.yml` links.
  - *Replacement Deletion*: Delete `docs/reviews/`, `docs/internal/`, `docs/transitions/`, `docs/transition_plan.md`.
  - *Weave Gate*: `vine gate --json`

#### Wave 1C: Benchmark Asymmetry Fixes & CI Pipeline Unification (`@bench-falcon`)
- [x] **Task 1.6: Fix Benchmark Asymmetries & Add CLI Filter Arguments** (`HIGH-BENCH-02..05`, `MED-BENCH-06`)
  - *Strand*: `strand/fix-benchmark-asymmetries`
  - *Provider*: `benchmarks/nim/bench_*.nim`, `benchmarks/rust/bench-ffi-crossbeam/src/lib.rs`
  - *Consumer*: Align `dkChaseLevBatch` vs `cb_deque_steal_batch` payload handling; emit `latency_p99_ns` in `bench_maps.nim`; align `parallelFor` sink accumulation across `TaskPool`, `LockedPoolCore`, and `rayon`; match 64-byte allocations in `cbe_retire_reclaim_batch`; add CLI filter argument parsing across all 7 benchmark binaries.
  - *Weave Gate*: `vine gate --json` (Woven @ `68eb249`)

- [x] **Task 1.7: Unify CI Benchmark Workflows & Snapshot Pipeline** (`CRIT-BENCH-01`)
  - *Strand*: `strand/unify-bench-ci`
  - *Lock*: `rhizo lock file:.github/workflows/bench.yml 600 --fencing`
  - *Provider*: `.github/workflows/bench.yml`, `.github/workflows/bench-comparison.yml`
  - *Consumer*: Merge Rust/C++ benchmark adapters into `bench.yml` so `docs/assets/bench-results/latest.json` is updated with full comparison data on `main`.
  - *Weave Gate*: `vine gate --json` (Woven @ `7b596a8`)

#### Wave 1D: Test Suite Wiring, Hang Prevention Watchdog & Dead Code Purge (`@auditor-pegasus`)
- [x] **Task 1.8: Wire All 11 Omitted Test Suites into `nimble test` & Purge 31 Dead Test Files** (`HIGH-WIRE-05`, `MED-DEAD-01`)
  - *Strand*: `strand/wire-tests-and-purge-dead-code`
  - *Provider*: `tests/unit/runner.nim`, `tests/concurrency/runner.nim`, `tests/test.nim`
  - *Consumer*: Import `t_path_c_matrix`, 8 `t_verify_pop_clears_*`, `t_queue_smart_constructors`, `t_cabi` into runners.
  - *Replacement Deletion*: Delete all 47 legacy unreferenced test files.
  - *Weave Gate*: `vine gate --json` (Woven @ `5255144`)

- [ ] **Task 1.9: Per-Test Sentinel Watchdog Thread & Hang Prevention** (`@auditor-pegasus`)
  - *Strand*: `strand/task-test-watchdog`
  - *Provider*: `tests/test_watchdog.nim`
  - *Consumer*: Wire into `tests/unit/runner.nim`, `tests/concurrency/runner.nim`, `tests/test.nim`, `tests/stress/runner.nim`.
  - *Config*: Default ON; configurable via `LFQ_TEST_TIMEOUT_SEC` / `-d:lockfreeTestTimeoutSec` (default: 180s / 3 min); turn-offable via `LFQ_TEST_WATCHDOG=0` / `-d:lockfreeNoTestWatchdog`. Sentinel thread cancelled on test completion, cleanly joined in `testRunEnded` for zero TSan thread leaks.
  - *Weave Gate*: `vine gate --json`

---

### Phase 2: v0.4.0 Roadmap Primitives

- [ ] **Task 2.1: Implement Lock-Free `AtomicArc[T]` / `AtomicSharedPtr[T]`** (`@architect-lynx`)
  - *Strand*: `strand/feat-atomic-arc`
  - *Provider*: `src/lockfree/atomic_arc.nim`, `src/lockfree.nim`
  - *Consumer*: Provide split-reference-counted 128-bit DWCAS atomic pointer with lock-free `load()`, `store()`, `swap()`, `compareExchange()`; wire into C ABI and test suite.
  - *Weave Gate*: `vine gate --json`

- [ ] **Task 2.2: Implement Lock-Free `SkipListPriorityQueue[T]`** (`@auditor-pegasus`)
  - *Strand*: `strand/feat-skiplist-priority-queue`
  - *Provider*: `src/lockfree/priority_queue.nim`, `src/lockfree.nim`
  - *Consumer*: Lindén-Jonsson lock-free priority queue with logical deletion batching and NEBR SMR; integrate with `TaskPool` deadline scheduling and test suite.
  - *Weave Gate*: `vine gate --json`

- [ ] **Task 2.3: Implement Generic `FlatCombiner[T]` Adapter** (`@implementer-starling`)
  - *Strand*: `strand/feat-flat-combiner`
  - *Provider*: `src/lockfree/flat_combiner.nim`, `src/lockfree.nim`
  - *Consumer*: Hendler-Incze-Shavit-Tzafrir Flat-Combining wrapper turning sequential data structures into high-throughput concurrent structures; wire into C ABI, test suite, and benchmarks.
  - *Weave Gate*: `vine gate --json`
