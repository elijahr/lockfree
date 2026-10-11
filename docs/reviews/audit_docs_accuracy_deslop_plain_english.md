# Comprehensive Documentation Audit: Accuracy, De-Marketing, De-Slop & ISO Plain English

**Date**: 2026-10-11  
**Auditor**: Caleb Thorne (`auditor-pegasus`), Verification & Adversarial Auditor  
**Directive**: `msg_1791713675_orchestrator-whipbird_3252`  
**Task ID**: `audit-docs-accuracy-deslop-plain-english`  
**Target Repositories**:
- `/Users/eek/Development/lockfree` (Canonical Concurrency Toolkit)
- `/Users/eek/Development/lockfreequeues` (Compatibility Facade)
- `/Users/eek/Development/nim-debra` (Compatibility Facade)

---

## 1. Executive Summary & Audit Mandate

An adversarial audit of the documentation across `lockfree`, `lockfreequeues`, and `nim-debra` reveals a substantial divergence between the **actual technical implementation** and the **published documentation**.

1. **Severe Scope Understatement & Stale Artifacts**: `lockfree` is documented in multiple top-level pages (`docs/index.md`, `mkdocs.yml`, `docs/guide/index.md`) as merely "lock-free queues for Nim" or "queues + SMR". In fact, `lockfree` contains a comprehensive 18-module concurrent data structure and synchronization suite (`Ctrie`, `SkipListMap`, `SkipListSet`, `TreiberStack`, `ChaseLevDeque`, `BroadcastRing`, `RendezvousChannel`, `TaskPool`, `StreamBuffer`, `Channel[T]`, `async_bridge`, `cabi`, and 128-bit hardware atomics). Critically, `docs/index.md` still bears the title `# lockfreequeues` and instructs users to run `nimble install lockfreequeues`!
2. **Missing Modern API Reference**: `mkdocs.yml` and `docs/api/` completely lack API documentation pages for 12 modern production modules (`channel`, `ctrie`, `set`, `skiplist`, `stack`, `deque`, `broadcast`, `rendezvous`, `taskpool`, `streambuffer`, `async_bridge`, `cabi`).
3. **Marketing Buzzwords & Superlatives**: Prominent copy contains ungrounded claims, hyperbolic superlatives ("Ultra-high-performance", "sustains 18,209 ops/ms — 10.6x faster than Nim's standard library Channel", "crash-proof", "leak-free", "zero-overhead", "safety tripwires").
4. **AI Slop & Stylistic Tells**: Prose exhibits AI hallmarks including metaphor-loaded verbs ("load-bearing"), intensifier adverbs ("genuinely", "truly"), punchline endings ("a production incident waiting to happen"), tricolons, conversational throat-clearing ("Welcome to the definitive user guide..."), and severe em-dash saturation (375 em-dashes across the documentation tree).
5. **Phantom Reservations (`debra_plus.nim` / Brown 2017 / Q-FAITHFUL)**: Multiple documents retain speculative future reservations for `debra_plus.nim`, confusing historical attribution disclaimers regarding Brown 2017, and internal review tags ("Q-FAITHFUL") that have no place in user-facing specification documentation.

This audit provides an itemized, per-file analysis and concrete, specification-grade declarative rewrite recommendations conforming to ISO plain standard English.

---

## 2. Dimension 1: Project Identity & Scope Correction

### 2.1 The Actual Scope of `lockfree`
The implementation in `src/lockfree/` provides a comprehensive lock-free concurrent programming toolkit consisting of 18 distinct architectural subsystems:

