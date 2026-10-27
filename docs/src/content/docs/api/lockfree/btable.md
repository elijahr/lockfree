---
title: "lockfree/btable"
description: "API reference for lockfree/btable"
---

=========================================================================== Concurrency Topology: SPSC, MPSC, SPMC, MPMC Bounded Concurrent Hash Table (<tt class="docutils literal"><span class="pre"><span class="Identifier">BTable</span><span class="Punctuation">[</span><span class="Identifier">K</span><span class="Punctuation">,</span> <span class="Identifier">V</span><span class="Punctuation">,</span> <span class="Identifier">Cap</span><span class="Punctuation">,</span> <span class="Identifier">ccProd</span><span class="Punctuation">,</span> <span class="Identifier">ccCons</span><span class="Punctuation">]</span></span></tt>)<hr />
<p>A preallocated, zero-SMR, zero-hot-path-heap-allocation bounded concurrent hash table backed by an open-addressing linear-probing slot array with per-slot atomic state &amp; sequence counters (<tt class="docutils literal"><span class="pre"><span class="Identifier">Empty</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">Occupied</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">Tombstone</span></span></tt>) and a preallocated flat-combining publication array.</p>
<p>Key properties:</p>
<ul class="simple"><li><strong>Preallocated Open-Addressing Probe Table</strong>: Preallocates <tt class="docutils literal"><span class="pre"><span class="DecNumber">2</span> <span class="Operator">*</span> <span class="Identifier">nextPowerOfTwo</span><span class="Punctuation">(</span><span class="Identifier">Cap</span><span class="Punctuation">)</span></span></tt> probe slots inside <tt class="docutils literal"><span class="pre"><span class="Identifier">BTableCore</span><span class="Punctuation">[</span><span class="Identifier">K</span><span class="Punctuation">,</span> <span class="Identifier">V</span><span class="Punctuation">,</span> <span class="Identifier">Cap</span><span class="Punctuation">]</span></span></tt> at initialization time so maximum load factor never exceeds 50% at capacity <tt class="docutils literal"><span class="pre"><span class="Identifier">Cap</span></span></tt>.</li>
<li><strong>Tombstone-Aware Linear Probing</strong>: <tt class="docutils literal"><span class="pre"><span class="Identifier">put</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">insert</span></span></tt> records <tt class="docutils literal"><span class="pre"><span class="Identifier">firstTombstone</span></span></tt> and continues probing until seeing <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> or <tt class="docutils literal"><span class="pre"><span class="Identifier">Empty</span></span></tt> (or exhausting all probe slots) before reusing <tt class="docutils literal"><span class="pre"><span class="Identifier">firstTombstone</span></span></tt>, preventing duplicate keys even when every slot is <tt class="docutils literal"><span class="pre"><span class="Identifier">Occupied</span></span></tt> or <tt class="docutils literal"><span class="pre"><span class="Identifier">Tombstone</span></span></tt>.</li>
<li><strong>Zero Hot-Path Heap Allocation &amp; Zero SMR</strong>: <tt class="docutils literal"><span class="pre"><span class="Identifier">tryPut</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">put</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">tryInsert</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">insert</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">tryGet</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">get</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">contains</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">remove</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">computeIfAbsent</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">atomicUpdate</span></span></tt>, and <tt class="docutils literal"><span class="pre"><span class="Identifier">upsert</span></span></tt> never allocate dynamic nodes or touch NEBR/DEBRA.</li>
<li><strong>ARC/ORC Memory Safety</strong>: Deleted and overwritten slots immediately invoke <tt class="docutils literal"><span class="pre"><span class="Identifier">reset</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt> on displaced keys/values under the combiner/slot synchronization protocol, guaranteeing zero leaks and zero TSan data races.</li>
</ul>
typestates verified


## Types

### `BTableSlot`

```nim
BTableSlot[K; V] = object
  state*: Atomic[uint32]
  seq*: Atomic[uint64]
  hashVal*: uint32
  key*: K
  val*: V
```

### `BTableCore`

```nim
BTableCore[K; V; Cap; ProbeSlots] = object
  combinerLock* {.align: 128.}: Atomic[uint64]
  count* {.align: 128.}: Atomic[int]
  activePubSlots* {.align: 128.}: Atomic[int]
  rc* {.align: 128.}: Atomic[int]
  liveCount*: int
  effCap*: int
  pubSlots*: array[BTableMaxCombinerSlots, BTablePubSlot[K, V]]
  slots*: array[ProbeSlots, BTableSlot[K, V]]
```

### `BTableLifecycleCtx`

```nim
BTableLifecycleCtx[K; V; Cap; ccProd; ccCons] = object of RootObj
```

### `BTableInit`

```nim
BTableInit[K; V; Cap; ccProd; ccCons] = distinct BTableLifecycleCtx[K, V, Cap,
    ccProd, ccCons]
```

### `BTableDestroyed`

```nim
BTableDestroyed[K; V; Cap; ccProd; ccCons] = distinct BTableLifecycleCtx[K, V,
    Cap, ccProd, ccCons]
```

### `BTableLifecycleState`

```nim
BTableLifecycleState = enum
  fsBTableDestroyed, fsBTableInit
```

### `BTableLifecycleStates`

```nim
BTableLifecycleStates[K; V; Cap; ccProd; ccCons] = BTableDestroyed[K, V, Cap,
    ccProd, ccCons] |
    BTableInit[K, V, Cap, ccProd, ccCons]
```

### `BTable`

```nim
BTable[K; V; Cap; ccProd; ccCons] {..} = object
  core*: ptr BTableCore[K, V, Cap, calcBTableProbeSlots(Cap)]
```

### `BoundedTable`

```nim
BoundedTable[K; V; Cap; ccProd; ccCons] = BTable[K, V, Cap, ccProd, ccCons]
```

### `SpscBoundedTable`

```nim
SpscBoundedTable[K; V; Cap] = BTable[K, V, Cap, ccSingle, ccSingle]
```

### `MpscBoundedTable`

```nim
MpscBoundedTable[K; V; Cap] = BTable[K, V, Cap, ccMulti, ccSingle]
```

### `SpmcBoundedTable`

```nim
SpmcBoundedTable[K; V; Cap] = BTable[K, V, Cap, ccSingle, ccMulti]
```

### `MpmcBoundedTable`

```nim
MpmcBoundedTable[K; V; Cap] = BTable[K, V, Cap, ccMulti, ccMulti]
```

### `SpscBTable`

```nim
SpscBTable[K; V; Cap] = BTable[K, V, Cap, ccSingle, ccSingle]
```

### `MpscBTable`

```nim
MpscBTable[K; V; Cap] = BTable[K, V, Cap, ccMulti, ccSingle]
```

