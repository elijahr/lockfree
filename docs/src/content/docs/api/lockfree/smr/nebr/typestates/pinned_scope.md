---
title: "lockfree/smr/nebr/typestates/pinned_scope"
description: "API reference for lockfree/smr/nebr/typestates/pinned_scope"
---

<p>PinnedScope RAII guard for pin-scoped retire.</p>
<p><tt class="docutils literal"><span class="pre"><span class="Identifier">PinnedScope</span><span class="Punctuation">[</span><span class="Identifier">MT</span><span class="Punctuation">,</span> <span class="Identifier">CC</span><span class="Punctuation">]</span></span></tt> is the recommended high-level entry point for the pin/retire/unpin cycle, replacing the now-deprecated block-form sugar. Construct via <tt class="docutils literal"><span class="pre"><span class="Identifier">pinScope</span><span class="Punctuation">(</span><span class="Identifier">unpinned</span><span class="Punctuation">(</span><span class="Identifier">handle</span><span class="Punctuation">)</span><span class="Punctuation">)</span></span></tt>; destruction (block exit, scope end, explicit <tt class="docutils literal"><span class="pre"><span class="Operator">=</span><span class="Identifier">destroy</span></span></tt>) drives the underlying <tt class="docutils literal"><span class="pre"><span class="Identifier">EpochGuardContext</span></span></tt> through <tt class="docutils literal"><span class="pre"><span class="Identifier">unpin</span></span></tt> (and, if signaled, <tt class="docutils literal"><span class="pre"><span class="Identifier">acknowledge</span></span></tt>) and finally <tt class="docutils literal"><span class="pre"><span class="Identifier">close</span></span></tt>, clearing the slot's <tt class="docutils literal"><span class="pre"><span class="Identifier">pinned</span></span></tt> flag.</p>
<p>The typestate carries two static generic-param axes:</p>
<ul class="simple"><li><tt class="docutils literal"><span class="pre"><span class="Identifier">MT</span><span class="Punctuation">:</span> <span class="Keyword">static</span> <span class="Identifier">int</span></span></tt> — capacity of the manager's thread array.</li>
<li><tt class="docutils literal"><span class="pre"><span class="Identifier">CC</span><span class="Punctuation">:</span> <span class="Keyword">static</span> <span class="Identifier">PinScopeCardinality</span> <span class="Operator">=</span> <span class="Identifier">ccSingle</span></span></tt> — consumer-cardinality phantom mirroring <tt class="docutils literal"><span class="pre"><span class="Identifier">DebraManager</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">ThreadHandle</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">EpochGuardContext</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">RetireContext</span></span></tt>. Default <tt class="docutils literal"><span class="pre"><span class="Identifier">ccSingle</span></span></tt> matches the 0.7.x call shape.</li>
</ul>
<p>Codegen-emitted helpers (=copy hooks, <tt class="docutils literal"><span class="pre"><span class="Identifier">state</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt> procs, <tt class="docutils literal"><span class="pre"><span class="Operator">$</span></span></tt> overloads, <tt class="docutils literal"><span class="pre"><span class="Identifier">match</span></span></tt> macros) inherit <tt class="docutils literal"><span class="pre"><span class="Identifier">CC</span> <span class="Operator">=</span> <span class="Identifier">ccSingle</span></span></tt> via the typestate macro's <tt class="docutils literal"><span class="pre"><span class="Identifier">defaults</span><span class="Punctuation">:</span></span></tt> body section (typestates 0.9.2+).</p>

