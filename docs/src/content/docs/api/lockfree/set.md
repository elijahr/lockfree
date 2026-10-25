---
title: "lockfree/set"
description: "API reference for lockfree/set"
---

=========================================================================== Concurrency Topology: MPMC (Multi-Producer Multi-Consumer) Lock-Free Ordered Set<hr />
<table border="1" class="docutils"><tr><th>Dimension</th><th>Specification</th></tr>
<tr><td><strong>Topologies</strong></td><td>MPMC (Multi-Producer Multi-Consumer Concurrent Ordered Set)</td></tr>
<tr><td><strong>Algorithm</strong></td><td>Fraser / Herlihy Lock-Free SkipList with Harris Logical Marking</td></tr>
<tr><td><strong>Ordering</strong></td><td>Strict Total Key Order (ascending level-0 traversal)</td></tr>
<tr><td><strong>Capacity</strong></td><td>Dynamically Unbounded</td></tr>
<tr><td><strong>Coordination</strong></td><td>Atomic marked next-pointers, CAS insertion/physical unlinking</td></tr>
<tr><td><strong>Progress Guarantee</strong></td><td>Lock-Free (Insert, Remove) / Wait-Free Population (Contains)</td></tr>
<tr><td><strong>Memory Reclamation</strong></td><td>Debra SMR (Epoch-Based Reclamation, <tt class="docutils literal"><span class="pre"><span class="Identifier">MaxThreads</span></span></tt> capacity)</td></tr>
<tr><td><strong>Set Algebra</strong></td><td>Concurrent intersect, union, difference, and isSubsetOf</td></tr>
</table>
<h2><a class="toc-backref" id="overview" href="#overview">Overview</a></h2><p><tt class="docutils literal"><span class="pre"><span class="Identifier">SkipListSet</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> is an MPMC lock-free ordered set based on Fraser and Herlihy's lock-free skip list algorithm with Harris-style logical deletion marking and Debra Safe Memory Reclamation (SMR).</p>
<p>Elements are maintained in strictly ascending sorted order at level 0. The set supports concurrent membership queries (<tt class="docutils literal"><span class="pre"><span class="Identifier">contains</span></span></tt>), insertions (<tt class="docutils literal"><span class="pre"><span class="Identifier">insert</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">incl</span></span></tt>), removals (<tt class="docutils literal"><span class="pre"><span class="Identifier">remove</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">excl</span></span></tt>), size queries (<tt class="docutils literal"><span class="pre"><span class="Identifier">len</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">isEmpty</span></span></tt>), sorted iteration (<tt class="docutils literal"><span class="pre"><span class="Identifier">items</span></span></tt>), and concurrent set algebra (<tt class="docutils literal"><span class="pre"><span class="Identifier">intersect</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">union</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">difference</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">isSubsetOf</span></span></tt>).</p>


## Types

### `SkipListSet`

```nim
SkipListSet[T; MaxThreads; MaxLevel] = object
  core*: ptr SkipListSetCore[T, MaxThreads, MaxLevel]
```

### `Set`

```nim
Set[T; MaxThreads; MaxLevel] = SkipListSet[T, MaxThreads, MaxLevel]
```

### `ConcurrentSet`

```nim
ConcurrentSet[T; MaxThreads; MaxLevel] = SkipListSet[T, MaxThreads, MaxLevel]
```

### `OrderedSet`

```nim
OrderedSet[T; MaxThreads; MaxLevel] = SkipListSet[T, MaxThreads, MaxLevel]
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
proc getOrRegisterHandle[T; MaxThreads, MaxLevel: static int](
    self: SkipListSet[T, MaxThreads, MaxLevel]): ThreadHandle[MaxThreads,
    ccMulti]
```

### `newSkipListSet`

```nim
proc newSkipListSet[T; MaxThreads: static int = DefaultMaxThreads;
                    MaxLevel: static int = DefaultMaxLevel](): SkipListSet[T,
    MaxThreads, MaxLevel]
```

Constructs a new empty <tt class="docutils literal"><span class="pre"><span class="Identifier">SkipListSet</span></span></tt> with a dedicated <tt class="docutils literal"><span class="pre"><span class="Identifier">DebraManager</span></span></tt>.

### `newSkipListSet`

