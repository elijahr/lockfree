---
title: "lockfree/smr/nebr/typestates/guard"
description: "API reference for lockfree/smr/nebr/typestates/guard"
---

<p>EpochGuard typestate for pin/unpin lifecycle.</p>
<p>Ensures threads properly enter/exit critical sections.</p>
<p>The typestate carries two static generic-param axes:</p>
<ul class="simple"><li><tt class="docutils literal"><span class="pre"><span class="Identifier">MaxThreads</span><span class="Punctuation">:</span> <span class="Keyword">static</span> <span class="Identifier">int</span></span></tt> — capacity of the manager's thread array.</li>
<li><tt class="docutils literal"><span class="pre"><span class="Identifier">CC</span><span class="Punctuation">:</span> <span class="Keyword">static</span> <span class="Identifier">PinScopeCardinality</span> <span class="Operator">=</span> <span class="Identifier">ccSingle</span></span></tt> — consumer-cardinality phantom mirroring <tt class="docutils literal"><span class="pre"><span class="Identifier">DebraManager</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">ThreadHandle</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">RegistrationContext</span></span></tt>. Default <tt class="docutils literal"><span class="pre"><span class="Identifier">ccSingle</span></span></tt> matches the 0.7.x call shape, so existing call sites that spell only <tt class="docutils literal"><span class="pre"><span class="Identifier">MaxThreads</span></span></tt> continue to bind cleanly.</li>
</ul>
<p>Codegen-emitted helpers (variant type <tt class="docutils literal"><span class="pre"><span class="Identifier">UnpinResult</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Operator">=</span><span class="Identifier">copy</span></span></tt> hooks, <tt class="docutils literal"><span class="pre"><span class="Identifier">state</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt> procs, <tt class="docutils literal"><span class="pre"><span class="Operator">$</span></span></tt> overloads, <tt class="docutils literal"><span class="pre"><span class="Identifier">match</span></span></tt> macros) inherit <tt class="docutils literal"><span class="pre"><span class="Identifier">CC</span> <span class="Operator">=</span> <span class="Identifier">ccSingle</span></span></tt> via the typestate macro's <tt class="docutils literal"><span class="pre"><span class="Identifier">defaults</span><span class="Punctuation">:</span></span></tt> body section (typestates 0.9.2+).</p>

<h2><a class="toc-backref" id="states" href="#states">States</a></h2><ul class="simple"><li><tt class="docutils literal"><span class="pre"><span class="Identifier">Unpinned</span></span></tt> — outside a critical section. Constructed via <tt class="docutils literal"><span class="pre"><span class="Identifier">unpinned</span></span></tt>.</li>
<li><tt class="docutils literal"><span class="pre"><span class="Identifier">Pinned</span></span></tt> — inside a critical section, epoch captured.</li>
<li><tt class="docutils literal"><span class="pre"><span class="Identifier">Neutralized</span></span></tt> — was Pinned, then signaled; must <tt class="docutils literal"><span class="pre"><span class="Identifier">acknowledge</span></span></tt> before re-pinning.</li>
<li><tt class="docutils literal"><span class="pre"><span class="Identifier">Closed</span></span></tt> — terminal state reached only by the destructor path of <tt class="docutils literal"><span class="pre"><span class="Identifier">PinnedScope</span></span></tt>. User code SHOULD NOT call <tt class="docutils literal"><span class="pre"><span class="Identifier">close</span></span></tt> directly; rely on <tt class="docutils literal"><span class="pre"><span class="Identifier">PinnedScope</span></span></tt> to drive the lifecycle. <tt class="docutils literal"><span class="pre"><span class="Identifier">close</span></span></tt> performs no atomic operations — the slot's <tt class="docutils literal"><span class="pre"><span class="Identifier">pinned</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">neutralized</span></span></tt> flags were already cleared by the preceding <tt class="docutils literal"><span class="pre"><span class="Identifier">unpin</span></span></tt> (or <tt class="docutils literal"><span class="pre"><span class="Identifier">unpin</span> <span class="Operator">+</span> <span class="Identifier">acknowledge</span></span></tt>) call.</li>
</ul>

<h2><a class="toc-backref" id="pitfalls" href="#pitfalls">Pitfalls</a></h2><ul class="simple"><li>The <tt class="docutils literal"><span class="pre"><span class="Identifier">Unpinned</span></span></tt> -&gt; <tt class="docutils literal"><span class="pre"><span class="Identifier">Pinned</span></span></tt> -&gt; <tt class="docutils literal"><span class="pre"><span class="Identifier">Unpinned</span></span></tt>/<tt class="docutils literal"><span class="pre"><span class="Identifier">Neutralized</span></span></tt> typestate sequence must be respected. Calling <tt class="docutils literal"><span class="pre"><span class="Identifier">pin</span></span></tt> on a handle that is already pinned at the slot level (the manager's <tt class="docutils literal"><span class="pre"><span class="Identifier">threads</span><span class="Punctuation">[</span><span class="Identifier">idx</span><span class="Punctuation">]</span><span class="Operator">.</span><span class="Identifier">pinned</span></span></tt> flag is true) leaves the slot inconsistent. Use <tt class="docutils literal"><span class="pre"><span class="Identifier">PinnedScope</span></span></tt> (in <tt class="docutils literal"><span class="pre"><span class="Identifier">debra</span><span class="Operator">/</span><span class="Identifier">typestates</span><span class="Operator">/</span><span class="Identifier">pinned_scope</span></span></tt>) for the common path; reach for the typestate API only when you need finer control.</li>
<li>If <tt class="docutils literal"><span class="pre"><span class="Identifier">unpin</span></span></tt> returns <tt class="docutils literal"><span class="pre"><span class="Identifier">Neutralized</span></span></tt>, the thread was signaled while inside the critical section. Call <tt class="docutils literal"><span class="pre"><span class="Identifier">acknowledge</span></span></tt> before re-pinning. Skipping <tt class="docutils literal"><span class="pre"><span class="Identifier">acknowledge</span></span></tt> will leave the slot's <tt class="docutils literal"><span class="pre"><span class="Identifier">neutralized</span></span></tt> flag set, and the next <tt class="docutils literal"><span class="pre"><span class="Identifier">pin</span></span></tt>/<tt class="docutils literal"><span class="pre"><span class="Identifier">unpin</span></span></tt> cycle will misreport state.</li>
<li><tt class="docutils literal"><span class="pre"><span class="Identifier">Pinned</span><span class="Punctuation">[</span><span class="Identifier">MT</span><span class="Punctuation">,</span> <span class="Identifier">CC</span><span class="Punctuation">]</span></span></tt> carries the captured <tt class="docutils literal"><span class="pre"><span class="Identifier">epoch</span></span></tt> field; do not mutate the manager's global epoch under the assumption a particular <tt class="docutils literal"><span class="pre"><span class="Identifier">Pinned</span></span></tt> value tracks it. Advance the manager epoch on the worker side, then re-pin to refresh.</li>
</ul>

<h2><a class="toc-backref" id="see-also" href="#see-also">See also</a></h2><ul class="simple"><li><a class="reference internal" href="#debra">debra</a> - the recommended high-level RAII guard.</li>
<li><a class="reference internal" href="#debra">debra</a> - <tt class="docutils literal"><span class="pre"><span class="Identifier">RetireReady</span></span></tt> constructed from <tt class="docutils literal"><span class="pre"><span class="Identifier">Pinned</span></span></tt>.</li>
</ul>


## Types

### `EpochGuardContext`

```nim
EpochGuardContext[MaxThreads; CC] = object of RootObj
  handle*: ThreadHandle[MaxThreads, CC]
  epoch*: uint64
```

### `Unpinned`

```nim
Unpinned[MaxThreads; CC] = distinct EpochGuardContext[MaxThreads, CC]
```

### `Pinned`

```nim
Pinned[MaxThreads; CC] = distinct EpochGuardContext[MaxThreads, CC]
```

### `Neutralized`

```nim
Neutralized[MaxThreads; CC] = distinct EpochGuardContext[MaxThreads, CC]
```

### `Closed`

```nim
Closed[MaxThreads; CC] = distinct EpochGuardContext[MaxThreads, CC]
```

### `EpochGuardContextState`

```nim
EpochGuardContextState = enum
  fsPinned, fsUnpinned, fsClosed, fsNeutralized
```

### `EpochGuardContextStates`

```nim
EpochGuardContextStates[MaxThreads; CC] = Pinned[MaxThreads, CC] |
    Unpinned[MaxThreads, CC] |
    Closed[MaxThreads, CC] |
    Neutralized[MaxThreads, CC]
```

### `UnpinResultKind`

```nim
UnpinResultKind = enum
  uUnpinned, uNeutralized
```

### `UnpinResult`

```nim
UnpinResult[MaxThreads; CC] = object
  case kind*: UnpinResultKind
  of uUnpinned:
    unpinned*: Unpinned[MaxThreads, CC]
  of uNeutralized:
    neutralized*: Neutralized[MaxThreads, CC]
```


## Procedures & Functions

### `state`

```nim
proc state[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    f: Pinned[MaxThreads, CC]): EpochGuardContextState
```

Runtime state inspection for Pinned. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    f: Unpinned[MaxThreads, CC]): EpochGuardContextState
```

Runtime state inspection for Unpinned. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    f: Closed[MaxThreads, CC]): EpochGuardContextState
```

Runtime state inspection for Closed. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    f: Neutralized[MaxThreads, CC]): EpochGuardContextState
```

Runtime state inspection for Neutralized. Returns the enum value for pattern matching in case expressions.

### ``$``

```nim
proc `$`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    s: Pinned[MaxThreads, CC]): string
```

String representation for state 'Pinned'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    s: Unpinned[MaxThreads, CC]): string
```

