---
title: "lockfree/smr/nebr/types"
description: "API reference for lockfree/smr/nebr/types"
---

Core types for DEBRA+ implementation.


## Types

### `ThreadState`

```nim
ThreadState[MaxThreads] = object
  epoch* {.align: 8.}: Atomic[uint64] ## Last observed global epoch.
  pinned* {.align: 8.}: Atomic[bool] ## Whether thread is currently in a critical section.
  neutralized* {.align: 8.}: Atomic[bool] ## Whether thread was force-unpinned by signal.
  threadId* {.align: 8.}: Atomic[ThreadId] ## Thread identifier for sending signals.
  currentBag*: ptr LimboBag  ## Currently filling limbo bag.
  limboBagTail*: ptr LimboBag ## Tail of limbo bag list (oldest).
  advanceCounter*: uint64
```

Per-thread state tracked by the DEBRA manager.

### `DebraManager`

```nim
DebraManager[MaxThreads; CC] = object
  globalEpoch* {.align: 128.}: Atomic[uint64] ## Global epoch counter.
  activeThreadMask* {.align: 128.}: Atomic[uint64] ## Bitmask of registered threads.
  boundClients* {.align: 128.}: Atomic[int] ## Refcount of clients (e.g. lock-free data structures) currently bound to
                                            ## this manager via `bindClient` / `unbindClient`. The destructor asserts
                                            ## this is zero so a client cannot outlive its manager. Cache-line aligned
                                            ## to keep client bind/unbind off the hot `globalEpoch` and
                                            ## `activeThreadMask` lines.
  threads* {.align: 128.}: array[MaxThreads, ThreadState[MaxThreads]] ## Per-thread state. Cache-line aligned to prevent false sharing across
                                                                      ## the per-thread slots (each slot is owned by a different thread, so
                                                                      ## adjacent slots sharing a cache line would cause false-sharing on every
                                                                      ## atomic write).
```

<p>Coordinates epoch-based reclamation across threads.</p>
<p>The <tt class="docutils literal"><span class="pre"><span class="Identifier">CC</span></span></tt> parameter (introduced in 0.8.0) is the consumer-cardinality phantom that propagates through <tt class="docutils literal"><span class="pre"><span class="Identifier">ThreadHandle</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">registerThread</span></span></tt>, and the EBR typestate graphs. It defaults to <tt class="docutils literal"><span class="pre"><span class="Identifier">ccSingle</span></span></tt> so 0.7.x call shapes compile unchanged; downstream queues set it to <tt class="docutils literal"><span class="pre"><span class="Identifier">ccMulti</span></span></tt> when multi-consumer retire-races are possible. See <a class="reference internal" href="#debra">debra</a>.</p>

### `ThreadHandle`

```nim
ThreadHandle[MaxThreads; CC] = object
  idx*: int                  ## Index into the threads array.
  manager*: ptr DebraManager[MaxThreads, CC] ## Pointer to the manager.
```

<p>Handle for a registered thread. Required for pin/unpin.</p>
<p>The <tt class="docutils literal"><span class="pre"><span class="Identifier">CC</span></span></tt> parameter (introduced in 0.8.0) carries the consumer cardinality of the pin scopes this handle will open. It defaults to <tt class="docutils literal"><span class="pre"><span class="Identifier">ccSingle</span></span></tt> so 0.7.x call shapes compile unchanged.</p>

### `DebraRegistrationError`

```nim
DebraRegistrationError = object of CatchableError
```

Raised when thread registration fails (e.g., max threads reached).


## Procedures & Functions

### `initDebraManager`

```nim
proc initDebraManager[MaxThreads: static int;
                      CC: static PinScopeCardinality = ccSingle](): DebraManager[
    MaxThreads, CC]
```

<p>Initialize a new DEBRA+ manager.</p>
<p>Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">DebraManager</span><span class="Punctuation">[</span><span class="Identifier">MaxThreads</span><span class="Punctuation">,</span> <span class="Identifier">CC</span><span class="Punctuation">]</span></span></tt>. The <tt class="docutils literal"><span class="pre"><span class="Identifier">CC</span></span></tt> axis is not inferable from a zero-argument call, so it defaults to <tt class="docutils literal"><span class="pre"><span class="Identifier">ccSingle</span></span></tt> to keep the 0.7.x-style <tt class="docutils literal"><span class="pre"><span class="Identifier">initDebraManager</span><span class="Punctuation">[</span><span class="Identifier">N</span><span class="Punctuation">]</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt> call shape working unchanged. Callers that want <tt class="docutils literal"><span class="pre"><span class="Identifier">ccMulti</span></span></tt> spell it explicitly: <tt class="docutils literal"><span class="pre"><span class="Identifier">initDebraManager</span><span class="Punctuation">[</span><span class="Identifier">N</span><span class="Punctuation">,</span> <span class="Identifier">ccMulti</span><span class="Punctuation">]</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt>.</p>
<p>The global epoch starts at 1 (not 0) so that epoch 0 can represent &quot;never observed&quot; in thread state.</p>

### ``=destroy``

```nim
proc `=destroy`[MaxThreads: static int; CC: static PinScopeCardinality](
    manager: var DebraManager[MaxThreads, CC]) {.raises: [].}
```

<p>Drain all per-thread limbo bags when the manager goes out of scope.</p>
<p>Worker threads must have joined before the manager is destroyed (the bag lists are owned by their respective slots without synchronization, so concurrent retire during destruction is undefined). Process-exit and end-of-scope cleanup is the typical caller.</p>
<p>Asserts via <tt class="docutils literal"><span class="pre"><span class="Identifier">doAssert</span></span></tt> that no clients are still bound (<tt class="docutils literal"><span class="pre"><span class="Identifier">boundClients</span> <span class="Operator">==</span> <span class="DecNumber">0</span></span></tt>). A non-zero count means a data structure built on this manager (e.g. a lock-free queue) is being destroyed after its manager, which is a programmer error: the client will continue to call into freed manager state. The assertion fires in release builds because the downstream UB is silent.</p>
<p>Without this, retire-but-not-yet-reclaimed objects (and the limbo bags that hold them) leak under ASAN at exit. With aggressive Manual strategies or short-lived managers, the leak is observable.</p>

