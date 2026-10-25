---
title: "lockfree/typestates/mpsc_pop"
description: "API reference for lockfree/typestates/mpsc_pop"
---

<p>MPSC Pop operation lifecycle typestate (Vyukov per-slot sequence protocol).</p>
<p>State machine: Start -&gt; SlotClaimed | Empty | Start (3-arm: claim succeeded / generation empty / retry) SlotClaimed -&gt; T (terminal: read data + re-arm seq)</p>
<p>Key invariant: Once a slot is claimed via CAS on <tt class="docutils literal"><span class="pre"><span class="Identifier">head</span></span></tt>, the data MUST be read and the per-slot <tt class="docutils literal"><span class="pre"><span class="Identifier">seq</span></span></tt> MUST be advanced to <tt class="docutils literal"><span class="pre"><span class="Identifier">pos</span> <span class="Operator">+</span> <span class="Identifier">N</span></span></tt> (release). That release is the consumer-&gt;next-generation-producer happens-before edge.</p>
<p>Single-consumer by <em>contract</em>, but Nim's <tt class="docutils literal"><span class="pre"><span class="Identifier">Mpsc</span></span></tt> facade does NOT enforce single-thread access. We keep <tt class="docutils literal"><span class="pre"><span class="Identifier">compareExchangeWeak</span></span></tt> on <tt class="docutils literal"><span class="pre"><span class="Identifier">head</span></span></tt> even on the single-consumer side as defense in depth: an accidental two-thread mis-use surfaces as a benign retry rather than silent data corruption.</p>
<p>Memory ordering follows Vyukov canonical: <tt class="docutils literal"><span class="pre"><span class="Identifier">moRelaxed</span></span></tt> on the global <tt class="docutils literal"><span class="pre"><span class="Identifier">head</span></span></tt> CAS (the per-slot <tt class="docutils literal"><span class="pre"><span class="Identifier">seq</span></span></tt> does the data-ordering work), <tt class="docutils literal"><span class="pre"><span class="Identifier">moAcquire</span></span></tt> on the <tt class="docutils literal"><span class="pre"><span class="Identifier">seq</span></span></tt> load (pairs with producer's release at <tt class="docutils literal"><span class="pre"><span class="Identifier">pos</span> <span class="Operator">+</span> <span class="DecNumber">1</span></span></tt>), and <tt class="docutils literal"><span class="pre"><span class="Identifier">moRelease</span></span></tt> on the <tt class="docutils literal"><span class="pre"><span class="Identifier">seq</span></span></tt> store at <tt class="docutils literal"><span class="pre"><span class="Identifier">pos</span> <span class="Operator">+</span> <span class="Identifier">N</span></span></tt> (gates the next-generation producer).</p>
<p>Backoff: this verb returns the <tt class="docutils literal"><span class="pre"><span class="Identifier">Start</span></span></tt> arm to signal &quot;retry&quot;. The facade holds <tt class="docutils literal"><span class="pre"><span class="Keyword">var</span> <span class="Identifier">spins</span> <span class="Operator">=</span> <span class="Identifier">InitialSpin</span></span></tt> and calls <tt class="docutils literal"><span class="pre"><span class="Identifier">backoffOnRetry</span><span class="Punctuation">(</span><span class="Identifier">spins</span><span class="Punctuation">)</span></span></tt> between iterations on the Start arm.</p>


## Types

### `MPSCPopStart`

```nim
MPSCPopStart[N] = object
```

Entry point. No data yet.

### `MPSCPopSlotClaimed`

```nim
MPSCPopSlotClaimed[N] = object
  pos*: uint64
  slot*: PhysicalSlotN[N]
```

CAS on <tt class="docutils literal"><span class="pre"><span class="Identifier">head</span></span></tt> succeeded - we own the slot at <tt class="docutils literal"><span class="pre"><span class="Identifier">pos</span> <span class="Keyword">mod</span> <span class="Identifier">N</span></span></tt>. MUST read data and publish the seq advance (re-arm for next gen).

### `MPSCPopEmpty`

```nim
MPSCPopEmpty[N] = object
```

Terminal: queue was empty this generation (per-slot seq lags).

### `MPSCPopOpState`

```nim
MPSCPopOpState = enum
  fsMPSCPopSlotClaimed, fsMPSCPopEmpty, fsMPSCPopStart
```

### `MPSCPopOpStates`

```nim
MPSCPopOpStates[N] = MPSCPopSlotClaimed[N] | MPSCPopEmpty[N] | MPSCPopStart[N]
```

### `MPSCPopClaimResultKind`

```nim
MPSCPopClaimResultKind = enum
  mMPSCPopSlotClaimed, mMPSCPopEmpty, mMPSCPopStart
```

### `MPSCPopClaimResult`

```nim
MPSCPopClaimResult[N] = object
  case kind*: MPSCPopClaimResultKind
  of mMPSCPopSlotClaimed:
    mpscpopslotclaimed*: MPSCPopSlotClaimed[N]
  of mMPSCPopEmpty:
    mpscpopempty*: MPSCPopEmpty[N]
  of mMPSCPopStart:
    mpscpopstart*: MPSCPopStart[N]
```

### `MpscBase`

```nim
MpscBase[N; P; T] = object
  head* {.align: 128.}: Atomic[uint64]
  tail* {.align: 128.}: Atomic[uint64]
  cells*: MPMCCellArrayN[N, SlotEncoding(T)]
```


## Procedures & Functions

### `state`

```nim
proc state[N: static int](f: MPSCPopSlotClaimed[N]): MPSCPopOpState
```

Runtime state inspection for MPSCPopSlotClaimed. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state[N: static int](f: MPSCPopEmpty[N]): MPSCPopOpState
```

Runtime state inspection for MPSCPopEmpty. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state[N: static int](f: MPSCPopStart[N]): MPSCPopOpState
```

Runtime state inspection for MPSCPopStart. Returns the enum value for pattern matching in case expressions.

### ``$``

```nim
proc `$`[N: static int](s: MPSCPopSlotClaimed[N]): string
```

String representation for state 'MPSCPopSlotClaimed'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`[N: static int](s: MPSCPopEmpty[N]): string
```

String representation for state 'MPSCPopEmpty'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`[N: static int](s: MPSCPopStart[N]): string
```

String representation for state 'MPSCPopStart'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`(s: MPSCPopOpState): string {.raises: [], tags: [], forbids: [].}
```

String representation of MPSCPopOpState enum. Strips the fs prefix for human-friendly output.

### `toMPSCPopClaimResult`

```nim
proc toMPSCPopClaimResult[N: static int](s: sink MPSCPopSlotClaimed[N]): MPSCPopClaimResult[
    N]
```

### `toMPSCPopClaimResult`

```nim
proc toMPSCPopClaimResult[N: static int](s: sink MPSCPopEmpty[N]): MPSCPopClaimResult[
    N]
```

### `toMPSCPopClaimResult`

```nim
proc toMPSCPopClaimResult[N: static int](s: sink MPSCPopStart[N]): MPSCPopClaimResult[
    N]
```

### ``$``

```nim
proc `$`[N: static int](r: MPSCPopClaimResult[N]): string
```

String representation of branching union 'MPSCPopClaimResult<a class="reference internal" href="#N">N</a>'. Returns the active branch's bare state name.

### `start`

```nim
proc start[N: static int](): MPSCPopStart[N] {.inline.}
```

Begin a pop operation.

### `tryClaim`

```nim
proc tryClaim[N, P: static int; T](op: MPSCPopStart[N];
                                   queue: var MpscBase[N, P, T]): MPSCPopClaimResult[
    N] {.inline, raises: [], tags: [TypestateOp, RootEffect].}
```

Vyukov consumer claim. Returns one of:<ul class="simple"><li>SlotClaimed: head CAS won; caller must call <tt class="docutils literal"><span class="pre"><span class="Identifier">complete</span></span></tt>.</li>
<li>Empty: per-slot seq says producer hasn't written this generation yet. Caller returns false to user.</li>
<li>Start: CAS race or mis-use detected; caller backs off and retries.</li>
</ul>

### `complete`

```nim
proc complete[N, P: static int; T](op: MPSCPopSlotClaimed[N];
                                   queue: var MpscBase[N, P, T]): T {.inline,
    notATransition.}
```

Read value from the claimed slot, then re-arm the seq for the next generation. The <tt class="docutils literal"><span class="pre"><span class="Identifier">seq</span><span class="Operator">.</span><span class="Identifier">store</span><span class="Punctuation">(</span><span class="Identifier">pos</span><span class="Operator">+</span><span class="Identifier">N</span><span class="Punctuation">,</span> <span class="Identifier">moRelease</span><span class="Punctuation">)</span></span></tt> is the consumer-&gt;next- producer edge; the next producer at virtual position <tt class="docutils literal"><span class="pre"><span class="Identifier">pos</span> <span class="Operator">+</span> <span class="Identifier">N</span></span></tt> will see this seq value via its acquire load and proceed to claim.


## Templates

### ``-&gt;``

```nim
template `->`[N: static int](_: typedesc[MPSCPopClaimResult[N]];
                             s: sink MPSCPopSlotClaimed[N]): MPSCPopClaimResult[
    N]
```

### ``-&gt;``

```nim
template `->`[N: static int](_: typedesc[MPSCPopClaimResult[N]];
                             s: sink MPSCPopEmpty[N]): MPSCPopClaimResult[N]
```

### ``-&gt;``

```nim
template `->`[N: static int](_: typedesc[MPSCPopClaimResult[N]];
                             s: sink MPSCPopStart[N]): MPSCPopClaimResult[N]
```


## Macros

### `match`

```nim
macro match[N: static int](value: MPSCPopClaimResult[N]; arms: untyped): untyped
```

Pattern-match on a branching union; rewrites into a <tt class="docutils literal"><span class="pre"><span class="Keyword">case</span></span></tt> over the kind discriminator. The value being matched must be a <tt class="docutils literal"><span class="pre"><span class="Keyword">var</span></span></tt> binding. Branch fields are extracted with <tt class="docutils literal"><span class="pre"><span class="Identifier">move</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt>, which requires a mutable binding. Syntax is <tt class="docutils literal"><span class="pre"><span class="Identifier">StateName</span><span class="Punctuation">(</span><span class="Keyword">bind</span><span class="Punctuation">)</span><span class="Punctuation">:</span></span></tt>, not <tt class="docutils literal"><span class="pre"><span class="Keyword">of</span> <span class="Identifier">StateName</span> <span class="Keyword">as</span> <span class="Keyword">bind</span><span class="Punctuation">:</span></span></tt>.

### `match`

```nim
macro match[N: static int](value: MPSCPopOpStates[N]; arms: untyped): untyped
```

Single-target pattern match on states of typestate 'MPSCPopOp'; rewrites to <tt class="docutils literal"><span class="pre"><span class="Keyword">block</span><span class="Punctuation">:</span> <span class="Keyword">let</span> <span class="Keyword">bind</span> <span class="Operator">=</span> <span class="Identifier">move</span><span class="Punctuation">(</span><span class="Identifier">value</span><span class="Punctuation">)</span><span class="Punctuation">;</span> <span class="Identifier">body</span></span></tt>. Syntax is <tt class="docutils literal"><span class="pre"><span class="Operator">&lt;</span><span class="Identifier">StateName</span><span class="Operator">&gt;</span><span class="Punctuation">(</span><span class="Keyword">bind</span><span class="Punctuation">)</span><span class="Punctuation">:</span></span></tt>, with exactly one arm.

### `MPSCPopOp`

```nim
macro MPSCPopOp(initial`gensym0: untyped; typeDef`gensym0: untyped): untyped
```

Typestate-attachment pragma (auto-generated; see §3.7 of the v0.9.0 design doc). Apply to a type declaration to bind the type to this typestate with <tt class="docutils literal"><span class="pre"><span class="Identifier">initial</span></span></tt> as the starting state. Validates TA-002..TA-004 at compile time and populates <tt class="docutils literal"><span class="pre"><span class="Identifier">typestateAttachments</span></span></tt>.

