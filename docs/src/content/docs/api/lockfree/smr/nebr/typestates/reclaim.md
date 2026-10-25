---
title: "lockfree/smr/nebr/typestates/reclaim"
description: "API reference for lockfree/smr/nebr/typestates/reclaim"
---

<p>Reclaim typestate for safe memory reclamation.</p>
<p>Walks the calling thread's limbo bags and reclaims objects retired before <tt class="docutils literal"><span class="pre"><span class="Identifier">safeEpoch</span></span></tt>. Each thread reclaims only its own retired objects; cross-thread reclamation is not supported because the limbo bag list is mutated by the owning thread (via <tt class="docutils literal"><span class="pre"><span class="Identifier">retire</span></span></tt>) without synchronization.</p>

<h2><a class="toc-backref" id="perminusthread-reclamation" href="#perminusthread-reclamation">Per-thread reclamation</a></h2><p><tt class="docutils literal"><span class="pre"><span class="Identifier">tryReclaim</span></span></tt> walks the calling thread's slot only. The slot is identified by the <tt class="docutils literal"><span class="pre"><span class="Identifier">ThreadHandle</span></span></tt> passed to <tt class="docutils literal"><span class="pre"><span class="Identifier">reclaimStart</span><span class="Punctuation">(</span><span class="Identifier">handle</span><span class="Punctuation">)</span></span></tt>, or by the thread-local <tt class="docutils literal"><span class="pre"><span class="Identifier">threadLocalIdx</span></span></tt> set during <tt class="docutils literal"><span class="pre"><span class="Identifier">registerThread</span></span></tt> for the legacy <tt class="docutils literal"><span class="pre"><span class="Identifier">reclaimStart</span><span class="Punctuation">(</span><span class="Keyword">addr</span> <span class="Identifier">manager</span><span class="Punctuation">)</span></span></tt> form.</p>
<p>A thread that retires but never calls <tt class="docutils literal"><span class="pre"><span class="Identifier">tryReclaim</span></span></tt> will accumulate limbo bags that no other thread can reclaim on its behalf. If such a thread stalls or exits without draining its bags, those objects are leaked. The <tt class="docutils literal"><span class="pre"><span class="Identifier">neutralizeStalled</span></span></tt> mechanism handles stalled-but-still-running threads (by forcing them to unpin so the global epoch can advance); it does not free their retired objects.</p>

