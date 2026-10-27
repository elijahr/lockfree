---
title: "lockfree/smr/nebr/typestates/signal_handler"
description: "API reference for lockfree/smr/nebr/typestates/signal_handler"
---

<p>SignalHandler typestate.</p>
<p>Ensures signal handler is installed before DEBRA operations.</p>
<p>The <tt class="docutils literal"><span class="pre"><span class="Identifier">install</span></span></tt> transition delegates to the production <tt class="docutils literal"><span class="pre"><span class="Identifier">signal</span><span class="Operator">.</span><span class="Identifier">installSignalHandler</span></span></tt> (the single source of truth for the SIGUSR1 neutralization handler), so driving this typestate installs the <em>real</em> handler rather than a placeholder. On Windows <tt class="docutils literal"><span class="pre"><span class="Identifier">installSignalHandler</span></span></tt> is itself a no-op because the neutralization protocol uses SuspendThread/ResumeThread directly; the typestate transition is retained for API parity so callers compile unchanged.</p>


## Types

### `SignalHandlerContext`

```nim
SignalHandlerContext = object of RootObj
```

### `HandlerUninstalled`

```nim
HandlerUninstalled = distinct SignalHandlerContext
```

### `HandlerInstalled`

```nim
HandlerInstalled = distinct SignalHandlerContext
```

### `SignalHandlerContextState`

```nim
SignalHandlerContextState = enum
  fsHandlerUninstalled, fsHandlerInstalled
```

### `SignalHandlerContextStates`

```nim
SignalHandlerContextStates = HandlerUninstalled | HandlerInstalled
```


## Procedures & Functions

### `state`

```nim
proc state(f: HandlerUninstalled): SignalHandlerContextState {.raises: [],
    tags: [], forbids: [].}
```

Runtime state inspection for HandlerUninstalled. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state(f: HandlerInstalled): SignalHandlerContextState {.raises: [],
    tags: [], forbids: [].}
```

Runtime state inspection for HandlerInstalled. Returns the enum value for pattern matching in case expressions.

### ``$``

```nim
proc `$`(s: HandlerUninstalled): string {.raises: [], tags: [], forbids: [].}
```

String representation for state 'HandlerUninstalled'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`(s: HandlerInstalled): string {.raises: [], tags: [], forbids: [].}
```

String representation for state 'HandlerInstalled'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`(s: SignalHandlerContextState): string {.raises: [], tags: [],
    forbids: [].}
```

String representation of SignalHandlerContextState enum. Strips the fs prefix for human-friendly output.

### ``=copy``

```nim
proc `=copy`(dest: var HandlerUninstalled; src: HandlerUninstalled) {.error: "State \'HandlerUninstalled\' cannot be copied. Transitions consume the input state.".}
```

### ``=copy``

```nim
proc `=copy`(dest: var HandlerInstalled; src: HandlerInstalled) {.error: "State \'HandlerInstalled\' cannot be copied. Transitions consume the input state.".}
```

### `initSignalHandler`

```nim
proc initSignalHandler(): HandlerUninstalled {.raises: [], tags: [], forbids: [].}
```

Create uninstalled signal handler context.

### `install`

```nim
proc install(h: sink HandlerUninstalled): HandlerInstalled {.raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

<p>Install SIGUSR1 handler for DEBRA+ neutralization.</p>
<p>Delegates to the production <tt class="docutils literal"><span class="pre"><span class="Identifier">signal</span><span class="Operator">.</span><span class="Identifier">installSignalHandler</span></span></tt> so this typestate installs the real neutralization handler (idempotent and thread-safe). On Windows <tt class="docutils literal"><span class="pre"><span class="Identifier">installSignalHandler</span></span></tt> is a no-op (no async handler is needed); the transition still flips <tt class="docutils literal"><span class="pre"><span class="Identifier">installed</span> <span class="Operator">=</span> <span class="Identifier">true</span></span></tt> for API parity.</p>

### `isInstalled`

```nim
func isInstalled(h: HandlerInstalled): bool {.notATransition, raises: [],
    tags: [], forbids: [].}
```

Check if handler is installed.


## Macros

### `match`

```nim
macro match(value: SignalHandlerContextStates; arms: untyped): untyped
```

Single-target pattern match on states of typestate 'SignalHandlerContext'; rewrites to <tt class="docutils literal"><span class="pre"><span class="Keyword">block</span><span class="Punctuation">:</span> <span class="Keyword">let</span> <span class="Keyword">bind</span> <span class="Operator">=</span> <span class="Identifier">move</span><span class="Punctuation">(</span><span class="Identifier">value</span><span class="Punctuation">)</span><span class="Punctuation">;</span> <span class="Identifier">body</span></span></tt>. Syntax is <tt class="docutils literal"><span class="pre"><span class="Operator">&lt;</span><span class="Identifier">StateName</span><span class="Operator">&gt;</span><span class="Punctuation">(</span><span class="Keyword">bind</span><span class="Punctuation">)</span><span class="Punctuation">:</span></span></tt>, with exactly one arm.

