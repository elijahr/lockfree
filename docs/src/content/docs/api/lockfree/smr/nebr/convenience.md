---
title: "lockfree/smr/nebr/convenience"
description: "API reference for lockfree/smr/nebr/convenience"
---

<p>High-level convenience API for common DEBRA patterns.</p>
<p>These procs compose the low-level typestate API for frequent use cases. For fine-grained control or batching, use the typestate API directly.</p>

<h2><a class="toc-backref" id="pitfalls" href="#pitfalls">Pitfalls</a></h2><ul class="simple"><li><tt class="docutils literal"><span class="pre"><span class="Identifier">PinnedScope</span></span></tt> (in <tt class="docutils literal"><span class="pre"><span class="Identifier">debra</span><span class="Operator">/</span><span class="Identifier">typestates</span><span class="Operator">/</span><span class="Identifier">pinned_scope</span></span></tt>) does not allow re-pinning the same handle inside its scope. A <tt class="docutils literal"><span class="pre"><span class="Identifier">doAssert</span></span></tt> inside <tt class="docutils literal"><span class="pre"><span class="Identifier">pinScope</span><span class="Punctuation">(</span><span class="Identifier">unpinned</span><span class="Punctuation">(</span><span class="Identifier">handle</span><span class="Punctuation">)</span><span class="Punctuation">)</span></span></tt> catches direct nesting and fires in release builds too, because a second <tt class="docutils literal"><span class="pre"><span class="Identifier">pin</span></span></tt> would silently corrupt the pinned-flag on the thread's slot — this is a safety guard, not just a debug aid. Different handles (multi-manager) are independent.</li>
<li>Do not invoke explicit typestate transitions (<tt class="docutils literal"><span class="pre"><span class="Identifier">unpinned</span></span></tt>/<tt class="docutils literal"><span class="pre"><span class="Identifier">pin</span></span></tt>/<tt class="docutils literal"><span class="pre"><span class="Identifier">unpin</span></span></tt>/<tt class="docutils literal"><span class="pre"><span class="Identifier">acknowledge</span></span></tt>) inside a live <tt class="docutils literal"><span class="pre"><span class="Identifier">PinnedScope</span></span></tt>. The scope's <tt class="docutils literal"><span class="pre"><span class="Operator">=</span><span class="Identifier">destroy</span></span></tt> already manages the lifecycle; manual transitions on the same handle desync the slot's <tt class="docutils literal"><span class="pre"><span class="Identifier">pinned</span></span></tt> flag.</li>
<li><tt class="docutils literal"><span class="pre"><span class="Identifier">retireReady</span><span class="Punctuation">(</span><span class="Identifier">scope</span><span class="Operator">.</span><span class="Identifier">state</span><span class="Punctuation">)</span></span></tt> projects the inner <tt class="docutils literal"><span class="pre"><span class="Identifier">Pinned</span><span class="Punctuation">[</span><span class="Identifier">MT</span><span class="Punctuation">,</span> <span class="Identifier">CC</span><span class="Punctuation">]</span></span></tt> to a <tt class="docutils literal"><span class="pre"><span class="Keyword">var</span> <span class="Identifier">RetireReady</span><span class="Punctuation">[</span><span class="Identifier">MT</span><span class="Punctuation">,</span> <span class="Identifier">CC</span><span class="Punctuation">]</span></span></tt> that retires through the convenience <tt class="docutils literal"><span class="pre"><span class="Identifier">retire</span><span class="Punctuation">(</span><span class="Keyword">var</span> <span class="Identifier">RetireReady</span><span class="Punctuation">,</span> <span class="Operator">...</span><span class="Punctuation">)</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">retireBatch</span><span class="Punctuation">(</span><span class="Keyword">var</span> <span class="Identifier">RetireReady</span><span class="Punctuation">,</span> <span class="Operator">...</span><span class="Punctuation">)</span></span></tt> procs below. Items retired via <tt class="docutils literal"><span class="pre"><span class="Identifier">ready</span><span class="Operator">.</span><span class="Identifier">retire</span><span class="Punctuation">(</span><span class="Operator">...</span><span class="Punctuation">)</span></span></tt> are added to the thread's limbo bag at the pinned epoch and are not reclaimed until a later reclamation pass observes a safe epoch.</li>
<li><tt class="docutils literal"><span class="pre"><span class="Identifier">reclaimNow</span></span></tt> returns 0 when no epoch is safe to reclaim yet. That is normal at startup or when no thread has advanced the epoch since the last retire. It is not an error; reclamation is best-effort.</li>
<li><tt class="docutils literal"><span class="pre"><span class="Identifier">retireBatch</span></span></tt> retires from the supplied <tt class="docutils literal"><span class="pre"><span class="Identifier">openArray</span></span></tt> synchronously. The array contents are copied into the limbo bag during the call, so the caller's array does not need to outlive the reclamation pass.</li>
</ul>

