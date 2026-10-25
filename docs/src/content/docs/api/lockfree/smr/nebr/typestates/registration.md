---
title: "lockfree/smr/nebr/typestates/registration"
description: "API reference for lockfree/smr/nebr/typestates/registration"
---

<p>Registration typestate for thread registration.</p>
<p>Handles thread registration with the DEBRA manager, ensuring threads properly claim slots in the thread array using lock-free CAS operations.</p>
<p>The typestate carries two static generic-param axes:</p>
<ul class="simple"><li><tt class="docutils literal"><span class="pre"><span class="Identifier">MaxThreads</span><span class="Punctuation">:</span> <span class="Keyword">static</span> <span class="Identifier">int</span></span></tt> — capacity of the manager's thread array.</li>
<li><tt class="docutils literal"><span class="pre"><span class="Identifier">CC</span><span class="Punctuation">:</span> <span class="Keyword">static</span> <span class="Identifier">PinScopeCardinality</span> <span class="Operator">=</span> <span class="Identifier">ccSingle</span></span></tt> — consumer-cardinality phantom mirroring <tt class="docutils literal"><span class="pre"><span class="Identifier">DebraManager</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">ThreadHandle</span></span></tt>. Default <tt class="docutils literal"><span class="pre"><span class="Identifier">ccSingle</span></span></tt> matches the 0.7.x call shape, so existing call sites that spell only <tt class="docutils literal"><span class="pre"><span class="Identifier">MaxThreads</span></span></tt> continue to bind cleanly.</li>
</ul>
<p>Codegen-emitted helpers (variant type <tt class="docutils literal"><span class="pre"><span class="Identifier">RegisterResult</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Operator">=</span><span class="Identifier">copy</span></span></tt> hooks, <tt class="docutils literal"><span class="pre"><span class="Identifier">state</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt> procs, <tt class="docutils literal"><span class="pre"><span class="Operator">$</span></span></tt> overloads, <tt class="docutils literal"><span class="pre"><span class="Identifier">match</span></span></tt> macros) inherit <tt class="docutils literal"><span class="pre"><span class="Identifier">CC</span> <span class="Operator">=</span> <span class="Identifier">ccSingle</span></span></tt> via the typestate macro's <tt class="docutils literal"><span class="pre"><span class="Identifier">defaults</span><span class="Punctuation">:</span></span></tt> body section (typestates 0.9.2+).</p>


## Types

### `RegistrationContext`

```nim
RegistrationContext[MaxThreads; CC] = object of RootObj
  manager*: ptr DebraManager[MaxThreads, CC]
  idx*: int
```

### `Unregistered`

```nim
Unregistered[MaxThreads; CC] = distinct RegistrationContext[MaxThreads, CC]
```

### `Registered`

```nim
Registered[MaxThreads; CC] = distinct RegistrationContext[MaxThreads, CC]
```

### `RegistrationFull`

```nim
RegistrationFull[MaxThreads; CC] = distinct RegistrationContext[MaxThreads, CC]
```

### `RegistrationContextState`

```nim
RegistrationContextState = enum
  fsUnregistered, fsRegistered, fsRegistrationFull
```

### `RegistrationContextStates`

```nim
RegistrationContextStates[MaxThreads; CC] = Unregistered[MaxThreads, CC] |
    Registered[MaxThreads, CC] |
    RegistrationFull[MaxThreads, CC]
```

### `RegisterResultKind`

```nim
RegisterResultKind = enum
  rRegistered, rRegistrationFull
```

### `RegisterResult`

```nim
RegisterResult[MaxThreads; CC] = object
  case kind*: RegisterResultKind
  of rRegistered:
    registered*: Registered[MaxThreads, CC]
  of rRegistrationFull:
    registrationfull*: RegistrationFull[MaxThreads, CC]
```


## Procedures & Functions

### `state`

```nim
proc state[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    f: Unregistered[MaxThreads, CC]): RegistrationContextState
```

Runtime state inspection for Unregistered. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    f: Registered[MaxThreads, CC]): RegistrationContextState
```

Runtime state inspection for Registered. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    f: RegistrationFull[MaxThreads, CC]): RegistrationContextState
```

Runtime state inspection for RegistrationFull. Returns the enum value for pattern matching in case expressions.

### ``$``

```nim
proc `$`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    s: Unregistered[MaxThreads, CC]): string
```

String representation for state 'Unregistered'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    s: Registered[MaxThreads, CC]): string
```

String representation for state 'Registered'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    s: RegistrationFull[MaxThreads, CC]): string
```

String representation for state 'RegistrationFull'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`(s: RegistrationContextState): string {.raises: [], tags: [],
    forbids: [].}
```

String representation of RegistrationContextState enum. Strips the fs prefix for human-friendly output.

### ``=copy``

```nim
proc `=copy`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    dest: var Unregistered[MaxThreads, CC]; src: Unregistered[MaxThreads, CC]) {.error: "State \'Unregistered\' cannot be copied. Transitions consume the input state.".}
```