### `SpmcBTable`

```nim
SpmcBTable[K; V; Cap] = BTable[K, V, Cap, ccSingle, ccMulti]
```

### `MpmcBTable`

```nim
MpmcBTable[K; V; Cap] = BTable[K, V, Cap, ccMulti, ccMulti]
```


## Constants

### `BTableSlotEmpty`

```nim
BTableSlotEmpty = 0'u32
```

### `BTableSlotOccupied`

```nim
BTableSlotOccupied = 1'u32
```

### `BTableSlotTombstone`

```nim
BTableSlotTombstone = 2'u32
```

### `BTableMaxCombinerSlots`

```nim
BTableMaxCombinerSlots = 64
```

### `BTableMaxCombineRounds`

```nim
BTableMaxCombineRounds = 8
```


## Procedures & Functions

### `calcBTableProbeSlots`

```nim
proc calcBTableProbeSlots(cap: int): int {.compileTime, raises: [], tags: [],
    forbids: [].}
```

### `state`

```nim
proc state[K; V; Cap: static int; ccProd: static PinScopeCardinality;
           ccCons: static PinScopeCardinality](
    f: BTableDestroyed[K, V, Cap, ccProd, ccCons]): BTableLifecycleState
```

Runtime state inspection for BTableDestroyed. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state[K; V; Cap: static int; ccProd: static PinScopeCardinality;
           ccCons: static PinScopeCardinality](
    f: BTableInit[K, V, Cap, ccProd, ccCons]): BTableLifecycleState
```

Runtime state inspection for BTableInit. Returns the enum value for pattern matching in case expressions.

### ``$``

```nim
proc `$`[K; V; Cap: static int; ccProd: static PinScopeCardinality;
         ccCons: static PinScopeCardinality](
    s: BTableDestroyed[K, V, Cap, ccProd, ccCons]): string
```

String representation for state 'BTableDestroyed'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`[K; V; Cap: static int; ccProd: static PinScopeCardinality;
         ccCons: static PinScopeCardinality](
    s: BTableInit[K, V, Cap, ccProd, ccCons]): string
```

String representation for state 'BTableInit'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`(s: BTableLifecycleState): string {.raises: [], tags: [], forbids: [].}
```

String representation of BTableLifecycleState enum. Strips the fs prefix for human-friendly output.

### ``=destroy``

```nim
proc `=destroy`[K, V; Cap: static int; ccProd: static PinScopeCardinality;
                ccCons: static PinScopeCardinality](
    self: var BTable[K, V, Cap, ccProd, ccCons]) {.raises: [], raises: [].}
```

### ``=copy``

```nim
proc `=copy`[K, V; Cap: static int; ccProd: static PinScopeCardinality;
             ccCons: static PinScopeCardinality](
    dest: var BTable[K, V, Cap, ccProd, ccCons];
    src: BTable[K, V, Cap, ccProd, ccCons]) {.notATransition.}
```

### ``=sink``

```nim
proc `=sink`[K, V; Cap: static int; ccProd: static PinScopeCardinality;
             ccCons: static PinScopeCardinality](
    dest: var BTable[K, V, Cap, ccProd, ccCons];
    src: BTable[K, V, Cap, ccProd, ccCons]) {.notATransition.}
```

### `initBTable`

```nim
proc initBTable[K, V; Cap: static int;
                ccProd: static PinScopeCardinality = ccMulti;
                ccCons: static PinScopeCardinality = ccMulti](): BTable[K, V,
    Cap, ccProd, ccCons]
```

Initializes a preallocated bounded concurrent hash table with capacity <tt class="docutils literal"><span class="pre"><span class="Identifier">Cap</span></span></tt>.

### `newBTable`

```nim
proc newBTable[K, V; Cap: static int;
               ccProd: static PinScopeCardinality = ccMulti;
               ccCons: static PinScopeCardinality = ccMulti](): BTable[K, V,
    Cap, ccProd, ccCons] {.inline.}
```

### `initBoundedTable`

```nim
proc initBoundedTable[K, V; Cap: static int;
                      ccProd: static PinScopeCardinality = ccMulti;
                      ccCons: static PinScopeCardinality = ccMulti](): BoundedTable[
    K, V, Cap, ccProd, ccCons] {.inline.}
```

### `newBoundedTable`

```nim
proc newBoundedTable[K, V; Cap: static int;
                     ccProd: static PinScopeCardinality = ccMulti;
                     ccCons: static PinScopeCardinality = ccMulti](): BoundedTable[
    K, V, Cap, ccProd, ccCons] {.inline.}
```

### `initSpscBTable`

```nim
proc initSpscBTable[K, V; Cap: static int](): SpscBTable[K, V, Cap] {.inline.}
```

### `initMpscBTable`

```nim
proc initMpscBTable[K, V; Cap: static int](): MpscBTable[K, V, Cap] {.inline.}
```

### `initSpmcBTable`

```nim
proc initSpmcBTable[K, V; Cap: static int](): SpmcBTable[K, V, Cap] {.inline.}
```

### `initMpmcBTable`

```nim
proc initMpmcBTable[K, V; Cap: static int](): MpmcBTable[K, V, Cap] {.inline.}
```

### `newSpscBTable`

```nim
proc newSpscBTable[K, V; Cap: static int](): SpscBTable[K, V, Cap] {.inline.}
```

### `newMpscBTable`

```nim
proc newMpscBTable[K, V; Cap: static int](): MpscBTable[K, V, Cap] {.inline.}
```

### `newSpmcBTable`

```nim
proc newSpmcBTable[K, V; Cap: static int](): SpmcBTable[K, V, Cap] {.inline.}
```

### `newMpmcBTable`

```nim
proc newMpmcBTable[K, V; Cap: static int](): MpmcBTable[K, V, Cap] {.inline.}
```

### `tryPut`

```nim
proc tryPut[K, V; Cap: static int; ccProd: static PinScopeCardinality;
            ccCons: static PinScopeCardinality](
    self: BTable[K, V, Cap, ccProd, ccCons]; key: sink K; val: sink V): bool {.
    gcsafe, notATransition.}
```

Inserts <tt class="docutils literal"><span class="pre"><span class="Punctuation">(</span><span class="Identifier">key</span><span class="Punctuation">,</span> <span class="Identifier">val</span><span class="Punctuation">)</span></span></tt> or updates <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> if already present. Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt> on success, or <tt class="docutils literal"><span class="pre"><span class="Identifier">false</span></span></tt> if <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> is new and the table is full (<tt class="docutils literal"><span class="pre"><span class="Identifier">len</span> <span class="Operator">==</span> <span class="Identifier">Cap</span></span></tt>).

### `tryPutEx`

```nim
proc tryPutEx[K, V; Cap: static int; ccProd: static PinScopeCardinality;
              ccCons: static PinScopeCardinality](
    self: BTable[K, V, Cap, ccProd, ccCons]; key: sink K; val: sink V;
    outInserted: ptr bool; outFull: ptr bool): bool {.gcsafe, notATransition.}
