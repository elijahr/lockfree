---
title: "lockfree/typestates/mpmc_cell"
description: "API reference for lockfree/typestates/mpmc_cell"
---

<p>Co-located cell layout for bounded MPMC/SPMC/MPSC queues.</p>
<p>Each cell holds the per-slot sequence counter alongside its data payload. Cells are aligned to CacheLineBytes so adjacent slots never share a cache line — eliminates false sharing between producer and consumer working on neighbouring positions. See design doc §5 for the layout decision and §10.2 for the recipe this module implements.</p>
<p>The protocol state (the <tt class="docutils literal"><span class="pre"><span class="Identifier">seq</span></span></tt> counter) and the payload data live in the same cell to ensure that a producer or consumer touching a slot incurs at most one cache miss on the cold path. The {.align.} pragma alone is NOT sufficient to keep cells on independent cache lines — see the comment on the explicit <tt class="docutils literal"><span class="pre"><span class="Identifier">pad</span></span></tt> field below.</p>


## Types

### `MPMCCellPayload`

```nim
MPMCCellPayload[T] = object
  seq*: Atomic[uint64]
  data*: T
```

Logical contents of a cell: the protocol counter and the user payload. Kept as a sub-object so <tt class="docutils literal"><span class="pre"><span class="Identifier">sizeof</span><span class="Punctuation">(</span><span class="Identifier">MPMCCellPayload</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span><span class="Punctuation">)</span></span></tt> is well-defined (independent of any outer alignment pragma) and can be used to size the explicit tail padding on the wrapping <tt class="docutils literal"><span class="pre"><span class="Identifier">MPMCCell</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>.

### `MPMCCell`

```nim
MPMCCell[T] = object
  payload*: MPMCCellPayload[T]
  pad*: array[(CacheLineBytes - sizeof(MPMCCellPayload[T]) mod CacheLineBytes) mod
      CacheLineBytes, byte]
```

A cell holding one <tt class="docutils literal"><span class="pre"><span class="Identifier">MPMCCellPayload</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> plus explicit tail padding so <tt class="docutils literal"><span class="pre"><span class="Identifier">sizeof</span><span class="Punctuation">(</span><span class="Identifier">MPMCCell</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span><span class="Punctuation">)</span></span></tt> is a multiple of <tt class="docutils literal"><span class="pre"><span class="Identifier">CacheLineBytes</span></span></tt>. Cache-line alignment is enforced by the <tt class="docutils literal"><span class="pre"><span class="Identifier">cells</span><span class="Operator">*</span></span></tt> field on <tt class="docutils literal"><span class="pre"><span class="Identifier">MPMCCellArrayN</span></span></tt> (Nim's <tt class="docutils literal"><span class="pre"><span class="Punctuation">{</span><span class="Operator">.</span><span class="Identifier">align</span><span class="Operator">.</span><span class="Punctuation">}</span></span></tt> pragma is only valid as a <em>field</em> pragma, not as a <em>type</em> pragma — see &quot;explicit padding rationale&quot; comment below). With the array's first element cache-aligned and each cell sized to a cache-line multiple, every cell sits on its own cache line.

### `MPMCCellArrayN`

```nim
MPMCCellArrayN[N; T] = object
  cells* {.align: 128.}: array[N, MPMCCell[T]]
```

Array of cells indexed by PhysicalSlotN<a class="reference internal" href="#N">N</a>. Owned by a queue facade. The <tt class="docutils literal"><span class="pre"><span class="Punctuation">{</span><span class="Operator">.</span><span class="Identifier">align</span><span class="Operator">.</span><span class="Punctuation">}</span></span></tt> on <tt class="docutils literal"><span class="pre"><span class="Identifier">cells</span></span></tt> aligns the first cell to a cache-line boundary; combined with each cell's tail padding (see <tt class="docutils literal"><span class="pre"><span class="Identifier">MPMCCell</span><span class="Operator">.</span><span class="Identifier">pad</span></span></tt>), every subsequent cell also lands on its own cache line.


## Procedures & Functions

### `init`

```nim
proc init[N: static int; T](a: var MPMCCellArrayN[N, T])
```

Initialize seq<a class="reference internal" href="#i">i</a> = i. Data is left uninitialised (matches StorageN.init semantics — the protocol guarantees readers cannot observe data unless a writer has stored it under a matching seq value first).

### `seqLoad`

```nim
proc seqLoad[N: static int; T](a: var MPMCCellArrayN[N, T];
                               idx: PhysicalSlotN[N]; order: static MemoryOrder): uint64 {.
    inline, notATransition.}
```

### `seqStore`

```nim
proc seqStore[N: static int; T](a: var MPMCCellArrayN[N, T];
                                idx: PhysicalSlotN[N]; val: uint64;
                                order: static MemoryOrder) {.inline,
    notATransition.}
```

### `dataPtr`

```nim
proc dataPtr[N: static int; T](a: var MPMCCellArrayN[N, T];
                               idx: PhysicalSlotN[N]): ptr T {.inline,
    notATransition.}
```

Plain (non-atomic) access to the payload data. Caller MUST hold slot ownership via the seq protocol before reading or writing through this pointer — the seq counter's acquire/release pairing provides the happens-before for any read/write through the returned pointer.