<h2><a class="toc-backref" id="states" href="#states">States</a></h2><ul class="simple"><li><tt class="docutils literal"><span class="pre"><span class="Identifier">PinnedScopeAlive</span></span></tt> — the scope holds a <tt class="docutils literal"><span class="pre"><span class="Identifier">Pinned</span><span class="Punctuation">[</span><span class="Identifier">MT</span><span class="Punctuation">,</span> <span class="Identifier">CC</span><span class="Punctuation">]</span></span></tt> value and is eligible for <tt class="docutils literal"><span class="pre"><span class="Identifier">retireOnCAS</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">retireOnPublish</span></span></tt>.</li>
<li><tt class="docutils literal"><span class="pre"><span class="Identifier">PinnedScopeDestroyed</span></span></tt> — terminal state reached via <tt class="docutils literal"><span class="pre"><span class="Operator">=</span><span class="Identifier">destroy</span></span></tt>. The inner <tt class="docutils literal"><span class="pre"><span class="Identifier">Pinned</span></span></tt> was moved out and driven to <tt class="docutils literal"><span class="pre"><span class="Identifier">Closed</span></span></tt> through the <tt class="docutils literal"><span class="pre"><span class="Identifier">unpin</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">acknowledge</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">close</span></span></tt> chain.</li>
</ul>

<h2><a class="toc-backref" id="retire-methods" href="#retire-methods">Retire methods</a></h2><ul class="simple"><li><tt class="docutils literal"><span class="pre"><span class="Identifier">retireOnCAS</span></span></tt> — atomically swap a published pointer, retire the displaced value. Multi-writer safe (the CAS arbitrates).</li>
<li><tt class="docutils literal"><span class="pre"><span class="Identifier">retireOnPublish</span></span></tt> — store-and-retire. <strong>FOOT-GUN: single-writer required (DR-S4).</strong> nim-debra cannot statically verify that the caller's atomic is single-writer. Under multi-writer use, the displaced value may be retired concurrently and double-freed on reclamation. Use <tt class="docutils literal"><span class="pre"><span class="Identifier">retireOnCAS</span></span></tt> for the multi-writer-safe form.</li>
</ul>

<h2><a class="toc-backref" id="pitfalls" href="#pitfalls">Pitfalls</a></h2><ul class="simple"><li>Do NOT call <tt class="docutils literal"><span class="pre"><span class="Identifier">pinScope</span></span></tt> while the thread is already pinned at the slot level. A <tt class="docutils literal"><span class="pre"><span class="Identifier">doAssert</span></span></tt> guards in release builds.</li>
<li><tt class="docutils literal"><span class="pre"><span class="Identifier">PinnedScope</span></span></tt> is non-copyable (<tt class="docutils literal"><span class="pre"><span class="Operator">=</span><span class="Identifier">copy</span></span></tt> is <tt class="docutils literal"><span class="pre"><span class="Punctuation">{</span><span class="Operator">.</span><span class="Identifier">error</span><span class="Operator">.</span><span class="Punctuation">}</span></span></tt>). Move it between scopes if you must transfer ownership; the destructor runs exactly once at the final owner's scope end.</li>
<li><tt class="docutils literal"><span class="pre"><span class="Operator">=</span><span class="Identifier">wasMoved</span></span></tt> marks the source as <tt class="docutils literal"><span class="pre"><span class="Identifier">consumed</span> <span class="Operator">=</span> <span class="Identifier">true</span></span></tt>; a re-entrant <tt class="docutils literal"><span class="pre"><span class="Operator">=</span><span class="Identifier">destroy</span></span></tt> on a moved-from value is a no-op.</li>
</ul>

<h2><a class="toc-backref" id="see-also" href="#see-also">See also</a></h2><ul class="simple"><li><a class="reference internal" href="#debra">debra</a> / <a class="reference internal" href="#unpin">unpin</a> / <a class="reference internal" href="#acknowledge">acknowledge</a> / <a class="reference internal" href="#close">close</a> — the underlying <tt class="docutils literal"><span class="pre"><span class="Identifier">EpochGuardContext</span></span></tt> transitions driven internally.</li>
<li><a class="reference internal" href="#debra">debra</a> — <tt class="docutils literal"><span class="pre"><span class="Identifier">RetireReady</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">Retired</span></span></tt> rotation used inside the retire methods.</li>
</ul>


## Types

### `PinnedScopeContext`

```nim
PinnedScopeContext[MT; CC] = object of RootObj
```