```

Inserts <tt class="docutils literal"><span class="pre"><span class="Punctuation">(</span><span class="Identifier">key</span><span class="Punctuation">,</span> <span class="Identifier">val</span><span class="Punctuation">)</span></span></tt> or updates <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> if already present, recording whether a new entry was inserted (<tt class="docutils literal"><span class="pre"><span class="Identifier">outInserted</span><span class="Punctuation">[</span><span class="Punctuation">]</span></span></tt>) or whether the table was full (<tt class="docutils literal"><span class="pre"><span class="Identifier">outFull</span><span class="Punctuation">[</span><span class="Punctuation">]</span></span></tt>).

### `put`

```nim
proc put[K, V; Cap: static int; ccProd: static PinScopeCardinality;
         ccCons: static PinScopeCardinality](
    self: BTable[K, V, Cap, ccProd, ccCons]; key: sink K; val: sink V): bool {.
    discardable, inline, gcsafe, notATransition.}
```

Inserts or updates <tt class="docutils literal"><span class="pre"><span class="Punctuation">(</span><span class="Identifier">key</span><span class="Punctuation">,</span> <span class="Identifier">val</span><span class="Punctuation">)</span></span></tt>. Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">false</span></span></tt> if <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> is absent and <tt class="docutils literal"><span class="pre"><span class="Identifier">len</span> <span class="Operator">==</span> <span class="Identifier">Cap</span></span></tt>.

### ``[]=``

```nim
proc `[]=`[K, V; Cap: static int; ccProd: static PinScopeCardinality;
           ccCons: static PinScopeCardinality](
    self: BTable[K, V, Cap, ccProd, ccCons]; key: sink K; val: sink V) {.inline,
    gcsafe, notATransition.}
```

### `tryInsert`

```nim
proc tryInsert[K, V; Cap: static int; ccProd: static PinScopeCardinality;
               ccCons: static PinScopeCardinality](
    self: BTable[K, V, Cap, ccProd, ccCons]; key: sink K; val: sink V): bool {.
    gcsafe, notATransition.}
```

Inserts <tt class="docutils literal"><span class="pre"><span class="Punctuation">(</span><span class="Identifier">key</span><span class="Punctuation">,</span> <span class="Identifier">val</span><span class="Punctuation">)</span></span></tt> only if <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> is not already present and <tt class="docutils literal"><span class="pre"><span class="Identifier">len</span> <span class="Operator">&lt;</span> <span class="Identifier">Cap</span></span></tt>. Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt> if inserted, or <tt class="docutils literal"><span class="pre"><span class="Identifier">false</span></span></tt> if <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> already exists or the table is full.

### `tryInsertEx`

```nim
proc tryInsertEx[K, V; Cap: static int; ccProd: static PinScopeCardinality;
                 ccCons: static PinScopeCardinality](
    self: BTable[K, V, Cap, ccProd, ccCons]; key: sink K; val: sink V;
    outInserted: ptr bool; outFull: ptr bool): bool {.gcsafe, notATransition.}
```

Inserts <tt class="docutils literal"><span class="pre"><span class="Punctuation">(</span><span class="Identifier">key</span><span class="Punctuation">,</span> <span class="Identifier">val</span><span class="Punctuation">)</span></span></tt> only if <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> is not already present and <tt class="docutils literal"><span class="pre"><span class="Identifier">len</span> <span class="Operator">&lt;</span> <span class="Identifier">capacity</span></span></tt>, recording whether <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> was inserted (<tt class="docutils literal"><span class="pre"><span class="Identifier">outInserted</span><span class="Punctuation">[</span><span class="Punctuation">]</span></span></tt>) or whether the table was full (<tt class="docutils literal"><span class="pre"><span class="Identifier">outFull</span><span class="Punctuation">[</span><span class="Punctuation">]</span></span></tt>).

### `insert`

```nim
proc insert[K, V; Cap: static int; ccProd: static PinScopeCardinality;
            ccCons: static PinScopeCardinality](
    self: BTable[K, V, Cap, ccProd, ccCons]; key: sink K; val: sink V): bool {.
    discardable, inline, gcsafe, notATransition.}
```

Alias for <tt class="docutils literal"><span class="pre"><span class="Identifier">tryInsert</span></span></tt>.

### `tryGet`

```nim
proc tryGet[K, V; Cap: static int; ccProd: static PinScopeCardinality;
            ccCons: static PinScopeCardinality](
    self: BTable[K, V, Cap, ccProd, ccCons]; key: K; outVal: var V): bool {.
    gcsafe, notATransition.}
```

Looks up <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> and copies its value into <tt class="docutils literal"><span class="pre"><span class="Identifier">outVal</span></span></tt>. Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt> if found, or <tt class="docutils literal"><span class="pre"><span class="Identifier">false</span></span></tt> if absent.

### `get`

```nim
proc get[K, V; Cap: static int; ccProd: static PinScopeCardinality;
         ccCons: static PinScopeCardinality](
    self: BTable[K, V, Cap, ccProd, ccCons]; key: K): Option[V] {.inline,
    gcsafe, notATransition.}
```

Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">some</span><span class="Punctuation">(</span><span class="Identifier">val</span><span class="Punctuation">)</span></span></tt> if <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> is present, or <tt class="docutils literal"><span class="pre"><span class="Identifier">none</span><span class="Punctuation">(</span><span class="Identifier">V</span><span class="Punctuation">)</span></span></tt> if absent.

### `lookup`

```nim
proc lookup[K, V; Cap: static int; ccProd: static PinScopeCardinality;
            ccCons: static PinScopeCardinality](
    self: BTable[K, V, Cap, ccProd, ccCons]; key: K): Option[V] {.inline,
    gcsafe, notATransition.}
```

Alias for <tt class="docutils literal"><span class="pre"><span class="Identifier">get</span></span></tt>.

### `contains`

```nim
proc contains[K, V; Cap: static int; ccProd: static PinScopeCardinality;
              ccCons: static PinScopeCardinality](
    self: BTable[K, V, Cap, ccProd, ccCons]; key: K): bool {.gcsafe,
    notATransition.}
```

Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt> if <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> is present in the bounded table.

### ``[]``

```nim
proc `[]`[K, V; Cap: static int; ccProd: static PinScopeCardinality;
          ccCons: static PinScopeCardinality](
    self: BTable[K, V, Cap, ccProd, ccCons]; key: K): V {.gcsafe, notATransition.}
