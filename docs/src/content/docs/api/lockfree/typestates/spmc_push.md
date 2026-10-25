---
title: "lockfree/typestates/spmc_push"
description: "API reference for lockfree/typestates/spmc_push"
---

<p>SPMC Push operation lifecycle typestate (Vyukov per-slot sequence protocol).</p>
<p>State machine: Start -&gt; SlotClaimed | Full | Start (3-arm: claim succeeded / generation full / retry) SlotClaimed -&gt; bool (terminal: write data + publish seq)</p>
<p>Key invariant: Once a slot is claimed via CAS on <tt class="docutils literal"><span class="pre"><span class="Identifier">tail</span></span></tt>, data MUST be written and the per-slot <tt class="docutils literal"><span class="pre"><span class="Identifier">seq</span></span></tt> MUST be advanced to <tt class="docutils literal"><span class="pre"><span class="Identifier">pos</span> <span class="Operator">+</span> <span class="DecNumber">1</span></span></tt> (release). That release is the producer-&gt;consumer happens-before edge.</p>
<p>Single-producer by <em>contract</em>, but Nim's <tt class="docutils literal"><span class="pre"><span class="Identifier">Spmc</span></span></tt> facade does NOT enforce single-thread access. We keep <tt class="docutils literal"><span class="pre"><span class="Identifier">compareExchangeWeak</span></span></tt> on <tt class="docutils literal"><span class="pre"><span class="Identifier">tail</span></span></tt> even on the single-producer side as defense in depth: an accidental two-thread mis-use surfaces as a benign retry rather than silent data corruption.</p>
<p>Memory ordering follows Vyukov canonical: <tt class="docutils literal"><span class="pre"><span class="Identifier">moRelaxed</span></span></tt> on the global <tt class="docutils literal"><span class="pre"><span class="Identifier">tail</span></span></tt> CAS (the per-slot <tt class="docutils literal"><span class="pre"><span class="Identifier">seq</span></span></tt> does the data-ordering work), <tt class="docutils literal"><span class="pre"><span class="Identifier">moAcquire</span></span></tt> on the <tt class="docutils literal"><span class="pre"><span class="Identifier">seq</span></span></tt> load (pairs with consumer's release at <tt class="docutils literal"><span class="pre"><span class="Identifier">pos</span> <span class="Operator">+</span> <span class="Identifier">N</span></span></tt>), and <tt class="docutils literal"><span class="pre"><span class="Identifier">moRelease</span></span></tt> on the <tt class="docutils literal"><span class="pre"><span class="Identifier">seq</span></span></tt> store at <tt class="docutils literal"><span class="pre"><span class="Identifier">pos</span> <span class="Operator">+</span> <span class="DecNumber">1</span></span></tt> (gates the matching consumer).</p>
<p>Backoff: this verb returns the <tt class="docutils literal"><span class="pre"><span class="Identifier">Start</span></span></tt> arm to signal &quot;retry&quot;. The facade holds <tt class="docutils literal"><span class="pre"><span class="Keyword">var</span> <span class="Identifier">spins</span> <span class="Operator">=</span> <span class="Identifier">InitialSpin</span></span></tt> and calls <tt class="docutils literal"><span class="pre"><span class="Identifier">backoffOnRetry</span><span class="Punctuation">(</span><span class="Identifier">spins</span><span class="Punctuation">)</span></span></tt> between iterations on the Start arm. See design doc §6.</p>
<p>See design doc §2 (algorithm), §3 (bug walkthrough), §10.6 (recipe).</p>


## Types

### `SPMCPushStart`

```nim
SPMCPushStart[N] = object
```

Entry point. No data yet.

### `SPMCPushSlotClaimed`

```nim
SPMCPushSlotClaimed[N] = object
  pos*: uint64
  slot*: PhysicalSlotN[N]
```

CAS on <tt class="docutils literal"><span class="pre"><span class="Identifier">tail</span></span></tt> succeeded - we own the slot at <tt class="docutils literal"><span class="pre"><span class="Identifier">pos</span> <span class="Keyword">mod</span> <span class="Identifier">N</span></span></tt>. MUST write data and publish the seq advance.

### `SPMCPushFull`

```nim
SPMCPushFull[N] = object
```

Terminal: generation full.

### `SPMCPushOpState`

```nim
SPMCPushOpState = enum
  fsSPMCPushStart, fsSPMCPushFull, fsSPMCPushSlotClaimed
```

### `SPMCPushOpStates`

```nim
SPMCPushOpStates[N] = SPMCPushStart[N] | SPMCPushFull[N] |
    SPMCPushSlotClaimed[N]
```

### `SPMCPushClaimResultKind`

```nim
SPMCPushClaimResultKind = enum
  sSPMCPushSlotClaimed, sSPMCPushFull, sSPMCPushStart
```

### `SPMCPushClaimResult`

```nim
SPMCPushClaimResult[N] = object
  case kind*: SPMCPushClaimResultKind
  of sSPMCPushSlotClaimed:
    spmcpushslotclaimed*: SPMCPushSlotClaimed[N]
  of sSPMCPushFull:
    spmcpushfull*: SPMCPushFull[N]
  of sSPMCPushStart:
    spmcpushstart*: SPMCPushStart[N]
```

### `SpmcPushBase`

```nim
SpmcPushBase[N; C; T] = object
  head* {.align: 128.}: Atomic[uint64]
  tail* {.align: 128.}: Atomic[uint64]
  cells*: MPMCCellArrayN[N, SlotEncoding(T)]
```


## Procedures & Functions

### `state`

```nim
proc state[N: static int](f: SPMCPushStart[N]): SPMCPushOpState
```

Runtime state inspection for SPMCPushStart. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state[N: static int](f: SPMCPushFull[N]): SPMCPushOpState
```

Runtime state inspection for SPMCPushFull. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state[N: static int](f: SPMCPushSlotClaimed[N]): SPMCPushOpState
```

Runtime state inspection for SPMCPushSlotClaimed. Returns the enum value for pattern matching in case expressions.

### ``$``

```nim
proc `$`[N: static int](s: SPMCPushStart[N]): string
```

String representation for state 'SPMCPushStart'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`[N: static int](s: SPMCPushFull[N]): string
```

String representation for state 'SPMCPushFull'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`[N: static int](s: SPMCPushSlotClaimed[N]): string
```

String representation for state 'SPMCPushSlotClaimed'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`(s: SPMCPushOpState): string {.raises: [], tags: [], forbids: [].}
```

String representation of SPMCPushOpState enum. Strips the fs prefix for human-friendly output.

### `toSPMCPushClaimResult`

```nim
proc toSPMCPushClaimResult[N: static int](s: sink SPMCPushSlotClaimed[N]): SPMCPushClaimResult[
    N]
```

### `toSPMCPushClaimResult`

```nim
proc toSPMCPushClaimResult[N: static int](s: sink SPMCPushFull[N]): SPMCPushClaimResult[
    N]
```

### `toSPMCPushClaimResult`

```nim
proc toSPMCPushClaimResult[N: static int](s: sink SPMCPushStart[N]): SPMCPushClaimResult[
    N]
```

### ``$``

```nim
proc `$`[N: static int](r: SPMCPushClaimResult[N]): string
```

String representation of branching union 'SPMCPushClaimResult<a class="reference internal" href="#N">N</a>'. Returns the active branch's bare state name.

### `start`

```nim
proc start[N: static int](): SPMCPushStart[N] {.inline.}
```

Begin a push operation.

### `tryClaim`

```nim
proc tryClaim[N, C: static int; T](op: SPMCPushStart[N];
                                   queue: var SpmcPushBase[N, C, T]): SPMCPushClaimResult[
    N] {.inline, raises: [], tags: [TypestateOp, RootEffect].}
```

Vyukov producer claim. Returns one of:<ul class="simple"><li>SlotClaimed: tail CAS won; caller must call <tt class="docutils literal"><span class="pre"><span class="Identifier">complete</span></span></tt>.</li>
<li>Full: per-slot seq says the previous-generation consumer hasn't re-armed this slot yet. Caller returns false to user.</li>
<li>Start: CAS race or mis-use detected; caller backs off and retries.</li>
</ul>

### `complete`

```nim
proc complete[N, C: static int; T](op: SPMCPushSlotClaimed[N];
                                   queue: var SpmcPushBase[N, C, T];
                                   item: sink T): bool {.inline, notATransition.}
```

Write item to the claimed slot, then publish the seq advance. The <tt class="docutils literal"><span class="pre"><span class="Identifier">seq</span><span class="Operator">.</span><span class="Identifier">store</span><span class="Punctuation">(</span><span class="Identifier">pos</span><span class="Operator">+</span><span class="DecNumber">1</span><span class="Punctuation">,</span> <span class="Identifier">moRelease</span><span class="Punctuation">)</span></span></tt> is the producer-&gt;consumer edge.

### `extractFalse`

```nim
proc extractFalse[N: static int](op: SPMCPushFull[N]): bool {.notATransition.}
```

Terminal: extract false result (queue was full this generation).


## Templates

### ``-&gt;``

```nim
template `->`[N: static int](_: typedesc[SPMCPushClaimResult[N]];
                             s: sink SPMCPushSlotClaimed[N]): SPMCPushClaimResult[
    N]
```

### ``-&gt;``

```nim
template `->`[N: static int](_: typedesc[SPMCPushClaimResult[N]];
                             s: sink SPMCPushFull[N]): SPMCPushClaimResult[N]
```

### ``-&gt;``

```nim
template `->`[N: static int](_: typedesc[SPMCPushClaimResult[N]];
                             s: sink SPMCPushStart[N]): SPMCPushClaimResult[N]
```


## Macros

### `match`

```nim
macro match[N: static int](value: SPMCPushClaimResult[N]; arms: untyped): untyped
```

Pattern-match on a branching union; rewrites into a <tt class="docutils literal"><span class="pre"><span class="Keyword">case</span></span></tt> over the kind discriminator. The value being matched must be a <tt class="docutils literal"><span class="pre"><span class="Keyword">var</span></span></tt> binding. Branch fields are extracted with <tt class="docutils literal"><span class="pre"><span class="Identifier">move</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt>, which requires a mutable binding. Syntax is <tt class="docutils literal"><span class="pre"><span class="Identifier">StateName</span><span class="Punctuation">(</span><span class="Keyword">bind</span><span class="Punctuation">)</span><span class="Punctuation">:</span></span></tt>, not <tt class="docutils literal"><span class="pre"><span class="Keyword">of</span> <span class="Identifier">StateName</span> <span class="Keyword">as</span> <span class="Keyword">bind</span><span class="Punctuation">:</span></span></tt>.

### `match`

```nim
macro match[N: static int](value: SPMCPushOpStates[N]; arms: untyped): untyped
```

Single-target pattern match on states of typestate 'SPMCPushOp'; rewrites to <tt class="docutils literal"><span class="pre"><span class="Keyword">block</span><span class="Punctuation">:</span> <span class="Keyword">let</span> <span class="Keyword">bind</span> <span class="Operator">=</span> <span class="Identifier">move</span><span class="Punctuation">(</span><span class="Identifier">value</span><span class="Punctuation">)</span><span class="Punctuation">;</span> <span class="Identifier">body</span></span></tt>. Syntax is <tt class="docutils literal"><span class="pre"><span class="Operator">&lt;</span><span class="Identifier">StateName</span><span class="Operator">&gt;</span><span class="Punctuation">(</span><span class="Keyword">bind</span><span class="Punctuation">)</span><span class="Punctuation">:</span></span></tt>, with exactly one arm.

### `SPMCPushOp`

```nim
macro SPMCPushOp(initial`gensym0: untyped; typeDef`gensym0: untyped): untyped
```

Typestate-attachment pragma (auto-generated; see §3.7 of the v0.9.0 design doc). Apply to a type declaration to bind the type to this typestate with <tt class="docutils literal"><span class="pre"><span class="Identifier">initial</span></span></tt> as the starting state. Validates TA-002..TA-004 at compile time and populates <tt class="docutils literal"><span class="pre"><span class="Identifier">typestateAttachments</span></span></tt>.

