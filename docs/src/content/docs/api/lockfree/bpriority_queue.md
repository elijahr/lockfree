---
title: "lockfree/bpriority_queue"
description: "API reference for lockfree/bpriority_queue"
---

=========================================================================== Concurrency Topology: SPSC, MPSC, SPMC, MPMC Bounded Priority Queue (<tt class="docutils literal"><span class="pre"><span class="Identifier">BPriorityQueue</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">,</span> <span class="Identifier">Cap</span><span class="Punctuation">,</span> <span class="Identifier">ccProd</span><span class="Punctuation">,</span> <span class="Identifier">ccCons</span><span class="Punctuation">]</span></span></tt>)<hr />
<p>A preallocated, zero-SMR, zero-hot-path-heap-allocation bounded concurrent min-priority queue backed by a contiguous binary min-heap of capacity <tt class="docutils literal"><span class="pre"><span class="Identifier">Cap</span></span></tt> and a preallocated flat-combining publication array.</p>
<p>Key properties:</p>
<ul class="simple"><li><strong>Preallocated Contiguous Binary Heap</strong>: All <tt class="docutils literal"><span class="pre"><span class="Identifier">Cap</span></span></tt> heap entries and combiner publication slots are allocated inside <tt class="docutils literal"><span class="pre"><span class="Identifier">BPriorityQueueCore</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">,</span> <span class="Identifier">Cap</span><span class="Punctuation">]</span></span></tt> at construction time (<tt class="docutils literal"><span class="pre"><span class="Identifier">initBPriorityQueue</span></span></tt>).</li>
<li><strong>Zero Hot-Path Heap Allocation &amp; Zero SMR</strong>: <tt class="docutils literal"><span class="pre"><span class="Identifier">tryPush</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">push</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">tryPopMin</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">popMin</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">peekMin</span></span></tt>, and <tt class="docutils literal"><span class="pre"><span class="Identifier">clear</span></span></tt> perform zero heap allocations and never touch NEBR/DEBRA epoch reclamation.</li>
<li><strong>Strict FIFO Tie-Breaking</strong>: Equal priorities are ordered deterministically by a monotonically increasing 64-bit <tt class="docutils literal"><span class="pre"><span class="Identifier">seqId</span></span></tt>, preserving insertion order.</li>
<li><strong>ARC/ORC Memory Safety</strong>: Popped and cleared heap slots immediately invoke <tt class="docutils literal"><span class="pre"><span class="Identifier">reset</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt>, releasing managed payloads (<tt class="docutils literal"><span class="pre"><span class="Identifier">string</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">seq</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Keyword">ref</span></span></tt>) without leak or TSan data races.</li>
</ul>


## Types

### `BHeapEntry`

```nim
BHeapEntry[T] = object
  key*: T
  seqId*: uint64
```

### `BPriorityQueueCore`

```nim
BPriorityQueueCore[T; Cap] = object
  combinerLock* {.align: 128.}: Atomic[uint64]
  count* {.align: 128.}: Atomic[int]
  activePubSlots* {.align: 128.}: Atomic[int]
  rc* {.align: 128.}: Atomic[int]
  nextSeqId*: uint64
  heapSize*: int
  effCap*: int
  pubSlots*: array[BPQMaxCombinerSlots, BPQPubSlot[T]]
  heap*: array[Cap, BHeapEntry[T]]
```

### `BPriorityQueue`

```nim
BPriorityQueue[T; Cap; ccProd; ccCons] = object
  core*: ptr BPriorityQueueCore[T, Cap]
```

### `BoundedPriorityQueue`

```nim
BoundedPriorityQueue[T; Cap; ccProd; ccCons] = BPriorityQueue[T, Cap, ccProd,
    ccCons]
```

### `SpscBoundedPriorityQueue`

```nim
SpscBoundedPriorityQueue[T; Cap] = BPriorityQueue[T, Cap, ccSingle, ccSingle]
```

### `MpscBoundedPriorityQueue`

```nim
MpscBoundedPriorityQueue[T; Cap] = BPriorityQueue[T, Cap, ccMulti, ccSingle]
```

### `SpmcBoundedPriorityQueue`

```nim
SpmcBoundedPriorityQueue[T; Cap] = BPriorityQueue[T, Cap, ccSingle, ccMulti]
```

### `MpmcBoundedPriorityQueue`

```nim
MpmcBoundedPriorityQueue[T; Cap] = BPriorityQueue[T, Cap, ccMulti, ccMulti]
```

### `SpscBPriorityQueue`

```nim
SpscBPriorityQueue[T; Cap] = BPriorityQueue[T, Cap, ccSingle, ccSingle]
```

### `MpscBPriorityQueue`

```nim
MpscBPriorityQueue[T; Cap] = BPriorityQueue[T, Cap, ccMulti, ccSingle]
```

### `SpmcBPriorityQueue`

```nim
SpmcBPriorityQueue[T; Cap] = BPriorityQueue[T, Cap, ccSingle, ccMulti]
```

### `MpmcBPriorityQueue`

```nim
MpmcBPriorityQueue[T; Cap] = BPriorityQueue[T, Cap, ccMulti, ccMulti]
```


## Constants

### `BPQMaxCombinerSlots`

```nim
BPQMaxCombinerSlots = 64
```

### `BPQMaxCombineRounds`

```nim
BPQMaxCombineRounds = 8
```


## Procedures & Functions

### ``=destroy``

```nim
proc `=destroy`[T; Cap: static int; ccProd: static PinScopeCardinality;
                ccCons: static PinScopeCardinality](
    self: var BPriorityQueue[T, Cap, ccProd, ccCons]) {.raises: [].}
```

### ``=copy``

```nim
proc `=copy`[T; Cap: static int; ccProd: static PinScopeCardinality;
             ccCons: static PinScopeCardinality](
    dest: var BPriorityQueue[T, Cap, ccProd, ccCons];
    src: BPriorityQueue[T, Cap, ccProd, ccCons])
```

### ``=sink``

```nim
proc `=sink`[T; Cap: static int; ccProd: static PinScopeCardinality;
             ccCons: static PinScopeCardinality](
    dest: var BPriorityQueue[T, Cap, ccProd, ccCons];
    src: BPriorityQueue[T, Cap, ccProd, ccCons])
```

### `initBPriorityQueue`

```nim
proc initBPriorityQueue[T; Cap: static int;
                        ccProd: static PinScopeCardinality = ccMulti;
                        ccCons: static PinScopeCardinality = ccMulti](): BPriorityQueue[
    T, Cap, ccProd, ccCons]
```

Initializes a preallocated bounded priority queue with capacity <tt class="docutils literal"><span class="pre"><span class="Identifier">Cap</span></span></tt>.

### `newBPriorityQueue`

```nim
proc newBPriorityQueue[T; Cap: static int;
                       ccProd: static PinScopeCardinality = ccMulti;
                       ccCons: static PinScopeCardinality = ccMulti](): BPriorityQueue[
    T, Cap, ccProd, ccCons] {.inline.}
```

### `initBoundedPriorityQueue`

```nim
proc initBoundedPriorityQueue[T; Cap: static int;
                              ccProd: static PinScopeCardinality = ccMulti;
                              ccCons: static PinScopeCardinality = ccMulti](): BoundedPriorityQueue[
    T, Cap, ccProd, ccCons] {.inline.}
```

### `newBoundedPriorityQueue`

```nim
proc newBoundedPriorityQueue[T; Cap: static int;
                             ccProd: static PinScopeCardinality = ccMulti;
                             ccCons: static PinScopeCardinality = ccMulti](): BoundedPriorityQueue[
    T, Cap, ccProd, ccCons] {.inline.}
```

### `initSpscBPriorityQueue`

```nim
proc initSpscBPriorityQueue[T; Cap: static int](): SpscBPriorityQueue[T, Cap] {.
    inline.}
```

### `initMpscBPriorityQueue`

```nim
proc initMpscBPriorityQueue[T; Cap: static int](): MpscBPriorityQueue[T, Cap] {.
    inline.}
```

### `initSpmcBPriorityQueue`

```nim
proc initSpmcBPriorityQueue[T; Cap: static int](): SpmcBPriorityQueue[T, Cap] {.
    inline.}
```

### `initMpmcBPriorityQueue`

```nim
proc initMpmcBPriorityQueue[T; Cap: static int](): MpmcBPriorityQueue[T, Cap] {.
    inline.}
```

### `newSpscBPriorityQueue`

```nim
proc newSpscBPriorityQueue[T; Cap: static int](): SpscBPriorityQueue[T, Cap] {.
    inline.}
```

### `newMpscBPriorityQueue`

```nim
proc newMpscBPriorityQueue[T; Cap: static int](): MpscBPriorityQueue[T, Cap] {.
    inline.}
```

### `newSpmcBPriorityQueue`

```nim
proc newSpmcBPriorityQueue[T; Cap: static int](): SpmcBPriorityQueue[T, Cap] {.
    inline.}
```

### `newMpmcBPriorityQueue`

```nim
proc newMpmcBPriorityQueue[T; Cap: static int](): MpmcBPriorityQueue[T, Cap] {.
    inline.}
```

### `tryPush`

```nim
proc tryPush[T; Cap: static int; ccProd: static PinScopeCardinality;
             ccCons: static PinScopeCardinality](
    self: BPriorityQueue[T, Cap, ccProd, ccCons]; item: sink T): bool {.gcsafe.}
```

Attempts to insert <tt class="docutils literal"><span class="pre"><span class="Identifier">item</span></span></tt> into the bounded priority queue without heap allocation. Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt> if inserted, or <tt class="docutils literal"><span class="pre"><span class="Identifier">false</span></span></tt> if the priority queue is full (<tt class="docutils literal"><span class="pre"><span class="Identifier">len</span> <span class="Operator">==</span> <span class="Identifier">Cap</span></span></tt>).

### `push`

```nim
proc push[T; Cap: static int; ccProd: static PinScopeCardinality;
          ccCons: static PinScopeCardinality](
    self: BPriorityQueue[T, Cap, ccProd, ccCons]; item: sink T): bool {.
    discardable, inline, gcsafe.}
```

Inserts <tt class="docutils literal"><span class="pre"><span class="Identifier">item</span></span></tt> into the bounded priority queue. Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt> if inserted, or <tt class="docutils literal"><span class="pre"><span class="Identifier">false</span></span></tt> if full (<tt class="docutils literal"><span class="pre"><span class="Identifier">len</span> <span class="Operator">==</span> <span class="Identifier">Cap</span></span></tt>).

### `tryPopMin`

```nim
proc tryPopMin[T; Cap: static int; ccProd: static PinScopeCardinality;
               ccCons: static PinScopeCardinality](
    self: BPriorityQueue[T, Cap, ccProd, ccCons]; outVal: var T): bool {.gcsafe.}
```

Attempts to remove the minimum element into <tt class="docutils literal"><span class="pre"><span class="Identifier">outVal</span></span></tt>. Equal priorities are popped in strict FIFO insertion order. Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt> if an element was popped, or <tt class="docutils literal"><span class="pre"><span class="Identifier">false</span></span></tt> if empty.

### `popMin`

```nim
proc popMin[T; Cap: static int; ccProd: static PinScopeCardinality;
            ccCons: static PinScopeCardinality](
    self: BPriorityQueue[T, Cap, ccProd, ccCons]): Option[T] {.inline, gcsafe.}
```

Removes and returns <tt class="docutils literal"><span class="pre"><span class="Identifier">some</span><span class="Punctuation">(</span><span class="Identifier">minItem</span><span class="Punctuation">)</span></span></tt>, or <tt class="docutils literal"><span class="pre"><span class="Identifier">none</span><span class="Punctuation">(</span><span class="Identifier">T</span><span class="Punctuation">)</span></span></tt> if empty.

### `peekMin`

```nim
proc peekMin[T; Cap: static int; ccProd: static PinScopeCardinality;
             ccCons: static PinScopeCardinality](
    self: BPriorityQueue[T, Cap, ccProd, ccCons]): Option[T] {.gcsafe.}
```

Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">some</span><span class="Punctuation">(</span><span class="Identifier">minItem</span><span class="Punctuation">)</span></span></tt> without removing it, or <tt class="docutils literal"><span class="pre"><span class="Identifier">none</span><span class="Punctuation">(</span><span class="Identifier">T</span><span class="Punctuation">)</span></span></tt> if empty.

### `clear`

```nim
proc clear[T; Cap: static int; ccProd: static PinScopeCardinality;
           ccCons: static PinScopeCardinality](
    self: BPriorityQueue[T, Cap, ccProd, ccCons]) {.gcsafe.}
```

Removes and destroys all elements currently in the bounded priority queue.

### `len`

```nim
proc len[T; Cap: static int; ccProd: static PinScopeCardinality;
         ccCons: static PinScopeCardinality](
    self: BPriorityQueue[T, Cap, ccProd, ccCons]): int {.inline.}
```

Returns the current number of active elements in the priority queue (<tt class="docutils literal"><span class="pre"><span class="DecNumber">0</span> <span class="Operator">..</span> <span class="Identifier">capacity</span></span></tt>).

### `capacity`

```nim
proc capacity[T; Cap: static int; ccProd: static PinScopeCardinality;
              ccCons: static PinScopeCardinality](
    self: BPriorityQueue[T, Cap, ccProd, ccCons]): int {.inline.}
```

Returns the effective capacity of the bounded priority queue (defaults to <tt class="docutils literal"><span class="pre"><span class="Identifier">Cap</span></span></tt>).

### `setEffectiveCapacity`

```nim
proc setEffectiveCapacity[T; Cap: static int;
                          ccProd: static PinScopeCardinality;
                          ccCons: static PinScopeCardinality](
    self: BPriorityQueue[T, Cap, ccProd, ccCons]; effCap: int)
```

Sets the effective maximum entry count (<tt class="docutils literal"><span class="pre"><span class="DecNumber">1</span> <span class="Operator">..</span> <span class="Identifier">Cap</span></span></tt>) on an empty <tt class="docutils literal"><span class="pre"><span class="Identifier">BPriorityQueue</span></span></tt>.

### `isEmpty`

```nim
proc isEmpty[T; Cap: static int; ccProd: static PinScopeCardinality;
             ccCons: static PinScopeCardinality](
    self: BPriorityQueue[T, Cap, ccProd, ccCons]): bool {.inline.}
```

Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt> if the priority queue currently contains no active elements.

### `isFull`

```nim
proc isFull[T; Cap: static int; ccProd: static PinScopeCardinality;
            ccCons: static PinScopeCardinality](
    self: BPriorityQueue[T, Cap, ccProd, ccCons]): bool {.inline.}
```

Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt> if the priority queue has reached its effective capacity.


## Templates

### `pop`

```nim
template pop[T; Cap: static int; ccProd, ccCons: static PinScopeCardinality](
    pq: BPriorityQueue[T, Cap, ccProd, ccCons]): untyped
```

### `peek`

```nim
template peek[T; Cap: static int; ccProd, ccCons: static PinScopeCardinality](
    pq: BPriorityQueue[T, Cap, ccProd, ccCons]): untyped
```

