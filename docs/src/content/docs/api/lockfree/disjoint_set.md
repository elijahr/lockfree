---
title: "lockfree/disjoint_set"
description: "API reference for lockfree/disjoint_set"
---

=========================================================================== Concurrency Topology: Wait-Free / Lock-Free Concurrent Disjoint-Set (Union-Find / DSU — Anderson &amp; Woll 1991 / Jayanti &amp; Tarjan 2016)<hr />
<p>A preallocated, zero-SMR, zero-hot-path-allocation concurrent Disjoint-Set (Union-Find / DSU) data structure for parallel graph connectivity, Kruskal minimum spanning trees, connected-component labeling, and concurrent dependency-graph cycle detection / subgraph partitioning.</p>
<p>Key architectural properties:</p>
<ul class="simple"><li><strong>64-Bit Packed Slot Representation (`[rank: uint32 | parent: uint32]`)</strong>: Each element <tt class="docutils literal"><span class="pre"><span class="Identifier">i</span> <span class="Keyword">in</span> <span class="DecNumber">0</span> <span class="Operator">..&lt;</span> <span class="Identifier">size</span></span></tt> occupies a single <tt class="docutils literal"><span class="pre"><span class="Identifier">Atomic</span><span class="Punctuation">[</span><span class="Identifier">uint64</span><span class="Punctuation">]</span></span></tt> word in a contiguous 64-byte cache-line-aligned flat array (<tt class="docutils literal"><span class="pre"><span class="Identifier">slots</span></span></tt>). Packing both the 32-bit upper-bound tree rank and the 32-bit parent index into one 64-bit atomic word enables single-word <tt class="docutils literal"><span class="pre"><span class="Identifier">compareExchange</span></span></tt> to atomically verify root status (<tt class="docutils literal"><span class="pre"><span class="Identifier">parent</span> <span class="Operator">==</span> <span class="Identifier">i</span></span></tt>) and expected rank simultaneously.</li>
<li><strong>Wait-Free `find` with Atomic CAS Path Splitting / Halving</strong>: <tt class="docutils literal"><span class="pre"><span class="Identifier">find</span><span class="Punctuation">(</span><span class="Identifier">x</span><span class="Punctuation">)</span></span></tt> traverses parent pointers toward the set representative while performing one-shot non-blocking atomic CAS path splitting (<tt class="docutils literal"><span class="pre"><span class="Identifier">parent</span><span class="Punctuation">(</span><span class="Identifier">x</span><span class="Punctuation">)</span> <span class="Punctuation">:</span><span class="Operator">=</span> <span class="Identifier">parent</span><span class="Punctuation">(</span><span class="Identifier">parent</span><span class="Punctuation">(</span><span class="Identifier">x</span><span class="Punctuation">)</span><span class="Punctuation">)</span></span></tt>) that preserves <tt class="docutils literal"><span class="pre"><span class="Identifier">rank</span><span class="Punctuation">(</span><span class="Identifier">x</span><span class="Punctuation">)</span></span></tt>. Because parent pointers only advance toward strictly higher-rank (or deterministically higher-index) ancestors, the parent graph is a strict acyclic forest with height at most <tt class="docutils literal"><span class="pre"><span class="Identifier">floor</span><span class="Punctuation">(</span><span class="Identifier">log2</span><span class="Punctuation">(</span><span class="Identifier">size</span><span class="Punctuation">)</span><span class="Punctuation">)</span> <span class="Operator">+</span> <span class="DecNumber">1</span></span></tt> and amortized <tt class="docutils literal"><span class="pre"><span class="Identifier">O</span><span class="Punctuation">(</span><span class="Identifier">alpha</span><span class="Punctuation">(</span><span class="Identifier">size</span><span class="Punctuation">)</span><span class="Punctuation">)</span></span></tt> step complexity.</li>
<li><strong>Lock-Free Rank-Based `union` with Deterministic Tie-Breaking</strong>: <tt class="docutils literal"><span class="pre"><span class="Identifier">union</span><span class="Punctuation">(</span><span class="Identifier">x</span><span class="Punctuation">,</span> <span class="Identifier">y</span><span class="Punctuation">)</span></span></tt> locates root representatives <tt class="docutils literal"><span class="pre"><span class="Identifier">u</span> <span class="Operator">=</span> <span class="Identifier">find</span><span class="Punctuation">(</span><span class="Identifier">x</span><span class="Punctuation">)</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">v</span> <span class="Operator">=</span> <span class="Identifier">find</span><span class="Punctuation">(</span><span class="Identifier">y</span><span class="Punctuation">)</span></span></tt>. If <tt class="docutils literal"><span class="pre"><span class="Identifier">u</span> <span class="Operator">!=</span> <span class="Identifier">v</span></span></tt>, the lower-rank root is linked under the higher-rank root via atomic CAS. When <tt class="docutils literal"><span class="pre"><span class="Identifier">rank</span><span class="Punctuation">(</span><span class="Identifier">u</span><span class="Punctuation">)</span> <span class="Operator">==</span> <span class="Identifier">rank</span><span class="Punctuation">(</span><span class="Identifier">v</span><span class="Punctuation">)</span></span></tt>, ties are broken deterministically by element index (<tt class="docutils literal"><span class="pre"><span class="Identifier">min</span><span class="Punctuation">(</span><span class="Identifier">u</span><span class="Punctuation">,</span> <span class="Identifier">v</span><span class="Punctuation">)</span> <span class="Operator">-&gt;</span> <span class="Identifier">max</span><span class="Punctuation">(</span><span class="Identifier">u</span><span class="Punctuation">,</span> <span class="Identifier">v</span><span class="Punctuation">)</span></span></tt>), making concurrent cycle formation mathematically impossible without locks, followed by a best-effort atomic rank increment on the winning root and an atomic decrement of <tt class="docutils literal"><span class="pre"><span class="Identifier">setCount</span></span></tt>.</li>
<li><strong>Linearizable `sameSet(x, y)` (Anderson &amp; Woll Root Re-Verification)</strong>: When <tt class="docutils literal"><span class="pre"><span class="Identifier">u</span> <span class="Operator">=</span> <span class="Identifier">find</span><span class="Punctuation">(</span><span class="Identifier">x</span><span class="Punctuation">)</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">v</span> <span class="Operator">=</span> <span class="Identifier">find</span><span class="Punctuation">(</span><span class="Identifier">y</span><span class="Punctuation">)</span></span></tt> differ (<tt class="docutils literal"><span class="pre"><span class="Identifier">u</span> <span class="Operator">!=</span> <span class="Identifier">v</span></span></tt>), <tt class="docutils literal"><span class="pre"><span class="Identifier">sameSet</span></span></tt> re-reads <tt class="docutils literal"><span class="pre"><span class="Identifier">slots</span><span class="Punctuation">[</span><span class="Identifier">u</span><span class="Punctuation">]</span></span></tt> to verify <tt class="docutils literal"><span class="pre"><span class="Identifier">u</span></span></tt> was still a root after <tt class="docutils literal"><span class="pre"><span class="Identifier">find</span><span class="Punctuation">(</span><span class="Identifier">y</span><span class="Punctuation">)</span></span></tt> observed <tt class="docutils literal"><span class="pre"><span class="Identifier">v</span></span></tt>. If <tt class="docutils literal"><span class="pre"><span class="Identifier">u</span></span></tt> was concurrently linked during <tt class="docutils literal"><span class="pre"><span class="Identifier">find</span><span class="Punctuation">(</span><span class="Identifier">y</span><span class="Punctuation">)</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">sameSet</span></span></tt> retries, ensuring strict linearizability under concurrent <tt class="docutils literal"><span class="pre"><span class="Identifier">union</span></span></tt> operations.</li>
<li><strong>Zero SMR / Zero Dynamic Node Reclamation</strong>: All slots live in a single flat array for the lifetime of the <tt class="docutils literal"><span class="pre"><span class="Identifier">DisjointSet</span></span></tt>; no epoch-based reclamation (NEBR/DEBRA) or hazard pointers are required.</li>
</ul>


