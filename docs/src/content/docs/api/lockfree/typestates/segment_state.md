---
title: "lockfree/typestates/segment_state"
description: "API reference for lockfree/typestates/segment_state"
---

<p>Segment-state predicate for the unbounded MPSC arm.</p>
<p>Companion to the two slot-state predicate families in <tt class="docutils literal"><span class="pre"><span class="Identifier">slot_state</span><span class="Operator">.</span><span class="Identifier">nim</span></span></tt>, covering the MPSC committed-segment predicate (the linked-segment destructor walk).</p>
<p>Substrate: <tt class="docutils literal"><span class="pre"><span class="Identifier">Segment</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">,</span> <span class="Identifier">ccMulti</span><span class="Punctuation">,</span> <span class="Identifier">ccSingle</span><span class="Punctuation">,</span> <span class="Identifier">S</span><span class="Punctuation">]</span><span class="Operator">.</span><span class="Identifier">committed</span><span class="Punctuation">:</span> <span class="Identifier">array</span><span class="Punctuation">[</span><span class="Identifier">S</span><span class="Punctuation">,</span> <span class="Identifier">Atomic</span><span class="Punctuation">[</span><span class="Identifier">bool</span><span class="Punctuation">]</span><span class="Punctuation">]</span></span></tt> — the committed-flag overlay on the MPSC arm (declared in <tt class="docutils literal"><span class="pre"><span class="Identifier">queue</span><span class="Operator">.</span><span class="Identifier">nim</span></span></tt> on the <tt class="docutils literal"><span class="pre"><span class="Punctuation">(</span><span class="Identifier">ccMulti</span> <span class="Identifier">×</span> <span class="Identifier">ccSingle</span><span class="Punctuation">)</span></span></tt> shape).</p>
<p>Current call sites: NONE in v0.1.0. The first consumer is the segment destructor walk, which walks <tt class="docutils literal"><span class="pre"><span class="Identifier">committed</span><span class="Punctuation">[</span><span class="Identifier">i</span><span class="Punctuation">]</span></span></tt> to drop any values committed by the producer but not yet read by the consumer when the segment is reclaimed.</p>
<p>Why a sibling module rather than a section in <tt class="docutils literal"><span class="pre"><span class="Identifier">slot_state</span><span class="Operator">.</span><span class="Identifier">nim</span></span></tt>? Orthogonality rationale: three substrates → three predicate families. The MPSC <tt class="docutils literal"><span class="pre"><span class="Identifier">committed</span><span class="Punctuation">[</span><span class="Identifier">i</span><span class="Punctuation">]</span></span></tt> is a segment-overlay flag with different lifetime semantics from the per-slot seq counters used by Families A and B. Keeping it lexically distinct makes accidental cross-substrate reuse impossible.</p>
<p>Import note: this module imports <tt class="docutils literal"><span class="pre"><span class="Identifier">queue</span><span class="Operator">.</span><span class="Identifier">nim</span></span></tt> (and is itself NOT imported by <tt class="docutils literal"><span class="pre"><span class="Identifier">queue</span><span class="Operator">.</span><span class="Identifier">nim</span></span></tt> in v0.1.0), so there is no cycle.</p>


## Procedures & Functions

### `slotIsCommittedAndUnread`

```nim
proc slotIsCommittedAndUnread[T; S: static int](
    seg: var Segment[T, ccMulti, ccSingle, S]; slot: int; prevConsumerIdx: int): bool {.
    inline.}
```

Returns true when <tt class="docutils literal"><span class="pre"><span class="Identifier">slot</span></span></tt> is at or past the consumer's last-read index AND the producer has flipped its <tt class="docutils literal"><span class="pre"><span class="Identifier">committed</span><span class="Punctuation">[</span><span class="Identifier">slot</span><span class="Punctuation">]</span></span></tt> flag to true. The relaxed load suffices because the destructor walk runs only when the segment is being reclaimed — all producers and the consumer have already quiesced by EBR/manual reclamation guarantees, so no in-flight publish can race the walk.