<h2><a class="toc-backref" id="pitfalls" href="#pitfalls">Pitfalls</a></h2><ul class="simple"><li>The <tt class="docutils literal"><span class="pre"><span class="Identifier">ReclaimStart</span></span></tt> -&gt; <tt class="docutils literal"><span class="pre"><span class="Identifier">EpochsLoaded</span></span></tt> -&gt; <tt class="docutils literal"><span class="pre"><span class="Identifier">ReclaimReady</span></span></tt>/<tt class="docutils literal"><span class="pre"><span class="Identifier">ReclaimBlocked</span></span></tt> chain must be honored. <tt class="docutils literal"><span class="pre"><span class="Identifier">ReclaimBlocked</span></span></tt> means the global epoch has not advanced far enough for any retired object to be safe; this is normal, not an error. <tt class="docutils literal"><span class="pre"><span class="Identifier">manager</span><span class="Operator">.</span><span class="Identifier">advance</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt> increments the global epoch.</li>
<li>Reclamation does not require pinning. The walker only inspects per-thread epoch stamps. Calling reclaim from a worker that is currently <tt class="docutils literal"><span class="pre"><span class="Identifier">Pinned</span></span></tt> on the same manager is safe but will see its own thread as a constraint on <tt class="docutils literal"><span class="pre"><span class="Identifier">safeEpoch</span></span></tt>.</li>
<li><tt class="docutils literal"><span class="pre"><span class="Identifier">tryReclaim</span></span></tt> is <tt class="docutils literal"><span class="pre"><span class="Identifier">notATransition</span></span></tt> because <tt class="docutils literal"><span class="pre"><span class="Identifier">ReclaimReady</span></span></tt> is the terminal state of the <tt class="docutils literal"><span class="pre"><span class="Identifier">ReclaimContext</span></span></tt> typestate and the count return value is what the caller cares about.</li>
<li><tt class="docutils literal"><span class="pre"><span class="Identifier">reclaimStart</span><span class="Punctuation">(</span><span class="Keyword">addr</span> <span class="Identifier">manager</span><span class="Punctuation">)</span></span></tt> infers the slot from the thread-local <tt class="docutils literal"><span class="pre"><span class="Identifier">threadLocalRegistered</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">threadLocalIdx</span></span></tt> pair, additionally guarded by <tt class="docutils literal"><span class="pre"><span class="Identifier">threadLocalManager</span></span></tt> so a thread registered with manager A cannot accidentally walk manager B's slot list. If the calling thread has not been registered with <tt class="docutils literal"><span class="pre"><span class="Identifier">manager</span></span></tt>, the returned context carries <tt class="docutils literal"><span class="pre"><span class="Identifier">idx</span> <span class="Operator">=</span> <span class="Operator">-</span><span class="DecNumber">1</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">tryReclaim</span></span></tt> short-circuits to 0 reclaimed (rather than silently walking slot 0's bag list and racing with its owner). Prefer the handle form <tt class="docutils literal"><span class="pre"><span class="Identifier">reclaimStart</span><span class="Punctuation">(</span><span class="Identifier">handle</span><span class="Punctuation">)</span></span></tt> regardless: it is explicit and needs no thread-local lookup.</li>
</ul>

<h2><a class="toc-backref" id="see-also" href="#see-also">See also</a></h2><ul class="simple"><li><a class="reference internal" href="#debra">debra</a> - the one-shot wrapper.</li>
<li><a class="reference internal" href="#debra">debra</a> - puts objects into limbo bags.</li>
</ul>


## Types

### `ReclaimContext`

```nim
ReclaimContext[MaxThreads; CC] = object of RootObj
  manager*: ptr DebraManager[MaxThreads, CC]
  idx*: int                  ## Slot index of the calling thread; bag walk targets this slot only.
  globalEpoch*: uint64
  safeEpoch*: uint64
```

### `ReclaimStart`

```nim
ReclaimStart[MaxThreads; CC] = distinct ReclaimContext[MaxThreads, CC]
```

### `EpochsLoaded`

```nim
EpochsLoaded[MaxThreads; CC] = distinct ReclaimContext[MaxThreads, CC]
```

### `ReclaimReady`

```nim
ReclaimReady[MaxThreads; CC] = distinct ReclaimContext[MaxThreads, CC]
```

### `ReclaimBlocked`

```nim
ReclaimBlocked[MaxThreads; CC] = distinct ReclaimContext[MaxThreads, CC]
```

### `ReclaimContextState`

```nim
ReclaimContextState = enum
  fsReclaimStart, fsReclaimReady, fsEpochsLoaded, fsReclaimBlocked
```

### `ReclaimContextStates`

```nim
ReclaimContextStates[MaxThreads; CC] = ReclaimStart[MaxThreads, CC] |
    ReclaimReady[MaxThreads, CC] |
    EpochsLoaded[MaxThreads, CC] |
    ReclaimBlocked[MaxThreads, CC]
```

### `ReclaimCheckKind`

```nim
ReclaimCheckKind = enum
  rReclaimReady, rReclaimBlocked
```

### `ReclaimCheck`

```nim
ReclaimCheck[MaxThreads; CC] = object
  case kind*: ReclaimCheckKind
  of rReclaimReady:
    reclaimready*: ReclaimReady[MaxThreads, CC]
  of rReclaimBlocked:
    reclaimblocked*: ReclaimBlocked[MaxThreads, CC]
```


## Procedures & Functions

### `state`

```nim
proc state[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    f: ReclaimStart[MaxThreads, CC]): ReclaimContextState
```

Runtime state inspection for ReclaimStart. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    f: ReclaimReady[MaxThreads, CC]): ReclaimContextState
```

Runtime state inspection for ReclaimReady. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    f: EpochsLoaded[MaxThreads, CC]): ReclaimContextState
```