## Types

### `DisjointSetCore`

```nim
DisjointSetCore = object
  setCount* {.align: 128.}: Atomic[int]
  rc* {.align: 128.}: Atomic[int]
  size*: int
  slots*: ptr UncheckedArray[Atomic[uint64]]
```

### `DisjointSet`

```nim
DisjointSet = object
  core*: ptr DisjointSetCore
```

Wait-free / lock-free concurrent Disjoint-Set (Union-Find / DSU). Uses atomic reference counting on <tt class="docutils literal"><span class="pre"><span class="Identifier">core</span></span></tt> so instances can be safely moved, copied, or shared across threads by value or pointer.

### `UnionFind`

```nim
UnionFind = DisjointSet
```

Alias for <tt class="docutils literal"><span class="pre"><span class="Identifier">DisjointSet</span></span></tt>.

### `ConcurrentDisjointSet`

```nim
ConcurrentDisjointSet = DisjointSet
```

Alias for <tt class="docutils literal"><span class="pre"><span class="Identifier">DisjointSet</span></span></tt>.


## Constants

### `CacheLine`

```nim
CacheLine = 128
```

### `MaxDisjointSetSize`

```nim
MaxDisjointSetSize = 2147483647
```

Maximum number of elements supported by 32-bit packed parent indices.


