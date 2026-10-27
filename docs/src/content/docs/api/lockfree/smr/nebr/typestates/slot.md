---
title: "lockfree/smr/nebr/typestates/slot"
description: "API reference for lockfree/smr/nebr/typestates/slot"
---

<p>ThreadSlot typestate: a compile-time-only ordering marker for the slot lifecycle.</p>
<p>IMPORTANT: this typestate is a <em>compile-time marker only</em>. The state transitions (<tt class="docutils literal"><span class="pre"><span class="Identifier">claim</span></span></tt>/<tt class="docutils literal"><span class="pre"><span class="Identifier">activate</span></span></tt>/<tt class="docutils literal"><span class="pre"><span class="Identifier">drain</span></span></tt>/<tt class="docutils literal"><span class="pre"><span class="Identifier">release</span></span></tt>) perform NO atomic operations and carry NO backing runtime state: each is a pure cast between distinct wrappers of the same <tt class="docutils literal"><span class="pre"><span class="Identifier">SlotContext</span></span></tt>. They do not touch <tt class="docutils literal"><span class="pre"><span class="Identifier">manager</span><span class="Operator">.</span><span class="Identifier">activeThreadMask</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">threadId</span></span></tt>, or any per-slot flag, so an <tt class="docutils literal"><span class="pre"><span class="Identifier">Active</span></span></tt> value here has no relationship to whether the slot's bit is actually set.</p>
<p>The authoritative slot state machine lives in <tt class="docutils literal"><span class="pre"><span class="Identifier">registration</span><span class="Operator">.</span><span class="Identifier">nim</span></span></tt>: a slot is genuinely claimed by the <tt class="docutils literal"><span class="pre"><span class="Identifier">activeThreadMask</span></span></tt> compare-exchange (registration.nim, <tt class="docutils literal"><span class="pre"><span class="Identifier">register</span></span></tt>) and released by the corresponding mask clear. This typestate only documents/enforces the <em>legal ordering</em> of those phases at compile time for callers that choose to model them; it does not gate the underlying bitmask.</p>
<p>The intended phase ordering it encodes:</p>
<ul class="simple"><li>Free: Slot is available for claiming</li>
<li>Claiming: Thread is attempting to claim the slot</li>
<li>Active: Slot is actively in use by a thread</li>
<li>Draining: Thread is unregistering, draining limbo bags</li>
<li>Free: Slot released back to pool</li>
</ul>


## Types

### `SlotContext`

```nim
SlotContext[MaxThreads; CC] = object of RootObj
  idx*: int
  manager*: ptr DebraManager[MaxThreads, CC]
```

### `Free`

```nim
Free[MaxThreads; CC] = distinct SlotContext[MaxThreads, CC]
```

### `Claiming`

```nim
Claiming[MaxThreads; CC] = distinct SlotContext[MaxThreads, CC]
```

### `Active`

```nim
Active[MaxThreads; CC] = distinct SlotContext[MaxThreads, CC]
```

### `Draining`

```nim
Draining[MaxThreads; CC] = distinct SlotContext[MaxThreads, CC]
```

### `SlotContextState`

```nim
SlotContextState = enum
  fsFree, fsClaiming, fsActive, fsDraining
```

### `SlotContextStates`

```nim
SlotContextStates[MaxThreads; CC] = Free[MaxThreads, CC] |
    Claiming[MaxThreads, CC] |
    Active[MaxThreads, CC] |
    Draining[MaxThreads, CC]
```


## Procedures & Functions

### `state`

```nim
proc state[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    f: Free[MaxThreads, CC]): SlotContextState
```

Runtime state inspection for Free. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    f: Claiming[MaxThreads, CC]): SlotContextState
```

Runtime state inspection for Claiming. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    f: Active[MaxThreads, CC]): SlotContextState
```

Runtime state inspection for Active. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    f: Draining[MaxThreads, CC]): SlotContextState
```

Runtime state inspection for Draining. Returns the enum value for pattern matching in case expressions.

### ``$``

```nim
proc `$`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    s: Free[MaxThreads, CC]): string
```

String representation for state 'Free'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    s: Claiming[MaxThreads, CC]): string
```

String representation for state 'Claiming'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    s: Active[MaxThreads, CC]): string
```

String representation for state 'Active'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    s: Draining[MaxThreads, CC]): string
```

String representation for state 'Draining'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`(s: SlotContextState): string {.raises: [], tags: [], forbids: [].}
```