<h2><a class="toc-backref" id="naming-convention" href="#naming-convention">Naming convention</a></h2><p>This module is the <strong>manager-level</strong> layer: <tt class="docutils literal"><span class="pre"><span class="Identifier">retire</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">retireBatch</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">reclaimNow</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">retireAndReclaim</span></span></tt>, and <tt class="docutils literal"><span class="pre"><span class="Identifier">advanceEvery</span></span></tt> (alongside <tt class="docutils literal"><span class="pre"><span class="Identifier">PinnedScope</span></span></tt> in <tt class="docutils literal"><span class="pre"><span class="Identifier">debra</span><span class="Operator">/</span><span class="Identifier">typestates</span><span class="Operator">/</span><span class="Identifier">pinned_scope</span></span></tt>) coordinate the epoch-based reclamation pipeline (deferred destruction until no thread can observe an object). They take a <tt class="docutils literal"><span class="pre"><span class="Punctuation">(</span><span class="Identifier">pointer</span><span class="Punctuation">,</span> <span class="Identifier">Destructor</span><span class="Punctuation">)</span></span></tt> pair and decide <em>when</em> the destructor runs.</p>
<p>The <strong>object-lifetime</strong> layer in <tt class="docutils literal"><span class="pre"><span class="Identifier">debra</span><span class="Operator">/</span><span class="Identifier">refptr</span></span></tt> uses different verbs (<tt class="docutils literal"><span class="pre"><span class="Identifier">retain</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">release</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">releaseDestructor</span></span></tt>) because it operates on a single object's GC refcount and has no awareness of epochs or threads. The two layers compose: <tt class="docutils literal"><span class="pre"><span class="Identifier">releaseDestructor</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt> from <tt class="docutils literal"><span class="pre"><span class="Identifier">debra</span><span class="Operator">/</span><span class="Identifier">refptr</span></span></tt> is the destructor handed to <tt class="docutils literal"><span class="pre"><span class="Identifier">pin</span><span class="Operator">.</span><span class="Identifier">retire</span><span class="Punctuation">(</span><span class="Identifier">p</span><span class="Punctuation">,</span> <span class="Identifier">dtor</span><span class="Punctuation">)</span></span></tt> so that <tt class="docutils literal"><span class="pre"><span class="Identifier">release</span></span></tt> runs at safe-epoch reclamation time. The verbs differ because the layers differ; do not expect <tt class="docutils literal"><span class="pre"><span class="Identifier">retire</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">retain</span></span></tt> (or <tt class="docutils literal"><span class="pre"><span class="Identifier">reclaim</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">release</span></span></tt>) to be synonyms.</p>

