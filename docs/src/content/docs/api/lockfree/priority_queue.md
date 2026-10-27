---
title: "lockfree/priority_queue"
description: "API reference for lockfree/priority_queue"
---

<p>Lock-Free Concurrent Priority Queue (<tt class="docutils literal"><span class="pre"><span class="Identifier">SkipListPriorityQueue</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>).</p>
<p>Implements the Lindén-Jonsson lock-free concurrent priority queue (&quot;A Skiplist-Based Concurrent Priority Queue with Minimal Memory Contention&quot;, Jonatan Lindén &amp; Bengt Jonsson, OPODIS 2013) backed by <tt class="docutils literal"><span class="pre"><span class="Identifier">DebraManager</span></span></tt> (Neutralization-Based Reclamation / DEBRA+) for safe lock-free node reclamation.</p>
<p>Key concurrency properties:</p>
<ul class="simple"><li><strong>Minimized Pop Contention</strong>: <tt class="docutils literal"><span class="pre"><span class="Identifier">popMin</span></span></tt> logically deletes the minimum node by atomically flipping <tt class="docutils literal"><span class="pre"><span class="Identifier">node</span><span class="Operator">.</span><span class="Identifier">deleted</span></span></tt> (<tt class="docutils literal"><span class="pre"><span class="Identifier">false</span> <span class="Operator">-&gt;</span> <span class="Identifier">true</span></span></tt>) along level 0 without modifying <tt class="docutils literal"><span class="pre"><span class="Identifier">head</span><span class="Operator">.</span><span class="Identifier">next</span><span class="Punctuation">[</span><span class="DecNumber">0</span><span class="Punctuation">]</span></span></tt> on every pop.</li>
<li><strong>Batch Physical Restructuring</strong>: When the prefix of logically deleted nodes exceeds <tt class="docutils literal"><span class="pre"><span class="Identifier">DefaultRestructureThreshold</span></span></tt> (or when the queue drains), the prefix towers are marked from top level down to level 0 and physically spliced out in a single multi-level pass, retiring unlinked nodes to <tt class="docutils literal"><span class="pre"><span class="Identifier">DebraManager</span></span></tt> strictly once on the thread that wins the level-0 unlink CAS.</li>
<li><strong>Strict FIFO Tie-Breaking</strong>: Equal priorities are ordered deterministically by a monotonically increasing 64-bit <tt class="docutils literal"><span class="pre"><span class="Identifier">seqId</span></span></tt>, preserving all duplicate priorities in insertion order.</li>
</ul>


## Types

### `Prioritized`

```nim
Prioritized[P; V] = object
  priority*: P
  value*: V
```

