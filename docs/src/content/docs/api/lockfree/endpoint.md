---
title: "lockfree/endpoint"
description: "API reference for lockfree/endpoint"
---

<p>Endpoint types for static thread-affinity.</p>
<p><strong>Lifecycle vs role — orthogonal layers.</strong> <tt class="docutils literal"><span class="pre"><span class="Identifier">Endpoint</span></span></tt> is the typestate for endpoint LIFECYCLE only: <tt class="docutils literal"><span class="pre"><span class="Identifier">Unbound</span> <span class="Operator">-&gt;</span> <span class="Identifier">Bound</span> <span class="Operator">-&gt;</span> <span class="Identifier">Closed</span></span></tt>. ROLE is carried via the <tt class="docutils literal"><span class="pre"><span class="Identifier">Tag</span></span></tt> generic parameter — one of <tt class="docutils literal"><span class="pre"><span class="Identifier">SpscProducerTag</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">SpscConsumerTag</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">MpmcProducerTag</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">MpmcConsumerTag</span></span></tt> (all in <tt class="docutils literal"><span class="pre"><span class="Identifier">role_tags</span><span class="Operator">.</span><span class="Identifier">nim</span></span></tt>), or <tt class="docutils literal"><span class="pre"><span class="Identifier">AnyThreadTag</span></span></tt> for the same-thread shortcut path explicitly chosen by <tt class="docutils literal"><span class="pre"><span class="Identifier">getProducerHere</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">getConsumerHere</span></span></tt> call sites. <tt class="docutils literal"><span class="pre"><span class="Identifier">Tag</span></span></tt> distinctness is enforced at compile time via the <tt class="docutils literal"><span class="pre"><span class="Punctuation">{</span><span class="Operator">.</span><span class="Identifier">tags</span><span class="Punctuation">:</span> <span class="Punctuation">[</span><span class="Identifier">TagType</span><span class="Punctuation">,</span> <span class="Identifier">TypestateOp</span><span class="Punctuation">]</span><span class="Operator">.</span><span class="Punctuation">}</span></span></tt> effect pragma on <tt class="docutils literal"><span class="pre"><span class="Identifier">push</span></span></tt>/<tt class="docutils literal"><span class="pre"><span class="Identifier">pop</span></span></tt> procs plus <tt class="docutils literal"><span class="pre"><span class="Punctuation">{</span><span class="Operator">.</span><span class="Identifier">forbids</span><span class="Punctuation">:</span> <span class="Punctuation">[</span><span class="Operator">...</span><span class="Punctuation">]</span><span class="Operator">.</span><span class="Punctuation">}</span></span></tt> regions; the typestate FSM here carries no role information.</p>
<p><strong>Backend specialisation via type-class overloads.</strong> Gating <tt class="docutils literal"><span class="pre"><span class="Identifier">handle</span><span class="Punctuation">:</span> <span class="Identifier">ThreadHandle</span><span class="Punctuation">[</span><span class="Operator">...</span><span class="Punctuation">]</span></span></tt> and the <tt class="docutils literal"><span class="pre"><span class="Identifier">registerThread</span></span></tt>/<tt class="docutils literal"><span class="pre"><span class="Identifier">unregisterThread</span></span></tt> calls via <tt class="docutils literal"><span class="pre"><span class="Keyword">when</span> <span class="Identifier">queueT</span> <span class="Keyword">is</span> <span class="Identifier">Queue</span><span class="Punctuation">:</span></span></tt> does not work: Nim 2.2's eager generic resolution rejects <tt class="docutils literal"><span class="pre"><span class="Keyword">is</span> <span class="Identifier">Queue</span></span></tt> on the 6-static-param <tt class="docutils literal"><span class="pre"><span class="Identifier">Queue</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">,</span> <span class="Identifier">ccProd</span><span class="Punctuation">,</span> <span class="Identifier">ccCons</span><span class="Punctuation">,</span> <span class="Identifier">ST</span><span class="Punctuation">,</span> <span class="Identifier">S</span><span class="Punctuation">,</span> <span class="Identifier">MaxThreads</span><span class="Punctuation">]</span></span></tt> without bound arguments. Instead, <tt class="docutils literal"><span class="pre"><span class="Keyword">concept</span> <span class="Identifier">BQueueType</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">QueueType</span></span></tt> type-class match on overloaded helper procs. The handle storage lives unconditionally on <tt class="docutils literal"><span class="pre"><span class="Identifier">Bound</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">Closed</span></span></tt> (opaque <tt class="docutils literal"><span class="pre"><span class="Identifier">manager</span><span class="Punctuation">:</span> <span class="Identifier">pointer</span></span></tt> + <tt class="docutils literal"><span class="pre"><span class="Identifier">handleIdx</span><span class="Punctuation">:</span> <span class="Identifier">int</span></span></tt>), with the Queue overloads casting back to <tt class="docutils literal"><span class="pre"><span class="Identifier">ThreadHandle</span><span class="Punctuation">[</span><span class="Identifier">MaxThreads</span><span class="Punctuation">,</span> <span class="Identifier">CC</span><span class="Punctuation">]</span></span></tt> at the call site where queueT is concrete. The 16-byte cost on BQueue endpoints is the tradeoff for keeping the typestate axis at 3 generic params and the API uniform.</p>
<p><strong>Single Endpoint typestate.</strong> Two parallel typestates <tt class="docutils literal"><span class="pre"><span class="Identifier">ProducerEndpoint</span></span></tt> + <tt class="docutils literal"><span class="pre"><span class="Identifier">ConsumerEndpoint</span></span></tt> with identical state sets are not viable: typestates 0.12.0 TA-004 forbids sharing state types across typestates. The typestates are merged into a single <tt class="docutils literal"><span class="pre"><span class="Identifier">Endpoint</span></span></tt> — role lives in <tt class="docutils literal"><span class="pre"><span class="Identifier">Tag</span></span></tt>, lifecycle in <tt class="docutils literal"><span class="pre"><span class="Identifier">Endpoint</span></span></tt>.</p>
<p><strong>Fallback:</strong> if the three-axis generic typestate trips a further nim-typestates corner case, drop <tt class="docutils literal"><span class="pre"><span class="Identifier">queueT</span></span></tt> from the typestate axis and store it as a non-typestate field.</p>
<pre>----------------------------------------------------------------------
Same-thread shortcut helpers + bindConsumer one-shot wrapper.