String representation for state 'Unpinned'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    s: Closed[MaxThreads, CC]): string
```

String representation for state 'Closed'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    s: Neutralized[MaxThreads, CC]): string
```

String representation for state 'Neutralized'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`(s: EpochGuardContextState): string {.raises: [], tags: [], forbids: [].}
```

String representation of EpochGuardContextState enum. Strips the fs prefix for human-friendly output.

### `toUnpinResult`

```nim
proc toUnpinResult[MaxThreads: static int;
                   CC: static PinScopeCardinality = ccSingle](
    s: sink Unpinned[MaxThreads, CC]): UnpinResult[MaxThreads, CC]
```

### `toUnpinResult`

```nim
proc toUnpinResult[MaxThreads: static int;
                   CC: static PinScopeCardinality = ccSingle](
    s: sink Neutralized[MaxThreads, CC]): UnpinResult[MaxThreads, CC]
```

### ``$``

```nim
proc `$`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    r: UnpinResult[MaxThreads, CC]): string
```

String representation of branching union 'UnpinResult<a class="reference internal" href="#MaxThreads, CC">MaxThreads, CC</a>'. Returns the active branch's bare state name.

### `unpinned`

```nim
proc unpinned[MaxThreads: static int; CC: static PinScopeCardinality](
    handle: ThreadHandle[MaxThreads, CC]): Unpinned[MaxThreads, CC]
```

