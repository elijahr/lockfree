---
title: "lockfree/typestates/constructs"
description: "API reference for lockfree/typestates/constructs"
---

<pre>===========================================================================
First-Class Domain Typestate Extension Constructs (`lockfree/typestates/constructs`)
===========================================================================

Bridges user-defined `nim-typestates` state machines with `lockfree`
transport primitives (`BQueue`, `Queue`, `Bound`, `Channel`, `TreiberStack`,
`BStack`, `ChaseLevDeque`, `BroadcastRing`, `RendezvousChannel`).

Features:
- Re-exports the `nim-typestates` DSL (`typestate`, `transition`,
  `notATransition`, `destructorTransition`, `verifyTypestates`, `TypestateOp`)
  so consumer projects can author compile-time state machines directly via
  `import lockfree/typestates` or `import lockfree`.
- `TypestateGate[Base, InState, OutState, Transport]`: Zero-overhead
  type-safe transport gate that accepts `sink InState` on ingress (`sendState` /
  `trySendState` / `pushBottom`) and yields `Option[OutState]` on egress
  (`recvState` / `tryRecvState` / `stealState`), enforcing domain state
  transitions across thread/channel boundaries with move-only ARC/ORC safety.
- `TypestatePipelineStage[Base, InState, MidState, OutState, InTransport, OutTransport]`:
  Composable multi-stage typestate actor/pipeline step that consumes `InState`
  from `inbound`, applies a `InState -&gt; MidState` transition proc, and forwards
  `MidState -&gt; OutState` into `outbound`.</pre>


## Types

### `TypestateGate`

```nim
TypestateGate[Base; InState; OutState; Transport] = object
  transport*: ptr Transport
```

Zero-overhead typestate transport gate parameterized by:<ul class="simple"><li><tt class="docutils literal"><span class="pre"><span class="Identifier">Base</span></span></tt>: The underlying carrier type stored in <tt class="docutils literal"><span class="pre"><span class="Identifier">Transport</span></span></tt></li>
<li><tt class="docutils literal"><span class="pre"><span class="Identifier">InState</span></span></tt>: Required source typestate (<tt class="docutils literal"><span class="pre"><span class="Keyword">distinct</span> <span class="Identifier">Base</span></span></tt>) on ingress</li>
<li><tt class="docutils literal"><span class="pre"><span class="Identifier">OutState</span></span></tt>: Resulting target typestate (<tt class="docutils literal"><span class="pre"><span class="Keyword">distinct</span> <span class="Identifier">Base</span></span></tt>) on egress</li>
<li><tt class="docutils literal"><span class="pre"><span class="Identifier">Transport</span></span></tt>: Any <tt class="docutils literal"><span class="pre"><span class="Identifier">lockfree</span></span></tt> queue, stack, deque, ring, channel, or <tt class="docutils literal"><span class="pre"><span class="Identifier">Bound</span></span></tt> endpoint</li>
</ul>

### `TypestatePipelineStage`

```nim
TypestatePipelineStage[Base; InState; MidState; OutState; InTransport;
                       OutTransport] = object
  inbound*: TypestateGate[Base, InState, InState, InTransport]
  outbound*: TypestateGate[Base, MidState, OutState, OutTransport]
```

Composable pipeline stage bridging an <tt class="docutils literal"><span class="pre"><span class="Identifier">inbound</span></span></tt> transport (<tt class="docutils literal"><span class="pre"><span class="Identifier">Base</span></span></tt> -&gt; <tt class="docutils literal"><span class="pre"><span class="Identifier">InState</span></span></tt>) and an <tt class="docutils literal"><span class="pre"><span class="Identifier">outbound</span></span></tt> transport (<tt class="docutils literal"><span class="pre"><span class="Identifier">MidState</span></span></tt> -&gt; <tt class="docutils literal"><span class="pre"><span class="Identifier">OutState</span></span></tt>).


## Procedures & Functions

### `initTypestateGate`

```nim
proc initTypestateGate[Base, InState, OutState, Transport](
    transport: var Transport): TypestateGate[Base, InState, OutState, Transport] {.
    inline, notATransition.}
```

Wraps <tt class="docutils literal"><span class="pre"><span class="Identifier">transport</span></span></tt> in a compile-time <tt class="docutils literal"><span class="pre"><span class="Identifier">InState</span> <span class="Operator">-&gt;</span> <span class="Identifier">OutState</span></span></tt> typestate gate.

### `trySendState`

```nim
proc trySendState[Base, InState, OutState, Transport, ItemT](
    gate: TypestateGate[Base, InState, OutState, Transport]; item: sink ItemT): bool {.
    inline, notATransition.}
```

Consumes <tt class="docutils literal"><span class="pre"><span class="Identifier">item</span></span></tt> in state <tt class="docutils literal"><span class="pre"><span class="Identifier">InState</span></span></tt> via <tt class="docutils literal"><span class="pre"><span class="Identifier">move</span></span></tt> (preserving ARC/ORC ownership without extra copies) and enqueues/pushes it into <tt class="docutils literal"><span class="pre"><span class="Identifier">gate</span><span class="Operator">.</span><span class="Identifier">transport</span></span></tt>.