```

Returns the value associated with <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt>. Raises <tt class="docutils literal"><span class="pre"><span class="Identifier">KeyError</span></span></tt> if <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> is not found.

### `hasKey`

```nim
proc hasKey[K, V; Cap: static int; ccProd: static PinScopeCardinality;
            ccCons: static PinScopeCardinality](
    self: BTable[K, V, Cap, ccProd, ccCons]; key: K): bool {.inline, gcsafe,
    notATransition.}
```

Alias for <tt class="docutils literal"><span class="pre"><span class="Identifier">contains</span></span></tt>. Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt> if <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> is present in the table.

### `remove`

```nim
proc remove[K, V; Cap: static int; ccProd: static PinScopeCardinality;
            ccCons: static PinScopeCardinality](
    self: BTable[K, V, Cap, ccProd, ccCons]; key: K): bool {.discardable,
    gcsafe, notATransition.}
```

Removes <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> from the bounded table if present. Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt> if <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> was found and removed, or <tt class="docutils literal"><span class="pre"><span class="Identifier">false</span></span></tt> if absent.

### `del`

```nim
proc del[K, V; Cap: static int; ccProd: static PinScopeCardinality;
         ccCons: static PinScopeCardinality](
    self: BTable[K, V, Cap, ccProd, ccCons]; key: K): bool {.discardable,
    inline, gcsafe, notATransition.}
```

Alias for <tt class="docutils literal"><span class="pre"><span class="Identifier">remove</span></span></tt>.

### `tryTake`

```nim
proc tryTake[K, V; Cap: static int; ccProd: static PinScopeCardinality;
             ccCons: static PinScopeCardinality](
    self: BTable[K, V, Cap, ccProd, ccCons]; key: K; outVal: var V): bool {.
    gcsafe, notATransition.}
```

Atomically removes <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt>, copies its removed value into <tt class="docutils literal"><span class="pre"><span class="Identifier">outVal</span></span></tt>, and returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt>, or returns <tt class="docutils literal"><span class="pre"><span class="Identifier">false</span></span></tt> if <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> is absent. Safe for <tt class="docutils literal"><span class="pre"><span class="Identifier">pointer</span></span></tt>/<tt class="docutils literal"><span class="pre"><span class="Keyword">nil</span></span></tt> values.

### `take`

```nim
proc take[K, V; Cap: static int; ccProd: static PinScopeCardinality;
          ccCons: static PinScopeCardinality](
    self: BTable[K, V, Cap, ccProd, ccCons]; key: K): Option[V] {.gcsafe,
    notATransition.}
```

Atomically removes <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> and returns <tt class="docutils literal"><span class="pre"><span class="Identifier">some</span><span class="Punctuation">(</span><span class="Identifier">removedVal</span><span class="Punctuation">)</span></span></tt>, or <tt class="docutils literal"><span class="pre"><span class="Identifier">none</span><span class="Punctuation">(</span><span class="Identifier">V</span><span class="Punctuation">)</span></span></tt> if absent.

### `tryComputeIfAbsent`

```nim
proc tryComputeIfAbsent[K, V; Cap: static int;
                        ccProd: static PinScopeCardinality;
                        ccCons: static PinScopeCardinality](
    self: BTable[K, V, Cap, ccProd, ccCons]; key: K;
    factory: proc (k: K): V {.gcsafe.}; outVal: var V): bool {.gcsafe,
    notATransition.}
```

Atomically looks up <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt>; if absent and <tt class="docutils literal"><span class="pre"><span class="Identifier">len</span> <span class="Operator">&lt;</span> <span class="Identifier">Cap</span></span></tt>, computes <tt class="docutils literal"><span class="pre"><span class="Identifier">factory</span><span class="Punctuation">(</span><span class="Identifier">key</span><span class="Punctuation">)</span></span></tt>, inserts it, stores the value in <tt class="docutils literal"><span class="pre"><span class="Identifier">outVal</span></span></tt>, and returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt>. Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">false</span></span></tt> only if <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> is absent and the table is full (<tt class="docutils literal"><span class="pre"><span class="Identifier">len</span> <span class="Operator">==</span> <span class="Identifier">Cap</span></span></tt>). Safe for <tt class="docutils literal"><span class="pre"><span class="Identifier">pointer</span></span></tt>/<tt class="docutils literal"><span class="pre"><span class="Keyword">nil</span></span></tt> values.

### `tryComputeIfAbsent`

```nim
proc tryComputeIfAbsent[K, V; Cap: static int;
                        ccProd: static PinScopeCardinality;
                        ccCons: static PinScopeCardinality](
    self: BTable[K, V, Cap, ccProd, ccCons]; key: K;
    factory: proc (k: K): V {.gcsafe.}): Option[V] {.gcsafe, notATransition.}
```

Atomically looks up <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt>; if absent and <tt class="docutils literal"><span class="pre"><span class="Identifier">len</span> <span class="Operator">&lt;</span> <span class="Identifier">Cap</span></span></tt>, computes <tt class="docutils literal"><span class="pre"><span class="Identifier">factory</span><span class="Punctuation">(</span><span class="Identifier">key</span><span class="Punctuation">)</span></span></tt>, inserts it, and returns <tt class="docutils literal"><span class="pre"><span class="Identifier">some</span><span class="Punctuation">(</span><span class="Identifier">val</span><span class="Punctuation">)</span></span></tt>. Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">none</span><span class="Punctuation">(</span><span class="Identifier">V</span><span class="Punctuation">)</span></span></tt> only if <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> is absent and the table is full (<tt class="docutils literal"><span class="pre"><span class="Identifier">len</span> <span class="Operator">==</span> <span class="Identifier">Cap</span></span></tt>).

### `tryComputeIfAbsent`

```nim
proc tryComputeIfAbsent[K, V; Cap: static int;
                        ccProd: static PinScopeCardinality;
                        ccCons: static PinScopeCardinality](
    self: BTable[K, V, Cap, ccProd, ccCons]; key: K;
    factory: proc (): V {.gcsafe.}): Option[V] {.inline, gcsafe, notATransition.}
```

### `computeIfAbsent`

```nim
proc computeIfAbsent[K, V; Cap: static int; ccProd: static PinScopeCardinality;
                     ccCons: static PinScopeCardinality](
    self: BTable[K, V, Cap, ccProd, ccCons]; key: K;
    factory: proc (k: K): V {.gcsafe.}): V {.inline, gcsafe, notATransition.}