| Subsystem / Module | Implementation File | Architectural Role | Current Docs Status |
| :--- | :--- | :--- | :--- |
| **Bounded Queues** | `bqueue.nim` | Dmitry Vyukov per-slot sequence counter ring buffer (SPSC, SPMC, MPSC, MPMC) | Documented |
| **Unbounded Queues** | `queue.nim` | Morrison & Afek strict-LCRQ (DWCAS MPMC) and committed-flag segment chains | Documented |
| **CSP Channels** | `channel.nim` | High-level channel facade with sender/receiver refcounts, bounded caching, auto-close | **Missing from API docs** |
| **Concurrent Map** | `ctrie.nim` | Non-blocking Concurrent Hash Array Mapped Trie (HAMT) with $O(1)$ snapshots | **Missing from API docs** |
| **Concurrent Set** | `set.nim` | Non-blocking set built on lock-free skiplist substrate | **Missing from API docs** |
| **SkipList** | `skiplist.nim` | Fraser & Herlihy lock-free skiplist with Harris logical deletion marking | **Missing from API docs** |
| **Treiber Stack** | `stack.nim` | LIFO Treiber stack with Hendler et al. Elimination-Backoff Array | **Missing from API docs** |
| **Work-Stealing Deque** | `deque.nim` | Chase-Lev dynamic circular work-stealing deque with bulk steal | **Missing from API docs** |
| **Broadcast Ring** | `broadcast.nim` | Multicast fan-out ring buffer with dynamic subscriber cursors | **Missing from API docs** |
| **Rendezvous Channel** | `rendezvous.nim` | Synchronous zero-buffer dual queue with native OS futex suspension | **Missing from API docs** |
| **Task Scheduler** | `taskpool.nim` | Work-stealing task pool coordinating worker deques and parallel execution | **Missing from API docs** |
| **Streaming Buffer** | `streambuffer.nim` | Cacheline-isolated circular byte stream buffer | **Missing from API docs** |
| **Async Bridge** | `async_bridge.nim` | Non-blocking adapter for `std/asyncdispatch` and `chronos` | **Missing from API docs** |
| **C ABI** | `cabi.nim` | Foreign function interface exports and C headers (`include/lockfree.h`) | **Missing from API docs** |
| **Hardware Atomics** | `atomics.nim` | C11/C++20 atomics, 128-bit DWCAS (`cmpxchg16b`/`casp`), exponential backoff | Partially documented |
| **Memory Reclamation** | `smr/nebr.nim` | Neutralization-Enhanced Bounded Epoch Reclamation | Documented |
| **Path-C GC Safety** | `managed_ref.nim`, `managed_slice.nim` | Token-based GC isolation for `ref T`, `string`, and `seq[T]` payloads | Documented |
| **Typestate Lifecycle**| `endpoint.nim`, `typestates.nim` | Compile-time affine thread-binding verification (`Unbound → Bound → Closed`) | Documented |

### 2.2 Stale `lockfreequeues` Copy-Paste Artifacts
The following files still contain outdated names, descriptions, or installation instructions from the pre-v5 `lockfreequeues` repository:

1. **`docs/index.md`**:
   - **Line 1**: `# lockfreequeues` $\rightarrow$ Must be `# lockfree`.
   - **Line 3**: `Lock-free queues for Nim...` $\rightarrow$ Must reflect the entire concurrency toolkit.
   - **Line 25**: `...via [nim-debra](https://github.com/elijahr/nim-debra)...` $\rightarrow$ In-tree `lockfree/smr/nebr`.
   - **Line 58**: `All atomics route through debra/atomics...` $\rightarrow$ All atomics route through `lockfree/atomics`.
   - **Line 66**: `nimble install lockfreequeues` $\rightarrow$ `nimble install lockfree`.
   - **Lines 74, 92**: `import lockfreequeues` $\rightarrow$ `import lockfree`.
2. **`docs/guide/index.md`**:
   - **Lines 69-75**: Explicitly states: *"The umbrella is queues + SMR; it is not a general-purpose lock-free container library. Hashes, sets, skiplists, and channels are out of scope... `std/asyncdispatch` is not adapted; `chronos` is the only supported async runtime."* $\rightarrow$ **COMPLETELY INACCURATE**. The codebase contains production implementations of Ctrie, Set, SkipList, Channel, and AsyncBridge (supporting both `std/asyncdispatch` and `chronos`). This entire section must be rewritten.
3. **`mkdocs.yml`**:
   - **Line 2**: `site_description: Lock-free queues for Nim` $\rightarrow$ `site_description: Lock-free concurrency primitives and data structures for Nim`.
   - **Lines 115-136**: Navigation tree omits `channel`, `ctrie`, `set`, `skiplist`, `stack`, `deque`, `broadcast`, `rendezvous`, `taskpool`, `streambuffer`, `async_bridge`, and `cabi`.
