---
title: "lockfree/typestates/slot_state"
description: "API reference for lockfree/typestates/slot_state"
---

<p>Slot-state predicates for v0.1.0 lockfree umbrella.</p>
<p>Two predicate families plus an MPSC committed-segment predicate in sibling <tt class="docutils literal"><span class="pre"><span class="Identifier">segment_state</span><span class="Operator">.</span><span class="Identifier">nim</span></span></tt>.</p>
<p>Module-layout choice: shared <tt class="docutils literal"><span class="pre"><span class="Identifier">slot_state</span><span class="Operator">.</span><span class="Identifier">nim</span></span></tt> for Families A and B. Family-A symbols use the <tt class="docutils literal"><span class="pre"><span class="Identifier">B</span></span></tt> suffix (<tt class="docutils literal"><span class="pre"><span class="Identifier">seqIsClosedB</span></span></tt>, etc.); Family-B uses no suffix (<tt class="docutils literal"><span class="pre"><span class="Identifier">seqIsClosed</span></span></tt>, etc.) because LCRQ-integration is the live consumer in v0.1.0 (4 call sites in <tt class="docutils literal"><span class="pre"><span class="Identifier">queue</span><span class="Operator">.</span><span class="Identifier">nim</span></span></tt>). The two families intentionally do NOT share a <tt class="docutils literal"><span class="pre"><span class="Identifier">seqIsClosed</span></span></tt> symbol so that a silent <tt class="docutils literal"><span class="pre"><span class="Identifier">uint64</span></span></tt> ↔ <tt class="docutils literal"><span class="pre"><span class="Identifier">uint</span></span></tt> width punning across the substrates cannot occur (orthogonality rationale).</p>
<p>Three substrates → two slot-state predicate families plus one segment-state predicate (the MPSC <tt class="docutils literal"><span class="pre"><span class="Identifier">committed</span><span class="Punctuation">[</span><span class="Identifier">i</span><span class="Punctuation">]</span></span></tt> predicate lives in the sibling <tt class="docutils literal"><span class="pre"><span class="Identifier">segment_state</span><span class="Operator">.</span><span class="Identifier">nim</span></span></tt> module):</p>
<p>Family A — Bounded-Vyukov: Substrate: <tt class="docutils literal"><span class="pre"><span class="Identifier">MPMCCell</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> with <tt class="docutils literal"><span class="pre"><span class="Identifier">payload</span><span class="Operator">.</span><span class="Identifier">seq</span><span class="Punctuation">:</span> <span class="Identifier">Atomic</span><span class="Punctuation">[</span><span class="Identifier">uint64</span><span class="Punctuation">]</span></span></tt>. Close sentinel: <tt class="docutils literal"><span class="pre"><span class="Identifier">ClosedBitB</span> <span class="Operator">=</span> <span class="Identifier">high</span><span class="Punctuation">(</span><span class="Identifier">uint64</span><span class="Punctuation">)</span> <span class="Keyword">shr</span> <span class="DecNumber">1</span></span></tt> (64-bit wide). Current call sites: NONE (placeholder for future bounded close-on-empty; consumed by later phases).</p>
<p>Family B — LCRQ-integration: Substrate: <tt class="docutils literal"><span class="pre"><span class="Identifier">LCRQCell</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span> <span class="Operator">=</span> <span class="Identifier">Atomic</span><span class="Punctuation">[</span><span class="Identifier">Pair</span><span class="Punctuation">[</span><span class="Identifier">uint</span><span class="Punctuation">,</span> <span class="Identifier">T</span><span class="Punctuation">]</span><span class="Punctuation">]</span></span></tt>. Close sentinel: <tt class="docutils literal"><span class="pre"><span class="Identifier">CLOSED_BIT</span></span></tt>, platform-uint wide. Live consumer in <tt class="docutils literal"><span class="pre"><span class="Identifier">queue</span><span class="Operator">.</span><span class="Identifier">nim</span></span></tt>.</p>
<p>Import-cycle note: this module is a <em>substrate</em> for queue.nim (queue.nim imports it), so it MUST NOT import queue.nim. For Family B that means <tt class="docutils literal"><span class="pre"><span class="Identifier">seqIsClosed</span><span class="Punctuation">(</span><span class="Identifier">s</span><span class="Punctuation">:</span> <span class="Identifier">uint</span><span class="Punctuation">)</span></span></tt> takes a plain <tt class="docutils literal"><span class="pre"><span class="Identifier">uint</span></span></tt> and uses a locally-defined <tt class="docutils literal"><span class="pre"><span class="Identifier">LCRQClosedBit</span></span></tt> constant whose value is computed by the same formula as queue.nim's <tt class="docutils literal"><span class="pre"><span class="Identifier">CLOSED_BIT</span><span class="Operator">*</span> <span class="Operator">=</span> <span class="DecNumber">1'</span><span class="Identifier">u</span> <span class="Keyword">shl</span> <span class="Punctuation">(</span><span class="Identifier">sizeof</span><span class="Punctuation">(</span><span class="Identifier">uint</span><span class="Punctuation">)</span> <span class="Operator">*</span> <span class="DecNumber">8</span> <span class="Operator">-</span> <span class="DecNumber">1</span><span class="Punctuation">)</span></span></tt>.</p>
<p>Drift guard (honest scope): the import cycle (queue.nim imports THIS module) makes it impossible to <tt class="docutils literal"><span class="pre"><span class="Keyword">import</span></span></tt> <tt class="docutils literal"><span class="pre"><span class="Identifier">CLOSED_BIT</span></span></tt> here, so a true cross-module pin (<tt class="docutils literal"><span class="pre"><span class="Keyword">static</span><span class="Punctuation">:</span> <span class="Identifier">doAssert</span> <span class="Identifier">LCRQClosedBit</span> <span class="Operator">==</span> <span class="Identifier">CLOSED_BIT</span></span></tt>) CANNOT exist. Instead the two constants are kept equal by using the IDENTICAL formula, and a LOCAL static-assert at the bottom of this file pins this module's <tt class="docutils literal"><span class="pre"><span class="Identifier">LCRQClosedBit</span></span></tt> to that canonical formula (<tt class="docutils literal"><span class="pre"><span class="DecNumber">1'</span><span class="Identifier">u</span> <span class="Keyword">shl</span> <span class="Punctuation">(</span><span class="Identifier">sizeof</span><span class="Punctuation">(</span><span class="Identifier">uint</span><span class="Punctuation">)</span> <span class="Operator">*</span> <span class="DecNumber">8</span> <span class="Operator">-</span> <span class="DecNumber">1</span><span class="Punctuation">)</span></span></tt>). That tripwire fires if someone edits THIS module's constant away from the canonical formula. RESIDUAL RISK (explicit, not guarded): if someone edits queue.nim's <tt class="docutils literal"><span class="pre"><span class="Identifier">CLOSED_BIT</span></span></tt> formula, the divergence is NOT caught here — the local assert only pins this module's side. Keeping both on the same literal formula is the only mitigation available without breaking the cycle.</p>


