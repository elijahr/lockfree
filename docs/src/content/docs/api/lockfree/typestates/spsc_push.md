---
title: "lockfree/typestates/spsc_push"
description: "API reference for lockfree/typestates/spsc_push"
---

<p>SPSC Push operation lifecycle typestate.</p>
<p>Enforces correct sequencing for single-producer push: Start -&gt; LoadPointers -&gt; CheckFull -&gt; WriteData -&gt; Complete</p>
<p>Key invariant: Once data is written, tail MUST be advanced.</p>
<p>Uses N+1 slot arithmetic (no committed flags needed for SPSC).</p>


## Types

### `SPSCPushStart`

```nim
SPSCPushStart[N] = object
```

Entry point. No data yet.

### `SPSCPushPointersLoaded`

```nim
SPSCPushPointersLoaded[N] = object
  head*: WrappedValueN1[N]
  tail*: WrappedValueN1[N]
```

Loaded head and tail.

### `SPSCPushNotFull`

```nim
SPSCPushNotFull[N] = object
  tail*: WrappedValueN1[N]
  slot*: PhysicalSlotN1[N]
```

Confirmed queue has space.

### `SPSCPushDataWritten`

```nim
SPSCPushDataWritten[N] = object
  newTail*: WrappedValueN1[N]
```

Data written to slot. MUST advance tail.

### `SPSCPushFull`

```nim
SPSCPushFull[N] = object
```

Terminal: queue was full.

### `SPSCPushOpState`

```nim
SPSCPushOpState = enum
  fsSPSCPushNotFull, fsSPSCPushFull, fsSPSCPushStart, fsSPSCPushDataWritten,
  fsSPSCPushPointersLoaded
```

### `SPSCPushOpStates`

```nim
SPSCPushOpStates[N] = SPSCPushNotFull[N] | SPSCPushFull[N] | SPSCPushStart[N] |
    SPSCPushDataWritten[N] |
    SPSCPushPointersLoaded[N]
```

### `SPSCFullCheckKind`

```nim
SPSCFullCheckKind = enum
  sSPSCPushNotFull, sSPSCPushFull
```

### `SPSCFullCheck`

```nim
SPSCFullCheck[N] = object
  case kind*: SPSCFullCheckKind
  of sSPSCPushNotFull:
    spscpushnotfull*: SPSCPushNotFull[N]
  of sSPSCPushFull:
    spscpushfull*: SPSCPushFull[N]
```

### `SpscBase`

```nim
SpscBase[N; T] = object
  head* {.align: 128.}: Atomic[int]
  tail* {.align: 128.}: Atomic[int]
  storage*: StorageN1[N, T]
```


## Procedures & Functions

### `state`

```nim
proc state[N: static int](f: SPSCPushNotFull[N]): SPSCPushOpState
```

Runtime state inspection for SPSCPushNotFull. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state[N: static int](f: SPSCPushFull[N]): SPSCPushOpState
```

Runtime state inspection for SPSCPushFull. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state[N: static int](f: SPSCPushStart[N]): SPSCPushOpState
```

Runtime state inspection for SPSCPushStart. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state[N: static int](f: SPSCPushDataWritten[N]): SPSCPushOpState
```

Runtime state inspection for SPSCPushDataWritten. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state[N: static int](f: SPSCPushPointersLoaded[N]): SPSCPushOpState
```

Runtime state inspection for SPSCPushPointersLoaded. Returns the enum value for pattern matching in case expressions.

### ``$``

```nim
proc `$`[N: static int](s: SPSCPushNotFull[N]): string
```

String representation for state 'SPSCPushNotFull'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`[N: static int](s: SPSCPushFull[N]): string
```

String representation for state 'SPSCPushFull'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`[N: static int](s: SPSCPushStart[N]): string
```

String representation for state 'SPSCPushStart'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`[N: static int](s: SPSCPushDataWritten[N]): string
```

String representation for state 'SPSCPushDataWritten'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`[N: static int](s: SPSCPushPointersLoaded[N]): string
```

String representation for state 'SPSCPushPointersLoaded'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`(s: SPSCPushOpState): string {.raises: [], tags: [], forbids: [].}
```

String representation of SPSCPushOpState enum. Strips the fs prefix for human-friendly output.

### `toSPSCFullCheck`

```nim
proc toSPSCFullCheck[N: static int](s: sink SPSCPushNotFull[N]): SPSCFullCheck[N]
```

### `toSPSCFullCheck`

```nim
proc toSPSCFullCheck[N: static int](s: sink SPSCPushFull[N]): SPSCFullCheck[N]
```

