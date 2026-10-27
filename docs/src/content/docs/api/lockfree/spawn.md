---
title: "lockfree/spawn"
description: "API reference for lockfree/spawn"
---

Thread-spawn helpers for the v5.0.0 endpoint API — 2-step API.
<h3><a class="toc-backref" id="why-2minusstep-instead-of-singleminuscall-macro" href="#why-2minusstep-instead-of-singleminuscall-macro">Why 2-step instead of single-call macro</a></h3><p>A single-call macro form (<tt class="docutils literal"><span class="pre"><span class="Identifier">spawnBoundProducer</span><span class="Punctuation">(</span><span class="Identifier">q</span><span class="Punctuation">)</span><span class="Punctuation">:</span> <span class="Identifier">body</span></span></tt>) is not viable. Nim 2.2.10 codegen issue: <tt class="docutils literal"><span class="pre"><span class="Punctuation">{</span><span class="Operator">.</span><span class="Identifier">thread</span><span class="Punctuation">,</span> <span class="Identifier">nimcall</span><span class="Punctuation">,</span> <span class="Identifier">gcsafe</span><span class="Operator">.</span><span class="Punctuation">}</span></span></tt> procs emitted by macros OR templates inside a block/proc context are silently downgraded to closures, then <tt class="docutils literal"><span class="pre"><span class="Identifier">createThread</span></span></tt> calls into invalid memory at thread entry (no stack trace, body-independent segfault). Hand-rolled module-scope thread procs work correctly.</p>
<p>The 2-step API makes the module-scope constraint EXPLICIT. <tt class="docutils literal"><span class="pre"><span class="Identifier">defineProducerWorker</span><span class="Punctuation">(</span><span class="Identifier">WorkerName</span><span class="Punctuation">,</span> <span class="Identifier">queueType</span><span class="Punctuation">,</span> <span class="Identifier">body</span><span class="Punctuation">)</span></span></tt> is a DECLARATION that MUST live at module scope (like <tt class="docutils literal"><span class="pre"><span class="Keyword">proc</span></span></tt>/<tt class="docutils literal"><span class="pre"><span class="Keyword">type</span></span></tt>). <tt class="docutils literal"><span class="pre"><span class="Identifier">spawnDefined</span><span class="Punctuation">(</span><span class="Identifier">WorkerName</span><span class="Punctuation">,</span> <span class="Identifier">queue</span><span class="Punctuation">)</span></span></tt> at the call site spawns the pre-defined worker.</p>
<p><strong>MUST be invoked at module scope.</strong> Inside a proc body, the emitted <tt class="docutils literal"><span class="pre"><span class="Punctuation">{</span><span class="Operator">.</span><span class="Identifier">thread</span><span class="Punctuation">,</span> <span class="Identifier">nimcall</span><span class="Operator">.</span><span class="Punctuation">}</span></span></tt> worker is silently downgraded to a closure (Nim 2.2.10 codegen issue), causing runtime segfaults. Module-scope misuse IS caught at compile time: each <tt class="docutils literal"><span class="pre"><span class="Identifier">defineProducerWorker</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">defineConsumerWorker</span></span></tt> expansion emits an <tt class="docutils literal"><span class="pre"><span class="Keyword">export</span></span></tt> statement, which Nim rejects outside top-level scope (<tt class="docutils literal"><span class="pre"><span class="Identifier">Error</span><span class="Punctuation">:</span> <span class="CharLit">'export'</span> <span class="Keyword">is</span> <span class="Identifier">only</span> <span class="Identifier">allowed</span> <span class="Identifier">at</span> <span class="Identifier">top</span> <span class="Identifier">level</span></span></tt>). This export-as-scope-probe trips a clear compile error before a nested-scope misuse can ship — it is not a bespoke <tt class="docutils literal"><span class="pre"><span class="Punctuation">{</span><span class="Operator">.</span><span class="Identifier">error</span><span class="Operator">.</span><span class="Punctuation">}</span></span></tt> but it is a real guard, not merely a doc-comment convention.</p>

<h3><a class="toc-backref" id="usage" href="#usage">Usage</a></h3><p><pre class="listing"><span class="Keyword">import</span> <span class="Identifier">std</span><span class="Operator">/</span><span class="Identifier">atomics</span>
<span class="Keyword">import</span> <span class="Identifier">lockfree</span><span class="Operator">/</span><span class="Punctuation">[</span><span class="Identifier">bqueue</span><span class="Punctuation">,</span> <span class="Identifier">endpoint</span><span class="Punctuation">,</span> <span class="Identifier">role_tags</span><span class="Punctuation">,</span> <span class="Identifier">spawn</span><span class="Punctuation">]</span>