Key-value wrapper for priority queues where only <tt class="docutils literal"><span class="pre"><span class="Identifier">priority</span></span></tt> participates in ordering and <tt class="docutils literal"><span class="pre"><span class="Identifier">value</span></span></tt> can be any arbitrary type (including <tt class="docutils literal"><span class="pre"><span class="Identifier">pointer</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Keyword">ref</span></span></tt>, or structs that do not implement <tt class="docutils literal"><span class="pre"><span class="Operator">&lt;</span></span></tt> or <tt class="docutils literal"><span class="pre"><span class="Identifier">cmp</span></span></tt>).

### `SkipListPriorityQueue`

```nim
SkipListPriorityQueue[T; MaxThreads; MaxLevel] = object
  core*: ptr SkipListPriorityQueueCore[T, MaxThreads, MaxLevel]
```

### `PriorityQueue`

```nim
PriorityQueue[T; MaxThreads; MaxLevel] = SkipListPriorityQueue[T, MaxThreads,
    MaxLevel]
```

### `ConcurrentPriorityQueue`

```nim
ConcurrentPriorityQueue[T; MaxThreads; MaxLevel] = SkipListPriorityQueue[T,
    MaxThreads, MaxLevel]
```

### `LockFreePriorityQueue`

```nim
LockFreePriorityQueue[T; MaxThreads; MaxLevel] = SkipListPriorityQueue[T,
    MaxThreads, MaxLevel]
```


## Constants

### `DefaultPQueueMaxThreads`

```nim
DefaultPQueueMaxThreads = 64
```

### `DefaultPQueueMaxLevel`

```nim
DefaultPQueueMaxLevel = 16
```

### `DefaultRestructureThreshold`

```nim
DefaultRestructureThreshold = 32
```


## Procedures & Functions

### ``&lt;``

```nim
proc `<`[P, V](a, b: Prioritized[P, V]): bool {.inline.}
```

### ``&lt;=``

```nim
proc `<=`[P, V](a, b: Prioritized[P, V]): bool {.inline.}
```

### ``==``

```nim
proc `==`[P, V](a, b: Prioritized[P, V]): bool {.inline.}
```

### `cmp`

```nim
proc cmp[P, V](a, b: Prioritized[P, V]): int {.inline.}
```

### `getOrRegisterHandle`

```nim
proc getOrRegisterHandle[T; MaxThreads: static int; MaxLevel: static int](
    pq: SkipListPriorityQueue[T, MaxThreads, MaxLevel]): ThreadHandle[
    MaxThreads, ccMulti]
```

### `registerThread`

```nim
proc registerThread[T; MaxThreads: static int; MaxLevel: static int](
    pq: SkipListPriorityQueue[T, MaxThreads, MaxLevel])
```

Explicitly registers the calling thread with the priority queue's SMR manager.

### `unregisterThread`

```nim
proc unregisterThread[T; MaxThreads: static int; MaxLevel: static int](
    pq: SkipListPriorityQueue[T, MaxThreads, MaxLevel])
```

Drains any pending retired nodes in the calling thread's limbo bags and unregisters the thread from the priority queue's SMR manager.

### ``=destroy``

```nim
proc `=destroy`[T; MaxThreads: static int; MaxLevel: static int](
    self: var SkipListPriorityQueue[T, MaxThreads, MaxLevel]) {.gcsafe,
    raises: [].}
```

### ``=copy``

```nim
proc `=copy`[T; MaxThreads: static int; MaxLevel: static int](
    dest: var SkipListPriorityQueue[T, MaxThreads, MaxLevel];
    src: SkipListPriorityQueue[T, MaxThreads, MaxLevel])
```

### `newSkipListPriorityQueue`

```nim
proc newSkipListPriorityQueue[T;
                              MaxThreads: static int = DefaultPQueueMaxThreads;
                              MaxLevel: static int = DefaultPQueueMaxLevel](): SkipListPriorityQueue[
    T, MaxThreads, MaxLevel]
```

Allocates and initializes a new lock-free <tt class="docutils literal"><span class="pre"><span class="Identifier">SkipListPriorityQueue</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>.

### `initSkipListPriorityQueue`

```nim
proc initSkipListPriorityQueue[T; MaxThreads: static int = DefaultPQueueMaxThreads;
                               MaxLevel: static int = DefaultPQueueMaxLevel](): SkipListPriorityQueue[
    T, MaxThreads, MaxLevel] {.inline.}
```

Alias for <tt class="docutils literal"><span class="pre"><span class="Identifier">newSkipListPriorityQueue</span></span></tt>.

### `newPriorityQueue`

```nim
proc newPriorityQueue[T; MaxThreads: static int = DefaultPQueueMaxThreads;
                      MaxLevel: static int = DefaultPQueueMaxLevel](): PriorityQueue[
    T, MaxThreads, MaxLevel] {.inline.}
```

### `initPriorityQueue`

```nim
proc initPriorityQueue[T; MaxThreads: static int = DefaultPQueueMaxThreads;
                       MaxLevel: static int = DefaultPQueueMaxLevel](): PriorityQueue[
    T, MaxThreads, MaxLevel] {.inline.}
```

### `newConcurrentPriorityQueue`

```nim
proc newConcurrentPriorityQueue[T; MaxThreads: static int = DefaultPQueueMaxThreads;
                                MaxLevel: static int = DefaultPQueueMaxLevel](): ConcurrentPriorityQueue[
    T, MaxThreads, MaxLevel] {.inline.}
```

### `newLockFreePriorityQueue`

```nim
proc newLockFreePriorityQueue[T;
                              MaxThreads: static int = DefaultPQueueMaxThreads;
                              MaxLevel: static int = DefaultPQueueMaxLevel](): LockFreePriorityQueue[
    T, MaxThreads, MaxLevel] {.inline.}
```

### `push`

```nim
proc push[T; MaxThreads: static int; MaxLevel: static int](
    pq: SkipListPriorityQueue[T, MaxThreads, MaxLevel]; item: sink T)
```

Inserts <tt class="docutils literal"><span class="pre"><span class="Identifier">item</span></span></tt> into the priority queue. Duplicate priorities are preserved and popped in strict FIFO order.

### `push`

```nim
proc push[P, V; MaxThreads: static int; MaxLevel: static int](
    pq: SkipListPriorityQueue[Prioritized[P, V], MaxThreads, MaxLevel];
    priority: P; value: sink V) {.inline.}
```

Convenience overload for pushing a <tt class="docutils literal"><span class="pre"><span class="Punctuation">(</span><span class="Identifier">priority</span><span class="Punctuation">,</span> <span class="Identifier">value</span><span class="Punctuation">)</span></span></tt> pair into a <tt class="docutils literal"><span class="pre"><span class="Identifier">SkipListPriorityQueue</span><span class="Punctuation">[</span><span class="Identifier">Prioritized</span><span class="Punctuation">[</span><span class="Identifier">P</span><span class="Punctuation">,</span> <span class="Identifier">V</span><span class="Punctuation">]</span><span class="Punctuation">]</span></span></tt>.

### `popMin`

```nim
proc popMin[T; MaxThreads: static int; MaxLevel: static int](
    pq: SkipListPriorityQueue[T, MaxThreads, MaxLevel]): Option[T]
```

Removes and returns the minimum element (<tt class="docutils literal"><span class="pre"><span class="Identifier">some</span><span class="Punctuation">(</span><span class="Identifier">minItem</span><span class="Punctuation">)</span></span></tt>), or <tt class="docutils literal"><span class="pre"><span class="Identifier">none</span><span class="Punctuation">(</span><span class="Identifier">T</span><span class="Punctuation">)</span></span></tt> if the priority queue is empty. Equal priorities are popped in strict FIFO insertion order.

### `tryPopMin`

```nim
proc tryPopMin[T; MaxThreads: static int; MaxLevel: static int](
    pq: SkipListPriorityQueue[T, MaxThreads, MaxLevel]; outVal: var T): bool
```

Attempts to remove the minimum element into <tt class="docutils literal"><span class="pre"><span class="Identifier">outVal</span></span></tt>. Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt> if an element was popped, or <tt class="docutils literal"><span class="pre"><span class="Identifier">false</span></span></tt> if the queue is empty.

### `peekMin`

```nim
proc peekMin[T; MaxThreads: static int; MaxLevel: static int](
    pq: SkipListPriorityQueue[T, MaxThreads, MaxLevel]): Option[T]
```

Returns the minimum element (<tt class="docutils literal"><span class="pre"><span class="Identifier">some</span><span class="Punctuation">(</span><span class="Identifier">minItem</span><span class="Punctuation">)</span></span></tt>) without removing it, or <tt class="docutils literal"><span class="pre"><span class="Identifier">none</span><span class="Punctuation">(</span><span class="Identifier">T</span><span class="Punctuation">)</span></span></tt> if the priority queue is empty.

### `len`

```nim
proc len[T; MaxThreads: static int; MaxLevel: static int](
    pq: SkipListPriorityQueue[T, MaxThreads, MaxLevel]): int {.inline.}
```

Returns the current number of active elements in the priority queue.

### `isEmpty`

```nim
proc isEmpty[T; MaxThreads: static int; MaxLevel: static int](
    pq: SkipListPriorityQueue[T, MaxThreads, MaxLevel]): bool {.inline.}
```

Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt> if the priority queue currently contains no active elements.

### `clear`

```nim
proc clear[T; MaxThreads: static int; MaxLevel: static int](
    pq: SkipListPriorityQueue[T, MaxThreads, MaxLevel])
```

Removes all elements currently in the priority queue and triggers physical restructuring of the deleted prefix.

### ``$``

```nim
proc `$`[T; MaxThreads: static int; MaxLevel: static int](
    pq: SkipListPriorityQueue[T, MaxThreads, MaxLevel]): string
```

Formats the priority queue contents in ascending priority order.


## Templates

### `pop`

```nim
template pop[T; MaxThreads: static int; MaxLevel: static int](
    pq: SkipListPriorityQueue[T, MaxThreads, MaxLevel]): untyped
```

### `peek`

```nim
template peek[T; MaxThreads: static int; MaxLevel: static int](
    pq: SkipListPriorityQueue[T, MaxThreads, MaxLevel]): untyped
```