## Procedures & Functions

### `packRankParent`

```nim
proc packRankParent(rank: uint32; parent: uint32): uint64 {.inline, raises: [],
    tags: [], forbids: [].}
```

Packs a 32-bit tree rank and 32-bit parent index into a 64-bit atomic word.

### `unpackRank`

```nim
proc unpackRank(word: uint64): uint32 {.inline, raises: [], tags: [],
                                        forbids: [].}
```

Extracts the 32-bit upper-bound tree rank from a packed 64-bit slot word.

### `unpackParent`

```nim
proc unpackParent(word: uint64): uint32 {.inline, raises: [], tags: [],
    forbids: [].}
```

Extracts the 32-bit parent index from a packed 64-bit slot word.

### ``=destroy``

```nim
proc `=destroy`(self: var DisjointSet) {.raises: [], raises: [], tags: [],
    forbids: [].}
```

### `destroy`

```nim
proc destroy(self: var DisjointSet) {.inline, raises: [], tags: [], forbids: [].}
```

Explicitly releases a reference to the shared disjoint set core.

### ``=copy``

```nim
proc `=copy`(dest: var DisjointSet; src: DisjointSet) {.raises: [], tags: [],
    forbids: [].}
```

### ``=sink``

```nim
proc `=sink`(dest: var DisjointSet; src: DisjointSet) {.raises: [], tags: [],
    forbids: [].}
```

### `initDisjointSet`

```nim
proc initDisjointSet(size: int): DisjointSet {.raises: [ValueError], tags: [],
    forbids: [].}
```

Initializes a concurrent <tt class="docutils literal"><span class="pre"><span class="Identifier">DisjointSet</span></span></tt> with <tt class="docutils literal"><span class="pre"><span class="Identifier">size</span></span></tt> disjoint singleton sets (<tt class="docutils literal"><span class="pre"><span class="DecNumber">0</span> <span class="Operator">..&lt;</span> <span class="Identifier">size</span></span></tt>), where each element <tt class="docutils literal"><span class="pre"><span class="Identifier">i</span></span></tt> starts with <tt class="docutils literal"><span class="pre"><span class="Identifier">parent</span> <span class="Operator">=</span> <span class="Identifier">i</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">rank</span> <span class="Operator">=</span> <span class="DecNumber">0</span></span></tt>. Raises <tt class="docutils literal"><span class="pre"><span class="Identifier">ValueError</span></span></tt> if <tt class="docutils literal"><span class="pre"><span class="Identifier">size</span> <span class="Operator">&lt;</span> <span class="DecNumber">0</span></span></tt> or <tt class="docutils literal"><span class="pre"><span class="Identifier">size</span> <span class="Operator">&gt;</span> <span class="Identifier">MaxDisjointSetSize</span></span></tt>.

### `newDisjointSet`

```nim
proc newDisjointSet(size: int): DisjointSet {.inline, raises: [ValueError],
    tags: [], forbids: [].}
```

Alias for <tt class="docutils literal"><span class="pre"><span class="Identifier">initDisjointSet</span><span class="Punctuation">(</span><span class="Identifier">size</span><span class="Punctuation">)</span></span></tt>.

### `find`

```nim
proc find(self: DisjointSet; x: int): int {.gcsafe, raises: [], tags: [],
    forbids: [].}
```

