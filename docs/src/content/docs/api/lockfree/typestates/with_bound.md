---
title: "lockfree/typestates/with_bound"
description: "API reference for lockfree/typestates/with_bound"
---

RAII wrapper template (<tt class="docutils literal"><span class="pre"><span class="Identifier">withBoundEndpoint</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">withBoundProducer</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">withBoundConsumer</span></span></tt>) + <tt class="docutils literal"><span class="pre"><span class="Identifier">Queueable</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> concept per design §5.5.
<h2><a class="toc-backref" id="purpose" href="#purpose">Purpose</a></h2><p>v0.1.0 surfaces two API styles for endpoint binding:</p>
<ol class="simple"><li><strong>Typestate-guarded surface (existing)</strong> — users call <tt class="docutils literal"><span class="pre"><span class="Identifier">q</span><span class="Operator">.</span><span class="Identifier">getProducer</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt>, then <tt class="docutils literal"><span class="pre"><span class="Identifier">bindToThread</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt>, then <tt class="docutils literal"><span class="pre"><span class="Identifier">push</span><span class="Punctuation">(</span><span class="Identifier">item</span><span class="Punctuation">)</span></span></tt>, then <tt class="docutils literal"><span class="pre"><span class="Identifier">close</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt>. The <tt class="docutils literal"><span class="pre"><span class="Identifier">Unbound</span> <span class="Identifier">→</span> <span class="Identifier">Bound</span> <span class="Identifier">→</span> <span class="Identifier">Closed</span></span></tt> typestate FSM is visible and provides compile-time guards (no <tt class="docutils literal"><span class="pre"><span class="Identifier">push</span></span></tt> on <tt class="docutils literal"><span class="pre"><span class="Identifier">Unbound</span></span></tt>, no double bind, no use-after-close).</li>
<li><strong>RAII surface (this module)</strong> — <tt class="docutils literal"><span class="pre"><span class="Identifier">withBoundProducer</span><span class="Punctuation">(</span><span class="Identifier">q</span><span class="Punctuation">,</span> <span class="Identifier">p</span><span class="Punctuation">)</span><span class="Punctuation">:</span> <span class="Identifier">body</span></span></tt> expands to a block that runs <tt class="docutils literal"><span class="pre"><span class="Identifier">getProducer</span> <span class="Operator">+</span> <span class="Identifier">bindToThread</span></span></tt>, executes <tt class="docutils literal"><span class="pre"><span class="Identifier">body</span></span></tt> with <tt class="docutils literal"><span class="pre"><span class="Identifier">p</span></span></tt> bound to the <tt class="docutils literal"><span class="pre"><span class="Identifier">Bound</span><span class="Punctuation">[</span><span class="Operator">...</span><span class="Punctuation">]</span></span></tt> endpoint, and runs <tt class="docutils literal"><span class="pre"><span class="Identifier">close</span></span></tt> on scope exit via <tt class="docutils literal"><span class="pre"><span class="Keyword">defer</span></span></tt>. The typestate FSM still drives the compile-time guards inside <tt class="docutils literal"><span class="pre"><span class="Identifier">body</span></span></tt>; the user just doesn't type the transitions.</li>
</ol>
<p>Both surfaces dispatch to the same per-cardinality push/pop bodies — there is no duplicate implementation. Bug fixes apply uniformly.</p>
<p>The <tt class="docutils literal"><span class="pre"><span class="Identifier">Queueable</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> concept (§5.5.5) is a non-typestate-aware ergonomic surface for library code that wants a single generic <tt class="docutils literal"><span class="pre"><span class="Identifier">Queueable</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>-shaped parameter rather than <tt class="docutils literal"><span class="pre"><span class="Identifier">Queue</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">,</span> <span class="Identifier">ccProd</span><span class="Punctuation">,</span> <span class="Operator">...</span><span class="Punctuation">]</span> <span class="Operator">|</span> <span class="Identifier">BQueue</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">,</span> <span class="Identifier">ccProd</span><span class="Punctuation">,</span> <span class="Operator">...</span><span class="Punctuation">]</span> <span class="Operator">|</span> <span class="Identifier">Bound</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">,</span> <span class="Identifier">Tag</span><span class="Punctuation">,</span> <span class="Identifier">Queue</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">,</span> <span class="Operator">...</span><span class="Punctuation">]</span><span class="Punctuation">]</span></span></tt> enumerated arms. Concept resolution is verified across the full Path-C-encoded payload set (ref X / string / seq<a class="reference internal" href="#U">U</a> / POD T).</p>