These templates/procs live here (next to getProducer/getConsumer) so they
bind against THIS module's factories rather than any locally-shadowing
factory the user's expansion site might have declared (e.g. bench-adapter
modules define their own `getConsumer` returning adapter-local view types).
----------------------------------------------------------------------</pre>
---------------------------------------------------------------------- Alias-analysis constraint (Nim Issue #19013): <tt class="docutils literal"><span class="pre"><span class="Identifier">Unbound</span></span></tt> MUST be a thin <tt class="docutils literal"><span class="pre"><span class="Keyword">ptr</span></span></tt> wrapper over the queue with no ref/string/seq/closure subgraph. <tt class="docutils literal"><span class="pre"><span class="Identifier">system</span><span class="Operator">.</span><span class="Identifier">supportsCopyMem</span></span></tt> returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt> iff the type has no GC'd subgraph; static-assert that the actual queue families pass. ----------------------------------------------------------------------typestates verified


## Types

### `BQueueType`

```nim
BQueueType = concept x
    x is BQueue
```

Type class matching any <tt class="docutils literal"><span class="pre"><span class="Identifier">BQueue</span><span class="Punctuation">[</span><span class="Operator">...</span><span class="Punctuation">]</span></span></tt> instantiation. Used to dispatch the no-op backend overloads (BQueue endpoints carry no debra registration).

### `QueueType`

```nim
QueueType = concept x
    x is Queue
```

Type class matching any <tt class="docutils literal"><span class="pre"><span class="Identifier">Queue</span><span class="Punctuation">[</span><span class="Operator">...</span><span class="Punctuation">]</span></span></tt> instantiation. Used to dispatch the debra-integrated backend overloads (Queue endpoints call <tt class="docutils literal"><span class="pre"><span class="Identifier">registerThread</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">unregisterThread</span></span></tt>).

### `TreiberStackType`

```nim
TreiberStackType = concept x
    x is TreiberStack
```

Type class matching any <tt class="docutils literal"><span class="pre"><span class="Identifier">TreiberStack</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> instantiation. Dispatches to <tt class="docutils literal"><span class="pre"><span class="Identifier">stack</span><span class="Operator">.</span><span class="Identifier">registerThread</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">stack</span><span class="Operator">.</span><span class="Identifier">unregisterThread</span></span></tt> to maintain TLS NEBR handle coherence.

### `BStackType`

```nim
BStackType = concept x
    x is BStack
```

Type class matching any <tt class="docutils literal"><span class="pre"><span class="Identifier">BStack</span><span class="Punctuation">[</span><span class="Operator">...</span><span class="Punctuation">]</span></span></tt> instantiation (zero-SMR preallocated).

### `ChaseLevDequeType`

```nim
ChaseLevDequeType = concept x
    x is ChaseLevDeque
```

Type class matching any <tt class="docutils literal"><span class="pre"><span class="Identifier">ChaseLevDeque</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> instantiation.

### `BTableType`

```nim
BTableType = concept x
    x is BTable
```

Type class matching any <tt class="docutils literal"><span class="pre"><span class="Identifier">BTable</span><span class="Punctuation">[</span><span class="Operator">...</span><span class="Punctuation">]</span></span></tt> instantiation (zero-SMR preallocated).

### `EndpointState`

```nim
EndpointState = enum
  fsUnbound, fsBound, fsEndpointClosed
```

### `EndpointStates`

```nim
EndpointStates[T; Tag; queueT] = Unbound[T, Tag, queueT] | Bound[T, Tag, queueT] |
    EndpointClosed[T, Tag, queueT]
```


## Procedures & Functions

### `state`

```nim
proc state[T; Tag; queueT](f: Unbound[T, Tag, queueT]): EndpointState
```

Runtime state inspection for Unbound. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state[T; Tag; queueT](f: Bound[T, Tag, queueT]): EndpointState
```

Runtime state inspection for Bound. Returns the enum value for pattern matching in case expressions.

### `state`

```nim
proc state[T; Tag; queueT](f: EndpointClosed[T, Tag, queueT]): EndpointState
```

Runtime state inspection for EndpointClosed. Returns the enum value for pattern matching in case expressions.

### ``$``

```nim
proc `$`[T; Tag; queueT](s: Unbound[T, Tag, queueT]): string
```

String representation for state 'Unbound'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`[T; Tag; queueT](s: Bound[T, Tag, queueT]): string
```

String representation for state 'Bound'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`[T; Tag; queueT](s: EndpointClosed[T, Tag, queueT]): string
```

String representation for state 'EndpointClosed'. Returns the bare state name (no fs prefix).

### ``$``

```nim
proc `$`(s: EndpointState): string {.raises: [], tags: [], forbids: [].}
```

String representation of EndpointState enum. Strips the fs prefix for human-friendly output.

### `bindToThread`

```nim
proc bindToThread[T; Tag; queueT](u: sink Unbound[T, Tag, queueT]): Bound[T,
    Tag, queueT] {.tags: [Tag, TypestateOp, RootEffect], gcsafe, raises: [].}
```

<p>Bind the endpoint to the calling thread.</p>
<p>The sugar pragma <tt class="docutils literal"><span class="pre"><span class="Punctuation">{</span><span class="Operator">.</span><span class="Identifier">transition</span><span class="Punctuation">(</span><span class="Identifier">tag</span><span class="Punctuation">:</span> <span class="Operator">...</span><span class="Punctuation">)</span><span class="Operator">.</span><span class="Punctuation">}</span></span></tt> is not usable here: the Nim parser rejects the <tt class="docutils literal"><span class="pre"><span class="Identifier">nkObjConstr</span></span></tt> pragma form and it conflates value-typestate with proc-effect. The explicit composed form above is the only available shape.</p>

### `close`

```nim
proc close[T; Tag; queueT](b: sink Bound[T, Tag, queueT]): EndpointClosed[T,
    Tag, queueT] {.tags: [Tag, TypestateOp, RootEffect], gcsafe, raises: [].}
```

Release the endpoint. Queue endpoints call <tt class="docutils literal"><span class="pre"><span class="Identifier">unregisterThread</span></span></tt>; BQueue endpoints are a no-op.

### `getProducer`

```nim
proc getProducer[T; ccCons: static PinScopeCardinality; N, P, C: static int](
    self: var BQueue[T, ccMulti, ccCons, N, P, C]; idx: int = -1): Unbound[T,
    AnyThreadTag, BQueue[T, ccMulti, ccCons, N, P, C]] {.
    raises: [NoProducersAvailableError].}
```

<p>Reserve a per-thread producer slot on a multi-producer <tt class="docutils literal"><span class="pre"><span class="Identifier">BQueue</span></span></tt> and return an <tt class="docutils literal"><span class="pre"><span class="Identifier">Unbound</span></span></tt> endpoint owning that slot. The caller transitions the endpoint to <tt class="docutils literal"><span class="pre"><span class="Identifier">Bound</span></span></tt> via <tt class="docutils literal"><span class="pre"><span class="Identifier">bindToThread</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt> before any <tt class="docutils literal"><span class="pre"><span class="Identifier">push</span></span></tt>.</p>
<p>When <tt class="docutils literal"><span class="pre"><span class="Identifier">idx</span> <span class="Operator">&gt;=</span> <span class="DecNumber">0</span></span></tt>, the caller pins a specific slot (testing). When <tt class="docutils literal"><span class="pre"><span class="Identifier">idx</span> <span class="Operator">==</span> <span class="Operator">-</span><span class="DecNumber">1</span></span></tt>, the calling thread's <tt class="docutils literal"><span class="pre"><span class="Identifier">getThreadId</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt> claims the first free slot via CAS over <tt class="docutils literal"><span class="pre"><span class="Identifier">producerThreadIds</span></span></tt>.</p>

### `getConsumer`

```nim
proc getConsumer[T; ccProd: static PinScopeCardinality; N, P, C: static int](
    self: var BQueue[T, ccProd, ccMulti, N, P, C]; idx: int = -1): Unbound[T,
    AnyThreadTag, BQueue[T, ccProd, ccMulti, N, P, C]] {.
    raises: [NoConsumersAvailableError].}
```

Reserve a per-thread consumer slot on a multi-consumer <tt class="docutils literal"><span class="pre"><span class="Identifier">BQueue</span></span></tt> and return an <tt class="docutils literal"><span class="pre"><span class="Identifier">Unbound</span></span></tt> endpoint. Symmetric to <tt class="docutils literal"><span class="pre"><span class="Identifier">getProducer</span></span></tt>; the caller must <tt class="docutils literal"><span class="pre"><span class="Identifier">bindToThread</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt> before any <tt class="docutils literal"><span class="pre"><span class="Identifier">pop</span></span></tt>.

### `getProducer`

```nim
proc getProducer[T; ccProd, ccCons: static PinScopeCardinality;
                 ST: static DeallocationStrategy; S, MaxThreads: static int](
    self: var Queue[T, ccProd, ccCons, ST, S, MaxThreads]): Unbound[T,
    AnyThreadTag, Queue[T, ccProd, ccCons, ST, S, MaxThreads]] {.raises: [].}
```

Queue-flavour producer factory. For <tt class="docutils literal"><span class="pre"><span class="Identifier">ccProd</span> <span class="Operator">==</span> <span class="Identifier">ccMulti</span></span></tt> the endpoint reserves a producer index against the queue's <tt class="docutils literal"><span class="pre"><span class="Identifier">producerCount</span></span></tt> atomic; debra registration happens later at <tt class="docutils literal"><span class="pre"><span class="Identifier">bindToThread</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt> via the QueueType overload of <tt class="docutils literal"><span class="pre"><span class="Identifier">onBind</span></span></tt>. For <tt class="docutils literal"><span class="pre"><span class="Identifier">ccProd</span> <span class="Operator">==</span> <span class="Identifier">ccSingle</span></span></tt> (SPSC / SPMC) the endpoint carries no meaningful index (set to <tt class="docutils literal"><span class="pre"><span class="Operator">-</span><span class="DecNumber">1</span></span></tt>) and <tt class="docutils literal"><span class="pre"><span class="Identifier">bindToThread</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt> is a no-op (debra-free SPSC absorbed body has no manager — gated by <tt class="docutils literal"><span class="pre"><span class="Keyword">when</span> <span class="Identifier">compiles</span><span class="Punctuation">(</span><span class="Identifier">b</span><span class="Operator">.</span><span class="Identifier">queue</span><span class="Operator">.</span><span class="Identifier">manager</span><span class="Punctuation">)</span></span></tt>).

### `getConsumer`

```nim
proc getConsumer[T; ccProd, ccCons: static PinScopeCardinality;
                 ST: static DeallocationStrategy; S, MaxThreads: static int](
    self: var Queue[T, ccProd, ccCons, ST, S, MaxThreads]): Unbound[T,
    AnyThreadTag, Queue[T, ccProd, ccCons, ST, S, MaxThreads]] {.raises: [].}
```

Queue-flavour consumer factory. Symmetric to <tt class="docutils literal"><span class="pre"><span class="Identifier">getProducer</span></span></tt>; for <tt class="docutils literal"><span class="pre"><span class="Identifier">ccCons</span> <span class="Operator">==</span> <span class="Identifier">ccMulti</span></span></tt> reserves a slot via <tt class="docutils literal"><span class="pre"><span class="Identifier">consumerCount</span></span></tt>; for <tt class="docutils literal"><span class="pre"><span class="Identifier">ccCons</span> <span class="Operator">==</span> <span class="Identifier">ccSingle</span></span></tt> the endpoint carries no meaningful index.

### `getProducer`

```nim
proc getProducer[T](self: var TreiberStack[T]): Unbound[T, MpmcProducerTag,
    TreiberStack[T]] {.raises: [], notATransition.}
```

TreiberStack producer factory. Returns an <tt class="docutils literal"><span class="pre"><span class="Identifier">Unbound</span></span></tt> producer endpoint that registers the calling thread with the stack's NEBR manager on <tt class="docutils literal"><span class="pre"><span class="Identifier">bindToThread</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt>.

### `getConsumer`

```nim
proc getConsumer[T](self: var TreiberStack[T]): Unbound[T, MpmcConsumerTag,
    TreiberStack[T]] {.raises: [], notATransition.}
```

TreiberStack consumer factory. Returns an <tt class="docutils literal"><span class="pre"><span class="Identifier">Unbound</span></span></tt> consumer endpoint that registers the calling thread with the stack's NEBR manager on <tt class="docutils literal"><span class="pre"><span class="Identifier">bindToThread</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt>.

### `getProducer`

```nim
proc getProducer[T; Cap: static int; ccProd, ccCons: static PinScopeCardinality](
    self: var BStack[T, Cap, ccProd, ccCons]): Unbound[T, MpmcProducerTag,
    BStack[T, Cap, ccProd, ccCons]] {.raises: [], notATransition.}
```

BStack producer factory.

### `getConsumer`

```nim
proc getConsumer[T; Cap: static int; ccProd, ccCons: static PinScopeCardinality](
    self: var BStack[T, Cap, ccProd, ccCons]): Unbound[T, MpmcConsumerTag,
    BStack[T, Cap, ccProd, ccCons]] {.raises: [], notATransition.}
```

BStack consumer factory.

### `getOwner`

```nim
proc getOwner[T](self: var ChaseLevDeque[T]): Unbound[T, DequeOwnerTag,
    ChaseLevDeque[T]] {.raises: [], notATransition.}
```

ChaseLevDeque owner-worker factory (<tt class="docutils literal"><span class="pre"><span class="Identifier">pushBottom</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">popBottom</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">tryPopBottom</span></span></tt>).

### `getThief`

```nim
proc getThief[T](self: var ChaseLevDeque[T]): Unbound[T, DequeThiefTag,
    ChaseLevDeque[T]] {.raises: [], notATransition.}
```

ChaseLevDeque thief factory (<tt class="docutils literal"><span class="pre"><span class="Identifier">steal</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">trySteal</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">stealBatch</span></span></tt>).

### `getProducer`

```nim
proc getProducer[T](self: var ChaseLevDeque[T]): Unbound[T, DequeOwnerTag,
    ChaseLevDeque[T]] {.inline, raises: [], notATransition.}
```

### `getConsumer`

```nim
proc getConsumer[T](self: var ChaseLevDeque[T]): Unbound[T, DequeThiefTag,
    ChaseLevDeque[T]] {.inline, raises: [], notATransition.}
```

### `getWriter`

```nim
proc getWriter[K, V; Cap: static int; ccProd, ccCons: static PinScopeCardinality](
    self: var BTable[K, V, Cap, ccProd, ccCons]): Unbound[(K, V),
    TableWriterTag, BTable[K, V, Cap, ccProd, ccCons]] {.raises: [],
    notATransition.}
```

BTable writer endpoint factory (permits both mutations and lookups).

### `getReader`

```nim
proc getReader[K, V; Cap: static int; ccProd, ccCons: static PinScopeCardinality](
    self: var BTable[K, V, Cap, ccProd, ccCons]): Unbound[(K, V),
    TableReaderTag, BTable[K, V, Cap, ccProd, ccCons]] {.raises: [],
    notATransition.}
```

BTable reader endpoint factory (permits read-only lookups; rejects mutations at compile time).

### `getProducer`

```nim
proc getProducer[K, V; Cap: static int;
                 ccProd, ccCons: static PinScopeCardinality](
    self: var BTable[K, V, Cap, ccProd, ccCons]): Unbound[(K, V),
    TableWriterTag, BTable[K, V, Cap, ccProd, ccCons]] {.inline, raises: [],
    notATransition.}
```

### `getConsumer`

```nim
proc getConsumer[K, V; Cap: static int;
                 ccProd, ccCons: static PinScopeCardinality](
    self: var BTable[K, V, Cap, ccProd, ccCons]): Unbound[(K, V),
    TableReaderTag, BTable[K, V, Cap, ccProd, ccCons]] {.inline, raises: [],
    notATransition.}
```

### `bindConsumer`

```nim
proc bindConsumer[T; ccProd: static PinScopeCardinality;
                  ST: static DeallocationStrategy; S, MaxThreads: static int](
    self: var Queue[T, ccProd, ccSingle, ST, S, MaxThreads]): Bound[T,
    AnyThreadTag, Queue[T, ccProd, ccSingle, ST, S, MaxThreads]] {.raises: [].}
```

<p>One-shot bind for the SC consumer of an MPSC-style Queue. Replaces the deleted v4.x <tt class="docutils literal"><span class="pre"><span class="Identifier">attachConsumer</span></span></tt>.</p>
<p>This is the proc-form equivalent of the <tt class="docutils literal"><span class="pre"><span class="Identifier">getConsumerHere</span></span></tt> template for the SC consumer case; it is kept as a proc (not a template alias) so it can carry the <tt class="docutils literal"><span class="pre"><span class="Punctuation">{</span><span class="Operator">.</span><span class="Identifier">raises</span><span class="Punctuation">:</span> <span class="Punctuation">[</span><span class="Punctuation">]</span><span class="Operator">.</span><span class="Punctuation">}</span></span></tt> effect annotation that replaced v4.x <tt class="docutils literal"><span class="pre"><span class="Identifier">attachConsumer</span></span></tt>.</p>


## Templates

### `getProducerHere`

```nim
template getProducerHere[T; ccCons: static PinScopeCardinality;
                         N, P, C: static int](
    self: var BQueue[T, ccMulti, ccCons, N, P, C]; idx: int = -1): Bound[T,
    AnyThreadTag, BQueue[T, ccMulti, ccCons, N, P, C]]
```

BQueue producer same-thread shortcut.

### `getConsumerHere`

```nim
template getConsumerHere[T; ccProd: static PinScopeCardinality;
                         N, P, C: static int](
    self: var BQueue[T, ccProd, ccMulti, N, P, C]; idx: int = -1): Bound[T,
    AnyThreadTag, BQueue[T, ccProd, ccMulti, N, P, C]]
```

BQueue consumer same-thread shortcut.

### `getProducerHere`

```nim
template getProducerHere[T; ccProd, ccCons: static PinScopeCardinality;
                         ST: static DeallocationStrategy;
                         S, MaxThreads: static int](
    self: var Queue[T, ccProd, ccCons, ST, S, MaxThreads]): Bound[T,
    AnyThreadTag, Queue[T, ccProd, ccCons, ST, S, MaxThreads]]
```

Queue producer same-thread shortcut.

### `getConsumerHere`

```nim
template getConsumerHere[T; ccProd, ccCons: static PinScopeCardinality;
                         ST: static DeallocationStrategy;
                         S, MaxThreads: static int](
    self: var Queue[T, ccProd, ccCons, ST, S, MaxThreads]): Bound[T,
    AnyThreadTag, Queue[T, ccProd, ccCons, ST, S, MaxThreads]]
```

Queue consumer same-thread shortcut.

### `getProducerHere`

```nim
template getProducerHere[T](self: var TreiberStack[T]): Bound[T,
    MpmcProducerTag, TreiberStack[T]]
```

### `getConsumerHere`

```nim
template getConsumerHere[T](self: var TreiberStack[T]): Bound[T,
    MpmcConsumerTag, TreiberStack[T]]
```

### `getProducerHere`

```nim
template getProducerHere[T; Cap: static int;
                         ccProd, ccCons: static PinScopeCardinality](
    self: var BStack[T, Cap, ccProd, ccCons]): Bound[T, MpmcProducerTag,
    BStack[T, Cap, ccProd, ccCons]]
```

### `getConsumerHere`

```nim
template getConsumerHere[T; Cap: static int;
                         ccProd, ccCons: static PinScopeCardinality](
    self: var BStack[T, Cap, ccProd, ccCons]): Bound[T, MpmcConsumerTag,
    BStack[T, Cap, ccProd, ccCons]]
```

### `getOwnerHere`

```nim
template getOwnerHere[T](self: var ChaseLevDeque[T]): Bound[T, DequeOwnerTag,
    ChaseLevDeque[T]]
```

### `getThiefHere`

```nim
template getThiefHere[T](self: var ChaseLevDeque[T]): Bound[T, DequeThiefTag,
    ChaseLevDeque[T]]
```

### `getProducerHere`

```nim
template getProducerHere[T](self: var ChaseLevDeque[T]): Bound[T, DequeOwnerTag,
    ChaseLevDeque[T]]
```

### `getConsumerHere`

```nim
template getConsumerHere[T](self: var ChaseLevDeque[T]): Bound[T, DequeThiefTag,
    ChaseLevDeque[T]]
```

### `getWriterHere`

```nim
template getWriterHere[K, V; Cap: static int;
                       ccProd, ccCons: static PinScopeCardinality](
    self: var BTable[K, V, Cap, ccProd, ccCons]): Bound[(K, V), TableWriterTag,
    BTable[K, V, Cap, ccProd, ccCons]]
```

### `getReaderHere`

```nim
template getReaderHere[K, V; Cap: static int;
                       ccProd, ccCons: static PinScopeCardinality](
    self: var BTable[K, V, Cap, ccProd, ccCons]): Bound[(K, V), TableReaderTag,
    BTable[K, V, Cap, ccProd, ccCons]]
```

### `getProducerHere`

```nim
template getProducerHere[K, V; Cap: static int;
                         ccProd, ccCons: static PinScopeCardinality](
    self: var BTable[K, V, Cap, ccProd, ccCons]): Bound[(K, V), TableWriterTag,
    BTable[K, V, Cap, ccProd, ccCons]]
```

### `getConsumerHere`

```nim
template getConsumerHere[K, V; Cap: static int;
                         ccProd, ccCons: static PinScopeCardinality](
    self: var BTable[K, V, Cap, ccProd, ccCons]): Bound[(K, V), TableReaderTag,
    BTable[K, V, Cap, ccProd, ccCons]]
```


## Macros

### `match`

```nim
macro match[T; Tag; queueT](value: EndpointStates[T, Tag, queueT]; arms: untyped): untyped
```

Single-target pattern match on states of typestate 'Endpoint'; rewrites to <tt class="docutils literal"><span class="pre"><span class="Keyword">block</span><span class="Punctuation">:</span> <span class="Keyword">let</span> <span class="Keyword">bind</span> <span class="Operator">=</span> <span class="Identifier">move</span><span class="Punctuation">(</span><span class="Identifier">value</span><span class="Punctuation">)</span><span class="Punctuation">;</span> <span class="Identifier">body</span></span></tt>. Syntax is <tt class="docutils literal"><span class="pre"><span class="Operator">&lt;</span><span class="Identifier">StateName</span><span class="Operator">&gt;</span><span class="Punctuation">(</span><span class="Keyword">bind</span><span class="Punctuation">)</span><span class="Punctuation">:</span></span></tt>, with exactly one arm.

### `Endpoint`

```nim
macro Endpoint(initial`gensym0: untyped; typeDef`gensym0: untyped): untyped
```

Typestate-attachment pragma (auto-generated; see §3.7 of the v0.9.0 design doc). Apply to a type declaration to bind the type to this typestate with <tt class="docutils literal"><span class="pre"><span class="Identifier">initial</span></span></tt> as the starting state. Validates TA-002..TA-004 at compile time and populates <tt class="docutils literal"><span class="pre"><span class="Identifier">typestateAttachments</span></span></tt>.

