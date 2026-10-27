---
title: "lockfree/smr/nebr/signal"
description: "API reference for lockfree/smr/nebr/signal"
---

<p>Thread neutralization for DEBRA+.</p>
<p>Two-arm implementation:</p>
<ul class="simple"><li><strong>POSIX</strong>: SIGUSR1 handler. Other threads send SIGUSR1; the handler runs asynchronously in the target's context and flips <tt class="docutils literal"><span class="pre"><span class="Identifier">pinned</span></span></tt>/<tt class="docutils literal"><span class="pre"><span class="Identifier">neutralized</span></span></tt> in the target's slot via raw pointer arithmetic (stride captured by <tt class="docutils literal"><span class="pre"><span class="Identifier">setGlobalManager</span></span></tt>).</li>
<li><strong>Windows</strong>: SuspendThread/ResumeThread. The scanner suspends the target, walks <tt class="docutils literal"><span class="pre"><span class="Identifier">manager</span><span class="Operator">.</span><span class="Identifier">threads</span><span class="Punctuation">[</span><span class="Punctuation">]</span></span></tt> via the same pointer arithmetic the POSIX handler uses, flips the slot, then resumes. There is no asynchronous handler; <tt class="docutils literal"><span class="pre"><span class="Identifier">installSignalHandler</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">forceReinstallSignalHandler</span></span></tt> are no-ops on this platform.</li>
</ul>
<p><strong>Deadlock constraint (both arms)</strong>: do not call DEBRA reclamation while holding a lock that other DEBRA-using threads might be blocked on. The constraint is the same on both platforms; the mechanism differs (signal-handler-side acquire on POSIX vs. scanner-side suspend-and-wait on Windows).</p>
<p>The cross-platform <tt class="docutils literal"><span class="pre"><span class="Identifier">neutralizeRemoteSlot</span></span></tt> entry point hides the difference from <tt class="docutils literal"><span class="pre"><span class="Identifier">neutralize</span><span class="Operator">.</span><span class="Identifier">scanAndSignal</span></span></tt>.</p>


## Procedures & Functions

### `installSignalHandler`

```nim
proc installSignalHandler() {.raises: [], tags: [], forbids: [].}
```

<p>Install SIGUSR1 handler for DEBRA+ neutralization.</p>
<p>Safe to call multiple times - subsequent calls are no-ops. Called automatically during first DebraManager initialization.</p>
<p>Thread-safety: the <tt class="docutils literal"><span class="pre"><span class="Identifier">signalHandlerInstalled</span></span></tt> flag is <tt class="docutils literal"><span class="pre"><span class="Identifier">Atomic</span><span class="Punctuation">[</span><span class="Identifier">bool</span><span class="Punctuation">]</span></span></tt>, acquire-loaded for the fast-path bail-out and release-stored after a successful <tt class="docutils literal"><span class="pre"><span class="Identifier">sigaction</span></span></tt>. Two threads may both observe the flag false and both call <tt class="docutils literal"><span class="pre"><span class="Identifier">sigaction</span></span></tt>; that is benign because <tt class="docutils literal"><span class="pre"><span class="Identifier">sigaction</span></span></tt> is thread-safe and re-arming the same handler is idempotent at the OS level.</p>

### `isSignalHandlerInstalled`

```nim
proc isSignalHandlerInstalled(): bool {.raises: [], tags: [], forbids: [].}
```

Check if signal handler has been installed.

### `forceReinstallSignalHandler`

```nim
proc forceReinstallSignalHandler() {.raises: [], tags: [], forbids: [].}
```

Re-install the SIGUSR1 handler unconditionally, bypassing the <tt class="docutils literal"><span class="pre"><span class="Identifier">signalHandlerInstalled</span></span></tt> idempotency flag. Intended for test isolation: when a sibling test installs a different SIGUSR1 handler via direct <tt class="docutils literal"><span class="pre"><span class="Identifier">sigaction</span></span></tt> (e.g. the placeholder in <tt class="docutils literal"><span class="pre"><span class="Identifier">typestates</span><span class="Operator">/</span><span class="Identifier">signal_handler</span></span></tt>), the OS-level handler is overwritten even though <tt class="docutils literal"><span class="pre"><span class="Identifier">signalHandlerInstalled</span></span></tt> remains true. Calling this restores the real <tt class="docutils literal"><span class="pre"><span class="Identifier">neutralizationHandler</span></span></tt>. Not part of the library's public surface for normal use; prefer <tt class="docutils literal"><span class="pre"><span class="Identifier">installSignalHandler</span></span></tt> in production code.

### `neutralizeRemoteSlot`

```nim
proc neutralizeRemoteSlot(tid: ThreadId; slot: int) {.raises: [], tags: [],
    forbids: [].}
```