4. **`docs/guide/safety-model.md`**:
   - **Line 3**: `This document covers the thread-safety contract of lockfreequeues...` $\rightarrow$ `lockfree`.
   - **Line 12**: `By default, lockfreequeues requires queue item types to be lock-free.` $\rightarrow$ `lockfree`.
   - **Line 15**: `import lockfreequeues` $\rightarrow$ `import lockfree`.
   - **Lines 26-30**: Contradictory code snippet claiming `ref object` fails compilation on `arc`/`orc`, immediately preceding a section explaining Path-C admission for `ref T`.
5. **`docs/guide/performance-tuning.md`**:
   - **Line 3**: `...getting the most out of lockfreequeues...` $\rightarrow$ `lockfree`.
   - **Line 32**: `import lockfreequeues` $\rightarrow$ `import lockfree`.
   - **Line 56**: `lockfreequeues is NUMA-naïve.` $\rightarrow$ `lockfree is NUMA-naïve.`.
6. **`docs/guide/bounded-vs-unbounded.md`**:
   - **Line 37**: `import lockfreequeues` $\rightarrow$ `import lockfree`.

### 2.3 Compatibility Facade Framing in Downstream Repositories
- **`lockfreequeues/README.md`**: Cleanly frames the package as a backwards-compatibility wrapper. However, `lockfreequeues/docs/index.md` still retains legacy queue tutorials. `lockfreequeues/docs/` should either be deleted or reduced to a single landing page redirecting to canonical `lockfree` documentation.
- **`nim-debra/README.md`**: Cleanly frames the package as a backwards-compatibility wrapper. `nim-debra/docs/` was already removed in commit `d4d782a`.

---

## 3. Dimension 2: De-Marketing & Superlative Elimination

Documentation must provide objective, empirical, and reproducible descriptions. Marketing adjectives, uncalibrated performance claims, and speculative hype degrade technical credibility.

### 2.1 Inventory of Marketing Language

| File | Line | Current Marketing / Superlative Text | Defect Rationale | Proposed Factual ISO Replacement |
| :--- | :--- | :--- | :--- | :--- |
| `README.md` | 10 | `**Ultra-high-performance lock-free queues...**` | Superlative buzzword. | `**Lock-free concurrent data structures, communication channels, and memory reclamation (NEBR) for Nim.**` |
| `README.md` | 15 | `Under heavy multi-producer multi-consumer contention, lockfree sustains **18,209 ops/ms** — **10.6x faster than Nim's standard library Channel**.` | Marketing claim in hero section without benchmark environment, hardware, or methodology. | Move throughput figures to `benchmarks.md` with explicit hardware specifications (CPU, cores, frequency, OS). In README, state: `Benchmarks comparing lockfree against std/syncio and external libraries are documented in [benchmarks.md](docs/benchmarks.md).` |
| `README.md` | 27 | `...for zero-overhead integration with C, C++, Rust, Zig, and Python.` | "Zero-overhead" is marketing hype. | `...for direct C-ABI invocation without intermediate runtime wrappers.` |
| `README.md` | 28 | `...with 23 negative compile-fail safety tripwires.` | Sensationalist phrasing ("safety tripwires"). | `...with 23 negative compile-time rejection tests.` |
| `docs/guides/user_guide.md` | 3 | `Whether you are building an ultra-low latency financial order router, a high-throughput network service, a real-time audio pipeline, or a multi-threaded game engine in Nim...` | Marketing persona pitch. | Omit conversational setup. Begin directly: `The lockfree library provides non-blocking concurrent data structures for multithreaded Nim programs.` |
| `docs/guides/user_guide.md` | 3 | `...designed for maximum scalability, deterministic latency, and zero mutual-exclusion overhead.` | Unquantified superlatives ("maximum", "deterministic"). | `...designed without locks or OS-level mutual exclusion.` |
| `docs/guides/user_guide.md` | 5 | `...bridges everyday, colloquial data structure names... to their high-performance lock-free implementations...` | Fluff ("everyday, colloquial", "high-performance"). | `This guide maps standard abstract data type interfaces to their non-blocking implementations in lockfree.` |
| `docs/guides/user_guide.md` | 6 | `...keep your multi-threaded systems leak-free and crash-proof.` | Hyperbolic absolute claim ("crash-proof"). | `...provide memory reclamation and thread-safe reference handling across execution threads.` |
| `docs/designs/design_streambuffer.md` | 52 | `...circular byte stream buffer designed specifically for zero-overhead streaming I/O.` | "Zero-overhead" buzzword. | `...circular byte stream buffer for direct memory transfer without intermediate copying.` |
| `docs/designs/design_async_bridge.md` | 53 | `...provides a zero-overhead, memory-safe, lock-free async adapter layer...` | Buzzword stacking. | `...provides a non-blocking bridge allowing asynchronous coroutines to dispatch to concurrent queues.` |

