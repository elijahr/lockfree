---
title: "lockfree/bqueue"
description: "API reference for lockfree/bqueue"
---

=========================================================================== Concurrency Topology: SPSC, SPMC, MPSC, MPMC Bounded Ring-Buffer Queues (<tt class="docutils literal"><span class="pre"><span class="Identifier">BQueue</span></span></tt>)<hr />
<p>Bounded lock-free queue — <tt class="docutils literal"><span class="pre"><span class="Identifier">BQueue</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">,</span> <span class="Identifier">ccProd</span><span class="Punctuation">,</span> <span class="Identifier">ccCons</span><span class="Punctuation">,</span> <span class="Identifier">N</span><span class="Punctuation">,</span> <span class="Identifier">P</span><span class="Punctuation">,</span> <span class="Identifier">C</span><span class="Punctuation">]</span></span></tt>.</p>
<p>A 6-param bounded ring-buffer surface with no debra integration and no <tt class="docutils literal"><span class="pre"><span class="Identifier">ST</span></span></tt>/<tt class="docutils literal"><span class="pre"><span class="Identifier">S</span></span></tt>/<tt class="docutils literal"><span class="pre"><span class="Identifier">MaxThreads</span></span></tt> axes. Cardinality dispatch uses <tt class="docutils literal"><span class="pre"><span class="Keyword">when</span> <span class="Punctuation">(</span><span class="Identifier">ccProd</span><span class="Punctuation">,</span> <span class="Identifier">ccCons</span><span class="Punctuation">)</span> <span class="Keyword">is</span></span></tt> internally.</p>
<p><strong>Param order is LOAD-BEARING</strong>: <tt class="docutils literal"><span class="pre"><span class="Identifier">T</span><span class="Punctuation">,</span> <span class="Identifier">ccProd</span><span class="Punctuation">,</span> <span class="Identifier">ccCons</span><span class="Punctuation">,</span> <span class="Identifier">N</span><span class="Punctuation">,</span> <span class="Identifier">P</span><span class="Punctuation">,</span> <span class="Identifier">C</span></span></tt>.</p>
<p><strong>No cross-import.</strong> <tt class="docutils literal"><span class="pre"><span class="Identifier">bqueue</span><span class="Operator">.</span><span class="Identifier">nim</span></span></tt> MUST NOT <tt class="docutils literal"><span class="pre"><span class="Keyword">import</span> <span class="Operator">./</span><span class="Identifier">queue</span></span></tt> (or vice-versa). Shared helpers route through <tt class="docutils literal"><span class="pre"><span class="Operator">./</span><span class="Identifier">internal</span><span class="Operator">/</span><span class="Identifier">shared</span></span></tt>. Any helper added to <tt class="docutils literal"><span class="pre"><span class="Identifier">internal</span><span class="Operator">/</span><span class="Identifier">shared</span></span></tt> is available to both modules without creating a backward dependency that would defeat the split.</p>
<p><strong>Queueable[T] concept hookup.</strong> Bare <tt class="docutils literal"><span class="pre"><span class="Identifier">BQueue</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">,</span> <span class="Identifier">ccSingle</span><span class="Punctuation">,</span> <span class="Identifier">ccSingle</span><span class="Punctuation">,</span> <span class="Operator">...</span><span class="Punctuation">]</span></span></tt> satisfies the <tt class="docutils literal"><span class="pre"><span class="Identifier">Queueable</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> concept defined in <tt class="docutils literal"><span class="pre"><span class="Operator">./</span><span class="Identifier">typestates</span><span class="Operator">/</span><span class="Identifier">with_bound</span></span></tt>. Conformance is pinned by static doAsserts in that module across the full Path-C-encoded payload set (ref / string / seq / POD). No code change to this module is required for concept conformance — the existing public <tt class="docutils literal"><span class="pre"><span class="Identifier">push</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">pop</span></span></tt> signatures on the SPSC arm already match the concept's expected shape.</p>
<p><strong>Field-layout invariant.</strong> Bounded queue bodies preserve the offset prefix required by the typestate Base types (<tt class="docutils literal"><span class="pre"><span class="Identifier">SpscBase</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">MpscBase</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">SpmcBase</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">MpmcBase</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Operator">*</span><span class="Identifier">PushBase</span></span></tt>). The <tt class="docutils literal"><span class="pre"><span class="Keyword">static</span><span class="Punctuation">:</span></span></tt> offsetOf asserts below lock the prefix at canonical instantiations so the unsafe casts in the push/pop bodies remain sound. Object-field offsets are computed structurally, so a match for one instantiation implies a match for all.</p>
<p><strong>Cardinality dispatch ladder.</strong> The four (ccProd × ccCons) combos are handled by <tt class="docutils literal"><span class="pre"><span class="Keyword">when</span></span></tt> arms inside the procs, matching the layout the legacy per-family files (<tt class="docutils literal"><span class="pre"><span class="Identifier">spsc</span><span class="Operator">.</span><span class="Identifier">nim</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">mpsc</span><span class="Operator">.</span><span class="Identifier">nim</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">spmc</span><span class="Operator">.</span><span class="Identifier">nim</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">mpmc</span><span class="Operator">.</span><span class="Identifier">nim</span></span></tt>) used pre-unification:</p>
<ul class="simple"><li><tt class="docutils literal"><span class="pre"><span class="Identifier">ccSingle</span> <span class="Identifier">×</span> <span class="Identifier">ccSingle</span></span></tt> (SPSC): direct <tt class="docutils literal"><span class="pre"><span class="Identifier">Queue</span><span class="Operator">.</span><span class="Identifier">push</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">Queue</span><span class="Operator">.</span><span class="Identifier">pop</span></span></tt>.</li>
<li><tt class="docutils literal"><span class="pre"><span class="Identifier">ccMulti</span> <span class="Identifier">×</span> <span class="Identifier">ccSingle</span></span></tt> (MPSC): producer.push / direct pop.</li>
<li><tt class="docutils literal"><span class="pre"><span class="Identifier">ccSingle</span> <span class="Identifier">×</span> <span class="Identifier">ccMulti</span></span></tt> (SPMC): direct push / consumer.pop.</li>
<li><tt class="docutils literal"><span class="pre"><span class="Identifier">ccMulti</span> <span class="Identifier">×</span> <span class="Identifier">ccMulti</span></span></tt> (MPMC): producer.push / consumer.pop.</li>
</ul>
<p>Multi-side direct-on-queue calls are gated by compile-time <tt class="docutils literal"><span class="pre"><span class="Punctuation">{</span><span class="Operator">.</span><span class="Identifier">error</span><span class="Operator">.</span><span class="Punctuation">}</span></span></tt> overloads — calling <tt class="docutils literal"><span class="pre"><span class="Identifier">BQueue</span><span class="Operator">.</span><span class="Identifier">push</span><span class="Punctuation">(</span><span class="Identifier">item</span><span class="Punctuation">)</span></span></tt> on a <tt class="docutils literal"><span class="pre"><span class="Identifier">ccProd</span> <span class="Operator">==</span> <span class="Identifier">ccMulti</span></span></tt> queue (or <tt class="docutils literal"><span class="pre"><span class="Identifier">BQueue</span><span class="Operator">.</span><span class="Identifier">pop</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt> on <tt class="docutils literal"><span class="pre"><span class="Identifier">ccCons</span> <span class="Operator">==</span> <span class="Identifier">ccMulti</span></span></tt>) fails at compile time with a message pointing the caller at <tt class="docutils literal"><span class="pre"><span class="Identifier">BQueue</span><span class="Operator">.</span><span class="Identifier">getProducer</span><span class="Punctuation">(</span><span class="Punctuation">)</span><span class="Operator">.</span><span class="Identifier">push</span><span class="Punctuation">(</span><span class="Identifier">item</span><span class="Punctuation">)</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">BQueue</span><span class="Operator">.</span><span class="Identifier">getConsumer</span><span class="Punctuation">(</span><span class="Punctuation">)</span><span class="Operator">.</span><span class="Identifier">pop</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt>.</p>
<p>---------------------------------------------------------------------- Middle-axis Lifecycle typestate.</p>
<p>Tracks <tt class="docutils literal"><span class="pre"><span class="Identifier">QueueInit</span> <span class="Operator">-&gt;</span> <span class="Identifier">QueueDestroyed</span></span></tt> on the BQueue value itself. Mirrors nebr's <tt class="docutils literal"><span class="pre"><span class="Identifier">pinned_scope</span><span class="Operator">.</span><span class="Identifier">nim</span></span></tt> (lines 67-93) verbatim in structure:</p>
<ul class="simple"><li>Phantom context type carries the BQueue's generic params (T, cardinalities, sizes) and <tt class="docutils literal"><span class="pre"><span class="Keyword">of</span> <span class="Identifier">RootObj</span></span></tt> so the state types can <tt class="docutils literal"><span class="pre"><span class="Keyword">distinct</span></span></tt> from it and the typestate's <tt class="docutils literal"><span class="pre"><span class="Identifier">inheritsFromRootObj</span> <span class="Operator">=</span> <span class="Identifier">true</span></span></tt> flag is honored.</li>
<li>Two state types (initial <tt class="docutils literal"><span class="pre"><span class="Identifier">BQueueInit</span></span></tt> + terminal <tt class="docutils literal"><span class="pre"><span class="Identifier">BQueueDestroyed</span></span></tt>) are phantom — they never appear in user code; they exist purely so the typestate verifier can attach them to BQueue and drive the <tt class="docutils literal"><span class="pre"><span class="Operator">=</span><span class="Identifier">destroy</span></span></tt> transition.</li>
<li>The single transition lives on <tt class="docutils literal"><span class="pre"><span class="Operator">=</span><span class="Identifier">destroy</span></span></tt> via <tt class="docutils literal"><span class="pre"><span class="Identifier">destructorTransition</span></span></tt> (line further below in the destructor section). State-preserving ops (<tt class="docutils literal"><span class="pre"><span class="Identifier">push</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">pop</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">getProducer</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">getConsumer</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">attach</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">detach</span></span></tt>, batch variants) declare NO transition pragma — the typestate verifier accepts same-module state-preserving methods on attached types as non-transitioning operations that mutate runtime fields without changing the static typestate.</li>
</ul>
<p><strong>State-preserving discipline:</strong> every state-preserving op on BQueue stays in bqueue.nim (same module) and omits <tt class="docutils literal"><span class="pre"><span class="Punctuation">{</span><span class="Operator">.</span><span class="Identifier">transition</span><span class="Operator">.</span><span class="Punctuation">}</span></span></tt>. Cross- module callers would need <tt class="docutils literal"><span class="pre"><span class="Punctuation">{</span><span class="Operator">.</span><span class="Identifier">notATransition</span><span class="Operator">.</span><span class="Punctuation">}</span></span></tt> per the typestates pragma rules; the current implementation does NOT expose any cross-module state-preserving ops, so none are tagged. ----------------------------------------------------------------------</p>
<p>---------------------------------------------------------------------- Param-coherence guards for BQueue.</p>
<p>Asserts the 6 bounded-side invariants: N &gt; 0, P/C consistent with cardinality, etc. The unbounded-side guards (S &gt; 0, MaxThreads &gt; 0, N == 0 and P == 0 and C == 0) do not apply — BQueue has no S or MaxThreads and its N is required positive. ----------------------------------------------------------------------</p>
<p>---------------------------------------------------------------------- Field-offset prefix invariants vs typestate Base types.</p>
<p>The bounded push/pop ladders below cast <tt class="docutils literal"><span class="pre"><span class="Identifier">BQueue</span></span></tt> pointers to the per-family typestate Base types (<tt class="docutils literal"><span class="pre"><span class="Identifier">SpscBase</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">MpscBase</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">SpmcBase</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">MpmcBase</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Operator">*</span><span class="Identifier">PushBase</span></span></tt>). For those casts to be sound the BQueue object must share its leading field layout with each Base. Pin one canonical instantiation per cardinality: object-field offsets are computed structurally, so a match for one instantiation implies a match for all. ----------------------------------------------------------------------</p>
<p>---------------------------------------------------------------------- Constructor / accessors.</p>
<p>6-param BQueue type signature (no ST phantom — bounded body has no deallocation strategy; default destructor is sufficient). ----------------------------------------------------------------------</p>
<p>---------------------------------------------------------------------- Family-named bounded smart constructors.</p>
<p>Thin wrappers around <tt class="docutils literal"><span class="pre"><span class="Identifier">newBQueue</span></span></tt> with cardinality pre-bound. M4 alias-return lock honored — every signature returns the user-visible <tt class="docutils literal"><span class="pre"><span class="Identifier">BQueue</span></span></tt> alias, never a backing <tt class="docutils literal"><span class="pre"><span class="Operator">*</span><span class="Identifier">Multi</span></span></tt>/<tt class="docutils literal"><span class="pre"><span class="Operator">*</span><span class="Identifier">Single</span></span></tt> type. The wrappers stay because the test suite (and downstream user code) reach <tt class="docutils literal"><span class="pre"><span class="Identifier">newSpscQueue</span></span></tt>/<tt class="docutils literal"><span class="pre"><span class="Identifier">newMpscQueue</span></span></tt>/<tt class="docutils literal"><span class="pre"><span class="Identifier">newSpmcQueue</span></span></tt>/<tt class="docutils literal"><span class="pre"><span class="Identifier">newMpmcQueue</span></span></tt> widely; replacing them all with raw <tt class="docutils literal"><span class="pre"><span class="Identifier">newBQueue</span><span class="Punctuation">[</span><span class="Operator">...</span><span class="Punctuation">]</span></span></tt> invocations would be a large mechanical change with no semantic benefit. ----------------------------------------------------------------------</p>
<p>---------------------------------------------------------------------- getProducer / getConsumer — multi-cardinality thread-id registration.</p>
<p>Defined only for <tt class="docutils literal"><span class="pre"><span class="Identifier">ccProd</span> <span class="Operator">==</span> <span class="Identifier">ccMulti</span></span></tt> resp. <tt class="docutils literal"><span class="pre"><span class="Identifier">ccCons</span> <span class="Operator">==</span> <span class="Identifier">ccMulti</span></span></tt>. Single-cardinality side pushes/pops directly through <tt class="docutils literal"><span class="pre"><span class="Identifier">BQueue</span><span class="Operator">.</span><span class="Identifier">push</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">BQueue</span><span class="Operator">.</span><span class="Identifier">pop</span></span></tt> (no handshake required). ----------------------------------------------------------------------</p>
<p>---------------------------------------------------------------------- Batch push / pop — <tt class="docutils literal"><span class="pre"><span class="Identifier">openArray</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">count</span></span></tt>-style overloads.</p>
<p>Batch operations are best-effort loops over single-item primitives (semantic carried from the legacy bodies; batch atomicity is intentionally NOT preserved). ----------------------------------------------------------------------</p>
<pre>----------------------------------------------------------------------
Destructors driving Lifecycle / Claim-state terminal transitions .

Mirror nebr `pinned_scope.nim` verbatim: the typestate terminal transition is
emitted by `=destroy` via `destructorTransition: InitialState -&gt;
TerminalState`. State- preserving ops (push, pop, getProducer, getConsumer,
attach, detach) declare no transition pragma; the typestate stays
static-stable across them and only the destructor moves the value to the
terminal state.

**transitionError apparatus reinterpretation**: push/pop are NOT transitions
(they declare no `{.transition.}`); `transitionError` attaches only to
transition declarations. The destructor IS a transition, so its
`transitionError` carries the user-visible diagnostic. push/pop have no
`transitionError` annotation because they have nothing to attach it to.

**Limitation**: typestates v0.9.3 does NOT statically catch a
use-after-destroy (a method call on a value already in BQueueDestroyed). The
CFG analyzer enforces &quot;reaches terminal by end of scope,&quot; not &quot;no method
calls on a value already in terminal state.&quot; Documented in CHANGELOG v5.0.0.
----------------------------------------------------------------------</pre>
<p>---------------------------------------------------------------------- Push / pop on Bound endpoints.</p>
<p>These overloads live on <tt class="docutils literal"><span class="pre"><span class="Identifier">Bound</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">,</span> <span class="Identifier">Tag</span><span class="Punctuation">,</span> <span class="Identifier">BQueue</span><span class="Punctuation">[</span><span class="Operator">...</span><span class="Punctuation">]</span><span class="Punctuation">]</span></span></tt> receivers with <tt class="docutils literal"><span class="pre"><span class="Punctuation">{</span><span class="Operator">.</span><span class="Identifier">tags</span><span class="Punctuation">:</span> <span class="Punctuation">[</span><span class="Identifier">Tag</span><span class="Punctuation">]</span><span class="Operator">.</span><span class="Punctuation">}</span></span></tt> effect pragmas for static role discrimination. <tt class="docutils literal"><span class="pre"><span class="Identifier">Tag</span></span></tt> is a phantom generic that drives effect-tag checking; the bodies themselves don't use it.</p>
<p><strong>Role guards.</strong> Each overload restricts <tt class="docutils literal"><span class="pre"><span class="Identifier">Tag</span></span></tt> to the appropriate role tag (e.g., MPSC push requires <tt class="docutils literal"><span class="pre"><span class="Identifier">Tag</span><span class="Punctuation">:</span> <span class="Identifier">MpmcProducerTag</span> <span class="Operator">|</span> <span class="Identifier">SpscProducerTag</span></span></tt>-style constraint; here we keep <tt class="docutils literal"><span class="pre"><span class="Identifier">Tag</span></span></tt> open at this layer and rely on the spawn-macro layer in C14+ to bind the correct tag for each call site. Role distinctness compile-fail tests at C9-tripwire scope assert this — see <tt class="docutils literal"><span class="pre"><span class="Identifier">tests</span><span class="Operator">/</span><span class="Identifier">should_fail</span><span class="Operator">/</span></span></tt>). ----------------------------------------------------------------------</p>
Same-thread shortcut helpers (<tt class="docutils literal"><span class="pre"><span class="Identifier">getProducerHere</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">getConsumerHere</span></span></tt>) live in <tt class="docutils literal"><span class="pre"><span class="Identifier">endpoint</span><span class="Operator">.</span><span class="Identifier">nim</span></span></tt> next to <tt class="docutils literal"><span class="pre"><span class="Identifier">getProducer</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">getConsumer</span></span></tt> so the template binds against the endpoint module's factories rather than any locally-shadowing factory at the expansion site (e.g. bench adapters with their own consumer-view factory).<p>---------------------------------------------------------------------- Drain helpers — <tt class="docutils literal"><span class="pre"><span class="Keyword">iterator</span> <span class="Identifier">drain</span><span class="Operator">*</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Keyword">proc</span> <span class="Identifier">destroyAndDrain</span><span class="Operator">*</span></span></tt></p>
<p>Drain is the user-facing extraction mechanism for unpopped items at queue end-of-life. Under mm:none, drain is the ONLY way to release per-item resources (the queue's <tt class="docutils literal"><span class="pre"><span class="Operator">=</span><span class="Identifier">destroy</span></span></tt> does not touch payload bits — pure bit-transport contract). Under arc / orc / atomicArc / refc, <tt class="docutils literal"><span class="pre"><span class="Operator">=</span><span class="Identifier">destroy</span></span></tt> already runs <tt class="docutils literal"><span class="pre"><span class="Identifier">disposeSlotEncoded</span></span></tt> on abandoned slots (see the <tt class="docutils literal"><span class="pre"><span class="Operator">=</span><span class="Identifier">destroy</span></span></tt> hook above); drain is still useful when the consumer wants ownership of each remaining item rather than letting the destructor walk dispose them.</p>
<p>Per-cardinality dispatch:</p>
<ul class="simple"><li>SPSC + MPSC bounded — drain on bare BQueue (ccCons == ccSingle).</li>
<li>SPMC + MPMC bounded — drain on Bound<a class="reference internal" href="#T, Tag, BQueue[..., ccMulti]">T, Tag, BQueue[..., ccMulti]</a> (mirrors the pop ceremony; the bare BQueue pop is <tt class="docutils literal"><span class="pre"><span class="Punctuation">{</span><span class="Operator">.</span><span class="Identifier">error</span><span class="Operator">.</span><span class="Punctuation">}</span></span></tt> for ccCons == ccMulti, and so is drain).</li>
</ul>
<p>Contract: drain is single-threaded — caller owns the queue exclusively during the drain (no concurrent producers/consumers). Under that contract the multi-consumer CAS-loop in pop always wins on the first try, so drain proceeds linearly. ----------------------------------------------------------------------</p>
NOTE: <tt class="docutils literal"><span class="pre">destroyAndDrain</span></tt> is intentionally NOT provided on Bound endpoints for <tt class="docutils literal"><span class="pre">ccCons == ccMulti</span></tt> arms. The bare queue variable remains in scope behind the Bound endpoint, and its scope-end <tt class="docutils literal"><span class="pre">=destroy</span></tt> would conflict with an explicit destructor call from inside <tt class="docutils literal"><span class="pre">destroyAndDrain</span></tt> (double-destroy at the typestate level). For multi-consumer arms, the canonical pattern is: for item in drain(myBoundConsumer): cleanup(item) # myQueue's scope-end <tt class="docutils literal"><span class="pre"><span class="Operator">=</span><span class="Identifier">destroy</span></span></tt> walks any residual slots Or, after the drain loop, call <tt class="docutils literal"><span class="pre">=destroy</span></tt> on the bare queue explicitly if early teardown is desired.<h1 id="testminusonly-introspection-helpersdot"><center>Test-only introspection helpers.</center></h1>


## Types

### `BQueueLifecycleCtx`

```nim
BQueueLifecycleCtx[T; ccProd; ccCons; N; P; C] = object of RootObj
```

Phantom context type for the BQueue Lifecycle typestate. Never instantiated at runtime; carries the generic param shape so the state types below can <tt class="docutils literal"><span class="pre"><span class="Keyword">distinct</span></span></tt> from it.

### `BQueueInit`

```nim
BQueueInit[T; ccProd; ccCons; N; P; C] = distinct BQueueLifecycleCtx[T, ccProd,
    ccCons, N, P, C]
```

Initial Lifecycle state for a BQueue. Every newly constructed BQueue enters this state via the <tt class="docutils literal"><span class="pre"><span class="Punctuation">{</span><span class="Operator">.</span><span class="Identifier">BQueueLifecycle</span><span class="Punctuation">:</span> <span class="Identifier">BQueueInit</span><span class="Operator">.</span><span class="Punctuation">}</span></span></tt> attachment pragma on the BQueue object below.

### `BQueueDestroyed`

```nim
BQueueDestroyed[T; ccProd; ccCons; N; P; C] = distinct BQueueLifecycleCtx[T,
    ccProd, ccCons, N, P, C]
```

Terminal Lifecycle state for a BQueue. Reached exclusively via the BQueue <tt class="docutils literal"><span class="pre"><span class="Operator">=</span><span class="Identifier">destroy</span></span></tt> destructor's <tt class="docutils literal"><span class="pre"><span class="Identifier">destructorTransition</span></span></tt>.

### `BQueueLifecycleState`

```nim
BQueueLifecycleState = enum
  fsBQueueDestroyed, fsBQueueInit
```

### `BQueueLifecycleStates`

```nim
BQueueLifecycleStates[T; ccProd; ccCons; N; P; C] = BQueueDestroyed[T, ccProd,
    ccCons, N, P, C] |
    BQueueInit[T, ccProd, ccCons, N, P, C]
```

### `BQueue`

```nim
BQueue[T; ccProd; ccCons; N; P; C] {..} = object
  when ccProd == ccSingle and ccCons == ccSingle:
    head* {.align: CacheLineBytes.}: Atomic[int]
    tail* {.align: CacheLineBytes.}: Atomic[int]
    storage*: StorageN1[N, SlotEncoding(T)]
  else:
    head* {.align: CacheLineBytes.}: Atomic[uint64]
    tail* {.align: CacheLineBytes.}: Atomic[uint64]
    cells*: MPMCCellArrayN[N, SlotEncoding(T)]
    when ccProd == ccMulti:
      producerThreadIds*: array[P, Atomic[int]]
    when ccCons == ccMulti:
      consumerThreadIds*: array[C, Atomic[int]]
```

<h1><a class="toc-backref" id="concurrency-topologycolon-bounded-queue-nimbqueue" href="#concurrency-topologycolon-bounded-queue-nimbqueue">Concurrency Topology: Bounded Queue (<tt class="docutils literal"><span class="pre"><span class="Identifier">BQueue</span></span></tt>)</a></h1><table border="1" class="docutils"><tr><th>Dimension</th><th>Specification</th></tr>
<tr><td><strong>Topologies</strong></td><td>SPSC, MPSC, SPMC, MPMC (compile-time cardinality dispatch)</td></tr>
<tr><td><strong>Algorithm</strong></td><td>Dmitry Vyukov Bounded MPMC Queue / Wait-Free Circular Buffer</td></tr>
<tr><td><strong>Capacity</strong></td><td>Fixed compile-time capacity <tt class="docutils literal"><span class="pre"><span class="Identifier">N</span></span></tt> (must be power of two)</td></tr>
<tr><td><strong>Index Synchronization</strong></td><td>Per-slot atomic sequence counters + CacheLine-aligned head/tail</td></tr>
<tr><td><strong>Payload Encoding</strong></td><td>Path-C Type Admission (<tt class="docutils literal"><span class="pre"><span class="Identifier">SlotEncoding</span><span class="Punctuation">(</span><span class="Identifier">T</span><span class="Punctuation">)</span></span></tt>: POD, ManagedRef/Slice)</td></tr>
<tr><td><strong>Progress Guarantee</strong></td><td>Lock-Free (MPMC, MPSC, SPMC) / Wait-Free (SPSC)</td></tr>
<tr><td><strong>Memory Reclamation</strong></td><td>In-place slot reuse (Zero heap allocation, no SMR required)</td></tr>
</table>
<h3><a class="toc-backref" id="concurrency-topologycolon-bounded-queue-nimbqueue-dmitry-vyukov-bounded-mpmc-algorithm" href="#concurrency-topologycolon-bounded-queue-nimbqueue-dmitry-vyukov-bounded-mpmc-algorithm">Dmitry Vyukov Bounded MPMC Algorithm</a></h3><p>For multi-producer and/or multi-consumer topologies (MPMC, MPSC, SPMC), <tt class="docutils literal"><span class="pre"><span class="Identifier">BQueue</span></span></tt> implements Dmitry Vyukov's array-based bounded queue algorithm:</p>
<ul class="simple"><li><strong>Per-Slot Sequence Counters</strong>: Each cell in <tt class="docutils literal"><span class="pre"><span class="Identifier">cells</span></span></tt> contains <tt class="docutils literal"><span class="pre"><span class="Identifier">sequence</span><span class="Punctuation">:</span> <span class="Identifier">Atomic</span><span class="Punctuation">[</span><span class="Identifier">uint64</span><span class="Punctuation">]</span></span></tt> and the slot payload. Sequence numbers track cell generation and lifecycle turns:<ul class="simple"><li>Initial state for slot <tt class="docutils literal"><span class="pre"><span class="Identifier">i</span></span></tt>: <tt class="docutils literal"><span class="pre"><span class="Identifier">sequence</span> <span class="Operator">==</span> <span class="Identifier">i</span></span></tt>.</li>
<li>Enqueue turn at position <tt class="docutils literal"><span class="pre"><span class="Identifier">pos</span></span></tt>: producer checks <tt class="docutils literal"><span class="pre"><span class="Identifier">sequence</span> <span class="Operator">==</span> <span class="Identifier">pos</span></span></tt>. Upon writing, producer advances <tt class="docutils literal"><span class="pre"><span class="Identifier">sequence</span></span></tt> to <tt class="docutils literal"><span class="pre"><span class="Identifier">pos</span> <span class="Operator">+</span> <span class="DecNumber">1</span></span></tt>.</li>
<li>Dequeue turn at position <tt class="docutils literal"><span class="pre"><span class="Identifier">pos</span></span></tt>: consumer checks <tt class="docutils literal"><span class="pre"><span class="Identifier">sequence</span> <span class="Operator">==</span> <span class="Identifier">pos</span> <span class="Operator">+</span> <span class="DecNumber">1</span></span></tt>. Upon reading, consumer resets <tt class="docutils literal"><span class="pre"><span class="Identifier">sequence</span></span></tt> to <tt class="docutils literal"><span class="pre"><span class="Identifier">pos</span> <span class="Operator">+</span> <span class="Identifier">mask</span> <span class="Operator">+</span> <span class="DecNumber">1</span></span></tt>, recycling the slot for the next turn.</li>
</ul>
</li>
<li><strong>Cacheline Separation</strong>: <tt class="docutils literal"><span class="pre"><span class="Identifier">head</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">tail</span></span></tt> indices reside on separate 64/128-byte cachelines (<tt class="docutils literal"><span class="pre"><span class="Identifier">CacheLineBytes</span></span></tt>), eliminating false sharing between producer and consumer cores.</li>
<li><strong>ABA Immunity</strong>: The monotonically advancing sequence counters prevent ABA hazards without requiring Double-Width CAS (DWCAS).</li>
</ul>

<h3><a class="toc-backref" id="concurrency-topologycolon-bounded-queue-nimbqueue-pathminusc-payload-encoding" href="#concurrency-topologycolon-bounded-queue-nimbqueue-pathminusc-payload-encoding">Path-C Payload Encoding</a></h3><p>Managed payload types in Nim (ref types under ARC/ORC, <tt class="docutils literal"><span class="pre"><span class="Identifier">string</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">seq</span></span></tt>) cannot be moved or copied with raw bitwise operations without corrupting ARC/ORC metadata. Path-C payload encoding routes types according to their nature:</p>
<ul class="simple"><li>Raw primitives and POD types are stored directly inline.</li>
<li>Managed ref objects use <tt class="docutils literal"><span class="pre"><span class="Identifier">ManagedRef</span></span></tt> with explicit destructor/refcount tracking.</li>
<li>Strings and seqs utilize <tt class="docutils literal"><span class="pre"><span class="Identifier">ManagedSlice</span></span></tt> with safe dispose hooks.</li>
</ul>
<p>Field-layout split by cardinality:</p>
<ul class="simple"><li>SPSC (<tt class="docutils literal"><span class="pre"><span class="Identifier">ccSingle</span> <span class="Identifier">×</span> <span class="Identifier">ccSingle</span></span></tt>): <tt class="docutils literal"><span class="pre"><span class="Identifier">StorageN1</span><span class="Punctuation">[</span><span class="Identifier">N</span><span class="Punctuation">,</span> <span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> (N+1 slots, no per-slot seq counter); head/tail are <tt class="docutils literal"><span class="pre"><span class="Identifier">Atomic</span><span class="Punctuation">[</span><span class="Identifier">int</span><span class="Punctuation">]</span></span></tt>.</li>
<li>All other bounded shapes (MPSC / SPMC / MPMC): <tt class="docutils literal"><span class="pre"><span class="Identifier">MPMCCellArrayN</span><span class="Punctuation">[</span><span class="Identifier">N</span><span class="Punctuation">,</span> <span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> (Vyukov per-slot seq counters); head/tail are <tt class="docutils literal"><span class="pre"><span class="Identifier">Atomic</span><span class="Punctuation">[</span><span class="Identifier">uint64</span><span class="Punctuation">]</span></span></tt>.</li>
</ul>

### `BoundedQueue`

```nim
BoundedQueue[T; ccProd; ccCons; N; P; C] = BQueue[T, ccProd, ccCons, N, P, C]
```

<h1><a class="toc-backref" id="concurrency-topologycolon-generic-bounded-queue" href="#concurrency-topologycolon-generic-bounded-queue">Concurrency Topology: Generic Bounded Queue</a></h1><p>Ergonomic alias for <tt class="docutils literal"><span class="pre"><span class="Identifier">BQueue</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">,</span> <span class="Identifier">ccProd</span><span class="Punctuation">,</span> <span class="Identifier">ccCons</span><span class="Punctuation">,</span> <span class="Identifier">N</span><span class="Punctuation">,</span> <span class="Identifier">P</span><span class="Punctuation">,</span> <span class="Identifier">C</span><span class="Punctuation">]</span></span></tt>.</p>

### `MpmcBoundedQueue`

```nim
MpmcBoundedQueue[T; N; P; C] = BQueue[T, ccMulti, ccMulti, N, P, C]
```

<h1><a class="toc-backref" id="concurrency-topologycolon-mpmc-bounded-queue" href="#concurrency-topologycolon-mpmc-bounded-queue">Concurrency Topology: MPMC Bounded Queue</a></h1><p>Multi-Producer Multi-Consumer bounded lock-free queue based on Dmitry Vyukov's algorithm.</p>

### `SpscBoundedQueue`

```nim
SpscBoundedQueue[T; N] = BQueue[T, ccSingle, ccSingle, N, 0, 0]
```

<h1><a class="toc-backref" id="concurrency-topologycolon-spsc-bounded-queue" href="#concurrency-topologycolon-spsc-bounded-queue">Concurrency Topology: SPSC Bounded Queue</a></h1><p>Single-Producer Single-Consumer bounded wait-free circular buffer with cacheline separation.</p>

### `MpscBoundedQueue`

```nim
MpscBoundedQueue[T; N; P] = BQueue[T, ccMulti, ccSingle, N, P, 0]
```

<h1><a class="toc-backref" id="concurrency-topologycolon-mpsc-bounded-queue" href="#concurrency-topologycolon-mpsc-bounded-queue">Concurrency Topology: MPSC Bounded Queue</a></h1><p>Multi-Producer Single-Consumer bounded lock-free queue with registered producer threads.</p>

### `SpmcBoundedQueue`

```nim
SpmcBoundedQueue[T; N; C] = BQueue[T, ccSingle, ccMulti, N, 0, C]
```

<h1><a class="toc-backref" id="concurrency-topologycolon-spmc-bounded-queue" href="#concurrency-topologycolon-spmc-bounded-queue">Concurrency Topology: SPMC Bounded Queue</a></h1><p>Single-Producer Multi-Consumer bounded lock-free queue with registered consumer threads.</p>


## Procedures & Functions

### `state`

```nim
proc state[T; ccProd: static PinScopeCardinality;
           ccCons: static PinScopeCardinality; N: static int; P: static int;
           C: static int](f: BQueueDestroyed[T, ccProd, ccCons, N, P, C]): BQueueLifecycleState
```

Runtime state inspection for BQueueDestroyed. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state[T; ccProd: static PinScopeCardinality;
           ccCons: static PinScopeCardinality; N: static int; P: static int;
           C: static int](f: BQueueInit[T, ccProd, ccCons, N, P, C]): BQueueLifecycleState
```

Runtime state inspection for BQueueInit. Returns the enum value for pattern matching in case expressions.

### ``$``

```nim
proc `$`[T; ccProd: static PinScopeCardinality;
         ccCons: static PinScopeCardinality; N: static int; P: static int;
         C: static int](s: BQueueDestroyed[T, ccProd, ccCons, N, P, C]): string
```

String representation for state 'BQueueDestroyed'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`[T; ccProd: static PinScopeCardinality;
         ccCons: static PinScopeCardinality; N: static int; P: static int;
         C: static int](s: BQueueInit[T, ccProd, ccCons, N, P, C]): string
```

String representation for state 'BQueueInit'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`(s: BQueueLifecycleState): string {.raises: [], tags: [], forbids: [].}
```

String representation of BQueueLifecycleState enum. Strips the fs prefix for human-friendly output.

### `validateBQueueParams`

```nim
proc validateBQueueParams[T; ccProd, ccCons: static PinScopeCardinality;
                          N, P, C: static int](
    _: typedesc[BQueue[T, ccProd, ccCons, N, P, C]])
```

Compile-time entry point for BQueue's 4-5 param-coherence guards (subset of ). Invoked implicitly by <tt class="docutils literal"><span class="pre"><span class="Identifier">initBQueue</span></span></tt>; callers may invoke explicitly to exercise the guards in isolation. Has no runtime cost.

### `initBQueue`

```nim
proc initBQueue[T; ccProd, ccCons: static PinScopeCardinality;
                N, P, C: static int](): BQueue[T, ccProd, ccCons, N, P, C]
```

<p>Bounded-queue constructor. Initializes the slot storage, zeroes head/tail, and clears any producer/consumer thread-id registry tables (multi-cardinality only).</p>
<p><tt class="docutils literal"><span class="pre"><span class="Identifier">initBQueue</span></span></tt> is the primitive that returns a freshly cleared <tt class="docutils literal"><span class="pre"><span class="Identifier">BQueue</span></span></tt> value. <tt class="docutils literal"><span class="pre"><span class="Identifier">newBQueue</span></span></tt> is the canonical smart constructor and forwards verbatim — callers should prefer <tt class="docutils literal"><span class="pre"><span class="Identifier">newBQueue</span></span></tt>.</p>

### `newBQueue`

```nim
proc newBQueue[T; ccProd, ccCons: static PinScopeCardinality;
               N, P, C: static int](): BQueue[T, ccProd, ccCons, N, P, C] {.
    inline.}
```

<p>Canonical bounded-queue smart constructor (M4 alias-return lock — returns the user-visible <tt class="docutils literal"><span class="pre"><span class="Identifier">BQueue</span></span></tt> alias, never a backing type).</p>
<p>Forwards to <tt class="docutils literal"><span class="pre"><span class="Identifier">initBQueue</span></span></tt>. The family-named helpers (<tt class="docutils literal"><span class="pre"><span class="Identifier">newSpscQueue</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">newMpscQueue</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">newSpmcQueue</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">newMpmcQueue</span></span></tt>) are thin wrappers around this generic ctor with the cardinality pre-bound; they exist for ergonomic continuity with the v3.x → v4.x naming and minimize churn in the test suite.</p>

### `newSpscQueue`

```nim
proc newSpscQueue[T; N: static int](): BQueue[T, ccSingle, ccSingle, N, 0, 0] {.
    inline.}
```

Bounded spsc-equivalent (<tt class="docutils literal"><span class="pre"><span class="Identifier">ccSingle</span> <span class="Identifier">×</span> <span class="Identifier">ccSingle</span></span></tt>) smart-constructor.

### `newMpscQueue`

```nim
proc newMpscQueue[T; N, P: static int](): BQueue[T, ccMulti, ccSingle, N, P, 0] {.
    inline.}
```

Bounded mpsc-equivalent (<tt class="docutils literal"><span class="pre"><span class="Identifier">ccMulti</span> <span class="Identifier">×</span> <span class="Identifier">ccSingle</span></span></tt>) smart-constructor. <tt class="docutils literal"><span class="pre"><span class="Identifier">P</span></span></tt> is the producer-registry capacity.

### `newSpmcQueue`

```nim
proc newSpmcQueue[T; N, C: static int](): BQueue[T, ccSingle, ccMulti, N, 0, C] {.
    inline.}
```

Bounded spmc-equivalent (<tt class="docutils literal"><span class="pre"><span class="Identifier">ccSingle</span> <span class="Identifier">×</span> <span class="Identifier">ccMulti</span></span></tt>) smart-constructor. <tt class="docutils literal"><span class="pre"><span class="Identifier">C</span></span></tt> is the consumer-registry capacity.

### `newMpmcQueue`

```nim
proc newMpmcQueue[T; N, P, C: static int](): BQueue[T, ccMulti, ccMulti, N, P, C] {.
    inline.}
```

Bounded mpmc-equivalent (<tt class="docutils literal"><span class="pre"><span class="Identifier">ccMulti</span> <span class="Identifier">×</span> <span class="Identifier">ccMulti</span></span></tt>) smart-constructor. <tt class="docutils literal"><span class="pre"><span class="Identifier">P</span></span></tt> is the producer-registry capacity, <tt class="docutils literal"><span class="pre"><span class="Identifier">C</span></span></tt> is the consumer-registry capacity.

### `newBoundedQueue`

```nim
proc newBoundedQueue[T; ccProd, ccCons: static PinScopeCardinality;
                     N, P, C: static int](): BoundedQueue[T, ccProd, ccCons, N,
    P, C] {.inline.}
```

Smart constructor for BoundedQueue.

### `initBoundedQueue`

```nim
proc initBoundedQueue[T; ccProd, ccCons: static PinScopeCardinality;
                      N, P, C: static int](): BoundedQueue[T, ccProd, ccCons, N,
    P, C] {.inline.}
```

Initializes a BoundedQueue.

### `newMpmcBoundedQueue`

```nim
proc newMpmcBoundedQueue[T; N, P, C: static int](): MpmcBoundedQueue[T, N, P, C] {.
    inline.}
```

Smart constructor for MpmcBoundedQueue (Multi-Producer Multi-Consumer).

### `initMpmcBoundedQueue`

```nim
proc initMpmcBoundedQueue[T; N, P, C: static int](): MpmcBoundedQueue[T, N, P, C] {.
    inline.}
```

Initializes an MpmcBoundedQueue (Multi-Producer Multi-Consumer).

### `initBoundedMpmcQueue`

```nim
proc initBoundedMpmcQueue[T; N, P, C: static int](): MpmcBoundedQueue[T, N, P, C] {.
    inline.}
```

Initializes a Bounded MPMC Queue (Multi-Producer Multi-Consumer).

### `newBoundedMpmcQueue`

```nim
proc newBoundedMpmcQueue[T; N, P, C: static int](): MpmcBoundedQueue[T, N, P, C] {.
    inline.}
```

Smart constructor for Bounded MPMC Queue (Multi-Producer Multi-Consumer).

### `newSpscBoundedQueue`

```nim
proc newSpscBoundedQueue[T; N: static int](): SpscBoundedQueue[T, N] {.inline.}
```

Smart constructor for SpscBoundedQueue (Single-Producer Single-Consumer).

### `initSpscBoundedQueue`

```nim
proc initSpscBoundedQueue[T; N: static int](): SpscBoundedQueue[T, N] {.inline.}
```

Initializes an SpscBoundedQueue (Single-Producer Single-Consumer).

### `initBoundedSpscQueue`

```nim
proc initBoundedSpscQueue[T; N: static int](): SpscBoundedQueue[T, N] {.inline.}
```

Initializes a Bounded SPSC Queue (Single-Producer Single-Consumer).

### `newBoundedSpscQueue`

```nim
proc newBoundedSpscQueue[T; N: static int](): SpscBoundedQueue[T, N] {.inline.}
```

Smart constructor for Bounded SPSC Queue (Single-Producer Single-Consumer).

### `newMpscBoundedQueue`

```nim
proc newMpscBoundedQueue[T; N, P: static int](): MpscBoundedQueue[T, N, P] {.
    inline.}
```

Smart constructor for MpscBoundedQueue (Multi-Producer Single-Consumer).

### `initMpscBoundedQueue`

```nim
proc initMpscBoundedQueue[T; N, P: static int](): MpscBoundedQueue[T, N, P] {.
    inline.}
```

Initializes an MpscBoundedQueue (Multi-Producer Single-Consumer).

### `initBoundedMpscQueue`

```nim
proc initBoundedMpscQueue[T; N, P: static int](): MpscBoundedQueue[T, N, P] {.
    inline.}
```

Initializes a Bounded MPSC Queue (Multi-Producer Single-Consumer).

### `newBoundedMpscQueue`

```nim
proc newBoundedMpscQueue[T; N, P: static int](): MpscBoundedQueue[T, N, P] {.
    inline.}
```

Smart constructor for Bounded MPSC Queue (Multi-Producer Single-Consumer).

### `newSpmcBoundedQueue`

```nim
proc newSpmcBoundedQueue[T; N, C: static int](): SpmcBoundedQueue[T, N, C] {.
    inline.}
```

Smart constructor for SpmcBoundedQueue (Single-Producer Multi-Consumer).

### `initSpmcBoundedQueue`

```nim
proc initSpmcBoundedQueue[T; N, C: static int](): SpmcBoundedQueue[T, N, C] {.
    inline.}
```

Initializes an SpmcBoundedQueue (Single-Producer Multi-Consumer).

### `initBoundedSpmcQueue`

```nim
proc initBoundedSpmcQueue[T; N, C: static int](): SpmcBoundedQueue[T, N, C] {.
    inline.}
```

Initializes a Bounded SPMC Queue (Single-Producer Multi-Consumer).

### `newBoundedSpmcQueue`

```nim
proc newBoundedSpmcQueue[T; N, C: static int](): SpmcBoundedQueue[T, N, C] {.
    inline.}
```

Smart constructor for Bounded SPMC Queue (Single-Producer Multi-Consumer).

### `capacity`

```nim
proc capacity[T; ccProd, ccCons: static PinScopeCardinality; N, P, C: static int](
    self: var BQueue[T, ccProd, ccCons, N, P, C]): int {.inline.}
```

Returns the queue's storage capacity (<tt class="docutils literal"><span class="pre"><span class="Identifier">N</span></span></tt>).

### `producerCount`

```nim
proc producerCount[T; ccProd, ccCons: static PinScopeCardinality;
                   N, P, C: static int](self: var BQueue[T, ccProd, ccCons, N,
    P, C]): int {.inline.}
```

Returns the queue's producer-registry capacity (<tt class="docutils literal"><span class="pre"><span class="Identifier">P</span></span></tt>). Single-producer shapes report 0.

### `consumerCount`

```nim
proc consumerCount[T; ccProd, ccCons: static PinScopeCardinality;
                   N, P, C: static int](self: var BQueue[T, ccProd, ccCons, N,
    P, C]): int {.inline.}
```

Returns the queue's consumer-registry capacity (<tt class="docutils literal"><span class="pre"><span class="Identifier">C</span></span></tt>). Single-consumer shapes report 0.

### `push`

```nim
proc push[T; N: static int](self: var BQueue[T, ccSingle, ccSingle, N, 0, 0];
                            item: sink T): bool
```

SPSC single-item push (lock-free; uses the SPSC typestate verbs).

### `push`

```nim
proc push[T; N, C: static int](self: var BQueue[T, ccSingle, ccMulti, N, 0, C];
                               item: sink T): bool
```

SPMC single-item push (defensive CAS, single-producer-side).

### `push`

```nim
proc push[T; ccCons: static PinScopeCardinality; N, P, C: static int](
    self: var BQueue[T, ccMulti, ccCons, N, P, C]; item: T): bool {.error: "Direct push on a multi-producer BQueue is not allowed. Use q.getProducerHere(idx).push(item) (same-thread sugar) or q.getProducer(idx).bindToThread().push(item) (cross-thread) to obtain a per-thread Bound[T, Tag, BQueue[...]] and push through it.".}
```

### `pop`

```nim
proc pop[T; N: static int](self: var BQueue[T, ccSingle, ccSingle, N, 0, 0]): Option[
    T]
```

SPSC single-item pop.

### `pop`

```nim
proc pop[T; N, P: static int](self: var BQueue[T, ccMulti, ccSingle, N, P, 0]): Option[
    T]
```

MPSC single-item pop (defensive CAS, single-consumer-side).

### `pop`

```nim
proc pop[T; ccProd: static PinScopeCardinality; N, P, C: static int](
    self: var BQueue[T, ccProd, ccMulti, N, P, C]): Option[T] {.error: "Direct pop on a multi-consumer BQueue is not allowed. Use q.getConsumerHere(idx).pop() (same-thread sugar) or q.getConsumer(idx).bindToThread().pop() (cross-thread) to obtain a per-thread Bound[T, Tag, BQueue[...]] and pop through it.".}
```

### `popBatch`

```nim
proc popBatch[T; N: static int](self: var BQueue[T, ccSingle, ccSingle, N, 0, 0];
                                dest: var openArray[T]; maxCount: int = -1): int
```

SPSC direct batch pop into a caller-supplied buffer.

### `popBatch`

```nim
proc popBatch[T; N, P: static int](self: var BQueue[T, ccMulti, ccSingle, N, P,
    0]; dest: var openArray[T]; maxCount: int = -1): int
```

MPSC direct batch pop into a caller-supplied buffer.

### `popChunk`

```nim
proc popChunk[T; N: static int](self: var BQueue[T, ccSingle, ccSingle, N, 0, 0];
                                chunkSize: int): seq[T]
```

### `popChunk`

```nim
proc popChunk[T; N, P: static int](self: var BQueue[T, ccMulti, ccSingle, N, P,
    0]; chunkSize: int): seq[T]
```

### `push`

```nim
proc push[T; N: static int](self: var BQueue[T, ccSingle, ccSingle, N, 0, 0];
                            items: openArray[T]): Option[HSlice[int, int]]
```

SPSC batch push.

### `push`

```nim
proc push[T; N, C: static int](self: var BQueue[T, ccSingle, ccMulti, N, 0, C];
                               items: openArray[T]): Option[HSlice[int, int]]
```

SPMC batch push (loop of single-item pushes).

### `push`

```nim
proc push[T; ccCons: static PinScopeCardinality; N, P, C: static int](
    self: var BQueue[T, ccMulti, ccCons, N, P, C]; items: openArray[T]): Option[
    HSlice[int, int]] {.error: "Direct batch push on a multi-producer BQueue is not allowed. Use q.getProducerHere(idx).push(items) (same-thread sugar) or q.getProducer(idx).bindToThread().push(items) (cross-thread) to obtain a per-thread Bound[T, Tag, BQueue[...]] and batch-push through it.".}
```

### `pop`

```nim
proc pop[T; N: static int](self: var BQueue[T, ccSingle, ccSingle, N, 0, 0];
                           count: int): Option[seq[T]]
```

SPSC batch pop.

### `pop`

```nim
proc pop[T; N, P: static int](self: var BQueue[T, ccMulti, ccSingle, N, P, 0];
                              count: int): Option[seq[T]]
```

MPSC batch pop (loop of single-item pops).

### `pop`

```nim
proc pop[T; ccProd: static PinScopeCardinality; N, P, C: static int](
    self: var BQueue[T, ccProd, ccMulti, N, P, C]; count: int): Option[seq[T]] {.error: "Direct batch pop on a multi-consumer BQueue is not allowed. Use q.getConsumerHere(idx).pop(count) (same-thread sugar) or q.getConsumer(idx).bindToThread().pop(count) (cross-thread) to obtain a per-thread Bound[T, Tag, BQueue[...]] and batch-pop through it.".}
```

### ``=destroy``

```nim
proc `=destroy`[T; ccProd, ccCons: static PinScopeCardinality;
                N, P, C: static int](self: var BQueue[T, ccProd, ccCons, N, P, C]) {.transitionError: "BQueue used after =destroy (lifecycle: BQueueInit -> BQueueDestroyed).",
    raises: [], raises: [].}
```

<p>BQueue destructor — drives the Lifecycle terminal transition AND performs the destroy-walk for unpopped slots.</p>
<p>BQueue owns no debra/manager heap state. For POD T the default destructor would suffice. For ref / string / seq T the cells / storage hold <tt class="docutils literal"><span class="pre">SlotEncoding(T)</span></tt> values (ManagedRef or ManagedSlice — <tt class="docutils literal"><span class="pre">distinct uint</span></tt>, no auto-=destroy), so abandoned items must be explicitly disposed here. This is the ONLY library-managed cleanup path (push and pop are pure transfers).</p>

### ``=copy``

```nim
proc `=copy`[T; ccProd, ccCons: static PinScopeCardinality; N, P, C: static int](
    dest: var BQueue[T, ccProd, ccCons, N, P, C];
    source: BQueue[T, ccProd, ccCons, N, P, C]) {.error: "BQueue contains inlined atomic storage and cannot be copied. Pass by `var` or `ptr`.".}
```

### `push`

```nim
proc push[T; Tag: SpscProducerTag | MpmcProducerTag | AnyThreadTag;
          N, P: static int](self: Bound[T, Tag,
                                        BQueue[T, ccMulti, ccSingle, N, P, 0]];
                            item: sink T): bool {.
    tags: [Tag, TypestateOp, RootEffect], raises: [], notATransition.}
```

MPSC single-item push on a Bound producer endpoint.

### `push`

```nim
proc push[T; Tag: SpscProducerTag | MpmcProducerTag | AnyThreadTag;
          N, P, C: static int](self: Bound[T, Tag,
    BQueue[T, ccMulti, ccMulti, N, P, C]]; item: sink T): bool {.
    tags: [Tag, TypestateOp, RootEffect], raises: [], notATransition.}
```

MPMC single-item push on a Bound producer endpoint.

### `pop`

```nim
proc pop[T; Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag;
         N, C: static int](self: Bound[T, Tag,
                                       BQueue[T, ccSingle, ccMulti, N, 0, C]]): Option[
    T] {.tags: [Tag, TypestateOp, RootEffect], raises: [], notATransition.}
```

SPMC single-item pop on a Bound consumer endpoint.

### `pop`

```nim
proc pop[T; Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag;
         N, P, C: static int](self: Bound[T, Tag,
    BQueue[T, ccMulti, ccMulti, N, P, C]]): Option[T] {.
    tags: [Tag, TypestateOp, RootEffect], raises: [], notATransition.}
```

MPMC single-item pop on a Bound consumer endpoint.

### `push`

```nim
proc push[T; Tag: SpscProducerTag | MpmcProducerTag | AnyThreadTag;
          N, P: static int](self: Bound[T, Tag,
                                        BQueue[T, ccMulti, ccSingle, N, P, 0]];
                            items: openArray[T]): Option[HSlice[int, int]] {.
    tags: [Tag, TypestateOp, RootEffect], raises: [], notATransition.}
```

MPSC batch push. Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">none</span></span></tt> if all items pushed; <tt class="docutils literal"><span class="pre"><span class="Identifier">some</span><span class="Punctuation">(</span><span class="Identifier">slice</span><span class="Punctuation">)</span></span></tt> of unpushed indices otherwise.

### `push`

```nim
proc push[T; Tag: SpscProducerTag | MpmcProducerTag | AnyThreadTag;
          N, P, C: static int](self: Bound[T, Tag,
    BQueue[T, ccMulti, ccMulti, N, P, C]]; items: openArray[T]): Option[
    HSlice[int, int]] {.tags: [Tag, TypestateOp, RootEffect], raises: [],
                        notATransition.}
```

MPMC batch push. Same semantics as MPSC variant.

### `pop`

```nim
proc pop[T; Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag;
         N, C: static int](self: Bound[T, Tag,
                                       BQueue[T, ccSingle, ccMulti, N, 0, C]];
                           count: int): Option[seq[T]] {.
    tags: [Tag, TypestateOp, RootEffect], raises: [], notATransition.}
```

SPMC batch pop.

### `pop`

```nim
proc pop[T; Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag;
         N, P, C: static int](self: Bound[T, Tag,
    BQueue[T, ccMulti, ccMulti, N, P, C]]; count: int): Option[seq[T]] {.
    tags: [Tag, TypestateOp, RootEffect], raises: [], notATransition.}
```

MPMC batch pop.

### `popBatch`

```nim
proc popBatch[T; Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag;
              ccProd, ccCons: static PinScopeCardinality; N, P, C: static int](
    self: var Bound[T, Tag, BQueue[T, ccProd, ccCons, N, P, C]];
    dest: var openArray[T]; maxCount: int = -1): int {.
    tags: [Tag, TypestateOp, RootEffect], raises: [], notATransition.}
```

Multi-consumer BQueue batch pop into a caller-supplied openArray buffer. Extracts up to <tt class="docutils literal"><span class="pre"><span class="Identifier">min</span><span class="Punctuation">(</span><span class="Identifier">dest</span><span class="Operator">.</span><span class="Identifier">len</span><span class="Punctuation">,</span> <span class="Identifier">maxCount</span><span class="Punctuation">)</span></span></tt> items without allocating intermediate seqs. Returns the number of items successfully extracted.

### `popBatch`

```nim
proc popBatch[T; Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag;
              ccProd, ccCons: static PinScopeCardinality; N, P, C: static int](
    self: Bound[T, Tag, BQueue[T, ccProd, ccCons, N, P, C]];
    dest: var openArray[T]; maxCount: int = -1): int {.
    tags: [Tag, TypestateOp, RootEffect], raises: [], notATransition.}
```

Multi-consumer BQueue batch pop (value-receiver overload).

### `popChunk`

```nim
proc popChunk[T; Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag;
              ccProd, ccCons: static PinScopeCardinality; N, P, C: static int](
    self: var Bound[T, Tag, BQueue[T, ccProd, ccCons, N, P, C]]; chunkSize: int): seq[
    T] {.tags: [Tag, TypestateOp, RootEffect], raises: [], notATransition.}
```

Extracts a chunk of up to <tt class="docutils literal"><span class="pre"><span class="Identifier">chunkSize</span></span></tt> items into a new seq<a class="reference internal" href="#T">T</a>.

### `popChunk`

```nim
proc popChunk[T; Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag;
              ccProd, ccCons: static PinScopeCardinality; N, P, C: static int](
    self: Bound[T, Tag, BQueue[T, ccProd, ccCons, N, P, C]]; chunkSize: int): seq[
    T] {.tags: [Tag, TypestateOp, RootEffect], raises: [], notATransition.}
```

### `destroyAndDrain`

```nim
proc destroyAndDrain[T; ccProd: static PinScopeCardinality; N, P: static int](
    self: sink BQueue[T, ccProd, ccSingle, N, P, 0];
    cleanup: proc (item: T) {.gcsafe, raises: [].})
```

<p>Drain a single-consumer BQueue (SPSC or MPSC), calling <tt class="docutils literal"><span class="pre"><span class="Identifier">cleanup</span></span></tt> on each remaining item, then trigger queue destruction. Takes <tt class="docutils literal"><span class="pre"><span class="Identifier">sink</span></span></tt> of the queue so the caller's binding is moved-from (preventing scope-end double-destroy on top of the explicit destruction here).</p>
<p>Under mm:none this is the ONLY safe teardown path for a non-empty queue carrying ref / string / seq payloads (strict bit-transport contract). For POD payloads the <tt class="docutils literal"><span class="pre"><span class="Identifier">cleanup</span></span></tt> is logically a no-op.</p>

### `destroyAndDrain`

```nim
proc destroyAndDrain[T; ccProd: static PinScopeCardinality; N, P: static int](
    self: sink BQueue[T, ccProd, ccSingle, N, P, 0])
```

POD discard-callback overload for single-consumer BQueue. Takes <tt class="docutils literal"><span class="pre"><span class="Identifier">sink</span></span></tt> for the same reason as the callback overload. Safe for POD T; for non-POD T the queue's <tt class="docutils literal"><span class="pre"><span class="Operator">=</span><span class="Identifier">destroy</span></span></tt> walk handles disposal under arc/orc/atomicArc/refc — under mm:none, this overload leaks payload bits (the operator must provide an explicit cleanup callback under mm:none for non-POD T).


## Templates

### `assertBQueueParams`

```nim
template assertBQueueParams[T; ccProd, ccCons: static PinScopeCardinality;
                            N, P, C: static int]()
```


## Macros

### `match`

```nim
macro match[T; ccProd: static PinScopeCardinality;
            ccCons: static PinScopeCardinality; N: static int; P: static int;
            C: static int](value: BQueueLifecycleStates[T, ccProd, ccCons, N, P,
    C]; arms: untyped): untyped
```

Single-target pattern match on states of typestate 'BQueueLifecycle'; rewrites to <tt class="docutils literal"><span class="pre"><span class="Keyword">block</span><span class="Punctuation">:</span> <span class="Keyword">let</span> <span class="Keyword">bind</span> <span class="Operator">=</span> <span class="Identifier">move</span><span class="Punctuation">(</span><span class="Identifier">value</span><span class="Punctuation">)</span><span class="Punctuation">;</span> <span class="Identifier">body</span></span></tt>. Syntax is <tt class="docutils literal"><span class="pre"><span class="Operator">&lt;</span><span class="Identifier">StateName</span><span class="Operator">&gt;</span><span class="Punctuation">(</span><span class="Keyword">bind</span><span class="Punctuation">)</span><span class="Punctuation">:</span></span></tt>, with exactly one arm.

### `BQueueLifecycle`

```nim
macro BQueueLifecycle(initial`gensym0: untyped; typeDef`gensym0: untyped): untyped
```

Typestate-attachment pragma (auto-generated; see §3.7 of the v0.9.0 design doc). Apply to a type declaration to bind the type to this typestate with <tt class="docutils literal"><span class="pre"><span class="Identifier">initial</span></span></tt> as the starting state. Validates TA-002..TA-004 at compile time and populates <tt class="docutils literal"><span class="pre"><span class="Identifier">typestateAttachments</span></span></tt>.


## Iterators

### `drain`

```nim
iterator drain[T; ccProd: static PinScopeCardinality; N, P: static int](
    self: var BQueue[T, ccProd, ccSingle, N, P, 0]): T
```

Drain a single-consumer BQueue (SPSC or MPSC). Yields each remaining item until the queue is empty. Calls the existing pop in a loop — Path-C unwrap is already done by pop.

### `drain`

```nim
iterator drain[T; Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag;
               N, C: static int](self: Bound[T, Tag,
    BQueue[T, ccSingle, ccMulti, N, 0, C]]): T
```

Drain an SPMC BQueue via its Bound consumer endpoint.

### `drain`

```nim
iterator drain[T; Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag;
               N, P, C: static int](self: Bound[T, Tag,
    BQueue[T, ccMulti, ccMulti, N, P, C]]): T
```

Drain an MPMC BQueue via its Bound consumer endpoint.

### `items`

```nim
iterator items[T; ccProd: static PinScopeCardinality; N, P: static int](
    self: var BQueue[T, ccProd, ccSingle, N, P, 0]): T
```

Warning: Destructively drains the queue.

### `items`

```nim
iterator items[T; Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag;
               N, C: static int](self: Bound[T, Tag,
    BQueue[T, ccSingle, ccMulti, N, 0, C]]): T
```

Warning: Destructively drains the queue.

### `items`

```nim
iterator items[T; Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag;
               N, P, C: static int](self: Bound[T, Tag,
    BQueue[T, ccMulti, ccMulti, N, P, C]]): T
```

Warning: Destructively drains the queue.

### `pairs`

```nim
iterator pairs[T; ccProd: static PinScopeCardinality; N, P: static int](
    self: var BQueue[T, ccProd, ccSingle, N, P, 0]): (int, T)
```

Warning: Destructively drains the queue.

### `pairs`

```nim
iterator pairs[T; Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag;
               N, C: static int](self: Bound[T, Tag,
    BQueue[T, ccSingle, ccMulti, N, 0, C]]): (int, T)
```

Warning: Destructively drains the queue.

### `pairs`

```nim
iterator pairs[T; Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag;
               N, P, C: static int](self: Bound[T, Tag,
    BQueue[T, ccMulti, ccMulti, N, P, C]]): (int, T)
```

Warning: Destructively drains the queue.