<p>Returns the canonical root representative of the set containing <tt class="docutils literal"><span class="pre"><span class="Identifier">x</span></span></tt>.</p>
<p>Performs wait-free / bounded-step atomic CAS path splitting / halving during traversal: for each non-root node <tt class="docutils literal"><span class="pre"><span class="Identifier">cur</span></span></tt> with parent <tt class="docutils literal"><span class="pre"><span class="Identifier">p</span></span></tt> and grandparent <tt class="docutils literal"><span class="pre"><span class="Identifier">gp</span> <span class="Operator">!=</span> <span class="Identifier">p</span></span></tt>, attempts a single non-blocking CAS to swing <tt class="docutils literal"><span class="pre"><span class="Identifier">parent</span><span class="Punctuation">(</span><span class="Identifier">cur</span><span class="Punctuation">)</span></span></tt> directly to <tt class="docutils literal"><span class="pre"><span class="Identifier">gp</span></span></tt> while preserving <tt class="docutils literal"><span class="pre"><span class="Identifier">rank</span><span class="Punctuation">(</span><span class="Identifier">cur</span><span class="Punctuation">)</span></span></tt>, then advances <tt class="docutils literal"><span class="pre"><span class="Identifier">cur</span> <span class="Operator">=</span> <span class="Identifier">gp</span></span></tt>.</p>

### `findNoCompress`

```nim
proc findNoCompress(self: DisjointSet; x: int): int {.gcsafe, raises: [],
    tags: [], forbids: [].}
```

Returns the canonical root representative of the set containing <tt class="docutils literal"><span class="pre"><span class="Identifier">x</span></span></tt> using pure read-only atomic loads without mutating parent pointers.

### `tryUnion`

```nim
proc tryUnion(self: DisjointSet; x, y: int; outRoot: var int): bool {.gcsafe,
    raises: [], tags: [], forbids: [].}
```

<p>Atomically merges the set containing <tt class="docutils literal"><span class="pre"><span class="Identifier">x</span></span></tt> and the set containing <tt class="docutils literal"><span class="pre"><span class="Identifier">y</span></span></tt> using rank-based linking with deterministic index tie-breaking (Anderson-Woll / Jayanti-Tarjan).</p>
<p>Sets <tt class="docutils literal"><span class="pre"><span class="Identifier">outRoot</span></span></tt> to the canonical representative of the unified set. Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt> if <tt class="docutils literal"><span class="pre"><span class="Identifier">x</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">y</span></span></tt> belonged to distinct sets and were merged by this call, or <tt class="docutils literal"><span class="pre"><span class="Identifier">false</span></span></tt> if they were already in the same set.</p>

### `union`

```nim
proc union(self: DisjointSet; x, y: int): bool {.discardable, inline, gcsafe,
    raises: [], tags: [], forbids: [].}
```

Atomically merges the set containing <tt class="docutils literal"><span class="pre"><span class="Identifier">x</span></span></tt> and the set containing <tt class="docutils literal"><span class="pre"><span class="Identifier">y</span></span></tt>. Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt> if two distinct sets were merged, or <tt class="docutils literal"><span class="pre"><span class="Identifier">false</span></span></tt> if <tt class="docutils literal"><span class="pre"><span class="Identifier">x</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">y</span></span></tt> were already in the same set (useful for concurrent cycle detection).

### `sameSet`

```nim
proc sameSet(self: DisjointSet; x, y: int): bool {.gcsafe, raises: [], tags: [],
    forbids: [].}
```

<p>Linearizable query returning <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt> iff <tt class="docutils literal"><span class="pre"><span class="Identifier">x</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">y</span></span></tt> belong to the same set.</p>
<p>Uses Anderson &amp; Woll's root re-verification protocol: when <tt class="docutils literal"><span class="pre"><span class="Identifier">u</span> <span class="Operator">=</span> <span class="Identifier">find</span><span class="Punctuation">(</span><span class="Identifier">x</span><span class="Punctuation">)</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">v</span> <span class="Operator">=</span> <span class="Identifier">find</span><span class="Punctuation">(</span><span class="Identifier">y</span><span class="Punctuation">)</span></span></tt> differ, verifies that <tt class="docutils literal"><span class="pre"><span class="Identifier">u</span></span></tt> is still a root after <tt class="docutils literal"><span class="pre"><span class="Identifier">find</span><span class="Punctuation">(</span><span class="Identifier">y</span><span class="Punctuation">)</span></span></tt> completes so concurrent unions cannot cause false negatives.</p>

### `connected`

```nim
proc connected(self: DisjointSet; x, y: int): bool {.inline, gcsafe, raises: [],
    tags: [], forbids: [].}
```

Alias for <tt class="docutils literal"><span class="pre"><span class="Identifier">sameSet</span><span class="Punctuation">(</span><span class="Identifier">x</span><span class="Punctuation">,</span> <span class="Identifier">y</span><span class="Punctuation">)</span></span></tt>.

