---
title: "lockfree/queue"
description: "API reference for lockfree/queue"
---

=========================================================================== Concurrency Topology: SPSC, SPMC, MPSC, MPMC Unbounded Linked-Segment Queues (<tt class="docutils literal"><span class="pre"><span class="Identifier">Queue</span></span></tt>)<hr />
<p>Unbounded <tt class="docutils literal"><span class="pre"><span class="Identifier">Queue</span></span></tt> generic.</p>
<pre>Queue[T, ccProd, ccCons, ST, S, MaxThreads]</pre>
<p>Param order is LOAD-BEARING: T, ccProd, ccCons, ST, S, MaxThreads</p>
<p>The bounded surface lives in <tt class="docutils literal"><span class="pre"><span class="Identifier">bqueue</span><span class="Operator">.</span><span class="Identifier">nim</span></span></tt> (<tt class="docutils literal"><span class="pre"><span class="Identifier">BQueue</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">,</span> <span class="Identifier">ccProd</span><span class="Punctuation">,</span> <span class="Identifier">ccCons</span><span class="Punctuation">,</span> <span class="Identifier">N</span><span class="Punctuation">,</span> <span class="Identifier">P</span><span class="Punctuation">,</span> <span class="Identifier">C</span><span class="Punctuation">]</span></span></tt>). The <tt class="docutils literal"><span class="pre"><span class="Punctuation">(</span><span class="Identifier">ccSingle</span><span class="Punctuation">,</span> <span class="Identifier">ccSingle</span><span class="Punctuation">)</span></span></tt> branch of the object body carries no debra integration (no <tt class="docutils literal"><span class="pre"><span class="Identifier">manager</span></span></tt>, no <tt class="docutils literal"><span class="pre"><span class="Identifier">ownsManager</span></span></tt>, no pin/retire wrappers) and uses the committed-flag-free linked-segment protocol from the legacy standalone unbounded-SPSC module. The other three cardinality combos (MPSC, SPMC, MPMC) carry debra integration.</p>
<p>Cardinality-illegal direct-on-queue calls (multi-producer <tt class="docutils literal"><span class="pre"><span class="Identifier">push</span></span></tt> or multi-consumer <tt class="docutils literal"><span class="pre"><span class="Identifier">pop</span></span></tt> against <tt class="docutils literal"><span class="pre"><span class="Identifier">Queue</span></span></tt> directly rather than via <tt class="docutils literal"><span class="pre"><span class="Identifier">QueueProducer</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">QueueConsumer</span></span></tt>) are gated by compile-time <tt class="docutils literal"><span class="pre"><span class="Punctuation">{</span><span class="Operator">.</span><span class="Identifier">error</span><span class="Operator">.</span><span class="Punctuation">}</span></span></tt> overloads. The error messages reference the user-visible alias type names — no <tt class="docutils literal"><span class="pre"><span class="Operator">*</span><span class="Identifier">Multi</span></span></tt>/<tt class="docutils literal"><span class="pre"><span class="Operator">*</span><span class="Identifier">Single</span></span></tt> leakage.</p>
<p><strong>Queueable[T] concept hookup.</strong> Bare <tt class="docutils literal"><span class="pre"><span class="Identifier">Queue</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">,</span> <span class="Operator">...</span><span class="Punctuation">]</span></span></tt> does NOT satisfy the <tt class="docutils literal"><span class="pre"><span class="Identifier">Queueable</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> concept defined in <tt class="docutils literal"><span class="pre"><span class="Operator">./</span><span class="Identifier">typestates</span><span class="Operator">/</span><span class="Identifier">with_bound</span></span></tt> — unbounded push/pop always routes through a <tt class="docutils literal"><span class="pre"><span class="Identifier">Bound</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">,</span> <span class="Identifier">Tag</span><span class="Punctuation">,</span> <span class="Identifier">Queue</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">,</span> <span class="Operator">...</span><span class="Punctuation">]</span><span class="Punctuation">]</span></span></tt> endpoint (no direct push/pop on bare <tt class="docutils literal"><span class="pre"><span class="Identifier">Queue</span></span></tt>, even for SPSC). Users wanting an unbounded queue with the Queueable-style ergonomic surface use the typestate API (<tt class="docutils literal"><span class="pre"><span class="Identifier">getProducer</span><span class="Punctuation">(</span><span class="Punctuation">)</span><span class="Operator">.</span><span class="Identifier">bindToThread</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt>) or the <tt class="docutils literal"><span class="pre"><span class="Identifier">withBoundProducer</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">withBoundConsumer</span></span></tt> RAII templates in <tt class="docutils literal"><span class="pre"><span class="Operator">./</span><span class="Identifier">typestates</span><span class="Operator">/</span><span class="Identifier">with_bound</span></span></tt>.</p>
<p>---------------------------------------------------------------------- Middle-axis Lifecycle typestate.</p>
<p>Tracks <tt class="docutils literal"><span class="pre"><span class="Identifier">QueueInit</span> <span class="Operator">-&gt;</span> <span class="Identifier">QueueDestroyed</span></span></tt> on the unbounded Queue value. Parallel to <tt class="docutils literal"><span class="pre"><span class="Identifier">BQueue</span></span></tt>'s Lifecycle typestate in <tt class="docutils literal"><span class="pre"><span class="Identifier">bqueue</span><span class="Operator">.</span><span class="Identifier">nim</span></span></tt> — same structural pattern, distinct context / state types because typestate attachments are unique per type (TA-004) and the bqueue/queue split demands independent lifecycles. Mirrors nebr <tt class="docutils literal"><span class="pre"><span class="Identifier">pinned_scope</span><span class="Operator">.</span><span class="Identifier">nim</span></span></tt> verbatim in shape.</p>
<p>State-preserving discipline: every Queue state-preserving op (<tt class="docutils literal"><span class="pre"><span class="Identifier">push</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">pop</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">getProducer</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">getConsumer</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">retireOnCAS</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">retireOnPublish</span></span></tt>, batch variants) declares NO <tt class="docutils literal"><span class="pre"><span class="Punctuation">{</span><span class="Operator">.</span><span class="Identifier">transition</span><span class="Operator">.</span><span class="Punctuation">}</span></span></tt> pragma. They live in this module (queue.nim) so the same-module discipline is satisfied without <tt class="docutils literal"><span class="pre"><span class="Punctuation">{</span><span class="Operator">.</span><span class="Identifier">notATransition</span><span class="Operator">.</span><span class="Punctuation">}</span></span></tt>.</p>
<p>The terminal <tt class="docutils literal"><span class="pre"><span class="Identifier">QueueInit</span> <span class="Operator">-&gt;</span> <span class="Identifier">QueueDestroyed</span></span></tt> transition is emitted by <tt class="docutils literal"><span class="pre"><span class="Operator">=</span><span class="Identifier">destroy</span></span></tt> (further below in the file) via <tt class="docutils literal"><span class="pre"><span class="Identifier">destructorTransition</span></span></tt>. ----------------------------------------------------------------------</p>
<p>---------------------------------------------------------------------- Param-coherence guards — unbounded subset of legacy</p>
<p>The legacy 9 guards covered both rkNone (6 guards) and rkEbr (3 guards). The 6 rkNone guards moved to <tt class="docutils literal"><span class="pre"><span class="Identifier">bqueue</span><span class="Operator">.</span><span class="Identifier">nim</span></span></tt> (<tt class="docutils literal"><span class="pre"><span class="Identifier">assertBQueueParams</span></span></tt>); the 3 rkEbr guards remain here. ----------------------------------------------------------------------</p>
<h1 id="unboundedminusqueue-body-—-spsc-implementation"><center>Unbounded-queue body — SPSC implementation</center></h1><p>---------------------------------------------------------------------- Pre-retire foreclosure helper (push-10 race fix).</p>
<p>Invariant being enforced: a segment may be retired off <tt class="docutils literal"><span class="pre"><span class="Identifier">headSegment</span></span></tt> ONLY AFTER every cell in <tt class="docutils literal"><span class="pre"><span class="Punctuation">[</span><span class="Identifier">fromIdx</span><span class="Punctuation">,</span> <span class="Identifier">S</span><span class="Operator">-</span><span class="DecNumber">1</span><span class="Punctuation">]</span></span></tt> is permanently CLOSED — i.e., no producer can ever publish a value into it. This eliminates the &quot;producer publishes into retired segment&quot; orphan documented in <tt class="docutils literal"><span class="pre"><span class="Identifier">docs</span><span class="Operator">/</span><span class="Identifier">internal</span><span class="Operator">/</span><span class="Identifier">push</span><span class="Operator">-</span><span class="DecNumber">10</span><span class="Operator">-</span><span class="Identifier">lcrq</span><span class="Operator">-</span><span class="Identifier">race</span><span class="Operator">-</span><span class="Identifier">investigation</span><span class="Operator">.</span><span class="Identifier">md</span></span></tt>.</p>
<p>The pre-existing slow-path inline scan (queue.nim ~1631) only closes cells in <tt class="docutils literal"><span class="pre"><span class="Punctuation">[</span><span class="Identifier">mySlot</span><span class="Punctuation">,</span> <span class="Identifier">observed_tail</span><span class="Punctuation">)</span></span></tt>. Cells in <tt class="docutils literal"><span class="pre"><span class="Punctuation">[</span><span class="Identifier">observed_tail</span><span class="Punctuation">,</span> <span class="Identifier">S</span><span class="Operator">-</span><span class="DecNumber">1</span><span class="Punctuation">]</span></span></tt> may be tail-CAS-reserved by in-flight producers whose <tt class="docutils literal"><span class="pre"><span class="Identifier">tryPublish</span></span></tt> has not yet executed; retiring while those reservations remain allows the producer's later <tt class="docutils literal"><span class="pre"><span class="Identifier">tryPublish</span></span></tt> to land in an orphaned segment, and no consumer ever revisits it (data loss).</p>
<p><tt class="docutils literal"><span class="pre"><span class="Identifier">forecloseSegmentForRetire</span><span class="Punctuation">(</span><span class="Identifier">seg</span><span class="Punctuation">,</span> <span class="Identifier">fromIdx</span><span class="Punctuation">)</span></span></tt> closes the full <tt class="docutils literal"><span class="pre"><span class="Punctuation">[</span><span class="Identifier">fromIdx</span><span class="Punctuation">,</span> <span class="Identifier">S</span><span class="Operator">-</span><span class="DecNumber">1</span><span class="Punctuation">]</span></span></tt> range. If any cell is FILLED (<tt class="docutils literal"><span class="pre"><span class="Identifier">seq</span> <span class="Operator">==</span> <span class="DecNumber">1</span></span></tt>, not CLOSED) at scan-time, foreclosure returns <tt class="docutils literal"><span class="pre"><span class="Identifier">false</span></span></tt> — the caller MUST abort the retire and route back through the outer pop loop so the fast-path can claim the value via prevConsumerIdx-CAS.</p>
<p>Race interactions:</p>
<ul class="simple"><li>Producer P reserved tail at index k, has NOT yet <tt class="docutils literal"><span class="pre"><span class="Identifier">tryPublish</span></span></tt>'d: foreclose's <tt class="docutils literal"><span class="pre"><span class="Identifier">tryCloseOnEmpty</span><span class="Punctuation">(</span><span class="Identifier">k</span><span class="Punctuation">,</span> <span class="DecNumber">0</span><span class="Punctuation">)</span></span></tt> succeeds. P's eventual <tt class="docutils literal"><span class="pre"><span class="Identifier">tryPublish</span></span></tt> fails → P escalates to <tt class="docutils literal"><span class="pre"><span class="Identifier">seg</span><span class="Operator">.</span><span class="Identifier">next</span></span></tt>. No orphan.</li>
<li>Producer P has <tt class="docutils literal"><span class="pre"><span class="Identifier">tryPublish</span></span></tt>'d (cell at k is <tt class="docutils literal"><span class="pre"><span class="Identifier">seq</span><span class="Operator">=</span><span class="DecNumber">1</span></span></tt>): foreclose returns <tt class="docutils literal"><span class="pre"><span class="Identifier">false</span></span></tt>. Caller aborts retire. Outer loop's fast-path will reach k via prevConsumerIdx-CAS and claim. No orphan.</li>
<li>Producer P <tt class="docutils literal"><span class="pre"><span class="Identifier">tryPublish</span></span></tt>'s between foreclose's load and CAS at k: CAS fails (expected <tt class="docutils literal"><span class="pre"><span class="Identifier">seq</span><span class="Operator">=</span><span class="DecNumber">0</span></span></tt>, actual <tt class="docutils literal"><span class="pre"><span class="Identifier">seq</span><span class="Operator">=</span><span class="DecNumber">1</span></span></tt>); recheck shows FILLED → return <tt class="docutils literal"><span class="pre"><span class="Identifier">false</span></span></tt>. Caller aborts retire. Outer loop claims.</li>
</ul>
<p>Livelock argument: every iteration of the outer pop loop either claims a value (forward progress) OR foreclose returns true and retire fires (segment advance, also progress) OR foreclose returns false and the next iteration's fast-path claims the discovered FILLED cell. There is no path that loops without progress.</p>
<p>Memory-leak argument: every segment becomes foreclosable in finite time because producers can only reserve up to <tt class="docutils literal"><span class="pre"><span class="Identifier">S</span></span></tt> tail slots and each slot will either be claimed (advancing prevConsumerIdx) or closed (foreclose succeeds on next attempt). ----------------------------------------------------------------------</p>
<p>---------------------------------------------------------------------- Per-queue retire wrappers — + γ guard.</p>
<p>Defined only for non-spsc cardinalities (debra-integrated). Spsc- absorbed (<tt class="docutils literal"><span class="pre"><span class="Punctuation">(</span><span class="Identifier">ccSingle</span><span class="Punctuation">,</span> <span class="Identifier">ccSingle</span><span class="Punctuation">)</span></span></tt>) has no debra integration and thus no retire-bearing site; UFCS lookup of <tt class="docutils literal"><span class="pre"><span class="Identifier">q</span><span class="Operator">.</span><span class="Identifier">retireOn</span><span class="Operator">*</span></span></tt> on a spsc queue fails with method-not-defined, which is the desired guard.</p>
<p><tt class="docutils literal"><span class="pre"><span class="Identifier">retireOnCAS</span></span></tt> is callable under any consumer cardinality (DR-S3). <tt class="docutils literal"><span class="pre"><span class="Identifier">retireOnPublish</span></span></tt> is additionally gated on <tt class="docutils literal"><span class="pre"><span class="Identifier">ccCons</span> <span class="Operator">==</span> <span class="Identifier">ccSingle</span></span></tt> (DR-S4 single-writer foot-gun). The spsc exclusion is also structurally enforced: spsc's <tt class="docutils literal"><span class="pre"><span class="Punctuation">(</span><span class="Identifier">ccCons</span> <span class="Operator">==</span> <span class="Identifier">ccSingle</span><span class="Punctuation">)</span></span></tt> could match <tt class="docutils literal"><span class="pre"><span class="Identifier">retireOnPublish</span></span></tt>'s gate, but the receiver <tt class="docutils literal"><span class="pre"><span class="Keyword">var</span> <span class="Identifier">Queue</span><span class="Punctuation">[</span><span class="Operator">...</span><span class="Punctuation">,</span> <span class="Identifier">ccSingle</span><span class="Punctuation">,</span> <span class="Identifier">ccSingle</span><span class="Punctuation">,</span> <span class="Operator">...</span><span class="Punctuation">]</span></span></tt> body lacks the segment-pointer atomics the wrapper consumes — the guard fires before any harm is done, and the documented design is that spsc is debra-free. ----------------------------------------------------------------------</p>
<p>---------------------------------------------------------------------- Constructors.</p>
<p>Three overloads, distinguished by signature:</p>
<ol class="simple"><li><strong>typedesc-only</strong> — auto-create. Allocates a manager internally (non-spsc) or just initializes the body (spsc). Works for all 4 cardinality combos.</li>
<li><strong>typedesc + manager + handle</strong> — manager-borrowed for ccCons==ccSingle. The handle is consumed by mpsc-equiv only.</li>
<li><strong>typedesc + manager</strong> — manager-borrowed for ccCons==ccMulti.</li>
</ol>
<p>A 4th overload <tt class="docutils literal"><span class="pre"><span class="Punctuation">{</span><span class="Operator">.</span><span class="Identifier">error</span><span class="Operator">.</span><span class="Punctuation">}</span></span></tt>-gates the manager-borrowed signature on spsc-absorbed (<tt class="docutils literal"><span class="pre"><span class="Punctuation">(</span><span class="Identifier">ccSingle</span><span class="Punctuation">,</span> <span class="Identifier">ccSingle</span><span class="Punctuation">)</span></span></tt>) since debra is not used there. ----------------------------------------------------------------------</p>
<h1 id="len-slash-segmentcount-accessorsdot"><center>len / segmentCount accessors.</center></h1><p>---------------------------------------------------------------------- Push body — single-item.</p>
<p>Per-cardinality dispatch via <tt class="docutils literal"><span class="pre"><span class="Keyword">when</span> <span class="Punctuation">(</span><span class="Identifier">ccProd</span><span class="Punctuation">,</span> <span class="Identifier">ccCons</span><span class="Punctuation">)</span> <span class="Keyword">is</span></span></tt>:</p>
<ul class="simple"><li>spsc-absorbed (ccSingle × ccSingle): no pin, no committed-flag; simple tail/<tt class="docutils literal"><span class="pre"><span class="Identifier">next</span></span></tt> linked-segment advance. Lifted verbatim from the legacy <tt class="docutils literal"><span class="pre"><span class="Identifier">unbounded_spsc</span><span class="Operator">.</span><span class="Identifier">nim</span></span></tt> push.</li>
<li>spmc-equiv (ccSingle × ccMulti): no pin (single producer), simple tail advance.</li>
<li>mpsc/mpmc-equiv (ccMulti × _): pin via <tt class="docutils literal"><span class="pre"><span class="Identifier">pinScope</span><span class="Punctuation">(</span><span class="Identifier">unpinned</span><span class="Punctuation">(</span><span class="Identifier">self</span><span class="Operator">.</span><span class="Identifier">handle</span><span class="Punctuation">)</span><span class="Punctuation">)</span></span></tt>, CAS slot claim with segment growth on full.</li>
</ul>
<p>----------------------------------------------------------------------</p>
<p>---------------------------------------------------------------------- Pop body — single-item.</p>
<p>carrier decision: pop lives on bare <tt class="docutils literal"><span class="pre"><span class="Identifier">Queue</span></span></tt> for ccCons == ccSingle variants (spsc-absorbed + mpsc-equiv) and on <tt class="docutils literal"><span class="pre"><span class="Identifier">QueueConsumer</span></span></tt> for ccCons == ccMulti variants (spmc-equiv, mpmc-equiv). ----------------------------------------------------------------------</p>
---------------------------------------------------------------------- ---------------------------------------------------------------------- Destructors driving Lifecycle / Claim-state terminal transitions . Mirror BQueue's pattern. -------------------------------------------------------------------------------------------------------------------------------------------- Family-named unbounded smart constructors — kept as thin wrappers.
<h2><a class="toc-backref" id="len-slash-segmentcount-accessorsdot-every-signature-returns-nimqueue-dotdotdot-never-a-backing-typedot" href="#len-slash-segmentcount-accessorsdot-every-signature-returns-nimqueue-dotdotdot-never-a-backing-typedot">Every signature returns <tt class="docutils literal"><span class="pre"><span class="Identifier">Queue</span><span class="Punctuation">[</span><span class="Operator">...</span><span class="Punctuation">]</span></span></tt>, never a backing type.</a></h2><p>---------------------------------------------------------------------- Push / pop on Bound endpoints.</p>
<p>QueueProducer/QueueConsumer push/pop bodies live on <tt class="docutils literal"><span class="pre"><span class="Identifier">Bound</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">,</span> <span class="Identifier">Tag</span><span class="Punctuation">,</span> <span class="Identifier">Queue</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">,</span> <span class="Identifier">ccProd</span><span class="Punctuation">,</span> <span class="Identifier">ccCons</span><span class="Punctuation">,</span> <span class="Identifier">ST</span><span class="Punctuation">,</span> <span class="Identifier">S</span><span class="Punctuation">,</span> <span class="Identifier">MaxThreads</span><span class="Punctuation">]</span><span class="Punctuation">]</span></span></tt> receivers. The Bound endpoint carries opaque handle storage (<tt class="docutils literal"><span class="pre"><span class="Identifier">handleManager</span><span class="Punctuation">:</span> <span class="Identifier">pointer</span></span></tt> + <tt class="docutils literal"><span class="pre"><span class="Identifier">handleIdx</span><span class="Punctuation">:</span> <span class="Identifier">int</span></span></tt>); for the ccProd==ccMulti paths that need <tt class="docutils literal"><span class="pre"><span class="Identifier">pinScope</span><span class="Punctuation">(</span><span class="Identifier">unpinned</span><span class="Punctuation">(</span><span class="Identifier">handle</span><span class="Punctuation">)</span><span class="Punctuation">)</span></span></tt> the typed <tt class="docutils literal"><span class="pre"><span class="Identifier">ThreadHandle</span><span class="Punctuation">[</span><span class="Identifier">MaxThreads</span><span class="Punctuation">,</span> <span class="Identifier">CC</span><span class="Punctuation">]</span></span></tt> is reconstructed via cast at the call site (<tt class="docutils literal"><span class="pre"><span class="Keyword">when</span> <span class="Identifier">compiles</span><span class="Punctuation">(</span><span class="Identifier">self</span><span class="Operator">.</span><span class="Identifier">queue</span><span class="Operator">.</span><span class="Identifier">manager</span><span class="Punctuation">)</span></span></tt> gate + manager-pointer introspection — mirror of the onClose pattern in endpoint.nim).</p>
<p>SPSC-absorbed and SPMC-equiv push paths are debra-free; they ignore the handle storage entirely. ----------------------------------------------------------------------</p>
Same-thread shortcut helpers (<tt class="docutils literal"><span class="pre"><span class="Identifier">getProducerHere</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">getConsumerHere</span></span></tt>) and <tt class="docutils literal"><span class="pre"><span class="Identifier">bindConsumer</span></span></tt> live in <tt class="docutils literal"><span class="pre"><span class="Identifier">endpoint</span><span class="Operator">.</span><span class="Identifier">nim</span></span></tt> next to <tt class="docutils literal"><span class="pre"><span class="Identifier">getProducer</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">getConsumer</span></span></tt> so the templates bind against the endpoint module's factories rather than any locally-shadowing <tt class="docutils literal"><span class="pre"><span class="Identifier">getProducer</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">getConsumer</span></span></tt> proc at the expansion site.<p>---------------------------------------------------------------------- Drain helpers — <tt class="docutils literal"><span class="pre"><span class="Keyword">iterator</span> <span class="Identifier">drain</span><span class="Operator">*</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Keyword">proc</span> <span class="Identifier">destroyAndDrain</span><span class="Operator">*</span></span></tt></p>
<p>Mirrors the BQueue side: single-consumer arms (ccCons == ccSingle) drain directly on Queue; multi-consumer arms (ccCons == ccMulti) drain via Bound consumer endpoint.</p>
<p>Drain is a loop over the existing <tt class="docutils literal"><span class="pre"><span class="Identifier">pop</span></span></tt> primitive, which already performs Path-C unwrap. The contract is single-threaded — caller owns the queue exclusively during drain. MPMC unbounded pop's defensive CAS-loop always wins on the first try under that contract (no contention), so drain proceeds linearly through the segment chain. ----------------------------------------------------------------------</p>
NOTE: <tt class="docutils literal"><span class="pre">destroyAndDrain</span></tt> is intentionally NOT provided on Bound endpoints for <tt class="docutils literal"><span class="pre">ccCons == ccMulti</span></tt> arms (and likewise for MPSC, whose pop also lives on Bound). The bare <tt class="docutils literal"><span class="pre">var q: Queue[...]</span></tt> remains in scope behind the Bound endpoint, and its scope-end <tt class="docutils literal"><span class="pre">=destroy</span></tt> would conflict with an explicit destructor call from inside <tt class="docutils literal"><span class="pre">destroyAndDrain</span></tt> (double-destroy at the typestate level). For multi-consumer / MPSC arms, the canonical pattern is: for item in drain(myBoundConsumer): cleanup(item) # myQueue's scope-end <tt class="docutils literal"><span class="pre"><span class="Operator">=</span><span class="Identifier">destroy</span></span></tt> walks any residual slots<h1 id="testminusonly-introspection-helpers-for-the-unbounded-segment-layoutdot"><center>Test-only introspection helpers for the unbounded Segment layout.</center></h1>


## Types

### `LCRQCell`

```nim
LCRQCell[T] = Atomic[Pair[uint, T]]
```

Strict-LCRQ cell: native double-word DWCAS-able pair of seq counter (<tt class="docutils literal"><span class="pre"><span class="Identifier">Pair</span><span class="Operator">.</span><span class="Identifier">first</span></span></tt>) and payload (<tt class="docutils literal"><span class="pre"><span class="Identifier">Pair</span><span class="Operator">.</span><span class="Identifier">second</span></span></tt>). Transparent alias for <tt class="docutils literal"><span class="pre"><span class="Identifier">Atomic</span><span class="Punctuation">[</span><span class="Identifier">Pair</span><span class="Punctuation">[</span><span class="Identifier">uint</span><span class="Punctuation">,</span> <span class="Identifier">T</span><span class="Punctuation">]</span><span class="Punctuation">]</span></span></tt> — assigning a <tt class="docutils literal"><span class="pre"><span class="Identifier">LCRQCell</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> to / from the spelled-out type requires no conversion. Using platform-native <tt class="docutils literal"><span class="pre"><span class="Identifier">uint</span></span></tt> (rather than hardcoded <tt class="docutils literal"><span class="pre"><span class="Identifier">uint64</span></span></tt>) keeps the cell at the platform's native DWCAS width, preserving the lock-free guarantee on every debra-supported target.

### `QueueLifecycleCtx`

```nim
QueueLifecycleCtx[T; ccProd; ccCons; ST; S; MaxThreads] = object of RootObj
```

Phantom context type for the Queue Lifecycle typestate.

### `QueueInit`

```nim
QueueInit[T; ccProd; ccCons; ST; S; MaxThreads] = distinct QueueLifecycleCtx[T,
    ccProd, ccCons, ST, S, MaxThreads]
```

Initial Lifecycle state for an unbounded Queue.

### `QueueDestroyed`

```nim
QueueDestroyed[T; ccProd; ccCons; ST; S; MaxThreads] = distinct QueueLifecycleCtx[
    T, ccProd, ccCons, ST, S, MaxThreads]
```

Terminal Lifecycle state for an unbounded Queue.

### `QueueLifecycleState`

```nim
QueueLifecycleState = enum
  fsQueueDestroyed, fsQueueInit
```

### `QueueLifecycleStates`

```nim
QueueLifecycleStates[T; ccProd; ccCons; ST; S; MaxThreads] = QueueDestroyed[T,
    ccProd, ccCons, ST, S, MaxThreads] |
    QueueInit[T, ccProd, ccCons, ST, S, MaxThreads]
```

### `Segment`

```nim
Segment[T; ccProd; ccCons; S] = object
  when ccProd == ccMulti and ccCons == ccMulti:
    cells* {.align: CacheLineBytes.}: array[S, LCRQCell[SlotEncoding(T)]]
  elif ccProd == ccMulti:
    data*: array[S, SlotEncoding(T)]
  else:
    data*: array[S, SlotEncoding(T)]
  next* {.align: 128.}: Atomic[ptr Segment[T, ccProd, ccCons, S]]
  tail* {.align: 128.}: Atomic[int]
  when ccCons == ccSingle:
    head* {.align: CacheLineBytes.}: int
  when ccProd == ccMulti and ccCons == ccSingle:
    committed* {.align: CacheLineBytes.}: array[S, Atomic[bool]]
  when ccCons == ccMulti:
    prevConsumerIdx* {.align: CacheLineBytes.}: Atomic[int]
```

<p>Unbounded-queue segment. One linked-segment payload, parameterized by <tt class="docutils literal"><span class="pre"><span class="Punctuation">(</span><span class="Identifier">ccProd</span><span class="Punctuation">,</span> <span class="Identifier">ccCons</span><span class="Punctuation">)</span></span></tt> so each cardinality variant's field set matches its per-family analogue.</p>
<p>Field set:</p>
<ul class="simple"><li><tt class="docutils literal"><span class="pre"><span class="Identifier">data</span><span class="Punctuation">:</span> <span class="Identifier">array</span><span class="Punctuation">[</span><span class="Identifier">S</span><span class="Punctuation">,</span> <span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> — slot storage (non-MPMC variants).</li>
<li><tt class="docutils literal"><span class="pre"><span class="Identifier">cells</span><span class="Punctuation">:</span> <span class="Identifier">array</span><span class="Punctuation">[</span><span class="Identifier">S</span><span class="Punctuation">,</span> <span class="Identifier">LCRQCell</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span><span class="Punctuation">]</span></span></tt> — strict-LCRQ cells (MPMC only). Replaces <tt class="docutils literal"><span class="pre"><span class="Identifier">committed</span> <span class="Operator">+</span> <span class="Identifier">data</span></span></tt> on the <tt class="docutils literal"><span class="pre"><span class="Identifier">ccMulti</span> <span class="Identifier">×</span> <span class="Identifier">ccMulti</span></span></tt> arm.</li>
<li><tt class="docutils literal"><span class="pre"><span class="Identifier">next</span><span class="Punctuation">:</span> <span class="Identifier">Atomic</span><span class="Punctuation">[</span><span class="Keyword">ptr</span> <span class="Identifier">Segment</span><span class="Punctuation">[</span><span class="Operator">...</span><span class="Punctuation">]</span><span class="Punctuation">]</span></span></tt> — linked-list pointer.</li>
<li><tt class="docutils literal"><span class="pre"><span class="Identifier">tail</span><span class="Punctuation">:</span> <span class="Identifier">Atomic</span><span class="Punctuation">[</span><span class="Identifier">int</span><span class="Punctuation">]</span></span></tt> — producer write index. Atomic for multi-producer coordination and for spsc-equiv (publish via release).</li>
<li><tt class="docutils literal"><span class="pre"><span class="Identifier">head</span><span class="Punctuation">:</span> <span class="Identifier">int</span></span></tt> — single-consumer non-atomic read position. Present on <tt class="docutils literal"><span class="pre"><span class="Punctuation">(</span><span class="Identifier">ccProd</span> <span class="Identifier">×</span> <span class="Identifier">ccSingle</span><span class="Punctuation">)</span></span></tt> shapes (mpsc-equiv and the absorbed spsc-equiv). Only the single consumer ever writes it.</li>
<li><tt class="docutils literal"><span class="pre"><span class="Identifier">committed</span><span class="Punctuation">:</span> <span class="Identifier">array</span><span class="Punctuation">[</span><span class="Identifier">S</span><span class="Punctuation">,</span> <span class="Identifier">Atomic</span><span class="Punctuation">[</span><span class="Identifier">bool</span><span class="Punctuation">]</span><span class="Punctuation">]</span></span></tt> — multi-producer publication flags. Present on <tt class="docutils literal"><span class="pre"><span class="Identifier">ccProd</span> <span class="Operator">==</span> <span class="Identifier">ccMulti</span> <span class="Keyword">and</span> <span class="Identifier">ccCons</span> <span class="Operator">==</span> <span class="Identifier">ccSingle</span></span></tt> (MPSC only — MPMC migrated to <tt class="docutils literal"><span class="pre"><span class="Identifier">cells</span></span></tt>).</li>
<li><tt class="docutils literal"><span class="pre"><span class="Identifier">prevConsumerIdx</span><span class="Punctuation">:</span> <span class="Identifier">Atomic</span><span class="Punctuation">[</span><span class="Identifier">int</span><span class="Punctuation">]</span></span></tt> — multi-consumer CAS slot. Present on <tt class="docutils literal"><span class="pre"><span class="Identifier">ccCons</span> <span class="Operator">==</span> <span class="Identifier">ccMulti</span></span></tt>.</li>
</ul>

### `Queue`

```nim
Queue[T; ccProd; ccCons; ST; S; MaxThreads] {..} = object
  when ccProd == ccSingle and ccCons == ccSingle:
    headSegment* {.align: CacheLineBytes.}: Atomic[
        ptr Segment[T, ccProd, ccCons, S]]
    tailSegment* {.align: CacheLineBytes.}: Atomic[
        ptr Segment[T, ccProd, ccCons, S]]
    itemCount*: Atomic[int]
    segments*: Atomic[int]
  else:
    when ccCons == ccMulti:
      manager*: ptr DebraManager[MaxThreads, nebr.ccMulti]
    else:
      manager*: ptr DebraManager[MaxThreads, nebr.ccSingle]
    headSegment* {.align: CacheLineBytes.}: Atomic[
        ptr Segment[T, ccProd, ccCons, S]]
    tailSegment* {.align: CacheLineBytes.}: Atomic[
        ptr Segment[T, ccProd, ccCons, S]]
    itemCount*: Atomic[int]
    segments*: Atomic[int]
    ownsManager*: bool
    when ccProd == ccMulti:
      producerCount*: Atomic[int]
    when ccCons == ccMulti:
      consumerCount*: Atomic[int]
```

<h1><a class="toc-backref" id="concurrency-topologycolon-unbounded-queue-nimqueue" href="#concurrency-topologycolon-unbounded-queue-nimqueue">Concurrency Topology: Unbounded Queue (<tt class="docutils literal"><span class="pre"><span class="Identifier">Queue</span></span></tt>)</a></h1><table border="1" class="docutils"><tr><th>Dimension</th><th>Specification</th></tr>
<tr><td><strong>Topologies</strong></td><td>SPSC, MPSC, SPMC, MPMC (compile-time cardinality dispatch)</td></tr>
<tr><td><strong>Algorithm</strong></td><td>Linked-Segment LCRQ / Lock-Free Ring Queue + Debra SMR</td></tr>
<tr><td><strong>Capacity</strong></td><td>Dynamically unbounded (chained segments of size <tt class="docutils literal"><span class="pre"><span class="Identifier">S</span></span></tt>)</td></tr>
<tr><td><strong>Coordination</strong></td><td>Atomic head/tail pointers, CAS enqueue/dequeue, DWCAS LCRQ</td></tr>
<tr><td><strong>Payload Encoding</strong></td><td>Path-C Type Admission (<tt class="docutils literal"><span class="pre"><span class="Identifier">SlotEncoding</span><span class="Punctuation">(</span><span class="Identifier">T</span><span class="Punctuation">)</span></span></tt>: POD, ManagedRef/Slice)</td></tr>
<tr><td><strong>Progress Guarantee</strong></td><td>Lock-Free (MPMC, MPSC, SPMC) / Wait-Free (SPSC)</td></tr>
<tr><td><strong>Memory Reclamation</strong></td><td>NEBR / DEBRA (Epoch-Based Reclamation, <tt class="docutils literal"><span class="pre"><span class="Identifier">MaxThreads</span></span></tt> capacity)</td></tr>
</table><p>Body layout splits on <tt class="docutils literal"><span class="pre"><span class="Punctuation">(</span><span class="Identifier">ccProd</span><span class="Punctuation">,</span> <span class="Identifier">ccCons</span><span class="Punctuation">)</span> <span class="Keyword">is</span> <span class="Punctuation">(</span><span class="Identifier">ccSingle</span><span class="Punctuation">,</span> <span class="Identifier">ccSingle</span><span class="Punctuation">)</span></span></tt>:</p>
<ul class="simple"><li><strong>spsc-absorbed</strong> (ccSingle × ccSingle): no debra integration. Linked-segment with committed-flag-free SPSC protocol absorbed verbatim from the legacy <tt class="docutils literal"><span class="pre"><span class="Identifier">UnboundedSpsc</span><span class="Punctuation">[</span><span class="Identifier">S</span><span class="Punctuation">,</span> <span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> type. <tt class="docutils literal"><span class="pre"><span class="Identifier">MaxThreads</span></span></tt> is a type-uniform phantom — no thread-registry capacity is consumed.</li>
<li><strong>non-spsc</strong> (mpsc-/spmc-/mpmc-equiv): debra- integrated. Owns <tt class="docutils literal"><span class="pre"><span class="Identifier">manager</span></span></tt>, walks pin/retire chains in <tt class="docutils literal"><span class="pre"><span class="Identifier">push</span></span></tt>/<tt class="docutils literal"><span class="pre"><span class="Identifier">pop</span></span></tt>. <tt class="docutils literal"><span class="pre"><span class="Identifier">MaxThreads</span></span></tt> sizes the debra registry.</li>
</ul>

### `UnboundedQueue`

```nim
UnboundedQueue[T; ccProd; ccCons; ST; S; MaxThreads] = Queue[T, ccProd, ccCons,
    ST, S, MaxThreads]
```

### `MpmcQueue`

```nim
MpmcQueue[T; ST; S; MaxThreads] = Queue[T, ccMulti, ccMulti, ST, S, MaxThreads]
```

### `SpscQueue`

```nim
SpscQueue[T; ST; S; MaxThreads] = Queue[T, ccSingle, ccSingle, ST, S, MaxThreads]
```

### `MpscQueue`

```nim
MpscQueue[T; ST; S; MaxThreads] = Queue[T, ccMulti, ccSingle, ST, S, MaxThreads]
```

### `SpmcQueue`

```nim
SpmcQueue[T; ST; S; MaxThreads] = Queue[T, ccSingle, ccMulti, ST, S, MaxThreads]
```


## Constants

### `LockFreeQueuesAdvanceEvery`

```nim
LockFreeQueuesAdvanceEvery {.intdefine.}: int = 64
```

Cadence for <tt class="docutils literal"><span class="pre"><span class="Identifier">advanceEvery</span></span></tt> calls in the rkEbr Eager reclamation path. Override at compile time with <tt class="docutils literal"><span class="pre"><span class="Operator">-</span><span class="Identifier">d</span><span class="Punctuation">:</span><span class="Identifier">LockFreeQueuesAdvanceEvery</span><span class="Operator">=</span><span class="Identifier">N</span></span></tt>.

### `LockFreeQueuesMaxWaitForPublishSpins`

```nim
LockFreeQueuesMaxWaitForPublishSpins {.intdefine.}: int = 1024
```

Bounded-spin budget for an MPMC consumer waiting on a stalled producer that won the tail-CAS but has not yet <tt class="docutils literal"><span class="pre"><span class="Identifier">tryPublish</span></span></tt>'d (LCRQ §4 / CRIT-1). After this many spins the consumer drives <tt class="docutils literal"><span class="pre"><span class="Identifier">tryCloseOnEmpty</span></span></tt> on its reserved cell, surrendering the slot and falling through to the slow-path-style skip. Override at compile time with <tt class="docutils literal"><span class="pre"><span class="Operator">-</span><span class="Identifier">d</span><span class="Punctuation">:</span><span class="Identifier">LockFreeQueuesMaxWaitForPublishSpins</span><span class="Operator">=</span><span class="Identifier">N</span></span></tt>. Smaller = faster forward progress under producer stalls but more close-on-empty traffic; larger = better steady-state throughput but worse tail latency when producers stall.

### `CLOSED_BIT`

```nim
CLOSED_BIT = 9223372036854775808'u
```

<p>Strict-LCRQ close sentinel. A cell with <tt class="docutils literal"><span class="pre"><span class="Identifier">seq</span> <span class="Operator">==</span> <span class="Identifier">CLOSED_BIT</span></span></tt> is permanently closed: no producer can publish into it, no consumer can claim it.</p>
<p>The sentinel occupies the high bit of the platform-native <tt class="docutils literal"><span class="pre"><span class="Identifier">uint</span></span></tt> so that <tt class="docutils literal"><span class="pre"><span class="Identifier">LCRQCell</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> stays at native double-word width on every target debra supports (16 bytes on 64-bit, 8 bytes on 32-bit). On 64-bit (uint == uint64) the value is identical to <tt class="docutils literal"><span class="pre"><span class="DecNumber">1'</span><span class="Identifier">u64</span> <span class="Keyword">shl</span> <span class="DecNumber">63</span></span></tt>.</p>


## Procedures & Functions

### `tryPublish`

```nim
proc tryPublish[T](cell: var LCRQCell[T]; expectedSeq: uint; value: T): bool {.
    inline.}
```

<p>Producer publish via DWCAS into an empty cell. Returns true on success (cell now <tt class="docutils literal"><span class="pre"><span class="Punctuation">(</span><span class="Identifier">expectedSeq</span><span class="Operator">+</span><span class="DecNumber">1</span><span class="Punctuation">,</span> <span class="Identifier">value</span><span class="Punctuation">)</span></span></tt>). Returns false if the cell is already filled, closed, or at a different epoch.</p>
<p>Precondition for nullable T (<tt class="docutils literal"><span class="pre"><span class="Keyword">ptr</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Keyword">ref</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">pointer</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">cstring</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Keyword">proc</span></span></tt>, closures): <tt class="docutils literal"><span class="pre"><span class="Identifier">value</span></span></tt> MUST NOT be nil. The std/options transport used by <tt class="docutils literal"><span class="pre"><span class="Identifier">tryClaim</span></span></tt> (<tt class="docutils literal"><span class="pre"><span class="Identifier">some</span><span class="Punctuation">(</span><span class="Identifier">val</span><span class="Punctuation">)</span></span></tt>) asserts <tt class="docutils literal"><span class="pre"><span class="Keyword">not</span> <span class="Identifier">val</span><span class="Operator">.</span><span class="Identifier">isNil</span></span></tt> at runtime for nullable types; forbidding nil here surfaces the contract violation at the producer rather than as a delayed AssertionDefect inside an unrelated consumer's <tt class="docutils literal"><span class="pre"><span class="Identifier">tryClaim</span></span></tt> call. <tt class="docutils literal"><span class="pre"><span class="Identifier">doAssert</span></span></tt> (not <tt class="docutils literal"><span class="pre"><span class="Identifier">assert</span></span></tt>) so the guard survives <tt class="docutils literal"><span class="pre"><span class="Operator">-</span><span class="Identifier">d</span><span class="Punctuation">:</span><span class="Identifier">danger</span></span></tt> builds. <tt class="docutils literal"><span class="pre"><span class="Keyword">when</span> <span class="Identifier">compiles</span><span class="Punctuation">(</span><span class="Identifier">value</span><span class="Operator">.</span><span class="Identifier">isNil</span><span class="Punctuation">)</span></span></tt> covers every nullable type Nim exposes (broader than <tt class="docutils literal"><span class="pre"><span class="Identifier">T</span> <span class="Keyword">is</span> <span class="Keyword">ptr</span> <span class="Keyword">or</span> <span class="Keyword">ref</span></span></tt>).</p>

### `tryClaim`

```nim
proc tryClaim[T](cell: var LCRQCell[T]; expectedSeq: uint): Option[T] {.inline.}
```

<p>Consumer claim via DWCAS.</p>
<p>CONTRACT: NEVER inspect <tt class="docutils literal"><span class="pre"><span class="Identifier">observed</span><span class="Operator">.</span><span class="Identifier">second</span></span></tt>. The CAS on the seq encoding is the sole authority on cell state. A filled cell with payload <tt class="docutils literal"><span class="pre"><span class="Identifier">default</span><span class="Punctuation">(</span><span class="Identifier">T</span><span class="Punctuation">)</span></span></tt> (e.g. <tt class="docutils literal"><span class="pre"><span class="Identifier">q</span><span class="Operator">.</span><span class="Identifier">push</span><span class="Punctuation">(</span><span class="DecNumber">0</span><span class="Punctuation">)</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">q</span><span class="Operator">.</span><span class="Identifier">push</span><span class="Punctuation">(</span><span class="Keyword">nil</span><span class="Punctuation">)</span></span></tt>) is a legitimate publish and MUST be returned via <tt class="docutils literal"><span class="pre"><span class="Identifier">some</span><span class="Punctuation">(</span><span class="Identifier">observed</span><span class="Operator">.</span><span class="Identifier">second</span><span class="Punctuation">)</span></span></tt>.</p>

### `tryCloseOnEmpty`

```nim
proc tryCloseOnEmpty[T](cell: var LCRQCell[T]; expectedSeq: uint): bool {.inline.}
```

Consumer close-on-empty via DWCAS. Atomically sets <tt class="docutils literal"><span class="pre"><span class="Identifier">CLOSED_BIT</span></span></tt> on an empty cell so no producer can later publish into it. Returns false if the cell is already filled or closed.

### `state`

```nim
proc state[T; ccProd: static PinScopeCardinality;
           ccCons: static PinScopeCardinality; ST: static DeallocationStrategy;
           S: static int; MaxThreads: static int](
    f: QueueDestroyed[T, ccProd, ccCons, ST, S, MaxThreads]): QueueLifecycleState
```

Runtime state inspection for QueueDestroyed. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state[T; ccProd: static PinScopeCardinality;
           ccCons: static PinScopeCardinality; ST: static DeallocationStrategy;
           S: static int; MaxThreads: static int](
    f: QueueInit[T, ccProd, ccCons, ST, S, MaxThreads]): QueueLifecycleState
```

Runtime state inspection for QueueInit. Returns the enum value for pattern matching in case expressions.

### ``$``

```nim
proc `$`[T; ccProd: static PinScopeCardinality;
         ccCons: static PinScopeCardinality; ST: static DeallocationStrategy;
         S: static int; MaxThreads: static int](
    s: QueueDestroyed[T, ccProd, ccCons, ST, S, MaxThreads]): string
```

String representation for state 'QueueDestroyed'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`[T; ccProd: static PinScopeCardinality;
         ccCons: static PinScopeCardinality; ST: static DeallocationStrategy;
         S: static int; MaxThreads: static int](
    s: QueueInit[T, ccProd, ccCons, ST, S, MaxThreads]): string
```

String representation for state 'QueueInit'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`(s: QueueLifecycleState): string {.raises: [], tags: [], forbids: [].}
```

String representation of QueueLifecycleState enum. Strips the fs prefix for human-friendly output.

### `validateQueueParams`

```nim
proc validateQueueParams[T; ccProd, ccCons: static PinScopeCardinality;
                         ST: static DeallocationStrategy;
                         S, MaxThreads: static int](
    _: typedesc[Queue[T, ccProd, ccCons, ST, S, MaxThreads]])
```

Compile-time entry point for the 2 param-coherence guards. Has no runtime cost.

### `retireOnCAS`

```nim
proc retireOnCAS[T; ccProd, ccCons: static PinScopeCardinality;
                 ST: static DeallocationStrategy;
                 CC: static nebr.PinScopeCardinality; S, MaxThreads: static int;
                 U](q: var Queue[T, ccProd, ccCons, ST, S, MaxThreads];
                    scope: var PinnedScope[MaxThreads, CC];
                    atomic: var Atomic[U]; expected: var U; desired: U;
                    dtor: Destructor): bool {.discardable.}
```

Per-queue <tt class="docutils literal"><span class="pre"><span class="Identifier">retireOnCAS</span></span></tt> wrapper. Delegates to nebr's <tt class="docutils literal"><span class="pre"><span class="Identifier">pinned_scope</span><span class="Operator">.</span><span class="Identifier">retireOnCAS</span></span></tt>.

### `retireOnPublish`

```nim
proc retireOnPublish[T; ccProd: static PinScopeCardinality;
                     ST: static DeallocationStrategy;
                     CC: static nebr.PinScopeCardinality;
                     S, MaxThreads: static int; U](
    q: var Queue[T, ccProd, ccSingle, ST, S, MaxThreads];
    scope: var PinnedScope[MaxThreads, CC]; atomic: var Atomic[U]; desired: U;
    dtor: Destructor)
```

Per-queue <tt class="docutils literal"><span class="pre"><span class="Identifier">retireOnPublish</span></span></tt> wrapper. <strong>FOOT-GUN — single-writer required (DR-S4).</strong> Delegates to nebr's <tt class="docutils literal"><span class="pre"><span class="Identifier">pinned_scope</span><span class="Operator">.</span><span class="Identifier">retireOnPublish</span></span></tt>.

### `newQueue`

```nim
proc newQueue[T; ccProd: static PinScopeCardinality;
              ST: static DeallocationStrategy = DefaultDeallocationStrategy;
              S, MaxThreads: static int](
    _: typedesc[Queue[T, ccProd, ccSingle, ST, S, MaxThreads]];
    manager: ptr DebraManager[MaxThreads, ccSingle];
    handle: ThreadHandle[MaxThreads, ccSingle]): Queue[T, ccProd, ccSingle, ST,
    S, MaxThreads]
```

<p>Manager-borrowed unbounded <tt class="docutils literal"><span class="pre"><span class="Identifier">newQueue</span></span></tt> overload — ccCons == ccSingle variants (mpsc-equiv only; the spsc-absorbed <tt class="docutils literal"><span class="pre"><span class="Punctuation">(</span><span class="Identifier">ccSingle</span><span class="Punctuation">,</span> <span class="Identifier">ccSingle</span><span class="Punctuation">)</span></span></tt> shape is debra-free and uses a separate <tt class="docutils literal"><span class="pre"><span class="Punctuation">{</span><span class="Operator">.</span><span class="Identifier">error</span><span class="Operator">.</span><span class="Punctuation">}</span></span></tt> overload below).</p>
<p>Caller owns the <tt class="docutils literal"><span class="pre"><span class="Identifier">DebraManager</span></span></tt>. Sets <tt class="docutils literal"><span class="pre"><span class="Identifier">ownsManager</span> <span class="Operator">=</span> <span class="Identifier">false</span></span></tt>. The handle is consumed by mpsc-equiv (<tt class="docutils literal"><span class="pre"><span class="Identifier">ccProd</span> <span class="Operator">==</span> <span class="Identifier">ccMulti</span></span></tt>) and stored on the queue. ccProd-ccSingle spsc-equiv would be type-uniformly constructable here, but is excluded by the dedicated spsc <tt class="docutils literal"><span class="pre"><span class="Punctuation">{</span><span class="Operator">.</span><span class="Identifier">error</span><span class="Operator">.</span><span class="Punctuation">}</span></span></tt> overload further below.</p>

### `newQueue`

```nim
proc newQueue[T; ccProd: static PinScopeCardinality;
              ST: static DeallocationStrategy = DefaultDeallocationStrategy;
              S, MaxThreads: static int](
    _: typedesc[Queue[T, ccProd, ccSingle, ST, S, MaxThreads]];
    manager: ptr DebraManager[MaxThreads, ccSingle]): Queue[T, ccProd, ccSingle,
    ST, S, MaxThreads]
```

Handle-free manager-borrowed unbounded <tt class="docutils literal"><span class="pre"><span class="Identifier">newQueue</span></span></tt> overload for ccCons == ccSingle (mpsc-equiv). The single consumer's debra handle is NOT registered here; the consumer thread registers itself via <tt class="docutils literal"><span class="pre"><span class="Identifier">attachConsumer</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt> before its first <tt class="docutils literal"><span class="pre"><span class="Identifier">pop</span></span></tt>. The handle-carrying overload above remains the escape hatch for callers who register on the consumer thread and supply the handle directly.

### `newQueue`

```nim
proc newQueue[T; ccProd: static PinScopeCardinality;
              ST: static DeallocationStrategy = DefaultDeallocationStrategy;
              S, MaxThreads: static int](
    _: typedesc[Queue[T, ccProd, ccMulti, ST, S, MaxThreads]];
    manager: ptr DebraManager[MaxThreads, ccMulti];
    handle: ThreadHandle[MaxThreads, ccMulti]): Queue[T, ccProd, ccMulti, ST, S,
    MaxThreads]
```

Manager-borrowed unbounded <tt class="docutils literal"><span class="pre"><span class="Identifier">newQueue</span></span></tt> overload — ccCons == ccMulti variants (spmc-equiv + mpmc-equiv).

### `newQueue`

```nim
proc newQueue[T; ccProd: static PinScopeCardinality;
              ST: static DeallocationStrategy = DefaultDeallocationStrategy;
              S, MaxThreads: static int](
    _: typedesc[Queue[T, ccProd, ccMulti, ST, S, MaxThreads]];
    manager: ptr DebraManager[MaxThreads, ccMulti]): Queue[T, ccProd, ccMulti,
    ST, S, MaxThreads]
```

Handle-free manager-borrowed unbounded <tt class="docutils literal"><span class="pre"><span class="Identifier">newQueue</span></span></tt> overload for ccCons == ccMulti (spmc-equiv and mpmc-equiv).

### `newQueue`

```nim
proc newQueue[T; ST: static DeallocationStrategy;
              CC: static nebr.PinScopeCardinality; S, MaxThreads: static int](
    _: typedesc[Queue[T, ccSingle, ccSingle, ST, S, MaxThreads]];
    manager: ptr DebraManager[MaxThreads, CC];
    handle: ThreadHandle[MaxThreads, CC]): Queue[T, ccSingle, ccSingle, ST, S,
    MaxThreads] {.error: "Spsc-absorbed Queue (ccSingle × ccSingle) is debra-free. Use the typedesc-only newQueue(Queue[..., ccSingle, ccSingle, ST, S, MaxThreads]) overload instead.".}
```

### `newQueue`

```nim
proc newQueue[T; ST: static DeallocationStrategy;
              CC: static nebr.PinScopeCardinality; S, MaxThreads: static int](
    _: typedesc[Queue[T, ccSingle, ccSingle, ST, S, MaxThreads]];
    manager: ptr DebraManager[MaxThreads, CC]): Queue[T, ccSingle, ccSingle, ST,
    S, MaxThreads] {.error: "Spsc-absorbed Queue (ccSingle × ccSingle) is debra-free. Use the typedesc-only newQueue(Queue[..., ccSingle, ccSingle, ST, S, MaxThreads]) overload instead.".}
```

### `newQueue`

```nim
proc newQueue[T; ccProd, ccCons: static PinScopeCardinality;
              ST: static DeallocationStrategy = DefaultDeallocationStrategy;
              S, MaxThreads: static int](
    _: typedesc[Queue[T, ccProd, ccCons, ST, S, MaxThreads]]): Queue[T, ccProd,
    ccCons, ST, S, MaxThreads]
```

<p>Auto-create unbounded <tt class="docutils literal"><span class="pre"><span class="Identifier">newQueue</span></span></tt> overload. For the spsc-absorbed <tt class="docutils literal"><span class="pre"><span class="Punctuation">(</span><span class="Identifier">ccSingle</span><span class="Punctuation">,</span> <span class="Identifier">ccSingle</span><span class="Punctuation">)</span></span></tt> branch this skips manager allocation entirely. For the other three cardinality combos, allocates a private <tt class="docutils literal"><span class="pre"><span class="Identifier">DebraManager</span><span class="Punctuation">[</span><span class="Identifier">MaxThreads</span><span class="Punctuation">,</span> <span class="Operator">...</span><span class="Punctuation">]</span></span></tt> and sets <tt class="docutils literal"><span class="pre"><span class="Identifier">ownsManager</span> <span class="Operator">=</span> <span class="Identifier">true</span></span></tt>.</p>
<p><strong>No thread is registered at construction.</strong> <tt class="docutils literal"><span class="pre"><span class="Identifier">registerThread</span></span></tt> is thread-affine (stamps the calling thread + installs a signal handler on the calling OS thread), so registering here would mis-route the handle when the queue is later operated on a different thread. Each operating thread registers itself at attach-time: producers/consumers via <tt class="docutils literal"><span class="pre"><span class="Identifier">getProducer</span><span class="Punctuation">(</span><span class="Punctuation">)</span><span class="Operator">.</span><span class="Identifier">attach</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">getConsumer</span><span class="Punctuation">(</span><span class="Punctuation">)</span><span class="Operator">.</span><span class="Identifier">attach</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt>, and the mpsc-equiv single consumer via <tt class="docutils literal"><span class="pre"><span class="Identifier">attachConsumer</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt> before its first <tt class="docutils literal"><span class="pre"><span class="Identifier">pop</span></span></tt>.</p>

### `initQueue`

```nim
proc initQueue[T; ccProd, ccCons: static PinScopeCardinality;
               ST: static DeallocationStrategy = DefaultDeallocationStrategy;
               S: static int = 64; MaxThreads: static int = 128](
    _: typedesc[Queue[T, ccProd, ccCons, ST, S, MaxThreads]]): Queue[T, ccProd,
    ccCons, ST, S, MaxThreads] {.inline.}
```

Typedesc overload for initializing an unbounded Queue value object.

### `initQueue`

```nim
proc initQueue[T; ccProd, ccCons: static PinScopeCardinality;
               ST: static DeallocationStrategy = DefaultDeallocationStrategy;
               S: static int = 64; MaxThreads: static int = 128](): Queue[T,
    ccProd, ccCons, ST, S, MaxThreads] {.inline.}
```

Initializes an unbounded Queue value object with sensible defaults (S=64, MaxThreads=128).

### `newQueue`

```nim
proc newQueue[T; ccProd, ccCons: static PinScopeCardinality;
              ST: static DeallocationStrategy = DefaultDeallocationStrategy;
              S: static int = 64; MaxThreads: static int = 128](): Queue[T,
    ccProd, ccCons, ST, S, MaxThreads] {.inline.}
```

Smart constructor alias for initQueue.

### `len`

```nim
proc len[T; ccProd, ccCons: static PinScopeCardinality;
         ST: static DeallocationStrategy; S, MaxThreads: static int](
    self: var Queue[T, ccProd, ccCons, ST, S, MaxThreads]): int
```

Number of items currently in the queue (atomic snapshot).

### `segmentCount`

```nim
proc segmentCount[T; ccProd, ccCons: static PinScopeCardinality;
                  ST: static DeallocationStrategy; S, MaxThreads: static int](
    self: var Queue[T, ccProd, ccCons, ST, S, MaxThreads]): int
```

Number of segments currently allocated (atomic snapshot).

### `isEmpty`

```nim
proc isEmpty[T; ccProd, ccCons: static PinScopeCardinality;
             ST: static DeallocationStrategy; S, MaxThreads: static int](
    self: var Queue[T, ccProd, ccCons, ST, S, MaxThreads]): bool {.inline.}
```

Returns true if the queue is empty (atomic snapshot). Checks if headSegment == tailSegment (and unconsumed slots).

### `pop`

```nim
proc pop[T; ST: static DeallocationStrategy; S, MaxThreads: static int](
    self: var Queue[T, ccSingle, ccSingle, ST, S, MaxThreads]): Option[T]
```

Spsc-absorbed pop — direct slot read + segment advance with <tt class="docutils literal"><span class="pre"><span class="Identifier">freeAligned</span><span class="Punctuation">(</span><span class="Identifier">oldSeg</span><span class="Punctuation">)</span></span></tt>. No pin (no retire-race; only one consumer ever runs, only one producer ever writes). Lifted verbatim from the unbounded SPSC pop path.

### `pop`

```nim
proc pop[T; ccProd: static PinScopeCardinality; ST: static DeallocationStrategy;
         S, MaxThreads: static int](self: var Queue[T, ccProd, ccSingle, ST, S,
    MaxThreads]; count: int): Option[seq[T]]
```

Batch pop for ccCons == ccSingle. Thin loop over single-item pop.

### `pop`

```nim
proc pop[T; ccProd: static PinScopeCardinality; ST: static DeallocationStrategy;
         S, MaxThreads: static int](self: var Queue[T, ccProd, ccMulti, ST, S,
    MaxThreads]): Option[T] {.error: "Direct pop on a multi-consumer Queue is not allowed. Use q.getConsumerHere().pop() (same-thread sugar) or q.bindConsumer().pop() (one-shot SC consumer) to obtain a per-thread Bound[T, Tag, Queue[...]] and pop through it.".}
```

### `pop`

```nim
proc pop[T; ccProd: static PinScopeCardinality; ST: static DeallocationStrategy;
         S, MaxThreads: static int](self: var Queue[T, ccProd, ccMulti, ST, S,
    MaxThreads]; count: int): Option[seq[T]] {.error: "Direct batch pop on a multi-consumer Queue is not allowed. Use q.getConsumerHere().pop(count) (same-thread sugar) or q.bindConsumer().pop(count) (one-shot SC consumer) to obtain a per-thread Bound[T, Tag, Queue[...]] and batch-pop through it.".}
```

### ``=copy``

```nim
proc `=copy`[T; ccProd, ccCons: static PinScopeCardinality;
             ST: static DeallocationStrategy; S, MaxThreads: static int](
    dst: var Queue[T, ccProd, ccCons, ST, S, MaxThreads];
    src: Queue[T, ccProd, ccCons, ST, S, MaxThreads]) {.error: "Queue is non-copyable: it owns a `ptr Segment` chain and (for non-spsc cardinalities) a `ptr DebraManager`. Copying would alias these owned pointers and double-free / use-after-free at `=destroy`. Move the Queue (it has `=destroy` move semantics) or share it by `ptr`/`var` parameter instead.".}
```

Compile-time copy ban. A Queue owns heap state (segment chain + optionally the debra manager, recorded by <tt class="docutils literal"><span class="pre"><span class="Identifier">ownsManager</span></span></tt>) that is reclaimed exactly once in <tt class="docutils literal"><span class="pre"><span class="Operator">=</span><span class="Identifier">destroy</span></span></tt>. A field-wise copy would duplicate the owning <tt class="docutils literal"><span class="pre"><span class="Keyword">ptr</span></span></tt>s and reclaim them twice. Move semantics (the implicit <tt class="docutils literal"><span class="pre"><span class="Operator">=</span><span class="Identifier">sink</span></span></tt> synthesized alongside <tt class="docutils literal"><span class="pre"><span class="Operator">=</span><span class="Identifier">destroy</span></span></tt>) remain available; only copies are rejected.

### ``=destroy``

```nim
proc `=destroy`[T; ccProd, ccCons: static PinScopeCardinality;
                ST: static DeallocationStrategy; S, MaxThreads: static int](
    self: var Queue[T, ccProd, ccCons, ST, S, MaxThreads]) {.transitionError: "Queue used after =destroy (lifecycle: QueueInit -> QueueDestroyed).",
    raises: [], raises: [].}
```

<p>Destructor. Walks <tt class="docutils literal"><span class="pre"><span class="Identifier">headSegment</span></span></tt> → <tt class="docutils literal"><span class="pre"><span class="Identifier">next</span></span></tt> → ... freeing each segment. For non-spsc cardinalities, additionally unbinds the client refcount on the manager and (when <tt class="docutils literal"><span class="pre"><span class="Identifier">ownsManager</span></span></tt>) runs the manager's destructor.</p>
<p>Also drives the Lifecycle terminal transition (<tt class="docutils literal"><span class="pre"><span class="Identifier">QueueInit</span> <span class="Operator">-&gt;</span> <span class="Identifier">QueueDestroyed</span></span></tt>) via <tt class="docutils literal"><span class="pre"><span class="Identifier">destructorTransition</span></span></tt>.</p>
<p><strong>Precondition:</strong> all worker threads that attached to this queue must be joined before <tt class="docutils literal"><span class="pre"><span class="Operator">=</span><span class="Identifier">destroy</span></span></tt> runs. debra 0.8.0 has no per-thread unregister; thread handles live until the manager is destroyed here. Destroying the queue while an attached worker is still pinning/popping is undefined. For shared-manager queues (<tt class="docutils literal"><span class="pre"><span class="Identifier">ownsManager</span> <span class="Operator">==</span> <span class="Identifier">false</span></span></tt>) the destructor only unbinds the client refcount; the manager is left intact for its owner to free.</p>

### `initUnboundedSpscQueue`

```nim
proc initUnboundedSpscQueue[T; ST: static DeallocationStrategy = DefaultDeallocationStrategy;
                            S: static int = 64; MaxThreads: static int = 128](): Queue[
    T, ccSingle, ccSingle, ST, S, MaxThreads] {.inline.}
```

Unbounded SPSC (<tt class="docutils literal"><span class="pre"><span class="Identifier">ccSingle</span> <span class="Identifier">×</span> <span class="Identifier">ccSingle</span></span></tt>) auto-create constructor. Skips manager allocation (SPSC has no debra integration).

### `newUnboundedSpscQueue`

```nim
proc newUnboundedSpscQueue[T; ST: static DeallocationStrategy = DefaultDeallocationStrategy;
                           S: static int = 64; MaxThreads: static int = 128](): Queue[
    T, ccSingle, ccSingle, ST, S, MaxThreads] {.inline.}
```

Unbounded SPSC (<tt class="docutils literal"><span class="pre"><span class="Identifier">ccSingle</span> <span class="Identifier">×</span> <span class="Identifier">ccSingle</span></span></tt>) auto-create smart-constructor.

### `initUnboundedMpscQueue`

```nim
proc initUnboundedMpscQueue[T; ST: static DeallocationStrategy = DefaultDeallocationStrategy;
                            S: static int = 64; MaxThreads: static int = 128](
    manager: ptr DebraManager[MaxThreads, ccSingle]): Queue[T, ccMulti,
    ccSingle, ST, S, MaxThreads] {.inline.}
```

Unbounded MPSC (<tt class="docutils literal"><span class="pre"><span class="Identifier">ccMulti</span> <span class="Identifier">×</span> <span class="Identifier">ccSingle</span></span></tt>) borrow constructor — manager-only form.

### `newUnboundedMpscQueue`

```nim
proc newUnboundedMpscQueue[T; ST: static DeallocationStrategy = DefaultDeallocationStrategy;
                           S: static int = 64; MaxThreads: static int = 128](
    manager: ptr DebraManager[MaxThreads, ccSingle]): Queue[T, ccMulti,
    ccSingle, ST, S, MaxThreads] {.inline.}
```

Unbounded MPSC (<tt class="docutils literal"><span class="pre"><span class="Identifier">ccMulti</span> <span class="Identifier">×</span> <span class="Identifier">ccSingle</span></span></tt>) borrow smart-constructor — manager-only form.

### `initUnboundedMpscQueue`

```nim
proc initUnboundedMpscQueue[T; ST: static DeallocationStrategy = DefaultDeallocationStrategy;
                            S: static int = 64; MaxThreads: static int = 128](): Queue[
    T, ccMulti, ccSingle, ST, S, MaxThreads] {.inline.}
```

Unbounded mpsc-equivalent (<tt class="docutils literal"><span class="pre"><span class="Identifier">ccMulti</span> <span class="Identifier">×</span> <span class="Identifier">ccSingle</span></span></tt>) auto-create constructor.

### `newUnboundedMpscQueue`

```nim
proc newUnboundedMpscQueue[T; ST: static DeallocationStrategy = DefaultDeallocationStrategy;
                           S: static int = 64; MaxThreads: static int = 128](): Queue[
    T, ccMulti, ccSingle, ST, S, MaxThreads] {.inline.}
```

Unbounded mpsc-equivalent (<tt class="docutils literal"><span class="pre"><span class="Identifier">ccMulti</span> <span class="Identifier">×</span> <span class="Identifier">ccSingle</span></span></tt>) auto-create smart-constructor.

### `initUnboundedSpmcQueue`

```nim
proc initUnboundedSpmcQueue[T; ST: static DeallocationStrategy = DefaultDeallocationStrategy;
                            S: static int = 64; MaxThreads: static int = 128](
    manager: ptr DebraManager[MaxThreads, ccMulti]): Queue[T, ccSingle, ccMulti,
    ST, S, MaxThreads] {.inline.}
```

Unbounded spmc-equivalent (<tt class="docutils literal"><span class="pre"><span class="Identifier">ccSingle</span> <span class="Identifier">×</span> <span class="Identifier">ccMulti</span></span></tt>) borrow constructor.

### `newUnboundedSpmcQueue`

```nim
proc newUnboundedSpmcQueue[T; ST: static DeallocationStrategy = DefaultDeallocationStrategy;
                           S: static int = 64; MaxThreads: static int = 128](
    manager: ptr DebraManager[MaxThreads, ccMulti]): Queue[T, ccSingle, ccMulti,
    ST, S, MaxThreads] {.inline.}
```

Unbounded spmc-equivalent (<tt class="docutils literal"><span class="pre"><span class="Identifier">ccSingle</span> <span class="Identifier">×</span> <span class="Identifier">ccMulti</span></span></tt>) borrow smart-constructor.

### `initUnboundedSpmcQueue`

```nim
proc initUnboundedSpmcQueue[T; ST: static DeallocationStrategy = DefaultDeallocationStrategy;
                            S: static int = 64; MaxThreads: static int = 128](): Queue[
    T, ccSingle, ccMulti, ST, S, MaxThreads] {.inline.}
```

Unbounded spmc-equivalent (<tt class="docutils literal"><span class="pre"><span class="Identifier">ccSingle</span> <span class="Identifier">×</span> <span class="Identifier">ccMulti</span></span></tt>) auto-create constructor.

### `newUnboundedSpmcQueue`

```nim
proc newUnboundedSpmcQueue[T; ST: static DeallocationStrategy = DefaultDeallocationStrategy;
                           S: static int = 64; MaxThreads: static int = 128](): Queue[
    T, ccSingle, ccMulti, ST, S, MaxThreads] {.inline.}
```

Unbounded spmc-equivalent (<tt class="docutils literal"><span class="pre"><span class="Identifier">ccSingle</span> <span class="Identifier">×</span> <span class="Identifier">ccMulti</span></span></tt>) auto-create smart-constructor.

### `initUnboundedMpmcQueue`

```nim
proc initUnboundedMpmcQueue[T; ST: static DeallocationStrategy = DefaultDeallocationStrategy;
                            S: static int = 64; MaxThreads: static int = 128](
    manager: ptr DebraManager[MaxThreads, ccMulti]): Queue[T, ccMulti, ccMulti,
    ST, S, MaxThreads] {.inline.}
```

Unbounded mpmc-equivalent (<tt class="docutils literal"><span class="pre"><span class="Identifier">ccMulti</span> <span class="Identifier">×</span> <span class="Identifier">ccMulti</span></span></tt>) borrow constructor.

### `newUnboundedMpmcQueue`

```nim
proc newUnboundedMpmcQueue[T; ST: static DeallocationStrategy = DefaultDeallocationStrategy;
                           S: static int = 64; MaxThreads: static int = 128](
    manager: ptr DebraManager[MaxThreads, ccMulti]): Queue[T, ccMulti, ccMulti,
    ST, S, MaxThreads] {.inline.}
```

Unbounded mpmc-equivalent (<tt class="docutils literal"><span class="pre"><span class="Identifier">ccMulti</span> <span class="Identifier">×</span> <span class="Identifier">ccMulti</span></span></tt>) borrow smart-constructor.

### `initUnboundedMpmcQueue`

```nim
proc initUnboundedMpmcQueue[T; ST: static DeallocationStrategy = DefaultDeallocationStrategy;
                            S: static int = 64; MaxThreads: static int = 128](): Queue[
    T, ccMulti, ccMulti, ST, S, MaxThreads] {.inline.}
```

Unbounded mpmc-equivalent (<tt class="docutils literal"><span class="pre"><span class="Identifier">ccMulti</span> <span class="Identifier">×</span> <span class="Identifier">ccMulti</span></span></tt>) auto-create constructor.

### `newUnboundedMpmcQueue`

```nim
proc newUnboundedMpmcQueue[T; ST: static DeallocationStrategy = DefaultDeallocationStrategy;
                           S: static int = 64; MaxThreads: static int = 128](): Queue[
    T, ccMulti, ccMulti, ST, S, MaxThreads] {.inline.}
```

Unbounded mpmc-equivalent (<tt class="docutils literal"><span class="pre"><span class="Identifier">ccMulti</span> <span class="Identifier">×</span> <span class="Identifier">ccMulti</span></span></tt>) auto-create smart-constructor.

### `initUnboundedQueue`

```nim
proc initUnboundedQueue[T; ccProd, ccCons: static PinScopeCardinality; ST: static
    DeallocationStrategy = DefaultDeallocationStrategy; S: static int = 64;
                        MaxThreads: static int = 128](): UnboundedQueue[T,
    ccProd, ccCons, ST, S, MaxThreads] {.inline.}
```

Generic constructor for UnboundedQueue.

### `newUnboundedQueue`

```nim
proc newUnboundedQueue[T; ccProd, ccCons: static PinScopeCardinality; ST: static
    DeallocationStrategy = DefaultDeallocationStrategy; S: static int = 64;
                       MaxThreads: static int = 128](): UnboundedQueue[T,
    ccProd, ccCons, ST, S, MaxThreads] {.inline.}
```

Generic smart constructor for UnboundedQueue.

### `initSpscQueue`

```nim
proc initSpscQueue[T; ST: static DeallocationStrategy = DefaultDeallocationStrategy;
                   S: static int = 64; MaxThreads: static int = 128](): SpscQueue[
    T, ST, S, MaxThreads] {.inline.}
```

Initializes an unbounded SpscQueue (Single-Producer Single-Consumer).

### `newSpscQueue`

```nim
proc newSpscQueue[T; ST: static DeallocationStrategy = DefaultDeallocationStrategy;
                  S: static int = 64; MaxThreads: static int = 128](): SpscQueue[
    T, ST, S, MaxThreads] {.inline.}
```

Smart constructor for SpscQueue (Single-Producer Single-Consumer Unbounded).

### `initMpscQueue`

```nim
proc initMpscQueue[T; ST: static DeallocationStrategy = DefaultDeallocationStrategy;
                   S: static int = 64; MaxThreads: static int = 128](
    manager: ptr DebraManager[MaxThreads, ccSingle]): MpscQueue[T, ST, S,
    MaxThreads] {.inline.}
```

Initializes an unbounded MpscQueue with shared manager.

### `newMpscQueue`

```nim
proc newMpscQueue[T; ST: static DeallocationStrategy = DefaultDeallocationStrategy;
                  S: static int = 64; MaxThreads: static int = 128](
    manager: ptr DebraManager[MaxThreads, ccSingle]): MpscQueue[T, ST, S,
    MaxThreads] {.inline.}
```

Smart constructor for MpscQueue with shared manager.

### `initMpscQueue`

```nim
proc initMpscQueue[T; ST: static DeallocationStrategy = DefaultDeallocationStrategy;
                   S: static int = 64; MaxThreads: static int = 128](): MpscQueue[
    T, ST, S, MaxThreads] {.inline.}
```

Initializes an unbounded MpscQueue (Multi-Producer Single-Consumer).

### `newMpscQueue`

```nim
proc newMpscQueue[T; ST: static DeallocationStrategy = DefaultDeallocationStrategy;
                  S: static int = 64; MaxThreads: static int = 128](): MpscQueue[
    T, ST, S, MaxThreads] {.inline.}
```

Smart constructor for MpscQueue (Multi-Producer Single-Consumer Unbounded).

### `initSpmcQueue`

```nim
proc initSpmcQueue[T; ST: static DeallocationStrategy = DefaultDeallocationStrategy;
                   S: static int = 64; MaxThreads: static int = 128](
    manager: ptr DebraManager[MaxThreads, ccMulti]): SpmcQueue[T, ST, S,
    MaxThreads] {.inline.}
```

Initializes an unbounded SpmcQueue with shared manager.

### `newSpmcQueue`

```nim
proc newSpmcQueue[T; ST: static DeallocationStrategy = DefaultDeallocationStrategy;
                  S: static int = 64; MaxThreads: static int = 128](
    manager: ptr DebraManager[MaxThreads, ccMulti]): SpmcQueue[T, ST, S,
    MaxThreads] {.inline.}
```

Smart constructor for SpmcQueue with shared manager.

### `initSpmcQueue`

```nim
proc initSpmcQueue[T; ST: static DeallocationStrategy = DefaultDeallocationStrategy;
                   S: static int = 64; MaxThreads: static int = 128](): SpmcQueue[
    T, ST, S, MaxThreads] {.inline.}
```

Initializes an unbounded SpmcQueue (Single-Producer Multi-Consumer).

### `newSpmcQueue`

```nim
proc newSpmcQueue[T; ST: static DeallocationStrategy = DefaultDeallocationStrategy;
                  S: static int = 64; MaxThreads: static int = 128](): SpmcQueue[
    T, ST, S, MaxThreads] {.inline.}
```

Smart constructor for SpmcQueue (Single-Producer Multi-Consumer Unbounded).

### `initMpmcQueue`

```nim
proc initMpmcQueue[T; ST: static DeallocationStrategy = DefaultDeallocationStrategy;
                   S: static int = 64; MaxThreads: static int = 128](
    manager: ptr DebraManager[MaxThreads, ccMulti]): MpmcQueue[T, ST, S,
    MaxThreads] {.inline.}
```

Initializes an unbounded MpmcQueue with shared manager.

### `newMpmcQueue`

```nim
proc newMpmcQueue[T; ST: static DeallocationStrategy = DefaultDeallocationStrategy;
                  S: static int = 64; MaxThreads: static int = 128](
    manager: ptr DebraManager[MaxThreads, ccMulti]): MpmcQueue[T, ST, S,
    MaxThreads] {.inline.}
```

Smart constructor for MpmcQueue with shared manager.

### `initMpmcQueue`

```nim
proc initMpmcQueue[T; ST: static DeallocationStrategy = DefaultDeallocationStrategy;
                   S: static int = 64; MaxThreads: static int = 128](): MpmcQueue[
    T, ST, S, MaxThreads] {.inline.}
```

Initializes an unbounded MpmcQueue (Multi-Producer Multi-Consumer).

### `newMpmcQueue`

```nim
proc newMpmcQueue[T; ST: static DeallocationStrategy = DefaultDeallocationStrategy;
                  S: static int = 64; MaxThreads: static int = 128](): MpmcQueue[
    T, ST, S, MaxThreads] {.inline.}
```

Smart constructor for MpmcQueue (Multi-Producer Multi-Consumer Unbounded).

### `initSpscUnboundedQueue`

```nim
proc initSpscUnboundedQueue[T; ST: static DeallocationStrategy = DefaultDeallocationStrategy;
                            S: static int = 64; MaxThreads: static int = 128](): SpscQueue[
    T, ST, S, MaxThreads] {.inline.}
```

Initializes an SpscQueue (Single-Producer Single-Consumer Unbounded).

### `newSpscUnboundedQueue`

```nim
proc newSpscUnboundedQueue[T; ST: static DeallocationStrategy = DefaultDeallocationStrategy;
                           S: static int = 64; MaxThreads: static int = 128](): SpscQueue[
    T, ST, S, MaxThreads] {.inline.}
```

Smart constructor for SpscQueue (Single-Producer Single-Consumer Unbounded).

### `initMpscUnboundedQueue`

```nim
proc initMpscUnboundedQueue[T; ST: static DeallocationStrategy = DefaultDeallocationStrategy;
                            S: static int = 64; MaxThreads: static int = 128](): MpscQueue[
    T, ST, S, MaxThreads] {.inline.}
```

Initializes an MpscQueue (Multi-Producer Single-Consumer Unbounded).

### `newMpscUnboundedQueue`

```nim
proc newMpscUnboundedQueue[T; ST: static DeallocationStrategy = DefaultDeallocationStrategy;
                           S: static int = 64; MaxThreads: static int = 128](): MpscQueue[
    T, ST, S, MaxThreads] {.inline.}
```

Smart constructor for MpscQueue (Multi-Producer Single-Consumer Unbounded).

### `initSpmcUnboundedQueue`

```nim
proc initSpmcUnboundedQueue[T; ST: static DeallocationStrategy = DefaultDeallocationStrategy;
                            S: static int = 64; MaxThreads: static int = 128](): SpmcQueue[
    T, ST, S, MaxThreads] {.inline.}
```

Initializes an SpmcQueue (Single-Producer Multi-Consumer Unbounded).

### `newSpmcUnboundedQueue`

```nim
proc newSpmcUnboundedQueue[T; ST: static DeallocationStrategy = DefaultDeallocationStrategy;
                           S: static int = 64; MaxThreads: static int = 128](): SpmcQueue[
    T, ST, S, MaxThreads] {.inline.}
```

Smart constructor for SpmcQueue (Single-Producer Multi-Consumer Unbounded).

### `initMpmcUnboundedQueue`

```nim
proc initMpmcUnboundedQueue[T; ST: static DeallocationStrategy = DefaultDeallocationStrategy;
                            S: static int = 64; MaxThreads: static int = 128](): MpmcQueue[
    T, ST, S, MaxThreads] {.inline.}
```

Initializes an MpmcQueue (Multi-Producer Multi-Consumer Unbounded).

### `newMpmcUnboundedQueue`

```nim
proc newMpmcUnboundedQueue[T; ST: static DeallocationStrategy = DefaultDeallocationStrategy;
                           S: static int = 64; MaxThreads: static int = 128](): MpmcQueue[
    T, ST, S, MaxThreads] {.inline.}
```

Smart constructor for MpmcQueue (Multi-Producer Multi-Consumer Unbounded).

### `push`

```nim
proc push[T; Tag: SpscProducerTag | MpmcProducerTag | AnyThreadTag;
          ccProd, ccCons: static PinScopeCardinality;
          ST: static DeallocationStrategy; S, MaxThreads: static int](
    self: Bound[T, Tag, Queue[T, ccProd, ccCons, ST, S, MaxThreads]];
    item: sink T) {.tags: [Tag, TypestateOp, RootEffect], raises: [],
                    notATransition.}
```

Push a single item onto the unbounded queue (cardinality-dispatched).

### `push`

```nim
proc push[T; Tag: SpscProducerTag | MpmcProducerTag | AnyThreadTag;
          ccProd, ccCons: static PinScopeCardinality;
          ST: static DeallocationStrategy; S, MaxThreads: static int](
    self: Bound[T, Tag, Queue[T, ccProd, ccCons, ST, S, MaxThreads]];
    items: openArray[T]) {.tags: [Tag, TypestateOp, RootEffect], raises: [],
                           notATransition.}
```

Batch push (thin loop).

### `pop`

```nim
proc pop[T; Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag;
         ccProd: static PinScopeCardinality; ST: static DeallocationStrategy;
         S, MaxThreads: static int](self: Bound[T, Tag,
    Queue[T, ccProd, ccSingle, ST, S, MaxThreads]]): Option[T] {.
    tags: [Tag, TypestateOp, RootEffect], raises: [], notATransition.}
```

Pop for <tt class="docutils literal"><span class="pre"><span class="Identifier">ccCons</span> <span class="Operator">==</span> <span class="Identifier">ccSingle</span></span></tt> (SPSC + MPSC). Single consumer thread, no pin required. Body consolidates the two direct-on-Queue pop overloads with cardinality dispatch via the existing <tt class="docutils literal"><span class="pre"><span class="Keyword">when</span></span></tt> arms.

### `pop`

```nim
proc pop[T; Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag;
         ccProd: static PinScopeCardinality; ST: static DeallocationStrategy;
         S, MaxThreads: static int](self: Bound[T, Tag,
    Queue[T, ccProd, ccSingle, ST, S, MaxThreads]]; count: int): Option[seq[T]] {.
    tags: [Tag, TypestateOp, RootEffect], raises: [], notATransition.}
```

Batch pop for ccCons==ccSingle. Thin loop over single-item pop.

### `pop`

```nim
proc pop[T; Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag;
         ST: static DeallocationStrategy; S, MaxThreads: static int](
    self: Bound[T, Tag, Queue[T, ccSingle, ccMulti, ST, S, MaxThreads]]): Option[
    T] {.tags: [Tag, TypestateOp, RootEffect], raises: [], notATransition.}
```

<p>SPMC pop — retire-bearing site. Pin claim via reconstructed ThreadHandle from opaque Bound storage.</p>
<p>DEBRA Pin–Claim Ordering Invariant (both topologies):</p>
<ol class="simple"><li>Pin opens BEFORE headSegment.load (this <tt class="docutils literal"><span class="pre"><span class="Identifier">pinScope</span></span></tt> scope).</li>
<li>Pin covers slot reservation through readItem/extract window (<tt class="docutils literal"><span class="pre"><span class="Identifier">prevConsumerIdx</span><span class="Operator">.</span><span class="Identifier">compareExchange</span></span></tt> -&gt; <tt class="docutils literal"><span class="pre"><span class="Identifier">move</span><span class="Punctuation">(</span><span class="Identifier">seg</span><span class="Operator">.</span><span class="Identifier">data</span><span class="Punctuation">[</span><span class="Identifier">mySlot</span><span class="Punctuation">]</span><span class="Punctuation">)</span></span></tt> in SPMC; <tt class="docutils literal"><span class="pre"><span class="Identifier">prevConsumerIdx</span><span class="Operator">.</span><span class="Identifier">compareExchange</span></span></tt> -&gt; <tt class="docutils literal"><span class="pre"><span class="Identifier">tryClaim</span></span></tt> DWCAS in MPMC).</li>
<li>Segment under pin == segment under claim (pointer linearity).</li>
<li>headSegment advance (<tt class="docutils literal"><span class="pre"><span class="Identifier">retireOnCAS</span></span></tt>) retires oldSeg via DEBRA; oldSeg is not freed until all pins in its retire-epoch rotate.</li>
<li>Bulk variant acquires per-call pin satisfying (1)–(4).</li>
<li><p>Pin coverage (topology-conditional):</p>
<p>a. Consumer (both SPMC and MPMC): pin opens BEFORE the consumer's slot claim / close-CAS in <tt class="docutils literal"><span class="pre"><span class="Identifier">pop</span></span></tt>, and remains open THROUGH the claim/close completion AND the subsequent item extraction or segment transition. Same <tt class="docutils literal"><span class="pre"><span class="Identifier">pinScope</span></span></tt> as the <tt class="docutils literal"><span class="pre"><span class="Identifier">headSegment</span><span class="Operator">.</span><span class="Identifier">load</span></span></tt> that produced the segment pointer.</p>
<p>b. MPMC producer: push publish-CAS occurs within the same <tt class="docutils literal"><span class="pre"><span class="Identifier">pinScope</span></span></tt> as the <tt class="docutils literal"><span class="pre"><span class="Identifier">tailSegment</span><span class="Operator">.</span><span class="Identifier">load</span></span></tt> that produced the segment pointer. Required because peer producers can retire the segment under us via headSegment-advance (peer-producer retire race). Implementation: MPMC push wraps the retry loop in <tt class="docutils literal"><span class="pre"><span class="Identifier">pinScope</span></span></tt>.</p>
<p>c. SPMC producer: push does NOT require <tt class="docutils literal"><span class="pre"><span class="Identifier">pinScope</span></span></tt>. Single-producer immunity: no peer producer can retire the segment under us. Implementation: SPMC push explicitly opts out of <tt class="docutils literal"><span class="pre"><span class="Identifier">pinScope</span></span></tt>.</p>
</li>
</ol>
<p>DO NOT alter pinScope without re-establishing this invariant.</p>

### `pop`

```nim
proc pop[T; Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag;
         ST: static DeallocationStrategy; S, MaxThreads: static int](
    self: Bound[T, Tag, Queue[T, ccMulti, ccMulti, ST, S, MaxThreads]]): Option[
    T] {.tags: [Tag, TypestateOp, RootEffect], raises: [], notATransition.}
```

<p>MPMC pop — retire-bearing site.</p>
<p>DEBRA Pin–Claim Ordering Invariant (both topologies):</p>
<ol class="simple"><li>Pin opens BEFORE headSegment.load (this <tt class="docutils literal"><span class="pre"><span class="Identifier">pinScope</span></span></tt> scope).</li>
<li>Pin covers slot reservation through readItem/extract window (<tt class="docutils literal"><span class="pre"><span class="Identifier">prevConsumerIdx</span><span class="Operator">.</span><span class="Identifier">compareExchange</span></span></tt> -&gt; <tt class="docutils literal"><span class="pre"><span class="Identifier">move</span><span class="Punctuation">(</span><span class="Identifier">seg</span><span class="Operator">.</span><span class="Identifier">data</span><span class="Punctuation">[</span><span class="Identifier">mySlot</span><span class="Punctuation">]</span><span class="Punctuation">)</span></span></tt> in SPMC; <tt class="docutils literal"><span class="pre"><span class="Identifier">prevConsumerIdx</span><span class="Operator">.</span><span class="Identifier">compareExchange</span></span></tt> -&gt; <tt class="docutils literal"><span class="pre"><span class="Identifier">tryClaim</span></span></tt> DWCAS in MPMC).</li>
<li>Segment under pin == segment under claim (pointer linearity).</li>
<li>headSegment advance (<tt class="docutils literal"><span class="pre"><span class="Identifier">retireOnCAS</span></span></tt>) retires oldSeg via DEBRA; oldSeg is not freed until all pins in its retire-epoch rotate.</li>
<li>Bulk variant acquires per-call pin satisfying (1)–(4).</li>
<li><p>Pin coverage (topology-conditional):</p>
<p>a. Consumer (both SPMC and MPMC): pin opens BEFORE the consumer's slot claim / close-CAS in <tt class="docutils literal"><span class="pre"><span class="Identifier">pop</span></span></tt>, and remains open THROUGH the claim/close completion AND the subsequent item extraction or segment transition. Same <tt class="docutils literal"><span class="pre"><span class="Identifier">pinScope</span></span></tt> as the <tt class="docutils literal"><span class="pre"><span class="Identifier">headSegment</span><span class="Operator">.</span><span class="Identifier">load</span></span></tt> that produced the segment pointer.</p>
<p>b. MPMC producer: push publish-CAS occurs within the same <tt class="docutils literal"><span class="pre"><span class="Identifier">pinScope</span></span></tt> as the <tt class="docutils literal"><span class="pre"><span class="Identifier">tailSegment</span><span class="Operator">.</span><span class="Identifier">load</span></span></tt> that produced the segment pointer. Required because peer producers can retire the segment under us via headSegment-advance (peer-producer retire race). Implementation: MPMC push wraps the retry loop in <tt class="docutils literal"><span class="pre"><span class="Identifier">pinScope</span></span></tt>.</p>
<p>c. SPMC producer: push does NOT require <tt class="docutils literal"><span class="pre"><span class="Identifier">pinScope</span></span></tt>. Single-producer immunity: no peer producer can retire the segment under us. Implementation: SPMC push explicitly opts out of <tt class="docutils literal"><span class="pre"><span class="Identifier">pinScope</span></span></tt>.</p>
</li>
</ol>
<p>DO NOT alter pinScope without re-establishing this invariant.</p>

### `pop`

```nim
proc pop[T; Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag;
         ccProd: static PinScopeCardinality; ST: static DeallocationStrategy;
         S, MaxThreads: static int](self: Bound[T, Tag,
    Queue[T, ccProd, ccMulti, ST, S, MaxThreads]]; count: int): Option[seq[T]] {.
    tags: [Tag, TypestateOp, RootEffect], raises: [], notATransition.}
```

### `popBatch`

```nim
proc popBatch[T; Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag;
              ccProd, ccCons: static PinScopeCardinality;
              ST: static DeallocationStrategy; S, MaxThreads: static int](
    self: var Bound[T, Tag, Queue[T, ccProd, ccCons, ST, S, MaxThreads]];
    dest: var openArray[T]; maxCount: int = -1): int {.
    tags: [Tag, TypestateOp, RootEffect], raises: [], notATransition.}
```

Batch pop for Queue into caller-supplied buffer <tt class="docutils literal"><span class="pre"><span class="Identifier">dest</span></span></tt>. For MPMC strict-LCRQ, amortizes slot reservations on <tt class="docutils literal"><span class="pre"><span class="Identifier">prevConsumerIdx</span></span></tt> via atomic slot advance and runs SMR epoch advancement once for the entire batch.

### `popBatch`

```nim
proc popBatch[T; Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag;
              ccProd, ccCons: static PinScopeCardinality;
              ST: static DeallocationStrategy; S, MaxThreads: static int](
    self: Bound[T, Tag, Queue[T, ccProd, ccCons, ST, S, MaxThreads]];
    dest: var openArray[T]; maxCount: int = -1): int {.
    tags: [Tag, TypestateOp, RootEffect], raises: [], notATransition.}
```

### `popChunk`

```nim
proc popChunk[T; Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag;
              ccProd, ccCons: static PinScopeCardinality;
              ST: static DeallocationStrategy; S, MaxThreads: static int](
    self: var Bound[T, Tag, Queue[T, ccProd, ccCons, ST, S, MaxThreads]];
    chunkSize: int): seq[T] {.tags: [Tag, TypestateOp, RootEffect], raises: [],
                              notATransition.}
```

### `popChunk`

```nim
proc popChunk[T; Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag;
              ccProd, ccCons: static PinScopeCardinality;
              ST: static DeallocationStrategy; S, MaxThreads: static int](
    self: Bound[T, Tag, Queue[T, ccProd, ccCons, ST, S, MaxThreads]];
    chunkSize: int): seq[T] {.tags: [Tag, TypestateOp, RootEffect], raises: [],
                              notATransition.}
```

### `destroyAndDrain`

```nim
proc destroyAndDrain[T; ST: static DeallocationStrategy;
                     S, MaxThreads: static int](
    self: sink Queue[T, ccSingle, ccSingle, ST, S, MaxThreads];
    cleanup: proc (item: T) {.gcsafe, raises: [].})
```

Drain SPSC unbounded Queue, run <tt class="docutils literal"><span class="pre"><span class="Identifier">cleanup</span></span></tt> per item, then destroy. Takes <tt class="docutils literal"><span class="pre"><span class="Identifier">sink</span></span></tt> of the queue so the caller's binding is moved-from (preventing scope-end double-destroy). Under mm:none this is the ONLY safe teardown path for a non-empty queue with ref / string / seq payloads.

### `destroyAndDrain`

```nim
proc destroyAndDrain[T; ST: static DeallocationStrategy;
                     S, MaxThreads: static int](
    self: sink Queue[T, ccSingle, ccSingle, ST, S, MaxThreads])
```

SPSC POD discard overload. Takes <tt class="docutils literal"><span class="pre"><span class="Identifier">sink</span></span></tt> to prevent caller-side scope-end double-destroy.


## Templates

### `assertQueueParams`

```nim
template assertQueueParams[T; ccProd, ccCons: static PinScopeCardinality;
                           ST: static DeallocationStrategy;
                           S, MaxThreads: static int]()
```


## Macros

### `match`

```nim
macro match[T; ccProd: static PinScopeCardinality;
            ccCons: static PinScopeCardinality; ST: static DeallocationStrategy;
            S: static int; MaxThreads: static int](
    value: QueueLifecycleStates[T, ccProd, ccCons, ST, S, MaxThreads];
    arms: untyped): untyped
```

Single-target pattern match on states of typestate 'QueueLifecycle'; rewrites to <tt class="docutils literal"><span class="pre"><span class="Keyword">block</span><span class="Punctuation">:</span> <span class="Keyword">let</span> <span class="Keyword">bind</span> <span class="Operator">=</span> <span class="Identifier">move</span><span class="Punctuation">(</span><span class="Identifier">value</span><span class="Punctuation">)</span><span class="Punctuation">;</span> <span class="Identifier">body</span></span></tt>. Syntax is <tt class="docutils literal"><span class="pre"><span class="Operator">&lt;</span><span class="Identifier">StateName</span><span class="Operator">&gt;</span><span class="Punctuation">(</span><span class="Keyword">bind</span><span class="Punctuation">)</span><span class="Punctuation">:</span></span></tt>, with exactly one arm.

### `QueueLifecycle`

```nim
macro QueueLifecycle(initial`gensym7: untyped; typeDef`gensym7: untyped): untyped
```

Typestate-attachment pragma (auto-generated; see §3.7 of the v0.9.0 design doc). Apply to a type declaration to bind the type to this typestate with <tt class="docutils literal"><span class="pre"><span class="Identifier">initial</span></span></tt> as the starting state. Validates TA-002..TA-004 at compile time and populates <tt class="docutils literal"><span class="pre"><span class="Identifier">typestateAttachments</span></span></tt>.


## Iterators

### `drain`

```nim
iterator drain[T; ST: static DeallocationStrategy; S, MaxThreads: static int](
    self: var Queue[T, ccSingle, ccSingle, ST, S, MaxThreads]): T
```

Drain SPSC-absorbed unbounded Queue. Bare-Queue pop is available for SPSC only (the only arm where direct-on-Queue pop survived v5.0.0); other cardinalities route drain through Bound endpoints.

### `drain`

```nim
iterator drain[T; Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag;
               ST: static DeallocationStrategy; S, MaxThreads: static int](
    self: Bound[T, Tag, Queue[T, ccMulti, ccSingle, ST, S, MaxThreads]]): T
```

Drain MPSC unbounded Queue via Bound consumer endpoint.

### `drain`

```nim
iterator drain[T; Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag;
               ST: static DeallocationStrategy; S, MaxThreads: static int](
    self: Bound[T, Tag, Queue[T, ccSingle, ccMulti, ST, S, MaxThreads]]): T
```

Drain SPMC unbounded Queue via Bound consumer endpoint.

### `drain`

```nim
iterator drain[T; Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag;
               ST: static DeallocationStrategy; S, MaxThreads: static int](
    self: Bound[T, Tag, Queue[T, ccMulti, ccMulti, ST, S, MaxThreads]]): T
```

Drain MPMC unbounded Queue via Bound consumer endpoint. The MPMC consumer-CAS pop succeeds on the first try under the single- consumer drain contract (no contention).

### `items`

```nim
iterator items[T; ST: static DeallocationStrategy; S, MaxThreads: static int](
    self: var Queue[T, ccSingle, ccSingle, ST, S, MaxThreads]): T
```

Warning: Destructively drains the queue.

### `items`

```nim
iterator items[T; Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag;
               ST: static DeallocationStrategy; S, MaxThreads: static int](
    self: Bound[T, Tag, Queue[T, ccMulti, ccSingle, ST, S, MaxThreads]]): T
```

Warning: Destructively drains the queue.

### `items`

```nim
iterator items[T; Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag;
               ST: static DeallocationStrategy; S, MaxThreads: static int](
    self: Bound[T, Tag, Queue[T, ccSingle, ccMulti, ST, S, MaxThreads]]): T
```

Warning: Destructively drains the queue.

### `items`

```nim
iterator items[T; Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag;
               ST: static DeallocationStrategy; S, MaxThreads: static int](
    self: Bound[T, Tag, Queue[T, ccMulti, ccMulti, ST, S, MaxThreads]]): T
```

Warning: Destructively drains the queue.

### `pairs`

```nim
iterator pairs[T; ST: static DeallocationStrategy; S, MaxThreads: static int](
    self: var Queue[T, ccSingle, ccSingle, ST, S, MaxThreads]): (int, T)
```

Warning: Destructively drains the queue.

### `pairs`

```nim
iterator pairs[T; Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag;
               ST: static DeallocationStrategy; S, MaxThreads: static int](
    self: Bound[T, Tag, Queue[T, ccMulti, ccSingle, ST, S, MaxThreads]]): (int,
    T)
```

Warning: Destructively drains the queue.

### `pairs`

```nim
iterator pairs[T; Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag;
               ST: static DeallocationStrategy; S, MaxThreads: static int](
    self: Bound[T, Tag, Queue[T, ccSingle, ccMulti, ST, S, MaxThreads]]): (int,
    T)
```

Warning: Destructively drains the queue.

### `pairs`

```nim
iterator pairs[T; Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag;
               ST: static DeallocationStrategy; S, MaxThreads: static int](
    self: Bound[T, Tag, Queue[T, ccMulti, ccMulti, ST, S, MaxThreads]]): (int, T)
```

Warning: Destructively drains the queue.