---

## 4. Dimension 3: De-Slop & Stylistic Pattern Removal

### 4.1 Metaphor-Loaded Verbs & Technical Jargon Slop
- **"load-bearing"**:
  - `docs/api/bqueue.md:61`: `The parameter order is load-bearing: T, ccProd, ccCons, N, P, C.` $\rightarrow$ Rewrite: `The generic parameter sequence is fixed: T, ccProd, ccCons, N, P, C.`
  - `docs/api/queue.md:66`: `The parameter order is load-bearing: T, ccProd, ccCons, ST, S, MaxThreads.` $\rightarrow$ Rewrite: `The generic parameter sequence is fixed: T, ccProd, ccCons, ST, S, MaxThreads.`
  - `docs/legacy/nim-debra/guide/atomics.md:279`: `Comparand alignment (load-bearing).` $\rightarrow$ Rewrite: `Comparand alignment requirement.`

### 4.2 Intensifier Adverbs
- **"genuinely"**:
  - `docs/guide/managed-ref.md:91`: `...types that genuinely cannot form a cycle through their ref fields.` $\rightarrow$ Rewrite: `...types that cannot form reference cycles.`
  - `docs/guide/bounded-vs-unbounded.md:256`: `This is appropriate when you genuinely cannot drop and the producer can...` $\rightarrow$ Rewrite: `This is appropriate when items cannot be dropped and the producer can...`
  - `docs/legacy/nim-debra/safety-model.md:38`: `If you genuinely need a non-lock-free atomic for some reason...` $\rightarrow$ Rewrite: `If a non-lock-free atomic is required...`

### 4.3 Conversational Throat-Clearing & Punchline Endings
- `docs/guide/getting-started.md:3`: `Your first five minutes with lockfree: install, write a bounded SPSC program, write an unbounded MPMC program, learn when to reach for the standalone reclaimer.` $\rightarrow$ Rewrite: `This guide covers installation, bounded SPSC initialization, unbounded MPMC execution, and memory reclaimer configuration.`
- `docs/guide/core-concepts.md:7`: `Read this once, then return to the topic-specific guides as needed.` $\rightarrow$ Delete.
- `docs/guide/bounded-vs-unbounded.md:50`: `...or a production incident waiting to happen...` $\rightarrow$ Rewrite: `...or unbounded memory growth if the consumer stalls.`

### 4.4 Em-Dash Saturation Analysis (375 Instances)
A grep across `docs/` and `README.md` identified **375 em-dashes (`—`)**. Em-dashes in technical prose frequently mask run-on sentences, parenthetical interruptions, and casual AI conversational rhythms.
- **Rule 1 (Definition)**: Where an em-dash separates a term from its definition, use a colon or parentheses.
  - *Before*: `nebr — Neutralizable Epoch-Based Reclamation`
  - *After*: `nebr: Neutralizable Epoch-Based Reclamation`
- **Rule 2 (Parenthetical clause)**: Where an em-dash introduces explanatory detail, use commas, parentheses, or separate sentences.
  - *Before*: `Memory cost is exactly N * sizeof(T) plus a few cache-line-aligned counters — no allocation happens during operation.`
  - *After*: `Memory cost is exactly N * sizeof(T) plus cache-line-aligned counters. No dynamic allocation occurs during queue operations.`
- **Rule 3 (Itemization)**: Where an em-dash precedes an explanation in a bulleted list, use a colon.
  - *Before*: `- Bounded queues (BQueue) — ring buffers with compile-time capacity`
  - *After*: `- Bounded queues (`BQueue`): ring buffers with compile-time capacity`

---

## 5. Dimension 4: ISO Plain Standard English Guidelines

