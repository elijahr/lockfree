---
title: "lockfree/skiplist"
description: "API reference for lockfree/skiplist"
---

<h1><a class="toc-backref" id="concurrency-topologycolon-mpmc-lockminusfree-ordered-keyminusvalue-map-nimskiplistmap" href="#concurrency-topologycolon-mpmc-lockminusfree-ordered-keyminusvalue-map-nimskiplistmap">Concurrency Topology: MPMC Lock-Free Ordered Key-Value Map (<tt class="docutils literal"><span class="pre"><span class="Identifier">SkipListMap</span></span></tt>)</a></h1><table border="1" class="docutils"><tr><th>Dimension</th><th>Specification</th></tr>
<tr><td><strong>Topologies</strong></td><td>MPMC (Multi-Producer Multi-Consumer Concurrent Key-Value Map)</td></tr>
<tr><td><strong>Algorithm</strong></td><td>Fraser / Herlihy Lock-Free SkipList with Harris Logical Marking</td></tr>
<tr><td><strong>Ordering</strong></td><td>Strict Total Key Order (ascending level-0 traversal)</td></tr>
<tr><td><strong>Capacity</strong></td><td>Dynamically Unbounded</td></tr>
<tr><td><strong>Coordination</strong></td><td>Atomic marked next-pointers, CAS insertion/physical unlinking</td></tr>
<tr><td><strong>Payload Encoding</strong></td><td>Type-agnostic pointer-indirection box (<tt class="docutils literal"><span class="pre"><span class="Identifier">VBox</span><span class="Punctuation">[</span><span class="Identifier">V</span><span class="Punctuation">]</span></span></tt>)</td></tr>
<tr><td><strong>Progress Guarantee</strong></td><td>Lock-Free (Put, Delete) / Wait-Free Population (Get, Contains)</td></tr>
<tr><td><strong>Memory Reclamation</strong></td><td>Debra SMR (Epoch-Based Reclamation, <tt class="docutils literal"><span class="pre"><span class="Identifier">MaxThreads</span></span></tt> capacity)</td></tr>
</table>
<h2><a class="toc-backref" id="concurrency-topologycolon-mpmc-lockminusfree-ordered-keyminusvalue-map-nimskiplistmap-overview" href="#concurrency-topologycolon-mpmc-lockminusfree-ordered-keyminusvalue-map-nimskiplistmap-overview">Overview</a></h2><p><tt class="docutils literal"><span class="pre"><span class="Identifier">SkipListMap</span><span class="Punctuation">[</span><span class="Identifier">K</span><span class="Punctuation">,</span> <span class="Identifier">V</span><span class="Punctuation">]</span></span></tt> is an MPMC lock-free ordered associative table implementing Keir Fraser's and Maurice Herlihy's lock-free skip list algorithm with Harris-style logical deletion marking and Debra Safe Memory Reclamation (SMR).</p>
<p>It maintains keys in strictly sorted order at level 0, supporting concurrent insertions (<tt class="docutils literal"><span class="pre"><span class="Identifier">put</span></span></tt>), lookups (<tt class="docutils literal"><span class="pre"><span class="Identifier">get</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">contains</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Punctuation">[</span><span class="Punctuation">]</span></span></tt>), removals (<tt class="docutils literal"><span class="pre"><span class="Identifier">delete</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">del</span></span></tt>), atomic conditional updates (<tt class="docutils literal"><span class="pre"><span class="Identifier">computeIfAbsent</span></span></tt>), and ordered range traversals (<tt class="docutils literal"><span class="pre"><span class="Identifier">pairs</span></span></tt>).</p>


## Types

### `SkipListMap`

```nim
SkipListMap[K; V; MaxThreads; MaxLevel] = object
  core*: ptr SkipListCore[K, V, MaxThreads, MaxLevel]
```

### `SortedTable`

```nim
SortedTable[K; V; MaxThreads; MaxLevel] = SkipListMap[K, V, MaxThreads, MaxLevel]
```

### `OrderedTable`

```nim
OrderedTable[K; V; MaxThreads; MaxLevel] = SkipListMap[K, V, MaxThreads,
    MaxLevel]
```

### `ConcurrentSortedTable`

```nim
ConcurrentSortedTable[K; V; MaxThreads; MaxLevel] = SkipListMap[K, V,
    MaxThreads, MaxLevel]
```


## Constants

### `DefaultMaxThreads`

```nim
DefaultMaxThreads = 64
```

### `DefaultMaxLevel`

```nim
DefaultMaxLevel = 16
```


## Procedures & Functions

### `getOrRegisterHandle`

```nim
proc getOrRegisterHandle[K, V; MaxThreads, MaxLevel: static int](
    self: SkipListMap[K, V, MaxThreads, MaxLevel]): ThreadHandle[MaxThreads,
    ccMulti]
```

### `newSkipListMap`

```nim
proc newSkipListMap[K, V; MaxThreads: static int = DefaultMaxThreads;
                    MaxLevel: static int = DefaultMaxLevel](): SkipListMap[K, V,
    MaxThreads, MaxLevel]
```

Constructs a new empty <tt class="docutils literal"><span class="pre"><span class="Identifier">SkipListMap</span></span></tt> with a dedicated <tt class="docutils literal"><span class="pre"><span class="Identifier">DebraManager</span></span></tt>.

### `newSkipListMap`

```nim
proc newSkipListMap[K, V; MaxThreads: static int = DefaultMaxThreads;
                    MaxLevel: static int = DefaultMaxLevel](
    manager: ptr DebraManager[MaxThreads, ccMulti]): SkipListMap[K, V,
    MaxThreads, MaxLevel]
```

Constructs a new empty <tt class="docutils literal"><span class="pre"><span class="Identifier">SkipListMap</span></span></tt> sharing an external <tt class="docutils literal"><span class="pre"><span class="Identifier">DebraManager</span></span></tt>.

### `initSkipListMap`

```nim
proc initSkipListMap[K, V; MaxThreads: static int = DefaultMaxThreads;
                     MaxLevel: static int = DefaultMaxLevel](): SkipListMap[K,
    V, MaxThreads, MaxLevel] {.inline.}
```

### ``=destroy``

```nim
proc `=destroy`[K, V; MaxThreads, MaxLevel: static int](
    self: var SkipListMap[K, V, MaxThreads, MaxLevel]) {.gcsafe, raises: [].}
```

### ``=copy``

```nim
proc `=copy`[K, V; MaxThreads, MaxLevel: static int](
    dest: var SkipListMap[K, V, MaxThreads, MaxLevel];
    src: SkipListMap[K, V, MaxThreads, MaxLevel])
```

### `len`

```nim
proc len[K, V; MaxThreads, MaxLevel: static int](
    self: SkipListMap[K, V, MaxThreads, MaxLevel]): int {.inline.}
```

Returns the number of items currently in the map.

### `registerThread`

```nim
proc registerThread[K, V; MaxThreads, MaxLevel: static int](
    self: var SkipListMap[K, V, MaxThreads, MaxLevel]): ThreadHandle[MaxThreads,
    ccMulti] {.inline.}
```

Explicitly registers the calling thread with the map's Debra manager.

### `unregisterThread`

```nim
proc unregisterThread[K, V; MaxThreads, MaxLevel: static int](
    self: var SkipListMap[K, V, MaxThreads, MaxLevel];
    handle: ThreadHandle[MaxThreads, ccMulti]) {.inline.}
```

Unregisters the thread handle, releasing its slot in the Debra registry.

### `get`

```nim
proc get[K, V; MaxThreads, MaxLevel: static int](
    self: SkipListMap[K, V, MaxThreads, MaxLevel]; key: K;
    handle: ThreadHandle[MaxThreads, ccMulti]): Option[V]
```

Looks up <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> in the map using the provided thread handle. Wait-free population guarantee: does not perform CAS or mutate state.

### `get`

```nim
proc get[K, V; MaxThreads, MaxLevel: static int](
    self: SkipListMap[K, V, MaxThreads, MaxLevel]; key: K): Option[V] {.inline.}
```

Looks up <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> in the map using automatic thread registration.

### ``[]``

```nim
proc `[]`[K, V; MaxThreads, MaxLevel: static int](
    self: SkipListMap[K, V, MaxThreads, MaxLevel]; key: K): V {.inline.}
```

Returns the value associated with <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt>. Raises <tt class="docutils literal"><span class="pre"><span class="Identifier">KeyError</span></span></tt> if absent.

### `getOrDefault`

```nim
proc getOrDefault[K, V; MaxThreads, MaxLevel: static int](
    self: SkipListMap[K, V, MaxThreads, MaxLevel]; key: K;
    defaultVal: V = default(V)): V {.inline.}
```

Returns the value associated with <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt>, or <tt class="docutils literal"><span class="pre"><span class="Identifier">defaultVal</span></span></tt> if absent.

### `contains`

```nim
proc contains[K, V; MaxThreads, MaxLevel: static int](
    self: SkipListMap[K, V, MaxThreads, MaxLevel]; key: K;
    handle: ThreadHandle[MaxThreads, ccMulti]): bool {.inline.}
```

Returns true if <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> is present in the map.

### `contains`

```nim
proc contains[K, V; MaxThreads, MaxLevel: static int](
    self: SkipListMap[K, V, MaxThreads, MaxLevel]; key: K): bool {.inline.}
```

Returns true if <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> is present in the map (auto-dispatched thread handle).

### `hasKey`

```nim
proc hasKey[K, V; MaxThreads, MaxLevel: static int](
    self: SkipListMap[K, V, MaxThreads, MaxLevel]; key: K;
    handle: ThreadHandle[MaxThreads, ccMulti]): bool {.inline.}
```

Alias for <tt class="docutils literal"><span class="pre"><span class="Identifier">contains</span></span></tt>. Returns true if <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> is present in the map.

### `hasKey`

```nim
proc hasKey[K, V; MaxThreads, MaxLevel: static int](
    self: SkipListMap[K, V, MaxThreads, MaxLevel]; key: K): bool {.inline.}
```

Alias for <tt class="docutils literal"><span class="pre"><span class="Identifier">contains</span></span></tt>. Returns true if <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> is present in the map (auto-dispatched thread handle).

### `put`

```nim
proc put[K, V; MaxThreads, MaxLevel: static int](
    self: var SkipListMap[K, V, MaxThreads, MaxLevel]; key: K; val: V;
    handle: ThreadHandle[MaxThreads, ccMulti]): bool
```

Inserts or updates <tt class="docutils literal"><span class="pre"><span class="Punctuation">(</span><span class="Identifier">key</span><span class="Punctuation">,</span> <span class="Identifier">val</span><span class="Punctuation">)</span></span></tt>. Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt> if a new key was inserted, <tt class="docutils literal"><span class="pre"><span class="Identifier">false</span></span></tt> if an existing key was updated.

### `put`

```nim
proc put[K, V; MaxThreads, MaxLevel: static int](
    self: var SkipListMap[K, V, MaxThreads, MaxLevel]; key: K; val: V): bool {.
    inline.}
```

Inserts or updates <tt class="docutils literal"><span class="pre"><span class="Punctuation">(</span><span class="Identifier">key</span><span class="Punctuation">,</span> <span class="Identifier">val</span><span class="Punctuation">)</span></span></tt> using automatic thread registration.

### ``[]=``

```nim
proc `[]=`[K, V; MaxThreads, MaxLevel: static int](
    self: var SkipListMap[K, V, MaxThreads, MaxLevel]; key: K; val: V) {.inline.}
```

Table assignment syntax <tt class="docutils literal"><span class="pre"><span class="Identifier">map</span><span class="Punctuation">[</span><span class="Identifier">key</span><span class="Punctuation">]</span> <span class="Operator">=</span> <span class="Identifier">val</span></span></tt>.

### `delete`

```nim
proc delete[K, V; MaxThreads, MaxLevel: static int](
    self: var SkipListMap[K, V, MaxThreads, MaxLevel]; key: K;
    handle: ThreadHandle[MaxThreads, ccMulti]): bool
```

Logically marks and physically splices <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> out of the map. Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt> if <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> was found and removed, <tt class="docutils literal"><span class="pre"><span class="Identifier">false</span></span></tt> otherwise.

### `delete`

```nim
proc delete[K, V; MaxThreads, MaxLevel: static int](
    self: var SkipListMap[K, V, MaxThreads, MaxLevel]; key: K): bool {.inline.}
```

Deletes <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> using automatic thread registration.

### `del`

```nim
proc del[K, V; MaxThreads, MaxLevel: static int](
    self: var SkipListMap[K, V, MaxThreads, MaxLevel]; key: K) {.inline.}
```

Table deletion syntax <tt class="docutils literal"><span class="pre"><span class="Identifier">del</span><span class="Punctuation">(</span><span class="Identifier">map</span><span class="Punctuation">,</span> <span class="Identifier">key</span><span class="Punctuation">)</span></span></tt>.

### `computeIfAbsent`

```nim
proc computeIfAbsent[K, V; MaxThreads, MaxLevel: static int](
    self: var SkipListMap[K, V, MaxThreads, MaxLevel]; key: K;
    fn: proc (k: K): V {.closure, gcsafe.};
    handle: ThreadHandle[MaxThreads, ccMulti]): V
```

If <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> is not already associated with a value, attempts to compute its value using <tt class="docutils literal"><span class="pre"><span class="Identifier">fn</span><span class="Punctuation">(</span><span class="Identifier">key</span><span class="Punctuation">)</span></span></tt> and enters it into the map. Returns current value.

### `computeIfAbsent`

```nim
proc computeIfAbsent[K, V; MaxThreads, MaxLevel: static int](
    self: var SkipListMap[K, V, MaxThreads, MaxLevel]; key: K;
    fn: proc (k: K): V {.closure, gcsafe.}): V {.inline.}
```

### `computeIfAbsent`

```nim
proc computeIfAbsent[K, V; MaxThreads, MaxLevel: static int](
    self: var SkipListMap[K, V, MaxThreads, MaxLevel]; key: K;
    fn: proc (): V {.closure, gcsafe.}): V {.inline.}
```

### `atomicUpdate`

```nim
proc atomicUpdate[K, V; MaxThreads, MaxLevel: static int](
    self: var SkipListMap[K, V, MaxThreads, MaxLevel]; key: K;
    updateProc: proc (v: V): V {.closure, gcsafe.};
    handle: ThreadHandle[MaxThreads, ccMulti]): Option[V]
```

Atomically transforms an existing value associated with <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> via in-place CAS on <tt class="docutils literal"><span class="pre"><span class="Identifier">node</span><span class="Operator">.</span><span class="Identifier">valPtr</span></span></tt>. If <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> is absent, returns <tt class="docutils literal"><span class="pre"><span class="Identifier">none</span><span class="Punctuation">(</span><span class="Identifier">V</span><span class="Punctuation">)</span></span></tt>. If <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> is present, updates <tt class="docutils literal"><span class="pre"><span class="Identifier">val</span></span></tt> to <tt class="docutils literal"><span class="pre"><span class="Identifier">newVal</span> <span class="Operator">=</span> <span class="Identifier">updateProc</span><span class="Punctuation">(</span><span class="Identifier">oldVal</span><span class="Punctuation">)</span></span></tt> and returns <tt class="docutils literal"><span class="pre"><span class="Identifier">some</span><span class="Punctuation">(</span><span class="Identifier">newVal</span><span class="Punctuation">)</span></span></tt>. Lock-free, O(log N) search + O(1) in-place value CAS.

### `atomicUpdate`

```nim
proc atomicUpdate[K, V; MaxThreads, MaxLevel: static int](
    self: var SkipListMap[K, V, MaxThreads, MaxLevel]; key: K;
    updateProc: proc (v: V): V {.closure, gcsafe.}): Option[V] {.inline.}
```

### `upsert`

```nim
proc upsert[K, V; MaxThreads, MaxLevel: static int](
    self: var SkipListMap[K, V, MaxThreads, MaxLevel]; key: K; insertVal: V;
    updateProc: proc (oldVal: V): V {.closure, gcsafe.};
    handle: ThreadHandle[MaxThreads, ccMulti]): V
```

Atomically inserts <tt class="docutils literal"><span class="pre"><span class="Identifier">insertVal</span></span></tt> if <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> is absent, or updates <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> with <tt class="docutils literal"><span class="pre"><span class="Identifier">updateProc</span><span class="Punctuation">(</span><span class="Identifier">oldVal</span><span class="Punctuation">)</span></span></tt> via in-place CAS if present. Returns the settled value. Lock-free.

### `upsert`

```nim
proc upsert[K, V; MaxThreads, MaxLevel: static int](
    self: var SkipListMap[K, V, MaxThreads, MaxLevel]; key: K; insertVal: V;
    updateProc: proc (oldVal: V): V {.closure, gcsafe.}): V {.inline.}
```

### `snapshotPairs`

```nim
proc snapshotPairs[K, V; MaxThreads, MaxLevel: static int](
    self: SkipListMap[K, V, MaxThreads, MaxLevel];
    handle: ThreadHandle[MaxThreads, ccMulti]): seq[(K, V)]
```

Returns a point-in-time materialized sequence of all (key, value) pairs in strictly ascending key order under Debra SMR protection.

### `snapshotPairs`

```nim
proc snapshotPairs[K, V; MaxThreads, MaxLevel: static int](
    self: SkipListMap[K, V, MaxThreads, MaxLevel]): seq[(K, V)] {.inline.}
```

### `snapshotKeys`

```nim
proc snapshotKeys[K, V; MaxThreads, MaxLevel: static int](
    self: SkipListMap[K, V, MaxThreads, MaxLevel];
    handle: ThreadHandle[MaxThreads, ccMulti]): seq[K]
```

Returns a point-in-time materialized sequence of all keys in strictly ascending key order under Debra SMR protection.

### `snapshotKeys`

```nim
proc snapshotKeys[K, V; MaxThreads, MaxLevel: static int](
    self: SkipListMap[K, V, MaxThreads, MaxLevel]): seq[K] {.inline.}
```

### `snapshotValues`

```nim
proc snapshotValues[K, V; MaxThreads, MaxLevel: static int](
    self: SkipListMap[K, V, MaxThreads, MaxLevel];
    handle: ThreadHandle[MaxThreads, ccMulti]): seq[V]
```

Returns a point-in-time materialized sequence of all values in strictly ascending key order under Debra SMR protection.

### `snapshotValues`

```nim
proc snapshotValues[K, V; MaxThreads, MaxLevel: static int](
    self: SkipListMap[K, V, MaxThreads, MaxLevel]): seq[V] {.inline.}
```

### `newSortedTable`

```nim
proc newSortedTable[K, V; MaxThreads: static int = DefaultMaxThreads;
                    MaxLevel: static int = DefaultMaxLevel](): SortedTable[K, V,
    MaxThreads, MaxLevel] {.inline.}
```

Smart constructor for <tt class="docutils literal"><span class="pre"><span class="Identifier">SortedTable</span><span class="Punctuation">[</span><span class="Identifier">K</span><span class="Punctuation">,</span> <span class="Identifier">V</span><span class="Punctuation">]</span></span></tt>.

### `initSortedTable`

```nim
proc initSortedTable[K, V; MaxThreads: static int = DefaultMaxThreads;
                     MaxLevel: static int = DefaultMaxLevel](): SortedTable[K,
    V, MaxThreads, MaxLevel] {.inline.}
```

Initializer for <tt class="docutils literal"><span class="pre"><span class="Identifier">SortedTable</span><span class="Punctuation">[</span><span class="Identifier">K</span><span class="Punctuation">,</span> <span class="Identifier">V</span><span class="Punctuation">]</span></span></tt>.

### `newOrderedTable`

```nim
proc newOrderedTable[K, V; MaxThreads: static int = DefaultMaxThreads;
                     MaxLevel: static int = DefaultMaxLevel](): OrderedTable[K,
    V, MaxThreads, MaxLevel] {.inline.}
```

Smart constructor for <tt class="docutils literal"><span class="pre"><span class="Identifier">OrderedTable</span><span class="Punctuation">[</span><span class="Identifier">K</span><span class="Punctuation">,</span> <span class="Identifier">V</span><span class="Punctuation">]</span></span></tt>.

### `initOrderedTable`

```nim
proc initOrderedTable[K, V; MaxThreads: static int = DefaultMaxThreads;
                      MaxLevel: static int = DefaultMaxLevel](): OrderedTable[K,
    V, MaxThreads, MaxLevel] {.inline.}
```

Initializer for <tt class="docutils literal"><span class="pre"><span class="Identifier">OrderedTable</span><span class="Punctuation">[</span><span class="Identifier">K</span><span class="Punctuation">,</span> <span class="Identifier">V</span><span class="Punctuation">]</span></span></tt>.

### `newConcurrentSortedTable`

```nim
proc newConcurrentSortedTable[K, V; MaxThreads: static int = DefaultMaxThreads;
                              MaxLevel: static int = DefaultMaxLevel](): ConcurrentSortedTable[
    K, V, MaxThreads, MaxLevel] {.inline.}
```

Smart constructor for <tt class="docutils literal"><span class="pre"><span class="Identifier">ConcurrentSortedTable</span><span class="Punctuation">[</span><span class="Identifier">K</span><span class="Punctuation">,</span> <span class="Identifier">V</span><span class="Punctuation">]</span></span></tt>.

### `initConcurrentSortedTable`

```nim
proc initConcurrentSortedTable[K, V; MaxThreads: static int = DefaultMaxThreads;
                               MaxLevel: static int = DefaultMaxLevel](): ConcurrentSortedTable[
    K, V, MaxThreads, MaxLevel] {.inline.}
```

Initializer for <tt class="docutils literal"><span class="pre"><span class="Identifier">ConcurrentSortedTable</span><span class="Punctuation">[</span><span class="Identifier">K</span><span class="Punctuation">,</span> <span class="Identifier">V</span><span class="Punctuation">]</span></span></tt>.


## Iterators

### `pairs`

```nim
iterator pairs[K, V; MaxThreads, MaxLevel: static int](
    self: SkipListMap[K, V, MaxThreads, MaxLevel];
    handle: ThreadHandle[MaxThreads, ccMulti]): (K, V)
```

Iterates over all <tt class="docutils literal"><span class="pre"><span class="Punctuation">(</span><span class="Identifier">key</span><span class="Punctuation">,</span> <span class="Identifier">value</span><span class="Punctuation">)</span></span></tt> pairs in strictly ascending key order.

### `pairs`

```nim
iterator pairs[K, V; MaxThreads, MaxLevel: static int](
    self: SkipListMap[K, V, MaxThreads, MaxLevel]): (K, V)
```

Iterates over all <tt class="docutils literal"><span class="pre"><span class="Punctuation">(</span><span class="Identifier">key</span><span class="Punctuation">,</span> <span class="Identifier">value</span><span class="Punctuation">)</span></span></tt> pairs in strictly ascending key order (auto handle).

### `keys`

```nim
iterator keys[K, V; MaxThreads, MaxLevel: static int](
    self: SkipListMap[K, V, MaxThreads, MaxLevel]): K
```

Iterates over all keys in strictly ascending order.

### `values`

```nim
iterator values[K, V; MaxThreads, MaxLevel: static int](
    self: SkipListMap[K, V, MaxThreads, MaxLevel]): V
```

Iterates over all values in strictly ascending key order.

### `items`

```nim
iterator items[K, V; MaxThreads, MaxLevel: static int](
    self: SkipListMap[K, V, MaxThreads, MaxLevel]): (K, V)
```

Default iterator over key-value tuples.