```

Atomically returns existing value for <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> or computes and inserts <tt class="docutils literal"><span class="pre"><span class="Identifier">factory</span><span class="Punctuation">(</span><span class="Identifier">key</span><span class="Punctuation">)</span></span></tt>.

### `computeIfAbsent`

```nim
proc computeIfAbsent[K, V; Cap: static int; ccProd: static PinScopeCardinality;
                     ccCons: static PinScopeCardinality](
    self: BTable[K, V, Cap, ccProd, ccCons]; key: K;
    factory: proc (): V {.gcsafe.}): V {.inline, gcsafe, notATransition.}
```

### `tryAtomicUpdate`

```nim
proc tryAtomicUpdate[K, V; Cap: static int; ccProd: static PinScopeCardinality;
                     ccCons: static PinScopeCardinality](
    self: BTable[K, V, Cap, ccProd, ccCons]; key: K;
    updater: proc (k: K; oldVal: V): V {.gcsafe.}; outVal: var V): bool {.
    gcsafe, notATransition.}
```

Atomically updates the value for <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> in-place via <tt class="docutils literal"><span class="pre"><span class="Identifier">updater</span><span class="Punctuation">(</span><span class="Identifier">key</span><span class="Punctuation">,</span> <span class="Identifier">oldVal</span><span class="Punctuation">)</span></span></tt>, stores the new value in <tt class="docutils literal"><span class="pre"><span class="Identifier">outVal</span></span></tt>, and returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt> if <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> existed, or <tt class="docutils literal"><span class="pre"><span class="Identifier">false</span></span></tt> if <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> was absent. Safe for <tt class="docutils literal"><span class="pre"><span class="Identifier">pointer</span></span></tt>/<tt class="docutils literal"><span class="pre"><span class="Keyword">nil</span></span></tt> values.

### `atomicUpdate`

```nim
proc atomicUpdate[K, V; Cap: static int; ccProd: static PinScopeCardinality;
                  ccCons: static PinScopeCardinality](
    self: BTable[K, V, Cap, ccProd, ccCons]; key: K;
    updater: proc (k: K; oldVal: V): V {.gcsafe.}): Option[V] {.gcsafe,
    notATransition.}
```

Atomically updates the value for <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> in-place via <tt class="docutils literal"><span class="pre"><span class="Identifier">updater</span><span class="Punctuation">(</span><span class="Identifier">key</span><span class="Punctuation">,</span> <span class="Identifier">oldVal</span><span class="Punctuation">)</span></span></tt>. Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">some</span><span class="Punctuation">(</span><span class="Identifier">newVal</span><span class="Punctuation">)</span></span></tt> if <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> existed, or <tt class="docutils literal"><span class="pre"><span class="Identifier">none</span><span class="Punctuation">(</span><span class="Identifier">V</span><span class="Punctuation">)</span></span></tt> if <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> was absent.

### `atomicUpdate`

```nim
proc atomicUpdate[K, V; Cap: static int; ccProd: static PinScopeCardinality;
                  ccCons: static PinScopeCardinality](
    self: BTable[K, V, Cap, ccProd, ccCons]; key: K;
    updater: proc (oldVal: V): V {.gcsafe.}): Option[V] {.inline, gcsafe,
    notATransition.}
```

### `tryUpsert`

```nim
proc tryUpsert[K, V; Cap: static int; ccProd: static PinScopeCardinality;
               ccCons: static PinScopeCardinality](
    self: BTable[K, V, Cap, ccProd, ccCons]; key: K; initialVal: V;
    updater: proc (k: K; oldVal: V): V {.gcsafe.}; outVal: var V): bool {.
    gcsafe, notATransition.}
```

Atomically inserts <tt class="docutils literal"><span class="pre"><span class="Punctuation">(</span><span class="Identifier">key</span><span class="Punctuation">,</span> <span class="Identifier">initialVal</span><span class="Punctuation">)</span></span></tt> if absent (when <tt class="docutils literal"><span class="pre"><span class="Identifier">len</span> <span class="Operator">&lt;</span> <span class="Identifier">Cap</span></span></tt>), or updates the existing entry via <tt class="docutils literal"><span class="pre"><span class="Identifier">updater</span><span class="Punctuation">(</span><span class="Identifier">key</span><span class="Punctuation">,</span> <span class="Identifier">oldVal</span><span class="Punctuation">)</span></span></tt>, storing the resulting value in <tt class="docutils literal"><span class="pre"><span class="Identifier">outVal</span></span></tt> and returning <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt>, or <tt class="docutils literal"><span class="pre"><span class="Identifier">false</span></span></tt> if <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> was absent and <tt class="docutils literal"><span class="pre"><span class="Identifier">len</span> <span class="Operator">==</span> <span class="Identifier">Cap</span></span></tt>. Safe for <tt class="docutils literal"><span class="pre"><span class="Identifier">pointer</span></span></tt>/<tt class="docutils literal"><span class="pre"><span class="Keyword">nil</span></span></tt> values.

### `tryUpsert`

```nim
proc tryUpsert[K, V; Cap: static int; ccProd: static PinScopeCardinality;
               ccCons: static PinScopeCardinality](
    self: BTable[K, V, Cap, ccProd, ccCons]; key: K; initialVal: V;
    updater: proc (k: K; oldVal: V): V {.gcsafe.}): Option[V] {.gcsafe,
    notATransition.}
```

Atomically inserts <tt class="docutils literal"><span class="pre"><span class="Punctuation">(</span><span class="Identifier">key</span><span class="Punctuation">,</span> <span class="Identifier">initialVal</span><span class="Punctuation">)</span></span></tt> if absent (when <tt class="docutils literal"><span class="pre"><span class="Identifier">len</span> <span class="Operator">&lt;</span> <span class="Identifier">Cap</span></span></tt>), or updates the existing entry via <tt class="docutils literal"><span class="pre"><span class="Identifier">updater</span><span class="Punctuation">(</span><span class="Identifier">key</span><span class="Punctuation">,</span> <span class="Identifier">oldVal</span><span class="Punctuation">)</span></span></tt>. Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">some</span><span class="Punctuation">(</span><span class="Identifier">finalVal</span><span class="Punctuation">)</span></span></tt>, or <tt class="docutils literal"><span class="pre"><span class="Identifier">none</span><span class="Punctuation">(</span><span class="Identifier">V</span><span class="Punctuation">)</span></span></tt> if <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> was absent and <tt class="docutils literal"><span class="pre"><span class="Identifier">len</span> <span class="Operator">==</span> <span class="Identifier">Cap</span></span></tt>.

### `tryUpsert`

```nim
proc tryUpsert[K, V; Cap: static int; ccProd: static PinScopeCardinality;
               ccCons: static PinScopeCardinality](
    self: BTable[K, V, Cap, ccProd, ccCons]; key: K; initialVal: V;
    updater: proc (oldVal: V): V {.gcsafe.}): Option[V] {.inline, gcsafe,
    notATransition.}