Technical documentation must adhere to specification-grade English:
1. **Direct Declarative Statements**: State what the code does, what invariants hold, and what preconditions are required. Avoid narrative journeys.
2. **Subject-Verb-Object Structure**: Place the subject first. Avoid passive copula evasions ("is designed to allow" $\rightarrow$ "allows").
3. **Explicit Quantifiers and Units**: Replace vague descriptors ("fast", "small", "massive") with exact numbers, algorithmic bounds ($O(1)$, $O(\log N)$), or cacheline sizing (64 bytes).
4. **No Conversational Direct Address**: Minimize "you", "we", and rhetorical questions. Frame sentences in terms of the system, module, caller, or thread.

### Before & After Rewrites for Primary Documents

#### A. `lockfree/README.md` (Hero & Overview)
- **Before**:
  ```markdown
  # lockfree

  > **Ultra-high-performance lock-free queues, typestate-safe channels, and epoch-based memory reclamation (NEBR) for Nim, with native C ABI bindings.**  
  > *Consolidated successor to `lockfreequeues` and `nim-debra`.*

  `lockfree` delivers wait-free and lock-free concurrent data structures across the full single/multi-producer and single/multi-consumer matrix. Bounded queues operate as zero-allocation ring buffers; unbounded queues use linked segments with in-tree epoch-based memory reclamation (NEBR / DEBRA+).

  Under heavy multi-producer multi-consumer contention, `lockfree` sustains **18,209 ops/ms** — **10.6x faster than Nim's standard library `Channel`**.
  ```
- **After (ISO Plain English)**:
  ```markdown
  # lockfree

  Lock-free concurrent data structures, communication channels, and safe memory reclamation for Nim.

  The `lockfree` library provides non-blocking concurrent programming primitives across single-producer, multi-producer, single-consumer, and multi-consumer topologies. It consolidates the implementations previously published under `lockfreequeues` and `nim-debra`.

  The package provides:
  - Bounded ring buffers (`BQueue`) with static memory allocation.
  - Unbounded dynamic-segment queues (`Queue`) using Morrison-Afek strict-LCRQ.
  - Bidirectional communication channels (`Channel`) with automatic thread registration.
  - Associative maps (`Ctrie`, `SkipListMap`) and sets (`SkipListSet`).
  - LIFO stacks (`TreiberStack`) with elimination backoff and work-stealing deques (`ChaseLevDeque`).
  - Multicast rings (`BroadcastRing`) and synchronous dual queues (`RendezvousChannel`).
  - Safe memory reclamation via Neutralization-Enhanced Bounded Epoch Reclamation (`lockfree/smr/nebr`).
  - Foreign function interface exports via C ABI headers (`include/lockfree.h`).
  ```

#### B. `docs/index.md` (Main Documentation Landing Page)
- **Before**:
  ```markdown
  # lockfreequeues

  Lock-free queues for Nim, implemented as ring buffers (bounded) and linked segments (unbounded).

  ## Overview

  v5 exposes two unified, cardinality-parameterized queue types — [`BQueue`](api/bqueue.md) (bounded) and [`Queue`](api/queue.md) (unbounded)...
  ```
- **After (ISO Plain English)**:
  ```markdown
  # lockfree

  Concurrent data structures and synchronization primitives for Nim.

  ## Overview

  The `lockfree` library provides production-grade non-blocking algorithms for multithreaded systems. All primitives avoid mutual-exclusion locks, providing either lock-free or wait-free progress guarantees.

  ### Core Modules

  - **Queues**: Bounded static ring buffers (`BQueue`) and unbounded dynamic queues (`Queue`).
  - **Channels**: Asynchronous buffered channels (`Channel`) and synchronous zero-capacity channels (`RendezvousChannel`).
  - **Containers**: Concurrent hash tries (`Ctrie`), ordered maps (`SkipListMap`), and concurrent sets (`SkipListSet`).
  - **Work Scheduling**: Treiber stacks (`TreiberStack`), Chase-Lev deques (`ChaseLevDeque`), and task pools (`TaskPool`).
  - **Streaming**: Multicast fan-out rings (`BroadcastRing`) and circular byte buffers (`StreamBuffer`).
  - **Memory Management**: Epoch-based memory reclamation (`nebr`) and GC token lowering (`ManagedRef`, `ManagedSlice`).
  - **Interoperability**: C ABI shared library exports (`cabi.nim`) and C headers (`include/lockfree.h`).
  ```

