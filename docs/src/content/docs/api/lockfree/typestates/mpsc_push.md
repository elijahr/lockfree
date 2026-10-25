---
title: "lockfree/typestates/mpsc_push"
description: "API reference for lockfree/typestates/mpsc_push"
---

<p>MPSC Push operation lifecycle typestate (Vyukov per-slot sequence protocol).</p>
<p>State machine: Start -&gt; SlotClaimed | Full | Start (3-arm: claim succeeded / generation full / retry) SlotClaimed -&gt; bool (terminal: write data + publish seq)</p>
<p>Multiple producers race on <tt class="docutils literal"><span class="pre"><span class="Identifier">tail</span></span></tt> — identical in shape to <tt class="docutils literal"><span class="pre"><span class="Identifier">mpmc_push</span></span></tt>, only the facade name differs (MpscPushBase vs MpmcPushBase).</p>
<p>Key invariant: Once a slot is claimed via CAS on <tt class="docutils literal"><span class="pre"><span class="Identifier">tail</span></span></tt>, data MUST be written and the per-slot <tt class="docutils literal"><span class="pre"><span class="Identifier">seq</span></span></tt> MUST be advanced to <tt class="docutils literal"><span class="pre"><span class="Identifier">pos</span> <span class="Operator">+</span> <span class="DecNumber">1</span></span></tt> (release). That release is the producer-&gt;consumer happens-before edge.</p>
<p>Memory ordering follows Vyukov canonical: <tt class="docutils literal"><span class="pre"><span class="Identifier">moRelaxed</span></span></tt> on the global <tt class="docutils literal"><span class="pre"><span class="Identifier">tail</span></span></tt> CAS (the per-slot <tt class="docutils literal"><span class="pre"><span class="Identifier">seq</span></span></tt> does the data-ordering work), <tt class="docutils literal"><span class="pre"><span class="Identifier">moAcquire</span></span></tt> on the <tt class="docutils literal"><span class="pre"><span class="Identifier">seq</span></span></tt> load (pairs with consumer's release at <tt class="docutils literal"><span class="pre"><span class="Identifier">pos</span> <span class="Operator">+</span> <span class="Identifier">N</span></span></tt>), and <tt class="docutils literal"><span class="pre"><span class="Identifier">moRelease</span></span></tt> on the <tt class="docutils literal"><span class="pre"><span class="Identifier">seq</span></span></tt> store at <tt class="docutils literal"><span class="pre"><span class="Identifier">pos</span> <span class="Operator">+</span> <span class="DecNumber">1</span></span></tt> (gates the matching consumer).</p>
<p>Backoff: this verb returns the <tt class="docutils literal"><span class="pre"><span class="Identifier">Start</span></span></tt> arm to signal &quot;retry&quot;. The facade holds <tt class="docutils literal"><span class="pre"><span class="Keyword">var</span> <span class="Identifier">spins</span> <span class="Operator">=</span> <span class="Identifier">InitialSpin</span></span></tt> and calls <tt class="docutils literal"><span class="pre"><span class="Identifier">backoffOnRetry</span><span class="Punctuation">(</span><span class="Identifier">spins</span><span class="Punctuation">)</span></span></tt> between iterations on the Start arm.</p>


## Types

### `MPSCPushStart`

```nim
MPSCPushStart[N] = object
```

Entry point. No data yet.

### `MPSCPushSlotClaimed`

```nim
MPSCPushSlotClaimed[N] = object
  pos*: uint64
  slot*: PhysicalSlotN[N]
```

CAS on <tt class="docutils literal"><span class="pre"><span class="Identifier">tail</span></span></tt> succeeded - we own the slot at <tt class="docutils literal"><span class="pre"><span class="Identifier">pos</span> <span class="Keyword">mod</span> <span class="Identifier">N</span></span></tt>. MUST write data and publish the seq advance.

### `MPSCPushFull`

```nim
MPSCPushFull[N] = object
```

Terminal: generation full.

### `MPSCPushOpState`

```nim
MPSCPushOpState = enum
  fsMPSCPushStart, fsMPSCPushFull, fsMPSCPushSlotClaimed
```

### `MPSCPushOpStates`

```nim
MPSCPushOpStates[N] = MPSCPushStart[N] | MPSCPushFull[N] |
    MPSCPushSlotClaimed[N]
```

### `MPSCPushClaimResultKind`

```nim
MPSCPushClaimResultKind = enum
  mMPSCPushSlotClaimed, mMPSCPushFull, mMPSCPushStart
```

### `MPSCPushClaimResult`

```nim
MPSCPushClaimResult[N] = object
  case kind*: MPSCPushClaimResultKind
  of mMPSCPushSlotClaimed:
    mpscpushslotclaimed*: MPSCPushSlotClaimed[N]
  of mMPSCPushFull:
    mpscpushfull*: MPSCPushFull[N]
  of mMPSCPushStart:
    mpscpushstart*: MPSCPushStart[N]
```

### `MpscPushBase`

```nim
MpscPushBase[N; P; T] = object
  head* {.align: 128.}: Atomic[uint64]
  tail* {.align: 128.}: Atomic[uint64]
  cells*: MPMCCellArrayN[N, SlotEncoding(T)]
```


## Procedures & Functions

### `state`

```nim
proc state[N: static int](f: MPSCPushStart[N]): MPSCPushOpState
```

Runtime state inspection for MPSCPushStart. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state[N: static int](f: MPSCPushFull[N]): MPSCPushOpState
```

Runtime state inspection for MPSCPushFull. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state[N: static int](f: MPSCPushSlotClaimed[N]): MPSCPushOpState
```

Runtime state inspection for MPSCPushSlotClaimed. Returns the enum value for pattern matching in case expressions.

### ``$``

```nim
proc `$`[N: static int](s: MPSCPushStart[N]): string
```

String representation for state 'MPSCPushStart'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`[N: static int](s: MPSCPushFull[N]): string
```

String representation for state 'MPSCPushFull'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`[N: static int](s: MPSCPushSlotClaimed[N]): string
```

String representation for state 'MPSCPushSlotClaimed'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`(s: MPSCPushOpState): string {.raises: [], tags: [], forbids: [].}
```

String representation of MPSCPushOpState enum. Strips the fs prefix for human-friendly output.

### `toMPSCPushClaimResult`

```nim
proc toMPSCPushClaimResult[N: static int](s: sink MPSCPushSlotClaimed[N]): MPSCPushClaimResult[
    N]
```

### `toMPSCPushClaimResult`

```nim
proc toMPSCPushClaimResult[N: static int](s: sink MPSCPushFull[N]): MPSCPushClaimResult[
    N]
```

### `toMPSCPushClaimResult`

```nim
proc toMPSCPushClaimResult[N: static int](s: sink MPSCPushStart[N]): MPSCPushClaimResult[
    N]
```

### ``$``

```nim
proc `$`[N: static int](r: MPSCPushClaimResult[N]): string
```

String representation of branching union 'MPSCPushClaimResult<a class="reference internal" href="#N">N</a>'. Returns the active branch's bare state name.

### `start`

```nim
proc start[N: static int](): MPSCPushStart[N] {.inline.}
```

Begin a push operation.

### `tryClaim`

```nim
proc tryClaim[N, P: static int; T](op: MPSCPushStart[N];
                                   queue: var MpscPushBase[N, P, T]): MPSCPushClaimResult[
    N] {.inline, raises: [], tags: [TypestateOp, RootEffect].}
```

Vyukov producer claim. Returns one of:<ul class="simple"><li>SlotClaimed: tail CAS won; caller must call <tt class="docutils literal"><span class="pre"><span class="Identifier">complete</span></span></tt>.</li>
<li>Full: per-slot seq says the previous-generation consumer hasn't re-armed this slot yet. Caller returns false to user.</li>
<li>Start: CAS race or producer raced ahead; caller backs off and retries.</li>
</ul>

### `complete`

```nim
proc complete[N, P: static int; T](op: MPSCPushSlotClaimed[N];
                                   queue: var MpscPushBase[N, P, T];
                                   item: sink T): bool {.inline, notATransition.}
```

Write item to the claimed slot, then publish the seq advance. The <tt class="docutils literal"><span class="pre"><span class="Identifier">seq</span><span class="Operator">.</span><span class="Identifier">store</span><span class="Punctuation">(</span><span class="Identifier">pos</span><span class="Operator">+</span><span class="DecNumber">1</span><span class="Punctuation">,</span> <span class="Identifier">moRelease</span><span class="Punctuation">)</span></span></tt> is the producer-&gt;consumer edge.

### `extractFalse`

```nim
proc extractFalse[N: static int](op: MPSCPushFull[N]): bool {.notATransition.}
```

Terminal: extract false result (queue was full this generation).


## Templates

### ``-&gt;``

```nim
template `->`[N: static int](_: typedesc[MPSCPushClaimResult[N]];
                             s: sink MPSCPushSlotClaimed[N]): MPSCPushClaimResult[
    N]
```

### ``-&gt;``

```nim
template `->`[N: static int](_: typedesc[MPSCPushClaimResult[N]];
                             s: sink MPSCPushFull[N]): MPSCPushClaimResult[N]
```

### ``-&gt;``

```nim
template `->`[N: static int](_: typedesc[MPSCPushClaimResult[N]];
                             s: sink MPSCPushStart[N]): MPSCPushClaimResult[N]
```


## Macros

### `match`

```nim
macro match[N: static int](value: MPSCPushClaimResult[N]; arms: untyped): untyped
```

Pattern-match on a branching union; rewrites into a <tt class="docutils literal"><span class="pre"><span class="Keyword">case</span></span></tt> over the kind discriminator. The value being matched must be a <tt class="docutils literal"><span class="pre"><span class="Keyword">var</span></span></tt> binding. Branch fields are extracted with <tt class="docutils literal"><span class="pre"><span class="Identifier">move</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt>, which requires a mutable binding. Syntax is <tt class="docutils literal"><span class="pre"><span class="Identifier">StateName</span><span class="Punctuation">(</span><span class="Keyword">bind</span><span class="Punctuation">)</span><span class="Punctuation">:</span></span></tt>, not <tt class="docutils literal"><span class="pre"><span class="Keyword">of</span> <span class="Identifier">StateName</span> <span class="Keyword">as</span> <span class="Keyword">bind</span><span class="Punctuation">:</span></span></tt>.

### `match`

```nim
macro match[N: static int](value: MPSCPushOpStates[N]; arms: untyped): untyped
```

Single-target pattern match on states of typestate 'MPSCPushOp'; rewrites to <tt class="docutils literal"><span class="pre"><span class="Keyword">block</span><span class="Punctuation">:</span> <span class="Keyword">let</span> <span class="Keyword">bind</span> <span class="Operator">=</span> <span class="Identifier">move</span><span class="Punctuation">(</span><span class="Identifier">value</span><span class="Punctuation">)</span><span class="Punctuation">;</span> <span class="Identifier">body</span></span></tt>. Syntax is <tt class="docutils literal"><span class="pre"><span class="Operator">&lt;</span><span class="Identifier">StateName</span><span class="Operator">&gt;</span><span class="Punctuation">(</span><span class="Keyword">bind</span><span class="Punctuation">)</span><span class="Punctuation">:</span></span></tt>, with exactly one arm.

### `MPSCPushOp`

```nim
macro MPSCPushOp(initial`gensym0: untyped; typeDef`gensym0: untyped): untyped
```

Typestate-attachment pragma (auto-generated; see §3.7 of the v0.9.0 design doc). Apply to a type declaration to bind the type to this typestate with <tt class="docutils literal"><span class="pre"><span class="Identifier">initial</span></span></tt> as the starting state. Validates TA-002..TA-004 at compile time and populates <tt class="docutils literal"><span class="pre"><span class="Identifier">typestateAttachments</span></span></tt>.