```

### `upsert`

```nim
proc upsert[K, V; Cap: static int; ccProd: static PinScopeCardinality;
            ccCons: static PinScopeCardinality](
    self: BTable[K, V, Cap, ccProd, ccCons]; key: K; initialVal: V;
    updater: proc (k: K; oldVal: V): V {.gcsafe.}): V {.inline, gcsafe,
    notATransition.}
```

### `upsert`

```nim
proc upsert[K, V; Cap: static int; ccProd: static PinScopeCardinality;
            ccCons: static PinScopeCardinality](
    self: BTable[K, V, Cap, ccProd, ccCons]; key: K; initialVal: V;
    updater: proc (oldVal: V): V {.gcsafe.}): V {.inline, gcsafe, notATransition.}
```

### `snapshotPairs`

```nim
proc snapshotPairs[K, V; Cap: static int; ccProd: static PinScopeCardinality;
                   ccCons: static PinScopeCardinality](
    self: BTable[K, V, Cap, ccProd, ccCons]): seq[(K, V)] {.gcsafe,
    notATransition.}
```

Returns a point-in-time snapshot of all <tt class="docutils literal"><span class="pre"><span class="Punctuation">(</span><span class="Identifier">key</span><span class="Punctuation">,</span> <span class="Identifier">val</span><span class="Punctuation">)</span></span></tt> pairs currently in the table.

### `snapshotKeys`

```nim
proc snapshotKeys[K, V; Cap: static int; ccProd: static PinScopeCardinality;
                  ccCons: static PinScopeCardinality](
    self: BTable[K, V, Cap, ccProd, ccCons]): seq[K] {.gcsafe, notATransition.}
```

### `snapshotValues`

```nim
proc snapshotValues[K, V; Cap: static int; ccProd: static PinScopeCardinality;
                    ccCons: static PinScopeCardinality](
    self: BTable[K, V, Cap, ccProd, ccCons]): seq[V] {.gcsafe, notATransition.}
```

### `clear`

```nim
proc clear[K, V; Cap: static int; ccProd: static PinScopeCardinality;
           ccCons: static PinScopeCardinality](
    self: BTable[K, V, Cap, ccProd, ccCons]) {.gcsafe, notATransition.}
```

Removes and destroys all entries in the bounded table, resetting all slots to <tt class="docutils literal"><span class="pre"><span class="Identifier">BTableSlotEmpty</span></span></tt>.

### `clearWith`

```nim
proc clearWith[K, V; Cap: static int; ccProd: static PinScopeCardinality;
               ccCons: static PinScopeCardinality](
    self: BTable[K, V, Cap, ccProd, ccCons];
    destructor: proc (key: K; val: V; userData: pointer) {.cdecl, gcsafe.};
    userData: pointer) {.gcsafe, notATransition.}
```

Clears all entries in the bounded table, invoking <tt class="docutils literal"><span class="pre"><span class="Identifier">destructor</span><span class="Punctuation">(</span><span class="Identifier">key</span><span class="Punctuation">,</span> <span class="Identifier">val</span><span class="Punctuation">,</span> <span class="Identifier">userData</span><span class="Punctuation">)</span></span></tt> (when non-nil) on each occupied slot before resetting all slots to <tt class="docutils literal"><span class="pre"><span class="Identifier">BTableSlotEmpty</span></span></tt>.

### `len`

```nim
proc len[K, V; Cap: static int; ccProd: static PinScopeCardinality;
         ccCons: static PinScopeCardinality](
    self: BTable[K, V, Cap, ccProd, ccCons]): int {.inline, notATransition.}
```

Returns the current number of active key-value entries in the table (<tt class="docutils literal"><span class="pre"><span class="DecNumber">0</span> <span class="Operator">..</span> <span class="Identifier">capacity</span></span></tt>).

### `capacity`

```nim
proc capacity[K, V; Cap: static int; ccProd: static PinScopeCardinality;
              ccCons: static PinScopeCardinality](
    self: BTable[K, V, Cap, ccProd, ccCons]): int {.inline, notATransition.}
```

Returns the effective maximum entry capacity of the bounded table (defaults to <tt class="docutils literal"><span class="pre"><span class="Identifier">Cap</span></span></tt>).

### `setEffectiveCapacity`

```nim
proc setEffectiveCapacity[K, V; Cap: static int;
                          ccProd: static PinScopeCardinality;
                          ccCons: static PinScopeCardinality](
    self: BTable[K, V, Cap, ccProd, ccCons]; effCap: int) {.notATransition.}
```

Sets the effective maximum entry count (<tt class="docutils literal"><span class="pre"><span class="DecNumber">1</span> <span class="Operator">..</span> <span class="Identifier">Cap</span></span></tt>) on an empty <tt class="docutils literal"><span class="pre"><span class="Identifier">BTable</span></span></tt>.

### `probeCapacity`

```nim
proc probeCapacity[K, V; Cap: static int; ccProd: static PinScopeCardinality;
                   ccCons: static PinScopeCardinality](
    self: BTable[K, V, Cap, ccProd, ccCons]): int {.inline, notATransition.}
```

Returns the underlying preallocated open-addressing probe table size (<tt class="docutils literal"><span class="pre"><span class="DecNumber">2</span> <span class="Operator">*</span> <span class="Identifier">nextPowerOfTwo</span><span class="Punctuation">(</span><span class="Identifier">Cap</span><span class="Punctuation">)</span></span></tt>).

### `isEmpty`

```nim
proc isEmpty[K, V; Cap: static int; ccProd: static PinScopeCardinality;
             ccCons: static PinScopeCardinality](
    self: BTable[K, V, Cap, ccProd, ccCons]): bool {.inline, notATransition.}
```

Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt> if the table currently contains no entries.

### `isFull`

```nim
proc isFull[K, V; Cap: static int; ccProd: static PinScopeCardinality;
            ccCons: static PinScopeCardinality](
    self: BTable[K, V, Cap, ccProd, ccCons]): bool {.inline, notATransition.}
```

Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt> if the table has reached its effective capacity.

### `tryPut`

```nim
proc tryPut[K, V; Cap: static int; ccProd: static PinScopeCardinality;
            ccCons: static PinScopeCardinality](
    ep: Bound[(K, V), TableWriterTag, BTable[K, V, Cap, ccProd, ccCons]];
    key: sink K; val: sink V): bool {.inline, gcsafe, notATransition.}
