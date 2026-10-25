---
title: "lockfree/bqueue128"
description: "API reference for lockfree/bqueue128"
---

<h1><a class="toc-backref" id="concurrency-topologycolon-128minusbit-dwcas-bounded-mpmc-queue-nimbqueue128" href="#concurrency-topologycolon-128minusbit-dwcas-bounded-mpmc-queue-nimbqueue128">Concurrency Topology: 128-Bit DWCAS Bounded MPMC Queue (<tt class="docutils literal"><span class="pre"><span class="Identifier">BQueue128</span></span></tt>)</a></h1><table border="1" class="docutils"><tr><th>Dimension</th><th>Specification</th></tr>
<tr><td><strong>Topologies</strong></td><td>MPMC, MPSC, SPMC, SPSC (fully multi-producer multi-consumer safe)</td></tr>
<tr><td><strong>Algorithm</strong></td><td>Double-Word CAS (DWCAS) Bounded MPMC Ring Buffer</td></tr>
<tr><td><strong>Capacity</strong></td><td>Fixed compile-time capacity <tt class="docutils literal"><span class="pre"><span class="Identifier">N</span></span></tt> (must be a power of two)</td></tr>
<tr><td><strong>Atomic Substrate</strong></td><td>128-Bit Hardware DWCAS (<tt class="docutils literal"><span class="pre"><span class="Identifier">CMPXCHG16B</span></span></tt> on x86_64, <tt class="docutils literal"><span class="pre"><span class="Identifier">CASP</span></span></tt> on ARM64)</td></tr>
<tr><td><strong>Slot Geometry</strong></td><td>16-Byte Aligned <tt class="docutils literal"><span class="pre"><span class="Identifier">Pair</span><span class="Punctuation">[</span><span class="Identifier">uint64</span><span class="Punctuation">,</span> <span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> (Sequence + Value in 1 Word)</td></tr>
<tr><td><strong>Cacheline Isolation</strong></td><td><tt class="docutils literal"><span class="pre"><span class="Identifier">head</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">tail</span></span></tt> isolated on distinct <tt class="docutils literal"><span class="pre"><span class="Identifier">CacheLineBytes</span></span></tt> lines</td></tr>
<tr><td><strong>Progress Guarantee</strong></td><td>Lock-Free / Wait-Free Slot Publication</td></tr>
<tr><td><strong>Memory Reclamation</strong></td><td>Zero heap allocation at runtime, in-place slot reuse, zero SMR</td></tr>
</table>
<h3><a class="toc-backref" id="concurrency-topologycolon-128minusbit-dwcas-bounded-mpmc-queue-nimbqueue128-algorithmic-foundations" href="#concurrency-topologycolon-128minusbit-dwcas-bounded-mpmc-queue-nimbqueue128-algorithmic-foundations">Algorithmic Foundations</a></h3><p>In Dmitry Vyukov's classical bounded queue (<tt class="docutils literal"><span class="pre"><span class="Identifier">BQueue</span></span></tt>), publishing an item requires two separate phases:</p>
<ol class="simple"><li>Producer claims the slot turn by advancing <tt class="docutils literal"><span class="pre"><span class="Identifier">tail</span></span></tt>.</li>
<li>Producer writes <tt class="docutils literal"><span class="pre"><span class="Identifier">data</span></span></tt> non-atomically, then stores the updated <tt class="docutils literal"><span class="pre"><span class="Identifier">sequence</span></span></tt>.</li>
</ol>
<p>If the producer is descheduled between steps 1 and 2, the slot remains in a half-written intermediate state, forcing downstream consumers to spin.</p>
<p><tt class="docutils literal"><span class="pre"><span class="Identifier">BQueue128</span></span></tt> solves this via hardware <strong>128-Bit Double-Word Compare-And-Swap</strong>:</p>
<ul class="simple"><li>Each slot is an <tt class="docutils literal"><span class="pre"><span class="Identifier">Atomic</span><span class="Punctuation">[</span><span class="Identifier">Pair</span><span class="Punctuation">[</span><span class="Identifier">uint64</span><span class="Punctuation">,</span> <span class="Identifier">T</span><span class="Punctuation">]</span><span class="Punctuation">]</span></span></tt> (16 bytes aligned to 16 bytes).</li>
<li>The turn sequence and the 64-bit payload reside inside the <strong>same atomic word</strong>.</li>
<li><strong>Enqueue</strong>: Simultaneously advances sequence from <tt class="docutils literal"><span class="pre"><span class="Identifier">pos</span></span></tt> to <tt class="docutils literal"><span class="pre"><span class="Identifier">pos</span> <span class="Operator">+</span> <span class="DecNumber">1</span></span></tt> and installs the payload in a single atomic bus transaction (<tt class="docutils literal"><span class="pre"><span class="Identifier">cmpxchg16b</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">casp</span></span></tt>).</li>
<li><strong>Dequeue</strong>: Simultaneously reads the payload and recycles sequence to <tt class="docutils literal"><span class="pre"><span class="Identifier">pos</span> <span class="Operator">+</span> <span class="Identifier">N</span></span></tt>.</li>
<li><strong>Cache Density</strong>: With 16-byte slots, 4 slots pack into a single 64-byte line (or 8 on Apple Silicon 128-byte lines), reducing memory footprint by up to 75% compared to cache-padded cell structures.</li>
</ul>


## Types

### `BQueue128Slot`

```nim
BQueue128Slot[T] = Atomic[Pair[uint64, T]]
```

16-byte slot holding monotonic sequence counter (<tt class="docutils literal"><span class="pre"><span class="Identifier">Pair</span><span class="Operator">.</span><span class="Identifier">first</span></span></tt>) and payload (<tt class="docutils literal"><span class="pre"><span class="Identifier">Pair</span><span class="Operator">.</span><span class="Identifier">second</span></span></tt>) in a single hardware DWCAS-able atomic word.

### `BQueue128`

```nim
BQueue128[T; N] = object
  head* {.align: 128.}: Atomic[uint64]
  tail* {.align: 128.}: Atomic[uint64]
  cells* {.align: 128.}: array[N, BQueue128Slot[T]]
```

Bounded lock-free MPMC queue utilizing 128-bit atomic DWCAS for instantaneous slot publication without intermediate partial-write states.


## Procedures & Functions

### `initBQueue128`

```nim
proc initBQueue128[T: uint64 | int64 | pointer | int; N: static int](): BQueue128[
    T, N]
```

Initializes a value-type <tt class="docutils literal"><span class="pre"><span class="Identifier">BQueue128</span></span></tt> with compile-time power-of-two capacity <tt class="docutils literal"><span class="pre"><span class="Identifier">N</span></span></tt>. Inlined storage owns <tt class="docutils literal"><span class="pre"><span class="Identifier">array</span><span class="Punctuation">[</span><span class="Identifier">N</span><span class="Punctuation">,</span> <span class="Identifier">BQueue128Slot</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span><span class="Punctuation">]</span></span></tt>.

### `allocAlignedBQueue128`

```nim
proc allocAlignedBQueue128[T: uint64 | int64 | pointer | int; N: static int](): ptr BQueue128[
    T, N]
```

Allocates a heap-allocated <tt class="docutils literal"><span class="pre"><span class="Identifier">BQueue128</span></span></tt> instance guaranteed to be aligned to at least <tt class="docutils literal"><span class="pre"><span class="Identifier">CacheLineBytes</span></span></tt> (64 bytes on x86_64, 128 bytes on Apple Silicon). Free with <tt class="docutils literal"><span class="pre"><span class="Identifier">freeAlignedBQueue128</span></span></tt>.

### `freeAlignedBQueue128`

```nim
proc freeAlignedBQueue128[T: uint64 | int64 | pointer | int; N: static int](
    q: ptr BQueue128[T, N])
```

Releases a heap-allocated <tt class="docutils literal"><span class="pre"><span class="Identifier">BQueue128</span></span></tt> instance previously created by <tt class="docutils literal"><span class="pre"><span class="Identifier">allocAlignedBQueue128</span></span></tt>.

### ``=copy``

```nim
proc `=copy`[T, N](dest: var BQueue128[T, N]; src: BQueue128[T, N]) {.error: "BQueue128 contains inlined atomic storage and cannot be copied. Pass by `var` or `ptr`.".}
```

### `tryPush`

```nim
proc tryPush[T: uint64 | int64 | pointer | int; N: static int](
    self: var BQueue128[T, N]; val: T): bool {.inline.}
```

<p>Enqueues <tt class="docutils literal"><span class="pre"><span class="Identifier">val</span></span></tt> into the queue.</p>
<p>Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt> if enqueued successfully. Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">false</span></span></tt> immediately if the queue is full.</p>
<p>Uses 128-bit hardware DWCAS (<tt class="docutils literal"><span class="pre"><span class="Identifier">cmpxchg16b</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">casp</span></span></tt>) to atomically advance the slot turn and publish the payload in a single instruction.</p>

### `tryPop`

```nim
proc tryPop[T: uint64 | int64 | pointer | int; N: static int](
    self: var BQueue128[T, N]; val: var T): bool {.inline.}
```

<p>Dequeues an item from the queue, storing it in <tt class="docutils literal"><span class="pre"><span class="Identifier">val</span></span></tt>.</p>
<p>Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt> if an item was dequeued. Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">false</span></span></tt> immediately if the queue is empty.</p>

### `pop`

```nim
proc pop[T: uint64 | int64 | pointer | int; N: static int](
    self: var BQueue128[T, N]): Option[T] {.inline.}
```

Dequeues an item from the queue returning <tt class="docutils literal"><span class="pre"><span class="Identifier">some</span><span class="Punctuation">(</span><span class="Identifier">item</span><span class="Punctuation">)</span></span></tt> or <tt class="docutils literal"><span class="pre"><span class="Identifier">none</span><span class="Punctuation">(</span><span class="Identifier">T</span><span class="Punctuation">)</span></span></tt> if empty.

### `tryPeek`

```nim
proc tryPeek[T: uint64 | int64 | pointer | int; N: static int](
    self: BQueue128[T, N]; val: var T): bool {.inline.}
```

<p>Optimistically inspects the item at the head of the queue without dequeuing.</p>
<p>Note: In concurrent multi-consumer environments, peek is inherently racy.</p>

### `peek`

```nim
proc peek[T: uint64 | int64 | pointer | int; N: static int](
    self: BQueue128[T, N]): Option[T] {.inline.}
```

Optimistically inspects the item at the head of the queue returning <tt class="docutils literal"><span class="pre"><span class="Identifier">Option</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>.

### `len`

```nim
proc len[T, N](self: BQueue128[T, N]): int {.inline.}
```

Returns an approximate snapshot of the number of items currently in the queue.

### `capacity`

```nim
proc capacity[T, N](self: BQueue128[T, N]): int {.inline.}
```

Returns the maximum fixed capacity of the queue (<tt class="docutils literal"><span class="pre"><span class="Identifier">N</span></span></tt>).

### `isEmpty`

```nim
proc isEmpty[T, N](self: BQueue128[T, N]): bool {.inline.}
```

Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt> if the queue is approximately empty.

### `isFull`

```nim
proc isFull[T, N](self: BQueue128[T, N]): bool {.inline.}
```

Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt> if the queue is approximately full.

### `clear`

```nim
proc clear[T, N](self: var BQueue128[T, N])
```

Drains all elements from the queue until empty.

### `drain`

```nim
proc drain[T, N](self: var BQueue128[T, N]): seq[T]
```

Drains all elements from the queue into a seq.


## Templates

### `push`

```nim
template push[T, N](self: var BQueue128[T, N]; val: T): bool
```

Convenience alias for <tt class="docutils literal"><span class="pre"><span class="Identifier">tryPush</span></span></tt>.


## Iterators

### `items`

```nim
iterator items[T, N](self: var BQueue128[T, N]): T
```

Warning: Destructively drains the queue until empty, yielding each element.

