---
title: "lockfree/stack"
description: "API reference for lockfree/stack"
---

=========================================================================== Concurrency Topology: MPMC (Multi-Producer Multi-Consumer) Lock-Free LIFO Stack with Elimination-Backoff<hr />
<p>A high-performance, non-blocking MPMC LIFO stack based on the classic Treiber stack (Treiber, 1986) augmented with an Elimination-Backoff Array (Hendler, Shavit, Yerushalmi, 2004).</p>
<p>Topology:</p>
<ul class="simple"><li>Producers: Multi-Producer (MP) — concurrent lock-free push operations.</li>
<li>Consumers: Multi-Consumer (MC) — concurrent lock-free pop operations.</li>
<li>Ordering: LIFO (Last-In First-Out) linearizable semantics.</li>
<li>Contention Management: Elimination-Backoff Array allows concurrent pairs of push and pop operations to exchange payloads and cancel out without touching the central stack top pointer.</li>
<li>Memory Safety: Tagged atomic pointers (128-bit DWCAS) eliminate the ABA problem on the stack top pointer; NEBR epoch-based safe memory reclamation (DebraManager) and per-node claim synchronization guarantee zero use-after-free, zero data races during concurrent preemption, and tear-free reclamation under ARC, ORC, atomicArc, and refc memory managers.</li>
</ul>
typestates verified


## Types

### `TreiberStackLifecycleCtx`

```nim
TreiberStackLifecycleCtx[T] = object of RootObj
```

Phantom context type for the <tt class="docutils literal"><span class="pre"><span class="Identifier">TreiberStack</span></span></tt> Middle-axis Lifecycle typestate.

### `TreiberStackInit`

```nim
TreiberStackInit[T] = distinct TreiberStackLifecycleCtx[T]
```

Initial Lifecycle state for a <tt class="docutils literal"><span class="pre"><span class="Identifier">TreiberStack</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>.

### `TreiberStackDestroyed`

```nim
TreiberStackDestroyed[T] = distinct TreiberStackLifecycleCtx[T]
```

Terminal Lifecycle state for a <tt class="docutils literal"><span class="pre"><span class="Identifier">TreiberStack</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>, reached via <tt class="docutils literal"><span class="pre"><span class="Operator">=</span><span class="Identifier">destroy</span></span></tt>.

### `TreiberStackLifecycleState`

```nim
TreiberStackLifecycleState = enum
  fsTreiberStackDestroyed, fsTreiberStackInit
```

### `TreiberStackLifecycleStates`

```nim
TreiberStackLifecycleStates[T] = TreiberStackDestroyed[T] | TreiberStackInit[T]
```

### `TreiberStack`

```nim
TreiberStack[T] {..} = object
```

### `Stack`

```nim
Stack[T] = TreiberStack[T]
```

### `ConcurrentStack`

```nim
ConcurrentStack[T] = TreiberStack[T]
```


## Constants

### `EliminationCapacity`

```nim
EliminationCapacity = 8
```

Default number of collision slots in the Elimination-Backoff Array. Must be a power of 2 for fast modulo bitmasking.

### `EliminationSpins`

```nim
EliminationSpins = 32
```

Spin count for a pusher waiting in an elimination slot for a concurrent popper.

### `DefaultStackMaxThreads`

```nim
DefaultStackMaxThreads = 64
```

Maximum concurrent threads registered with a stack's NEBR SMR manager.


## Procedures & Functions

### `state`

```nim
proc state[T](f: TreiberStackDestroyed[T]): TreiberStackLifecycleState
```

Runtime state inspection for TreiberStackDestroyed. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state[T](f: TreiberStackInit[T]): TreiberStackLifecycleState
```

Runtime state inspection for TreiberStackInit. Returns the enum value for pattern matching in case expressions.

### ``$``

```nim
proc `$`[T](s: TreiberStackDestroyed[T]): string
```

String representation for state 'TreiberStackDestroyed'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`[T](s: TreiberStackInit[T]): string
```

String representation for state 'TreiberStackInit'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`(s: TreiberStackLifecycleState): string {.raises: [], tags: [],
    forbids: [].}
