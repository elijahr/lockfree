# Adversarial Audit: Dead Code, Orphaned Files, and Legacy Pruning

**Auditor**: Caleb Thorne (`auditor-pegasus`), Verification & Adversarial Auditor  
**Date**: October 11, 2026  
**Repository**: `lockfree` (`strand/task-audit-dead-code`)  
**Directive**: `msg_1791689660_orchestrator-whipbird_1002`  
**Status**: COMPLETE / OFFICIAL AUDIT DELIVERABLE  

---

## 1. Executive Summary & Audit Scorecard

In accordance with the `finding-dead-code` protocol, an adversarial sweep across `src/`, `tests/`, `tools/`, and `examples/` was executed under the invariant: **all code is dead until proven alive by verified call paths and test executions**.

### Primary Removals Executed in Strand
- **`examples/compat/` completely removed**: 8 legacy example files (`audio_buffer.nim`, `event_collector.nim`, `job_scheduler.nim`, `mupmuc.nim`, `mupsic.nim`, `sipmuc.nim`, `sipsic.nim`, `task_fanout.nim`) importing obsolete `lockfreequeues` package namespaces were purged from disk.

### Audit Scorecard

| Category | Finding ID | Severity | Description | Status |
| :--- | :--- | :--- | :--- | :--- |
| **Examples** | **DEAD-EX-01** | **HIGH** | `examples/compat/` contained 8 obsolete files importing pre-v5.0 `lockfreequeues`. | **PURGED** |
| **Examples** | **DEAD-EX-02** | **LOW** | `examples/debra_cc_helpers.nim` duplicates `tests/debra_cc_helpers.nim`. | DOCUMENTED |
| **Source (`src/`)** | **DEAD-SRC-01** | **HIGH** | `src/lockfree/typestates/segment_state.nim` is completely orphaned (0 importers, 0 call sites for `slotIsCommittedAndUnread`). | CONFIRMED DEAD |
| **Source (`src/`)** | **DEAD-SRC-02** | **MEDIUM** | `InvalidCallDefect` and `RendezvousDefect` in `src/lockfree/exceptions.nim` are dead types (never raised anywhere). | CONFIRMED DEAD |
| **Source (`src/`)** | **DEAD-SRC-03** | **MEDIUM** | Uncalled private procs in `rendezvous.nim` (`incRef`, `resetParker`), `ctrie.nim` (`freeVBox`, `destroyVBoxCallback`), and `async_bridge.nim` (`incRef`). | CONFIRMED DEAD |
| **Tests (`tests/`)** | **DEAD-TEST-01** | **HIGH** | 6 orphaned pre-v5 bounded queue test files (`t_mpsc.nim`, `t_mpsc_threaded.nim`, `t_spsc.nim`, `t_spsc_threaded.nim`, `t_mpmc.nim`, `t_mpmc_cell.nim`) not imported by any runner. | CONFIRMED DEAD |
| **Tests (`tests/`)** | **DEAD-TEST-02** | **HIGH** | 12 orphaned scratch/prototype test files including `test_minimal.nim` (1-byte empty file), `test_close.nim`, `test_bind_to_thread.nim`, etc. | CONFIRMED DEAD |
| **Tests (`tests/`)** | **DEAD-TEST-03** | **MEDIUM** | 13 un-imported internal typestate unit test files (`t_atomic_loaders.nim`, `t_cas.nim`, `t_fullness_checks.nim`, `t_slot_seq_n.nim`, etc.). | CONFIRMED DEAD |
| **Tests (`tests/`)** | **DEAD-TEST-04** | **MEDIUM** | Orphaned legacy SMR test fixtures in `tests/smr/debra-legacy/` (`t_nebr_dwcas_contention.nim`, `t_nebr_atomics_dsl_negative.nim`, `bench/`, `probes/`, `compile_only/`). | CONFIRMED DEAD |
| **Tools (`tools/`)** | **DEAD-TOOL-01** | **INFO** | `tools/act-cell`, `tools/momus-local`, and `tools/tests/*.sh` verified alive and actively exercised by `nimble act_tests`. | VERIFIED ALIVE |

---

## 2. Directory-by-Directory Audit Findings

### A. `examples/` Directory

#### Finding DEAD-EX-01: Legacy `examples/compat/` Namespace Bloat (Resolved)
- **Files**:
  - `examples/compat/audio_buffer.nim`
  - `examples/compat/event_collector.nim`
  - `examples/compat/job_scheduler.nim`
  - `examples/compat/mupmuc.nim`
  - `examples/compat/mupsic.nim`
  - `examples/compat/sipmuc.nim`
  - `examples/compat/sipsic.nim`
  - `examples/compat/task_fanout.nim`
- **Evidence**:
  Every file in this directory imported `lockfreequeues` and `lockfreequeues/atomic_dsl` (the obsolete v4 package identifier). Neither `lockfree.nimble` nor CI workflows ever compiled or executed these files.
