---
title: "lockfree/backoff"
description: "API reference for lockfree/backoff"
---

<p>lockfree/backoff</p>
<p>CAS-retry backoff policy for lockfree' typestate retry loops. Built on debra's <tt class="docutils literal"><span class="pre"><span class="Identifier">cpuPause</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">schedYield</span></span></tt> primitives. Two helpers:</p>
<ul class="simple"><li><tt class="docutils literal"><span class="pre"><span class="Identifier">backoffOnRetry</span></span></tt> - exponential backoff on CAS-failure retry. Doubles spin count each call up to MaxSpin; once spins reach YieldThreshold, also calls <tt class="docutils literal"><span class="pre"><span class="Identifier">schedYield</span></span></tt> to release the CPU quantum. Use at every <tt class="docutils literal"><span class="pre"><span class="Keyword">continue</span></span></tt> after a failed <tt class="docutils literal"><span class="pre"><span class="Identifier">tryClaim</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">compareExchange</span></span></tt> in a retry-until-success loop.</li>
<li><tt class="docutils literal"><span class="pre"><span class="Identifier">backoffOnPeerWait</span></span></tt> - cpuPause-only stateless backoff for short peer-completion waits (e.g. spinning on a committed flag set by a peer thread). No syscall, no state: peer publication latency is typically shorter than <tt class="docutils literal"><span class="pre"><span class="Identifier">sched_yield</span></span></tt>'s ~200ns-1us cost on Linux.</li>
</ul>
<p>State-passing pattern: <tt class="docutils literal"><span class="pre"><span class="Identifier">backoffOnRetry</span></span></tt> callers declare <tt class="docutils literal"><span class="pre"><span class="Keyword">var</span> <span class="Identifier">spins</span> <span class="Operator">=</span> <span class="Identifier">InitialSpin</span></span></tt> BEFORE entering the retry loop and pass it by <tt class="docutils literal"><span class="pre"><span class="Keyword">var</span></span></tt> reference; the helper mutates in place. <tt class="docutils literal"><span class="pre"><span class="Identifier">backoffOnPeerWait</span></span></tt> takes no arguments (stateless). The caller's success path adds zero instructions (helpers are only called on the failure edge, not per loop iteration unconditionally).</p>
<p>Constants are tunable via <tt class="docutils literal"><span class="pre"><span class="Operator">-</span><span class="Identifier">d</span><span class="Punctuation">:</span><span class="Identifier">LockfreeQueuesInitialSpin</span><span class="Operator">=</span><span class="Identifier">N</span></span></tt> etc. if a downstream user needs to retune for a specific workload, but defaults are chosen from lock-free literature (Mellor-Crummey/Scott, Anderson) and validated by Bencher gates.</p>
<p>NOTE: <tt class="docutils literal"><span class="pre"><span class="Identifier">cpuPause</span></span></tt> is named so (not <tt class="docutils literal"><span class="pre"><span class="Identifier">cpuRelax</span></span></tt>) in debra to avoid a collision with <tt class="docutils literal"><span class="pre"><span class="Identifier">system</span><span class="Operator">.</span><span class="Identifier">cpuRelax</span></span></tt> (re-exported from <tt class="docutils literal"><span class="pre"><span class="Identifier">std</span><span class="Operator">/</span><span class="Identifier">sysatomics</span></span></tt>). The stdlib version is a compiler-barrier-only fallback on non-x86; debra's <tt class="docutils literal"><span class="pre"><span class="Identifier">cpuPause</span></span></tt> emits the real <tt class="docutils literal"><span class="pre"><span class="Identifier">pause</span></span></tt>/<tt class="docutils literal"><span class="pre"><span class="Keyword">yield</span></span></tt> instruction.</p>


## Constants

### `InitialSpin`

```nim
InitialSpin {.intdefine.} = 4
```

Initial spin count for <tt class="docutils literal"><span class="pre"><span class="Identifier">backoffOnRetry</span></span></tt>. Caller initializes <tt class="docutils literal"><span class="pre"><span class="Keyword">var</span> <span class="Identifier">spins</span> <span class="Operator">=</span> <span class="Identifier">InitialSpin</span></span></tt> before the retry loop. Doubles each failed iteration.

### `MaxSpin`

```nim
MaxSpin {.intdefine.} = 256
```

Upper bound on <tt class="docutils literal"><span class="pre"><span class="Identifier">spins</span></span></tt> after exponential growth. Prevents runaway spin counts on pathologically contended workloads. 256 is aligned with Anderson/MCS exponential-cap norms (typical range 64-256): permissive enough to absorb high contention bursts without unbounded spin time, low enough that a worst-case spin completes in single-digit microseconds on modern x86/aarch64.

### `YieldThreshold`

```nim
YieldThreshold {.intdefine.} = 16
```

When <tt class="docutils literal"><span class="pre"><span class="Identifier">spins</span> <span class="Operator">&gt;=</span> <span class="Identifier">YieldThreshold</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">backoffOnRetry</span></span></tt> also calls <tt class="docutils literal"><span class="pre"><span class="Identifier">schedYield</span></span></tt> after the cpuPause burst. Below this threshold, stays in cpuPause-only mode (no syscall cost).


## Procedures & Functions

### `backoffOnRetry`

```nim
proc backoffOnRetry(spins: var int) {.inline, raises: [], tags: [], forbids: [].}
```

<p>Called on the failure path of a CAS-retry loop. Burns <tt class="docutils literal"><span class="pre"><span class="Identifier">spins</span></span></tt> cpuPause cycles, optionally yields the OS quantum if contention is escalating, then doubles <tt class="docutils literal"><span class="pre"><span class="Identifier">spins</span></span></tt> (capped at <tt class="docutils literal"><span class="pre"><span class="Identifier">MaxSpin</span></span></tt>).</p>
<p>Caller pattern: var spins = InitialSpin while true: ... if not tryClaim(...): backoffOnRetry(spins) continue ...</p>

### `backoffOnPeerWait`

```nim
proc backoffOnPeerWait() {.inline, raises: [], tags: [], forbids: [].}
```

<p>Called inside a tight <tt class="docutils literal"><span class="pre"><span class="Keyword">while</span> <span class="Identifier">peer</span><span class="Operator">-</span><span class="Identifier">flag</span><span class="Operator">-</span><span class="Keyword">not</span><span class="Operator">-</span><span class="Identifier">set</span><span class="Punctuation">:</span> <span class="Operator">...</span></span></tt> loop. Single cpuPause per call (no syscall, no state, no exponential growth). Stateless by design: peer publication latency is short enough that exponential growth and syscall escalation would overshoot.</p>
<p>Caller pattern (e.g. unbounded segment-local committed flag): while not seg.committed<a class="reference internal" href="#i">i</a>.load(moAcquire): backoffOnPeerWait()</p>

