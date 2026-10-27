---
title: "lockfree/smr/nebr/thread_id"
description: "API reference for lockfree/smr/nebr/thread_id"
---

<p>Platform-abstracted thread identifier for thread neutralization.</p>
<p>DEBRA+ needs a way to (a) identify the calling thread and (b) interrupt a stalled remote thread so the reclaimer can advance. The mechanism is platform-specific:</p>
<ul class="simple"><li><strong>POSIX</strong> (Linux, macOS, BSD): the identifier is a <tt class="docutils literal"><span class="pre"><span class="Identifier">Pthread</span></span></tt>. Remote neutralization is done by <tt class="docutils literal"><span class="pre"><span class="Identifier">pthread_kill</span><span class="Punctuation">(</span><span class="Identifier">tid</span><span class="Punctuation">,</span> <span class="Identifier">SIGUSR1</span><span class="Punctuation">)</span></span></tt> which delivers an asynchronous signal; the SIGUSR1 handler in <tt class="docutils literal"><span class="pre"><span class="Identifier">signal</span><span class="Operator">.</span><span class="Identifier">nim</span></span></tt> flips the target slot's <tt class="docutils literal"><span class="pre"><span class="Identifier">pinned</span></span></tt>/<tt class="docutils literal"><span class="pre"><span class="Identifier">neutralized</span></span></tt> flags. The <tt class="docutils literal"><span class="pre"><span class="Identifier">sendSignal</span></span></tt> proc is the primary entry point on POSIX.</li>
<li><strong>Windows</strong>: the identifier is the raw OS thread ID (<tt class="docutils literal"><span class="pre"><span class="Identifier">uint32</span></span></tt>, the <tt class="docutils literal"><span class="pre"><span class="Identifier">DWORD</span></span></tt> returned by <tt class="docutils literal"><span class="pre"><span class="Identifier">GetCurrentThreadId</span></span></tt>). It is OS-managed — no kernel handle is allocated, duplicated, or stored. Remote neutralization uses <tt class="docutils literal"><span class="pre"><span class="Identifier">SuspendThread</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">ResumeThread</span></span></tt>: the scanner opens a temporary handle via <tt class="docutils literal"><span class="pre"><span class="Identifier">OpenThread</span><span class="Punctuation">(</span><span class="Identifier">THREAD_SUSPEND_RESUME</span><span class="Punctuation">)</span></span></tt>, suspends the target, directly flips its slot via the same pointer-arithmetic walk that the POSIX signal handler uses, resumes, then <tt class="docutils literal"><span class="pre"><span class="Identifier">CloseHandle</span></span></tt>s in a <tt class="docutils literal"><span class="pre"><span class="Keyword">finally</span></span></tt> block. Handle lifetime is the duration of a single <tt class="docutils literal"><span class="pre"><span class="Identifier">neutralizeRemoteSlot</span></span></tt> call. This avoids the async-signal-safety constraints of the POSIX path; <tt class="docutils literal"><span class="pre"><span class="Identifier">signal</span><span class="Operator">.</span><span class="Identifier">nim</span></span></tt>'s handler-install machinery is a no-op on Windows. An earlier v0.10.0-dev design stored a duplicated handle in the slot; that design carried a bounded handle leak on slot churn and a use-after-close race between scanner and unregister. The on-demand <tt class="docutils literal"><span class="pre"><span class="Identifier">OpenThread</span></span></tt>/<tt class="docutils literal"><span class="pre"><span class="Identifier">CloseHandle</span></span></tt> design eliminates both by construction.</li>
</ul>
<p><strong>Deadlock constraint (both platforms)</strong>: do NOT call DEBRA reclamation while holding a lock that other DEBRA-using threads might be blocked on. On POSIX the SIGUSR1 handler runs in the target's context and may need to acquire shared state; on Windows a <tt class="docutils literal"><span class="pre"><span class="Identifier">SuspendThread</span></span></tt>'d target that holds a lock will deadlock the scanner if the scanner waits on that lock. Same hazard, different mechanism.</p>
<p>Cross-thread state mutation (the slot flip) lives in <tt class="docutils literal"><span class="pre"><span class="Identifier">neutralizeRemoteSlot</span></span></tt> so the call site in <tt class="docutils literal"><span class="pre"><span class="Identifier">neutralize</span><span class="Operator">.</span><span class="Identifier">scanAndSignal</span></span></tt> stays platform-neutral.</p>