<h2><a class="toc-backref" id="see-also" href="#see-also">See also</a></h2><ul class="simple"><li><a class="reference internal" href="#debra">debra</a> - explicit <tt class="docutils literal"><span class="pre"><span class="Identifier">pin</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">unpin</span></span></tt> typestate transitions.</li>
<li><a class="reference internal" href="#debra">debra</a> - typestate <tt class="docutils literal"><span class="pre"><span class="Identifier">retire</span></span></tt> (sink form).</li>
<li><a class="reference internal" href="#debra">debra</a> - typestate <tt class="docutils literal"><span class="pre"><span class="Identifier">reclaimStart</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">tryReclaim</span></span></tt>.</li>
</ul>


## Procedures & Functions

### `retire`

```nim
proc retire[MT: static int; CC: static PinScopeCardinality = ccSingle](
    pin: var RetireReady[MT, CC]; p: pointer; destructor: Destructor) {.
    notATransition.}
```

<p>Retire <tt class="docutils literal"><span class="pre"><span class="Identifier">p</span></span></tt> inside an existing pinned epoch held by <tt class="docutils literal"><span class="pre"><span class="Identifier">pin</span></span></tt>.</p>
<p>Wraps the sink-form <tt class="docutils literal"><span class="pre"><span class="Identifier">retire</span></span></tt> from typestates/retire.nim so the caller can chain <tt class="docutils literal"><span class="pre"><span class="Identifier">ready</span><span class="Operator">.</span><span class="Identifier">retire</span><span class="Punctuation">(</span><span class="Operator">...</span><span class="Punctuation">)</span></span></tt> repeatedly (e.g. on a <tt class="docutils literal"><span class="pre"><span class="Identifier">RetireReady</span></span></tt> projected from a <tt class="docutils literal"><span class="pre"><span class="Identifier">PinnedScope</span></span></tt> via <tt class="docutils literal"><span class="pre"><span class="Identifier">retireReady</span><span class="Punctuation">(</span><span class="Identifier">scope</span><span class="Operator">.</span><span class="Identifier">state</span><span class="Punctuation">)</span></span></tt>) without manually rebuilding <tt class="docutils literal"><span class="pre"><span class="Identifier">RetireReady</span></span></tt> from <tt class="docutils literal"><span class="pre"><span class="Identifier">Retired</span></span></tt>.</p>

### `retireBatch`

```nim
proc retireBatch[MT: static int; CC: static PinScopeCardinality = ccSingle](
    pin: var RetireReady[MT, CC]; items: openArray[(pointer, Destructor)]) {.
    notATransition.}
```

<p>Retire each <tt class="docutils literal"><span class="pre"><span class="Punctuation">(</span><span class="Identifier">p</span><span class="Punctuation">,</span> <span class="Identifier">dtor</span><span class="Punctuation">)</span></span></tt> in <tt class="docutils literal"><span class="pre"><span class="Identifier">items</span></span></tt> inside an existing pinned epoch.</p>
<p>Must be called by a holder of a <tt class="docutils literal"><span class="pre"><span class="Keyword">var</span> <span class="Identifier">RetireReady</span><span class="Punctuation">[</span><span class="Identifier">MT</span><span class="Punctuation">,</span> <span class="Identifier">CC</span><span class="Punctuation">]</span></span></tt> (typically projected from a <tt class="docutils literal"><span class="pre"><span class="Identifier">PinnedScope</span></span></tt> via <tt class="docutils literal"><span class="pre"><span class="Identifier">retireReady</span><span class="Punctuation">(</span><span class="Identifier">scope</span><span class="Operator">.</span><span class="Identifier">state</span><span class="Punctuation">)</span></span></tt>). No pinning, no reclamation. Avoids one pin/unpin per object when freeing chains.</p>

### `advanceEvery`

```nim
proc advanceEvery[MT: static int; CC: static PinScopeCardinality = ccSingle](
    handle: ThreadHandle[MT, CC]; n: static int): bool {.discardable.}
```

