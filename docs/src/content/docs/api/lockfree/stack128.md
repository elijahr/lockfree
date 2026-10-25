---
title: "lockfree/stack128"
description: "API reference for lockfree/stack128"
---

=========================================================================== Concurrency Topology: 128-Bit Hardware DWCAS Lock-Free LIFO Stack (<tt class="docutils literal"><span class="pre"><span class="Identifier">TaggedStack</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">Stack128</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>)<hr />
<p>A high-performance, non-blocking MPMC LIFO stack that leverages hardware 128-Bit Double-Word Compare-And-Swap (DWCAS) to eliminate the ABA problem without requiring Safe Memory Reclamation (SMR) or thread registration.</p>
<p>Key Properties:</p>
<ul class="simple"><li><strong>Hardware 128-Bit Atomic Top</strong>: The stack top is represented as an <tt class="docutils literal"><span class="pre"><span class="Identifier">Atomic</span><span class="Punctuation">[</span><span class="Identifier">Pair</span><span class="Punctuation">[</span><span class="Identifier">uint64</span><span class="Punctuation">,</span> <span class="Identifier">uint64</span><span class="Punctuation">]</span><span class="Punctuation">]</span></span></tt> packing <tt class="docutils literal"><span class="pre"><span class="Punctuation">[</span><span class="Identifier">node_pointer</span> <span class="Operator">|</span> <span class="DecNumber">64</span><span class="Operator">-</span><span class="Identifier">bit</span> <span class="Identifier">ABA</span> <span class="Identifier">counter</span><span class="Punctuation">]</span></span></tt>. Every push and pop atomically updates the pointer and increments the 64-bit generation counter in a single hardware instruction (<tt class="docutils literal"><span class="pre"><span class="Identifier">casp</span></span></tt> on ARM64, <tt class="docutils literal"><span class="pre"><span class="Identifier">cmpxchg16b</span></span></tt> on x86_64).</li>
<li><strong>Zero SMR / Zero Debra</strong>: SMR engines (Epoch-based or Hazard Pointers) require threads to register, maintain TLS epoch handles, and pin/unpin on every access. <tt class="docutils literal"><span class="pre"><span class="Identifier">TaggedStack</span></span></tt> achieves memory safety via an internal lock-free pooled freelist: popped nodes are recycled to an atomic freelist rather than immediately deallocated to the OS. Because allocated node memory remains valid for the lifetime of the stack, dereferencing <tt class="docutils literal"><span class="pre"><span class="Identifier">node</span><span class="Operator">.</span><span class="Identifier">next</span></span></tt> during a concurrent pop race is guaranteed safe.</li>
<li><strong>Unbounded Growth</strong>: When the freelist is empty, fresh nodes are allocated on demand. On stack destruction (<tt class="docutils literal"><span class="pre"><span class="Operator">=</span><span class="Identifier">destroy</span></span></tt>), all allocated nodes across both the active stack and the freelist are reclaimed.</li>
<li><strong>Copy-Safe</strong>: Explicitly marks <tt class="docutils literal"><span class="pre"><span class="Operator">=</span><span class="Identifier">copy</span></span></tt> with <tt class="docutils literal"><span class="pre"><span class="Punctuation">{</span><span class="Operator">.</span><span class="Identifier">error</span><span class="Operator">.</span><span class="Punctuation">}</span></span></tt> to prevent accidental shallow-copy bugs.</li>
</ul>


## Types

### `TaggedStack`

```nim
TaggedStack[T] = object
  top* {.align: 128.}: Atomic[TaggedHead]
  freeList* {.align: 128.}: Atomic[TaggedHead]
  count* {.align: 128.}: Atomic[int]
```

MPMC Lock-Free LIFO Stack powered by 128-bit hardware DWCAS and pooled recycling. Thread-safe, non-blocking, and requires zero thread registration or epoch SMR.

### `Stack128`

```nim
Stack128[T] = TaggedStack[T]
```

Semantic alias for <tt class="docutils literal"><span class="pre"><span class="Identifier">TaggedStack</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>.


## Procedures & Functions

### ``=copy``

```nim
proc `=copy`[T](dest: var TaggedStack[T]; src: TaggedStack[T]) {.error: "TaggedStack contains inlined atomic state and cannot be copied. Pass by `var` or `ptr`.".}
```

### `initTaggedStack`

```nim
proc initTaggedStack[T](): TaggedStack[T]
```

Initializes an empty value-type <tt class="docutils literal"><span class="pre"><span class="Identifier">TaggedStack</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>.

### `initStack128`

```nim
proc initStack128[T](): Stack128[T] {.inline.}
```

Initializes an empty value-type <tt class="docutils literal"><span class="pre"><span class="Identifier">Stack128</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>. Alias for <tt class="docutils literal"><span class="pre"><span class="Identifier">initTaggedStack</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt>.

### `newTaggedStack`

```nim
proc newTaggedStack[T](): ptr TaggedStack[T]
```

Heap-allocates a cacheline-aligned <tt class="docutils literal"><span class="pre"><span class="Identifier">TaggedStack</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>. Free with <tt class="docutils literal"><span class="pre"><span class="Identifier">freeTaggedStack</span></span></tt>.

### `newStack128`

```nim
proc newStack128[T](): ptr Stack128[T] {.inline.}
```

Heap-allocates a cacheline-aligned <tt class="docutils literal"><span class="pre"><span class="Identifier">Stack128</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>. Alias for <tt class="docutils literal"><span class="pre"><span class="Identifier">newTaggedStack</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt>.

### `freeTaggedStack`

```nim
proc freeTaggedStack[T](s: ptr TaggedStack[T])
```

Releases a heap-allocated <tt class="docutils literal"><span class="pre"><span class="Identifier">TaggedStack</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> instance created with <tt class="docutils literal"><span class="pre"><span class="Identifier">newTaggedStack</span></span></tt>.

### `freeStack128`

```nim
proc freeStack128[T](s: ptr Stack128[T]) {.inline.}
```

### `tryPush`

```nim
proc tryPush[T](self: var TaggedStack[T]; item: var T): bool
```

Attempts to push <tt class="docutils literal"><span class="pre"><span class="Identifier">item</span></span></tt> onto the stack in a single non-blocking attempt. Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt> and moves <tt class="docutils literal"><span class="pre"><span class="Identifier">item</span></span></tt> on success. Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">false</span></span></tt> and leaves <tt class="docutils literal"><span class="pre"><span class="Identifier">item</span></span></tt> completely unmodified on contention.

### `tryPush`

```nim
proc tryPush[T](self: var TaggedStack[T]; item: sink T): bool {.inline.}
```

Convenience overload for <tt class="docutils literal"><span class="pre"><span class="Identifier">tryPush</span></span></tt> taking a sink value.

### `push`

```nim
proc push[T](self: var TaggedStack[T]; item: sink T)
```

Pushes an item onto the stack, retrying with exponential backoff on contention. Thread-safe, non-blocking MPMC.

### `push`

```nim
proc push[T](self: var TaggedStack[T]; items: openArray[T])
```

Pushes multiple items onto the stack in sequence.

### `tryPop`

```nim
proc tryPop[T](self: var TaggedStack[T]; item: var T): bool
```

Attempts to pop an item from the stack in LIFO order. Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt> and assigns <tt class="docutils literal"><span class="pre"><span class="Identifier">item</span></span></tt> if an element was popped; returns <tt class="docutils literal"><span class="pre"><span class="Identifier">false</span></span></tt> if empty.

### `pop`

```nim
proc pop[T](self: var TaggedStack[T]): Option[T]
```

Pops an item from the stack in LIFO order. Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">some</span><span class="Punctuation">(</span><span class="Identifier">item</span><span class="Punctuation">)</span></span></tt> if available, or <tt class="docutils literal"><span class="pre"><span class="Identifier">none</span><span class="Punctuation">(</span><span class="Identifier">T</span><span class="Punctuation">)</span></span></tt> if the stack is empty.

### `peek`

```nim
proc peek[T](self: var TaggedStack[T]): Option[T]
```

Returns a copy of the item at the top of the stack without removing it, or <tt class="docutils literal"><span class="pre"><span class="Identifier">none</span><span class="Punctuation">(</span><span class="Identifier">T</span><span class="Punctuation">)</span></span></tt> if empty. Note that concurrent pops may race with peek.

### `peek`

```nim
proc peek[T](self: TaggedStack[T]): Option[T] {.inline.}
```

### `len`

```nim
proc len[T](self: var TaggedStack[T]): int {.inline.}
```

Returns the approximate number of items in the stack.

### `len`

```nim
proc len[T](self: TaggedStack[T]): int {.inline.}
```

### `isEmpty`

```nim
proc isEmpty[T](self: var TaggedStack[T]): bool {.inline.}
```

Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt> if the stack is currently empty.

### `isEmpty`

```nim
proc isEmpty[T](self: TaggedStack[T]): bool {.inline.}
```

### `clear`

```nim
proc clear[T](self: var TaggedStack[T])
```

Atomically detaches and discards all items currently in the stack.

### `drain`

```nim
proc drain[T](self: var TaggedStack[T]): seq[T]
```

Atomically detaches all items from the stack and returns them in LIFO order.

### `drainInto`

```nim
proc drainInto[T](self: var TaggedStack[T]; dest: var seq[T])
```

Atomically detaches all items and appends them directly into <tt class="docutils literal"><span class="pre"><span class="Identifier">dest</span></span></tt> in LIFO order.

### ``=destroy``

```nim
proc `=destroy`[T](self: var TaggedStack[T]) {.raises: [].}
```

Reclaims all active nodes and pooled freelist nodes.

### `destroy`

```nim
proc destroy[T](self: var TaggedStack[T]) {.inline.}
```

Explicitly destroys and reclaims all active and pooled nodes.


## Iterators

### `items`

```nim
iterator items[T](self: var TaggedStack[T]): T
```

Warning: Destructively drains the stack in LIFO order.

