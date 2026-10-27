---
title: "lockfree/atomics/backoff"
description: "API reference for lockfree/atomics/backoff"
---

<p>debra/atomics/backoff</p>
<p>Spin-loop hint primitives for lock-free retry loops. Two procs:</p>
<ul class="simple"><li><tt class="docutils literal"><span class="pre"><span class="Identifier">cpuPause</span></span></tt> - per-CPU spin-loop hint (no syscall, no thread yield). Tells the CPU to back off cache-coherency traffic inside a tight retry loop (<tt class="docutils literal"><span class="pre"><span class="Identifier">pause</span></span></tt> on x86/x64, <tt class="docutils literal"><span class="pre"><span class="Keyword">yield</span></span></tt> on 32-bit ARM and aarch64). Emitted as inline asm under GCC/Clang and as the matching <tt class="docutils literal"><span class="pre"><span class="Identifier">_mm_pause</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Keyword">__yield</span></span></tt> intrinsic under MSVC. Compiles to a no-op on architectures or compilers without an established hint instruction; correctness is preserved, only micro-efficiency is lost. Named <tt class="docutils literal"><span class="pre"><span class="Identifier">cpuPause</span></span></tt> (not <tt class="docutils literal"><span class="pre"><span class="Identifier">cpuRelax</span></span></tt>) to avoid collision with <tt class="docutils literal"><span class="pre"><span class="Identifier">std</span><span class="Operator">/</span><span class="Identifier">sysatomics</span><span class="Operator">.</span><span class="Identifier">cpuRelax</span></span></tt> (re-exported via <tt class="docutils literal"><span class="pre"><span class="Identifier">system</span></span></tt> unless <tt class="docutils literal"><span class="pre"><span class="Operator">-</span><span class="Identifier">d</span><span class="Punctuation">:</span><span class="Identifier">nimPreviewSlimSystem</span></span></tt>). The stdlib version is a compiler-barrier-only fallback on non-x86 (no hardware <tt class="docutils literal"><span class="pre"><span class="Keyword">yield</span></span></tt>/<tt class="docutils literal"><span class="pre"><span class="Identifier">pause</span></span></tt> hint emitted); this implementation provides the real <tt class="docutils literal"><span class="pre"><span class="Keyword">yield</span></span></tt> hint.</li>
<li><tt class="docutils literal"><span class="pre"><span class="Identifier">schedYield</span></span></tt> - releases the current thread's CPU quantum back to the OS scheduler. Use when a CAS-retry loop has spun long enough that the holder is likely descheduled (oversubscribed runqueue). Maps to <tt class="docutils literal"><span class="pre"><span class="Identifier">sched_yield</span><span class="Punctuation">(</span><span class="DecNumber">2</span><span class="Punctuation">)</span></span></tt> on POSIX (Linux, macOS, BSDs) and <tt class="docutils literal"><span class="pre"><span class="Identifier">SwitchToThread</span></span></tt> on Windows. No-op on other targets.</li>
</ul>
<p>Both procs are <tt class="docutils literal"><span class="pre"><span class="Punctuation">{</span><span class="Operator">.</span><span class="Identifier">inline</span><span class="Operator">.</span><span class="Punctuation">}</span></span></tt> and have zero overhead when not invoked (no per-iteration cost on the success path of a CAS loop).</p>


## Procedures & Functions

### `cpuPause`

```nim
proc cpuPause() {.inline, raises: [], tags: [], forbids: [].}
```

### `schedYield`

```nim
proc schedYield() {.inline, raises: [], tags: [], forbids: [].}
```

