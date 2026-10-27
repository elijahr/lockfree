---
title: "lockfree/smr/nebr/typestates/manager"
description: "API reference for lockfree/smr/nebr/typestates/manager"
---

<p>DebraManager lifecycle typestate.</p>
<p>Ensures manager is initialized before use and properly shut down.</p>


## Types

### `ManagerContext`

```nim
ManagerContext[MaxThreads; CC] = object of RootObj
  manager*: ptr DebraManager[MaxThreads, CC]
```

### `ManagerUninitialized`

```nim
ManagerUninitialized[MaxThreads; CC] = distinct ManagerContext[MaxThreads, CC]
```

### `ManagerReady`

```nim
ManagerReady[MaxThreads; CC] = distinct ManagerContext[MaxThreads, CC]
```

### `ManagerShutdown`

```nim
ManagerShutdown[MaxThreads; CC] = distinct ManagerContext[MaxThreads, CC]
```

### `ManagerContextState`

```nim
ManagerContextState = enum
  fsManagerUninitialized, fsManagerReady, fsManagerShutdown
```

### `ManagerContextStates`

```nim
ManagerContextStates[MaxThreads; CC] = ManagerUninitialized[MaxThreads, CC] |
    ManagerReady[MaxThreads, CC] |
    ManagerShutdown[MaxThreads, CC]
```


## Procedures & Functions

### `state`

```nim
proc state[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    f: ManagerUninitialized[MaxThreads, CC]): ManagerContextState
```

Runtime state inspection for ManagerUninitialized. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    f: ManagerReady[MaxThreads, CC]): ManagerContextState
```

Runtime state inspection for ManagerReady. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    f: ManagerShutdown[MaxThreads, CC]): ManagerContextState
```

Runtime state inspection for ManagerShutdown. Returns the enum value for pattern matching in case expressions.

### ``$``

```nim
proc `$`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    s: ManagerUninitialized[MaxThreads, CC]): string
```

String representation for state 'ManagerUninitialized'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    s: ManagerReady[MaxThreads, CC]): string
```

String representation for state 'ManagerReady'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    s: ManagerShutdown[MaxThreads, CC]): string
```

String representation for state 'ManagerShutdown'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`(s: ManagerContextState): string {.raises: [], tags: [], forbids: [].}
```

String representation of ManagerContextState enum. Strips the fs prefix for human-friendly output.

### ``=copy``

```nim
proc `=copy`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    dest: var ManagerUninitialized[MaxThreads, CC];
    src: ManagerUninitialized[MaxThreads, CC]) {.error: "State \'ManagerUninitialized\' cannot be copied. Transitions consume the input state.".}
```

### ``=copy``

```nim
proc `=copy`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    dest: var ManagerReady[MaxThreads, CC]; src: ManagerReady[MaxThreads, CC]) {.error: "State \'ManagerReady\' cannot be copied. Transitions consume the input state.".}
```

### ``=copy``

```nim
proc `=copy`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    dest: var ManagerShutdown[MaxThreads, CC];
    src: ManagerShutdown[MaxThreads, CC]) {.error: "State \'ManagerShutdown\' cannot be copied. Transitions consume the input state.".}
```

### `uninitializedManager`

```nim
proc uninitializedManager[MaxThreads: static int;
                          CC: static PinScopeCardinality = ccSingle](
    mgr: ptr DebraManager[MaxThreads, CC]): ManagerUninitialized[MaxThreads, CC]
```

Wrap a manager pointer as uninitialized.

### `initialize`

```nim
proc initialize[MaxThreads: static int; CC: static PinScopeCardinality](
    m: sink ManagerUninitialized[MaxThreads, CC]): ManagerReady[MaxThreads, CC] {.
    raises: [], tags: [TypestateOp, RootEffect].}
```

Initialize the manager. Sets epoch to 1, clears all state.

### `shutdown`

```nim
proc shutdown[MaxThreads: static int; CC: static PinScopeCardinality](
    m: sink ManagerReady[MaxThreads, CC]): ManagerShutdown[MaxThreads, CC] {.
    skipCfgAnalysis, raises: [], tags: [TypestateOp, RootEffect].}
```

Shutdown manager. Reclaims all remaining limbo bags.

### `getManager`

```nim
func getManager[MaxThreads: static int; CC: static PinScopeCardinality](
    m: ManagerReady[MaxThreads, CC]): ptr DebraManager[MaxThreads, CC] {.
    notATransition.}
```

Get the underlying manager pointer.


## Macros

### `match`

```nim
macro match[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    value: ManagerContextStates[MaxThreads, CC]; arms: untyped): untyped
```

Single-target pattern match on states of typestate 'ManagerContext'; rewrites to <tt class="docutils literal"><span class="pre"><span class="Keyword">block</span><span class="Punctuation">:</span> <span class="Keyword">let</span> <span class="Keyword">bind</span> <span class="Operator">=</span> <span class="Identifier">move</span><span class="Punctuation">(</span><span class="Identifier">value</span><span class="Punctuation">)</span><span class="Punctuation">;</span> <span class="Identifier">body</span></span></tt>. Syntax is <tt class="docutils literal"><span class="pre"><span class="Operator">&lt;</span><span class="Identifier">StateName</span><span class="Operator">&gt;</span><span class="Punctuation">(</span><span class="Keyword">bind</span><span class="Punctuation">)</span><span class="Punctuation">:</span></span></tt>, with exactly one arm.