### ``$``

```nim
proc `$`[N: static int](r: SPSCFullCheck[N]): string
```

String representation of branching union 'SPSCFullCheck<a class="reference internal" href="#N">N</a>'. Returns the active branch's bare state name.

### `start`

```nim
proc start[N: static int](): SPSCPushStart[N] {.inline.}
```

Begin a push operation.

### `loadPointers`

```nim
proc loadPointers[N: static int; T](op: sink SPSCPushStart[N];
                                    queue: var SpscBase[N, T]): SPSCPushPointersLoaded[
    N] {.inline, raises: [], tags: [TypestateOp, RootEffect].}
```

Load head and tail atomically.

### `checkFull`

```nim
proc checkFull[N: static int](op: sink SPSCPushPointersLoaded[N]): SPSCFullCheck[
    N] {.inline, raises: [], tags: [TypestateOp, RootEffect].}
```

Check if queue is full. Returns branch type.

### `writeData`

```nim
proc writeData[N: static int; T](op: sink SPSCPushNotFull[N];
                                 queue: var SpscBase[N, T]; item: sink T): SPSCPushDataWritten[
    N] {.inline, raises: [], tags: [TypestateOp, RootEffect].}
```

Write item to the slot.

### `complete`

```nim
proc complete[N: static int; T](op: SPSCPushDataWritten[N];
                                queue: var SpscBase[N, T]): bool {.inline,
    notATransition.}
```

Advance tail and return success.

### `extractFalse`

```nim
proc extractFalse[N: static int](op: SPSCPushFull[N]): bool {.notATransition.}
```

Terminal: extract false result (queue was full).


## Templates

### ``-&gt;``

```nim
template `->`[N: static int](_: typedesc[SPSCFullCheck[N]];
                             s: sink SPSCPushNotFull[N]): SPSCFullCheck[N]
```

### ``-&gt;``

```nim
template `->`[N: static int](_: typedesc[SPSCFullCheck[N]];
                             s: sink SPSCPushFull[N]): SPSCFullCheck[N]
```


## Macros

### `match`

```nim
macro match[N: static int](value: SPSCFullCheck[N]; arms: untyped): untyped
```

Pattern-match on a branching union; rewrites into a <tt class="docutils literal"><span class="pre"><span class="Keyword">case</span></span></tt> over the kind discriminator. The value being matched must be a <tt class="docutils literal"><span class="pre"><span class="Keyword">var</span></span></tt> binding. Branch fields are extracted with <tt class="docutils literal"><span class="pre"><span class="Identifier">move</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt>, which requires a mutable binding. Syntax is <tt class="docutils literal"><span class="pre"><span class="Identifier">StateName</span><span class="Punctuation">(</span><span class="Keyword">bind</span><span class="Punctuation">)</span><span class="Punctuation">:</span></span></tt>, not <tt class="docutils literal"><span class="pre"><span class="Keyword">of</span> <span class="Identifier">StateName</span> <span class="Keyword">as</span> <span class="Keyword">bind</span><span class="Punctuation">:</span></span></tt>.

### `match`

```nim
macro match[N: static int](value: SPSCPushOpStates[N]; arms: untyped): untyped
```

Single-target pattern match on states of typestate 'SPSCPushOp'; rewrites to <tt class="docutils literal"><span class="pre"><span class="Keyword">block</span><span class="Punctuation">:</span> <span class="Keyword">let</span> <span class="Keyword">bind</span> <span class="Operator">=</span> <span class="Identifier">move</span><span class="Punctuation">(</span><span class="Identifier">value</span><span class="Punctuation">)</span><span class="Punctuation">;</span> <span class="Identifier">body</span></span></tt>. Syntax is <tt class="docutils literal"><span class="pre"><span class="Operator">&lt;</span><span class="Identifier">StateName</span><span class="Operator">&gt;</span><span class="Punctuation">(</span><span class="Keyword">bind</span><span class="Punctuation">)</span><span class="Punctuation">:</span></span></tt>, with exactly one arm.

### `SPSCPushOp`

```nim
macro SPSCPushOp(initial`gensym0: untyped; typeDef`gensym0: untyped): untyped
```

Typestate-attachment pragma (auto-generated; see §3.7 of the v0.9.0 design doc). Apply to a type declaration to bind the type to this typestate with <tt class="docutils literal"><span class="pre"><span class="Identifier">initial</span></span></tt> as the starting state. Validates TA-002..TA-004 at compile time and populates <tt class="docutils literal"><span class="pre"><span class="Identifier">typestateAttachments</span></span></tt>.

