---
title: "lockfree/typestates/virtual_values_n"
description: "API reference for lockfree/typestates/virtual_values_n"
---

<pre>N-slot virtual values for SPSC and unbounded queue slot-index arithmetic.

Used by spsc (SPSC) and the unbounded queue variants for `mod N` physical
slot calculation over a virtual space of 0..&lt;2*N. Bounded MPMC/MPSC/SPMC
queues use Vyukov-style sequence-numbered cells (mpmc_cell) instead.

NOTE (v0.1.0): PhysicalSlotN is production-live (type-safe slot indexing
across the bounded N-cardinality push/pop modules and mpmc_cell). The
index-arithmetic transition surface
(validate/add/wrapIfNeeded/index/incOrResetN) and the N-variant
fullness/atomic-loader helpers are currently exercised only by unit tests —
bounded MPMC/MPSC/SPMC use the Vyukov cell seq protocol (mpmc_cell) and SPSC
uses the N+1 variant (virtual_values_n1). They are retained as tested
building blocks for a possible future unbounded-arithmetic migration.</pre>


## Types

### `VirtualValueN`

```nim
VirtualValueN[N] = object
```

Base type for N-slot virtual values. Value field is PRIVATE - only extractable via state-specific accessors.

### `RawLoadedN`

```nim
RawLoadedN[N] = distinct VirtualValueN[N]
```

Just loaded from atomic - not yet validated.

### `WrappedValueN`

```nim
WrappedValueN[N] = distinct VirtualValueN[N]
```

<pre>Validated to be in range 0..&lt;2*N.</pre>

### `UnwrappedSumN`

```nim
UnwrappedSumN[N] = distinct VirtualValueN[N]
```

<pre>Result of addition - may be &gt;= 2*N, must wrap before use.</pre>

### `PhysicalSlotN`

```nim
PhysicalSlotN[N] = distinct VirtualValueN[N]
```

Storage index in range 0..&lt;N. Only obtainable via index().

### `VirtualValueNState`

```nim
VirtualValueNState = enum
  fsRawLoadedN, fsWrappedValueN, fsUnwrappedSumN, fsPhysicalSlotN
```

### `VirtualValueNStates`

```nim
VirtualValueNStates[N] = RawLoadedN[N] | WrappedValueN[N] | UnwrappedSumN[N] |
    PhysicalSlotN[N]
```


## Procedures & Functions

### `state`

```nim
proc state[N: static int](f: RawLoadedN[N]): VirtualValueNState
```

Runtime state inspection for RawLoadedN. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state[N: static int](f: WrappedValueN[N]): VirtualValueNState
```

Runtime state inspection for WrappedValueN. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state[N: static int](f: UnwrappedSumN[N]): VirtualValueNState
```

Runtime state inspection for UnwrappedSumN. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state[N: static int](f: PhysicalSlotN[N]): VirtualValueNState
```

Runtime state inspection for PhysicalSlotN. Returns the enum value for pattern matching in case expressions.

### ``$``

```nim
proc `$`[N: static int](s: RawLoadedN[N]): string
```

String representation for state 'RawLoadedN'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`[N: static int](s: WrappedValueN[N]): string
```

String representation for state 'WrappedValueN'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`[N: static int](s: UnwrappedSumN[N]): string
```

String representation for state 'UnwrappedSumN'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`[N: static int](s: PhysicalSlotN[N]): string
```

String representation for state 'PhysicalSlotN'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`(s: VirtualValueNState): string {.raises: [], tags: [], forbids: [].}
```

String representation of VirtualValueNState enum. Strips the fs prefix for human-friendly output.

### `rawValue`

```nim
proc rawValue[N: static int](r: RawLoadedN[N]): int {.notATransition.}
```

### `value`

```nim
proc value[N: static int](w: WrappedValueN[N]): int {.notATransition.}
```

### `unwrappedValue`

```nim
proc unwrappedValue[N: static int](u: UnwrappedSumN[N]): int {.notATransition.}
```

### `slotValue`

```nim
proc slotValue[N: static int](p: PhysicalSlotN[N]): int {.notATransition.}
```

### `initRawN`

```nim
proc initRawN[N: static int](val: int): RawLoadedN[N] {.inline.}
```

Create a raw loaded value (from atomic load).

### `validate`

```nim
proc validate[N: static int](r: RawLoadedN[N]): WrappedValueN[N] {.inline,
    raises: [], tags: [TypestateOp, RootEffect].}
```

<pre>Validate that raw value is in range 0..&lt;2*N.</pre>

### `add`

```nim
proc add[N: static int](w: WrappedValueN[N]; amount: int): UnwrappedSumN[N] {.
    inline, raises: [], tags: [TypestateOp, RootEffect].}
```

Add to wrapped value. Result may need wrapping.

### `wrapIfNeeded`

```nim
proc wrapIfNeeded[N: static int](u: UnwrappedSumN[N]): WrappedValueN[N] {.
    inline, raises: [], tags: [TypestateOp, RootEffect].}
```

<pre>Wrap value back into range 0..&lt;2*N if needed.</pre>

### `index`

```nim
proc index[N: static int](w: WrappedValueN[N]): PhysicalSlotN[N] {.inline,
    raises: [], tags: [TypestateOp, RootEffect].}
```

Convert to physical slot using mod N.

### `incOrResetN`

```nim
proc incOrResetN[N: static int](w: WrappedValueN[N]; amount: int): WrappedValueN[
    N] {.inline, raises: [], tags: [TypestateOp, RootEffect].}
```

Increment and wrap in one step.


## Macros

### `match`

```nim
macro match[N: static int](value: VirtualValueNStates[N]; arms: untyped): untyped
```

Single-target pattern match on states of typestate 'VirtualValueN'; rewrites to <tt class="docutils literal"><span class="pre"><span class="Keyword">block</span><span class="Punctuation">:</span> <span class="Keyword">let</span> <span class="Keyword">bind</span> <span class="Operator">=</span> <span class="Identifier">move</span><span class="Punctuation">(</span><span class="Identifier">value</span><span class="Punctuation">)</span><span class="Punctuation">;</span> <span class="Identifier">body</span></span></tt>. Syntax is <tt class="docutils literal"><span class="pre"><span class="Operator">&lt;</span><span class="Identifier">StateName</span><span class="Operator">&gt;</span><span class="Punctuation">(</span><span class="Keyword">bind</span><span class="Punctuation">)</span><span class="Punctuation">:</span></span></tt>, with exactly one arm.

