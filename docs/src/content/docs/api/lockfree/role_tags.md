---
title: "lockfree/role_tags"
description: "API reference for lockfree/role_tags"
---

Role-discriminating effect tags shared across queue flavours.<ul class="simple"><li><tt class="docutils literal"><span class="pre"><span class="Identifier">AnyThreadTag</span></span></tt>: same-thread shortcut path (<tt class="docutils literal"><span class="pre"><span class="Identifier">getProducerHere</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">getConsumerHere</span></span></tt>). Bypasses per-spawn freshness; runtime <tt class="docutils literal"><span class="pre"><span class="Identifier">getThreadId</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt> backstop catches misuse under <tt class="docutils literal"><span class="pre"><span class="Operator">-</span><span class="Identifier">d</span><span class="Punctuation">:</span><span class="Identifier">debug</span></span></tt>.</li>
<li><tt class="docutils literal"><span class="pre"><span class="Identifier">SpscProducerTag</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">SpscConsumerTag</span></span></tt>: SPSC has cardinality 1 per role, so per-spawn freshness collapses; role discrimination still applies.</li>
<li><tt class="docutils literal"><span class="pre"><span class="Identifier">MpmcProducerTag</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">MpmcConsumerTag</span></span></tt>: Option A — MPMC gets role discipline only (no per-spawn tag). Per-thread identity stays runtime- checked (see migration guide).</li>
</ul>


## Types

### `AnyThreadTag`

```nim
AnyThreadTag = object of RootEffect
```

### `SpscProducerTag`

```nim
SpscProducerTag = object of RootEffect
```

### `SpscConsumerTag`

```nim
SpscConsumerTag = object of RootEffect
```

### `MpmcProducerTag`

```nim
MpmcProducerTag = object of RootEffect
```

### `MpmcConsumerTag`

```nim
MpmcConsumerTag = object of RootEffect
```

### `DequeOwnerTag`

```nim
DequeOwnerTag = object of RootEffect
```

Single owner-worker role tag for <tt class="docutils literal"><span class="pre"><span class="Identifier">ChaseLevDeque</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> (<tt class="docutils literal"><span class="pre"><span class="Identifier">pushBottom</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">popBottom</span></span></tt>).

### `DequeThiefTag`

```nim
DequeThiefTag = object of RootEffect
```

Concurrent thief role tag for <tt class="docutils literal"><span class="pre"><span class="Identifier">ChaseLevDeque</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> (<tt class="docutils literal"><span class="pre"><span class="Identifier">steal</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">stealBatch</span></span></tt>).

### `TableWriterTag`

```nim
TableWriterTag = object of RootEffect
```

Read-write mutator role tag for <tt class="docutils literal"><span class="pre"><span class="Identifier">BTable</span><span class="Punctuation">[</span><span class="Identifier">K</span><span class="Punctuation">,</span> <span class="Identifier">V</span><span class="Punctuation">,</span> <span class="Identifier">Cap</span><span class="Punctuation">,</span> <span class="Identifier">ccProd</span><span class="Punctuation">,</span> <span class="Identifier">ccCons</span><span class="Punctuation">]</span></span></tt>.

### `TableReaderTag`

```nim
TableReaderTag = object of RootEffect
```

Read-only observer role tag for <tt class="docutils literal"><span class="pre"><span class="Identifier">BTable</span><span class="Punctuation">[</span><span class="Identifier">K</span><span class="Punctuation">,</span> <span class="Identifier">V</span><span class="Punctuation">,</span> <span class="Identifier">Cap</span><span class="Punctuation">,</span> <span class="Identifier">ccProd</span><span class="Punctuation">,</span> <span class="Identifier">ccCons</span><span class="Punctuation">]</span></span></tt>.