```

String representation of TreiberStackLifecycleState enum. Strips the fs prefix for human-friendly output.

### `registerThread`

```nim
proc registerThread[T](self: var TreiberStack[T])
```

Explicitly registers the calling thread with the stack's NEBR SMR manager.

### `unregisterThread`

```nim
proc unregisterThread[T](self: var TreiberStack[T]) {.gcsafe.}
```

Drains any pending retired nodes in the calling thread's limbo bags and unregisters the thread from the stack's NEBR SMR manager.

### `push`

```nim
proc push[T](self: var TreiberStack[T]; item: sink T)
```

Pushes an item onto the stack. Thread-safe, non-blocking MPMC.

### `push`

```nim
proc push[T](self: var TreiberStack[T]; items: openArray[T])
```

Pushes multiple items onto the stack in order.

### `pop`

```nim
proc pop[T](self: var TreiberStack[T]): Option[T]
```

Pops an item from the stack in LIFO order. Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">some</span><span class="Punctuation">(</span><span class="Identifier">item</span><span class="Punctuation">)</span></span></tt> if available, or <tt class="docutils literal"><span class="pre"><span class="Identifier">none</span><span class="Punctuation">(</span><span class="Identifier">T</span><span class="Punctuation">)</span></span></tt> if the stack is empty.

### `peek`

```nim
proc peek[T](self: var TreiberStack[T]): Option[T]
```

Returns a copy of the item at the top of the stack without removing it, or <tt class="docutils literal"><span class="pre"><span class="Identifier">none</span><span class="Punctuation">(</span><span class="Identifier">T</span><span class="Punctuation">)</span></span></tt> if the stack is currently empty.

### `peek`

```nim
proc peek[T](self: TreiberStack[T]): Option[T] {.inline.}
```

### `len`

```nim
proc len[T](self: var TreiberStack[T]): int {.inline.}
```

Returns the approximate number of items currently in the stack.

### `len`

```nim
proc len[T](self: TreiberStack[T]): int {.inline.}
```

### `isEmpty`

```nim
proc isEmpty[T](self: var TreiberStack[T]): bool {.inline.}
```

Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt> if the stack is currently empty, <tt class="docutils literal"><span class="pre"><span class="Identifier">false</span></span></tt> otherwise.

### `isEmpty`

```nim
proc isEmpty[T](self: TreiberStack[T]): bool {.inline.}
```

### `drain`

```nim
proc drain[T](self: var TreiberStack[T]): seq[T]
```

Atomically detaches all items currently in the stack and returns them in LIFO order.

### `drainInto`

```nim
proc drainInto[T](self: var TreiberStack[T]; dest: var seq[T])
```

Atomically detaches all items currently in the stack and appends them to <tt class="docutils literal"><span class="pre"><span class="Identifier">dest</span></span></tt> in LIFO order.

### `initTreiberStack`

```nim
proc initTreiberStack[T](): TreiberStack[T]
```

Creates an empty <tt class="docutils literal"><span class="pre"><span class="Identifier">TreiberStack</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>.

### `newTreiberStack`

```nim
proc newTreiberStack[T](): TreiberStack[T]
```

Creates an empty <tt class="docutils literal"><span class="pre"><span class="Identifier">TreiberStack</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>.

### `initStack`

```nim
proc initStack[T](): Stack[T]
```

Creates an empty <tt class="docutils literal"><span class="pre"><span class="Identifier">Stack</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>.

### `newStack`

```nim
proc newStack[T](): Stack[T]
```

Creates an empty <tt class="docutils literal"><span class="pre"><span class="Identifier">Stack</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>.

### `newConcurrentStack`

```nim
proc newConcurrentStack[T](): ref ConcurrentStack[T]
```

Allocates an empty <tt class="docutils literal"><span class="pre"><span class="Identifier">ConcurrentStack</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> on the heap.

### ``=destroy``

```nim
proc `=destroy`[T](self: var TreiberStack[T]) {.transitionError: "TreiberStack used after =destroy (lifecycle: TreiberStackInit -> TreiberStackDestroyed).",
    raises: [], raises: [].}
```

Cleans up all resources, freeing active and retired nodes.

### ``=copy``

```nim
proc `=copy`[T](dest: var TreiberStack[T]; src: TreiberStack[T]) {.error: "Copying a ConcurrentStack is disallowed; share via reference or pointer across threads.".}
```

### `push`

```nim
proc push[T; Tag: SpscProducerTag | MpmcProducerTag | AnyThreadTag](
    self: Bound[T, Tag, TreiberStack[T]]; item: sink T): bool {.discardable,
    tags: [Tag, TypestateOp, RootEffect], raises: [], notATransition.}