### `PinnedScopeAlive`

```nim
PinnedScopeAlive[MT; CC] = distinct PinnedScopeContext[MT, CC]
```

### `PinnedScopeDestroyed`

```nim
PinnedScopeDestroyed[MT; CC] = distinct PinnedScopeContext[MT, CC]
```

### `PinnedScopeLifecycleState`

```nim
PinnedScopeLifecycleState = enum
  fsPinnedScopeAlive, fsPinnedScopeDestroyed
```

### `PinnedScopeLifecycleStates`

```nim
PinnedScopeLifecycleStates[MT; CC] = PinnedScopeAlive[MT, CC] |
    PinnedScopeDestroyed[MT, CC]
```

### `PinnedScope`

```nim
PinnedScope[MT; CC] {..} = object
  state*: Pinned[MT, CC]
  consumed*: bool
```


## Procedures & Functions

### `state`

```nim
proc state[MT: static int; CC: static PinScopeCardinality = ccSingle](
    f: PinnedScopeAlive[MT, CC]): PinnedScopeLifecycleState
```

Runtime state inspection for PinnedScopeAlive. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state[MT: static int; CC: static PinScopeCardinality = ccSingle](
    f: PinnedScopeDestroyed[MT, CC]): PinnedScopeLifecycleState
```

Runtime state inspection for PinnedScopeDestroyed. Returns the enum value for pattern matching in case expressions.

### ``$``

```nim
proc `$`[MT: static int; CC: static PinScopeCardinality = ccSingle](
    s: PinnedScopeAlive[MT, CC]): string
```

String representation for state 'PinnedScopeAlive'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`[MT: static int; CC: static PinScopeCardinality = ccSingle](
    s: PinnedScopeDestroyed[MT, CC]): string
```

String representation for state 'PinnedScopeDestroyed'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`(s: PinnedScopeLifecycleState): string {.raises: [], tags: [],
    forbids: [].}
```

String representation of PinnedScopeLifecycleState enum. Strips the fs prefix for human-friendly output.

### ``=copy``

```nim
proc `=copy`[MT: static int; CC: static PinScopeCardinality = ccSingle](
    dest: var PinnedScopeAlive[MT, CC]; src: PinnedScopeAlive[MT, CC]) {.error: "State \'PinnedScopeAlive\' cannot be copied. Transitions consume the input state.".}
```

### ``=copy``

```nim
proc `=copy`[MT: static int; CC: static PinScopeCardinality = ccSingle](
    dest: var PinnedScopeDestroyed[MT, CC]; src: PinnedScopeDestroyed[MT, CC]) {.error: "State \'PinnedScopeDestroyed\' cannot be copied. Transitions consume the input state.".}
```

### `pinScope`

```nim
proc pinScope[MT: static int; CC: static PinScopeCardinality](
    u: sink Unpinned[MT, CC]): PinnedScope[MT, CC] {.raises: [].}
