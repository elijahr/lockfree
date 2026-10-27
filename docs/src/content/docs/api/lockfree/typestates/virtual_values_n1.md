---
title: "lockfree/typestates/virtual_values_n1"
description: "API reference for lockfree/typestates/virtual_values_n1"
---

<pre>N+1-slot virtual values for SPSC queue.

SPSC uses N+1 slots to distinguish full from empty without flags. Virtual
space is 0..&lt;2*(N+1). Uses `mod (N+1)` for slot calculation.</pre>


## Types

### `VirtualValueN1`

```nim
VirtualValueN1[N] = object
```

### `RawLoadedN1`

```nim
RawLoadedN1[N] = distinct VirtualValueN1[N]
```

### `WrappedValueN1`

```nim
WrappedValueN1[N] = distinct VirtualValueN1[N]
```

### `UnwrappedSumN1`

```nim
UnwrappedSumN1[N] = distinct VirtualValueN1[N]
```

### `PhysicalSlotN1`

```nim
PhysicalSlotN1[N] = distinct VirtualValueN1[N]
```

### `VirtualValueN1State`

```nim
VirtualValueN1State = enum
  fsWrappedValueN1, fsPhysicalSlotN1, fsRawLoadedN1, fsUnwrappedSumN1
```

### `VirtualValueN1States`

```nim
VirtualValueN1States[N] = WrappedValueN1[N] | PhysicalSlotN1[N] | RawLoadedN1[N] |
    UnwrappedSumN1[N]
```


## Procedures & Functions

### `state`

```nim
proc state[N: static int](f: WrappedValueN1[N]): VirtualValueN1State
```

Runtime state inspection for WrappedValueN1. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state[N: static int](f: PhysicalSlotN1[N]): VirtualValueN1State
```

Runtime state inspection for PhysicalSlotN1. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state[N: static int](f: RawLoadedN1[N]): VirtualValueN1State
```

Runtime state inspection for RawLoadedN1. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state[N: static int](f: UnwrappedSumN1[N]): VirtualValueN1State
```

Runtime state inspection for UnwrappedSumN1. Returns the enum value for pattern matching in case expressions.

### ``$``

```nim
proc `$`[N: static int](s: WrappedValueN1[N]): string
```

String representation for state 'WrappedValueN1'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`[N: static int](s: PhysicalSlotN1[N]): string
```

String representation for state 'PhysicalSlotN1'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`[N: static int](s: RawLoadedN1[N]): string
```

String representation for state 'RawLoadedN1'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`[N: static int](s: UnwrappedSumN1[N]): string
```

String representation for state 'UnwrappedSumN1'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`(s: VirtualValueN1State): string {.raises: [], tags: [], forbids: [].}
```

String representation of VirtualValueN1State enum. Strips the fs prefix for human-friendly output.

### `rawValue`

```nim
proc rawValue[N: static int](r: RawLoadedN1[N]): int {.notATransition.}
```

### `value`

```nim
proc value[N: static int](w: WrappedValueN1[N]): int {.notATransition.}
```

### `unwrappedValue`

```nim
proc unwrappedValue[N: static int](u: UnwrappedSumN1[N]): int {.notATransition.}
```

### `slotValue`

```nim
proc slotValue[N: static int](p: PhysicalSlotN1[N]): int {.notATransition.}
```

### `initRawN1`

```nim
proc initRawN1[N: static int](val: int): RawLoadedN1[N] {.inline.}
```

### `validate`

```nim
proc validate[N: static int](r: RawLoadedN1[N]): WrappedValueN1[N] {.inline,
    raises: [], tags: [TypestateOp, RootEffect].}
```

### `add`

```nim
proc add[N: static int](w: WrappedValueN1[N]; amount: int): UnwrappedSumN1[N] {.
    inline, raises: [], tags: [TypestateOp, RootEffect].}
```

### `wrapIfNeeded`

```nim
proc wrapIfNeeded[N: static int](u: UnwrappedSumN1[N]): WrappedValueN1[N] {.
    inline, raises: [], tags: [TypestateOp, RootEffect].}
```

### `index`

```nim
proc index[N: static int](w: WrappedValueN1[N]): PhysicalSlotN1[N] {.inline,
    raises: [], tags: [TypestateOp, RootEffect].}
```

KEY: mod (N+1), not mod N!

### `incOrResetN1`

```nim
proc incOrResetN1[N: static int](w: WrappedValueN1[N]; amount: int): WrappedValueN1[
    N] {.inline, raises: [], tags: [TypestateOp, RootEffect].}
```


## Macros

### `match`

```nim
macro match[N: static int](value: VirtualValueN1States[N]; arms: untyped): untyped
```

Single-target pattern match on states of typestate 'VirtualValueN1'; rewrites to <tt class="docutils literal"><span class="pre"><span class="Keyword">block</span><span class="Punctuation">:</span> <span class="Keyword">let</span> <span class="Keyword">bind</span> <span class="Operator">=</span> <span class="Identifier">move</span><span class="Punctuation">(</span><span class="Identifier">value</span><span class="Punctuation">)</span><span class="Punctuation">;</span> <span class="Identifier">body</span></span></tt>. Syntax is <tt class="docutils literal"><span class="pre"><span class="Operator">&lt;</span><span class="Identifier">StateName</span><span class="Operator">&gt;</span><span class="Punctuation">(</span><span class="Keyword">bind</span><span class="Punctuation">)</span><span class="Punctuation">:</span></span></tt>, with exactly one arm.