<p>Increment a per-handle counter; advance the global epoch once every <tt class="docutils literal"><span class="pre"><span class="Identifier">n</span></span></tt> calls. Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt> on the calls that actually advanced.</p>
<p>Cadence helper for the most common epoch advancement pattern: call this from a hot path (e.g. after each retire, or once per pop) without paying an atomic store on every invocation. Most calls are a single non-atomic increment plus a branch; only every Nth call performs the atomic <tt class="docutils literal"><span class="pre"><span class="Identifier">fetchAdd</span></span></tt> on the global epoch.</p>
<p>The counter lives on the handle's per-thread slot and is owned by the registered thread. No synchronization is required; different handles have independent counters.</p>
<p><tt class="docutils literal"><span class="pre"><span class="Identifier">n</span></span></tt> must be <tt class="docutils literal"><span class="pre"><span class="Operator">&gt;=</span> <span class="DecNumber">1</span></span></tt>. <tt class="docutils literal"><span class="pre"><span class="Identifier">n</span> <span class="Operator">==</span> <span class="DecNumber">1</span></span></tt> advances every call (equivalent to calling <tt class="docutils literal"><span class="pre"><span class="Identifier">manager</span><span class="Operator">.</span><span class="Identifier">advance</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt> directly). Larger <tt class="docutils literal"><span class="pre"><span class="Identifier">n</span></span></tt> reduces atomic-store traffic at the cost of letting the limbo bag fill more between advances.</p>
<p>Typical cadences:</p>
<ul class="simple"><li><tt class="docutils literal"><span class="pre"><span class="Identifier">n</span> <span class="Operator">=</span> <span class="DecNumber">1</span></span></tt>: advance every call. Simplest; highest throughput cost.</li>
<li><tt class="docutils literal"><span class="pre"><span class="Identifier">n</span> <span class="Operator">=</span> <span class="DecNumber">32</span></span></tt> to <tt class="docutils literal"><span class="pre"><span class="Identifier">n</span> <span class="Operator">=</span> <span class="DecNumber">128</span></span></tt>: good general default for queue hot paths.</li>
<li><tt class="docutils literal"><span class="pre"><span class="Identifier">n</span> <span class="Operator">=</span> <span class="DecNumber">1024</span><span class="Operator">+</span></span></tt>: very low-overhead, but limbo bag may grow noticeably.</li>
</ul>
<p>See also: <a class="reference internal" href="#advance">advance</a>, <a class="reference internal" href="#reclaimNow">reclaimNow</a>, the <a class="reference external" href="../guide/epoch-advancement.md">epoch advancement guide</a>.</p>

### `reclaimNow`

```nim
proc reclaimNow[MT: static int; CC: static PinScopeCardinality = ccSingle](
    handle: ThreadHandle[MT, CC]): int
```

<p>Run one reclamation pass over the calling thread's own retired objects. Returns the number of objects reclaimed, or 0 if no epoch is currently safe to reclaim.</p>
<p>Pinning is not required: reclamation only inspects per-thread epochs. Each thread reclaims only its own bags; cross-thread reclamation is not supported because the bag list is mutated by the owning thread (via <tt class="docutils literal"><span class="pre"><span class="Identifier">retire</span></span></tt>) without synchronization.</p>
<p>See also: <a class="reference internal" href="#debra">debra</a>, <a class="reference internal" href="#advance">advance</a>.</p>

### `reclaimNow`

```nim
proc reclaimNow[MT: static int; CC: static PinScopeCardinality = ccSingle](
    manager: var DebraManager[MT, CC]): int
```