```

<p>Construct a pinned scope. RAII-style: destruction unpins.</p>
<p>Renamed from <tt class="docutils literal"><span class="pre"><span class="Identifier">pin</span></span></tt> (the plan's original spelling) to <tt class="docutils literal"><span class="pre"><span class="Identifier">pinScope</span></span></tt> to avoid a proc-name collision with <tt class="docutils literal"><span class="pre"><span class="Identifier">guard</span><span class="Operator">.</span><span class="Identifier">pin</span></span></tt> (both consume <tt class="docutils literal"><span class="pre"><span class="Identifier">Unpinned</span><span class="Punctuation">[</span><span class="Identifier">MT</span><span class="Punctuation">,</span> <span class="Identifier">CC</span><span class="Punctuation">]</span></span></tt> but return different result typestates, and Nim cannot disambiguate by return type at standard call sites).</p>

<h2><a class="toc-backref" id="footminusguncolon-do-not-call-nimpinscope-while-already-pinned-at-the-slot" href="#footminusguncolon-do-not-call-nimpinscope-while-already-pinned-at-the-slot">Foot-gun: do NOT call <tt class="docutils literal"><span class="pre"><span class="Identifier">pinScope</span></span></tt> while already pinned at the slot</a></h2><p>level. A <tt class="docutils literal"><span class="pre"><span class="Identifier">doAssert</span></span></tt> guards in release builds. Use <tt class="docutils literal"><span class="pre"><span class="Identifier">PinnedScope</span></span></tt> per-thread; the guard catches double-pin from re-entrant code.</p>

<h2><a class="toc-backref" id="cleanup-contract" href="#cleanup-contract">Cleanup contract</a></h2><p>Cleanup is destructor-driven (<tt class="docutils literal"><span class="pre"><span class="Operator">=</span><span class="Identifier">destroy</span></span></tt>). Use a <tt class="docutils literal"><span class="pre"><span class="Identifier">PinnedScope</span><span class="Punctuation">[</span><span class="Identifier">MT</span><span class="Punctuation">,</span> <span class="Identifier">CC</span><span class="Punctuation">]</span></span></tt> inside a normal Nim <tt class="docutils literal"><span class="pre"><span class="Keyword">block</span><span class="Punctuation">:</span></span></tt> (or as a local in a proc); the destructor runs at the closing brace and drives the inner <tt class="docutils literal"><span class="pre"><span class="Identifier">Pinned</span></span></tt> through <tt class="docutils literal"><span class="pre"><span class="Identifier">unpin</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">acknowledge</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">close</span></span></tt>, clearing the slot's <tt class="docutils literal"><span class="pre"><span class="Identifier">pinned</span></span></tt> flag.</p>
<p><strong>No explicit `try/finally` is required at the caller site.</strong> Raises inside the scope — including chronos <tt class="docutils literal"><span class="pre"><span class="Identifier">CancelledError</span></span></tt> and any other <tt class="docutils literal"><span class="pre"><span class="Identifier">CatchableError</span></span></tt> — unwind through the destructor automatically. The cleanup runs on EVERY control-flow exit (normal return, <tt class="docutils literal"><span class="pre"><span class="Keyword">defer</span></span></tt>, raise, scope end), not just the happy path. See <tt class="docutils literal"><span class="pre"><span class="Identifier">tests</span><span class="Operator">/</span><span class="Identifier">t_pinscope_unwind</span><span class="Operator">.</span><span class="Identifier">nim</span></span></tt> for the regression test that exercises the raise path across <tt class="docutils literal"><span class="pre"><span class="Identifier">arc</span> <span class="Operator">/</span> <span class="Identifier">orc</span> <span class="Operator">/</span> <span class="Identifier">atomicArc</span></span></tt>.</p>
<p>Cancellation discipline (R10 / design §5.4.3) is still required for async callers: do not hold a <tt class="docutils literal"><span class="pre"><span class="Identifier">PinnedScope</span></span></tt> across an <tt class="docutils literal"><span class="pre"><span class="Identifier">await</span></span></tt>. The adapter in <tt class="docutils literal"><span class="pre"><span class="Identifier">src</span><span class="Operator">/</span><span class="Identifier">lockfree</span><span class="Operator">/</span><span class="Identifier">chronos</span><span class="Operator">.</span><span class="Identifier">nim</span></span></tt> already enforces this by releasing the pin inside the inner sync pop before the <tt class="docutils literal"><span class="pre"><span class="Identifier">await</span> <span class="Identifier">event</span><span class="Operator">.</span><span class="Identifier">wait</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt> line.</p>

### `retireOnCAS`

```nim
proc retireOnCAS[MT: static int; CC: static PinScopeCardinality;
                 T: ptr | pointer](scope: var PinnedScope[MT, CC];
                                   atomic: var Atomic[T]; expected: var T;
                                   desired: T; dtor: Destructor): bool {.
    discardable, raises: [].}