```

### `put`

```nim
proc put[K, V; Cap: static int; ccProd: static PinScopeCardinality;
         ccCons: static PinScopeCardinality](
    ep: Bound[(K, V), TableWriterTag, BTable[K, V, Cap, ccProd, ccCons]];
    key: sink K; val: sink V): bool {.discardable, inline, gcsafe,
                                      notATransition.}
```

### ``[]=``

```nim
proc `[]=`[K, V; Cap: static int; ccProd: static PinScopeCardinality;
           ccCons: static PinScopeCardinality](
    ep: Bound[(K, V), TableWriterTag, BTable[K, V, Cap, ccProd, ccCons]];
    key: sink K; val: sink V) {.inline, gcsafe, notATransition.}
```

### `tryInsert`

```nim
proc tryInsert[K, V; Cap: static int; ccProd: static PinScopeCardinality;
               ccCons: static PinScopeCardinality](
    ep: Bound[(K, V), TableWriterTag, BTable[K, V, Cap, ccProd, ccCons]];
    key: sink K; val: sink V): bool {.inline, gcsafe, notATransition.}
```

### `insert`

```nim
proc insert[K, V; Cap: static int; ccProd: static PinScopeCardinality;
            ccCons: static PinScopeCardinality](
    ep: Bound[(K, V), TableWriterTag, BTable[K, V, Cap, ccProd, ccCons]];
    key: sink K; val: sink V): bool {.discardable, inline, gcsafe,
                                      notATransition.}
```

### `remove`

```nim
proc remove[K, V; Cap: static int; ccProd: static PinScopeCardinality;
            ccCons: static PinScopeCardinality](
    ep: Bound[(K, V), TableWriterTag, BTable[K, V, Cap, ccProd, ccCons]]; key: K): bool {.
    discardable, inline, gcsafe, notATransition.}
```

### `del`

```nim
proc del[K, V; Cap: static int; ccProd: static PinScopeCardinality;
         ccCons: static PinScopeCardinality](
    ep: Bound[(K, V), TableWriterTag, BTable[K, V, Cap, ccProd, ccCons]]; key: K): bool {.
    discardable, inline, gcsafe, notATransition.}
```

### `take`

```nim
proc take[K, V; Cap: static int; ccProd: static PinScopeCardinality;
          ccCons: static PinScopeCardinality](
    ep: Bound[(K, V), TableWriterTag, BTable[K, V, Cap, ccProd, ccCons]]; key: K): Option[
    V] {.inline, gcsafe, notATransition.}
```

### `clear`

```nim
proc clear[K, V; Cap: static int; ccProd: static PinScopeCardinality;
           ccCons: static PinScopeCardinality](
    ep: Bound[(K, V), TableWriterTag, BTable[K, V, Cap, ccProd, ccCons]]) {.
    inline, gcsafe, notATransition.}
```

### `tryGet`

```nim
proc tryGet[K, V; Cap: static int; ccProd: static PinScopeCardinality;
            ccCons: static PinScopeCardinality;
            Tag: TableWriterTag | TableReaderTag](
    ep: Bound[(K, V), Tag, BTable[K, V, Cap, ccProd, ccCons]]; key: K;
    outVal: var V): bool {.inline, gcsafe, notATransition.}
```

### `get`

```nim
proc get[K, V; Cap: static int; ccProd: static PinScopeCardinality;
         ccCons: static PinScopeCardinality;
         Tag: TableWriterTag | TableReaderTag](
    ep: Bound[(K, V), Tag, BTable[K, V, Cap, ccProd, ccCons]]; key: K): Option[V] {.
    inline, gcsafe, notATransition.}
```

### `lookup`

```nim
proc lookup[K, V; Cap: static int; ccProd: static PinScopeCardinality;
            ccCons: static PinScopeCardinality;
            Tag: TableWriterTag | TableReaderTag](
    ep: Bound[(K, V), Tag, BTable[K, V, Cap, ccProd, ccCons]]; key: K): Option[V] {.
    inline, gcsafe, notATransition.}
```

### `contains`

```nim
proc contains[K, V; Cap: static int; ccProd: static PinScopeCardinality;
              ccCons: static PinScopeCardinality;
              Tag: TableWriterTag | TableReaderTag](
    ep: Bound[(K, V), Tag, BTable[K, V, Cap, ccProd, ccCons]]; key: K): bool {.
    inline, gcsafe, notATransition.}
```

### ``[]``

```nim
proc `[]`[K, V; Cap: static int; ccProd: static PinScopeCardinality;
          ccCons: static PinScopeCardinality;
          Tag: TableWriterTag | TableReaderTag](
    ep: Bound[(K, V), Tag, BTable[K, V, Cap, ccProd, ccCons]]; key: K): V {.
    inline, gcsafe, notATransition.}
```

### `hasKey`

```nim
proc hasKey[K, V; Cap: static int; ccProd: static PinScopeCardinality;
            ccCons: static PinScopeCardinality;
            Tag: TableWriterTag | TableReaderTag](
    ep: Bound[(K, V), Tag, BTable[K, V, Cap, ccProd, ccCons]]; key: K): bool {.
    inline, gcsafe, notATransition.}
```

### `len`

```nim
proc len[K, V; Cap: static int; ccProd: static PinScopeCardinality;
         ccCons: static PinScopeCardinality;
         Tag: TableWriterTag | TableReaderTag](
    ep: Bound[(K, V), Tag, BTable[K, V, Cap, ccProd, ccCons]]): int {.inline,
    notATransition.}
```

### `capacity`

```nim
proc capacity[K, V; Cap: static int; ccProd: static PinScopeCardinality;
              ccCons: static PinScopeCardinality;
              Tag: TableWriterTag | TableReaderTag](
    ep: Bound[(K, V), Tag, BTable[K, V, Cap, ccProd, ccCons]]): int {.inline,
    notATransition.}
```

### `isEmpty`

```nim
proc isEmpty[K, V; Cap: static int; ccProd: static PinScopeCardinality;
             ccCons: static PinScopeCardinality;
             Tag: TableWriterTag | TableReaderTag](
    ep: Bound[(K, V), Tag, BTable[K, V, Cap, ccProd, ccCons]]): bool {.inline,
    notATransition.}
```

### `isFull`

```nim
proc isFull[K, V; Cap: static int; ccProd: static PinScopeCardinality;
            ccCons: static PinScopeCardinality;
            Tag: TableWriterTag | TableReaderTag](
    ep: Bound[(K, V), Tag, BTable[K, V, Cap, ccProd, ccCons]]): bool {.inline,
    notATransition.}