<p>Legacy wrapper: infers the calling thread's slot from <tt class="docutils literal"><span class="pre"><span class="Identifier">threadLocalIdx</span></span></tt> (set by <tt class="docutils literal"><span class="pre"><span class="Identifier">registerThread</span></span></tt>). Prefer <tt class="docutils literal"><span class="pre"><span class="Identifier">reclaimNow</span><span class="Punctuation">(</span><span class="Identifier">handle</span><span class="Punctuation">)</span></span></tt> for clarity and for safety from unregistered threads.</p>
<p>The <tt class="docutils literal"><span class="pre"><span class="Identifier">CC</span></span></tt> parameter binds via the <tt class="docutils literal"><span class="pre"><span class="Identifier">manager</span></span></tt> argument; callers that pass <tt class="docutils literal"><span class="pre"><span class="Identifier">DebraManager</span><span class="Punctuation">[</span><span class="Identifier">N</span><span class="Punctuation">]</span></span></tt> (CC default <tt class="docutils literal"><span class="pre"><span class="Identifier">ccSingle</span></span></tt>) keep the 0.7.x call shape, while <tt class="docutils literal"><span class="pre"><span class="Identifier">DebraManager</span><span class="Punctuation">[</span><span class="Identifier">N</span><span class="Punctuation">,</span> <span class="Identifier">ccMulti</span><span class="Punctuation">]</span></span></tt> is also accepted.</p>
<p>See also: <a class="reference internal" href="#debra">debra</a>, <a class="reference internal" href="#advance">advance</a>.</p>

### `retireAndReclaim`

```nim
proc retireAndReclaim[MT: static int; CC: static PinScopeCardinality = ccSingle](
    handle: ThreadHandle[MT, CC]; p: pointer; destructor: Destructor;
    eager: bool = true)
```

<p>Retire a pointer and optionally attempt immediate reclamation.</p>
<p>This convenience wrapper:</p>
<ol class="simple"><li>Pins the current thread</li>
<li>Retires the pointer with the given destructor</li>
<li>Unpins the thread</li>
<li>If eager=true (default), attempts to reclaim retired objects</li>
</ol>
<p>For batching multiple retirements before reclaiming, use the low-level typestate API directly or call with eager=false.</p>


## Templates

### `withPin`

```nim
template withPin[MT: static int; CC: static PinScopeCardinality = ccSingle](
    th: ThreadHandle[MT, CC]; body: untyped) {.deprecated: "use PinnedScope: var scope = pinScope(unpinned(handle)); see CHANGELOG.md#v0.8.0".}
```

<p>Pin the calling thread, run <tt class="docutils literal"><span class="pre"><span class="Identifier">body</span></span></tt>, unpin on exit (including raises).</p>
<p>Injects <tt class="docutils literal"><span class="pre"><span class="Identifier">it</span></span></tt> as a <tt class="docutils literal"><span class="pre"><span class="Keyword">var</span> <span class="Identifier">RetireReady</span><span class="Punctuation">[</span><span class="Identifier">MT</span><span class="Punctuation">,</span> <span class="Identifier">CC</span><span class="Punctuation">]</span></span></tt> (matches the Nim convention used by <tt class="docutils literal"><span class="pre"><span class="Identifier">filterIt</span></span></tt>/<tt class="docutils literal"><span class="pre"><span class="Identifier">mapIt</span></span></tt>). Body may call <tt class="docutils literal"><span class="pre"><span class="Identifier">it</span><span class="Operator">.</span><span class="Identifier">retire</span><span class="Punctuation">(</span><span class="Identifier">p</span><span class="Punctuation">,</span> <span class="Identifier">dtor</span><span class="Punctuation">)</span></span></tt> zero or more times. Using <tt class="docutils literal"><span class="pre"><span class="Identifier">it</span></span></tt> avoids collisions with the exported <tt class="docutils literal"><span class="pre"><span class="Identifier">pin</span></span></tt> proc from <tt class="docutils literal"><span class="pre"><span class="Identifier">debra</span><span class="Operator">/</span><span class="Identifier">typestates</span><span class="Operator">/</span><span class="Identifier">guard</span></span></tt>.</p>
<p>Asserts the thread is not already pinned on the given handle. The check uses <tt class="docutils literal"><span class="pre"><span class="Identifier">doAssert</span></span></tt> and fires in release builds too — nested pins on the same handle silently corrupt the EBR slot's <tt class="docutils literal"><span class="pre"><span class="Identifier">pinned</span></span></tt> flag bookkeeping, so this is a safety guard, not just a debug aid. Different-handle nesting (multi-manager) is independent and legal.</p>