```nim
proc newSkipListSet[T; MaxThreads: static int = DefaultMaxThreads;
                    MaxLevel: static int = DefaultMaxLevel](
    manager: ptr DebraManager[MaxThreads, ccMulti]): SkipListSet[T, MaxThreads,
    MaxLevel]
```

Constructs a new empty <tt class="docutils literal"><span class="pre"><span class="Identifier">SkipListSet</span></span></tt> sharing an external <tt class="docutils literal"><span class="pre"><span class="Identifier">DebraManager</span></span></tt>.

### `initSkipListSet`

```nim
proc initSkipListSet[T; MaxThreads: static int = DefaultMaxThreads;
                     MaxLevel: static int = DefaultMaxLevel](): SkipListSet[T,
    MaxThreads, MaxLevel] {.inline.}
```

### `initSkipListSet`

```nim
proc initSkipListSet[T; MaxThreads: static int = DefaultMaxThreads;
                     MaxLevel: static int = DefaultMaxLevel](
    manager: ptr DebraManager[MaxThreads, ccMulti]): SkipListSet[T, MaxThreads,
    MaxLevel] {.inline.}
```

Constructs a new empty <tt class="docutils literal"><span class="pre"><span class="Identifier">SkipListSet</span></span></tt> sharing an external <tt class="docutils literal"><span class="pre"><span class="Identifier">DebraManager</span></span></tt>.

### ``=destroy``

```nim
proc `=destroy`[T; MaxThreads, MaxLevel: static int](
    self: var SkipListSet[T, MaxThreads, MaxLevel]) {.gcsafe, raises: [].}
```

### ``=copy``

```nim
proc `=copy`[T; MaxThreads, MaxLevel: static int](
    dest: var SkipListSet[T, MaxThreads, MaxLevel];
    src: SkipListSet[T, MaxThreads, MaxLevel])
```

### `len`

```nim
proc len[T; MaxThreads, MaxLevel: static int](
    self: SkipListSet[T, MaxThreads, MaxLevel]): int {.inline.}
```

Returns the approximate number of items currently in the set.

### `isEmpty`

```nim
proc isEmpty[T; MaxThreads, MaxLevel: static int](
    self: SkipListSet[T, MaxThreads, MaxLevel]): bool {.inline.}
```

Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt> if the set contains zero elements.

### `registerThread`

```nim
proc registerThread[T; MaxThreads, MaxLevel: static int](
    self: var SkipListSet[T, MaxThreads, MaxLevel]): ThreadHandle[MaxThreads,
    ccMulti] {.inline.}
```

Explicitly registers the calling thread with the set's Debra manager.

### `unregisterThread`

```nim
proc unregisterThread[T; MaxThreads, MaxLevel: static int](
    self: var SkipListSet[T, MaxThreads, MaxLevel];
    handle: ThreadHandle[MaxThreads, ccMulti]) {.inline.}
```

Unregisters the thread handle, releasing its slot in the Debra registry.

### `contains`

```nim
proc contains[T; MaxThreads, MaxLevel: static int](
    self: SkipListSet[T, MaxThreads, MaxLevel]; item: T;
    handle: ThreadHandle[MaxThreads, ccMulti]): bool
```

Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt> if <tt class="docutils literal"><span class="pre"><span class="Identifier">item</span></span></tt> is present in the set using the provided thread handle. Wait-free population guarantee: does not perform CAS or mutate state.

### `contains`

```nim
proc contains[T; MaxThreads, MaxLevel: static int](
    self: SkipListSet[T, MaxThreads, MaxLevel]; item: T): bool {.inline.}
```

Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt> if <tt class="docutils literal"><span class="pre"><span class="Identifier">item</span></span></tt> is present in the set (auto-dispatched thread handle).

### `insert`

```nim
proc insert[T; MaxThreads, MaxLevel: static int](
    self: var SkipListSet[T, MaxThreads, MaxLevel]; item: sink T;
    handle: ThreadHandle[MaxThreads, ccMulti]): bool
```

Inserts <tt class="docutils literal"><span class="pre"><span class="Identifier">item</span></span></tt> into the set. Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt> if a new item was inserted, <tt class="docutils literal"><span class="pre"><span class="Identifier">false</span></span></tt> if <tt class="docutils literal"><span class="pre"><span class="Identifier">item</span></span></tt> was already present.