---

## 6. Dimension 5: `debra_plus` Elimination & Citation Rectification

Mandate Item 5 requires confirming that all mentions of `debra_plus.nim` name reservation, Brown 2017/Q-FAITHFUL citations, and theoretical reservation notes are cataloged for removal.

### 6.1 Complete Itemized Deletion Inventory

```
====================================================================================================
FILE PATH                               LINES       TEXT TO REMOVE / REVISE
====================================================================================================
docs/guide/smr/nebr.md                  16-17       "; the name slot debra_plus.nim is reserved for a 
                                                    future faithful Brown 2015 port."
----------------------------------------------------------------------------------------------------
docs/guide/smr/nebr.md                  19-24       "> **Not to be confused with Brown 2017 NBR.** ... 
                                                    citation has been corrected here per Q-FAITHFUL."
----------------------------------------------------------------------------------------------------
docs/guide/smr/nebr.md                  251-253     "A faithful Brown 2015 port — debra_plus.nim — is 
                                                    held as future work. The name slot is reserved."
----------------------------------------------------------------------------------------------------
docs/guide/index.md                     71-74       "A faithful Brown 2015 DEBRA+ port (with sigsetjmp 
                                                    recovery and hazard pointers) is reserved as future 
                                                    work — the name debra_plus.nim is held for it; 
                                                    see the nebr deviation table..."
----------------------------------------------------------------------------------------------------
docs/migrations/from-nim-debra.md       82-105      Section: "## Attribution change (Brown 2015 DEBRA+, 
                                                    not Brown 2017 NBR)" -> Replace with a simple 
                                                    factual bibliography note citing Brown (PODC 2015).
----------------------------------------------------------------------------------------------------
docs/migrations/from-nim-debra.md       111-123     Entire section: "## The debra_plus.nim name slot"
                                                    (Delete all 13 lines).
----------------------------------------------------------------------------------------------------
docs/guide/concepts/smr.md              40-41       "| **NBR** (Neutralization-Based Reclamation, Brown 
                                                    2017) | A different algorithm from DEBRA+; ..."
                                                    (Remove table row).
----------------------------------------------------------------------------------------------------
docs/legacy/nim-debra/index.md          116         "- [DEBRA+: Efficient Memory Reclamation (Brown, 
                                                    2017)](https://arxiv.org/abs/1712.01044)..."
                                                    (Update citation to Brown 2015 PODC).
====================================================================================================
```

### 6.2 Rationale
1. **Speculative Future Reservations Are Anti-Patterns**: Documenting an unwritten file (`debra_plus.nim`) and holding "name slots" confuses users looking for existing APIs. Documentation describes software as implemented.
2. **Review Notes in Production Docs**: Mentions of internal review tokens ("per Q-FAITHFUL", "the R6 attribution") reflect review trajectory rather than technical specifications.
3. **Brown 2017 Disclaimers**: Upstream `nim-debra` had an incorrect citation to Brown's 2017 NBR paper. Rather than carrying paragraphs of meta-commentary apologizing for the earlier citation, documentation should directly and simply cite the actual source: Trevor Brown, *Reclaiming Memory for Lock-Free Data Structures: There has to be a Better Way* (PODC 2015).

---

## 7. Actionable Per-File Remediation Matrix

The table below catalogs every documentation file requiring remediation across the three repositories:

