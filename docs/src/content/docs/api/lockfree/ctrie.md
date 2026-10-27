---
title: "lockfree/ctrie"
description: "API reference for lockfree/ctrie"
---

<h1><a class="toc-backref" id="concurrency-topologycolon-mpmc-lockminusfree-concurrent-hash-trie-with-o-1-waitminusfree-snapshots-nimctrie-k-v" href="#concurrency-topologycolon-mpmc-lockminusfree-concurrent-hash-trie-with-o-1-waitminusfree-snapshots-nimctrie-k-v">Concurrency Topology: MPMC Lock-Free Concurrent Hash Trie with O(1) Wait-Free Snapshots (<tt class="docutils literal"><span class="pre"><span class="Identifier">Ctrie</span><span class="Punctuation">[</span><span class="Identifier">K</span><span class="Punctuation">,</span> <span class="Identifier">V</span><span class="Punctuation">]</span></span></tt>)</a></h1><table border="1" class="docutils"><tr><th>Dimension</th><th>Architectural Specification</th></tr>
<tr><td><strong>Topologies</strong></td><td>MPMC (Multi-Producer Multi-Consumer Concurrent Associative Map)</td></tr>
<tr><td><strong>Algorithm</strong></td><td>Aleksandar Prokopec Concurrent Hash Trie (Ctrie) with HAMT 32-way Branch</td></tr>
<tr><td><strong>Snapshots</strong></td><td>O(1) Time, O(1) Work Wait-Free Point-in-Time Generational Snapshots</td></tr>
<tr><td><strong>Tree Depth</strong></td><td>Maximum 7 levels for 32-bit hashes, 13 levels for 64-bit hashes (5 bits)</td></tr>
<tr><td><strong>Key Ordering</strong></td><td>Hash-partitioned HAMT (unordered key space; sorted iteration via snap)</td></tr>
<tr><td><strong>Coordination</strong></td><td>Atomic MainNode pointers on INodes, CAS compression and GCopy</td></tr>
<tr><td><strong>Payload Storage</strong></td><td>Type-agnostic pointer-indirection box (<tt class="docutils literal"><span class="pre"><span class="Identifier">VBox</span><span class="Punctuation">[</span><span class="Identifier">V</span><span class="Punctuation">]</span></span></tt>) under ARC/ORC</td></tr>
<tr><td><strong>Collision Strategy</strong></td><td>Immutable persistent collision lists (<tt class="docutils literal"><span class="pre"><span class="Identifier">LNode</span><span class="Punctuation">[</span><span class="Identifier">K</span><span class="Punctuation">,</span> <span class="Identifier">V</span><span class="Punctuation">]</span></span></tt>)</td></tr>
<tr><td><strong>Progress Guarantees</strong></td><td>Lookups: Wait-Free Population; Mutations: Lock-Free; Snapshots: Wait-Free</td></tr>
<tr><td><strong>SMR Substrate</strong></td><td>In-tree Debra SMR (NEBR, <tt class="docutils literal"><span class="pre"><span class="Identifier">src</span><span class="Operator">/</span><span class="Identifier">lockfree</span><span class="Operator">/</span><span class="Identifier">smr</span><span class="Operator">/</span><span class="Identifier">nebr</span><span class="Operator">/</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">MaxThreads</span></span></tt> capacity)</td></tr>
<tr><td><strong>Cache Alignment</strong></td><td>INode and Root pointers aligned to <tt class="docutils literal"><span class="pre"><span class="Identifier">CacheLineBytes</span></span></tt> (64/128-byte boundary)</td></tr>
</table>
<h2><a class="toc-backref" id="concurrency-topologycolon-mpmc-lockminusfree-concurrent-hash-trie-with-o-1-waitminusfree-snapshots-nimctrie-k-v-overview" href="#concurrency-topologycolon-mpmc-lockminusfree-concurrent-hash-trie-with-o-1-waitminusfree-snapshots-nimctrie-k-v-overview">Overview</a></h2><p><tt class="docutils literal"><span class="pre"><span class="Identifier">Ctrie</span><span class="Punctuation">[</span><span class="Identifier">K</span><span class="Punctuation">,</span> <span class="Identifier">V</span><span class="Punctuation">]</span></span></tt> is an MPMC lock-free concurrent hash array mapped trie (HAMT) implementing Aleksandar Prokopec's Ctrie algorithm with generational stamping, non-blocking lazy copy-on-write (<tt class="docutils literal"><span class="pre"><span class="Identifier">GCopy</span></span></tt>), bottom-up tombstone contraction, and in-tree Debra Safe Memory Reclamation (SMR).</p>
<p>Key capabilities:</p>
<ul class="simple"><li><strong>O(1) Wait-Free Snapshots</strong>: <tt class="docutils literal"><span class="pre"><span class="Identifier">snapshot</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt> creates an isolated point-in-time read-only view in O(1) time and work by atomically swinging the root to a new generation.</li>
<li><strong>Wait-Free Lookups</strong>: <tt class="docutils literal"><span class="pre"><span class="Identifier">get</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">contains</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Punctuation">[</span><span class="Punctuation">]</span></span></tt> traverse at most 7 levels without CAS.</li>
<li><strong>Lock-Free Mutations</strong>: <tt class="docutils literal"><span class="pre"><span class="Identifier">put</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">delete</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">computeIfAbsent</span></span></tt> use per-node CAS and lazy generational expansion without global locks.</li>
<li><strong>Memory Reclaiming</strong>: Nodes and displaced values are safely deferred-reclaimed via Debra SMR.</li>
</ul>


## Types

### `Generation`

```nim
Generation = object
  id*: uint64
  rc*: Atomic[int]
```

### `VBox`

```nim
VBox[V] = object
  rc*: Atomic[int]
  val*: V
```

### `MainNodeKind`

```nim
MainNodeKind = enum
  mnkCNode,                 ## Compressed Hash Array Node
  mnkTNode,                 ## Tomb Node (Contracted singleton)
  mnkLNode                   ## Collision List Node
```

### `MainNode`

```nim
MainNode[K; V] = object
  kind*: MainNodeKind
```

### `BranchNode`

```nim
BranchNode[K; V] = distinct uint
```

### `SNode`

```nim
SNode[K; V] = object
  key*: K
  vbox*: ptr VBox[V]
  hash*: uint32
```

### `CNode`

```nim
CNode[K; V] = object
  kind*: MainNodeKind
  bmp*: uint32
  gen*: ptr Generation
  csize*: int
  children*: UncheckedArray[BranchNode[K, V]]
```

### `TNode`

```nim
TNode[K; V] = object
  kind*: MainNodeKind
  snode*: ptr SNode[K, V]
```

### `LNodeEntry`

```nim
LNodeEntry[K; V] = object
  key*: K
  vbox*: ptr VBox[V]
  next*: ptr LNodeEntry[K, V]
```

### `LNode`

```nim
LNode[K; V] = object
  kind*: MainNodeKind
  hash*: uint32
  head*: ptr LNodeEntry[K, V]
```

### `INode`

```nim
INode[K; V] = object
  main*: Atomic[ptr MainNode[K, V]]
  gen*: ptr Generation
  rc*: Atomic[int]
```

### `CtrieCore`

```nim
CtrieCore[K; V; MaxThreads] = object
  id*: uint64
  root*: Atomic[ptr INode[K, V]]
  manager*: ptr DebraManager[MaxThreads, ccMulti]
  count*: Atomic[int]
  rc*: Atomic[int]
  ownsManager*: bool
```

### `Ctrie`

```nim
Ctrie[K; V; MaxThreads] = object
  core*: ptr CtrieCore[K, V, MaxThreads]
```

<h1><a class="toc-backref" id="concurrency-topologycolon-mpmc-multiminusproducer-multiminusconsumer" href="#concurrency-topologycolon-mpmc-multiminusproducer-multiminusconsumer">Concurrency Topology: MPMC (Multi-Producer Multi-Consumer)</a></h1><p>Aleksandar Prokopec Lock-Free Concurrent Hash Array Mapped Trie with O(1) Snapshots.</p>

### `Table`

```nim
Table[K; V; MaxThreads] = Ctrie[K, V, MaxThreads]
```

### `ConcurrentTable`

```nim
ConcurrentTable[K; V; MaxThreads] = Ctrie[K, V, MaxThreads]
```

### `ConcurrentMap`

```nim
ConcurrentMap[K; V; MaxThreads] = Ctrie[K, V, MaxThreads]
```

### `ConcurrentTrie`

```nim
ConcurrentTrie[K; V; MaxThreads] = Ctrie[K, V, MaxThreads]
```

### `Snapshot`

```nim
Snapshot[K; V; MaxThreads] = object
  core*: ptr CtrieCore[K, V, MaxThreads]
  root*: ptr INode[K, V]
```

<h1><a class="toc-backref" id="concurrency-topologycolon-snapshot-o-1-waitminusfree-pointminusinminustime-generation" href="#concurrency-topologycolon-snapshot-o-1-waitminusfree-pointminusinminustime-generation">Concurrency Topology: Snapshot (O(1) Wait-Free Point-in-Time Generation)</a></h1><p>Thread-safe, wait-free immutable view of a Ctrie generation.</p>


## Constants

### `DefaultMaxThreads`

```nim
DefaultMaxThreads = 64
```


## Procedures & Functions

### `getHash`

```nim
proc getHash[K](key: K): uint32 {.inline.}
```

### `getOrRegisterHandle`

```nim
proc getOrRegisterHandle[K, V; MaxThreads: static int](
    self: Ctrie[K, V, MaxThreads]): ThreadHandle[MaxThreads, ccMulti] {.inline.}
```

### `getOrRegisterHandle`

```nim
proc getOrRegisterHandle[K, V; MaxThreads: static int](
    snap: Snapshot[K, V, MaxThreads]): ThreadHandle[MaxThreads, ccMulti] {.
    inline.}
```

### `get`

```nim
proc get[K, V; MaxThreads: static int](self: Ctrie[K, V, MaxThreads]; key: K): Option[
    V]
```

Retrieves the value mapped to <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt>, or <tt class="docutils literal"><span class="pre"><span class="Identifier">none</span><span class="Punctuation">(</span><span class="Identifier">V</span><span class="Punctuation">)</span></span></tt> if absent. Wait-free.

### `contains`

```nim
proc contains[K, V; MaxThreads: static int](self: Ctrie[K, V, MaxThreads];
    key: K): bool {.inline.}
```

### `hasKey`

```nim
proc hasKey[K, V; MaxThreads: static int](self: Ctrie[K, V, MaxThreads]; key: K): bool {.
    inline.}
```

### ``[]``

```nim
proc `[]`[K, V; MaxThreads: static int](self: Ctrie[K, V, MaxThreads]; key: K): V {.
    inline.}
```

### `put`

```nim
proc put[K, V; MaxThreads: static int](self: Ctrie[K, V, MaxThreads]; key: K;
                                       val: V): Option[V] {.discardable.}
```

Inserts or updates <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> with <tt class="docutils literal"><span class="pre"><span class="Identifier">val</span></span></tt>. Returns previous value if replaced. Lock-free.

### `putIfAbsent`

```nim
proc putIfAbsent[K, V; MaxThreads: static int](self: Ctrie[K, V, MaxThreads];
    key: K; val: V): Option[V] {.discardable.}
```

Inserts <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> with <tt class="docutils literal"><span class="pre"><span class="Identifier">val</span></span></tt> if not already present. Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">none</span><span class="Punctuation">(</span><span class="Identifier">V</span><span class="Punctuation">)</span></span></tt> if inserted, or <tt class="docutils literal"><span class="pre"><span class="Identifier">some</span><span class="Punctuation">(</span><span class="Identifier">existingVal</span><span class="Punctuation">)</span></span></tt> if already present. Lock-free.

### ``[]=``

```nim
proc `[]=`[K, V; MaxThreads: static int](self: Ctrie[K, V, MaxThreads]; key: K;
    val: V) {.inline.}
```

### `delete`

```nim
proc delete[K, V; MaxThreads: static int](self: Ctrie[K, V, MaxThreads]; key: K): Option[
    V] {.discardable.}
```

Removes <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> from the Ctrie, executing bottom-up contraction if appropriate. Lock-free.

### `del`

```nim
proc del[K, V; MaxThreads: static int](self: Ctrie[K, V, MaxThreads]; key: K) {.
    inline.}
```

### `computeIfAbsent`

```nim
proc computeIfAbsent[K, V; MaxThreads: static int](
    self: Ctrie[K, V, MaxThreads]; key: K;
    computeFn: proc (k: K): V {.closure, gcsafe.}): V
```

Returns the existing value mapped to <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt>, or atomically computes and inserts it.

### `computeIfAbsent`

```nim
proc computeIfAbsent[K, V; MaxThreads: static int](
    self: Ctrie[K, V, MaxThreads]; key: K;
    computeFn: proc (): V {.closure, gcsafe.}): V {.inline.}
```

Parameterless computation overload for <tt class="docutils literal"><span class="pre"><span class="Identifier">computeIfAbsent</span></span></tt>.

### `atomicUpdate`

```nim
proc atomicUpdate[K, V; MaxThreads: static int](self: Ctrie[K, V, MaxThreads];
    key: K; updateProc: proc (v: V): V {.closure, gcsafe.}): Option[V] {.
    discardable.}
```

Atomically updates the value associated with <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> using <tt class="docutils literal"><span class="pre"><span class="Identifier">updateProc</span></span></tt>. If <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> is absent, returns <tt class="docutils literal"><span class="pre"><span class="Identifier">none</span><span class="Punctuation">(</span><span class="Identifier">V</span><span class="Punctuation">)</span></span></tt>. If <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> is present, replaces <tt class="docutils literal"><span class="pre"><span class="Identifier">oldVal</span></span></tt> with <tt class="docutils literal"><span class="pre"><span class="Identifier">newVal</span> <span class="Operator">=</span> <span class="Identifier">updateProc</span><span class="Punctuation">(</span><span class="Identifier">oldVal</span><span class="Punctuation">)</span></span></tt> and returns <tt class="docutils literal"><span class="pre"><span class="Identifier">some</span><span class="Punctuation">(</span><span class="Identifier">newVal</span><span class="Punctuation">)</span></span></tt>. Lock-free.

### `upsert`

```nim
proc upsert[K, V; MaxThreads: static int](self: Ctrie[K, V, MaxThreads]; key: K;
    insertVal: V; updateProc: proc (oldVal: V): V {.closure, gcsafe.}): V {.
    discardable.}
```

Atomically inserts <tt class="docutils literal"><span class="pre"><span class="Identifier">insertVal</span></span></tt> if <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> is absent, or updates <tt class="docutils literal"><span class="pre"><span class="Identifier">key</span></span></tt> with <tt class="docutils literal"><span class="pre"><span class="Identifier">updateProc</span><span class="Punctuation">(</span><span class="Identifier">oldVal</span><span class="Punctuation">)</span></span></tt> if present. Returns the settled value. Lock-free.

### `len`

```nim
proc len[K, V; MaxThreads: static int](self: Ctrie[K, V, MaxThreads]): int {.
    inline.}
```

### `isEmpty`

```nim
proc isEmpty[K, V; MaxThreads: static int](self: Ctrie[K, V, MaxThreads]): bool {.
    inline.}
```

### `snapshot`

```nim
proc snapshot[K, V; MaxThreads: static int](self: Ctrie[K, V, MaxThreads]): Snapshot[
    K, V, MaxThreads]
```

Atomically creates an O(1) wait-free point-in-time generation snapshot.

### `get`

```nim
proc get[K, V; MaxThreads: static int](snap: Snapshot[K, V, MaxThreads]; key: K): Option[
    V]
```

Wait-free read from snapshot generation.

### `contains`

```nim
proc contains[K, V; MaxThreads: static int](snap: Snapshot[K, V, MaxThreads];
    key: K): bool {.inline.}
```

### `len`

```nim
proc len[K, V; MaxThreads: static int](snap: Snapshot[K, V, MaxThreads]): int
```

### `isEmpty`

```nim
proc isEmpty[K, V; MaxThreads: static int](snap: Snapshot[K, V, MaxThreads]): bool {.
    inline.}
```

### `snapshotPairs`

```nim
proc snapshotPairs[K, V; MaxThreads: static int](
    snap: Snapshot[K, V, MaxThreads]): seq[(K, V)]
```

Returns a materialized sequence of (key, value) pairs from this snapshot view.

### `snapshotPairs`

```nim
proc snapshotPairs[K, V; MaxThreads: static int](self: Ctrie[K, V, MaxThreads]): seq[
    (K, V)]
```

Returns a materialized sequence of (key, value) pairs from an O(1) wait-free snapshot.

### `snapshotKeys`

```nim
proc snapshotKeys[K, V; MaxThreads: static int](snap: Snapshot[K, V, MaxThreads]): seq[
    K]
```

Returns a materialized sequence of keys from this snapshot view.

### `snapshotKeys`

```nim
proc snapshotKeys[K, V; MaxThreads: static int](self: Ctrie[K, V, MaxThreads]): seq[
    K]
```

Returns a materialized sequence of keys from an O(1) wait-free snapshot.

### `snapshotValues`

```nim
proc snapshotValues[K, V; MaxThreads: static int](
    snap: Snapshot[K, V, MaxThreads]): seq[V]
```

Returns a materialized sequence of values from this snapshot view.

### `snapshotValues`

```nim
proc snapshotValues[K, V; MaxThreads: static int](self: Ctrie[K, V, MaxThreads]): seq[
    V]
```

Returns a materialized sequence of values from an O(1) wait-free snapshot.

### ``=copy``

```nim
proc `=copy`[K, V; MaxThreads: static int](dest: var Ctrie[K, V, MaxThreads];
    src: Ctrie[K, V, MaxThreads])
```

### ``=destroy``

```nim
proc `=destroy`[K, V; MaxThreads: static int](self: var Ctrie[K, V, MaxThreads]) {.
    raises: [].}
```

### ``=copy``

```nim
proc `=copy`[K, V; MaxThreads: static int](dest: var Snapshot[K, V, MaxThreads];
    src: Snapshot[K, V, MaxThreads])
```

### ``=destroy``

```nim
proc `=destroy`[K, V; MaxThreads: static int](
    self: var Snapshot[K, V, MaxThreads]) {.raises: [].}
```

### `initCtrie`

```nim
proc initCtrie[K, V](capacityHint: int = 16;
                     maxThreads: static int = DefaultMaxThreads): Ctrie[K, V,
    maxThreads]
```

Initializes a new concurrent lock-free Ctrie<a class="reference internal" href="#K, V">K, V</a>.

### `getOrDefault`

```nim
proc getOrDefault[K, V; MaxThreads: static int](self: Ctrie[K, V, MaxThreads];
    key: K; defaultVal: V): V {.inline.}
```

### `getOrDefault`

```nim
proc getOrDefault[K, V; MaxThreads: static int](
    snap: Snapshot[K, V, MaxThreads]; key: K; defaultVal: V): V {.inline.}
```

### `initTable`

```nim
proc initTable[K, V](capacityHint: int = 16;
                     maxThreads: static int = DefaultMaxThreads): Table[K, V,
    maxThreads] {.inline.}
```

### `initConcurrentTable`

```nim
proc initConcurrentTable[K, V](capacityHint: int = 16;
                               maxThreads: static int = DefaultMaxThreads): ConcurrentTable[
    K, V, maxThreads] {.inline.}
```

### `initConcurrentMap`

```nim
proc initConcurrentMap[K, V](capacityHint: int = 16): ConcurrentMap[K, V, 64] {.
    inline.}
```

### `initConcurrentTrie`

```nim
proc initConcurrentTrie[K, V](capacityHint: int = 16): ConcurrentTrie[K, V, 64] {.
    inline.}
```

### `newCtrie`

```nim
proc newCtrie[K, V](capacityHint: int = 16;
                    maxThreads: static int = DefaultMaxThreads): Ctrie[K, V,
    maxThreads] {.inline.}
```

### `newTable`

```nim
proc newTable[K, V](capacityHint: int = 16;
                    maxThreads: static int = DefaultMaxThreads): Table[K, V,
    maxThreads] {.inline.}
```

### `newConcurrentTable`

```nim
proc newConcurrentTable[K, V](capacityHint: int = 16;
                              maxThreads: static int = DefaultMaxThreads): ConcurrentTable[
    K, V, maxThreads] {.inline.}
```

### `newConcurrentMap`

```nim
proc newConcurrentMap[K, V](capacityHint: int = 16): ConcurrentMap[K, V, 64] {.
    inline.}
```

### `newConcurrentTrie`

```nim
proc newConcurrentTrie[K, V](capacityHint: int = 16): ConcurrentTrie[K, V, 64] {.
    inline.}
```


## Templates

### `isSNode`

```nim
template isSNode[K, V](b: BranchNode[K, V]): bool
```

### `isINode`

```nim
template isINode[K, V](b: BranchNode[K, V]): bool
```

### `toSNode`

```nim
template toSNode[K, V](b: BranchNode[K, V]): ptr SNode[K, V]
```

### `toINode`

```nim
template toINode[K, V](b: BranchNode[K, V]): ptr INode[K, V]
```

### `makeBranchNode`

```nim
template makeBranchNode[K, V](p: ptr SNode[K, V]): BranchNode[K, V]
```

### `makeBranchNode`

```nim
template makeBranchNode[K, V](p: ptr INode[K, V]): BranchNode[K, V]
```


## Iterators

### `pairs`

```nim
iterator pairs[K, V; MaxThreads: static int](snap: Snapshot[K, V, MaxThreads]): (
    K, V)
```

Iterates across all (key, val) entries in this snapshot view.

### `keys`

```nim
iterator keys[K, V; MaxThreads: static int](snap: Snapshot[K, V, MaxThreads]): K
```

### `values`

```nim
iterator values[K, V; MaxThreads: static int](snap: Snapshot[K, V, MaxThreads]): V
```

### `pairs`

```nim
iterator pairs[K, V; MaxThreads: static int](self: Ctrie[K, V, MaxThreads]): (K,
    V)
```

Snapshot-isolated linearizable iteration over the active Ctrie.

### `keys`

```nim
iterator keys[K, V; MaxThreads: static int](self: Ctrie[K, V, MaxThreads]): K
```

### `values`

```nim
iterator values[K, V; MaxThreads: static int](self: Ctrie[K, V, MaxThreads]): V
```