### `insert`

```nim
proc insert[T; MaxThreads, MaxLevel: static int](
    self: var SkipListSet[T, MaxThreads, MaxLevel]; item: sink T): bool {.inline.}
```

Inserts <tt class="docutils literal"><span class="pre"><span class="Identifier">item</span></span></tt> into the set using automatic thread registration.

### `incl`

```nim
proc incl[T; MaxThreads, MaxLevel: static int](
    self: var SkipListSet[T, MaxThreads, MaxLevel]; item: sink T) {.inline.}
```

Syntax sugar: <tt class="docutils literal"><span class="pre"><span class="Identifier">set</span><span class="Operator">.</span><span class="Identifier">incl</span><span class="Punctuation">(</span><span class="Identifier">item</span><span class="Punctuation">)</span></span></tt>.

### `remove`

```nim
proc remove[T; MaxThreads, MaxLevel: static int](
    self: var SkipListSet[T, MaxThreads, MaxLevel]; item: T;
    handle: ThreadHandle[MaxThreads, ccMulti]): bool
```

Logically marks and physically unlinks <tt class="docutils literal"><span class="pre"><span class="Identifier">item</span></span></tt> from the set. Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt> if <tt class="docutils literal"><span class="pre"><span class="Identifier">item</span></span></tt> was found and removed, <tt class="docutils literal"><span class="pre"><span class="Identifier">false</span></span></tt> otherwise.

### `remove`

```nim
proc remove[T; MaxThreads, MaxLevel: static int](
    self: var SkipListSet[T, MaxThreads, MaxLevel]; item: T): bool {.inline.}
```

Removes <tt class="docutils literal"><span class="pre"><span class="Identifier">item</span></span></tt> from the set using automatic thread registration.

### `excl`

```nim
proc excl[T; MaxThreads, MaxLevel: static int](
    self: var SkipListSet[T, MaxThreads, MaxLevel]; item: T) {.inline.}
```

Syntax sugar: <tt class="docutils literal"><span class="pre"><span class="Identifier">set</span><span class="Operator">.</span><span class="Identifier">excl</span><span class="Punctuation">(</span><span class="Identifier">item</span><span class="Punctuation">)</span></span></tt>.

### `toSeq`

```nim
proc toSeq[T; MaxThreads, MaxLevel: static int](
    self: SkipListSet[T, MaxThreads, MaxLevel]): seq[T]
```

Collects all elements into a <tt class="docutils literal"><span class="pre"><span class="Identifier">seq</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> in ascending sorted order.

### `intersect`

```nim
proc intersect[T; MaxThreads, MaxLevel: static int](
    a, b: SkipListSet[T, MaxThreads, MaxLevel]): SkipListSet[T, MaxThreads,
    MaxLevel]
```

Computes the set intersection (A ∩ B).

### `union`

```nim
proc union[T; MaxThreads, MaxLevel: static int](
    a, b: SkipListSet[T, MaxThreads, MaxLevel]): SkipListSet[T, MaxThreads,
    MaxLevel]
```

Computes the set union (A ∪ B).

### `difference`

```nim
proc difference[T; MaxThreads, MaxLevel: static int](
    a, b: SkipListSet[T, MaxThreads, MaxLevel]): SkipListSet[T, MaxThreads,
    MaxLevel]
```

Computes the set difference (A B).

### `isSubsetOf`

```nim
proc isSubsetOf[T; MaxThreads, MaxLevel: static int](
    a, b: SkipListSet[T, MaxThreads, MaxLevel]): bool
```

Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt> if all elements of <tt class="docutils literal"><span class="pre"><span class="Identifier">a</span></span></tt> are present in <tt class="docutils literal"><span class="pre"><span class="Identifier">b</span></span></tt> (A ⊆ B).

### ``&lt;``

```nim
proc `<`[T; MaxThreads, MaxLevel: static int](
    a, b: SkipListSet[T, MaxThreads, MaxLevel]): bool {.inline.}
```

Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt> if <tt class="docutils literal"><span class="pre"><span class="Identifier">a</span></span></tt> is a strict subset of <tt class="docutils literal"><span class="pre"><span class="Identifier">b</span></span></tt> (A ⊂ B).

### ``==``