<h2><a class="toc-backref" id="pathminusc-transparency-operator-directive-2026minus06minus06" href="#pathminusc-transparency-operator-directive-2026minus06minus06">Path-C transparency (operator directive 2026-06-06)</a></h2><p>Both surfaces work uniformly across <tt class="docutils literal"><span class="pre"><span class="Keyword">ref</span> <span class="Identifier">X</span></span></tt> (via ManagedRef), <tt class="docutils literal"><span class="pre"><span class="Identifier">string</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">seq</span><span class="Punctuation">[</span><span class="Identifier">U</span><span class="Punctuation">]</span></span></tt> (via ManagedSlice), and POD T. The Path-C encoding routing happens INSIDE the existing per-cardinality push/pop bodies; this module never touches encoded slots. Users see <tt class="docutils literal"><span class="pre"><span class="Identifier">Queue</span><span class="Punctuation">[</span><span class="Keyword">ref</span> <span class="Identifier">Foo</span><span class="Punctuation">]</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">Queue</span><span class="Punctuation">[</span><span class="Identifier">string</span><span class="Punctuation">]</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">Queue</span><span class="Punctuation">[</span><span class="Identifier">seq</span><span class="Punctuation">[</span><span class="Identifier">int</span><span class="Punctuation">]</span><span class="Punctuation">]</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">Queue</span><span class="Punctuation">[</span><span class="Identifier">int</span><span class="Punctuation">]</span></span></tt> with the same surface regardless of which API style they choose.</p>


## Types

### `Queueable`

```nim
Queueable[T] = concept x
    var qref: typeof(x)
    push(qref, default(T)) is bool
    pop(qref) is Option[T]
```

Type-class for &quot;anything queue-like accepting / yielding <tt class="docutils literal"><span class="pre"><span class="Identifier">T</span></span></tt>&quot;.

### `Stackable`

```nim
Stackable[T] = concept x
    var sref: typeof(x)
    compiles(sref.push(default(T)))
    pop(sref) is Option[T]
    peek(sref) is Option[T]
```