```

### `tryPut`

```nim
proc tryPut[K, V; Cap: static int; ccProd: static PinScopeCardinality;
            ccCons: static PinScopeCardinality](
    ep: Bound[(K, V), TableReaderTag, BTable[K, V, Cap, ccProd, ccCons]];
    key: sink K; val: sink V): bool {.error: "Cannot call \'tryPut\' on a read-only BTable endpoint (Bound[(K, V), TableReaderTag, BTable[...]]). Use a writer endpoint (getWriter / withBoundWriter) to mutate entries.",
                                      notATransition.}
```

### `put`

```nim
proc put[K, V; Cap: static int; ccProd: static PinScopeCardinality;
         ccCons: static PinScopeCardinality](
    ep: Bound[(K, V), TableReaderTag, BTable[K, V, Cap, ccProd, ccCons]];
    key: sink K; val: sink V): bool {.error: "Cannot call \'put\' on a read-only BTable endpoint (Bound[(K, V), TableReaderTag, BTable[...]]). Use a writer endpoint (getWriter / withBoundWriter) to mutate entries.",
                                      notATransition.}
```

### `tryInsert`

```nim
proc tryInsert[K, V; Cap: static int; ccProd: static PinScopeCardinality;
               ccCons: static PinScopeCardinality](
    ep: Bound[(K, V), TableReaderTag, BTable[K, V, Cap, ccProd, ccCons]];
    key: sink K; val: sink V): bool {.error: "Cannot call \'tryInsert\' on a read-only BTable endpoint (Bound[(K, V), TableReaderTag, BTable[...]]). Use a writer endpoint (getWriter / withBoundWriter) to mutate entries.",
                                      notATransition.}
```

### `insert`

```nim
proc insert[K, V; Cap: static int; ccProd: static PinScopeCardinality;
            ccCons: static PinScopeCardinality](
    ep: Bound[(K, V), TableReaderTag, BTable[K, V, Cap, ccProd, ccCons]];
    key: sink K; val: sink V): bool {.error: "Cannot call \'insert\' on a read-only BTable endpoint (Bound[(K, V), TableReaderTag, BTable[...]]). Use a writer endpoint (getWriter / withBoundWriter) to mutate entries.",
                                      notATransition.}
```

### `remove`

```nim
proc remove[K, V; Cap: static int; ccProd: static PinScopeCardinality;
            ccCons: static PinScopeCardinality](
    ep: Bound[(K, V), TableReaderTag, BTable[K, V, Cap, ccProd, ccCons]]; key: K): bool {.error: "Cannot call \'remove\' on a read-only BTable endpoint (Bound[(K, V), TableReaderTag, BTable[...]]). Use a writer endpoint (getWriter / withBoundWriter) to mutate entries.",
    notATransition.}
```

### `del`

```nim
proc del[K, V; Cap: static int; ccProd: static PinScopeCardinality;
         ccCons: static PinScopeCardinality](
    ep: Bound[(K, V), TableReaderTag, BTable[K, V, Cap, ccProd, ccCons]]; key: K): bool {.error: "Cannot call \'del\' on a read-only BTable endpoint (Bound[(K, V), TableReaderTag, BTable[...]]). Use a writer endpoint (getWriter / withBoundWriter) to mutate entries.",
    notATransition.}
```

### `take`

```nim
proc take[K, V; Cap: static int; ccProd: static PinScopeCardinality;
          ccCons: static PinScopeCardinality](
    ep: Bound[(K, V), TableReaderTag, BTable[K, V, Cap, ccProd, ccCons]]; key: K): Option[
    V] {.error: "Cannot call \'take\' on a read-only BTable endpoint (Bound[(K, V), TableReaderTag, BTable[...]]). Use a writer endpoint (getWriter / withBoundWriter) to mutate entries.",
         notATransition.}
```

### `clear`

```nim
proc clear[K, V; Cap: static int; ccProd: static PinScopeCardinality;
           ccCons: static PinScopeCardinality](
    ep: Bound[(K, V), TableReaderTag, BTable[K, V, Cap, ccProd, ccCons]]) {.error: "Cannot call \'clear\' on a read-only BTable endpoint (Bound[(K, V), TableReaderTag, BTable[...]]). Use a writer endpoint (getWriter / withBoundWriter) to mutate entries.",
    notATransition.}
```

### `put`

```nim
proc put[K, V; Cap: static int; ccProd: static PinScopeCardinality;
         ccCons: static PinScopeCardinality; Tag](
    ep: Unbound[(K, V), Tag, BTable[K, V, Cap, ccProd, ccCons]]; key: sink K;
    val: sink V): bool {.error: "Cannot call \'put\' on an Unbound BTable endpoint. Bind the endpoint to the current thread first via `bindToThread(ep)` or `withBoundWriter`.",
                         notATransition.}
```

### `get`

```nim
proc get[K, V; Cap: static int; ccProd: static PinScopeCardinality;
         ccCons: static PinScopeCardinality; Tag](
    ep: Unbound[(K, V), Tag, BTable[K, V, Cap, ccProd, ccCons]]; key: K): Option[
    V] {.error: "Cannot call \'get\' on an Unbound BTable endpoint. Bind the endpoint to the current thread first via `bindToThread(ep)` or `withBoundReader`.",
         notATransition.}
```


## Macros

### `match`

```nim
macro match[K; V; Cap: static int; ccProd: static PinScopeCardinality;
            ccCons: static PinScopeCardinality](
    value: BTableLifecycleStates[K, V, Cap, ccProd, ccCons]; arms: untyped): untyped
```

Single-target pattern match on states of typestate 'BTableLifecycle'; rewrites to <tt class="docutils literal"><span class="pre"><span class="Keyword">block</span><span class="Punctuation">:</span> <span class="Keyword">let</span> <span class="Keyword">bind</span> <span class="Operator">=</span> <span class="Identifier">move</span><span class="Punctuation">(</span><span class="Identifier">value</span><span class="Punctuation">)</span><span class="Punctuation">;</span> <span class="Identifier">body</span></span></tt>. Syntax is <tt class="docutils literal"><span class="pre"><span class="Operator">&lt;</span><span class="Identifier">StateName</span><span class="Operator">&gt;</span><span class="Punctuation">(</span><span class="Keyword">bind</span><span class="Punctuation">)</span><span class="Punctuation">:</span></span></tt>, with exactly one arm.

### `BTableLifecycle`

```nim
macro BTableLifecycle(initial`gensym0: untyped; typeDef`gensym0: untyped): untyped
```

Typestate-attachment pragma (auto-generated; see §3.7 of the v0.9.0 design doc). Apply to a type declaration to bind the type to this typestate with <tt class="docutils literal"><span class="pre"><span class="Identifier">initial</span></span></tt> as the starting state. Validates TA-002..TA-004 at compile time and populates <tt class="docutils literal"><span class="pre"><span class="Identifier">typestateAttachments</span></span></tt>.

