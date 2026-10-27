---
title: "lockfree/deque"
description: "API reference for lockfree/deque"
---

============================================================================ Concurrency Topology: Single-Worker (pushBottom / popBottom at bottom) Multi-Thief (steal / stealBatch at top)<hr />
<p>Dynamic circular work-stealing deque implementing the Chase-Lev algorithm with formal C11 / weak-memory-model fences (Le, Pop, Cohen, Nardelli PPoPP '13) and bulk multi-item stealing (stealBatch).</p>
<p>Architectural Invariants:</p>
<ol class="simple"><li>Concurrency Topology:<ul class="simple"><li>Worker: operates at <tt class="docutils literal"><span class="pre"><span class="Identifier">bottom</span></span></tt> using LIFO order (pushBottom / popBottom). Minimizes communication latency and maximizes cache locality for divide-and-conquer / fork-join task parallelism.</li>
<li>Thieves: operate at <tt class="docutils literal"><span class="pre"><span class="Identifier">top</span></span></tt> using FIFO order (steal / stealBatch). Steals the oldest (typically largest granularity) tasks from the top, amortizing scheduling overhead across cores.</li>
</ul>
</li>
<li>Dynamic Circular Buffer with SMR-safe Retired Chains:<ul class="simple"><li>Automatically doubles buffer capacity when worker pushes to a full deque.</li>
<li>Previous buffers are retained in an unmanaged retired chain until deque destruction, guaranteeing concurrent thieves reading slots during or after resizing never experience use-after-free or ABA faults.</li>
</ul>
</li>
<li>Strict Memory Ordering:<ul class="simple"><li>Worker push publishes elements via <tt class="docutils literal"><span class="pre"><span class="Identifier">moRelease</span></span></tt> fence prior to relaxed bottom store.</li>
<li>Worker pop issues <tt class="docutils literal"><span class="pre"><span class="Identifier">moSequentiallyConsistent</span></span></tt> fence between bottom decrement and top load.</li>
<li>Thieves synchronize via <tt class="docutils literal"><span class="pre"><span class="Identifier">moAcquire</span></span></tt> top/bottom loads, <tt class="docutils literal"><span class="pre"><span class="Identifier">moSequentiallyConsistent</span></span></tt> fences, and atomic CAS (<tt class="docutils literal"><span class="pre"><span class="Identifier">compareExchangeStrong</span></span></tt>) on <tt class="docutils literal"><span class="pre"><span class="Identifier">top</span></span></tt>.</li>
</ul>
</li>
<li>Cacheline Alignment:<ul class="simple"><li><tt class="docutils literal"><span class="pre"><span class="Identifier">top</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">bottom</span></span></tt>, and <tt class="docutils literal"><span class="pre"><span class="Identifier">buffer</span></span></tt> are placed on distinct <tt class="docutils literal"><span class="pre"><span class="Identifier">CacheLineBytes</span></span></tt> boundaries, preventing false sharing between the active worker and competing thieves.</li>
</ul>
</li>
<li>ARC/ORC Full Lifecycle Compliance:<ul class="simple"><li>Supports POD types, <tt class="docutils literal"><span class="pre"><span class="Keyword">ref</span> <span class="Identifier">T</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">string</span></span></tt>, and <tt class="docutils literal"><span class="pre"><span class="Identifier">seq</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> via <tt class="docutils literal"><span class="pre"><span class="Identifier">SlotEncoding</span></span></tt> and Path-C transfer-ownership contracts without memory leaks.</li>
</ul>
</li>
</ol>
typestates verified


## Types

### `ChaseLevDequeLifecycleCtx`

```nim
ChaseLevDequeLifecycleCtx[T] = object of RootObj
```

Phantom context type for the <tt class="docutils literal"><span class="pre"><span class="Identifier">ChaseLevDeque</span></span></tt> Middle-axis Lifecycle typestate.

### `ChaseLevDequeInit`

```nim
ChaseLevDequeInit[T] = distinct ChaseLevDequeLifecycleCtx[T]
```

Initial Lifecycle state for a <tt class="docutils literal"><span class="pre"><span class="Identifier">ChaseLevDeque</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>.

### `ChaseLevDequeDestroyed`

```nim
ChaseLevDequeDestroyed[T] = distinct ChaseLevDequeLifecycleCtx[T]
```

Terminal Lifecycle state for a <tt class="docutils literal"><span class="pre"><span class="Identifier">ChaseLevDeque</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>, reached via <tt class="docutils literal"><span class="pre"><span class="Operator">=</span><span class="Identifier">destroy</span></span></tt>.

### `ChaseLevDequeLifecycleState`

```nim
ChaseLevDequeLifecycleState = enum
  fsChaseLevDequeDestroyed, fsChaseLevDequeInit
```

### `ChaseLevDequeLifecycleStates`

```nim
ChaseLevDequeLifecycleStates[T] = ChaseLevDequeDestroyed[T] |
    ChaseLevDequeInit[T]
```

### `ChaseLevDeque`

```nim
ChaseLevDeque[T] {..} = object
  core*: ptr ChaseLevDequeCore[T]
```

Lock-free Single-Worker / Multi-Thief work-stealing deque.

### `Deque`

```nim
Deque[T] = ChaseLevDeque[T]
```

### `ConcurrentDeque`

```nim
ConcurrentDeque[T] = ChaseLevDeque[T]
```


## Constants

### `moSeqCst`

```nim
moSeqCst = moSequentiallyConsistent
```

Ergonomic alias for <tt class="docutils literal"><span class="pre"><span class="Identifier">moSequentiallyConsistent</span></span></tt>.


## Procedures & Functions

### `state`

```nim
proc state[T](f: ChaseLevDequeDestroyed[T]): ChaseLevDequeLifecycleState
```

Runtime state inspection for ChaseLevDequeDestroyed. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state[T](f: ChaseLevDequeInit[T]): ChaseLevDequeLifecycleState
```

Runtime state inspection for ChaseLevDequeInit. Returns the enum value for pattern matching in case expressions.

### ``$``

```nim
proc `$`[T](s: ChaseLevDequeDestroyed[T]): string
```

String representation for state 'ChaseLevDequeDestroyed'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`[T](s: ChaseLevDequeInit[T]): string
```

String representation for state 'ChaseLevDequeInit'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`(s: ChaseLevDequeLifecycleState): string {.raises: [], tags: [],
    forbids: [].}
```

String representation of ChaseLevDequeLifecycleState enum. Strips the fs prefix for human-friendly output.

### ``=destroy``

```nim
proc `=destroy`[T](self: var ChaseLevDeque[T]) {.transitionError: "ChaseLevDeque used after =destroy (lifecycle: ChaseLevDequeInit -> ChaseLevDequeDestroyed).",
    raises: [], raises: [].}
```

### ``=copy``

```nim
proc `=copy`[T](dest: var ChaseLevDeque[T]; src: ChaseLevDeque[T])
```

### ``=sink``

```nim
proc `=sink`[T](dest: var ChaseLevDeque[T]; src: ChaseLevDeque[T])
```

### `initChaseLevDeque`

```nim
proc initChaseLevDeque[T](initialCapacity: int = 64): ChaseLevDeque[T]
```

Initializes a new <tt class="docutils literal"><span class="pre"><span class="Identifier">ChaseLevDeque</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> with power-of-two capacity (minimum 16).

### `initDeque`

```nim
proc initDeque[T](initialCapacity: int = 64): Deque[T] {.inline.}
```

Ergonomic alias constructor for <tt class="docutils literal"><span class="pre"><span class="Identifier">ChaseLevDeque</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>.

### `initConcurrentDeque`

```nim
proc initConcurrentDeque[T](initialCapacity: int = 64): ConcurrentDeque[T] {.
    inline.}
```

Ergonomic alias constructor for <tt class="docutils literal"><span class="pre"><span class="Identifier">ChaseLevDeque</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>.

### `newChaseLevDeque`

```nim
proc newChaseLevDeque[T](initialCapacity: int = 64): ChaseLevDeque[T] {.inline.}
```

Alias for <tt class="docutils literal"><span class="pre"><span class="Identifier">initChaseLevDeque</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>.

### `newDeque`

```nim
proc newDeque[T](initialCapacity: int = 64): Deque[T] {.inline.}
```

Alias for <tt class="docutils literal"><span class="pre"><span class="Identifier">initChaseLevDeque</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>.

### `newConcurrentDeque`

```nim
proc newConcurrentDeque[T](initialCapacity: int = 64): ConcurrentDeque[T] {.
    inline.}
```

Alias for <tt class="docutils literal"><span class="pre"><span class="Identifier">initChaseLevDeque</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>.

### `isNil`

```nim
proc isNil[T](self: ChaseLevDeque[T]): bool {.inline.}
```

Returns true if the deque handle has an uninitialized or destroyed core.

### `capacity`

```nim
proc capacity[T](self: ChaseLevDeque[T]): int
```

Returns the current slot capacity of the active circular buffer.

### `len`

```nim
proc len[T](self: ChaseLevDeque[T]): int
```

Returns an approximate count of items currently in the deque. Non-blocking estimation: max(0, bottom - top).

### `isEmpty`

```nim
proc isEmpty[T](self: ChaseLevDeque[T]): bool {.inline.}
```

Returns true if the deque currently contains zero items.

### `pushBottom`

```nim
proc pushBottom[T](self: ChaseLevDeque[T]; item: sink T)
```

Pushes an item to the bottom of the deque. ONLY the single owner-worker thread may invoke pushBottom.

### `popBottom`

```nim
proc popBottom[T](self: ChaseLevDeque[T]): Option[T]
```

Pops an item from the bottom of the deque (LIFO order). ONLY the single owner-worker thread may invoke popBottom. Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">none</span><span class="Punctuation">(</span><span class="Identifier">T</span><span class="Punctuation">)</span></span></tt> if the deque is empty.

### `tryPopBottom`

```nim
proc tryPopBottom[T](self: ChaseLevDeque[T]; item: var T): bool
```

Attempts to pop an item from the bottom. Returns true on success and assigns to <tt class="docutils literal"><span class="pre"><span class="Identifier">item</span></span></tt>.

### `steal`

```nim
proc steal[T](self: ChaseLevDeque[T]): Option[T]
```

Steals an item from the top of the deque (FIFO order). May be invoked concurrently by ANY number of thief threads. Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">none</span><span class="Punctuation">(</span><span class="Identifier">T</span><span class="Punctuation">)</span></span></tt> if the deque is empty or on CAS contention with peers.

### `trySteal`

```nim
proc trySteal[T](self: ChaseLevDeque[T]; item: var T): bool
```

Attempts to steal an item from top. Returns true on success and assigns to <tt class="docutils literal"><span class="pre"><span class="Identifier">item</span></span></tt>.

### `stealBatch`

```nim
proc stealBatch[T](self: ChaseLevDeque[T]; dest: var openArray[T];
                   maxItems: int = -1): int
```

Steals a batch of items from the top of the deque via per-slot CAS to prevent racing with popBottom jumping top past bottom (CVE-2021-32810). Writes stolen items to <tt class="docutils literal"><span class="pre"><span class="Identifier">dest</span><span class="Punctuation">[</span><span class="DecNumber">0</span> <span class="Operator">..&lt;</span> <span class="Identifier">stolenCount</span><span class="Punctuation">]</span></span></tt> in FIFO order and returns <tt class="docutils literal"><span class="pre"><span class="Identifier">stolenCount</span></span></tt>. If <tt class="docutils literal"><span class="pre"><span class="Identifier">maxItems</span> <span class="Operator">&lt;=</span> <span class="DecNumber">0</span></span></tt>, defaults to stealing up to <tt class="docutils literal"><span class="pre"><span class="Identifier">min</span><span class="Punctuation">(</span><span class="Identifier">dest</span><span class="Operator">.</span><span class="Identifier">len</span><span class="Punctuation">,</span> <span class="Punctuation">(</span><span class="Identifier">available</span> <span class="Operator">+</span> <span class="DecNumber">1</span><span class="Punctuation">)</span> <span class="Keyword">div</span> <span class="DecNumber">2</span><span class="Punctuation">)</span></span></tt>.

### `stealBatch`

```nim
proc stealBatch[T](self: ChaseLevDeque[T]; maxItems: int = -1): seq[T]
```

Steals a batch of items from the top of the deque into a new <tt class="docutils literal"><span class="pre"><span class="Identifier">seq</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>. If <tt class="docutils literal"><span class="pre"><span class="Identifier">maxItems</span> <span class="Operator">&lt;=</span> <span class="DecNumber">0</span></span></tt>, defaults to stealing up to <tt class="docutils literal"><span class="pre"><span class="Punctuation">(</span><span class="Identifier">available</span> <span class="Operator">+</span> <span class="DecNumber">1</span><span class="Punctuation">)</span> <span class="Keyword">div</span> <span class="DecNumber">2</span></span></tt>.

### ``$``

```nim
proc `$`[T](self: ChaseLevDeque[T]): string
```

### `pushBottom`

```nim
proc pushBottom[T; Tag: DequeOwnerTag | AnyThreadTag](
    self: Bound[T, Tag, ChaseLevDeque[T]]; item: sink T) {.
    tags: [Tag, TypestateOp, RootEffect], raises: [], notATransition.}
```

Pushes an item to the bottom of the deque via a <tt class="docutils literal"><span class="pre"><span class="Identifier">Bound</span></span></tt> owner endpoint.

### `popBottom`

```nim
proc popBottom[T; Tag: DequeOwnerTag | AnyThreadTag](
    self: Bound[T, Tag, ChaseLevDeque[T]]): Option[T] {.
    tags: [Tag, TypestateOp, RootEffect], raises: [], notATransition.}
```

Pops an item from the bottom of the deque via a <tt class="docutils literal"><span class="pre"><span class="Identifier">Bound</span></span></tt> owner endpoint.

### `tryPopBottom`

```nim
proc tryPopBottom[T; Tag: DequeOwnerTag | AnyThreadTag](
    self: Bound[T, Tag, ChaseLevDeque[T]]; item: var T): bool {.
    tags: [Tag, TypestateOp, RootEffect], raises: [], notATransition.}
```

Attempts to pop an item from the bottom via a <tt class="docutils literal"><span class="pre"><span class="Identifier">Bound</span></span></tt> owner endpoint.

### `pushBottom`

```nim
proc pushBottom[T](self: Bound[T, DequeThiefTag, ChaseLevDeque[T]]; item: sink T) {.error: "pushBottom on a DequeThiefTag endpoint is forbidden; only the single DequeOwnerTag endpoint may operate at the bottom of ChaseLevDeque.",
    notATransition.}
```

### `popBottom`

```nim
proc popBottom[T](self: Bound[T, DequeThiefTag, ChaseLevDeque[T]]): Option[T] {.error: "popBottom on a DequeThiefTag endpoint is forbidden; only the single DequeOwnerTag endpoint may operate at the bottom of ChaseLevDeque.",
    notATransition.}
```

### `tryPopBottom`

```nim
proc tryPopBottom[T](self: Bound[T, DequeThiefTag, ChaseLevDeque[T]];
                     item: var T): bool {.error: "tryPopBottom on a DequeThiefTag endpoint is forbidden; only the single DequeOwnerTag endpoint may operate at the bottom of ChaseLevDeque.",
    notATransition.}
```

### `steal`

```nim
proc steal[T; Tag: DequeThiefTag | AnyThreadTag](
    self: Bound[T, Tag, ChaseLevDeque[T]]): Option[T] {.
    tags: [Tag, TypestateOp, RootEffect], raises: [], notATransition.}
```

Steals an item from the top of the deque via a <tt class="docutils literal"><span class="pre"><span class="Identifier">Bound</span></span></tt> thief endpoint.

### `trySteal`

```nim
proc trySteal[T; Tag: DequeThiefTag | AnyThreadTag](
    self: Bound[T, Tag, ChaseLevDeque[T]]; item: var T): bool {.
    tags: [Tag, TypestateOp, RootEffect], raises: [], notATransition.}
```

Attempts to steal an item from the top via a <tt class="docutils literal"><span class="pre"><span class="Identifier">Bound</span></span></tt> thief endpoint.

### `stealBatch`

```nim
proc stealBatch[T; Tag: DequeThiefTag | AnyThreadTag](
    self: Bound[T, Tag, ChaseLevDeque[T]]; dest: var openArray[T];
    maxItems: int = -1): int {.tags: [Tag, TypestateOp, RootEffect], raises: [],
                               notATransition.}
```

Steals a batch of items from the top via a <tt class="docutils literal"><span class="pre"><span class="Identifier">Bound</span></span></tt> thief endpoint.

### `stealBatch`

```nim
proc stealBatch[T; Tag: DequeThiefTag | AnyThreadTag](
    self: Bound[T, Tag, ChaseLevDeque[T]]; maxItems: int = -1): seq[T] {.
    tags: [Tag, TypestateOp, RootEffect], raises: [], notATransition.}
```

Steals a batch of items into a new <tt class="docutils literal"><span class="pre"><span class="Identifier">seq</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> via a <tt class="docutils literal"><span class="pre"><span class="Identifier">Bound</span></span></tt> thief endpoint.

### `steal`

```nim
proc steal[T](self: Bound[T, DequeOwnerTag, ChaseLevDeque[T]]): Option[T] {.error: "steal on a DequeOwnerTag endpoint is forbidden; use popBottom on the owner endpoint or bind a DequeThiefTag endpoint via getThief().",
    notATransition.}
```

### `trySteal`

```nim
proc trySteal[T](self: Bound[T, DequeOwnerTag, ChaseLevDeque[T]]; item: var T): bool {.error: "trySteal on a DequeOwnerTag endpoint is forbidden; use tryPopBottom on the owner endpoint or bind a DequeThiefTag endpoint via getThief().",
    notATransition.}
```

### `stealBatch`

```nim
proc stealBatch[T](self: Bound[T, DequeOwnerTag, ChaseLevDeque[T]];
                   maxItems: int = -1): seq[T] {.error: "stealBatch on a DequeOwnerTag endpoint is forbidden; bind a DequeThiefTag endpoint via getThief().",
    notATransition.}
```

### `len`

```nim
proc len[T; Tag](self: Bound[T, Tag, ChaseLevDeque[T]]): int {.inline,
    notATransition.}
```

### `capacity`

```nim
proc capacity[T; Tag](self: Bound[T, Tag, ChaseLevDeque[T]]): int {.inline,
    notATransition.}
```

### `isEmpty`

```nim
proc isEmpty[T; Tag](self: Bound[T, Tag, ChaseLevDeque[T]]): bool {.inline,
    notATransition.}
```


## Macros

### `match`

```nim
macro match[T](value: ChaseLevDequeLifecycleStates[T]; arms: untyped): untyped
```

Single-target pattern match on states of typestate 'ChaseLevDequeLifecycle'; rewrites to <tt class="docutils literal"><span class="pre"><span class="Keyword">block</span><span class="Punctuation">:</span> <span class="Keyword">let</span> <span class="Keyword">bind</span> <span class="Operator">=</span> <span class="Identifier">move</span><span class="Punctuation">(</span><span class="Identifier">value</span><span class="Punctuation">)</span><span class="Punctuation">;</span> <span class="Identifier">body</span></span></tt>. Syntax is <tt class="docutils literal"><span class="pre"><span class="Operator">&lt;</span><span class="Identifier">StateName</span><span class="Operator">&gt;</span><span class="Punctuation">(</span><span class="Keyword">bind</span><span class="Punctuation">)</span><span class="Punctuation">:</span></span></tt>, with exactly one arm.

### `ChaseLevDequeLifecycle`

```nim
macro ChaseLevDequeLifecycle(initial`gensym0: untyped; typeDef`gensym0: untyped): untyped
```

Typestate-attachment pragma (auto-generated; see §3.7 of the v0.9.0 design doc). Apply to a type declaration to bind the type to this typestate with <tt class="docutils literal"><span class="pre"><span class="Identifier">initial</span></span></tt> as the starting state. Validates TA-002..TA-004 at compile time and populates <tt class="docutils literal"><span class="pre"><span class="Identifier">typestateAttachments</span></span></tt>.

