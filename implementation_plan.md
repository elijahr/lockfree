# Implementation Plan: Production-Ready `lockfree` & `lockfreequeues` Compatibility

**Target Repository**: `/Users/eek/Development/lockfree`  
**Compatibility Layer**: `lockfreequeues` legacy API shim  
**Swarm Orchestrator**: `orchestrator-whipbird`  
**Ratified Swarm Triad**:
- `architect-horsetail`: Marcus Vance (Staff Systems Architect)
- `auditor-pegasus`: Caleb Thorne (Verification & Adversarial Auditor)
- `implementer-kite`: Elena Rostova (DevEx & Implementation Lead)

---

## 1. Swarm Roster & Role Mapping

| Worker Name | Persona | Role | Core Mandate & Assigned Subsystems |
| :--- | :--- | :--- | :--- |
| **`architect-horsetail`** | Marcus Vance | Staff Systems Architect | Memory orderings (`moAcquire`/`moRelease`), Vyukov bounded MPMC, strict LCRQ unbounded MPMC, NEBR SMR lifecycle, DEBRA pin-claim invariants. |
| **`auditor-pegasus`** | Caleb Thorne | Verification & Adversarial Auditor | Zero green mirages, compile-fail negative controls (`tests/should_fail`), non-copyable move-analyzer tests (`=copy {.error.}`), TSAN/ASAN sanity, Two-Key Gate verification. |
| **`implementer-kite`** | Elena Rostova | DevEx & Implementation Lead | Rapid strand implementation, `lockfreequeues` backwards-compatibility shim, porting pending candidates from `v5-port-candidates-from-v4.3.md`, Two-Key Gate clearance. |

---

## 2. Distributed Locking & Concurrency Schedule

Before modifying any shared or critical core files, designated workers must acquire an atomic fencing lease via Rhizo:

| Shared Resource | Lock Name | Primary Owner | Expected Lease | Monotonic Fencing Verification |
| :--- | :--- | :--- | :--- | :--- |
| `src/lockfree/smr/nebr/typestates/manager.nim` | `lock:file:nebr:manager` | `implementer-kite` | 300s | `rhizo lock lock:file:nebr:manager 300 --fencing` |
| `src/lockfree/queue.nim` | `lock:file:core:queue` | `architect-horsetail` | 600s | `rhizo lock lock:file:core:queue 600 --fencing` |
| `src/lockfree/compat/` | `lock:file:compat:lockfreequeues`| `implementer-kite` | 300s | `rhizo lock lock:file:compat:lockfreequeues 300 --fencing` |

*Invariant*: If a lease expires, mutations must abort. Never overwrite shared state with a stale fencing token.

---

## 3. Vine Strand Lifecycle & Verification Matrix

All feature and refactoring tracks execute in isolated Rift / Git-worktree strands:

1. **Strand Provisioning**:
   ```bash
   vine new <task_id> --worktree
   ```
2. **Local Implementation & Testing**:
   - Implement assigned changes within the isolated strand directory.
   - Run unit tests and formatters.
3. **Two-Key Gate Verification**:
   ```bash
   vine gate --json
   ```
   *Requirements*:
   - Key 1 (Mechanical Merge-Tree): Clean mergeability against canonical trunk (`main`).
   - Key 2 (Semantic Test Suite): Clean pass of `nim r tests/should_fail/runner.nim` and MM tests.
4. **Trunk Weaving**:
   - Orchestrator (`orchestrator-whipbird`) verifies Two-Key Gate report and fast-forwards the strand into trunk:
     ```bash
     vine weave
     ```

---

## 4. Phase-by-Phase Task Checklist

### Phase 1: SMR / NEBR Hardening (from `nim-debra` backup)
- [x] **Task 1.1: NEBR Manager CFG False-Positive Bypass & Signal Handler Sink** (`implementer-kite`)
  - *Strand*: `strand/nebr-cfg-fix`
  - *Lock*: `lock:file:nebr:manager`
  - *Action*: Port commit `0f5eb87` into `src/lockfree/smr/nebr/typestates/manager.nim`:
    - Added `{.skipCfgAnalysis.}` to `shutdown` proc.
    - Added `sink` annotation to `h: HandlerUninstalled` in `signal_handler.nim`.
  - *Verification*: `nimble test` passed (6.5s).
  - *Weave*: Woven into `main` (`4d35a15`).

- [x] **Task 1.2: NEBR Hardening Audit & Verification** (`auditor-pegasus`)
  - *Verification*: Two-Key Gate Key 1 & Key 2 passed. Woven into trunk.

---

### Phase 2: Move-Analyzer & Non-Copyable Payloads
- [x] **Task 2.1: Port Move-Analyzer Test for Unbounded MPMC** (`implementer-kite` & `auditor-pegasus`)
  - *Strand*: `strand/mpmc-move-analyzer`
  - *Action*: Ported Task 19 to create `tests/t_unbounded_mpmc_move_analyzer.nim`.
    - Defined 8-byte non-copyable type (`MovePayload = object; id: int` with `proc =copy {.error.}`).
    - Supported move-only POD types under strict-LCRQ 128-bit DWCAS (`atomics.nim`, `path_c_admit.nim`, `queue.nim`).
    - Verified managed ref payloads (`RefPayload = ref object`) under Path C.
    - Verified wide non-copyable payloads (`WidePayload = object; a, b, c: int`) on `BQueue`.
  - *Verification*: `tests/t_unbounded_mpmc_move_analyzer.nim` 4/4 PASS across entire 4-lane matrix (orc, cpp, arc, refc).
  - *Weave*: Woven into `main` (`dda67b6`).

---