```

Pushes <tt class="docutils literal"><span class="pre"><span class="Identifier">item</span></span></tt> onto a <tt class="docutils literal"><span class="pre"><span class="Identifier">Bound</span></span></tt> producer endpoint for <tt class="docutils literal"><span class="pre"><span class="Identifier">TreiberStack</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>.

### `push`

```nim
proc push[T; Tag: SpscConsumerTag | MpmcConsumerTag](
    self: Bound[T, Tag, TreiberStack[T]]; item: sink T): bool {.error: "push on a consumer-tagged TreiberStack endpoint (SpscConsumerTag / MpmcConsumerTag) is forbidden; bind a producer endpoint via getProducer().",
    notATransition.}
```

### `pop`

```nim
proc pop[T; Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag](
    self: Bound[T, Tag, TreiberStack[T]]): Option[T] {.
    tags: [Tag, TypestateOp, RootEffect], raises: [], notATransition.}
```

Pops an item from a <tt class="docutils literal"><span class="pre"><span class="Identifier">Bound</span></span></tt> consumer endpoint for <tt class="docutils literal"><span class="pre"><span class="Identifier">TreiberStack</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>.

### `pop`

```nim
proc pop[T; Tag: SpscProducerTag | MpmcProducerTag](
    self: Bound[T, Tag, TreiberStack[T]]): Option[T] {.error: "pop on a producer-tagged TreiberStack endpoint (SpscProducerTag / MpmcProducerTag) is forbidden; bind a consumer endpoint via getConsumer().",
    notATransition.}
```

### `peek`

```nim
proc peek[T; Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag](
    self: Bound[T, Tag, TreiberStack[T]]): Option[T] {.
    tags: [Tag, TypestateOp, RootEffect], raises: [], notATransition.}
```

Peeks at the top item through a <tt class="docutils literal"><span class="pre"><span class="Identifier">Bound</span></span></tt> consumer endpoint for <tt class="docutils literal"><span class="pre"><span class="Identifier">TreiberStack</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>.

### `len`

```nim
proc len[T; Tag](self: Bound[T, Tag, TreiberStack[T]]): int {.inline,
    notATransition.}
```

### `isEmpty`

```nim
proc isEmpty[T; Tag](self: Bound[T, Tag, TreiberStack[T]]): bool {.inline,
    notATransition.}
```

### `activeThreadCount`

```nim
proc activeThreadCount[T](self: var TreiberStack[T]): int {.inline,
    notATransition.}
```

Returns the number of threads currently registered with the stack's NEBR manager.


## Macros

### `match`

```nim
macro match[T](value: TreiberStackLifecycleStates[T]; arms: untyped): untyped
```

Single-target pattern match on states of typestate 'TreiberStackLifecycle'; rewrites to <tt class="docutils literal"><span class="pre"><span class="Keyword">block</span><span class="Punctuation">:</span> <span class="Keyword">let</span> <span class="Keyword">bind</span> <span class="Operator">=</span> <span class="Identifier">move</span><span class="Punctuation">(</span><span class="Identifier">value</span><span class="Punctuation">)</span><span class="Punctuation">;</span> <span class="Identifier">body</span></span></tt>. Syntax is <tt class="docutils literal"><span class="pre"><span class="Operator">&lt;</span><span class="Identifier">StateName</span><span class="Operator">&gt;</span><span class="Punctuation">(</span><span class="Keyword">bind</span><span class="Punctuation">)</span><span class="Punctuation">:</span></span></tt>, with exactly one arm.

### `TreiberStackLifecycle`

```nim
macro TreiberStackLifecycle(initial`gensym0: untyped; typeDef`gensym0: untyped): untyped
```

Typestate-attachment pragma (auto-generated; see §3.7 of the v0.9.0 design doc). Apply to a type declaration to bind the type to this typestate with <tt class="docutils literal"><span class="pre"><span class="Identifier">initial</span></span></tt> as the starting state. Validates TA-002..TA-004 at compile time and populates <tt class="docutils literal"><span class="pre"><span class="Identifier">typestateAttachments</span></span></tt>.