## Types

### `ThreadId`

```nim
ThreadId = object
```

Platform-abstracted thread identifier (POSIX arm).


## Procedures & Functions

### `currentThreadId`

```nim
proc currentThreadId(): ThreadId {.raises: [], tags: [], forbids: [].}
```

Get the ThreadId of the current thread.

### `isCurrent`

```nim
proc isCurrent(tid: ThreadId): bool {.inline, raises: [], tags: [], forbids: [].}
```

Non-allocating identity check: returns true iff <tt class="docutils literal"><span class="pre"><span class="Identifier">tid</span></span></tt> refers to the calling thread. Mirrors the Windows arm — on POSIX <tt class="docutils literal"><span class="pre"><span class="Identifier">pthread_self</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt> is cheap (no kernel call), so the no-alloc guarantee is structural rather than a meaningful perf win, but the API parity matters for the cross-platform call site in <tt class="docutils literal"><span class="pre"><span class="Identifier">neutralize</span><span class="Operator">.</span><span class="Identifier">scanAndSignal</span></span></tt>.

### ``==``

```nim
proc `==`(a, b: ThreadId): bool {.raises: [], tags: [], forbids: [].}
```

Compare two ThreadIds for equality.

### ``$``

```nim
proc `$`(tid: ThreadId): string {.raises: [], tags: [], forbids: [].}
```

Render a <tt class="docutils literal"><span class="pre"><span class="Identifier">ThreadId</span></span></tt> for diagnostics. The auto-generated stringifier tries to format the underlying <tt class="docutils literal"><span class="pre"><span class="Identifier">Pthread</span></span></tt> (an opaque struct pointer on some POSIX platforms) as an integer, which fails to compile; we render the pointer bits as hex instead. Used by <tt class="docutils literal"><span class="pre"><span class="Identifier">unittest2</span><span class="Operator">.</span><span class="Identifier">check</span></span></tt> when an equality assertion involving a <tt class="docutils literal"><span class="pre"><span class="Identifier">ThreadId</span></span></tt> fails.

### `isValid`

```nim
proc isValid(tid: ThreadId): bool {.raises: [], tags: [], forbids: [].}
```

Check if this ThreadId represents a valid thread.

### `sendSignal`

```nim
proc sendSignal(tid: ThreadId; sig: cint): cint {.raises: [], tags: [],
    forbids: [].}
```

<p>Send a signal to the thread identified by tid. <strong>POSIX only.</strong></p>
<p>Returns 0 on success. Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">ESRCH</span></span></tt> immediately when <tt class="docutils literal"><span class="pre"><span class="Identifier">tid</span></span></tt> equals <tt class="docutils literal"><span class="pre"><span class="Identifier">InvalidThreadId</span></span></tt>; otherwise returns the error code from <tt class="docutils literal"><span class="pre"><span class="Identifier">pthread_kill</span></span></tt>.</p>
<p>Note: POSIX explicitly leaves <tt class="docutils literal"><span class="pre"><span class="Identifier">pthread_kill</span></span></tt> with an invalid <tt class="docutils literal"><span class="pre"><span class="Identifier">pthread_t</span></span></tt> as undefined behavior. Apple's libpthread happens to validate and return <tt class="docutils literal"><span class="pre"><span class="Identifier">ESRCH</span></span></tt>, but glibc dereferences the handle and may segfault. Callers must only pass either a live thread's id or <tt class="docutils literal"><span class="pre"><span class="Identifier">InvalidThreadId</span></span></tt>; passing a fabricated non-zero handle is unsupported.</p>

### `unsafeThreadId`

```nim
proc unsafeThreadId(handle: Pthread): ThreadId {.raises: [], tags: [],
    forbids: [].}
```

Create a ThreadId from a raw Pthread handle. For testing purposes only.

### `unsafeThreadIdFromInt`

```nim
proc unsafeThreadIdFromInt(value: int): ThreadId {.raises: [], tags: [],
    forbids: [].}
```

Create a ThreadId from an integer value. For testing purposes only - creates a fake thread ID.


## Templates

### `InvalidThreadId`

```nim
template InvalidThreadId(): ThreadId
```