Type-class for LIFO stacks (<tt class="docutils literal"><span class="pre"><span class="Identifier">TreiberStack</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">BStack</span></span></tt>) supporting <tt class="docutils literal"><span class="pre"><span class="Identifier">push</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">pop</span></span></tt>, and <tt class="docutils literal"><span class="pre"><span class="Identifier">peek</span></span></tt>.

### `Stealable`

```nim
Stealable[T] = concept x
    var dref: typeof(x)
    steal(dref) is Option[T]
```

Type-class for work-stealing deques (<tt class="docutils literal"><span class="pre"><span class="Identifier">ChaseLevDeque</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">Bound</span><span class="Punctuation">[</span><span class="Operator">...</span><span class="Punctuation">,</span> <span class="Identifier">DequeThiefTag</span><span class="Punctuation">,</span> <span class="Identifier">ChaseLevDeque</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span><span class="Punctuation">]</span></span></tt>) supporting <tt class="docutils literal"><span class="pre"><span class="Identifier">steal</span></span></tt>.

### `TableReadable`

```nim
TableReadable[K; V] = concept x
    var tref: typeof(x)
    get(tref, default(K)) is Option[V]
    contains(tref, default(K)) is bool
```

Type-class for concurrent hash tables and bound reader/writer endpoints supporting <tt class="docutils literal"><span class="pre"><span class="Identifier">get</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">contains</span></span></tt>.

### `TableWritable`

```nim
TableWritable[K; V] = concept x
    var tref: typeof(x)
    put(tref, default(K), default(V)) is bool
    get(tref, default(K)) is Option[V]
    remove(tref, default(K)) is bool
```

Type-class for concurrent hash tables and bound writer endpoints supporting <tt class="docutils literal"><span class="pre"><span class="Identifier">put</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">get</span></span></tt>, and <tt class="docutils literal"><span class="pre"><span class="Identifier">remove</span></span></tt>.


## Templates

### `withBoundProducer`

```nim
template withBoundProducer[T; ccCons: static PinScopeCardinality;
                           N, P, C: static int](
    queue: var BQueue[T, ccMulti, ccCons, N, P, C]; endpoint: untyped;
    body: untyped): untyped
```

BQueue multi-producer RAII wrapper. Acquires a per-thread producer slot, transitions to <tt class="docutils literal"><span class="pre"><span class="Identifier">Bound</span></span></tt>, runs <tt class="docutils literal"><span class="pre"><span class="Identifier">body</span></span></tt>, then transitions to <tt class="docutils literal"><span class="pre"><span class="Identifier">EndpointClosed</span></span></tt> on scope exit.

### `withBoundConsumer`

```nim
template withBoundConsumer[T; ccProd: static PinScopeCardinality;
                           N, P, C: static int](
    queue: var BQueue[T, ccProd, ccMulti, N, P, C]; endpoint: untyped;
    body: untyped): untyped
```

BQueue multi-consumer RAII wrapper. Symmetric to <tt class="docutils literal"><span class="pre"><span class="Identifier">withBoundProducer</span></span></tt>.

### `withBoundProducer`

```nim
template withBoundProducer[T; ccProd, ccCons: static PinScopeCardinality;
                           ST: static DeallocationStrategy;
                           S, MaxThreads: static int](
    queue: var Queue[T, ccProd, ccCons, ST, S, MaxThreads]; endpoint: untyped;
    body: untyped): untyped
```

Queue producer RAII wrapper. Covers all four cardinality arms (SPSC / MPSC / SPMC / MPMC) — <tt class="docutils literal"><span class="pre"><span class="Identifier">getProducer</span></span></tt> on <tt class="docutils literal"><span class="pre"><span class="Identifier">Queue</span></span></tt> is defined uniformly in <tt class="docutils literal"><span class="pre"><span class="Identifier">endpoint</span><span class="Operator">.</span><span class="Identifier">nim</span></span></tt>. SPSC absorbed arm (ccProd == ccSingle and ccCons == ccSingle) is debra-free, so <tt class="docutils literal"><span class="pre"><span class="Identifier">bindToThread</span></span></tt> is a no-op there; the template's shape is unchanged.

### `withBoundConsumer`

```nim
template withBoundConsumer[T; ccProd, ccCons: static PinScopeCardinality;
                           ST: static DeallocationStrategy;
                           S, MaxThreads: static int](
    queue: var Queue[T, ccProd, ccCons, ST, S, MaxThreads]; endpoint: untyped;
    body: untyped): untyped
```

Queue consumer RAII wrapper. Symmetric to <tt class="docutils literal"><span class="pre"><span class="Identifier">withBoundProducer</span></span></tt>.

### `withBoundProducer`

```nim
template withBoundProducer[T](stack: var TreiberStack[T]; endpoint: untyped;
                              body: untyped): untyped
```

TreiberStack producer RAII wrapper. Registers the calling thread with the stack's NEBR manager on entry and unregisters on scope exit.

### `withBoundConsumer`

```nim
template withBoundConsumer[T](stack: var TreiberStack[T]; endpoint: untyped;
                              body: untyped): untyped
```

TreiberStack consumer RAII wrapper. Registers the calling thread with the stack's NEBR manager on entry and unregisters on scope exit.

### `withBoundProducer`

```nim
template withBoundProducer[T; Cap: static int;
                           ccProd, ccCons: static PinScopeCardinality](
    stack: var BStack[T, Cap, ccProd, ccCons]; endpoint: untyped; body: untyped): untyped
```

BStack producer RAII wrapper.

### `withBoundConsumer`

```nim
template withBoundConsumer[T; Cap: static int;
                           ccProd, ccCons: static PinScopeCardinality](
    stack: var BStack[T, Cap, ccProd, ccCons]; endpoint: untyped; body: untyped): untyped
```

BStack consumer RAII wrapper.

### `withBoundOwner`

```nim
template withBoundOwner[T](deque: var ChaseLevDeque[T]; endpoint: untyped;
                           body: untyped): untyped
```

ChaseLevDeque owner-worker RAII wrapper (<tt class="docutils literal"><span class="pre"><span class="Identifier">pushBottom</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">popBottom</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">tryPopBottom</span></span></tt>).

### `withBoundThief`

```nim
template withBoundThief[T](deque: var ChaseLevDeque[T]; endpoint: untyped;
                           body: untyped): untyped
```

ChaseLevDeque thief RAII wrapper (<tt class="docutils literal"><span class="pre"><span class="Identifier">steal</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">trySteal</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">stealBatch</span></span></tt>).

### `withBoundProducer`

```nim
template withBoundProducer[T](deque: var ChaseLevDeque[T]; endpoint: untyped;
                              body: untyped): untyped
```

### `withBoundConsumer`

```nim
template withBoundConsumer[T](deque: var ChaseLevDeque[T]; endpoint: untyped;
                              body: untyped): untyped
```

### `withBoundWriter`

```nim
template withBoundWriter[K, V; Cap: static int;
                         ccProd, ccCons: static PinScopeCardinality](
    table: var BTable[K, V, Cap, ccProd, ccCons]; endpoint: untyped;
    body: untyped): untyped
```

BTable writer RAII wrapper (permits both mutations and lookups).

### `withBoundReader`

```nim
template withBoundReader[K, V; Cap: static int;
                         ccProd, ccCons: static PinScopeCardinality](
    table: var BTable[K, V, Cap, ccProd, ccCons]; endpoint: untyped;
    body: untyped): untyped
```

BTable reader RAII wrapper (permits read-only lookups; rejects mutations at compile time).

### `withBoundProducer`

```nim
template withBoundProducer[K, V; Cap: static int;
                           ccProd, ccCons: static PinScopeCardinality](
    table: var BTable[K, V, Cap, ccProd, ccCons]; endpoint: untyped;
    body: untyped): untyped
```

### `withBoundConsumer`

```nim
template withBoundConsumer[K, V; Cap: static int;
                           ccProd, ccCons: static PinScopeCardinality](
    table: var BTable[K, V, Cap, ccProd, ccCons]; endpoint: untyped;
    body: untyped): untyped
```

### `withBoundEndpoint`

```nim
template withBoundEndpoint(queue, endpoint, body: untyped): untyped
```

WARNING: this umbrella alias ALWAYS binds a PRODUCER endpoint (it forwards to withBoundProducer). A consumer-intent call here will SILENTLY acquire a producer slot — there is no role auto-detection. For a consumer endpoint you MUST call withBoundConsumer explicitly. The producer/consumer dispatch (getProducer vs getConsumer) cannot be inferred from the queue type alone, so this alias hard-codes the producer role.