Runtime state inspection for EpochsLoaded. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    f: ReclaimBlocked[MaxThreads, CC]): ReclaimContextState
```

Runtime state inspection for ReclaimBlocked. Returns the enum value for pattern matching in case expressions.

### ``$``

```nim
proc `$`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    s: ReclaimStart[MaxThreads, CC]): string
```

String representation for state 'ReclaimStart'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    s: ReclaimReady[MaxThreads, CC]): string
```

String representation for state 'ReclaimReady'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    s: EpochsLoaded[MaxThreads, CC]): string
```

String representation for state 'EpochsLoaded'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    s: ReclaimBlocked[MaxThreads, CC]): string
```

String representation for state 'ReclaimBlocked'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`(s: ReclaimContextState): string {.raises: [], tags: [], forbids: [].}
```

String representation of ReclaimContextState enum. Strips the fs prefix for human-friendly output.

### ``=copy``

```nim
proc `=copy`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    dest: var ReclaimStart[MaxThreads, CC]; src: ReclaimStart[MaxThreads, CC]) {.error: "State \'ReclaimStart\' cannot be copied. Transitions consume the input state.".}
```

### ``=copy``

```nim
proc `=copy`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    dest: var ReclaimReady[MaxThreads, CC]; src: ReclaimReady[MaxThreads, CC]) {.error: "State \'ReclaimReady\' cannot be copied. Transitions consume the input state.".}
```

### ``=copy``

```nim
proc `=copy`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    dest: var EpochsLoaded[MaxThreads, CC]; src: EpochsLoaded[MaxThreads, CC]) {.error: "State \'EpochsLoaded\' cannot be copied. Transitions consume the input state.".}
```

### ``=copy``

```nim
proc `=copy`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    dest: var ReclaimBlocked[MaxThreads, CC];
    src: ReclaimBlocked[MaxThreads, CC]) {.error: "State \'ReclaimBlocked\' cannot be copied. Transitions consume the input state.".}
```

### `toReclaimCheck`

```nim
proc toReclaimCheck[MaxThreads: static int;
                    CC: static PinScopeCardinality = ccSingle](
    s: sink ReclaimReady[MaxThreads, CC]): ReclaimCheck[MaxThreads, CC]
```

### `toReclaimCheck`

```nim
proc toReclaimCheck[MaxThreads: static int;
                    CC: static PinScopeCardinality = ccSingle](
    s: sink ReclaimBlocked[MaxThreads, CC]): ReclaimCheck[MaxThreads, CC]
```

### ``$``

```nim
proc `$`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    r: ReclaimCheck[MaxThreads, CC]): string
```

String representation of branching union 'ReclaimCheck<a class="reference internal" href="#MaxThreads, CC">MaxThreads, CC</a>'. Returns the active branch's bare state name.

### `reclaimStart`

```nim
proc reclaimStart[MaxThreads: static int; CC: static PinScopeCardinality](
    handle: ThreadHandle[MaxThreads, CC]): ReclaimStart[MaxThreads, CC]
```

<p>Begin reclamation attempt for the calling thread's own retired objects.</p>
<p><tt class="docutils literal"><span class="pre"><span class="Identifier">handle</span></span></tt> identifies the slot whose limbo bag list will be walked. Pass the handle returned by <tt class="docutils literal"><span class="pre"><span class="Identifier">registerThread</span></span></tt> from the same thread that retired the objects. Each thread reclaims its own bags; this is the only safe pattern without per-list synchronization.</p>
<p>See also: <a class="reference internal" href="#debra">debra</a> for the one-shot wrapper.</p>

### `reclaimStart`

```nim
proc reclaimStart[MaxThreads: static int;
                  CC: static PinScopeCardinality = ccSingle](
    mgr: ptr DebraManager[MaxThreads, CC]): ReclaimStart[MaxThreads, CC]
```

