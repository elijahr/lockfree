# PR: Release v0.1.0 — Umbrella Consolidation, Channel Facade, C ABI, and Performance Hardening

## Overview

This pull request represents the comprehensive release of **`lockfree` v0.1.0**, unifying the `lockfreequeues` and `nim-debra` codebases into a single high-performance lock-free concurrent runtime for Nim.

In addition to consolidating the queue topologies and in-tree NEBR Safe Memory Reclamation (SMR), this PR introduces the high-level **Channel Facade**, the **Cross-Language C ABI**, **Batch Pop Primitives**, **Apple Silicon 128B Cacheline Tuning**, and remediates all 10 findings from the adversarial deep code review with full ThreadSanitizer and AddressSanitizer verification.

---

## Key Highlights & Architectural Additions

### 1. Unified Queue Substrates (`BQueue` & `Queue`)
- **Bounded Ring Buffers (`BQueue`)**: Vyukov-style per-slot sequence counters with zero heap allocations across SPSC, SPMC, MPSC, and MPMC topologies.
- **Unbounded Linked Segments (`Queue`)**: Strict Morrison-Afek LCRQ algorithm for MPMC with Double-Word CAS (DWCAS) and close-CAS-on-empty progress rules.
- **Path-C GC Safety**: Transparently supports `ref T`, `string`, and `seq` across threads via 8-byte `ManagedRef` / `ManagedSlice` tokens, eliminating GC refcount races across `orc`, `arc`, `atomicArc`, and `refc`.

### 2. High-Level Channel Facade (`lockfree/channel`)
- Ergonomic Go/Rust-style `Channel[T]` built over the lock-free queue primitives.
- Split `senders` and `receivers` atomic refcounting (`AUDIT-CHAN-01`): when all senders drop, the channel auto-closes and unblocks receivers; when all receivers drop, sends immediately reject.
- Bounded thread-local MRU ring caches (`AUDIT-CHAN-02`) preventing memory leaks during channel churn.
- Dynamic capacity tiers pruned down to coarse buckets (`64`, `1024`, `65536`) alongside static compile-time generics (`newBoundedChannel[T, N]()`), avoiding compiler template bloat.

### 3. Cross-Language C ABI (`include/lockfree.h` & `lockfree/cabi`)
- First-class C-linkable header and shared library exports for C, C++, Rust, Zig, and Python.
- Dedicated producer/consumer handle structs with bound queue managers (`AUDIT-CABI-01`).
- Thread-safe handle lifecycle management using `allocShared0` / `deallocShared` (`AUDIT-CABI-02`) and destruction guards preventing queue free while active handles remain (`HIGH-CABI-02`).
- Channel close primitives (`lfq_queue_close`, `lfq_queue_is_closed`) with `LFQ_ERR_CLOSED` drain semantics (`MED-CABI-03`).

### 4. Batch Pop Primitives (`popBatch` & `popChunk`)
- High-throughput bulk drain operations on `BQueue` and `Queue`.
- Outer `pinScope` recursion removed for epoch safety (`CRIT-BATCH-01`).
- Atomic counter decrements coalesced into single amortized reservations (`MED-BATCH-04`) and gated behind `lockfreeDisableItemCount` checks (`HIGH-BATCH-02`).

### 5. Systems Optimization
- **ARCH-01 Destructor Walk**: `destroyAndDrain` and RAII destructor cleanup for unconsumed queue elements.
- **Apple Silicon Tuning**: Default `CacheLineBytes = 128` on `arm64` preventing false sharing on Apple M-series chips.
- **`Queue.isEmpty`**: Constant-time atomic inspection primitive.

### 6. Zero-Breakage Backward Compatibility Shims
- `src/lockfree/compat/lockfreequeues.nim` provides 100% drop-in compatibility for `lockfreequeues` v4.2.0 (`Sipsic`, `Mupsic`, `Sipmuc`, `Mupmuc`, `UnboundedSipsic`, etc.) and `debra` (`DebraManager`, `ThreadHandle`, `withPin`).
- Top-level shims `src/lockfreequeues.nim` and `src/debra.nim` ensure zero code changes required for existing adopters.

---

## Verification & Test Matrix

The entire test suite has been modularized and verified across all lanes:

| Suite | Target | Test Count | Result | Wall Clock |
| :--- | :--- | :---: | :---: | :---: |
| **Compile-Fail Tripwires** | `tests/should_fail/runner.nim` | 23 | **PASS** | 0.05s |
| **Core Umbrella Suite** | `nimble test` (`--mm:orc`) | 460 | **PASS** | 0.20s |
| **Channel Facade Suite** | `nimble channel` | 25 | **PASS** | 0.06s |
| **C ABI Verification** | `nimble cabi` (`-d:danger`) | 15 | **PASS** | 0.07s |
| **100k Concurrency Stress** | `nimble testStress` (`arc` / `orc`) | 21 | **PASS** | 0.63s |
| **Clang ThreadSanitizer** | `nimble testTSan` | 500 | **PASS** | **0 Data Races** |
| **Clang AddressSanitizer** | `nimble testASan` | 500 | **PASS** | **0 Leaks / 0 UAF** |

---

## Adversarial Code Review Sign-Off

All 10 findings from `post_implementation_deep_code_review.md` are resolved and verified:
- `CRIT-BATCH-01`: Verified outer `pinScope` removal; no recursive epoch guard pin collisions.
- `HIGH-BATCH-02`: Verified `itemCount.fetchSub` gated behind `when not defined(lockfreeDisableItemCount)`.
- `MED-BATCH-04`: Verified amortized atomic decrement coalescence (`fetchSub(batchClaimed)`).
- `AUDIT-CHAN-01`: Verified split sender/receiver atomic refcounts with auto-close and immediate reject semantics.
- `AUDIT-CHAN-02`: Verified bounded MRU ring cache (32 entries) eliminating TLS memory leaks.
- `AUDIT-CABI-01`: Verified direct binding of `handleManager` and `handleIdx` on handle structs.
- `HIGH-CABI-02`: Verified `lfq_queue_destroy` rejects destruction if active handles remain.
- `AUDIT-CABI-02`: Verified `allocShared0`/`deallocShared` and exception-safe `try-finally` handle accounting.
- `MED-CABI-03`: Verified `lfq_queue_close` and `lfq_queue_is_closed` C ABI exports with `LFQ_ERR_CLOSED`.
- `AUDIT-CABI-03`: Verified elimination of green mirage via 20,000-element seen array & atomic checksum verification.

Signed off unconditionally by `@auditor-pegasus` (Verification Auditor) and `@stress-lynx` (Concurrency Stress Lead).