### `numSets`

```nim
proc numSets(self: DisjointSet): int {.inline, gcsafe, raises: [], tags: [],
                                       forbids: [].}
```

Returns the current number of disjoint sets in <tt class="docutils literal"><span class="pre"><span class="Identifier">self</span></span></tt>.

### `len`

```nim
proc len(self: DisjointSet): int {.inline, gcsafe, raises: [], tags: [],
                                   forbids: [].}
```

Returns the total number of elements managed by <tt class="docutils literal"><span class="pre"><span class="Identifier">self</span></span></tt>.

### `size`

```nim
proc size(self: DisjointSet): int {.inline, gcsafe, raises: [], tags: [],
                                    forbids: [].}
```

Alias for <tt class="docutils literal"><span class="pre"><span class="Identifier">len</span><span class="Punctuation">(</span><span class="Identifier">self</span><span class="Punctuation">)</span></span></tt>.

### `rank`

```nim
proc rank(self: DisjointSet; x: int): uint32 {.inline, gcsafe, raises: [],
    tags: [], forbids: [].}
```

Returns the current upper-bound rank stored in slot <tt class="docutils literal"><span class="pre"><span class="Identifier">x</span></span></tt>.

### `isRoot`

```nim
proc isRoot(self: DisjointSet; x: int): bool {.inline, gcsafe, raises: [],
    tags: [], forbids: [].}
```

Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt> iff <tt class="docutils literal"><span class="pre"><span class="Identifier">x</span></span></tt> is currently the canonical root of its set.

### `clear`

```nim
proc clear(self: DisjointSet) {.gcsafe, raises: [], tags: [], forbids: [].}
```

Resets all elements <tt class="docutils literal"><span class="pre"><span class="DecNumber">0</span> <span class="Operator">..&lt;</span> <span class="Identifier">len</span></span></tt> back to singleton sets (<tt class="docutils literal"><span class="pre"><span class="Identifier">parent</span> <span class="Operator">=</span> <span class="Identifier">i</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">rank</span> <span class="Operator">=</span> <span class="DecNumber">0</span></span></tt>) and restores <tt class="docutils literal"><span class="pre"><span class="Identifier">numSets</span></span></tt> to <tt class="docutils literal"><span class="pre"><span class="Identifier">len</span></span></tt>.

### `find`

```nim
proc find(self: ptr DisjointSet; x: int): int {.inline, gcsafe, raises: [],
    tags: [], forbids: [].}
```

### `findNoCompress`

```nim
proc findNoCompress(self: ptr DisjointSet; x: int): int {.inline, gcsafe,
    raises: [], tags: [], forbids: [].}
```

### `tryUnion`

```nim
proc tryUnion(self: ptr DisjointSet; x, y: int; outRoot: var int): bool {.
    inline, gcsafe, raises: [], tags: [], forbids: [].}
```

### `union`

```nim
proc union(self: ptr DisjointSet; x, y: int): bool {.discardable, inline,
    gcsafe, raises: [], tags: [], forbids: [].}
```

### `sameSet`

```nim
proc sameSet(self: ptr DisjointSet; x, y: int): bool {.inline, gcsafe,
    raises: [], tags: [], forbids: [].}
```

### `connected`

```nim
proc connected(self: ptr DisjointSet; x, y: int): bool {.inline, gcsafe,
    raises: [], tags: [], forbids: [].}
```

### `numSets`

```nim
proc numSets(self: ptr DisjointSet): int {.inline, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `len`

```nim
proc len(self: ptr DisjointSet): int {.inline, gcsafe, raises: [], tags: [],
                                       forbids: [].}
```

### `size`

```nim
proc size(self: ptr DisjointSet): int {.inline, gcsafe, raises: [], tags: [],
                                        forbids: [].}
```

### `rank`

```nim
proc rank(self: ptr DisjointSet; x: int): uint32 {.inline, gcsafe, raises: [],
    tags: [], forbids: [].}
```

### `isRoot`

```nim
proc isRoot(self: ptr DisjointSet; x: int): bool {.inline, gcsafe, raises: [],
    tags: [], forbids: [].}
```

### `clear`

```nim
proc clear(self: ptr DisjointSet) {.inline, gcsafe, raises: [], tags: [],
                                    forbids: [].}
```