<p>Legacy entry point that infers the calling thread's slot from the thread-local <tt class="docutils literal"><span class="pre"><span class="Identifier">threadLocalIdx</span></span></tt> set by <tt class="docutils literal"><span class="pre"><span class="Identifier">registerThread</span></span></tt>. Prefer the <tt class="docutils literal"><span class="pre"><span class="Identifier">reclaimStart</span><span class="Punctuation">(</span><span class="Identifier">handle</span><span class="Punctuation">)</span></span></tt> overload.</p>
<p>If the calling thread has not been registered with this (or any) manager, the returned context carries <tt class="docutils literal"><span class="pre"><span class="Identifier">idx</span> <span class="Operator">=</span> <span class="Operator">-</span><span class="DecNumber">1</span></span></tt>, so <tt class="docutils literal"><span class="pre"><span class="Identifier">tryReclaim</span></span></tt> short-circuits to 0 reclaimed instead of mutating slot 0's bag list (which would race with that slot's owner). <tt class="docutils literal"><span class="pre"><span class="Identifier">threadLocalIdx</span></span></tt> defaults to 0 and cannot by itself distinguish &quot;registered at slot 0&quot; from &quot;never registered&quot;; the companion <tt class="docutils literal"><span class="pre"><span class="Identifier">threadLocalRegistered</span></span></tt> flag is the explicit registered-bit.</p>
<p>In multi-manager scenarios <tt class="docutils literal"><span class="pre"><span class="Identifier">threadLocalIdx</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">threadLocalRegistered</span></span></tt> describe the slot the calling thread holds with whichever manager it last registered with. Calling <tt class="docutils literal"><span class="pre"><span class="Identifier">reclaimStart</span><span class="Punctuation">(</span><span class="Keyword">addr</span> <span class="Identifier">managerB</span><span class="Punctuation">)</span></span></tt> from a thread registered with <tt class="docutils literal"><span class="pre"><span class="Identifier">managerA</span></span></tt> would otherwise reuse A's slot index against B's bag list, racing with B's actual slot owner. The companion <tt class="docutils literal"><span class="pre"><span class="Identifier">threadLocalManager</span></span></tt> pointer is therefore compared by identity here: on mismatch the context is returned with <tt class="docutils literal"><span class="pre"><span class="Identifier">idx</span> <span class="Operator">=</span> <span class="Operator">-</span><span class="DecNumber">1</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">tryReclaim</span></span></tt> short-circuits to 0.</p>
<p>See also: <a class="reference internal" href="#debra">debra</a> for the one-shot wrapper.</p>

### `loadEpochs`

```nim
proc loadEpochs[MaxThreads: static int; CC: static PinScopeCardinality](
    s: sink ReclaimStart[MaxThreads, CC]): EpochsLoaded[MaxThreads, CC] {.
    raises: [], tags: [TypestateOp, RootEffect].}
```

