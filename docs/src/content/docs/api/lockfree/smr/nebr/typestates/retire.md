---
title: "lockfree/smr/nebr/typestates/retire"
description: "API reference for lockfree/smr/nebr/typestates/retire"
---

<p>Retire typestate for adding objects to limbo bags.</p>
<p>Must be pinned to retire objects.</p>

<h2><a class="toc-backref" id="pitfalls" href="#pitfalls">Pitfalls</a></h2><ul class="simple"><li><tt class="docutils literal"><span class="pre"><span class="Identifier">retire</span></span></tt> is sink-form: it consumes <tt class="docutils literal"><span class="pre"><span class="Identifier">RetireReady</span><span class="Punctuation">[</span><span class="Identifier">MT</span><span class="Punctuation">]</span></span></tt> and returns <tt class="docutils literal"><span class="pre"><span class="Identifier">Retired</span><span class="Punctuation">[</span><span class="Identifier">MT</span><span class="Punctuation">]</span></span></tt>. To retire multiple objects in the same pinned epoch, convert back with <tt class="docutils literal"><span class="pre"><span class="Identifier">retireReadyFromRetired</span></span></tt>. The <tt class="docutils literal"><span class="pre"><span class="Keyword">var</span></span></tt>-form wrappers in <tt class="docutils literal"><span class="pre"><span class="Identifier">debra</span><span class="Operator">/</span><span class="Identifier">convenience</span></span></tt> (<tt class="docutils literal"><span class="pre"><span class="Identifier">retire</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">retireBatch</span></span></tt>) handle this for you.</li>
<li>The pointer/destructor pair handed to <tt class="docutils literal"><span class="pre"><span class="Identifier">retire</span><span class="Punctuation">(</span><span class="Identifier">p</span><span class="Punctuation">,</span> <span class="Identifier">dtor</span><span class="Punctuation">)</span></span></tt> is captured into the limbo bag immediately. The destructor closure must remain valid until reclamation runs (<tt class="docutils literal"><span class="pre"><span class="Identifier">Destructor</span></span></tt> is a <tt class="docutils literal"><span class="pre"><span class="Identifier">nimcall</span></span></tt> proc, so a top-level proc or <tt class="docutils literal"><span class="pre"><span class="Identifier">releaseDestructor</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt> result is fine).</li>
<li>Retiring the same pointer twice from different threads (or the same thread across multiple <tt class="docutils literal"><span class="pre"><span class="Identifier">pin</span></span></tt> cycles) double-frees on reclamation. The library does not deduplicate.</li>
</ul>

<h2><a class="toc-backref" id="see-also" href="#see-also">See also</a></h2><ul class="simple"><li><a class="reference internal" href="#debra">debra</a> + <tt class="docutils literal"><span class="pre"><span class="Identifier">scope</span><span class="Operator">.</span><span class="Identifier">retireOnCAS</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">scope</span><span class="Operator">.</span><span class="Identifier">retireOnPublish</span></span></tt> (or <tt class="docutils literal"><span class="pre"><span class="Identifier">retireReady</span><span class="Punctuation">(</span><span class="Identifier">scope</span><span class="Operator">.</span><span class="Identifier">state</span><span class="Punctuation">)</span><span class="Operator">.</span><span class="Identifier">retire</span><span class="Punctuation">(</span><span class="Operator">...</span><span class="Punctuation">)</span></span></tt>) - the recommended path.</li>
<li><a class="reference internal" href="#debra">debra</a> - eventual reclamation after epoch safety.</li>
</ul>


## Types

### `RetireContext`

```nim
RetireContext[MaxThreads; CC] = object of RootObj
  handle*: ThreadHandle[MaxThreads, CC]
  epoch*: uint64
```

### `RetireReady`

```nim
RetireReady[MaxThreads; CC] = distinct RetireContext[MaxThreads, CC]
```

### `Retired`

```nim
Retired[MaxThreads; CC] = distinct RetireContext[MaxThreads, CC]
```

### `RetireContextState`

```nim
RetireContextState = enum
  fsRetireReady, fsRetired
```

### `RetireContextStates`

```nim
RetireContextStates[MaxThreads; CC] = RetireReady[MaxThreads, CC] |
    Retired[MaxThreads, CC]
```


## Procedures & Functions

### `state`

```nim
proc state[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    f: RetireReady[MaxThreads, CC]): RetireContextState
```

Runtime state inspection for RetireReady. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    f: Retired[MaxThreads, CC]): RetireContextState
```

Runtime state inspection for Retired. Returns the enum value for pattern matching in case expressions.

### ``$``

```nim
proc `$`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    s: RetireReady[MaxThreads, CC]): string
```

String representation for state 'RetireReady'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    s: Retired[MaxThreads, CC]): string
```

String representation for state 'Retired'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`(s: RetireContextState): string {.raises: [], tags: [], forbids: [].}
```

String representation of RetireContextState enum. Strips the fs prefix for human-friendly output.

