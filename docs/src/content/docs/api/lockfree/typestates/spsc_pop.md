---
title: "lockfree/typestates/spsc_pop"
description: "API reference for lockfree/typestates/spsc_pop"
---

<p>SPSC Pop operation lifecycle typestate.</p>
<p>Enforces correct sequencing for single-consumer pop: Start -&gt; LoadPointers -&gt; CheckEmpty -&gt; Complete</p>
<p>Key invariant: Once NotEmpty is reached, we MUST read and advance head.</p>
<p>Uses N+1 slot arithmetic (no committed flags needed for SPSC).</p>


## Types

### `SPSCPopStart`

```nim
SPSCPopStart[N] = object
```

Entry point. No data yet.

### `SPSCPopPointersLoaded`

```nim
SPSCPopPointersLoaded[N] = object
  head*: WrappedValueN1[N]
  tail*: WrappedValueN1[N]
```

Loaded head and tail.

### `SPSCPopNotEmpty`

```nim
SPSCPopNotEmpty[N] = object
  head*: WrappedValueN1[N]
  slot*: PhysicalSlotN1[N]
```

Confirmed queue has items. MUST complete.

### `SPSCPopEmpty`

```nim
SPSCPopEmpty[N] = object
```

Terminal: queue was empty.

### `SPSCPopOpState`

```nim
SPSCPopOpState = enum
  fsSPSCPopEmpty, fsSPSCPopNotEmpty, fsSPSCPopStart, fsSPSCPopPointersLoaded
```

### `SPSCPopOpStates`

```nim
SPSCPopOpStates[N] = SPSCPopEmpty[N] | SPSCPopNotEmpty[N] | SPSCPopStart[N] |
    SPSCPopPointersLoaded[N]
```

### `SPSCEmptyCheckKind`

```nim
SPSCEmptyCheckKind = enum
  sSPSCPopNotEmpty, sSPSCPopEmpty
```

### `SPSCEmptyCheck`

```nim
SPSCEmptyCheck[N] = object
  case kind*: SPSCEmptyCheckKind
  of sSPSCPopNotEmpty:
    spscpopnotempty*: SPSCPopNotEmpty[N]
  of sSPSCPopEmpty:
    spscpopempty*: SPSCPopEmpty[N]
```


## Procedures & Functions

### `state`

```nim
proc state[N: static int](f: SPSCPopEmpty[N]): SPSCPopOpState
```

Runtime state inspection for SPSCPopEmpty. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state[N: static int](f: SPSCPopNotEmpty[N]): SPSCPopOpState
```

Runtime state inspection for SPSCPopNotEmpty. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state[N: static int](f: SPSCPopStart[N]): SPSCPopOpState
```

Runtime state inspection for SPSCPopStart. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state[N: static int](f: SPSCPopPointersLoaded[N]): SPSCPopOpState
```

Runtime state inspection for SPSCPopPointersLoaded. Returns the enum value for pattern matching in case expressions.

### ``$``

```nim
proc `$`[N: static int](s: SPSCPopEmpty[N]): string
```

String representation for state 'SPSCPopEmpty'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`[N: static int](s: SPSCPopNotEmpty[N]): string
```

String representation for state 'SPSCPopNotEmpty'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`[N: static int](s: SPSCPopStart[N]): string
```

String representation for state 'SPSCPopStart'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`[N: static int](s: SPSCPopPointersLoaded[N]): string
```

String representation for state 'SPSCPopPointersLoaded'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`(s: SPSCPopOpState): string {.raises: [], tags: [], forbids: [].}
```

String representation of SPSCPopOpState enum. Strips the fs prefix for human-friendly output.

### `toSPSCEmptyCheck`

```nim
proc toSPSCEmptyCheck[N: static int](s: sink SPSCPopNotEmpty[N]): SPSCEmptyCheck[
    N]