```nim
proc `==`[T; MaxThreads, MaxLevel: static int](
    a, b: SkipListSet[T, MaxThreads, MaxLevel]): bool
```

Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt> if sets <tt class="docutils literal"><span class="pre"><span class="Identifier">a</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">b</span></span></tt> contain identical elements.

### `toSkipListSet`

```nim
proc toSkipListSet[T](items: openArray[T]): SkipListSet[T, 64, 16]
```

Constructs a new <tt class="docutils literal"><span class="pre"><span class="Identifier">SkipListSet</span></span></tt> with default threads and level populated with items from <tt class="docutils literal"><span class="pre"><span class="Identifier">items</span></span></tt>.

### `newSet`

```nim
proc newSet[T; MaxThreads: static int = DefaultMaxThreads;
            MaxLevel: static int = DefaultMaxLevel](): Set[T, MaxThreads,
    MaxLevel] {.inline.}
```

Smart constructor for <tt class="docutils literal"><span class="pre"><span class="Identifier">Set</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>.

### `initSet`

```nim
proc initSet[T; MaxThreads: static int = DefaultMaxThreads;
             MaxLevel: static int = DefaultMaxLevel](): Set[T, MaxThreads,
    MaxLevel] {.inline.}
```

Initializer for <tt class="docutils literal"><span class="pre"><span class="Identifier">Set</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>.

### `newConcurrentSet`

```nim
proc newConcurrentSet[T; MaxThreads: static int = DefaultMaxThreads;
                      MaxLevel: static int = DefaultMaxLevel](): ConcurrentSet[
    T, MaxThreads, MaxLevel] {.inline.}
```

Smart constructor for <tt class="docutils literal"><span class="pre"><span class="Identifier">ConcurrentSet</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>.

### `initConcurrentSet`

```nim
proc initConcurrentSet[T; MaxThreads: static int = DefaultMaxThreads;
                       MaxLevel: static int = DefaultMaxLevel](): ConcurrentSet[
    T, MaxThreads, MaxLevel] {.inline.}
```

Initializer for <tt class="docutils literal"><span class="pre"><span class="Identifier">ConcurrentSet</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>.

### `newOrderedSet`

```nim
proc newOrderedSet[T; MaxThreads: static int = DefaultMaxThreads;
                   MaxLevel: static int = DefaultMaxLevel](): OrderedSet[T,
    MaxThreads, MaxLevel] {.inline.}
```

Smart constructor for <tt class="docutils literal"><span class="pre"><span class="Identifier">OrderedSet</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>.

### `initOrderedSet`

```nim
proc initOrderedSet[T; MaxThreads: static int = DefaultMaxThreads;
                    MaxLevel: static int = DefaultMaxLevel](): OrderedSet[T,
    MaxThreads, MaxLevel] {.inline.}
```

Initializer for <tt class="docutils literal"><span class="pre"><span class="Identifier">OrderedSet</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>.


## Templates

### ``*``

```nim
template `*`[T; MaxThreads, MaxLevel: static int](
    a, b: SkipListSet[T, MaxThreads, MaxLevel]): SkipListSet[T, MaxThreads,
    MaxLevel]
```

### ``+``

```nim
template `+`[T; MaxThreads, MaxLevel: static int](
    a, b: SkipListSet[T, MaxThreads, MaxLevel]): SkipListSet[T, MaxThreads,
    MaxLevel]
```

### ``-``

```nim
template `-`[T; MaxThreads, MaxLevel: static int](
    a, b: SkipListSet[T, MaxThreads, MaxLevel]): SkipListSet[T, MaxThreads,
    MaxLevel]
```

### ``&lt;=``

```nim
template `<=`[T; MaxThreads, MaxLevel: static int](
    a, b: SkipListSet[T, MaxThreads, MaxLevel]): bool
```


## Iterators

### `items`

```nim
iterator items[T; MaxThreads, MaxLevel: static int](
    self: SkipListSet[T, MaxThreads, MaxLevel];
    handle: ThreadHandle[MaxThreads, ccMulti]): T
```

Iterates over all elements in strictly ascending sorted order.

### `items`

```nim
iterator items[T; MaxThreads, MaxLevel: static int](
    self: SkipListSet[T, MaxThreads, MaxLevel]): T
```

Iterates over all elements in strictly ascending sorted order (auto handle).

