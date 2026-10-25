---
title: "lockfree/bstack"
description: "API reference for lockfree/bstack"
---

=========================================================================== Concurrency Topology: SPSC, MPSC, SPMC, MPMC Bounded Lock-Free LIFO Stack (<tt class="docutils literal"><span class="pre"><span class="Identifier">BStack</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">,</span> <span class="Identifier">Cap</span><span class="Punctuation">,</span> <span class="Identifier">ccProd</span><span class="Punctuation">,</span> <span class="Identifier">ccCons</span><span class="Punctuation">]</span></span></tt>)<hr />
<p>A preallocated, zero-SMR, zero-heap-allocation bounded lock-free LIFO stack supporting all four producer/consumer cardinality topologies (<tt class="docutils literal"><span class="pre"><span class="Identifier">ccSingle</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">ccMulti</span></span></tt>) and an integrated cache-line-aligned Elimination-Backoff Array (Hendler, Shavit, Yerushalmi, 2004) for MPMC high-contention pairs.</p>
<p>Key properties:</p>
<ul class="simple"><li><strong>Preallocated Contiguous Storage</strong>: All <tt class="docutils literal"><span class="pre"><span class="Identifier">Cap</span></span></tt> stack slots and elimination slots are preallocated inside <tt class="docutils literal"><span class="pre"><span class="Identifier">BStackCore</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">,</span> <span class="Identifier">Cap</span><span class="Punctuation">]</span></span></tt> at initialization time.</li>
<li><strong>Zero Hot-Path Heap Allocation</strong>: <tt class="docutils literal"><span class="pre"><span class="Identifier">tryPush</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">push</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">tryPop</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">pop</span></span></tt>, and <tt class="docutils literal"><span class="pre"><span class="Identifier">peek</span></span></tt> never allocate or free heap memory.</li>
<li><strong>Zero SMR / Zero NEBR</strong>: Slots remain valid for the lifetime of the stack and use 64-bit tagged index CAS (<tt class="docutils literal"><span class="pre"><span class="Punctuation">[</span><span class="DecNumber">32</span><span class="Operator">-</span><span class="Identifier">bit</span> <span class="Identifier">ABA</span> <span class="Identifier">tag</span> <span class="Operator">|</span> <span class="DecNumber">32</span><span class="Operator">-</span><span class="Identifier">bit</span> <span class="Identifier">slot</span> <span class="Identifier">index</span><span class="Punctuation">]</span></span></tt>) on both <tt class="docutils literal"><span class="pre"><span class="Identifier">top</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">freeHead</span></span></tt> to prevent ABA without epoch reclamation.</li>
<li><strong>ARC/ORC Memory Safety</strong>: Popped or cleared slots invoke <tt class="docutils literal"><span class="pre"><span class="Identifier">reset</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt> before returning indices to <tt class="docutils literal"><span class="pre"><span class="Identifier">freeHead</span></span></tt>, ensuring deterministic destruction of managed payloads (<tt class="docutils literal"><span class="pre"><span class="Identifier">string</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">seq</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Keyword">ref</span></span></tt>) and zero TSan data races.</li>
</ul>
typestates verified


## Types

### `BStackLifecycleCtx`

```nim
BStackLifecycleCtx[T; Cap; ccProd; ccCons] = object of RootObj
```

Phantom context type for the <tt class="docutils literal"><span class="pre"><span class="Identifier">BStack</span></span></tt> Middle-axis Lifecycle typestate.

### `BStackInit`

```nim
BStackInit[T; Cap; ccProd; ccCons] = distinct BStackLifecycleCtx[T, Cap, ccProd,
    ccCons]
```

Initial Lifecycle state for a <tt class="docutils literal"><span class="pre"><span class="Identifier">BStack</span></span></tt>.

### `BStackDestroyed`

```nim
BStackDestroyed[T; Cap; ccProd; ccCons] = distinct BStackLifecycleCtx[T, Cap,
    ccProd, ccCons]
```

Terminal Lifecycle state for a <tt class="docutils literal"><span class="pre"><span class="Identifier">BStack</span></span></tt>, reached via <tt class="docutils literal"><span class="pre"><span class="Operator">=</span><span class="Identifier">destroy</span></span></tt>.

### `BStackLifecycleState`

```nim
BStackLifecycleState = enum
  fsBStackDestroyed, fsBStackInit
```

### `BStackLifecycleStates`

```nim
BStackLifecycleStates[T; Cap; ccProd; ccCons] = BStackDestroyed[T, Cap, ccProd,
    ccCons] |
    BStackInit[T, Cap, ccProd, ccCons]
```

### `BStackCore`

```nim
BStackCore[T; Cap] = object
  top* {.align: 128.}: Atomic[uint64]
  freeHead* {.align: 128.}: Atomic[uint64]
  count* {.align: 128.}: Atomic[int]
  rc* {.align: 128.}: Atomic[int]
  effCap*: int
  elimination*: array[BStackEliminationCapacity, BStackElimSlot[T]]
  slots*: array[Cap, BStackSlot[T]]
```

### `BStack`

```nim
BStack[T; Cap; ccProd; ccCons] {..} = object
  core*: ptr BStackCore[T, Cap]
```

### `BoundedStack`

```nim
BoundedStack[T; Cap; ccProd; ccCons] = BStack[T, Cap, ccProd, ccCons]
```

### `SpscBoundedStack`

```nim
SpscBoundedStack[T; Cap] = BStack[T, Cap, ccSingle, ccSingle]
```

### `MpscBoundedStack`

```nim
MpscBoundedStack[T; Cap] = BStack[T, Cap, ccMulti, ccSingle]
```

### `SpmcBoundedStack`

```nim
SpmcBoundedStack[T; Cap] = BStack[T, Cap, ccSingle, ccMulti]
```

### `MpmcBoundedStack`

```nim
MpmcBoundedStack[T; Cap] = BStack[T, Cap, ccMulti, ccMulti]
```

### `SpscBStack`

```nim
SpscBStack[T; Cap] = BStack[T, Cap, ccSingle, ccSingle]
```

### `MpscBStack`

```nim
MpscBStack[T; Cap] = BStack[T, Cap, ccMulti, ccSingle]
```

### `SpmcBStack`

```nim
SpmcBStack[T; Cap] = BStack[T, Cap, ccSingle, ccMulti]
```

### `MpmcBStack`

```nim
MpmcBStack[T; Cap] = BStack[T, Cap, ccMulti, ccMulti]
```


## Constants

### `BStackEliminationCapacity`

```nim
BStackEliminationCapacity = 8
```

Number of collision slots in the Elimination-Backoff Array (power of 2).

### `BStackEliminationSpins`

```nim
BStackEliminationSpins = 32
```

Spin count for a pusher waiting in an elimination slot for a popper.


## Procedures & Functions

### `state`

```nim
proc state[T; Cap: static int; ccProd: static PinScopeCardinality;
           ccCons: static PinScopeCardinality](
    f: BStackDestroyed[T, Cap, ccProd, ccCons]): BStackLifecycleState
```

Runtime state inspection for BStackDestroyed. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state[T; Cap: static int; ccProd: static PinScopeCardinality;
           ccCons: static PinScopeCardinality](
    f: BStackInit[T, Cap, ccProd, ccCons]): BStackLifecycleState
```

Runtime state inspection for BStackInit. Returns the enum value for pattern matching in case expressions.

### ``$``

```nim
proc `$`[T; Cap: static int; ccProd: static PinScopeCardinality;
         ccCons: static PinScopeCardinality](
    s: BStackDestroyed[T, Cap, ccProd, ccCons]): string
```

String representation for state 'BStackDestroyed'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`[T; Cap: static int; ccProd: static PinScopeCardinality;
         ccCons: static PinScopeCardinality](
    s: BStackInit[T, Cap, ccProd, ccCons]): string
```

String representation for state 'BStackInit'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`(s: BStackLifecycleState): string {.raises: [], tags: [], forbids: [].}
```

String representation of BStackLifecycleState enum. Strips the fs prefix for human-friendly output.

### ``=destroy``

```nim
proc `=destroy`[T; Cap: static int; ccProd: static PinScopeCardinality;
                ccCons: static PinScopeCardinality](
    self: var BStack[T, Cap, ccProd, ccCons]) {.transitionError: "BStack used after =destroy (lifecycle: BStackInit -> BStackDestroyed).",
    raises: [], raises: [].}
```

### ``=copy``

```nim
proc `=copy`[T; Cap: static int; ccProd: static PinScopeCardinality;
             ccCons: static PinScopeCardinality](
    dest: var BStack[T, Cap, ccProd, ccCons];
    src: BStack[T, Cap, ccProd, ccCons])
```

### ``=sink``

```nim
proc `=sink`[T; Cap: static int; ccProd: static PinScopeCardinality;
             ccCons: static PinScopeCardinality](
    dest: var BStack[T, Cap, ccProd, ccCons];
    src: BStack[T, Cap, ccProd, ccCons])
```

### `initBStack`

```nim
proc initBStack[T; Cap: static int;
                ccProd: static PinScopeCardinality = ccMulti;
                ccCons: static PinScopeCardinality = ccMulti](): BStack[T, Cap,
    ccProd, ccCons]
```

Initializes a preallocated bounded lock-free stack with capacity <tt class="docutils literal"><span class="pre"><span class="Identifier">Cap</span></span></tt>.

### `newBStack`

```nim
proc newBStack[T; Cap: static int; ccProd: static PinScopeCardinality = ccMulti;
               ccCons: static PinScopeCardinality = ccMulti](): BStack[T, Cap,
    ccProd, ccCons] {.inline.}
```

### `initBoundedStack`

```nim
proc initBoundedStack[T; Cap: static int;
                      ccProd: static PinScopeCardinality = ccMulti;
                      ccCons: static PinScopeCardinality = ccMulti](): BoundedStack[
    T, Cap, ccProd, ccCons] {.inline.}
```

### `newBoundedStack`

```nim
proc newBoundedStack[T; Cap: static int;
                     ccProd: static PinScopeCardinality = ccMulti;
                     ccCons: static PinScopeCardinality = ccMulti](): BoundedStack[
    T, Cap, ccProd, ccCons] {.inline.}
```

### `initSpscBStack`

```nim
proc initSpscBStack[T; Cap: static int](): SpscBStack[T, Cap] {.inline.}
```

### `initMpscBStack`

```nim
proc initMpscBStack[T; Cap: static int](): MpscBStack[T, Cap] {.inline.}
```

### `initSpmcBStack`

```nim
proc initSpmcBStack[T; Cap: static int](): SpmcBStack[T, Cap] {.inline.}
```

### `initMpmcBStack`

```nim
proc initMpmcBStack[T; Cap: static int](): MpmcBStack[T, Cap] {.inline.}
```

### `newSpscBStack`

```nim
proc newSpscBStack[T; Cap: static int](): SpscBStack[T, Cap] {.inline.}
```

### `newMpscBStack`

```nim
proc newMpscBStack[T; Cap: static int](): MpscBStack[T, Cap] {.inline.}
```

### `newSpmcBStack`

```nim
proc newSpmcBStack[T; Cap: static int](): SpmcBStack[T, Cap] {.inline.}
```

### `newMpmcBStack`

```nim
proc newMpmcBStack[T; Cap: static int](): MpmcBStack[T, Cap] {.inline.}
```

### `tryPush`

```nim
proc tryPush[T; Cap: static int; ccProd: static PinScopeCardinality;
             ccCons: static PinScopeCardinality](
    self: BStack[T, Cap, ccProd, ccCons]; item: sink T): bool {.gcsafe.}
```

Attempts to push <tt class="docutils literal"><span class="pre"><span class="Identifier">item</span></span></tt> onto the bounded stack without allocating heap memory. Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt> on success, or <tt class="docutils literal"><span class="pre"><span class="Identifier">false</span></span></tt> if the stack has reached capacity <tt class="docutils literal"><span class="pre"><span class="Identifier">Cap</span></span></tt>.

### `push`

```nim
proc push[T; Cap: static int; ccProd: static PinScopeCardinality;
          ccCons: static PinScopeCardinality](
    self: BStack[T, Cap, ccProd, ccCons]; item: sink T): bool {.discardable,
    inline, gcsafe.}
```

Pushes <tt class="docutils literal"><span class="pre"><span class="Identifier">item</span></span></tt> onto the bounded stack. Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt> if pushed, or <tt class="docutils literal"><span class="pre"><span class="Identifier">false</span></span></tt> if the stack is full (<tt class="docutils literal"><span class="pre"><span class="Identifier">len</span> <span class="Operator">==</span> <span class="Identifier">Cap</span></span></tt>).

### `tryPop`

```nim
proc tryPop[T; Cap: static int; ccProd: static PinScopeCardinality;
            ccCons: static PinScopeCardinality](
    self: BStack[T, Cap, ccProd, ccCons]; outItem: var T): bool {.gcsafe.}
```

Attempts to pop the top item in LIFO order into <tt class="docutils literal"><span class="pre"><span class="Identifier">outItem</span></span></tt>. Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt> if an item was popped, or <tt class="docutils literal"><span class="pre"><span class="Identifier">false</span></span></tt> if the stack is empty.

### `pop`

```nim
proc pop[T; Cap: static int; ccProd: static PinScopeCardinality;
         ccCons: static PinScopeCardinality](
    self: BStack[T, Cap, ccProd, ccCons]): Option[T] {.inline, gcsafe.}
```

Pops and returns <tt class="docutils literal"><span class="pre"><span class="Identifier">some</span><span class="Punctuation">(</span><span class="Identifier">item</span><span class="Punctuation">)</span></span></tt> in LIFO order, or <tt class="docutils literal"><span class="pre"><span class="Identifier">none</span><span class="Punctuation">(</span><span class="Identifier">T</span><span class="Punctuation">)</span></span></tt> if empty.

### `tryPeek`

```nim
proc tryPeek[T; Cap: static int; ccProd: static PinScopeCardinality;
             ccCons: static PinScopeCardinality](
    self: BStack[T, Cap, ccProd, ccCons]; outItem: var T): bool {.gcsafe.}
```

Non-destructively copies the top item into <tt class="docutils literal"><span class="pre"><span class="Identifier">outItem</span></span></tt> and returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt>, or returns <tt class="docutils literal"><span class="pre"><span class="Identifier">false</span></span></tt> if the stack is empty. Safe for <tt class="docutils literal"><span class="pre"><span class="Identifier">pointer</span></span></tt>/<tt class="docutils literal"><span class="pre"><span class="Keyword">nil</span></span></tt> payloads.

### `peek`

```nim
proc peek[T; Cap: static int; ccProd: static PinScopeCardinality;
          ccCons: static PinScopeCardinality](
    self: BStack[T, Cap, ccProd, ccCons]): Option[T] {.inline, gcsafe.}
```

Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">some</span><span class="Punctuation">(</span><span class="Identifier">topItem</span><span class="Punctuation">)</span></span></tt> without removing it, or <tt class="docutils literal"><span class="pre"><span class="Identifier">none</span><span class="Punctuation">(</span><span class="Identifier">T</span><span class="Punctuation">)</span></span></tt> if empty.

### `drainInto`

```nim
proc drainInto[T; Cap: static int; ccProd: static PinScopeCardinality;
               ccCons: static PinScopeCardinality](
    self: BStack[T, Cap, ccProd, ccCons]; dest: var seq[T]) {.gcsafe.}
```

Atomically detaches all items currently in the stack and appends them to <tt class="docutils literal"><span class="pre"><span class="Identifier">dest</span></span></tt> in LIFO order.

### `drain`

```nim
proc drain[T; Cap: static int; ccProd: static PinScopeCardinality;
           ccCons: static PinScopeCardinality](
    self: BStack[T, Cap, ccProd, ccCons]): seq[T] {.gcsafe.}
```

Atomically detaches all items currently in the stack and returns them in LIFO order.

### `clear`

```nim
proc clear[T; Cap: static int; ccProd: static PinScopeCardinality;
           ccCons: static PinScopeCardinality](
    self: BStack[T, Cap, ccProd, ccCons]) {.gcsafe.}
```

Removes and destroys all items currently in the stack, returning all slots to the preallocated free pool.

### `len`

```nim
proc len[T; Cap: static int; ccProd: static PinScopeCardinality;
         ccCons: static PinScopeCardinality](
    self: BStack[T, Cap, ccProd, ccCons]): int {.inline.}
```

Returns the current number of elements in the bounded stack (<tt class="docutils literal"><span class="pre"><span class="DecNumber">0</span> <span class="Operator">..</span> <span class="Identifier">capacity</span></span></tt>).

### `capacity`

```nim
proc capacity[T; Cap: static int; ccProd: static PinScopeCardinality;
              ccCons: static PinScopeCardinality](
    self: BStack[T, Cap, ccProd, ccCons]): int {.inline.}
```

Returns the effective capacity of the bounded stack (defaults to <tt class="docutils literal"><span class="pre"><span class="Identifier">Cap</span></span></tt>).

### `setEffectiveCapacity`

```nim
proc setEffectiveCapacity[T; Cap: static int;
                          ccProd: static PinScopeCardinality;
                          ccCons: static PinScopeCardinality](
    self: BStack[T, Cap, ccProd, ccCons]; effCap: int)
```

Restricts the free-slot pool of an empty <tt class="docutils literal"><span class="pre"><span class="Identifier">BStack</span></span></tt> to <tt class="docutils literal"><span class="pre"><span class="Identifier">effCap</span></span></tt> slots (<tt class="docutils literal"><span class="pre"><span class="DecNumber">1</span> <span class="Operator">..</span> <span class="Identifier">Cap</span></span></tt>).

### `isEmpty`

```nim
proc isEmpty[T; Cap: static int; ccProd: static PinScopeCardinality;
             ccCons: static PinScopeCardinality](
    self: BStack[T, Cap, ccProd, ccCons]): bool {.inline.}
```

Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt> if the stack currently contains no items.

### `isFull`

```nim
proc isFull[T; Cap: static int; ccProd: static PinScopeCardinality;
            ccCons: static PinScopeCardinality](
    self: BStack[T, Cap, ccProd, ccCons]): bool {.inline.}
```

Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt> if all <tt class="docutils literal"><span class="pre"><span class="Identifier">Cap</span></span></tt> preallocated slots are currently in use.

### `tryPush`

```nim
proc tryPush[T; Tag: SpscProducerTag | MpmcProducerTag | AnyThreadTag;
             Cap: static int; ccProd: static PinScopeCardinality;
             ccCons: static PinScopeCardinality](
    self: Bound[T, Tag, BStack[T, Cap, ccProd, ccCons]]; item: sink T): bool {.
    tags: [Tag, TypestateOp, RootEffect], raises: [], notATransition.}
```

### `push`

```nim
proc push[T; Tag: SpscProducerTag | MpmcProducerTag | AnyThreadTag;
          Cap: static int; ccProd: static PinScopeCardinality;
          ccCons: static PinScopeCardinality](
    self: Bound[T, Tag, BStack[T, Cap, ccProd, ccCons]]; item: sink T): bool {.
    discardable, tags: [Tag, TypestateOp, RootEffect], raises: [],
    notATransition.}
```

### `tryPush`

```nim
proc tryPush[T; Tag: SpscConsumerTag | MpmcConsumerTag; Cap: static int;
             ccProd: static PinScopeCardinality;
             ccCons: static PinScopeCardinality](
    self: Bound[T, Tag, BStack[T, Cap, ccProd, ccCons]]; item: sink T): bool {.error: "tryPush on a consumer-tagged BStack endpoint (SpscConsumerTag / MpmcConsumerTag) is forbidden; bind a producer endpoint via getProducer().",
    notATransition.}
```

### `push`

```nim
proc push[T; Tag: SpscConsumerTag | MpmcConsumerTag; Cap: static int;
          ccProd: static PinScopeCardinality; ccCons: static PinScopeCardinality](
    self: Bound[T, Tag, BStack[T, Cap, ccProd, ccCons]]; item: sink T): bool {.error: "push on a consumer-tagged BStack endpoint (SpscConsumerTag / MpmcConsumerTag) is forbidden; bind a producer endpoint via getProducer().",
    notATransition.}
```

### `tryPop`

```nim
proc tryPop[T; Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag;
            Cap: static int; ccProd: static PinScopeCardinality;
            ccCons: static PinScopeCardinality](
    self: Bound[T, Tag, BStack[T, Cap, ccProd, ccCons]]; outItem: var T): bool {.
    tags: [Tag, TypestateOp, RootEffect], raises: [], notATransition.}
```

### `pop`

```nim
proc pop[T; Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag;
         Cap: static int; ccProd: static PinScopeCardinality;
         ccCons: static PinScopeCardinality](
    self: Bound[T, Tag, BStack[T, Cap, ccProd, ccCons]]): Option[T] {.
    tags: [Tag, TypestateOp, RootEffect], raises: [], notATransition.}
```

### `peek`

```nim
proc peek[T; Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag;
          Cap: static int; ccProd: static PinScopeCardinality;
          ccCons: static PinScopeCardinality](
    self: Bound[T, Tag, BStack[T, Cap, ccProd, ccCons]]): Option[T] {.
    tags: [Tag, TypestateOp, RootEffect], raises: [], notATransition.}
```

### `tryPop`

```nim
proc tryPop[T; Tag: SpscProducerTag | MpmcProducerTag; Cap: static int;
            ccProd: static PinScopeCardinality;
            ccCons: static PinScopeCardinality](
    self: Bound[T, Tag, BStack[T, Cap, ccProd, ccCons]]; outItem: var T): bool {.error: "tryPop on a producer-tagged BStack endpoint (SpscProducerTag / MpmcProducerTag) is forbidden; bind a consumer endpoint via getConsumer().",
    notATransition.}
```

### `pop`

```nim
proc pop[T; Tag: SpscProducerTag | MpmcProducerTag; Cap: static int;
         ccProd: static PinScopeCardinality; ccCons: static PinScopeCardinality](
    self: Bound[T, Tag, BStack[T, Cap, ccProd, ccCons]]): Option[T] {.error: "pop on a producer-tagged BStack endpoint (SpscProducerTag / MpmcProducerTag) is forbidden; bind a consumer endpoint via getConsumer().",
    notATransition.}
```

### `len`

```nim
proc len[T; Tag; Cap: static int; ccProd: static PinScopeCardinality;
         ccCons: static PinScopeCardinality](
    self: Bound[T, Tag, BStack[T, Cap, ccProd, ccCons]]): int {.inline,
    notATransition.}
```

### `capacity`

```nim
proc capacity[T; Tag; Cap: static int; ccProd: static PinScopeCardinality;
              ccCons: static PinScopeCardinality](
    self: Bound[T, Tag, BStack[T, Cap, ccProd, ccCons]]): int {.inline,
    notATransition.}
```

### `isEmpty`

```nim
proc isEmpty[T; Tag; Cap: static int; ccProd: static PinScopeCardinality;
             ccCons: static PinScopeCardinality](
    self: Bound[T, Tag, BStack[T, Cap, ccProd, ccCons]]): bool {.inline,
    notATransition.}
```

### `isFull`

```nim
proc isFull[T; Tag; Cap: static int; ccProd: static PinScopeCardinality;
            ccCons: static PinScopeCardinality](
    self: Bound[T, Tag, BStack[T, Cap, ccProd, ccCons]]): bool {.inline,
    notATransition.}
```


## Macros

### `match`

```nim
macro match[T; Cap: static int; ccProd: static PinScopeCardinality;
            ccCons: static PinScopeCardinality](
    value: BStackLifecycleStates[T, Cap, ccProd, ccCons]; arms: untyped): untyped
```

Single-target pattern match on states of typestate 'BStackLifecycle'; rewrites to <tt class="docutils literal"><span class="pre"><span class="Keyword">block</span><span class="Punctuation">:</span> <span class="Keyword">let</span> <span class="Keyword">bind</span> <span class="Operator">=</span> <span class="Identifier">move</span><span class="Punctuation">(</span><span class="Identifier">value</span><span class="Punctuation">)</span><span class="Punctuation">;</span> <span class="Identifier">body</span></span></tt>. Syntax is <tt class="docutils literal"><span class="pre"><span class="Operator">&lt;</span><span class="Identifier">StateName</span><span class="Operator">&gt;</span><span class="Punctuation">(</span><span class="Keyword">bind</span><span class="Punctuation">)</span><span class="Punctuation">:</span></span></tt>, with exactly one arm.

### `BStackLifecycle`

```nim
macro BStackLifecycle(initial`gensym0: untyped; typeDef`gensym0: untyped): untyped
```

Typestate-attachment pragma (auto-generated; see §3.7 of the v0.9.0 design doc). Apply to a type declaration to bind the type to this typestate with <tt class="docutils literal"><span class="pre"><span class="Identifier">initial</span></span></tt> as the starting state. Validates TA-002..TA-004 at compile time and populates <tt class="docutils literal"><span class="pre"><span class="Identifier">typestateAttachments</span></span></tt>.