Create unpinned epoch guard context.

### `pin`

```nim
proc pin[MaxThreads: static int; CC: static PinScopeCardinality](
    u: sink Unpinned[MaxThreads, CC]): Pinned[MaxThreads, CC] {.raises: [],
    tags: [TypestateOp, RootEffect].}
```

Enter critical section. Blocks reclamation of current epoch.

### `unpin`

```nim
proc unpin[MaxThreads: static int; CC: static PinScopeCardinality](
    p: sink Pinned[MaxThreads, CC]): UnpinResult[MaxThreads, CC] {.raises: [],
    tags: [TypestateOp, RootEffect].}
```

Leave critical section. Returns Neutralized if signaled.

### `acknowledge`

```nim
proc acknowledge[MaxThreads: static int; CC: static PinScopeCardinality](
    n: sink Neutralized[MaxThreads, CC]): Unpinned[MaxThreads, CC] {.raises: [],
    tags: [TypestateOp, RootEffect].}
```

<p>Acknowledge neutralization. Required before re-pinning.</p>
<p>See also: <a class="reference internal" href="#unpin">unpin</a> (returns <tt class="docutils literal"><span class="pre"><span class="Identifier">Neutralized</span></span></tt> when signaled), <a class="reference internal" href="#pin">pin</a>.</p>

### `close`

```nim
proc close[MaxThreads: static int; CC: static PinScopeCardinality](
    u: sink Unpinned[MaxThreads, CC]): Closed[MaxThreads, CC] {.raises: [],
    tags: [TypestateOp, RootEffect].}
```