<p>Load global epoch and compute minimum epoch across pinned threads.</p>
<p>Subscription read: an SC load of <tt class="docutils literal"><span class="pre"><span class="Identifier">globalEpoch</span></span></tt> participates in the C11 SC total order S, pairing with the SC RMW in <tt class="docutils literal"><span class="pre"><span class="Identifier">pin</span></span></tt> to give EBR its StoreLoad ordering across threads. Without this, a reclaimer can read another thread's <tt class="docutils literal"><span class="pre"><span class="Identifier">pinned</span><span class="Operator">=</span><span class="Identifier">false</span></span></tt> even when that thread's pin RMW has already been issued, then proceed to free an object the still-pinning thread is about to read. The SC load ensures that for every concurrently pinning thread T, either (a) T's pin RMW is visible here (we observe <tt class="docutils literal"><span class="pre"><span class="Identifier">pinned</span><span class="Operator">=</span><span class="Identifier">true</span></span></tt>), or (b) T's subsequent load of the protected pointer happens after our prior writes — so T cannot have observed a still-live pointer to an object we are about to free.</p>
<p>The SC RMW is issued against a stack-local <tt class="docutils literal"><span class="pre"><span class="Identifier">Atomic</span><span class="Punctuation">[</span><span class="Identifier">uint64</span><span class="Punctuation">]</span></span></tt>, NOT <tt class="docutils literal"><span class="pre"><span class="Identifier">manager</span><span class="Operator">.</span><span class="Identifier">globalEpoch</span></span></tt>: <tt class="docutils literal"><span class="pre"><span class="Identifier">globalEpoch</span></span></tt> is a hot shared cache line, and issuing the RMW there bounces it across cores on every reclaimer-side subscription. The subscription handshake requires three properties to be correct under TSAN:</p>
<ol class="simple"><li><strong>Hardware StoreLoad barrier.</strong> A plain SC load is too weak — on x86 it lowers to a bare <tt class="docutils literal"><span class="pre"><span class="Identifier">mov</span></span></tt> and loses the <tt class="docutils literal"><span class="pre"><span class="Identifier">mfence</span></span></tt> that an SC fence would provide. An SC RMW lowers to a <tt class="docutils literal"><span class="pre"><span class="Identifier">lock</span></span></tt>-prefixed instruction on x86 and an <tt class="docutils literal"><span class="pre"><span class="Identifier">ldaxr</span></span></tt>/<tt class="docutils literal"><span class="pre"><span class="Identifier">stlxr</span></span></tt> seq-cst loop on ARM, both of which are full StoreLoad barriers.</li>
<li><strong>Participation in C11's SC total order S.</strong> The SC loads on each thread's <tt class="docutils literal"><span class="pre"><span class="Identifier">pinned</span></span></tt> flag (below) are in S. For the proof of EBR safety to go through, the subscription point itself must be in S so that pin RMWs published before our subscription are visible. C11 §29.3 makes S a single total order across <strong>every</strong> SC op, regardless of which atomic location it touches.</li>
<li><strong>TSAN vector-clock modelling.</strong> Standalone SC fences are not modelled by TSAN (see <tt class="docutils literal"><span class="pre"><span class="Identifier">compiler</span><span class="Operator">-</span><span class="Identifier">rt</span><span class="Operator">/</span><span class="Identifier">lib</span><span class="Operator">/</span><span class="Identifier">tsan</span><span class="Operator">/</span><span class="Identifier">rtl</span><span class="Operator">/</span></span></tt> <tt class="docutils literal"><span class="pre"><span class="Identifier">tsan_interface_atomic</span><span class="Operator">.</span><span class="Identifier">cpp</span></span></tt> <tt class="docutils literal"><span class="pre"><span class="Identifier">OpFence</span><span class="Punctuation">:</span><span class="Punctuation">:</span><span class="Identifier">Atomic</span></span></tt> -&gt; <tt class="docutils literal"><span class="pre"><span class="Operator">//</span> <span class="Identifier">FIXME</span><span class="Punctuation">:</span> <span class="Keyword">not</span> <span class="Identifier">implemented</span><span class="Operator">.</span></span></tt>). SC RMWs are modelled correctly on every atomic location, so the analyser sees the synchronisation.</li>
</ol>
<p>Properties (1) and (3) are properties of the <em>instruction</em>, not the operand location; property (2) is location-independent by C11 construction. So a stack-local <tt class="docutils literal"><span class="pre"><span class="Identifier">Atomic</span><span class="Punctuation">[</span><span class="Identifier">uint64</span><span class="Punctuation">]</span></span></tt> gives us the same subscription point with no cross-thread cache traffic.</p>

### `safeEpoch`

```nim
func safeEpoch[MaxThreads: static int; CC: static PinScopeCardinality](
    e: EpochsLoaded[MaxThreads, CC]): uint64 {.notATransition.}
```

### `checkSafe`

```nim
proc checkSafe[MaxThreads: static int; CC: static PinScopeCardinality](
    e: sink EpochsLoaded[MaxThreads, CC]): ReclaimCheck[MaxThreads, CC] {.
    raises: [], tags: [TypestateOp, RootEffect].}
```

Check if any epochs are safe to reclaim.

### `tryReclaim`

```nim
proc tryReclaim[MaxThreads: static int; CC: static PinScopeCardinality](
    r: ReclaimReady[MaxThreads, CC]): int {.notATransition.}
```

<p>Reclaim eligible objects from the calling thread's own limbo bag list.</p>
<p>Returns the count of objects reclaimed. Walks only <tt class="docutils literal"><span class="pre"><span class="Identifier">manager</span><span class="Operator">.</span><span class="Identifier">threads</span><span class="Punctuation">[</span><span class="Identifier">idx</span><span class="Punctuation">]</span></span></tt> where <tt class="docutils literal"><span class="pre"><span class="Identifier">idx</span></span></tt> was captured into the <tt class="docutils literal"><span class="pre"><span class="Identifier">ReclaimContext</span></span></tt> by <tt class="docutils literal"><span class="pre"><span class="Identifier">reclaimStart</span></span></tt>. Other threads' bags are untouched: they reclaim their own.</p>
<p>Cross-thread reclamation would race with the owner thread's <tt class="docutils literal"><span class="pre"><span class="Identifier">retire</span></span></tt> mutations on <tt class="docutils literal"><span class="pre"><span class="Identifier">currentBag</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">limboBagTail</span></span></tt>; those fields have no synchronization and are owned by the registered thread.</p>


## Templates

### ``-&gt;``

```nim
template `->`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    _: typedesc[ReclaimCheck[MaxThreads, CC]];
    s: sink ReclaimReady[MaxThreads, CC]): ReclaimCheck[MaxThreads, CC]
```

### ``-&gt;``

```nim
template `->`[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    _: typedesc[ReclaimCheck[MaxThreads, CC]];
    s: sink ReclaimBlocked[MaxThreads, CC]): ReclaimCheck[MaxThreads, CC]
```


## Macros

### `match`

```nim
macro match[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    value: ReclaimCheck[MaxThreads, CC]; arms: untyped): untyped
```

Pattern-match on a branching union; rewrites into a <tt class="docutils literal"><span class="pre"><span class="Keyword">case</span></span></tt> over the kind discriminator. The value being matched must be a <tt class="docutils literal"><span class="pre"><span class="Keyword">var</span></span></tt> binding. Branch fields are extracted with <tt class="docutils literal"><span class="pre"><span class="Identifier">move</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt>, which requires a mutable binding. Syntax is <tt class="docutils literal"><span class="pre"><span class="Identifier">StateName</span><span class="Punctuation">(</span><span class="Keyword">bind</span><span class="Punctuation">)</span><span class="Punctuation">:</span></span></tt>, not <tt class="docutils literal"><span class="pre"><span class="Keyword">of</span> <span class="Identifier">StateName</span> <span class="Keyword">as</span> <span class="Keyword">bind</span><span class="Punctuation">:</span></span></tt>.

### `match`

```nim
macro match[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    value: ReclaimContextStates[MaxThreads, CC]; arms: untyped): untyped
```

Single-target pattern match on states of typestate 'ReclaimContext'; rewrites to <tt class="docutils literal"><span class="pre"><span class="Keyword">block</span><span class="Punctuation">:</span> <span class="Keyword">let</span> <span class="Keyword">bind</span> <span class="Operator">=</span> <span class="Identifier">move</span><span class="Punctuation">(</span><span class="Identifier">value</span><span class="Punctuation">)</span><span class="Punctuation">;</span> <span class="Identifier">body</span></span></tt>. Syntax is <tt class="docutils literal"><span class="pre"><span class="Operator">&lt;</span><span class="Identifier">StateName</span><span class="Operator">&gt;</span><span class="Punctuation">(</span><span class="Keyword">bind</span><span class="Punctuation">)</span><span class="Punctuation">:</span></span></tt>, with exactly one arm.