### ``=copy``

```nim
proc `=copy`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    dest: var RetireReady[MaxThreads, CC]; src: RetireReady[MaxThreads, CC]) {.error: "State \'RetireReady\' cannot be copied. Transitions consume the input state.".}
```

### ``=copy``

```nim
proc `=copy`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    dest: var Retired[MaxThreads, CC]; src: Retired[MaxThreads, CC]) {.error: "State \'Retired\' cannot be copied. Transitions consume the input state.".}
```

### `retireReady`

```nim
proc retireReady[MaxThreads: static int; CC: static PinScopeCardinality](
    p: Pinned[MaxThreads, CC]): RetireReady[MaxThreads, CC]
```

Create retire context from pinned state.

### `retireReadyFromRetired`

```nim
proc retireReadyFromRetired[MaxThreads: static int;
                            CC: static PinScopeCardinality](
    r: sink Retired[MaxThreads, CC]): RetireReady[MaxThreads, CC] {.
    notATransition.}
```

Get back to RetireReady after retiring (for multiple retires).

### `pinnedFromRetired`

```nim
proc pinnedFromRetired[MaxThreads: static int; CC: static PinScopeCardinality](
    r: sink Retired[MaxThreads, CC]): Pinned[MaxThreads, CC] {.notATransition.}
```

<p>Return a <tt class="docutils literal"><span class="pre"><span class="Identifier">Pinned</span><span class="Punctuation">[</span><span class="Identifier">MaxThreads</span><span class="Punctuation">,</span> <span class="Identifier">CC</span><span class="Punctuation">]</span></span></tt> reconstructed from a <tt class="docutils literal"><span class="pre"><span class="Identifier">Retired</span><span class="Punctuation">[</span><span class="Identifier">MaxThreads</span><span class="Punctuation">,</span> <span class="Identifier">CC</span><span class="Punctuation">]</span></span></tt> value, allowing the caller to keep working in the same pinned epoch (e.g. interleaving reads with further retires) instead of unpinning immediately after a retire.</p>
<p>Symmetric to <tt class="docutils literal"><span class="pre"><span class="Identifier">retireReadyFromRetired</span></span></tt>: same underlying <tt class="docutils literal"><span class="pre"><span class="Identifier">RetireContext</span><span class="Punctuation">[</span><span class="Identifier">MaxThreads</span><span class="Punctuation">,</span> <span class="Identifier">CC</span><span class="Punctuation">]</span></span></tt>, projected to the <tt class="docutils literal"><span class="pre"><span class="Identifier">Pinned</span></span></tt> typestate via the <tt class="docutils literal"><span class="pre"><span class="Identifier">EpochGuardContext</span><span class="Punctuation">[</span><span class="Identifier">MaxThreads</span><span class="Punctuation">,</span> <span class="Identifier">CC</span><span class="Punctuation">]</span></span></tt> shape (handle + epoch). The slot's <tt class="docutils literal"><span class="pre"><span class="Identifier">pinned</span></span></tt> flag is unchanged; this is a typestate rebrand, not a re-pin.</p>
<p>See also: <a class="reference internal" href="#retireReadyFromRetired">retireReadyFromRetired</a>, <a class="reference internal" href="#retire">retire</a>, <a class="reference internal" href="#debra">debra</a>.</p>

### `retire`

```nim
proc retire[MaxThreads: static int; CC: static PinScopeCardinality](
    r: sink RetireReady[MaxThreads, CC]; p: pointer; destructor: Destructor): Retired[
    MaxThreads, CC] {.raises: [], tags: [TypestateOp, RootEffect].}
```

<p>Retire a raw pointer for epoch-based reclamation.</p>
<p>The destructor will be called when the epoch becomes safe. Use for manually-managed memory (ptr types, alloc/dealloc, etc.)</p>

### `handle`

```nim
func handle[MaxThreads: static int; CC: static PinScopeCardinality](
    r: RetireReady[MaxThreads, CC]): ThreadHandle[MaxThreads, CC] {.
    notATransition.}
```


## Macros

### `match`

```nim
macro match[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    value: RetireContextStates[MaxThreads, CC]; arms: untyped): untyped
```

Single-target pattern match on states of typestate 'RetireContext'; rewrites to <tt class="docutils literal"><span class="pre"><span class="Keyword">block</span><span class="Punctuation">:</span> <span class="Keyword">let</span> <span class="Keyword">bind</span> <span class="Operator">=</span> <span class="Identifier">move</span><span class="Punctuation">(</span><span class="Identifier">value</span><span class="Punctuation">)</span><span class="Punctuation">;</span> <span class="Identifier">body</span></span></tt>. Syntax is <tt class="docutils literal"><span class="pre"><span class="Operator">&lt;</span><span class="Identifier">StateName</span><span class="Operator">&gt;</span><span class="Punctuation">(</span><span class="Keyword">bind</span><span class="Punctuation">)</span><span class="Punctuation">:</span></span></tt>, with exactly one arm.

