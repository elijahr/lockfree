---
title: "lockfree/typestates/slot_seq_n"
description: "API reference for lockfree/typestates/slot_seq_n"
---

<p>Per-slot sequence counters (Vyukov bounded MPMC).</p>
<p>Each slot carries an Atomic<a class="reference internal" href="#uint64">uint64</a> seq, initialised to its index. Producers and consumers compare a globally-monotonic claim cursor against this counter to decide whether the slot is owned by the current generation (claimable), the previous generation's pending consumer (full from the producer's POV), or a future generation (empty from the consumer's POV).</p>
<p>Memory ordering is supplied by the caller at every load/store; the module itself is order-agnostic so call sites can document intent inline. The order parameter is <tt class="docutils literal"><span class="pre"><span class="Keyword">static</span> <span class="Identifier">MemoryOrder</span></span></tt> because <tt class="docutils literal"><span class="pre"><span class="Identifier">debra</span><span class="Operator">/</span><span class="Identifier">atomics</span></span></tt> requires compile-time validation of the load/store ordering domain.</p>
<p>Indexing uses PhysicalSlotN<a class="reference internal" href="#N">N</a> for type-safe slot access (carried over from the old CommittedFlagsN module) — an arbitrary <tt class="docutils literal"><span class="pre"><span class="Identifier">int</span></span></tt> cannot be passed in, eliminating a class of off-by-one indexing bugs.</p>


## Types

### `SlotSeqN`

```nim
SlotSeqN[N] = object
  seqs*: array[N, Atomic[uint64]]
```

<p>Array of per-slot sequence counters. Used by bounded MPMC/SPMC/MPSC queues that adopt the Vyukov per-slot generation protocol.</p>
<p>NOTE (v0.1.0): no PRODUCTION consumer — the bounded Vyukov path uses the co-located MPMCCellPayload.seq in mpmc_cell.nim for cache-locality. SlotSeqN is retained as a tested building block (exercised by tests/t_typestates_import.nim) and a placeholder for a future standalone-seq-array phase; do not adopt it in production without revisiting the false-sharing tradeoff.</p>


## Procedures & Functions

### `init`

```nim
proc init[N: static int](s: var SlotSeqN[N])
```

Initialize seq<a class="reference internal" href="#i">i</a> = i. CRITICAL: NOT zeros (zero-init violates the algorithm; the first producer at pos=0 expects seq<a class="reference internal" href="#0">0</a>=0, seq<a class="reference internal" href="#1">1</a>=1, ...).

### `load`

```nim
proc load[N: static int](s: var SlotSeqN[N]; idx: PhysicalSlotN[N];
                         order: static MemoryOrder): uint64 {.inline,
    notATransition.}
```

### `store`

```nim
proc store[N: static int](s: var SlotSeqN[N]; idx: PhysicalSlotN[N];
                          val: uint64; order: static MemoryOrder) {.inline,
    notATransition.}
```