<p>Force-unpin and mark-neutralized a remote thread's slot.</p>
<p>Validates <tt class="docutils literal"><span class="pre"><span class="Identifier">slot</span></span></tt> is in <tt class="docutils literal"><span class="pre"><span class="Punctuation">[</span><span class="DecNumber">0</span><span class="Punctuation">,</span> <span class="Identifier">maxThreadsBound</span><span class="Punctuation">)</span></span></tt>; raises <tt class="docutils literal"><span class="pre"><span class="Identifier">AssertionDefect</span></span></tt> on out-of-bounds. The Windows arm performs raw pointer arithmetic against the published manager layout, so an out-of-range slot would otherwise read/write arbitrary memory past the <tt class="docutils literal"><span class="pre"><span class="Identifier">threads</span></span></tt> array. The bound is captured by <tt class="docutils literal"><span class="pre"><span class="Identifier">setGlobalManager</span></span></tt>; before that publish the bound is zero, which rejects every non-negative slot — the safe default.</p>
<p><strong>POSIX arm</strong>: sends <tt class="docutils literal"><span class="pre"><span class="Identifier">QuiescentSignal</span></span></tt> (SIGUSR1) to <tt class="docutils literal"><span class="pre"><span class="Identifier">tid</span></span></tt>. The handler installed by <tt class="docutils literal"><span class="pre"><span class="Identifier">installSignalHandler</span></span></tt> runs asynchronously in the target's context, reads the target's <tt class="docutils literal"><span class="pre"><span class="Identifier">threadLocalIdx</span></span></tt>, and flips the slot. The <tt class="docutils literal"><span class="pre"><span class="Identifier">slot</span></span></tt> argument is unused (kept for API parity).</p>
<p><strong>Windows arm</strong>: suspends <tt class="docutils literal"><span class="pre"><span class="Identifier">tid</span></span></tt> (which is a duplicated thread Handle), walks the published global manager to find slot <tt class="docutils literal"><span class="pre"><span class="Identifier">slot</span></span></tt>, flips <tt class="docutils literal"><span class="pre"><span class="Identifier">pinned</span></span></tt> to false and <tt class="docutils literal"><span class="pre"><span class="Identifier">neutralized</span></span></tt> to true under release ordering, then resumes the thread. The walk uses the same pointer-arithmetic descriptor (<tt class="docutils literal"><span class="pre"><span class="Identifier">globalManagerPtr</span></span></tt> + <tt class="docutils literal"><span class="pre"><span class="Identifier">threadsArrayOffsetBytes</span></span></tt> + <tt class="docutils literal"><span class="pre"><span class="Identifier">threadStateStrideBytes</span></span></tt>) that the POSIX handler uses, so the layout invariants asserted at the top of this file apply identically.</p>
<p>Both arms are no-ops when <tt class="docutils literal"><span class="pre"><span class="Identifier">tid</span></span></tt> is not valid.</p>
<p><strong>Deadlock note</strong>: see module-level comment. On Windows, the scanner blocks inside <tt class="docutils literal"><span class="pre"><span class="Identifier">SuspendThread</span></span></tt> only briefly (kernel suspends, returns); the slot-flip is wait-free. The risk is the target holding a lock that the scanner needs <em>after</em> this call.</p>

### `setGlobalManager`

```nim
proc setGlobalManager[MaxThreads: static int;
                      CC: static PinScopeCardinality = ccSingle](
    manager: ptr DebraManager[MaxThreads, CC])
```

<p>Set the global manager pointer for the signal handler and capture the byte-stride information the handler needs to find each thread's slot.</p>
<p>Must be called once after manager initialization, before any thread sends SIGUSR1. Safe to call repeatedly with the same manager; passing a different manager replaces the captured layout. Pass <tt class="docutils literal"><span class="pre"><span class="Keyword">nil</span></span></tt> via the untyped overload below to clear the global manager.</p>
<p><strong>Race constraint:</strong> This routine MUST NOT race with signal delivery. Either call it before any thread is registered, or fully quiesce all threads (no in-flight or pending SIGUSR1) before replacing the manager. The three atomic stores (header, stride, pointer) are not a single transaction: a signal arriving partway through could observe stride/header from one manager paired with the pointer from another, and if the two managers were instantiated with different <tt class="docutils literal"><span class="pre"><span class="Identifier">MaxThreads</span></span></tt> their layouts differ. The release/acquire edge below makes the <em>intra-call</em> publish order consistent (a reader who sees the new pointer also sees the new stride/header), but it does not make the call as a whole atomic with respect to a concurrent reader, and it does not protect against a reader pairing the <em>new</em> pointer with the <em>old</em> stride that was just overwritten.</p>
<p>On Windows the same descriptor is consumed by <tt class="docutils literal"><span class="pre"><span class="Identifier">neutralizeRemoteSlot</span></span></tt> running on the scanner thread, so the race constraint is identical (the scanner is the &quot;reader&quot; here, not an async handler).</p>

### `setGlobalManager`

```nim
proc setGlobalManager(manager: pointer) {.raises: [], tags: [], forbids: [].}
```

<p>Untyped overload, retained so callers (including tests) can clear the global manager by passing <tt class="docutils literal"><span class="pre"><span class="Keyword">nil</span></span></tt>. Passing a non-nil raw pointer is unsupported because the handler needs the per-type stride; callers with a typed <tt class="docutils literal"><span class="pre"><span class="Keyword">ptr</span> <span class="Identifier">DebraManager</span><span class="Punctuation">[</span><span class="Identifier">N</span><span class="Punctuation">]</span></span></tt> should use the generic overload above.</p>
<p><strong>Race constraint:</strong> Same as the typed overload — must not race with signal delivery. Quiesce all registered threads before clearing the manager.</p>