## Constants

### `ClosedBitB`

```nim
ClosedBitB = 9223372036854775807'u64
```

Family-A close sentinel. 64-bit wide because the Vyukov substrate is <tt class="docutils literal"><span class="pre"><span class="Identifier">Atomic</span><span class="Punctuation">[</span><span class="Identifier">uint64</span><span class="Punctuation">]</span></span></tt>. Distinct from Family-B's platform-uint <tt class="docutils literal"><span class="pre"><span class="Identifier">CLOSED_BIT</span></span></tt> so the two substrates remain lexically separable (orthogonality rationale).


## Procedures & Functions

### `seqIsEmptyB`

```nim
proc seqIsEmptyB(s: uint64; pos: uint64): bool {.inline, raises: [], tags: [],
    forbids: [].}
```

Family A. Vyukov empty: <tt class="docutils literal"><span class="pre"><span class="Identifier">seq</span> <span class="Operator">==</span> <span class="Identifier">pos</span></span></tt>.

### `seqIsFilledB`

```nim
proc seqIsFilledB(s: uint64; pos: uint64): bool {.inline, raises: [], tags: [],
    forbids: [].}
```

Family A. Vyukov filled: <tt class="docutils literal"><span class="pre"><span class="Identifier">seq</span> <span class="Operator">==</span> <span class="Identifier">pos</span> <span class="Operator">+</span> <span class="DecNumber">1</span></span></tt>.

### `seqIsClosedB`

```nim
proc seqIsClosedB(s: uint64): bool {.inline, raises: [], tags: [], forbids: [].}
```

Family A. Placeholder for future bounded close-on-empty; zero call sites in v0.1.0.

### `seqIsClaimedB`

```nim
proc seqIsClaimedB(s: uint64; pos: uint64): bool {.inline, raises: [], tags: [],
    forbids: [].}
```

Family A. Bounded destructor walk: a slot is &quot;claimed&quot; when its seq has advanced past the filled epoch but has not been closed.

### `seqIsLiveB`

```nim
proc seqIsLiveB[T](slot: var MPMCCell[T]; pos: uint64): bool {.inline.}
```

Family A. Loads <tt class="docutils literal"><span class="pre"><span class="Identifier">payload</span><span class="Operator">.</span><span class="Identifier">seq</span></span></tt> with <tt class="docutils literal"><span class="pre"><span class="Identifier">moRelaxed</span></span></tt> and reports whether the slot is filled at epoch <tt class="docutils literal"><span class="pre"><span class="Identifier">pos</span></span></tt> and not closed.

### `seqIsClosed`

```nim
proc seqIsClosed(s: uint): bool {.inline, raises: [], tags: [], forbids: [].}
```

Family B. LCRQ-integration close test. Replaces the inline <tt class="docutils literal"><span class="pre"><span class="Punctuation">(</span><span class="Operator">&lt;</span><span class="Identifier">seq</span><span class="Operator">&gt;</span> <span class="Keyword">and</span> <span class="Identifier">CLOSED_BIT</span><span class="Punctuation">)</span> <span class="Operator">!=</span> <span class="DecNumber">0'</span><span class="Identifier">u</span></span></tt> literals in queue.nim.