<p>One-way exit transition for <tt class="docutils literal"><span class="pre"><span class="Identifier">PinnedScope</span></span></tt>'s destructor path.</p>
<p><tt class="docutils literal"><span class="pre"><span class="Identifier">close</span></span></tt> is reserved for the <tt class="docutils literal"><span class="pre"><span class="Identifier">PinnedScope</span><span class="Operator">.=</span><span class="Identifier">destroy</span></span></tt> path; user code should rely on <tt class="docutils literal"><span class="pre"><span class="Identifier">PinnedScope</span></span></tt> to drive the lifecycle and should not call <tt class="docutils literal"><span class="pre"><span class="Identifier">close</span></span></tt> directly. <tt class="docutils literal"><span class="pre"><span class="Identifier">close</span></span></tt> performs no atomic operations; the slot's <tt class="docutils literal"><span class="pre"><span class="Identifier">pinned</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">neutralized</span></span></tt> flags were already cleared by the preceding <tt class="docutils literal"><span class="pre"><span class="Identifier">unpin</span></span></tt> (or <tt class="docutils literal"><span class="pre"><span class="Identifier">unpin</span> <span class="Operator">+</span> <span class="Identifier">acknowledge</span></span></tt>) call.</p>

### `epoch`

```nim
func epoch[MaxThreads: static int; CC: static PinScopeCardinality](
    p: Pinned[MaxThreads, CC]): uint64 {.notATransition.}
```

Get the epoch this thread is pinned at.

### `handle`

```nim
func handle[MaxThreads: static int; CC: static PinScopeCardinality](
    p: Pinned[MaxThreads, CC]): ThreadHandle[MaxThreads, CC] {.notATransition.}
```

Get the thread handle.


## Templates

### ``-&gt;``

```nim
template `->`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    _: typedesc[UnpinResult[MaxThreads, CC]]; s: sink Unpinned[MaxThreads, CC]): UnpinResult[
    MaxThreads, CC]
```

### ``-&gt;``

```nim
template `->`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    _: typedesc[UnpinResult[MaxThreads, CC]];
    s: sink Neutralized[MaxThreads, CC]): UnpinResult[MaxThreads, CC]
```


## Macros

### `match`

```nim
macro match[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    value: UnpinResult[MaxThreads, CC]; arms: untyped): untyped
```

Pattern-match on a branching union; rewrites into a <tt class="docutils literal"><span class="pre"><span class="Keyword">case</span></span></tt> over the kind discriminator. The value being matched must be a <tt class="docutils literal"><span class="pre"><span class="Keyword">var</span></span></tt> binding. Branch fields are extracted with <tt class="docutils literal"><span class="pre"><span class="Identifier">move</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt>, which requires a mutable binding. Syntax is <tt class="docutils literal"><span class="pre"><span class="Identifier">StateName</span><span class="Punctuation">(</span><span class="Keyword">bind</span><span class="Punctuation">)</span><span class="Punctuation">:</span></span></tt>, not <tt class="docutils literal"><span class="pre"><span class="Keyword">of</span> <span class="Identifier">StateName</span> <span class="Keyword">as</span> <span class="Keyword">bind</span><span class="Punctuation">:</span></span></tt>.

### `match`

```nim
macro match[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    value: EpochGuardContextStates[MaxThreads, CC]; arms: untyped): untyped
```

Single-target pattern match on states of typestate 'EpochGuardContext'; rewrites to <tt class="docutils literal"><span class="pre"><span class="Keyword">block</span><span class="Punctuation">:</span> <span class="Keyword">let</span> <span class="Keyword">bind</span> <span class="Operator">=</span> <span class="Identifier">move</span><span class="Punctuation">(</span><span class="Identifier">value</span><span class="Punctuation">)</span><span class="Punctuation">;</span> <span class="Identifier">body</span></span></tt>. Syntax is <tt class="docutils literal"><span class="pre"><span class="Operator">&lt;</span><span class="Identifier">StateName</span><span class="Operator">&gt;</span><span class="Punctuation">(</span><span class="Keyword">bind</span><span class="Punctuation">)</span><span class="Punctuation">:</span></span></tt>, with exactly one arm.

