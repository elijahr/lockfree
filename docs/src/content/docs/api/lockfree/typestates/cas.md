---
title: "lockfree/typestates/cas"
description: "API reference for lockfree/typestates/cas"
---

<p>Type-safe CAS operations.</p>
<p>Forces explicit handling of success and failure paths via a typestate union: a <tt class="docutils literal"><span class="pre"><span class="Identifier">CASPending</span></span></tt> is consumed by <tt class="docutils literal"><span class="pre"><span class="Identifier">executeCAS</span></span></tt> and produces either a <tt class="docutils literal"><span class="pre"><span class="Identifier">CASSucceeded</span></span></tt> (carrying the written value) or a <tt class="docutils literal"><span class="pre"><span class="Identifier">CASFailed</span></span></tt> (carrying the value actually observed at the address). Callers <tt class="docutils literal"><span class="pre"><span class="Identifier">match</span></span></tt> on the resulting <tt class="docutils literal"><span class="pre"><span class="Identifier">CASResult</span></span></tt> union and cannot reach the payload without selecting a branch.</p>


## Types

### `CASAttempt`

```nim
CASAttempt = object
```

### `CASPending`

```nim
CASPending = distinct CASAttempt
```

CAS prepared but not executed.

### `CASSucceeded`

```nim
CASSucceeded = object
  newVal*: int
```

Terminal: CAS succeeded; carries the written value.

### `CASFailed`

```nim
CASFailed = object
  actualVal*: int
```

Terminal: CAS failed; carries the value actually observed at the address.

### `CASAttemptState`

```nim
CASAttemptState = enum
  fsCASSucceeded, fsCASFailed, fsCASPending
```

### `CASAttemptStates`

```nim
CASAttemptStates = CASSucceeded | CASFailed | CASPending
```

### `CASResultKind`

```nim
CASResultKind = enum
  cCASSucceeded, cCASFailed
```

### `CASResult`

```nim
CASResult = object
  case kind*: CASResultKind
  of cCASSucceeded:
    cassucceeded*: CASSucceeded
  of cCASFailed:
    casfailed*: CASFailed
```


## Procedures & Functions

### `state`

```nim
proc state(f: CASSucceeded): CASAttemptState {.raises: [], tags: [], forbids: [].}
```

Runtime state inspection for CASSucceeded. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state(f: CASFailed): CASAttemptState {.raises: [], tags: [], forbids: [].}
```

Runtime state inspection for CASFailed. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state(f: CASPending): CASAttemptState {.raises: [], tags: [], forbids: [].}
```

Runtime state inspection for CASPending. Returns the enum value for pattern matching in case expressions.

### ``$``

```nim
proc `$`(s: CASSucceeded): string {.raises: [], tags: [], forbids: [].}
```

String representation for state 'CASSucceeded'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`(s: CASFailed): string {.raises: [], tags: [], forbids: [].}
```

String representation for state 'CASFailed'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`(s: CASPending): string {.raises: [], tags: [], forbids: [].}
```

String representation for state 'CASPending'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`(s: CASAttemptState): string {.raises: [], tags: [], forbids: [].}
```

String representation of CASAttemptState enum. Strips the fs prefix for human-friendly output.

### ``=copy``

```nim
proc `=copy`(dest: var CASSucceeded; src: CASSucceeded) {.error: "State \'CASSucceeded\' cannot be copied. Transitions consume the input state.".}
```

### ``=copy``

```nim
proc `=copy`(dest: var CASFailed; src: CASFailed) {.error: "State \'CASFailed\' cannot be copied. Transitions consume the input state.".}
```

### ``=copy``

```nim
proc `=copy`(dest: var CASPending; src: CASPending) {.error: "State \'CASPending\' cannot be copied. Transitions consume the input state.".}
```

### `toCASResult`

```nim
proc toCASResult(s: sink CASSucceeded): CASResult {.raises: [], tags: [],
    forbids: [].}
```

### `toCASResult`

```nim
proc toCASResult(s: sink CASFailed): CASResult {.raises: [], tags: [],
    forbids: [].}
```

### ``$``

```nim
proc `$`(r: CASResult): string {.raises: [], tags: [], forbids: [].}
```

String representation of branching union 'CASResult'. Returns the active branch's bare state name.

### `expectedVal`

```nim
proc expectedVal(p: CASPending): int {.notATransition, raises: [], tags: [],
                                       forbids: [].}
```

### `desiredVal`

```nim
proc desiredVal(p: CASPending): int {.notATransition, raises: [], tags: [],
                                      forbids: [].}
```

### `prepareCAS`

```nim
proc prepareCAS(atom: ptr Atomic[int]; expected, desired: int): CASPending {.
    inline, raises: [], tags: [], forbids: [].}
```

### `executeCAS`

```nim
proc executeCAS(p: sink CASPending): CASResult {.raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```


## Templates

### ``-&gt;``

```nim
template `->`(_: typedesc[CASResult]; s: sink CASSucceeded): CASResult
```

### ``-&gt;``

```nim
template `->`(_: typedesc[CASResult]; s: sink CASFailed): CASResult
```


## Macros

### `match`

```nim
macro match(value: CASResult; arms: untyped): untyped
```

Pattern-match on a branching union; rewrites into a <tt class="docutils literal"><span class="pre"><span class="Keyword">case</span></span></tt> over the kind discriminator. The value being matched must be a <tt class="docutils literal"><span class="pre"><span class="Keyword">var</span></span></tt> binding. Branch fields are extracted with <tt class="docutils literal"><span class="pre"><span class="Identifier">move</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt>, which requires a mutable binding. Syntax is <tt class="docutils literal"><span class="pre"><span class="Identifier">StateName</span><span class="Punctuation">(</span><span class="Keyword">bind</span><span class="Punctuation">)</span><span class="Punctuation">:</span></span></tt>, not <tt class="docutils literal"><span class="pre"><span class="Keyword">of</span> <span class="Identifier">StateName</span> <span class="Keyword">as</span> <span class="Keyword">bind</span><span class="Punctuation">:</span></span></tt>.

### `match`

```nim
macro match(value: CASAttemptStates; arms: untyped): untyped
```

Single-target pattern match on states of typestate 'CASAttempt'; rewrites to <tt class="docutils literal"><span class="pre"><span class="Keyword">block</span><span class="Punctuation">:</span> <span class="Keyword">let</span> <span class="Keyword">bind</span> <span class="Operator">=</span> <span class="Identifier">move</span><span class="Punctuation">(</span><span class="Identifier">value</span><span class="Punctuation">)</span><span class="Punctuation">;</span> <span class="Identifier">body</span></span></tt>. Syntax is <tt class="docutils literal"><span class="pre"><span class="Operator">&lt;</span><span class="Identifier">StateName</span><span class="Operator">&gt;</span><span class="Punctuation">(</span><span class="Keyword">bind</span><span class="Punctuation">)</span><span class="Punctuation">:</span></span></tt>, with exactly one arm.

