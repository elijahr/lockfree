---
title: "lockfree/smr/nebr/typestates/advance"
description: "API reference for lockfree/smr/nebr/typestates/advance"
---

<p>EpochAdvance typestate for advancing the global epoch.</p>
<p>Ensures atomic increment of the global epoch counter.</p>
<p>The typestate carries a <tt class="docutils literal"><span class="pre"><span class="Identifier">CC</span><span class="Punctuation">:</span> <span class="Keyword">static</span> <span class="Identifier">PinScopeCardinality</span> <span class="Operator">=</span> <span class="Identifier">ccSingle</span></span></tt> param so that ccMulti managers built by <tt class="docutils literal"><span class="pre"><span class="Identifier">initDebraManager</span><span class="Punctuation">[</span><span class="Identifier">N</span><span class="Punctuation">,</span> <span class="Identifier">ccMulti</span><span class="Punctuation">]</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt> can flow through this surface. The advance ALGORITHM is intentionally CC-agnostic (pure atomic epoch arithmetic, no cardinality-dependent branching), but the type system has to thread <tt class="docutils literal"><span class="pre"><span class="Identifier">CC</span></span></tt> to accept a <tt class="docutils literal"><span class="pre"><span class="Keyword">ptr</span> <span class="Identifier">DebraManager</span><span class="Punctuation">[</span><span class="Identifier">MT</span><span class="Punctuation">,</span> <span class="Identifier">CC</span><span class="Punctuation">]</span></span></tt> field for both cardinalities. The default <tt class="docutils literal"><span class="pre"><span class="Identifier">ccSingle</span></span></tt> preserves the 0.7.x-style call shape unchanged.</p>


## Types

### `AdvanceContext`

```nim
AdvanceContext[MaxThreads; CC] = object of RootObj
  manager*: ptr DebraManager[MaxThreads, CC]
  oldEpoch*: uint64
  newEpoch*: uint64
```

### `Current`

```nim
Current[MaxThreads; CC] = distinct AdvanceContext[MaxThreads, CC]
```

### `Advancing`

```nim
Advancing[MaxThreads; CC] = distinct AdvanceContext[MaxThreads, CC]
```

### `Advanced`

```nim
Advanced[MaxThreads; CC] = distinct AdvanceContext[MaxThreads, CC]
```

### `AdvanceContextState`

```nim
AdvanceContextState = enum
  fsAdvanced, fsAdvancing, fsCurrent
```

### `AdvanceContextStates`

```nim
AdvanceContextStates[MaxThreads; CC] = Advanced[MaxThreads, CC] |
    Advancing[MaxThreads, CC] |
    Current[MaxThreads, CC]
```


## Procedures & Functions

### `state`

```nim
proc state[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    f: Advanced[MaxThreads, CC]): AdvanceContextState
```

Runtime state inspection for Advanced. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    f: Advancing[MaxThreads, CC]): AdvanceContextState
```

Runtime state inspection for Advancing. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    f: Current[MaxThreads, CC]): AdvanceContextState
```

Runtime state inspection for Current. Returns the enum value for pattern matching in case expressions.

### ``$``

```nim
proc `$`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    s: Advanced[MaxThreads, CC]): string
```

String representation for state 'Advanced'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    s: Advancing[MaxThreads, CC]): string
```

String representation for state 'Advancing'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    s: Current[MaxThreads, CC]): string
```

String representation for state 'Current'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`(s: AdvanceContextState): string {.raises: [], tags: [], forbids: [].}
```

String representation of AdvanceContextState enum. Strips the fs prefix for human-friendly output.

### ``=copy``

```nim
proc `=copy`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    dest: var Advanced[MaxThreads, CC]; src: Advanced[MaxThreads, CC]) {.error: "State \'Advanced\' cannot be copied. Transitions consume the input state.".}
```

### ``=copy``

```nim
proc `=copy`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    dest: var Advancing[MaxThreads, CC]; src: Advancing[MaxThreads, CC]) {.error: "State \'Advancing\' cannot be copied. Transitions consume the input state.".}
```

### ``=copy``

```nim
proc `=copy`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    dest: var Current[MaxThreads, CC]; src: Current[MaxThreads, CC]) {.error: "State \'Current\' cannot be copied. Transitions consume the input state.".}
```

### `advanceCurrent`

```nim
proc advanceCurrent[MaxThreads: static int;
                    CC: static PinScopeCardinality = ccSingle](
    mgr: ptr DebraManager[MaxThreads, CC]): Current[MaxThreads, CC]
```

Create epoch advance context.

### `advance`

```nim
proc advance[MaxThreads: static int; CC: static PinScopeCardinality](
    c: sink Current[MaxThreads, CC]): Advancing[MaxThreads, CC] {.raises: [],
    tags: [TypestateOp, RootEffect].}
```

Begin advancing the global epoch.

### `complete`

```nim
proc complete[MaxThreads: static int; CC: static PinScopeCardinality](
    a: sink Advancing[MaxThreads, CC]): Advanced[MaxThreads, CC] {.raises: [],
    tags: [TypestateOp, RootEffect].}
```

Complete epoch advance by atomically incrementing globalEpoch.

### `newEpoch`

```nim
func newEpoch[MaxThreads: static int; CC: static PinScopeCardinality](
    a: Advanced[MaxThreads, CC]): uint64 {.notATransition.}
```

Get the new epoch value after advancement.

### `oldEpoch`

```nim
func oldEpoch[MaxThreads: static int; CC: static PinScopeCardinality](
    a: Advanced[MaxThreads, CC]): uint64 {.notATransition.}
```

Get the old epoch value before advancement.


## Macros

### `match`

```nim
macro match[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    value: AdvanceContextStates[MaxThreads, CC]; arms: untyped): untyped
```

Single-target pattern match on states of typestate 'AdvanceContext'; rewrites to <tt class="docutils literal"><span class="pre"><span class="Keyword">block</span><span class="Punctuation">:</span> <span class="Keyword">let</span> <span class="Keyword">bind</span> <span class="Operator">=</span> <span class="Identifier">move</span><span class="Punctuation">(</span><span class="Identifier">value</span><span class="Punctuation">)</span><span class="Punctuation">;</span> <span class="Identifier">body</span></span></tt>. Syntax is <tt class="docutils literal"><span class="pre"><span class="Operator">&lt;</span><span class="Identifier">StateName</span><span class="Operator">&gt;</span><span class="Punctuation">(</span><span class="Keyword">bind</span><span class="Punctuation">)</span><span class="Punctuation">:</span></span></tt>, with exactly one arm.