```

<p>Atomically swap a published pointer and retire the displaced value.</p>
<p>Returns true on CAS success (after rotating <tt class="docutils literal"><span class="pre"><span class="Identifier">scope</span><span class="Operator">.</span><span class="Identifier">state</span></span></tt> through <tt class="docutils literal"><span class="pre"><span class="Identifier">RetireReady</span></span></tt> -&gt; <tt class="docutils literal"><span class="pre"><span class="Identifier">Retired</span></span></tt> -&gt; <tt class="docutils literal"><span class="pre"><span class="Identifier">Pinned</span></span></tt>). Returns false on CAS failure, leaving <tt class="docutils literal"><span class="pre"><span class="Identifier">scope</span><span class="Operator">.</span><span class="Identifier">state</span></span></tt> unchanged.</p>
<p>Callable under any <tt class="docutils literal"><span class="pre"><span class="Identifier">CC</span></span></tt> (DR-S3).</p>
<p><tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> is an in/out parameter: on CAS failure it is updated to the value actually observed (as in stdlib <tt class="docutils literal"><span class="pre"><span class="Identifier">compareExchange</span></span></tt>), so a retry loop need not re-load before the next attempt.</p>
<p><strong>`T` contract:</strong> <tt class="docutils literal"><span class="pre"><span class="Identifier">T</span></span></tt> is constrained to <tt class="docutils literal"><span class="pre"><span class="Keyword">ptr</span> <span class="Operator">|</span> <span class="Identifier">pointer</span></span></tt> (a raw pointer type, <tt class="docutils literal"><span class="pre"><span class="Keyword">ptr</span> <span class="Identifier">X</span></span></tt> or <tt class="docutils literal"><span class="pre"><span class="Identifier">pointer</span></span></tt>). The displaced value is <tt class="docutils literal"><span class="pre"><span class="Keyword">cast</span><span class="Punctuation">[</span><span class="Identifier">pointer</span><span class="Punctuation">]</span></span></tt> and reclaimed via <tt class="docutils literal"><span class="pre"><span class="Identifier">dtor</span></span></tt>, so instantiating over a <tt class="docutils literal"><span class="pre"><span class="Keyword">ref</span></span></tt> is rejected at compile time — refs are GC-managed and would double-free on manual reclamation. Generic wrappers forwarding their own element type must likewise admit only pointer-shaped types.</p>

### `retireOnPublish`

```nim
proc retireOnPublish[MT: static int; CC: static PinScopeCardinality;
                     T: ptr | pointer](scope: var PinnedScope[MT, CC];
                                       atomic: var Atomic[T]; desired: T;
                                       dtor: Destructor) {.raises: [].}
```

<p><strong>FOOT-GUN — single-writer required (DR-S4).</strong></p>
<p>Stores <tt class="docutils literal"><span class="pre">desired</span></tt> into <tt class="docutils literal"><span class="pre">atomic</span></tt> and retires the displaced value. nim-debra cannot statically verify that <tt class="docutils literal"><span class="pre">atomic</span></tt> is single-writer; under multi-writer use, the displaced value may be retired concurrently and double-freed on reclamation.</p>
<p>Use <a class="reference internal" href="#retireOnCAS">retireOnCAS</a> for the multi-writer-safe form.</p>
<p><strong>`T` contract:</strong> <tt class="docutils literal"><span class="pre"><span class="Identifier">T</span></span></tt> is constrained to <tt class="docutils literal"><span class="pre"><span class="Keyword">ptr</span> <span class="Operator">|</span> <span class="Identifier">pointer</span></span></tt> (a raw pointer type, <tt class="docutils literal"><span class="pre"><span class="Keyword">ptr</span> <span class="Identifier">X</span></span></tt> or <tt class="docutils literal"><span class="pre"><span class="Identifier">pointer</span></span></tt>). The displaced value is <tt class="docutils literal"><span class="pre"><span class="Keyword">cast</span><span class="Punctuation">[</span><span class="Identifier">pointer</span><span class="Punctuation">]</span></span></tt> and reclaimed via <tt class="docutils literal"><span class="pre"><span class="Identifier">dtor</span></span></tt>, so instantiating over a <tt class="docutils literal"><span class="pre"><span class="Keyword">ref</span></span></tt> is rejected at compile time — refs are GC-managed and would double-free on manual reclamation. Generic wrappers forwarding their own element type must likewise admit only pointer-shaped types.</p>

### ``=destroy``

```nim
proc `=destroy`[MT: static int; CC: static PinScopeCardinality](
    scope: var PinnedScope[MT, CC]) {.raises: [], raises: [].}