### `sendState`

```nim
proc sendState[Base, InState, OutState, Transport, ItemT](
    gate: TypestateGate[Base, InState, OutState, Transport]; item: sink ItemT): bool {.
    discardable, inline, notATransition.}
```

Consumes <tt class="docutils literal"><span class="pre"><span class="Identifier">item</span></span></tt> in state <tt class="docutils literal"><span class="pre"><span class="Identifier">InState</span></span></tt> and sends/pushes it through <tt class="docutils literal"><span class="pre"><span class="Identifier">gate</span><span class="Operator">.</span><span class="Identifier">transport</span></span></tt>.

### `recvState`

```nim
proc recvState[Base, InState, OutState, Transport](
    gate: TypestateGate[Base, InState, OutState, Transport]): Option[OutState] {.
    inline, notATransition.}
```

Pops/receives the next payload from <tt class="docutils literal"><span class="pre"><span class="Identifier">gate</span><span class="Operator">.</span><span class="Identifier">transport</span></span></tt> and transitions it into <tt class="docutils literal"><span class="pre"><span class="Identifier">OutState</span></span></tt> via <tt class="docutils literal"><span class="pre"><span class="Identifier">move</span></span></tt>.

### `tryRecvState`

```nim
proc tryRecvState[Base, InState, OutState, Transport](
    gate: TypestateGate[Base, InState, OutState, Transport];
    outItem: var OutState): bool {.inline, notATransition.}
```

Non-blocking receive into <tt class="docutils literal"><span class="pre"><span class="Identifier">outItem</span></span></tt> in state <tt class="docutils literal"><span class="pre"><span class="Identifier">OutState</span></span></tt>.

### `stealState`

```nim
proc stealState[Base, InState, OutState, Transport](
    gate: TypestateGate[Base, InState, OutState, Transport]): Option[OutState] {.
    inline, notATransition.}
```

Work-stealing egress for <tt class="docutils literal"><span class="pre"><span class="Identifier">ChaseLevDeque</span></span></tt> or thief <tt class="docutils literal"><span class="pre"><span class="Identifier">Bound</span></span></tt> endpoints, yielding <tt class="docutils literal"><span class="pre"><span class="Identifier">Option</span><span class="Punctuation">[</span><span class="Identifier">OutState</span><span class="Punctuation">]</span></span></tt> via <tt class="docutils literal"><span class="pre"><span class="Identifier">move</span></span></tt>.

### `initTypestatePipelineStage`

```nim
proc initTypestatePipelineStage[Base, InState, MidState, OutState, InTransport,
                                OutTransport](inbound: var InTransport;
    outbound: var OutTransport): TypestatePipelineStage[Base, InState, MidState,
    OutState, InTransport, OutTransport] {.inline, notATransition.}
```

Initializes a typed pipeline stage that pops <tt class="docutils literal"><span class="pre"><span class="Identifier">InState</span></span></tt> from <tt class="docutils literal"><span class="pre"><span class="Identifier">inbound</span></span></tt>, transforms <tt class="docutils literal"><span class="pre"><span class="Identifier">InState</span> <span class="Operator">-&gt;</span> <span class="Identifier">MidState</span></span></tt>, and pushes <tt class="docutils literal"><span class="pre"><span class="Identifier">MidState</span> <span class="Operator">-&gt;</span> <span class="Identifier">OutState</span></span></tt> to <tt class="docutils literal"><span class="pre"><span class="Identifier">outbound</span></span></tt>.

### `stepStage`

```nim
proc stepStage[Base, InState, MidState, OutState, InTransport, OutTransport](
    stage: TypestatePipelineStage[Base, InState, MidState, OutState,
                                  InTransport, OutTransport];
    transform: proc (s: sink InState): MidState {.gcsafe.}): bool {.inline,
    notATransition.}
```

Pulls one <tt class="docutils literal"><span class="pre"><span class="Identifier">InState</span></span></tt> item from <tt class="docutils literal"><span class="pre"><span class="Identifier">stage</span><span class="Operator">.</span><span class="Identifier">inbound</span></span></tt>, applies <tt class="docutils literal"><span class="pre"><span class="Identifier">transform</span></span></tt> to transition <tt class="docutils literal"><span class="pre"><span class="Identifier">InState</span> <span class="Operator">-&gt;</span> <span class="Identifier">MidState</span></span></tt>, and sends <tt class="docutils literal"><span class="pre"><span class="Identifier">MidState</span></span></tt> into <tt class="docutils literal"><span class="pre"><span class="Identifier">stage</span><span class="Operator">.</span><span class="Identifier">outbound</span></span></tt>. Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt> if an item was processed and forwarded, or <tt class="docutils literal"><span class="pre"><span class="Identifier">false</span></span></tt> if <tt class="docutils literal"><span class="pre"><span class="Identifier">inbound</span></span></tt> was empty.