### Phase 3: DEBRA Pin-Claim Invariants & Memory Model Documentation
- [x] **Task 3.1: DEBRA Invariant Headers & Happens-Before Audit** (`architect-horsetail`)
  - *Strand*: `strand/task-debra-invariants-doc`
  - *Lock*: `lock:file:core:queue`
  - *Action*: Ported Tasks 17 / b751bab / 2e266a3 into `src/lockfree/queue.nim`:
    - Inscribed the 6-rule DEBRA Pin-Claim ordering invariant doc-comment on SPMC and MPMC pop.
    - Audited and documented happens-before chains at `queue.nim:1574-1875`.
  - *Verification*: `vine gate` Key 1 & Key 2 green (`d89b358`).
  - *Weave*: Woven into `main` (`39c1914`).

---

### Phase 4: `lockfreequeues` Backwards-Compatibility Shim Layer
- [x] **Task 4.1: Design and Implement Legacy Compatibility Module** (`architect-horsetail`)
  - *Strand*: `strand/task-compat-lockfreequeues`
  - *Action*: Implemented `src/lockfree/compat/lockfreequeues.nim` and `src/lockfreequeues.nim`:
    - Exported legacy bounded type aliases:
      - `Sipsic[N, P, C, T] = BQueue[T, ccSingle, ccSingle, N, P, C]`
      - `Mupsic[N, P, C, T] = BQueue[T, ccMulti, ccSingle, N, P, C]`
      - `Sipmuc[N, P, C, T] = BQueue[T, ccSingle, ccMulti, N, P, C]`
      - `Mupmuc[N, P, C, T] = BQueue[T, ccMulti, ccMulti, N, P, C]`
    - Exported legacy unbounded type aliases:
      - `UnboundedSipsic[T, ST, S] = Queue[T, ccSingle, ccSingle, ST, S]`
      - `UnboundedMupsic[T, ST, S, MaxThreads] = Queue[T, ccMulti, ccSingle, ST, S, MaxThreads]`
      - `UnboundedSipmuc[T, ST, S, MaxThreads] = Queue[T, ccSingle, ccMulti, ST, S, MaxThreads]`
      - `UnboundedMupmuc[T, ST, S, MaxThreads] = Queue[T, ccMulti, ccMulti, ST, S, MaxThreads]`
    - Re-exported legacy constructors: `newSipsicQueue`, `newMupsicQueue`, `newSipmucQueue`, `newMupmucQueue`, etc.
    - Implemented `DEFECT-CRIT-01` (constructor arity overloads) and `DEFECT-WARN-01` (unbounded auto-attachment on `getProducer`/`getConsumer`).
  - *Verification*: `tests/t_compat_lockfreequeues.nim` 7/7 PASS.
  - *Weave*: Woven into `main` (`5cb21cc` / merge commit).

- [x] **Task 4.2: Audit Backwards-Compatibility Parity & Port Legacy Suite** (`migrator-falcon`)
  - *Strand*: `strand/compat-legacy-suite`
  - *Action*: Ported legacy test suite and examples from `lockfreequeues` v4.2.0:
    - Ported all 5 legacy test suites to `tests/compat/`: `t_legacy_sipsic.nim`, `t_legacy_mupsic.nim`, `t_legacy_sipmuc.nim`, `t_legacy_mupmuc.nim`, `t_legacy_unbounded.nim`.
    - Ported all 8 production examples to `examples/compat/`: `audio_buffer.nim`, `event_collector.nim`, `job_scheduler.nim`, `mupmuc.nim`, `mupsic.nim`, `sipmuc.nim`, `sipsic.nim`, `task_fanout.nim`.
    - Added modular compatibility shims in `src/lockfreequeues/` and `src/debra.nim`.
    - Integrated legacy suites into master aggregator `tests/test.nim`.
  - *Verification*: 100% test pass rate across legacy test suites and examples.
  - *Weave*: Woven into `main` (`d715458`).

---

### Phase 5: Concurrency Sanity & Production Release Gate
- [x] **Task 5.1: High-Volume Stress Suite Verification & TSAN/ASAN Matrix** (`stress-lynx` / `auditor-pegasus`)
  - *Strand*: `strand/stress-tsan-matrix`
  - *Action*: Implemented comprehensive 100k unbounded stress test suite covering SPSC, MPSC, SPMC, and MPMC (Strict-LCRQ + NEBR epoch reclamation). Resolved Darwin consumer thread starvation under TSAN via `cpuPause()` and fixed Bound SPSC segment leak via `freeAligned(oldSeg)`.
  - *Verification*:
    - C (`-d:release`): 21/21 OK (0.39s)
    - ThreadSanitizer (`-fsanitize=thread -d:release`): 21/21 OK (3.95s, zero data races)
    - AddressSanitizer (`-fsanitize=address,undefined -d:release`): 21/21 OK (0.77s, zero memory errors)
    - C++ (`cpp -d:release`): 21/21 OK (0.41s)
  - *Weave*: Woven into `main` (`e3a1b79`).

- [ ] **Task 5.2: Full Multi-Backend Matrix & Two-Key Clearance** (`orchestrator-whipbird`)
  - *Action*: Execute `nimble test` (C, C++, ARC, ORC, REFC), `nimble should_fail`, and `nimble benchtests`.
  - *Verification*: 100% exit code 0 across the entire repository.

---

## 5. Dynamic Progress Tracking & Harness Protocol

1. **Orchestrator State Governance**:
   - As each task is dispatched, `@orchestrator-whipbird` sends the contract with `--type task` to the assigned worker.
   - Upon receiving the worker's gate report (`--type reply`), `@orchestrator-whipbird` verifies the gate, runs `vine weave`, and checks the `- [x]` box in this plan.
2. **Emergent Design Addendum Protocol**:
   - If unexpected constraints arise, workers must draft `docs/addenda/addendum_<topic>.md` and request ratification before departing from this plan.