String representation of SlotContextState enum. Strips the fs prefix for human-friendly output.

### ``=copy``

```nim
proc `=copy`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    dest: var Free[MaxThreads, CC]; src: Free[MaxThreads, CC]) {.error: "State \'Free\' cannot be copied. Transitions consume the input state.".}
```

### ``=copy``

```nim
proc `=copy`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    dest: var Claiming[MaxThreads, CC]; src: Claiming[MaxThreads, CC]) {.error: "State \'Claiming\' cannot be copied. Transitions consume the input state.".}
```

### ``=copy``

```nim
proc `=copy`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    dest: var Active[MaxThreads, CC]; src: Active[MaxThreads, CC]) {.error: "State \'Active\' cannot be copied. Transitions consume the input state.".}
```

### ``=copy``

```nim
proc `=copy`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    dest: var Draining[MaxThreads, CC]; src: Draining[MaxThreads, CC]) {.error: "State \'Draining\' cannot be copied. Transitions consume the input state.".}
```

### `freeSlot`

```nim
proc freeSlot[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    idx: int; mgr: ptr DebraManager[MaxThreads, CC]): Free[MaxThreads, CC]
```

Create a free slot context.

### `claim`

```nim
proc claim[MaxThreads: static int; CC: static PinScopeCardinality](
    f: sink Free[MaxThreads, CC]): Claiming[MaxThreads, CC] {.raises: [],
    tags: [TypestateOp, RootEffect].}
```

Begin claiming this slot. Transition to Claiming state.

### `activate`

```nim
proc activate[MaxThreads: static int; CC: static PinScopeCardinality](
    c: sink Claiming[MaxThreads, CC]): Active[MaxThreads, CC] {.raises: [],
    tags: [TypestateOp, RootEffect].}
```

Complete slot claim. Transition to Active state. This is where the slot becomes fully owned by a thread.

### `drain`

```nim
proc drain[MaxThreads: static int; CC: static PinScopeCardinality](
    a: sink Active[MaxThreads, CC]): Draining[MaxThreads, CC] {.raises: [],
    tags: [TypestateOp, RootEffect].}
```

Begin unregistration. Transition to Draining state. Thread will drain its limbo bags before releasing the slot.

### `release`

```nim
proc release[MaxThreads: static int; CC: static PinScopeCardinality](
    d: sink Draining[MaxThreads, CC]): Free[MaxThreads, CC] {.raises: [],
    tags: [TypestateOp, RootEffect].}
```

Release slot back to free pool. Transition back to Free state. This completes the lifecycle, making the slot available for reuse.

### `idx`

```nim
func idx[MaxThreads: static int; CC: static PinScopeCardinality](
    s: Active[MaxThreads, CC]): int {.notATransition.}
```

Get the slot index from Active state.

### `idx`

```nim
func idx[MaxThreads: static int; CC: static PinScopeCardinality](
    s: Draining[MaxThreads, CC]): int {.notATransition.}
```

Get the slot index from Draining state.

### `manager`

```nim
func manager[MaxThreads: static int; CC: static PinScopeCardinality](
    s: Active[MaxThreads, CC]): ptr DebraManager[MaxThreads, CC] {.
    notATransition.}
```

Get the manager pointer from Active state.

### `manager`

```nim
func manager[MaxThreads: static int; CC: static PinScopeCardinality](
    s: Draining[MaxThreads, CC]): ptr DebraManager[MaxThreads, CC] {.
    notATransition.}
```

Get the manager pointer from Draining state.


## Macros

### `match`

```nim
macro match[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    value: SlotContextStates[MaxThreads, CC]; arms: untyped): untyped
```

Single-target pattern match on states of typestate 'SlotContext'; rewrites to <tt class="docutils literal"><span class="pre"><span class="Keyword">block</span><span class="Punctuation">:</span> <span class="Keyword">let</span> <span class="Keyword">bind</span> <span class="Operator">=</span> <span class="Identifier">move</span><span class="Punctuation">(</span><span class="Identifier">value</span><span class="Punctuation">)</span><span class="Punctuation">;</span> <span class="Identifier">body</span></span></tt>. Syntax is <tt class="docutils literal"><span class="pre"><span class="Operator">&lt;</span><span class="Identifier">StateName</span><span class="Operator">&gt;</span><span class="Punctuation">(</span><span class="Keyword">bind</span><span class="Punctuation">)</span><span class="Punctuation">:</span></span></tt>, with exactly one arm.