```

<p>Destructor: drives the inner <tt class="docutils literal"><span class="pre"><span class="Identifier">Pinned</span></span></tt> through <tt class="docutils literal"><span class="pre"><span class="Identifier">unpin</span></span></tt> (and, if the thread was signaled, <tt class="docutils literal"><span class="pre"><span class="Identifier">acknowledge</span></span></tt>) and finally <tt class="docutils literal"><span class="pre"><span class="Identifier">close</span></span></tt>, clearing the slot's <tt class="docutils literal"><span class="pre"><span class="Identifier">pinned</span></span></tt> flag.</p>
<p>A <tt class="docutils literal"><span class="pre"><span class="Operator">=</span><span class="Identifier">wasMoved</span></span></tt>-marked scope (i.e. one whose value was moved into another scope) is consumed; this destructor is a no-op for it.</p>

### ``=copy``

```nim
proc `=copy`[MT: static int; CC: static PinScopeCardinality](
    dest: var PinnedScope[MT, CC]; src: PinnedScope[MT, CC]) {.error.}
```

### ``=wasMoved``

```nim
proc `=wasMoved`[MT: static int; CC: static PinScopeCardinality](
    scope: var PinnedScope[MT, CC])
```

Mark the moved-from value as consumed so a re-entrant <tt class="docutils literal"><span class="pre"><span class="Operator">=</span><span class="Identifier">destroy</span></span></tt> is a no-op. Do NOT touch <tt class="docutils literal"><span class="pre"><span class="Identifier">scope</span><span class="Operator">.</span><span class="Identifier">state</span></span></tt>; the move source is unreachable by the type system, and the destination owns the underlying <tt class="docutils literal"><span class="pre"><span class="Identifier">Pinned</span></span></tt>.


## Macros

### `match`

```nim
macro match[MT: static int; CC: static PinScopeCardinality = ccSingle](
    value: PinnedScopeLifecycleStates[MT, CC]; arms: untyped): untyped
```

Single-target pattern match on states of typestate 'PinnedScopeLifecycle'; rewrites to <tt class="docutils literal"><span class="pre"><span class="Keyword">block</span><span class="Punctuation">:</span> <span class="Keyword">let</span> <span class="Keyword">bind</span> <span class="Operator">=</span> <span class="Identifier">move</span><span class="Punctuation">(</span><span class="Identifier">value</span><span class="Punctuation">)</span><span class="Punctuation">;</span> <span class="Identifier">body</span></span></tt>. Syntax is <tt class="docutils literal"><span class="pre"><span class="Operator">&lt;</span><span class="Identifier">StateName</span><span class="Operator">&gt;</span><span class="Punctuation">(</span><span class="Keyword">bind</span><span class="Punctuation">)</span><span class="Punctuation">:</span></span></tt>, with exactly one arm.

### `PinnedScopeLifecycle`

```nim
macro PinnedScopeLifecycle(initial`gensym0: untyped; typeDef`gensym0: untyped): untyped
```

Typestate-attachment pragma (auto-generated; see §3.7 of the v0.9.0 design doc). Apply to a type declaration to bind the type to this typestate with <tt class="docutils literal"><span class="pre"><span class="Identifier">initial</span></span></tt> as the starting state. Validates TA-002..TA-004 at compile time and populates <tt class="docutils literal"><span class="pre"><span class="Identifier">typestateAttachments</span></span></tt>.