```

### `toSPSCEmptyCheck`

```nim
proc toSPSCEmptyCheck[N: static int](s: sink SPSCPopEmpty[N]): SPSCEmptyCheck[N]
```

### ``$``

```nim
proc `$`[N: static int](r: SPSCEmptyCheck[N]): string
```

String representation of branching union 'SPSCEmptyCheck<a class="reference internal" href="#N">N</a>'. Returns the active branch's bare state name.

### `start`

```nim
proc start[N: static int](): SPSCPopStart[N] {.inline.}
```

Begin a pop operation.

### `loadPointers`

```nim
proc loadPointers[N: static int; T](op: sink SPSCPopStart[N];
                                    queue: var SpscBase[N, T]): SPSCPopPointersLoaded[
    N] {.inline, raises: [], tags: [TypestateOp, RootEffect].}
```

Load head and tail atomically.

### `checkEmpty`

```nim
proc checkEmpty[N: static int](op: sink SPSCPopPointersLoaded[N]): SPSCEmptyCheck[
    N] {.inline, raises: [], tags: [TypestateOp, RootEffect].}
```

Check if queue is empty. Returns branch type.

### `complete`

```nim
proc complete[N: static int; T](op: SPSCPopNotEmpty[N];
                                queue: var SpscBase[N, T]): T {.inline,
    notATransition.}
```

Read value, advance head. Returns the value.


## Templates

### ``-&gt;``

```nim
template `->`[N: static int](_: typedesc[SPSCEmptyCheck[N]];
                             s: sink SPSCPopNotEmpty[N]): SPSCEmptyCheck[N]
```

### ``-&gt;``

```nim
template `->`[N: static int](_: typedesc[SPSCEmptyCheck[N]];
                             s: sink SPSCPopEmpty[N]): SPSCEmptyCheck[N]
```


## Macros

### `match`

```nim
macro match[N: static int](value: SPSCEmptyCheck[N]; arms: untyped): untyped
```

Pattern-match on a branching union; rewrites into a <tt class="docutils literal"><span class="pre"><span class="Keyword">case</span></span></tt> over the kind discriminator. The value being matched must be a <tt class="docutils literal"><span class="pre"><span class="Keyword">var</span></span></tt> binding. Branch fields are extracted with <tt class="docutils literal"><span class="pre"><span class="Identifier">move</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt>, which requires a mutable binding. Syntax is <tt class="docutils literal"><span class="pre"><span class="Identifier">StateName</span><span class="Punctuation">(</span><span class="Keyword">bind</span><span class="Punctuation">)</span><span class="Punctuation">:</span></span></tt>, not <tt class="docutils literal"><span class="pre"><span class="Keyword">of</span> <span class="Identifier">StateName</span> <span class="Keyword">as</span> <span class="Keyword">bind</span><span class="Punctuation">:</span></span></tt>.

### `match`

```nim
macro match[N: static int](value: SPSCPopOpStates[N]; arms: untyped): untyped
```

Single-target pattern match on states of typestate 'SPSCPopOp'; rewrites to <tt class="docutils literal"><span class="pre"><span class="Keyword">block</span><span class="Punctuation">:</span> <span class="Keyword">let</span> <span class="Keyword">bind</span> <span class="Operator">=</span> <span class="Identifier">move</span><span class="Punctuation">(</span><span class="Identifier">value</span><span class="Punctuation">)</span><span class="Punctuation">;</span> <span class="Identifier">body</span></span></tt>. Syntax is <tt class="docutils literal"><span class="pre"><span class="Operator">&lt;</span><span class="Identifier">StateName</span><span class="Operator">&gt;</span><span class="Punctuation">(</span><span class="Keyword">bind</span><span class="Punctuation">)</span><span class="Punctuation">:</span></span></tt>, with exactly one arm.

### `SPSCPopOp`

```nim
macro SPSCPopOp(initial`gensym0: untyped; typeDef`gensym0: untyped): untyped
```

Typestate-attachment pragma (auto-generated; see §3.7 of the v0.9.0 design doc). Apply to a type declaration to bind the type to this typestate with <tt class="docutils literal"><span class="pre"><span class="Identifier">initial</span></span></tt> as the starting state. Validates TA-002..TA-004 at compile time and populates <tt class="docutils literal"><span class="pre"><span class="Identifier">typestateAttachments</span></span></tt>.