| Repository | File Path | Defect Classes Identified | Required Action |
| :--- | :--- | :--- | :--- |
| `lockfree` | `README.md` | Stale scope (omits modern primitives), marketing buzzwords, hero benchmark claims, em-dash saturation. | **REWRITE**: Update hero, expand feature matrix to all 18 modules, remove hero ops/ms claim, de-slop prose. |
| `lockfree` | `docs/index.md` | Wrong title (`# lockfreequeues`), wrong package name, outdated scope, stale install command. | **REWRITE**: Replace with canonical `lockfree` specification and modern subsystem catalog. |
| `lockfree` | `mkdocs.yml` | Stale site description ("Lock-free queues"), missing 12 modern API navigation entries. | **EDIT**: Update site description, add API reference entries for all implemented data structures. |
| `lockfree` | `docs/guide/index.md` | False out-of-scope declarations (channels, maps, sets), `debra_plus` reservation, em-dashes. | **REWRITE**: Describe entire toolkit, eliminate out-of-scope claims, eliminate `debra_plus` slot note. |
| `lockfree` | `docs/guides/user_guide.md` | Conversational pitch opening, marketing buzzwords ("crash-proof", "ultra-low latency"), em-dashes. | **EDIT**: Remove marketing intro, convert comparative descriptions to ISO declarative prose. |
| `lockfree` | `docs/api/index.md` | Describes only `BQueue` and `Queue`, omits modern primitives. | **REWRITE**: Expand index to cover all 18 exported modules. |
| `lockfree` | `docs/api/bqueue.md` | Metaphor-loaded verb ("load-bearing parameter order"). | **EDIT**: Replace with "fixed parameter sequence". |
| `lockfree` | `docs/api/queue.md` | Metaphor-loaded verb ("load-bearing parameter order"). | **EDIT**: Replace with "fixed parameter sequence". |
| `lockfree` | `docs/guide/smr/nebr.md` | `debra_plus` reservation, Q-FAITHFUL review note, speculative future port text, em-dashes. | **EDIT**: Remove lines 16-17, 19-24, 251-253; simplify attribution to PODC 2015. |
| `lockfree` | `docs/guide/concepts/smr.md` | Brown 2017 citation and theoretical discussion. | **EDIT**: Prune table row 40 and theoretical commentary. |
| `lockfree` | `docs/guide/safety-model.md` | Mentions `lockfreequeues`, contradiction regarding `ref object` support. | **EDIT**: Rename package, update code example to reflect Path-C support. |
| `lockfree` | `docs/guide/performance-tuning.md` | Mentions `lockfreequeues`, `import lockfreequeues`. | **EDIT**: Replace package name and imports with `lockfree`. |
| `lockfree` | `docs/guide/bounded-vs-unbounded.md` | `import lockfreequeues`, punchline ending ("incident waiting to happen"). | **EDIT**: Update import, replace punchline with declarative failure mode. |
| `lockfree` | `docs/guide/managed-ref.md` | Intensifier adverb ("genuinely cannot form a cycle"). | **EDIT**: Strike "genuinely". |
| `lockfree` | `docs/migrations/from-nim-debra.md` | `debra_plus.nim` name slot reservation, conversational attribution section. | **EDIT**: Delete lines 111-123, simplify attribution section. |
| `lockfree` | `docs/legacy/nim-debra/index.md` | Outdated Brown 2017 citation. | **EDIT**: Update citation to Brown 2015 PODC. |
| `lockfreequeues` | `docs/index.md` | Retains full queue documentation rather than acting as a lean redirect. | **REWRITE**: Replace with compact facade landing page directing users to `lockfree`. |
| `lockfreequeues` | `README.md` | Contains slight marketing phrasing ("ultra-high-performance"). | **EDIT**: Align wording with ISO plain standard English. |
| `nim-debra` | `README.md` | Contains slight marketing phrasing ("zero-overhead"). | **EDIT**: Align wording with ISO plain standard English. |

---

## 8. Conclusion & Implementation Recommendations

1. **Phase 1: Project Identity & Critical Fixes**:
   - Correct `docs/index.md`, `mkdocs.yml`, and `README.md` to establish `lockfree` as the comprehensive lock-free concurrency toolkit.
   - Strike `# lockfreequeues` from `docs/index.md` and update installation commands.
2. **Phase 2: Eliminate Speculative & Review Notes**:
   - Prune all mentions of `debra_plus.nim` reservation, Q-FAITHFUL review notes, and Brown 2017 disclaimers across `docs/guide/smr/nebr.md`, `docs/guide/index.md`, and `docs/migrations/from-nim-debra.md`.
3. **Phase 3: De-Marketing & De-Slop Pass**:
   - Remove hype, superlatives, and intensifier adverbs across `README.md`, `user_guide.md`, and guide pages.
   - Clean up em-dash saturation and conversational throat-clearing.
4. **Phase 4: Modern API Reference Generation**:
   - Create documentation stubs and reference pages in `docs/api/` for `channel`, `ctrie`, `set`, `skiplist`, `stack`, `deque`, `broadcast`, `rendezvous`, `taskpool`, `streambuffer`, `async_bridge`, and `cabi`.
