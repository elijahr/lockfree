---
title: "lockfree/smr/nebr/typestates/neutralize"
description: "API reference for lockfree/smr/nebr/typestates/neutralize"
---

<p>Neutralize typestate for DEBRA+ neutralization signaling.</p>
<p>Ensures proper sequence: ScanStart -&gt; Scanning -&gt; ScanComplete</p>
<p>When the epoch needs to advance, scan all threads and send SIGUSR1 to pinned threads that are stalled (behind globalEpoch by threshold).</p>


## Types

### `NeutralizeContext`

```nim
NeutralizeContext[MaxThreads; CC] = object of RootObj
  manager*: ptr DebraManager[MaxThreads, CC]
  globalEpoch*: uint64
  threshold*: uint64
  signalsSent*: int
```

### `ScanStart`

```nim
ScanStart[MaxThreads; CC] = distinct NeutralizeContext[MaxThreads, CC]
```

### `Scanning`

```nim
Scanning[MaxThreads; CC] = distinct NeutralizeContext[MaxThreads, CC]
```

### `ScanComplete`

```nim
ScanComplete[MaxThreads; CC] = distinct NeutralizeContext[MaxThreads, CC]
```

### `NeutralizeContextState`

```nim
NeutralizeContextState = enum
  fsScanComplete, fsScanning, fsScanStart
```

### `NeutralizeContextStates`

```nim
NeutralizeContextStates[MaxThreads; CC] = ScanComplete[MaxThreads, CC] |
    Scanning[MaxThreads, CC] |
    ScanStart[MaxThreads, CC]
```


## Procedures & Functions

### `state`

```nim
proc state[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    f: ScanComplete[MaxThreads, CC]): NeutralizeContextState
```

Runtime state inspection for ScanComplete. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    f: Scanning[MaxThreads, CC]): NeutralizeContextState
```

Runtime state inspection for Scanning. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    f: ScanStart[MaxThreads, CC]): NeutralizeContextState
```

Runtime state inspection for ScanStart. Returns the enum value for pattern matching in case expressions.

### ``$``

```nim
proc `$`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    s: ScanComplete[MaxThreads, CC]): string
```

String representation for state 'ScanComplete'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    s: Scanning[MaxThreads, CC]): string
```

String representation for state 'Scanning'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    s: ScanStart[MaxThreads, CC]): string
```

String representation for state 'ScanStart'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`(s: NeutralizeContextState): string {.raises: [], tags: [], forbids: [].}
```

String representation of NeutralizeContextState enum. Strips the fs prefix for human-friendly output.

### ``=copy``

```nim
proc `=copy`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    dest: var ScanComplete[MaxThreads, CC]; src: ScanComplete[MaxThreads, CC]) {.error: "State \'ScanComplete\' cannot be copied. Transitions consume the input state.".}
```

### ``=copy``

```nim
proc `=copy`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    dest: var Scanning[MaxThreads, CC]; src: Scanning[MaxThreads, CC]) {.error: "State \'Scanning\' cannot be copied. Transitions consume the input state.".}
```

### ``=copy``

```nim
proc `=copy`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    dest: var ScanStart[MaxThreads, CC]; src: ScanStart[MaxThreads, CC]) {.error: "State \'ScanStart\' cannot be copied. Transitions consume the input state.".}
```

### `scanStart`

```nim
proc scanStart[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    mgr: ptr DebraManager[MaxThreads, CC]): ScanStart[MaxThreads, CC]
```

Begin neutralization scan.

### `loadEpoch`

```nim
proc loadEpoch[MaxThreads: static int; CC: static PinScopeCardinality](
    s: sink ScanStart[MaxThreads, CC]; epochsBeforeNeutralize: uint64 = 2): Scanning[
    MaxThreads, CC] {.raises: [], tags: [TypestateOp, RootEffect].}
```

Load global epoch and compute threshold for stalled threads. Threads with epoch &lt; (globalEpoch - epochsBeforeNeutralize) get signaled.

### `globalEpoch`

```nim
func globalEpoch[MaxThreads: static int; CC: static PinScopeCardinality](
    s: Scanning[MaxThreads, CC]): uint64 {.notATransition.}
```

Get the global epoch loaded during scan start.

### `threshold`

```nim
func threshold[MaxThreads: static int; CC: static PinScopeCardinality](
    s: Scanning[MaxThreads, CC]): uint64 {.notATransition.}
```

Get the epoch threshold for neutralization.

### `scanAndSignal`

```nim
proc scanAndSignal[MaxThreads: static int; CC: static PinScopeCardinality](
    s: sink Scanning[MaxThreads, CC]): ScanComplete[MaxThreads, CC] {.
    raises: [], tags: [TypestateOp, RootEffect].}
```

Scan all registered threads and send SIGUSR1 to stalled pinned threads. Returns count of signals sent.

### `signalsSent`

```nim
func signalsSent[MaxThreads: static int; CC: static PinScopeCardinality](
    c: ScanComplete[MaxThreads, CC]): int {.notATransition.}
```

Get number of signals sent during scan.

### `extractSignalCount`

```nim
func extractSignalCount[MaxThreads: static int; CC: static PinScopeCardinality](
    c: ScanComplete[MaxThreads, CC]): int {.notATransition.}
```

Extract the count of signals sent. Terminal operation.


## Macros

### `match`

```nim
macro match[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    value: NeutralizeContextStates[MaxThreads, CC]; arms: untyped): untyped
```

Single-target pattern match on states of typestate 'NeutralizeContext'; rewrites to <tt class="docutils literal"><span class="pre"><span class="Keyword">block</span><span class="Punctuation">:</span> <span class="Keyword">let</span> <span class="Keyword">bind</span> <span class="Operator">=</span> <span class="Identifier">move</span><span class="Punctuation">(</span><span class="Identifier">value</span><span class="Punctuation">)</span><span class="Punctuation">;</span> <span class="Identifier">body</span></span></tt>. Syntax is <tt class="docutils literal"><span class="pre"><span class="Operator">&lt;</span><span class="Identifier">StateName</span><span class="Operator">&gt;</span><span class="Punctuation">(</span><span class="Keyword">bind</span><span class="Punctuation">)</span><span class="Punctuation">:</span></span></tt>, with exactly one arm.

