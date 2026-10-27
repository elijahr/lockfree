---
title: "lockfree/endpoint_types"
description: "API reference for lockfree/endpoint_types"
---

<p>Endpoint state types — leaf module shared by <tt class="docutils literal"><span class="pre"><span class="Identifier">endpoint</span><span class="Operator">.</span><span class="Identifier">nim</span></span></tt> (which owns the typestate FSM + transition procs + backend dispatch) and the per-flavour <tt class="docutils literal"><span class="pre"><span class="Identifier">bqueue</span><span class="Operator">.</span><span class="Identifier">nim</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">queue</span><span class="Operator">.</span><span class="Identifier">nim</span></span></tt> (which carry the push/pop overloads on <tt class="docutils literal"><span class="pre"><span class="Identifier">Bound</span></span></tt>).</p>
<p><strong>Why split.</strong> <tt class="docutils literal"><span class="pre"><span class="Identifier">endpoint</span><span class="Operator">.</span><span class="Identifier">nim</span></span></tt> imports <tt class="docutils literal"><span class="pre"><span class="Operator">./</span><span class="Identifier">bqueue</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Operator">./</span><span class="Identifier">queue</span></span></tt> for the <tt class="docutils literal"><span class="pre"><span class="Identifier">BQueueType</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">QueueType</span></span></tt> concept matching used by the concept-dispatched <tt class="docutils literal"><span class="pre"><span class="Identifier">onBind</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">onClose</span></span></tt> helpers. <tt class="docutils literal"><span class="pre"><span class="Identifier">bqueue</span><span class="Operator">.</span><span class="Identifier">nim</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">queue</span><span class="Operator">.</span><span class="Identifier">nim</span></span></tt> need to declare push/pop on <tt class="docutils literal"><span class="pre"><span class="Identifier">Bound</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">,</span> <span class="Identifier">Tag</span><span class="Punctuation">,</span> <span class="Identifier">queueT</span><span class="Punctuation">]</span></span></tt> receivers — declaring <tt class="docutils literal"><span class="pre"><span class="Identifier">Bound</span></span></tt> here lets the per-flavour modules import it without a back-edge cycle.</p>
<p><strong>Cost of split.</strong> The <tt class="docutils literal"><span class="pre"><span class="Identifier">Endpoint</span></span></tt> typestate in <tt class="docutils literal"><span class="pre"><span class="Identifier">endpoint</span><span class="Operator">.</span><span class="Identifier">nim</span></span></tt> runs with <tt class="docutils literal"><span class="pre"><span class="Identifier">consumeOnTransition</span> <span class="Operator">=</span> <span class="Identifier">false</span></span></tt> (mirroring <tt class="docutils literal"><span class="pre"><span class="Identifier">BQueueLifecycle</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">QueueLifecycle</span></span></tt> in the same project). The static-affinity guarantee is upheld by lifecycle FSM strictness (<tt class="docutils literal"><span class="pre"><span class="Identifier">push</span></span></tt>/<tt class="docutils literal"><span class="pre"><span class="Identifier">pop</span></span></tt> exist only on <tt class="docutils literal"><span class="pre"><span class="Identifier">Bound</span></span></tt>) + role discrimination via the <tt class="docutils literal"><span class="pre"><span class="Identifier">Tag</span></span></tt> generic + effect-tag pragmas; the consume-on-transition flag would have added aliasing prevention on top, which is not load-bearing for the affinity guarantee and is incompatible with cross-module type+typestate split (typestates 0.12.0 codegen requires <tt class="docutils literal"><span class="pre"><span class="Operator">=</span><span class="Identifier">copy</span></span></tt> hooks in the same module as the type).</p>


## Types

### `Unbound`

```nim
Unbound[T; Tag; queueT] = object
  queue*: ptr queueT
  idx*: int
```

### `Bound`

```nim
Bound[T; Tag; queueT] = object
  queue*: ptr queueT
  idx*: int
  when defined(debug):
    attachedTid*: int
  handleManager*: pointer ## Opaque storage for the debra `ThreadHandle.manager` pointer. Meaningful
                          ## only for Queue endpoints; `nil` sentinel for BQueue endpoints. See
                          ## `endpoint.nim` onBind/onClose for the cast-back round-trip.
  handleIdx*: int
```

### `EndpointClosed`

```nim
EndpointClosed[T; Tag; queueT] = object
  queue*: ptr queueT
  handleManager*: pointer
  handleIdx*: int
```

### `Closed`

```nim
Closed[T; Tag; queueT] = EndpointClosed[T, Tag, queueT]
```

Public alias. <tt class="docutils literal"><span class="pre"><span class="Identifier">EndpointClosed</span></span></tt> is the canonical name (renamed to avoid the unqualified-<tt class="docutils literal"><span class="pre"><span class="Identifier">Closed</span></span></tt> collision with debra's <tt class="docutils literal"><span class="pre"><span class="Identifier">EpochGuardContext</span><span class="Operator">.</span><span class="Identifier">Closed</span></span></tt> typestate state visible through the import graph). User-facing API uses <tt class="docutils literal"><span class="pre"><span class="Identifier">Closed</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">,</span> <span class="Identifier">Tag</span><span class="Punctuation">,</span> <span class="Identifier">queueT</span><span class="Punctuation">]</span></span></tt>.

