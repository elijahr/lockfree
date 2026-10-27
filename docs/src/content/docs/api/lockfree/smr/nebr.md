---
title: "lockfree/smr/nebr"
description: "API reference for lockfree/smr/nebr"
---

<p>lockfree/smr/nebr: NEBR Safe Memory Reclamation</p>
<p>NEBR = Neutralization-Enhanced Bounded Reclamation. This module is the in-tree fork of nim-debra. Semantically identical to upstream nim-debra except for import paths.</p>
<p>Public facade re-exporting the manager + neutralize substrate plus the thread-registration, epoch, and client-binding helpers that downstream consumers (Queue<a class="reference internal" href="#T">T</a> with ref payloads, the destructor walk) need.</p>
<p>Design refs: nim-debra design §3.1, §3.7.</p>


## Procedures & Functions

### `registerThread`

```nim
proc registerThread[MaxThreads: static int; CC: static PinScopeCardinality](
    manager: var DebraManager[MaxThreads, CC]): ThreadHandle[MaxThreads, CC] {.
    raises: [DebraRegistrationError].}
```

<p>Register current thread with the NEBR manager.</p>
<p>Must be called once per thread before any epoch operations. Raises DebraRegistrationError if max threads already registered.</p>

### `unregisterThread`

```nim
proc unregisterThread[MaxThreads: static int;
                      CC: static PinScopeCardinality = ccSingle](
    manager: var DebraManager[MaxThreads, CC];
    handle: ThreadHandle[MaxThreads, CC]) {.raises: [].}
```

<p>Unregister the current thread from the NEBR manager, releasing the slot it claimed via <tt class="docutils literal"><span class="pre"><span class="Identifier">registerThread</span></span></tt> so a future <tt class="docutils literal"><span class="pre"><span class="Identifier">registerThread</span></span></tt> may re-claim that slot index for a different thread.</p>
<p><strong>Caller contract (preconditions).</strong> Both must hold or this proc fails a <tt class="docutils literal"><span class="pre"><span class="Identifier">doAssert</span></span></tt> (see &quot;Failure behavior&quot; below):</p>
<ol class="simple"><li><strong>Unpinned.</strong> The calling thread MUST have exited <em>all</em> pin scopes before calling. The slot's <tt class="docutils literal"><span class="pre"><span class="Identifier">pinned</span></span></tt> flag must be clear. Calling from inside a critical section is a programming error.</li>
<li><strong>Drained limbo.</strong> The calling thread MUST have drained its own retired/limbo objects before calling, i.e. run reclamation until it reclaims nothing — <tt class="docutils literal"><span class="pre"><span class="Identifier">reclaimNow</span><span class="Punctuation">(</span><span class="Identifier">handle</span><span class="Punctuation">)</span></span></tt> (the convenience entry point; underlying mechanism <tt class="docutils literal"><span class="pre"><span class="Identifier">tryReclaim</span></span></tt>) until it returns <tt class="docutils literal"><span class="pre"><span class="DecNumber">0</span></span></tt>. The slot's <tt class="docutils literal"><span class="pre"><span class="Identifier">currentBag</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">limboBagTail</span></span></tt> must be <tt class="docutils literal"><span class="pre"><span class="Keyword">nil</span></span></tt>. Unregistering with pending limbo is a programming error.</li>
</ol>
<p><strong>Why the contract exists.</strong> Releasing the slot lets <tt class="docutils literal"><span class="pre"><span class="Identifier">registerThread</span></span></tt> re-claim THIS slot index for a DIFFERENT thread; <tt class="docutils literal"><span class="pre"><span class="Identifier">register</span></span></tt> reuses the slot in place and does not re-initialise its epoch/pinned/limbo state. So any state left here is inherited verbatim by the next owner:</p>
<ul class="simple"><li>A departing thread's still-pending retired objects are NOT necessarily epoch-safe to free yet, and NEBR keeps NO manager-level orphan-reclaim list — it cannot adopt them. Eagerly freeing them here would be a premature-free UAF; leaving them on a reused slot would let the new owner's <tt class="docutils literal"><span class="pre"><span class="Identifier">tryReclaim</span></span></tt> walk them under a different epoch (a stale-slot use-after-free / double-free). Requiring the caller to drain first is the conservative resolution of both hazards.</li>
<li>A stale <tt class="docutils literal"><span class="pre"><span class="Identifier">pinned</span> <span class="Operator">=</span> <span class="Identifier">true</span></span></tt> would make reclamation observe this slot as pinned forever, stalling ALL reclamation manager-wide.</li>
</ul>
<p><strong>Failure behavior.</strong> Contract violations are reported via <tt class="docutils literal"><span class="pre"><span class="Identifier">doAssert</span></span></tt> (this proc is <tt class="docutils literal"><span class="pre"><span class="Punctuation">{</span><span class="Operator">.</span><span class="Identifier">raises</span><span class="Punctuation">:</span> <span class="Punctuation">[</span><span class="Punctuation">]</span><span class="Operator">.</span><span class="Punctuation">}</span></span></tt>, a compile-time-pinned contract, so it cannot raise). In debug builds a violation aborts loudly. Under <tt class="docutils literal"><span class="pre"><span class="Operator">-</span><span class="Identifier">d</span><span class="Punctuation">:</span><span class="Identifier">danger</span></span></tt> assertions are compiled out, so violating the contract is undefined behavior (the very slot-reuse UAF / double-free this contract prevents) rather than a loud abort. Treat the contract as mandatory in all builds, not merely as a debug aid.</p>
<p>A handle with an out-of-range index, a slot whose <tt class="docutils literal"><span class="pre"><span class="Identifier">activeThreadMask</span></span></tt> bit is already clear (double-unregister), or a thread-affinity mismatch is handled before the precondition checks: the first two return silently; the affinity mismatch is its own <tt class="docutils literal"><span class="pre"><span class="Identifier">doAssert</span></span></tt>.</p>

### `neutralizeStalled`

```nim
proc neutralizeStalled[MaxThreads: static int;
                       CC: static PinScopeCardinality = ccSingle](
    manager: var DebraManager[MaxThreads, CC];
    epochsBeforeNeutralize: uint64 = 2): int
```

Signal all stalled threads. Returns number of signals sent.

### `advance`

```nim
proc advance[MaxThreads: static int; CC: static PinScopeCardinality = ccSingle](
    manager: var DebraManager[MaxThreads, CC]) {.inline.}
```

Advance the global epoch.

### `currentEpoch`

```nim
proc currentEpoch[MaxThreads: static int;
                  CC: static PinScopeCardinality = ccSingle](
    manager: var DebraManager[MaxThreads, CC]): uint64 {.inline.}
```

Get current global epoch.

### `bindClient`

```nim
proc bindClient[MaxThreads: static int;
                CC: static PinScopeCardinality = ccSingle](
    manager: var DebraManager[MaxThreads, CC]) {.inline.}
```

Register a client as bound to this manager. Increments <tt class="docutils literal"><span class="pre"><span class="Identifier">boundClients</span></span></tt>.

### `unbindClient`

```nim
proc unbindClient[MaxThreads: static int;
                  CC: static PinScopeCardinality = ccSingle](
    manager: var DebraManager[MaxThreads, CC]) {.inline.}
```

Unregister a client previously bound via <tt class="docutils literal"><span class="pre"><span class="Identifier">bindClient</span></span></tt>.

### `clientCount`

```nim
proc clientCount[MaxThreads: static int;
                 CC: static PinScopeCardinality = ccSingle](
    manager: var DebraManager[MaxThreads, CC]): int {.inline.}
```

Number of clients currently bound to this manager.