### ``=copy``

```nim
proc `=copy`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    dest: var Registered[MaxThreads, CC]; src: Registered[MaxThreads, CC]) {.error: "State \'Registered\' cannot be copied. Transitions consume the input state.".}
```

### ``=copy``

```nim
proc `=copy`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    dest: var RegistrationFull[MaxThreads, CC];
    src: RegistrationFull[MaxThreads, CC]) {.error: "State \'RegistrationFull\' cannot be copied. Transitions consume the input state.".}
```

### `toRegisterResult`

```nim
proc toRegisterResult[MaxThreads: static int;
                      CC: static PinScopeCardinality = ccSingle](
    s: sink Registered[MaxThreads, CC]): RegisterResult[MaxThreads, CC]
```

### `toRegisterResult`

```nim
proc toRegisterResult[MaxThreads: static int;
                      CC: static PinScopeCardinality = ccSingle](
    s: sink RegistrationFull[MaxThreads, CC]): RegisterResult[MaxThreads, CC]
```

### ``$``

```nim
proc `$`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    r: RegisterResult[MaxThreads, CC]): string
```

String representation of branching union 'RegisterResult<a class="reference internal" href="#MaxThreads, CC">MaxThreads, CC</a>'. Returns the active branch's bare state name.

### `unregistered`

```nim
proc unregistered[MaxThreads: static int; CC: static PinScopeCardinality](
    mgr: ptr DebraManager[MaxThreads, CC]): Unregistered[MaxThreads, CC]
```

Create unregistered context for a thread.

### `register`

```nim
proc register[MaxThreads: static int; CC: static PinScopeCardinality](
    u: sink Unregistered[MaxThreads, CC]): RegisterResult[MaxThreads, CC] {.
    raises: [], tags: [TypestateOp, RootEffect].}
```

Try to register thread by claiming a slot. Returns Registered if successful, RegistrationFull if all slots are taken.

### `idx`

```nim
func idx[MaxThreads: static int; CC: static PinScopeCardinality](
    r: Registered[MaxThreads, CC]): int {.notATransition.}
```

Get the thread slot index.

### `getHandle`

```nim
func getHandle[MaxThreads: static int; CC: static PinScopeCardinality](
    r: Registered[MaxThreads, CC]): ThreadHandle[MaxThreads, CC]
```

Extract ThreadHandle for use in pin/unpin operations.


## Templates

### ``-&gt;``

```nim
template `->`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    _: typedesc[RegisterResult[MaxThreads, CC]];
    s: sink Registered[MaxThreads, CC]): RegisterResult[MaxThreads, CC]
```

### ``-&gt;``

```nim
template `->`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    _: typedesc[RegisterResult[MaxThreads, CC]];
    s: sink RegistrationFull[MaxThreads, CC]): RegisterResult[MaxThreads, CC]
```


## Macros

### `match`

```nim
macro match[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    value: RegisterResult[MaxThreads, CC]; arms: untyped): untyped
```

Pattern-match on a branching union; rewrites into a <tt class="docutils literal"><span class="pre"><span class="Keyword">case</span></span></tt> over the kind discriminator. The value being matched must be a <tt class="docutils literal"><span class="pre"><span class="Keyword">var</span></span></tt> binding. Branch fields are extracted with <tt class="docutils literal"><span class="pre"><span class="Identifier">move</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt>, which requires a mutable binding. Syntax is <tt class="docutils literal"><span class="pre"><span class="Identifier">StateName</span><span class="Punctuation">(</span><span class="Keyword">bind</span><span class="Punctuation">)</span><span class="Punctuation">:</span></span></tt>, not <tt class="docutils literal"><span class="pre"><span class="Keyword">of</span> <span class="Identifier">StateName</span> <span class="Keyword">as</span> <span class="Keyword">bind</span><span class="Punctuation">:</span></span></tt>.

### `match`

```nim
macro match[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    value: RegistrationContextStates[MaxThreads, CC]; arms: untyped): untyped
```

Single-target pattern match on states of typestate 'RegistrationContext'; rewrites to <tt class="docutils literal"><span class="pre"><span class="Keyword">block</span><span class="Punctuation">:</span> <span class="Keyword">let</span> <span class="Keyword">bind</span> <span class="Operator">=</span> <span class="Identifier">move</span><span class="Punctuation">(</span><span class="Identifier">value</span><span class="Punctuation">)</span><span class="Punctuation">;</span> <span class="Identifier">body</span></span></tt>. Syntax is <tt class="docutils literal"><span class="pre"><span class="Operator">&lt;</span><span class="Identifier">StateName</span><span class="Operator">&gt;</span><span class="Punctuation">(</span><span class="Keyword">bind</span><span class="Punctuation">)</span><span class="Punctuation">:</span></span></tt>, with exactly one arm.