<span class="Comment"># MUST be at module scope:</span>
<span class="Identifier">defineProducerWorker</span><span class="Punctuation">(</span><span class="Identifier">MyProducer</span><span class="Punctuation">,</span> <span class="Identifier">BQueue</span><span class="Punctuation">[</span><span class="Identifier">int</span><span class="Punctuation">,</span> <span class="Identifier">ccMulti</span><span class="Punctuation">,</span> <span class="Identifier">ccMulti</span><span class="Punctuation">,</span> <span class="DecNumber">64</span><span class="Punctuation">,</span> <span class="DecNumber">4</span><span class="Punctuation">,</span> <span class="DecNumber">4</span><span class="Punctuation">]</span><span class="Punctuation">)</span><span class="Punctuation">:</span>
  <span class="Keyword">for</span> <span class="Identifier">i</span> <span class="Keyword">in</span> <span class="DecNumber">0</span> <span class="Operator">..&lt;</span> <span class="DecNumber">10</span><span class="Punctuation">:</span>
    <span class="Keyword">discard</span> <span class="Identifier">producer</span><span class="Operator">.</span><span class="Identifier">push</span><span class="Punctuation">(</span><span class="Identifier">i</span><span class="Punctuation">)</span>

<span class="Keyword">proc</span> <span class="Identifier">main</span><span class="Punctuation">(</span><span class="Punctuation">)</span> <span class="Operator">=</span>
  <span class="Keyword">var</span> <span class="Identifier">q</span> <span class="Operator">=</span> <span class="Identifier">initBQueue</span><span class="Punctuation">[</span><span class="Identifier">int</span><span class="Punctuation">,</span> <span class="Identifier">ccMulti</span><span class="Punctuation">,</span> <span class="Identifier">ccMulti</span><span class="Punctuation">,</span> <span class="DecNumber">64</span><span class="Punctuation">,</span> <span class="DecNumber">4</span><span class="Punctuation">,</span> <span class="DecNumber">4</span><span class="Punctuation">]</span><span class="Punctuation">(</span><span class="Punctuation">)</span>
  <span class="Keyword">var</span> <span class="Identifier">thr</span> <span class="Operator">=</span> <span class="Identifier">spawnDefined</span><span class="Punctuation">(</span><span class="Identifier">MyProducer</span><span class="Punctuation">,</span> <span class="Identifier">q</span><span class="Punctuation">)</span>
  <span class="Identifier">joinThread</span><span class="Punctuation">(</span><span class="Identifier">thr</span><span class="Punctuation">)</span>

<span class="Identifier">main</span><span class="Punctuation">(</span><span class="Punctuation">)</span></pre></p>


## Procedures & Functions

### `spawnDefinedProducerImpl`

```nim
proc spawnDefinedProducerImpl[ArgT](workerProc: proc (arg: ArgT) {.thread,
    nimcall, gcsafe.}; tagged: ArgT): Thread[ArgT]
```

Internal helper (proc, not template) — invokes createThread at proc-call scope. Avoiding template/block wrappers around createThread sidesteps Nim 2.2.10 codegen issue.

### `spawnDefinedConsumerImpl`

```nim
proc spawnDefinedConsumerImpl[ArgT](workerProc: proc (arg: ArgT) {.thread,
    nimcall, gcsafe.}; tagged: ArgT): Thread[ArgT]
```


## Templates

### `spawnDefinedProducer`

```nim
template spawnDefinedProducer(workerProc: untyped; q: untyped): untyped
```

Spawn a producer worker declared via <tt class="docutils literal"><span class="pre"><span class="Identifier">defineProducerWorker</span></span></tt>. Returns the <tt class="docutils literal"><span class="pre"><span class="Identifier">Thread</span><span class="Punctuation">[</span><span class="Identifier">…</span><span class="Punctuation">]</span></span></tt> handle.

### `spawnDefinedConsumer`

```nim
template spawnDefinedConsumer(workerProc: untyped; q: untyped): untyped
```

Spawn a consumer worker declared via <tt class="docutils literal"><span class="pre"><span class="Identifier">defineConsumerWorker</span></span></tt>. Returns the <tt class="docutils literal"><span class="pre"><span class="Identifier">Thread</span><span class="Punctuation">[</span><span class="Identifier">…</span><span class="Punctuation">]</span></span></tt> handle.


## Macros

### `defineProducerWorker`

```nim
macro defineProducerWorker(workerName, queueType, body: untyped): untyped
```

Declare a producer worker proc with the given name. <tt class="docutils literal"><span class="pre"><span class="Identifier">queueType</span></span></tt> is the full queue type. <tt class="docutils literal"><span class="pre"><span class="Identifier">producer</span></span></tt> is injected into <tt class="docutils literal"><span class="pre"><span class="Identifier">body</span></span></tt>'s scope as <tt class="docutils literal"><span class="pre"><span class="Identifier">Bound</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">,</span> <span class="Identifier">MpmcProducerTag</span><span class="Punctuation">,</span> <span class="Identifier">queueType</span><span class="Punctuation">]</span></span></tt>. <strong>MUST be invoked at module scope.</strong>

### `defineConsumerWorker`

```nim
macro defineConsumerWorker(workerName, queueType, body: untyped): untyped
```

Symmetric: declare a consumer worker. <tt class="docutils literal"><span class="pre"><span class="Identifier">consumer</span></span></tt> is injected as <tt class="docutils literal"><span class="pre"><span class="Identifier">Bound</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">,</span> <span class="Identifier">MpmcConsumerTag</span><span class="Punctuation">,</span> <span class="Identifier">queueType</span><span class="Punctuation">]</span></span></tt>. MUST be at module scope.

