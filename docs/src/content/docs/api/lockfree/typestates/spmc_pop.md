---
title: "lockfree/typestates/spmc_pop"
description: "API reference for lockfree/typestates/spmc_pop"
---

<p>SPMC Pop operation lifecycle typestate (Vyukov per-slot sequence protocol).</p>
<p>State machine: Start -&gt; SlotClaimed | Empty | Start (3-arm: claim succeeded / generation empty / retry) SlotClaimed -&gt; T (terminal: read data + re-arm seq)</p>
<p>Multiple consumers race on <tt class="docutils literal"><span class="pre"><span class="Identifier">head</span></span></tt> — identical in shape to <tt class="docutils literal"><span class="pre"><span class="Identifier">mpmc_pop</span></span></tt>, only the facade name differs (SpmcBase vs MpmcBase).</p>
<p>Key invariant: Once a slot is claimed via CAS on <tt class="docutils literal"><span class="pre"><span class="Identifier">head</span></span></tt>, the data MUST be read and the per-slot <tt class="docutils literal"><span class="pre"><span class="Identifier">seq</span></span></tt> MUST be advanced to <tt class="docutils literal"><span class="pre"><span class="Identifier">pos</span> <span class="Operator">+</span> <span class="Identifier">N</span></span></tt> (release). That release is the consumer-&gt;next-generation-producer happens-before edge.</p>
<p>Memory ordering follows Vyukov canonical: <tt class="docutils literal"><span class="pre"><span class="Identifier">moRelaxed</span></span></tt> on the global <tt class="docutils literal"><span class="pre"><span class="Identifier">head</span></span></tt> CAS (the per-slot <tt class="docutils literal"><span class="pre"><span class="Identifier">seq</span></span></tt> does the data-ordering work), <tt class="docutils literal"><span class="pre"><span class="Identifier">moAcquire</span></span></tt> on the <tt class="docutils literal"><span class="pre"><span class="Identifier">seq</span></span></tt> load (pairs with producer's release at <tt class="docutils literal"><span class="pre"><span class="Identifier">pos</span> <span class="Operator">+</span> <span class="DecNumber">1</span></span></tt>), and <tt class="docutils literal"><span class="pre"><span class="Identifier">moRelease</span></span></tt> on the <tt class="docutils literal"><span class="pre"><span class="Identifier">seq</span></span></tt> store at <tt class="docutils literal"><span class="pre"><span class="Identifier">pos</span> <span class="Operator">+</span> <span class="Identifier">N</span></span></tt> (gates the next-generation producer).</p>
<p>Backoff: this verb returns the <tt class="docutils literal"><span class="pre"><span class="Identifier">Start</span></span></tt> arm to signal &quot;retry&quot;. The facade holds <tt class="docutils literal"><span class="pre"><span class="Keyword">var</span> <span class="Identifier">spins</span> <span class="Operator">=</span> <span class="Identifier">InitialSpin</span></span></tt> and calls <tt class="docutils literal"><span class="pre"><span class="Identifier">backoffOnRetry</span><span class="Punctuation">(</span><span class="Identifier">spins</span><span class="Punctuation">)</span></span></tt> between iterations on the Start arm. See design doc §6.</p>
<p>See design doc §2 (algorithm), §3 (bug walkthrough), §10.7 (recipe).</p>


## Types

### `SPMCPopStart`

```nim
SPMCPopStart[N] = object
```

Entry point. No data yet.

### `SPMCPopSlotClaimed`

```nim
SPMCPopSlotClaimed[N] = object
  pos*: uint64
  slot*: PhysicalSlotN[N]
```

CAS on <tt class="docutils literal"><span class="pre"><span class="Identifier">head</span></span></tt> succeeded - we own the slot at <tt class="docutils literal"><span class="pre"><span class="Identifier">pos</span> <span class="Keyword">mod</span> <span class="Identifier">N</span></span></tt>. MUST read data and publish the seq advance (re-arm for next gen).

### `SPMCPopEmpty`

```nim
SPMCPopEmpty[N] = object
```

Terminal: queue was empty this generation (per-slot seq lags).

### `SPMCPopOpState`

```nim
SPMCPopOpState = enum
  fsSPMCPopEmpty, fsSPMCPopSlotClaimed, fsSPMCPopStart
```

### `SPMCPopOpStates`

```nim
SPMCPopOpStates[N] = SPMCPopEmpty[N] | SPMCPopSlotClaimed[N] | SPMCPopStart[N]
```

### `SPMCPopClaimResultKind`

```nim
SPMCPopClaimResultKind = enum
  sSPMCPopSlotClaimed, sSPMCPopEmpty, sSPMCPopStart
```

### `SPMCPopClaimResult`

```nim
SPMCPopClaimResult[N] = object
  case kind*: SPMCPopClaimResultKind
  of sSPMCPopSlotClaimed:
    spmcpopslotclaimed*: SPMCPopSlotClaimed[N]
  of sSPMCPopEmpty:
    spmcpopempty*: SPMCPopEmpty[N]
  of sSPMCPopStart:
    spmcpopstart*: SPMCPopStart[N]
```

### `SpmcBase`

```nim
SpmcBase[N; C; T] = object
  head* {.align: 128.}: Atomic[uint64]
  tail* {.align: 128.}: Atomic[uint64]
  cells*: MPMCCellArrayN[N, SlotEncoding(T)]
```


## Procedures & Functions

### `state`

```nim
proc state[N: static int](f: SPMCPopEmpty[N]): SPMCPopOpState
```

Runtime state inspection for SPMCPopEmpty. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state[N: static int](f: SPMCPopSlotClaimed[N]): SPMCPopOpState
```

Runtime state inspection for SPMCPopSlotClaimed. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state[N: static int](f: SPMCPopStart[N]): SPMCPopOpState
```

Runtime state inspection for SPMCPopStart. Returns the enum value for pattern matching in case expressions.

### ``$``

```nim
proc `$`[N: static int](s: SPMCPopEmpty[N]): string
```

String representation for state 'SPMCPopEmpty'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`[N: static int](s: SPMCPopSlotClaimed[N]): string
```

String representation for state 'SPMCPopSlotClaimed'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`[N: static int](s: SPMCPopStart[N]): string
```

String representation for state 'SPMCPopStart'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`(s: SPMCPopOpState): string {.raises: [], tags: [], forbids: [].}
```

String representation of SPMCPopOpState enum. Strips the fs prefix for human-friendly output.

### `toSPMCPopClaimResult`

```nim
proc toSPMCPopClaimResult[N: static int](s: sink SPMCPopSlotClaimed[N]): SPMCPopClaimResult[
    N]
```

### `toSPMCPopClaimResult`

```nim
proc toSPMCPopClaimResult[N: static int](s: sink SPMCPopEmpty[N]): SPMCPopClaimResult[
    N]
```

### `toSPMCPopClaimResult`

```nim
proc toSPMCPopClaimResult[N: static int](s: sink SPMCPopStart[N]): SPMCPopClaimResult[
    N]
```

### ``$``

```nim
proc `$`[N: static int](r: SPMCPopClaimResult[N]): string
```

String representation of branching union 'SPMCPopClaimResult<a class="reference internal" href="#N">N</a>'. Returns the active branch's bare state name.

### `start`

```nim
proc start[N: static int](): SPMCPopStart[N] {.inline.}
```

Begin a pop operation.

### `tryClaim`

```nim
proc tryClaim[N, C: static int; T](op: SPMCPopStart[N];
                                   queue: var SpmcBase[N, C, T]): SPMCPopClaimResult[
    N] {.inline, raises: [], tags: [TypestateOp, RootEffect].}
```

Vyukov consumer claim. Returns one of:<ul class="simple"><li>SlotClaimed: head CAS won; caller must call <tt class="docutils literal"><span class="pre"><span class="Identifier">complete</span></span></tt>.</li>
<li>Empty: per-slot seq says producer hasn't written this generation yet. Caller returns false to user.</li>
<li>Start: CAS race or consumer raced ahead; caller backs off and retries.</li>
</ul>

### `complete`

```nim
proc complete[N, C: static int; T](op: SPMCPopSlotClaimed[N];
                                   queue: var SpmcBase[N, C, T]): T {.inline,
    notATransition.}
```

Read value from the claimed slot, then re-arm the seq for the next generation. The <tt class="docutils literal"><span class="pre"><span class="Identifier">seq</span><span class="Operator">.</span><span class="Identifier">store</span><span class="Punctuation">(</span><span class="Identifier">pos</span><span class="Operator">+</span><span class="Identifier">N</span><span class="Punctuation">,</span> <span class="Identifier">moRelease</span><span class="Punctuation">)</span></span></tt> is the consumer-&gt;next- producer edge; the next producer at virtual position <tt class="docutils literal"><span class="pre"><span class="Identifier">pos</span> <span class="Operator">+</span> <span class="Identifier">N</span></span></tt> will see this seq value via its acquire load and proceed to claim.


## Templates

### ``-&gt;``

```nim
template `->`[N: static int](_: typedesc[SPMCPopClaimResult[N]];
                             s: sink SPMCPopSlotClaimed[N]): SPMCPopClaimResult[
    N]
```

### ``-&gt;``

```nim
template `->`[N: static int](_: typedesc[SPMCPopClaimResult[N]];
                             s: sink SPMCPopEmpty[N]): SPMCPopClaimResult[N]
```

### ``-&gt;``

```nim
template `->`[N: static int](_: typedesc[SPMCPopClaimResult[N]];
                             s: sink SPMCPopStart[N]): SPMCPopClaimResult[N]
```


## Macros

### `match`

```nim
macro match[N: static int](value: SPMCPopClaimResult[N]; arms: untyped): untyped
```

Pattern-match on a branching union; rewrites into a <tt class="docutils literal"><span class="pre"><span class="Keyword">case</span></span></tt> over the kind discriminator. The value being matched must be a <tt class="docutils literal"><span class="pre"><span class="Keyword">var</span></span></tt> binding. Branch fields are extracted with <tt class="docutils literal"><span class="pre"><span class="Identifier">move</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt>, which requires a mutable binding. Syntax is <tt class="docutils literal"><span class="pre"><span class="Identifier">StateName</span><span class="Punctuation">(</span><span class="Keyword">bind</span><span class="Punctuation">)</span><span class="Punctuation">:</span></span></tt>, not <tt class="docutils literal"><span class="pre"><span class="Keyword">of</span> <span class="Identifier">StateName</span> <span class="Keyword">as</span> <span class="Keyword">bind</span><span class="Punctuation">:</span></span></tt>.

### `match`

```nim
macro match[N: static int](value: SPMCPopOpStates[N]; arms: untyped): untyped
```

Single-target pattern match on states of typestate 'SPMCPopOp'; rewrites to <tt class="docutils literal"><span class="pre"><span class="Keyword">block</span><span class="Punctuation">:</span> <span class="Keyword">let</span> <span class="Keyword">bind</span> <span class="Operator">=</span> <span class="Identifier">move</span><span class="Punctuation">(</span><span class="Identifier">value</span><span class="Punctuation">)</span><span class="Punctuation">;</span> <span class="Identifier">body</span></span></tt>. Syntax is <tt class="docutils literal"><span class="pre"><span class="Operator">&lt;</span><span class="Identifier">StateName</span><span class="Operator">&gt;</span><span class="Punctuation">(</span><span class="Keyword">bind</span><span class="Punctuation">)</span><span class="Punctuation">:</span></span></tt>, with exactly one arm.

### `SPMCPopOp`

```nim
macro SPMCPopOp(initial`gensym0: untyped; typeDef`gensym0: untyped): untyped
```

Typestate-attachment pragma (auto-generated; see §3.7 of the v0.9.0 design doc). Apply to a type declaration to bind the type to this typestate with <tt class="docutils literal"><span class="pre"><span class="Identifier">initial</span></span></tt> as the starting state. Validates TA-002..TA-004 at compile time and populates <tt class="docutils literal"><span class="pre"><span class="Identifier">typestateAttachments</span></span></tt>.