- **Action Taken**: Deleted `examples/compat/` in its entirety.

#### Finding DEAD-EX-02: Helper Duplication (`examples/debra_cc_helpers.nim`)
- **Evidence**: `examples/debra_cc_helpers.nim` duplicates logic from `tests/debra_cc_helpers.nim`.
- **Rationale**: `examples/nim.cfg` restricts search paths to `../src/` and excludes `../tests/` to keep examples standalone for end-users. The file is live because `examples/job_scheduler.nim` imports it.
- **Recommendation**: Retain in `examples/` as an intentional standalone example helper.

---

### B. `src/` Directory (Source Code Audit)

#### Finding DEAD-SRC-01: Orphaned Module `src/lockfree/typestates/segment_state.nim`
- **Path**: `src/lockfree/typestates/segment_state.nim`
- **Contents**:
  ```nim
  proc slotIsCommittedAndUnread*[T; S: static int](
      seg: var Segment[T, ccMulti, ccSingle, S];
      slot: int;
      prevConsumerIdx: int
  ): bool {.inline.} =
    slot >= prevConsumerIdx and seg.committed[slot].load(moRelaxed)
  ```
- **Evidence**:
  1. Grep search across the entire repository reveals **zero importers**:
     `grep -rn "import.*segment_state" src/ tests/` $\rightarrow$ 0 results.
  2. The only mentions of `segment_state` in the repository are two historical comments inside `slot_state.nim`.
  3. Header comment explicitly acknowledges: `## Current call sites: NONE in v0.1.0.`
- **Verdict**: **DEAD CODE**. Safe to delete.

#### Finding DEAD-SRC-02: Dead Exception Declarations in `src/lockfree/exceptions.nim`
- **Path**: `src/lockfree/exceptions.nim`
- **Evidence**:
  1. `InvalidCallDefect* = object of Defect`:
     In v5.0.0, runtime defect checks for invalid producer/consumer calls were replaced with compile-time `{.error.}` guards (tested in `tests/should_fail/runner.nim`). A codebase-wide grep confirms `InvalidCallDefect` is **never instantiated or raised anywhere in `src/`**.
  2. `RendezvousDefect* = object of Defect`:
     Exported by `src/lockfree/rendezvous.nim:40`, but **never instantiated, raised, or caught anywhere in the repository**. All rendezvous timeout/closed conditions raise `ChannelClosedDefect` or return boolean/option flags.
- **Verdict**: **DEAD TYPES**. Retained only if external backward-compatibility demands it; otherwise safe to deprecate and prune.

#### Finding DEAD-SRC-03: Uncalled Private Utility Procedures
- **Evidence**: Static AST and word-boundary call graph analysis identified 5 private routines with zero call sites in their declaring modules or across the project:
  1. `src/lockfree/rendezvous.nim:88`: `proc incRef[T](box: ptr VBox[T])` (VBox is allocated with `rc=1` and decremented with `decRef`; `incRef` is never called).
  2. `src/lockfree/rendezvous.nim:160`: `proc resetParker(p: var Parker)` (Parker words are written via `store(0)` in `initParker` or `park`; `resetParker` is never invoked).
  3. `src/lockfree/ctrie.nim:250`: `proc freeVBox[V](box: ptr VBox[V])` (Inline alias for `decRef(box)`; unused).
  4. `src/lockfree/ctrie.nim:253`: `proc destroyVBoxCallback[V](p: pointer)` (Unused callback).
  5. `src/lockfree/async_bridge.nim:60`: `proc incRef[T](box: ptr AsyncPayloadBox[T])` (Payload boxes are single-consumer; `incRef` is never called).
- **Verdict**: **DEAD ROUTINES**. Safe to remove during source hygiene refactoring.

---

### C. `tests/` Directory (Test Suite Audit)

#### Finding DEAD-TEST-01: Legacy Pre-v5 Bounded Queue Test Files
- **Files**:
  - `tests/t_mpsc.nim`
  - `tests/t_mpsc_threaded.nim`
  - `tests/t_spsc.nim`
  - `tests/t_spsc_threaded.nim`
  - `tests/t_mpmc.nim`
  - `tests/t_mpmc_cell.nim`
- **Evidence**:
  Documented in `tests/test.nim:5-10`:
  > *"v5.0.0: legacy bounded test imports removed. Per-family Mpsc/Spmc/Mpmc/Spsc coverage now lives in the t_queue_bounded_* files below, with verified pass-count parity (mpsc 28/28, spmc 27/27, mpmc 28/28, spsc 21/21, mpsc_threaded 2/2, spsc_threaded 2/2). The legacy tests/t_{mpsc,spmc,mpmc,spsc}{,_threaded}.nim files remain on disk until they are deleted alongside their src/ counterparts."*
  Because their `src/` counterparts (`src/lockfree/{mpsc,spmc,mpmc,spsc}.nim`) have already been deleted, these test files are entirely orphaned.