<h2><a class="toc-backref" id="pitfall-—-neutralization" href="#pitfall-—-neutralization">Pitfall — neutralization</a></h2><p>If another thread calls <tt class="docutils literal"><span class="pre"><span class="Identifier">neutralizeStalled</span></span></tt> on this thread mid-body (because we stalled long enough that other threads' reclamation was blocked waiting on us), the SIGUSR1 handler force-unpins the slot and <tt class="docutils literal"><span class="pre"><span class="Identifier">unpin</span></span></tt> returns <tt class="docutils literal"><span class="pre"><span class="Identifier">Neutralized</span></span></tt>. This template honours the typestate by acknowledging the neutralization in its <tt class="docutils literal"><span class="pre"><span class="Keyword">finally</span></span></tt>, but it does <strong>not</strong> surface the fact to the caller. Code paths that need to know whether their critical section was interrupted (for example to roll back a non-idempotent side effect they performed inside the body) must use the explicit <tt class="docutils literal"><span class="pre"><span class="Identifier">unpinned</span><span class="Punctuation">(</span><span class="Identifier">handle</span><span class="Punctuation">)</span><span class="Operator">.</span><span class="Identifier">pin</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">pin</span><span class="Operator">.</span><span class="Identifier">unpin</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt> form and branch on <tt class="docutils literal"><span class="pre"><span class="Identifier">UnpinResult</span><span class="Operator">.</span><span class="Identifier">kind</span></span></tt>. Code paths that only read epoch-protected pointers do not need to — neutralization only fires on threads that have already stalled long enough for another thread to suspect them, which is a workload-level pathology, not a normal operating condition.</p>
<p>See also: <a class="reference internal" href="#debra">debra</a> (explicit transition), <a class="reference internal" href="#retire">retire</a>, <a class="reference internal" href="#retireBatch">retireBatch</a>, <a class="reference internal" href="#debra">debra</a>.</p>

### `withPin`

```nim
template withPin[MT: static int; CC: static PinScopeCardinality = ccSingle](
    th: ThreadHandle[MT, CC]; name, body: untyped) {.deprecated: "use PinnedScope: var scope = pinScope(unpinned(handle)); see CHANGELOG.md#v0.8.0".}
```

Deprecated pin helper variant that injects a caller-supplied identifier <tt class="docutils literal"><span class="pre"><span class="Identifier">name</span></span></tt> (instead of the default <tt class="docutils literal"><span class="pre"><span class="Identifier">it</span></span></tt>). Use to disambiguate nested handles across multiple managers. The neutralization pitfall described on the unnamed deprecated template applies here too — see that docstring before relying on this form for code paths that may be interrupted by <tt class="docutils literal"><span class="pre"><span class="Identifier">neutralizeStalled</span></span></tt>.

### `withEpoch`

```nim
template withEpoch[MT: static int; CC: static PinScopeCardinality = ccSingle](
    th: ThreadHandle[MT, CC]; body: untyped)
```

RAII convenience block for pinning an epoch during a critical section. Enters pinScope, executes body, and automatically unpins on scope exit via PinnedScope's RAII destructor (including on exceptions and returns).

### `withEpoch`

```nim
template withEpoch[MT: static int; CC: static PinScopeCardinality = ccSingle](
    th: ThreadHandle[MT, CC]; scopeVar, body: untyped)
```

RAII convenience block binding <tt class="docutils literal"><span class="pre"><span class="Identifier">scopeVar</span></span></tt> as <tt class="docutils literal"><span class="pre"><span class="Keyword">var</span> <span class="Identifier">RetireReady</span><span class="Punctuation">[</span><span class="Identifier">MT</span><span class="Punctuation">,</span> <span class="Identifier">CC</span><span class="Punctuation">]</span></span></tt> for retiring objects inside the critical section. Automatically unpins on exit.