- **Verdict**: **DEAD TEST FILES**. Recommended for deletion.

#### Finding DEAD-TEST-02: Orphaned Scratch / Prototype Test Files
- **Files**:
  - `tests/test_minimal.nim` (**1-byte empty file!**)
  - `tests/test_close.nim`
  - `tests/test_bind_to_thread.nim`
  - `tests/test_bqueue_endpoint_compile.nim`
  - `tests/test_bqueue_get_producer_here.nim`
  - `tests/test_bqueue_push_pop_typed.nim`
  - `tests/test_endpoint_types.nim`
  - `tests/test_endpoint_typestate.nim`
  - `tests/test_queue_endpoint_compile.nim`
  - `tests/test_queue_get_producer_here.nim`
  - `tests/test_queue_push_pop_typed.nim`
  - `tests/test_spawn.nim`
- **Evidence**:
  These files were scratch tests created during early prototyping of the Endpoint and Spawn subsystems. None are imported by `tests/unit/runner.nim`, `tests/concurrency/runner.nim`, `tests/stress/runner.nim`, or `tests/test.nim`. None are executed by `lockfree.nimble` or GitHub Actions CI.
- **Verdict**: **DEAD SCRATCH FILES**. Recommended for deletion.

#### Finding DEAD-TEST-03: Orphaned Typestate Substrate Unit Tests
- **Files**:
  - `tests/t_atomic_loaders.nim`
  - `tests/t_cas.nim`
  - `tests/t_fullness_checks.nim`
  - `tests/t_slot_seq_n.nim`
  - `tests/t_storage_n.nim`
  - `tests/t_storage_n1.nim`
  - `tests/t_typestates_import.nim`
  - `tests/t_virtual_values_n.nim`
  - `tests/t_virtual_values_n1.nim`
  - `tests/t_queue_smart_constructors.nim`
  - `tests/t_queue_unbounded_batch.nim`
  - `tests/t_unbounded_spsc_lockfree_check.nim`
  - `tests/t_unbounded_spsc_lockfree_types.nim`
- **Evidence**:
  These test files were written to unit-test `src/lockfree/typestates/*` primitives, but were never wired into the test runners or CI suites. They sit unexecuted in `tests/`.
- **Verdict**: **ORPHANED TESTS**. Should either be imported into `tests/unit/runner.nim` for active regression coverage, or pruned.

#### Finding DEAD-TEST-04: SMR Legacy Fixtures in `tests/smr/debra-legacy/`
- **Files**:
  - `tests/smr/debra-legacy/t_nebr_dwcas_contention.nim` (omitted from `t_nebr_all.nim`, unreferenced anywhere)
  - `tests/smr/debra-legacy/t_nebr_atomics_dsl_negative.nim` (unreferenced anywhere)
  - `tests/smr/debra-legacy/t_nebr_item_processing.nim` (excluded due to missing upstream example dependencies)
  - `tests/smr/debra-legacy/t_nebr_lockfree_stack_typestates.nim` (excluded due to missing upstream example dependencies)
  - `tests/smr/debra-legacy/bench/` (unreferenced by nimble or CI)
  - `tests/smr/debra-legacy/compile_only/` (unreferenced by nimble or CI)
  - `tests/smr/debra-legacy/probes/` (unreferenced by nimble or CI)
- **Verdict**: **ORPHANED LEGACY SMR ASSETS**.

---

### D. `tools/` Directory
- **Files**:
  - `tools/act-cell`
  - `tools/momus-local`
  - `tools/tests/test_act_cell_watchdog.sh`
  - `tools/tests/test_act_cell_envvar.sh`
- **Evidence**:
  The shell test scripts in `tools/tests/` are actively executed by `lockfree.nimble:175-176` under `nimble act_tests`. The CLI tools are developer utilities for running local containerized CI cells.
- **Verdict**: **ALIVE AND MAINTAINED**. No dead code.

---

## 3. Removal & Remediation Plan

### Immediate Action (Completed in this Strand)
1. Pruned `examples/compat/` (8 files) to eliminate stale namespace references.

### Next Phased Cleanup Actions
1. **Delete Empty / Prototype Files**:
   - `rm tests/test_minimal.nim` (0 lines, empty file)
   - Prune obsolete `tests/test_*.nim` prototypes (11 files).
2. **Delete Legacy Bounded Queue Tests**:
   - Delete `tests/t_{mpsc,spmc,mpmc,spsc}{,_threaded}.nim` (parity verified in `t_queue_bounded_*`).
3. **Delete Orphaned Module**:
   - `rm src/lockfree/typestates/segment_state.nim`.
4. **Wire or Prune Orphaned Typestate Tests**:
   - Evaluate `tests/t_atomic_loaders.nim`, `t_cas.nim`, etc., and either add them to `tests/unit/runner.nim` or archive them.

---
*Signed,*  
**Caleb Thorne** (`auditor-pegasus`)  
Verification & Adversarial Auditor, `lockfree` Swarm
