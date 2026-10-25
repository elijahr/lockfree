---
title: "lockfree/atomics"
description: "API reference for lockfree/atomics"
---

<p>debra/atomics</p>
<p>Custom atomics for nebr (and lockfree).</p>
<p>Goals over std/atomics:</p>
<ul class="simple"><li>Reject <tt class="docutils literal"><span class="pre"><span class="Identifier">Atomic</span><span class="Punctuation">[</span><span class="Keyword">ref</span> <span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> at compile time (no silent spinlock).</li>
<li>Require <tt class="docutils literal"><span class="pre"><span class="Identifier">Atomic</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> to be lock-free at compile time.</li>
<li>Validate <tt class="docutils literal"><span class="pre"><span class="Identifier">MemoryOrder</span></span></tt> per op at compile time.</li>
<li>Statically assert <tt class="docutils literal"><span class="pre"><span class="Identifier">alignof</span><span class="Punctuation">(</span><span class="Identifier">Atomic</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span><span class="Punctuation">)</span> <span class="Operator">&gt;=</span> <span class="Identifier">sizeof</span><span class="Punctuation">(</span><span class="Identifier">T</span><span class="Punctuation">)</span></span></tt> so a target where <tt class="docutils literal"><span class="pre"><span class="Identifier">T</span></span></tt>'s natural alignment is insufficient (e.g. <tt class="docutils literal"><span class="pre"><span class="Identifier">uint64</span></span></tt> on some 32-bit ABIs) fails to compile rather than silently downgrading to a non-lock-free split-lock object. The assert is the safety boundary; we cannot force alignment higher than the type's natural alignment from generic code (see <tt class="docutils literal"><span class="pre"><span class="Identifier">Atomic</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> doc), so we trap the mismatch instead.</li>
</ul>
<p>Design doc: docs/design/2026-04-25-custom-atomics.md</p>
<p>User guide: see docs/guide/atomics.md for a side-by-side comparison with std/atomics, the DWCAS surface overview, memory-order policy, cross-compiler/arch compatibility matrix, and an LCRQ-style worked example.</p>
<p>Backend strategy: wrap GCC/Clang <tt class="docutils literal"><span class="pre"><span class="Identifier">__atomic_</span><span class="Operator">*</span><span class="Identifier">_n</span></span></tt> builtins for the unix toolchains (gcc, clang, llvm_gcc, nintendoswitch), and MSVC's <tt class="docutils literal"><span class="pre"><span class="Identifier">_Interlocked</span><span class="Operator">*</span></span></tt> intrinsics family (declared in <tt class="docutils literal"><span class="pre"><span class="Operator">&lt;</span><span class="Identifier">intrin</span><span class="Operator">.</span><span class="Identifier">h</span><span class="Operator">&gt;</span></span></tt>) for vcc. The MSVC arms cover the full 1-, 2-, 4-, and 8-byte <tt class="docutils literal"><span class="pre"><span class="Identifier">Atomic</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> surface plus AtomicFlag, fences, and the 16-byte DWCAS via <tt class="docutils literal"><span class="pre"><span class="Identifier">_InterlockedCompareExchange128</span></span></tt>.</p>
<p>DWCAS (16-byte) emit logic adapted from atomic128 (<a class="reference external" href="https://github.com/patternnoster/atomic128">https://github.com/patternnoster/atomic128</a>) by patternnoster, MIT licensed. See atomic128_ref.hpp for the C++ reference implementation that documents the GCC __sync vs __atomic footgun this code works around. Pinned upstream commit: d45ba3d348a9620a25552f9cf50dc7ccef05ef90. See THIRD_PARTY_LICENSES.md for the verbatim MIT text.</p>
<tt class="docutils literal"><span class="pre"><span class="Identifier">CacheLineBytes</span></span></tt>: bytes per L1 cache line. 128 on PowerPC, 64 elsewhere. Override with <tt class="docutils literal"><span class="pre"><span class="Operator">-</span><span class="Identifier">d</span><span class="Punctuation">:</span><span class="Identifier">CacheLineBytes</span><span class="Operator">=</span><span class="Identifier">N</span></span></tt>.


## Types

### `MemoryOrder`

```nim
MemoryOrder = enum
  moRelaxed,                ## No ordering constraints.
  moConsume,                ## Accepted, mapped to moAcquire (mirrors std).
  moAcquire,                ## No reordering of subsequent loads/stores before.
  moRelease,                ## No reordering of preceding loads/stores after.
  moAcquireRelease,         ## Both acquire and release on RMW.
  moSequentiallyConsistent   ## Single total order across all SC ops.
```

Specifies how non-atomic operations can be reordered around atomic operations. Ordinals match GCC's <tt class="docutils literal"><span class="pre"><span class="Identifier">__ATOMIC_</span><span class="Operator">*</span></span></tt> so <tt class="docutils literal"><span class="pre"><span class="Identifier">ord</span><span class="Punctuation">(</span><span class="Identifier">order</span><span class="Punctuation">)</span></span></tt> is passed directly to the builtins.

### `Pair`

```nim
Pair[A; B] = object
  first* {.align: 16.}: A
  second*: B
```

<p>16-byte-aligned object wrapper for DWCAS. Both halves must satisfy <tt class="docutils literal"><span class="pre"><span class="Identifier">supportsCopyMem</span></span></tt>, each must be <tt class="docutils literal"><span class="pre"><span class="Operator">&lt;=</span> <span class="DecNumber">8</span></span></tt> bytes, and <tt class="docutils literal"><span class="pre"><span class="Identifier">sizeof</span><span class="Punctuation">(</span><span class="Identifier">A</span><span class="Punctuation">)</span> <span class="Operator">+</span> <span class="Identifier">sizeof</span><span class="Punctuation">(</span><span class="Identifier">B</span><span class="Punctuation">)</span></span></tt> must equal 16. Domain-neutral field names: <tt class="docutils literal"><span class="pre"><span class="Identifier">first</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">second</span></span></tt>.</p>
<p>Conventional LCRQ usage spells <tt class="docutils literal"><span class="pre"><span class="Identifier">Pair</span><span class="Punctuation">[</span><span class="Identifier">uint64</span><span class="Punctuation">,</span> <span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> where <tt class="docutils literal"><span class="pre"><span class="Identifier">first</span></span></tt> is a monotonically-bumped sequence counter (ABA defense) and <tt class="docutils literal"><span class="pre"><span class="Identifier">second</span></span></tt> is the payload. Generation overflow is documented as impossible in practical lifetimes (uint64 monotonicity).</p>
<p>Field-level <tt class="docutils literal"><span class="pre"><span class="Punctuation">{</span><span class="Operator">.</span><span class="Identifier">align</span><span class="Punctuation">:</span> <span class="FloatNumber">16.</span><span class="Punctuation">}</span></span></tt> on <tt class="docutils literal"><span class="pre"><span class="Identifier">first</span><span class="Operator">*</span></span></tt> elevates the whole object to 16-byte alignment per Nim 2.2.10 align-pragma scope rules; the object-level form (<tt class="docutils literal"><span class="pre"><span class="Keyword">type</span> <span class="Identifier">Pair</span> <span class="Punctuation">{</span><span class="Operator">.</span><span class="Identifier">align</span><span class="Punctuation">:</span> <span class="FloatNumber">16.</span><span class="Punctuation">}</span> <span class="Operator">=</span> <span class="Keyword">object</span> <span class="Operator">...</span></span></tt>) is rejected.</p>
<p><tt class="docutils literal"><span class="pre"><span class="Keyword">ptr</span> <span class="Identifier">T</span></span></tt> fields are explicitly opt-out of ARC: <tt class="docutils literal"><span class="pre"><span class="Identifier">Pair</span></span></tt> makes no claim on the lifetime of whatever a contained <tt class="docutils literal"><span class="pre"><span class="Keyword">ptr</span></span></tt> points at.</p>
<p>See <tt class="docutils literal"><span class="pre"><span class="Identifier">docs</span><span class="Operator">/</span><span class="Identifier">guide</span><span class="Operator">/</span><span class="Identifier">atomics</span><span class="Operator">.</span><span class="Identifier">md</span></span></tt> §7 for an LCRQ-style worked example using <tt class="docutils literal"><span class="pre"><span class="Identifier">Pair</span><span class="Punctuation">[</span><span class="Identifier">uint64</span><span class="Punctuation">,</span> <span class="Keyword">ptr</span> <span class="Identifier">Node</span><span class="Punctuation">]</span></span></tt>.</p>

### `Atomic`

```nim
Atomic[T] = object
```

<p>Atomic wrapper for <tt class="docutils literal"><span class="pre"><span class="Identifier">T</span></span></tt>. Lock-free on this target; rejects <tt class="docutils literal"><span class="pre"><span class="Keyword">ref</span> <span class="Identifier">T</span></span></tt>.</p>
<p>Supports 1-, 2-, 4-, and 8-byte types only. 16-byte types (<tt class="docutils literal"><span class="pre"><span class="Identifier">__int128</span></span></tt>, double-quadword pointers) require a different code path (<tt class="docutils literal"><span class="pre"><span class="Identifier">cmpxchg16b</span></span></tt> on x86_64, <tt class="docutils literal"><span class="pre"><span class="Identifier">casp</span></span></tt> on aarch64) and are not currently provided. Such instantiations fail with a compile-time <tt class="docutils literal"><span class="pre"><span class="Punctuation">{</span><span class="Operator">.</span><span class="Identifier">error</span><span class="Operator">.</span><span class="Punctuation">}</span></span></tt> from the underlying <tt class="docutils literal"><span class="pre"><span class="Identifier">nonAtomicType</span></span></tt> template.</p>
<p>Note on alignment: Nim's field-level <tt class="docutils literal"><span class="pre"><span class="Punctuation">{</span><span class="Operator">.</span><span class="Identifier">align</span><span class="Punctuation">:</span> <span class="Operator">...</span><span class="Punctuation">}</span></span></tt> pragma cannot reference <tt class="docutils literal"><span class="pre"><span class="Identifier">sizeof</span><span class="Punctuation">(</span><span class="Identifier">T</span><span class="Punctuation">)</span></span></tt> from a generic context (as of Nim 2.2.6 it triggers <tt class="docutils literal"><span class="pre"><span class="Identifier">sizeof</span> <span class="Identifier">requires</span> <span class="Operator">.</span><span class="Identifier">importc</span> <span class="Identifier">types</span> <span class="Identifier">to</span> <span class="Identifier">be</span> <span class="Operator">.</span><span class="Identifier">completeStruct</span></span></tt>). We therefore rely on <tt class="docutils literal"><span class="pre"><span class="Identifier">T</span></span></tt>'s natural alignment — which is <tt class="docutils literal"><span class="pre"><span class="Operator">&gt;=</span> <span class="Identifier">sizeof</span><span class="Punctuation">(</span><span class="Identifier">T</span><span class="Punctuation">)</span></span></tt> for the primitives we ship on every 64-bit ABI we currently target, but is <strong>not</strong> universally true. Notably, on i386 System V <tt class="docutils literal"><span class="pre"><span class="Identifier">alignof</span><span class="Punctuation">(</span><span class="Identifier">uint64</span><span class="Punctuation">)</span> <span class="Operator">==</span> <span class="DecNumber">4</span></span></tt>, which would yield a split-lock object that is not always-lock-free.</p>
<p><tt class="docutils literal"><span class="pre"><span class="Identifier">enforceAtomicConstraints</span></span></tt> therefore fires <tt class="docutils literal"><span class="pre"><span class="Keyword">static</span><span class="Punctuation">:</span> <span class="Identifier">assert</span> <span class="Identifier">alignof</span><span class="Punctuation">(</span><span class="Identifier">Atomic</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span><span class="Punctuation">)</span> <span class="Operator">&gt;=</span> <span class="Identifier">sizeof</span><span class="Punctuation">(</span><span class="Identifier">T</span><span class="Punctuation">)</span></span></tt> per instantiation; a target where natural alignment is insufficient fails to compile rather than silently producing a non-lock-free object. If we ever need to support such a target, the fix is a per-size specialisation that boxes <tt class="docutils literal"><span class="pre"><span class="Identifier">T</span></span></tt> in a struct with an explicit <tt class="docutils literal"><span class="pre"><span class="Punctuation">{</span><span class="Operator">.</span><span class="Identifier">align</span><span class="Punctuation">:</span> <span class="FloatNumber">8.</span><span class="Punctuation">}</span></span></tt> (or similar) field; the generic path cannot do better today.</p>

### `AtomicFlag`

```nim
AtomicFlag = distinct uint8
```

Boolean flag with <tt class="docutils literal"><span class="pre"><span class="Identifier">testAndSet</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">clear</span></span></tt> semantics. Underlying byte must be 0 or 1; <tt class="docutils literal"><span class="pre"><span class="Identifier">__atomic_test_and_set</span></span></tt> is implementation-defined for any other value, so do not poke the raw uint8 directly.


## Constants

### `supportsDwcas`

```nim
supportsDwcas = true
```

<p>Compile-time predicate indicating whether the target architecture and toolchain provide 128-bit hardware Double-Word Compare-And-Swap (DWCAS).</p>
<p>True on 64-bit x86 (cmpxchg16b), 64-bit ARM (casp under FEAT_LSE or ldxp/stxp), and MSVC on x64/ARM64 (_InterlockedCompareExchange128). False on 32-bit platforms, WebAssembly, and architectures without 128-bit atomics.</p>


## Procedures & Functions

### `hasManagedFields`

```nim
proc hasManagedFields(T: typedesc): bool {.compileTime.}
```

### `load`

```nim
proc load[T](loc: var Atomic[T];
             order: static MemoryOrder = moSequentiallyConsistent): T {.inline.}
```

### `store`

```nim
proc store[T](loc: var Atomic[T]; desired: T;
              order: static MemoryOrder = moSequentiallyConsistent) {.inline.}
```

### `exchange`

```nim
proc exchange[T](loc: var Atomic[T]; desired: T;
                 order: static MemoryOrder = moSequentiallyConsistent): T {.
    inline.}
```

### `compareExchangeStrong`

```nim
proc compareExchangeStrong[T](loc: var Atomic[T]; expected: var T; desired: T;
                              success: static MemoryOrder;
                              failure: static MemoryOrder): bool {.inline.}
```

Strong CAS. On success, swaps <tt class="docutils literal"><span class="pre"><span class="Identifier">desired</span></span></tt> into <tt class="docutils literal"><span class="pre"><span class="Identifier">loc</span></span></tt>. On failure, overwrites <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> with the current value of <tt class="docutils literal"><span class="pre"><span class="Identifier">loc</span></span></tt>.

### `compareExchangeWeak`

```nim
proc compareExchangeWeak[T](loc: var Atomic[T]; expected: var T; desired: T;
                            success: static MemoryOrder;
                            failure: static MemoryOrder): bool {.inline.}
```

Weak CAS. May fail spuriously on platforms (notably ARM LL/SC) even when current value equals <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt>. Cheaper inside a loop.

### `compareExchangeStrong`

```nim
proc compareExchangeStrong[T](loc: var Atomic[T]; expected: var T; desired: T;
                              order: static MemoryOrder): bool {.inline.}
```

Strong CAS, single-order form. Failure order is derived from success per C11 (drop the release component): <tt class="docutils literal"><span class="pre"><span class="Identifier">moRelease</span></span></tt> -&gt; <tt class="docutils literal"><span class="pre"><span class="Identifier">moRelaxed</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">moAcquireRelease</span></span></tt> -&gt; <tt class="docutils literal"><span class="pre"><span class="Identifier">moAcquire</span></span></tt>, otherwise unchanged. Use the five-arg form to spell the failure order explicitly.

### `compareExchangeWeak`

```nim
proc compareExchangeWeak[T](loc: var Atomic[T]; expected: var T; desired: T;
                            order: static MemoryOrder): bool {.inline.}
```

Weak CAS, single-order form. Failure order is derived from success per <tt class="docutils literal"><span class="pre"><span class="Identifier">compareExchangeStrong</span></span></tt>'s single-order overload.

### `compareExchangeStrong`

```nim
proc compareExchangeStrong[T](loc: var Atomic[T]; expected: var T; desired: T): bool {.
    inline.}
```

Strong CAS, default-order form. Equivalent to passing <tt class="docutils literal"><span class="pre"><span class="Identifier">moSequentiallyConsistent</span></span></tt> for both success and failure.

### `compareExchangeWeak`

```nim
proc compareExchangeWeak[T](loc: var Atomic[T]; expected: var T; desired: T): bool {.
    inline.}
```

Weak CAS, default-order form. Equivalent to passing <tt class="docutils literal"><span class="pre"><span class="Identifier">moSequentiallyConsistent</span></span></tt> for both success and failure.

### `compareExchange`

```nim
proc compareExchange[T](loc: var Atomic[T]; expected: var T; desired: T;
                        success: static MemoryOrder; failure: static MemoryOrder): bool {.
    inline.}
```

Strong compare-and-exchange. Unsuffixed-name alias for <tt class="docutils literal"><span class="pre"><span class="Identifier">compareExchangeStrong</span></span></tt>, matching the spelling used by clients migrating from <tt class="docutils literal"><span class="pre"><span class="Identifier">std</span><span class="Operator">/</span><span class="Identifier">atomics</span></span></tt>.

### `compareExchange`

```nim
proc compareExchange[T](loc: var Atomic[T]; expected: var T; desired: T;
                        order: static MemoryOrder): bool {.inline.}
```

Strong CAS, single-order form. Failure order is derived from success per C11 (drop the release component). Alias for <tt class="docutils literal"><span class="pre"><span class="Identifier">compareExchangeStrong</span></span></tt>.

### `compareExchange`

```nim
proc compareExchange[T](loc: var Atomic[T]; expected: var T; desired: T): bool {.
    inline.}
```

Strong CAS, default-order form. Equivalent to passing <tt class="docutils literal"><span class="pre"><span class="Identifier">moSequentiallyConsistent</span></span></tt> for both success and failure. Alias for <tt class="docutils literal"><span class="pre"><span class="Identifier">compareExchangeStrong</span></span></tt>.

### `fetchAdd`

```nim
proc fetchAdd[T: SomeInteger](loc: var Atomic[T]; v: T; order: static
    MemoryOrder = moSequentiallyConsistent): T {.inline.}
```

### `fetchSub`

```nim
proc fetchSub[T: SomeInteger](loc: var Atomic[T]; v: T; order: static
    MemoryOrder = moSequentiallyConsistent): T {.inline.}
```

### `fetchAnd`

```nim
proc fetchAnd[T: SomeInteger](loc: var Atomic[T]; v: T; order: static
    MemoryOrder = moSequentiallyConsistent): T {.inline.}
```

### `fetchOr`

```nim
proc fetchOr[T: SomeInteger](loc: var Atomic[T]; v: T; order: static MemoryOrder = moSequentiallyConsistent): T {.
    inline.}
```

### `fetchXor`

```nim
proc fetchXor[T: SomeInteger](loc: var Atomic[T]; v: T; order: static
    MemoryOrder = moSequentiallyConsistent): T {.inline.}
```

### `fetchAdd`

```nim
proc fetchAdd[T: SomeFloat](loc: var Atomic[T]; v: T; order: static MemoryOrder = moSequentiallyConsistent): T {.
    inline.}
```

<p>Atomically add <tt class="docutils literal"><span class="pre"><span class="Identifier">v</span></span></tt> to the float value at <tt class="docutils literal"><span class="pre"><span class="Identifier">loc</span></span></tt> and return the previous value. Implemented as a <tt class="docutils literal"><span class="pre"><span class="Identifier">compareExchangeWeak</span></span></tt> CAS-loop because GCC's <tt class="docutils literal"><span class="pre"><span class="Identifier">__atomic_fetch_add_n</span></span></tt> is integer-only.</p>
<p>Semantics: the read-add-CAS cycle is repeated until the CAS succeeds, so the returned old value and the new stored value together reflect a coherent atomic update of <tt class="docutils literal"><span class="pre"><span class="Identifier">loc</span></span></tt>. Under contention, the loop may iterate multiple times.</p>
<p><tt class="docutils literal"><span class="pre"><span class="Identifier">order</span></span></tt> is applied to the successful CAS; the failure order is derived per C11 (drops the release component).</p>
<p>Bit-pattern fidelity caveat: <tt class="docutils literal"><span class="pre"><span class="Identifier">fetchAdd</span></span></tt> performs an IEEE-754 float addition; unlike <tt class="docutils literal"><span class="pre"><span class="Identifier">load</span></span></tt>/<tt class="docutils literal"><span class="pre"><span class="Identifier">store</span></span></tt>/<tt class="docutils literal"><span class="pre"><span class="Identifier">exchange</span></span></tt>/<tt class="docutils literal"><span class="pre"><span class="Identifier">compareExchange</span><span class="Operator">*</span></span></tt> (pure bitwise transfer), the bit-pattern guarantees do NOT apply to the <em>new stored value</em>. Specifically:</p>
<ul class="simple"><li>The returned old value IS bit-exact: it comes from a relaxed load before the add and reflects the pre-RMW storage bits verbatim (so e.g. a NaN payload in <tt class="docutils literal"><span class="pre"><span class="Identifier">loc</span></span></tt> is preserved in the return value).</li>
<li>The new stored value is <tt class="docutils literal"><span class="pre"><span class="Identifier">old</span> <span class="Operator">+</span> <span class="Identifier">v</span></span></tt> computed by the FPU, which means: NaN payloads are not preserved across the add (e.g. <tt class="docutils literal"><span class="pre"><span class="Identifier">NaN_payload_A</span> <span class="Operator">+</span> <span class="FloatNumber">1.0</span></span></tt> yields a quiet NaN with implementation- defined payload, not <tt class="docutils literal"><span class="pre"><span class="Identifier">payload_A</span></span></tt>); denormal results may flush to zero if FTZ/DAZ is enabled in the calling thread's FPU state; the rounding mode is whatever the FPU is currently set to (round-to-nearest by default; modifiable via <tt class="docutils literal"><span class="pre"><span class="Identifier">fesetround</span></span></tt> on x86 or FPCR on ARM); and overflow produces +/-Inf.</li>
</ul>
<p>The CAS-loop preserves atomicity; these caveats are inherent to float arithmetic, not to this implementation.</p>

### `threadFence`

```nim
proc threadFence(order: MemoryOrder) {.inline, raises: [], tags: [], forbids: [].}
```

Full memory fence between threads. All memory orders are valid.

### `signalFence`

```nim
proc signalFence(order: MemoryOrder) {.inline, raises: [], tags: [], forbids: [].}
```

Compiler-only fence. Prevents the compiler from reordering across the fence; emits no CPU instructions. All memory orders are valid.

### `testAndSet`

```nim
proc testAndSet(loc: var AtomicFlag;
                order: static MemoryOrder = moSequentiallyConsistent): bool {.
    inline.}
```

Atomically set the flag and return its previous value.

### `clear`

```nim
proc clear(loc: var AtomicFlag;
           order: static MemoryOrder = moSequentiallyConsistent) {.inline.}
```

Atomically reset the flag to false. <tt class="docutils literal"><span class="pre"><span class="Identifier">order</span></span></tt> must not be moAcquire / moAcquireRelease / moConsume.

### `load`

```nim
proc load[A, B](loc: var Atomic[Pair[A, B]];
                order: static MemoryOrder = moSequentiallyConsistent): Pair[A, B] {.
    inline.}
```

16-byte atomic load via DWCAS substrate. Returns the current value of <tt class="docutils literal"><span class="pre"><span class="Identifier">loc</span></span></tt> as a <tt class="docutils literal"><span class="pre"><span class="Identifier">Pair</span><span class="Punctuation">[</span><span class="Identifier">A</span><span class="Punctuation">,</span> <span class="Identifier">B</span><span class="Punctuation">]</span></span></tt>. Always seq_cst at the instruction level; sub-seq_cst <tt class="docutils literal"><span class="pre"><span class="Identifier">order</span></span></tt> values are accepted but upgraded with a compile- time warning.

### `store`

```nim
proc store[A, B](loc: var Atomic[Pair[A, B]]; desired: Pair[A, B];
                 order: static MemoryOrder = moSequentiallyConsistent) {.inline.}
```

16-byte atomic store via DWCAS substrate. Always seq_cst at the instruction level; sub-seq_cst <tt class="docutils literal"><span class="pre"><span class="Identifier">order</span></span></tt> values emit a compile-time warning.

### `exchange`

```nim
proc exchange[A, B](loc: var Atomic[Pair[A, B]]; desired: Pair[A, B];
                    order: static MemoryOrder = moSequentiallyConsistent): Pair[
    A, B] {.inline.}
```

16-byte atomic exchange via DWCAS substrate. Atomically replaces the value at <tt class="docutils literal"><span class="pre"><span class="Identifier">loc</span></span></tt> with <tt class="docutils literal"><span class="pre"><span class="Identifier">desired</span></span></tt> and returns the prior value. Always seq_cst at the instruction level; sub-seq_cst <tt class="docutils literal"><span class="pre"><span class="Identifier">order</span></span></tt> values emit a compile-time warning.

### `compareExchangeStrong`

```nim
proc compareExchangeStrong[A, B](loc: var Atomic[Pair[A, B]];
                                 expected: var Pair[A, B]; desired: Pair[A, B];
                                 success: static MemoryOrder;
                                 failure: static MemoryOrder): bool {.inline.}
```

<p>Strong 16-byte CAS via DWCAS. On success, swaps <tt class="docutils literal"><span class="pre"><span class="Identifier">desired</span></span></tt> into <tt class="docutils literal"><span class="pre"><span class="Identifier">loc</span></span></tt> and returns true; <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> is unchanged. On failure, overwrites <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> with the current value of <tt class="docutils literal"><span class="pre"><span class="Identifier">loc</span></span></tt> and returns false. Always seq_cst at the instruction level; sub-seq_cst <tt class="docutils literal"><span class="pre"><span class="Identifier">success</span></span></tt>/<tt class="docutils literal"><span class="pre"><span class="Identifier">failure</span></span></tt> values emit a compile-time warning.</p>
<p>ABA / aliasing note: <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">desired</span></span></tt> MUST be distinct memory locations. On CAS failure, <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> is overwritten in-place with the current value of <tt class="docutils literal"><span class="pre"><span class="Identifier">loc</span></span></tt>; on success, <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> is unchanged. Passing the same <tt class="docutils literal"><span class="pre"><span class="Keyword">var</span></span></tt> location for both <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">desired</span></span></tt> is a defined-but-confusing pattern (the desired payload is read first, then <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> is overwritten — but if <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">desired</span></span></tt> alias, the post-CAS <tt class="docutils literal"><span class="pre"><span class="Identifier">desired</span></span></tt> is undefined). Callers MUST NOT alias them. The 1/2/4/8-byte CAS surface has the same contract; the 16-byte ops re-document it here because the wider value makes accidental aliasing more tempting in LCRQ-style consumer code.</p>

### `compareExchangeStrong`

```nim
proc compareExchangeStrong[A, B](loc: var Atomic[Pair[A, B]];
                                 expected: var Pair[A, B]; desired: Pair[A, B];
                                 order: static MemoryOrder): bool {.inline.}
```

<p>Strong 16-byte CAS, single-order form. Failure order is derived from <tt class="docutils literal"><span class="pre"><span class="Identifier">order</span></span></tt> per C11 (drop the release component).</p>
<p>ABA / aliasing note: <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">desired</span></span></tt> MUST be distinct memory locations. On CAS failure, <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> is overwritten in-place with the current value of <tt class="docutils literal"><span class="pre"><span class="Identifier">loc</span></span></tt>; on success, <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> is unchanged. Passing the same <tt class="docutils literal"><span class="pre"><span class="Keyword">var</span></span></tt> location for both <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">desired</span></span></tt> is a defined-but-confusing pattern (the desired payload is read first, then <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> is overwritten — but if <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">desired</span></span></tt> alias, the post-CAS <tt class="docutils literal"><span class="pre"><span class="Identifier">desired</span></span></tt> is undefined). Callers MUST NOT alias them. The 1/2/4/8-byte CAS surface has the same contract; the 16-byte ops re-document it here because the wider value makes accidental aliasing more tempting in LCRQ-style consumer code.</p>

### `compareExchangeStrong`

```nim
proc compareExchangeStrong[A, B](loc: var Atomic[Pair[A, B]];
                                 expected: var Pair[A, B]; desired: Pair[A, B]): bool {.
    inline.}
```

<p>Strong 16-byte CAS, default-order form. Equivalent to passing <tt class="docutils literal"><span class="pre"><span class="Identifier">moSequentiallyConsistent</span></span></tt> for both success and failure.</p>
<p>ABA / aliasing note: <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">desired</span></span></tt> MUST be distinct memory locations. On CAS failure, <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> is overwritten in-place with the current value of <tt class="docutils literal"><span class="pre"><span class="Identifier">loc</span></span></tt>; on success, <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> is unchanged. Passing the same <tt class="docutils literal"><span class="pre"><span class="Keyword">var</span></span></tt> location for both <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">desired</span></span></tt> is a defined-but-confusing pattern (the desired payload is read first, then <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> is overwritten — but if <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">desired</span></span></tt> alias, the post-CAS <tt class="docutils literal"><span class="pre"><span class="Identifier">desired</span></span></tt> is undefined). Callers MUST NOT alias them. The 1/2/4/8-byte CAS surface has the same contract; the 16-byte ops re-document it here because the wider value makes accidental aliasing more tempting in LCRQ-style consumer code.</p>

### `compareExchangeWeak`

```nim
proc compareExchangeWeak[A, B](loc: var Atomic[Pair[A, B]];
                               expected: var Pair[A, B]; desired: Pair[A, B];
                               success: static MemoryOrder;
                               failure: static MemoryOrder): bool {.inline.}
```

<p>Weak 16-byte CAS via DWCAS. May fail spuriously only on ARMv8.0 LL/SC cores (no LSE), where <tt class="docutils literal"><span class="pre"><span class="Identifier">stlxp</span></span></tt> is permitted to fail without contention. On all other supported targets weak and strong are equivalent: x86_64 (<tt class="docutils literal"><span class="pre"><span class="Identifier">cmpxchg16b</span></span></tt>) is always-strong; arm64 with FEAT_LSE / LSE2 (Apple Silicon, modern server chips) emits <tt class="docutils literal"><span class="pre"><span class="Identifier">caspal</span></span></tt> for both procs (objdump-verified on Apple Silicon). Default to <tt class="docutils literal"><span class="pre"><span class="Identifier">compareExchangeStrong</span></span></tt>; reach for Weak only after measuring a contention win on an ARMv8.0 target.</p>
<p>ABA / aliasing note: <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">desired</span></span></tt> MUST be distinct memory locations. On CAS failure, <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> is overwritten in-place with the current value of <tt class="docutils literal"><span class="pre"><span class="Identifier">loc</span></span></tt>; on success, <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> is unchanged. Passing the same <tt class="docutils literal"><span class="pre"><span class="Keyword">var</span></span></tt> location for both <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">desired</span></span></tt> is a defined-but-confusing pattern (the desired payload is read first, then <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> is overwritten — but if <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">desired</span></span></tt> alias, the post-CAS <tt class="docutils literal"><span class="pre"><span class="Identifier">desired</span></span></tt> is undefined). Callers MUST NOT alias them. The 1/2/4/8-byte CAS surface has the same contract; the 16-byte ops re-document it here because the wider value makes accidental aliasing more tempting in LCRQ-style consumer code.</p>

### `compareExchangeWeak`

```nim
proc compareExchangeWeak[A, B](loc: var Atomic[Pair[A, B]];
                               expected: var Pair[A, B]; desired: Pair[A, B];
                               order: static MemoryOrder): bool {.inline.}
```

<p>Weak 16-byte CAS, single-order form. Failure order is derived from <tt class="docutils literal"><span class="pre"><span class="Identifier">order</span></span></tt> per C11 (drop the release component).</p>
<p>ABA / aliasing note: <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">desired</span></span></tt> MUST be distinct memory locations. On CAS failure, <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> is overwritten in-place with the current value of <tt class="docutils literal"><span class="pre"><span class="Identifier">loc</span></span></tt>; on success, <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> is unchanged. Passing the same <tt class="docutils literal"><span class="pre"><span class="Keyword">var</span></span></tt> location for both <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">desired</span></span></tt> is a defined-but-confusing pattern (the desired payload is read first, then <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> is overwritten — but if <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">desired</span></span></tt> alias, the post-CAS <tt class="docutils literal"><span class="pre"><span class="Identifier">desired</span></span></tt> is undefined). Callers MUST NOT alias them. The 1/2/4/8-byte CAS surface has the same contract; the 16-byte ops re-document it here because the wider value makes accidental aliasing more tempting in LCRQ-style consumer code.</p>

### `compareExchangeWeak`

```nim
proc compareExchangeWeak[A, B](loc: var Atomic[Pair[A, B]];
                               expected: var Pair[A, B]; desired: Pair[A, B]): bool {.
    inline.}
```

<p>Weak 16-byte CAS, default-order form. Equivalent to passing <tt class="docutils literal"><span class="pre"><span class="Identifier">moSequentiallyConsistent</span></span></tt> for both success and failure. Mirrors the <tt class="docutils literal"><span class="pre"><span class="Identifier">compareExchangeStrong</span></span></tt> default-order overload so that the two overload sets match shape-for-shape — relevant for callers migrating from <tt class="docutils literal"><span class="pre"><span class="Identifier">std</span><span class="Operator">/</span><span class="Identifier">atomics</span></span></tt>, whose <tt class="docutils literal"><span class="pre"><span class="Identifier">compareExchange</span><span class="Operator">*</span></span></tt> procs all accept the no-order form.</p>
<p>ABA / aliasing note: <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">desired</span></span></tt> MUST be distinct memory locations. On CAS failure, <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> is overwritten in-place with the current value of <tt class="docutils literal"><span class="pre"><span class="Identifier">loc</span></span></tt>; on success, <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> is unchanged. Passing the same <tt class="docutils literal"><span class="pre"><span class="Keyword">var</span></span></tt> location for both <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">desired</span></span></tt> is a defined-but-confusing pattern (the desired payload is read first, then <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> is overwritten — but if <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">desired</span></span></tt> alias, the post-CAS <tt class="docutils literal"><span class="pre"><span class="Identifier">desired</span></span></tt> is undefined). Callers MUST NOT alias them. The 1/2/4/8-byte CAS surface has the same contract; the 16-byte ops re-document it here because the wider value makes accidental aliasing more tempting in LCRQ-style consumer code.</p>

### `compareExchange`

```nim
proc compareExchange[A, B](loc: var Atomic[Pair[A, B]];
                           expected: var Pair[A, B]; desired: Pair[A, B];
                           success: static MemoryOrder;
                           failure: static MemoryOrder): bool {.inline.}
```

<p>Strong 16-byte CAS. Unsuffixed-name alias for <tt class="docutils literal"><span class="pre"><span class="Identifier">compareExchangeStrong</span></span></tt>, matching the spelling used by clients migrating from <tt class="docutils literal"><span class="pre"><span class="Identifier">std</span><span class="Operator">/</span><span class="Identifier">atomics</span></span></tt>.</p>
<p>ABA / aliasing note: <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">desired</span></span></tt> MUST be distinct memory locations. On CAS failure, <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> is overwritten in-place with the current value of <tt class="docutils literal"><span class="pre"><span class="Identifier">loc</span></span></tt>; on success, <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> is unchanged. Passing the same <tt class="docutils literal"><span class="pre"><span class="Keyword">var</span></span></tt> location for both <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">desired</span></span></tt> is a defined-but-confusing pattern (the desired payload is read first, then <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> is overwritten — but if <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">desired</span></span></tt> alias, the post-CAS <tt class="docutils literal"><span class="pre"><span class="Identifier">desired</span></span></tt> is undefined). Callers MUST NOT alias them. The 1/2/4/8-byte CAS surface has the same contract; the 16-byte ops re-document it here because the wider value makes accidental aliasing more tempting in LCRQ-style consumer code.</p>

### `compareExchange`

```nim
proc compareExchange[A, B](loc: var Atomic[Pair[A, B]];
                           expected: var Pair[A, B]; desired: Pair[A, B];
                           order: static MemoryOrder): bool {.inline.}
```

<p>Strong 16-byte CAS, single-order form. Alias for <tt class="docutils literal"><span class="pre"><span class="Identifier">compareExchangeStrong</span></span></tt>.</p>
<p>ABA / aliasing note: <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">desired</span></span></tt> MUST be distinct memory locations. On CAS failure, <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> is overwritten in-place with the current value of <tt class="docutils literal"><span class="pre"><span class="Identifier">loc</span></span></tt>; on success, <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> is unchanged. Passing the same <tt class="docutils literal"><span class="pre"><span class="Keyword">var</span></span></tt> location for both <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">desired</span></span></tt> is a defined-but-confusing pattern (the desired payload is read first, then <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> is overwritten — but if <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">desired</span></span></tt> alias, the post-CAS <tt class="docutils literal"><span class="pre"><span class="Identifier">desired</span></span></tt> is undefined). Callers MUST NOT alias them. The 1/2/4/8-byte CAS surface has the same contract; the 16-byte ops re-document it here because the wider value makes accidental aliasing more tempting in LCRQ-style consumer code.</p>

### `compareExchange`

```nim
proc compareExchange[A, B](loc: var Atomic[Pair[A, B]];
                           expected: var Pair[A, B]; desired: Pair[A, B]): bool {.
    inline.}
```

<p>Strong 16-byte CAS, default-order form. Alias for <tt class="docutils literal"><span class="pre"><span class="Identifier">compareExchangeStrong</span></span></tt>.</p>
<p>ABA / aliasing note: <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">desired</span></span></tt> MUST be distinct memory locations. On CAS failure, <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> is overwritten in-place with the current value of <tt class="docutils literal"><span class="pre"><span class="Identifier">loc</span></span></tt>; on success, <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> is unchanged. Passing the same <tt class="docutils literal"><span class="pre"><span class="Keyword">var</span></span></tt> location for both <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">desired</span></span></tt> is a defined-but-confusing pattern (the desired payload is read first, then <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> is overwritten — but if <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">desired</span></span></tt> alias, the post-CAS <tt class="docutils literal"><span class="pre"><span class="Identifier">desired</span></span></tt> is undefined). Callers MUST NOT alias them. The 1/2/4/8-byte CAS surface has the same contract; the 16-byte ops re-document it here because the wider value makes accidental aliasing more tempting in LCRQ-style consumer code.</p>

### `fetchAdd`

```nim
proc fetchAdd[A, B: SomeInteger](loc: var Atomic[Pair[A, B]]; delta: Pair[A, B];
    order: static MemoryOrder = moSequentiallyConsistent): Pair[A, B] {.inline.}
```

<p>Atomically add <tt class="docutils literal"><span class="pre"><span class="Identifier">delta</span><span class="Operator">.</span><span class="Identifier">first</span></span></tt> to <tt class="docutils literal"><span class="pre"><span class="Identifier">loc</span><span class="Operator">.</span><span class="Identifier">first</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">delta</span><span class="Operator">.</span><span class="Identifier">second</span></span></tt> to <tt class="docutils literal"><span class="pre"><span class="Identifier">loc</span><span class="Operator">.</span><span class="Identifier">second</span></span></tt>, returning the prior 128-bit pair. Both halves are updated as a single atomic transaction via a 16-byte CAS-loop (cmpxchg16b / casp / <tt class="docutils literal"><span class="pre"><span class="Identifier">_InterlockedCompareExchange128</span></span></tt>).</p>
<p>Half-type overflow behavior follows the underlying integer type (<tt class="docutils literal"><span class="pre"><span class="Identifier">SomeInteger</span></span></tt>). Unsigned halves wrap modulo <tt class="docutils literal"><span class="pre"><span class="DecNumber">2</span><span class="Operator">^</span><span class="Punctuation">(</span><span class="Identifier">sizeof</span><span class="Punctuation">(</span><span class="Identifier">half</span><span class="Punctuation">)</span><span class="Operator">*</span><span class="DecNumber">8</span><span class="Punctuation">)</span></span></tt>. Signed halves do NOT silently wrap: the half-add <tt class="docutils literal"><span class="pre"><span class="Identifier">prev</span><span class="Operator">.</span><span class="Identifier">first</span> <span class="Operator">+</span> <span class="Identifier">delta</span><span class="Operator">.</span><span class="Identifier">first</span></span></tt> is an ordinary checked Nim addition, so under default builds (overflow checks on) a signed-half overflow raises <tt class="docutils literal"><span class="pre"><span class="Identifier">OverflowDefect</span></span></tt> — aborting the CAS loop rather than completing the &quot;atomic transaction&quot;. Signed halves only wrap two's-complement under <tt class="docutils literal"><span class="pre"><span class="Operator">-</span><span class="Identifier">d</span><span class="Punctuation">:</span><span class="Identifier">danger</span></span></tt> or an explicit <tt class="docutils literal"><span class="pre"><span class="Punctuation">{</span><span class="Operator">.</span><span class="Identifier">push</span> <span class="Identifier">overflowChecks</span><span class="Punctuation">:</span> <span class="Identifier">off</span><span class="Operator">.</span><span class="Punctuation">}</span></span></tt>. For counters that must never trap (e.g. an LCRQ generation tag), use an unsigned half-type.</p>

### `fetchSub`

```nim
proc fetchSub[A, B: SomeInteger](loc: var Atomic[Pair[A, B]]; delta: Pair[A, B];
    order: static MemoryOrder = moSequentiallyConsistent): Pair[A, B] {.inline.}
```

Componentwise atomic subtract. See <tt class="docutils literal"><span class="pre"><span class="Identifier">fetchAdd</span></span></tt> for transactional semantics and overflow behavior.

### `fetchAnd`

```nim
proc fetchAnd[A, B: SomeInteger](loc: var Atomic[Pair[A, B]]; mask: Pair[A, B];
    order: static MemoryOrder = moSequentiallyConsistent): Pair[A, B] {.inline.}
```

Componentwise atomic bitwise AND. See <tt class="docutils literal"><span class="pre"><span class="Identifier">fetchAdd</span></span></tt> for transactional semantics.

### `fetchOr`

```nim
proc fetchOr[A, B: SomeInteger](loc: var Atomic[Pair[A, B]]; mask: Pair[A, B];
    order: static MemoryOrder = moSequentiallyConsistent): Pair[A, B] {.inline.}
```

Componentwise atomic bitwise OR. See <tt class="docutils literal"><span class="pre"><span class="Identifier">fetchAdd</span></span></tt> for transactional semantics.

### `fetchXor`

```nim
proc fetchXor[A, B: SomeInteger](loc: var Atomic[Pair[A, B]]; mask: Pair[A, B];
    order: static MemoryOrder = moSequentiallyConsistent): Pair[A, B] {.inline.}
```

Componentwise atomic bitwise XOR. See <tt class="docutils literal"><span class="pre"><span class="Identifier">fetchAdd</span></span></tt> for transactional semantics.


## Templates

### `cacheLineAligned`

```nim
template cacheLineAligned(decl: untyped)
```

Drop-in <tt class="docutils literal"><span class="pre"><span class="Punctuation">{</span><span class="Operator">.</span><span class="Identifier">align</span><span class="Punctuation">:</span> <span class="Identifier">CacheLineBytes</span><span class="Operator">.</span><span class="Punctuation">}</span></span></tt> shorthand.

### `enforceDwcasConstraints`

```nim
template enforceDwcasConstraints(A, B: typedesc)
```

<p>Gate 2 (Pair shape) + Gate 4 (lock-free) for <tt class="docutils literal"><span class="pre"><span class="Identifier">Atomic</span><span class="Punctuation">[</span><span class="Identifier">Pair</span><span class="Punctuation">[</span><span class="Identifier">A</span><span class="Punctuation">,</span> <span class="Identifier">B</span><span class="Punctuation">]</span><span class="Punctuation">]</span></span></tt>.</p>
<p>Checks <tt class="docutils literal"><span class="pre"><span class="Identifier">sizeof</span><span class="Punctuation">(</span><span class="Identifier">A</span><span class="Punctuation">)</span> <span class="Operator">+</span> <span class="Identifier">sizeof</span><span class="Punctuation">(</span><span class="Identifier">B</span><span class="Punctuation">)</span> <span class="Operator">==</span> <span class="DecNumber">16</span></span></tt> rather than <tt class="docutils literal"><span class="pre"><span class="Identifier">sizeof</span><span class="Punctuation">(</span><span class="Identifier">Pair</span><span class="Punctuation">[</span><span class="Identifier">A</span><span class="Punctuation">,</span> <span class="Identifier">B</span><span class="Punctuation">]</span><span class="Punctuation">)</span> <span class="Operator">==</span> <span class="DecNumber">16</span></span></tt>: the field-level <tt class="docutils literal"><span class="pre"><span class="Punctuation">{</span><span class="Operator">.</span><span class="Identifier">align</span><span class="Punctuation">:</span> <span class="FloatNumber">16.</span><span class="Punctuation">}</span></span></tt> on <tt class="docutils literal"><span class="pre"><span class="Identifier">first</span></span></tt> pads any undersized Pair up to 16 bytes, so the outer sizeof would silently mask half-size mismatches (e.g. <tt class="docutils literal"><span class="pre"><span class="Identifier">Pair</span><span class="Punctuation">[</span><span class="Identifier">uint64</span><span class="Punctuation">,</span> <span class="Identifier">uint32</span><span class="Punctuation">]</span></span></tt> has 12 bytes of payload + 4 padding). DWCAS requires both halves live (cmpxchg16b / casp compares all 128 bits), so the payload sum is the real safety invariant.</p>

### `nonAtomicType`

```nim
template nonAtomicType(T: typedesc): typedesc
```

### `dwcasLoad`

```nim
template dwcasLoad[A, B](loc: var Atomic[Pair[A, B]]; order: static MemoryOrder): Pair[
    A, B]
```

Low-level 16-byte atomic load emit. Backend-dispatched by compiler: gcc → <tt class="docutils literal"><span class="pre"><span class="Identifier">__sync_val_compare_and_swap</span></span></tt> on <tt class="docutils literal"><span class="pre"><span class="Identifier">__int128</span></span></tt> (inlines <tt class="docutils literal"><span class="pre"><span class="Identifier">cmpxchg16b</span></span></tt> on x86_64 with <tt class="docutils literal"><span class="pre"><span class="Operator">-</span><span class="Identifier">mcx16</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">casp</span></span></tt> on aarch64 with <tt class="docutils literal"><span class="pre"><span class="Operator">-</span><span class="Identifier">march</span><span class="Operator">=</span><span class="Identifier">armv8</span><span class="Operator">.</span><span class="DecNumber">1</span><span class="Operator">-</span><span class="Identifier">a</span><span class="Operator">+</span><span class="Identifier">lse</span></span></tt>); clang / llvm_gcc → <tt class="docutils literal"><span class="pre"><span class="Identifier">__atomic_load_n</span></span></tt> on <tt class="docutils literal"><span class="pre"><span class="Identifier">__int128</span></span></tt>. Callers should prefer <tt class="docutils literal"><span class="pre"><span class="Identifier">load</span><span class="Punctuation">(</span><span class="Identifier">Atomic</span><span class="Punctuation">[</span><span class="Identifier">Pair</span><span class="Punctuation">[</span><span class="Identifier">A</span><span class="Punctuation">,</span> <span class="Identifier">B</span><span class="Punctuation">]</span><span class="Punctuation">]</span><span class="Punctuation">)</span></span></tt> which carries the per-callsite memory-order validation and seq_cst-upgrade warning. Exposed for testing and for callers that have already validated the order policy externally.

### `dwcasStore`

```nim
template dwcasStore[A, B](loc: var Atomic[Pair[A, B]]; desired: Pair[A, B];
                          order: static MemoryOrder)
```

Low-level 16-byte atomic store emit. Backend-dispatched (see <tt class="docutils literal"><span class="pre"><span class="Identifier">dwcasLoad</span></span></tt>). Prefer <tt class="docutils literal"><span class="pre"><span class="Identifier">store</span><span class="Punctuation">(</span><span class="Identifier">Atomic</span><span class="Punctuation">[</span><span class="Identifier">Pair</span><span class="Punctuation">[</span><span class="Identifier">A</span><span class="Punctuation">,</span> <span class="Identifier">B</span><span class="Punctuation">]</span><span class="Punctuation">]</span><span class="Punctuation">)</span></span></tt> for the validated, warning-emitting surface.

### `dwcasExchange`

```nim
template dwcasExchange[A, B](loc: var Atomic[Pair[A, B]]; desired: Pair[A, B];
                             order: static MemoryOrder): Pair[A, B]
```

Low-level 16-byte atomic exchange emit. Backend-dispatched (see <tt class="docutils literal"><span class="pre"><span class="Identifier">dwcasLoad</span></span></tt>). Prefer <tt class="docutils literal"><span class="pre"><span class="Identifier">exchange</span><span class="Punctuation">(</span><span class="Identifier">Atomic</span><span class="Punctuation">[</span><span class="Identifier">Pair</span><span class="Punctuation">[</span><span class="Identifier">A</span><span class="Punctuation">,</span> <span class="Identifier">B</span><span class="Punctuation">]</span><span class="Punctuation">]</span><span class="Punctuation">)</span></span></tt> for the validated, warning-emitting surface.

### `dwcasCasStrong`

```nim
template dwcasCasStrong[A, B](loc: var Atomic[Pair[A, B]];
                              expected: var Pair[A, B]; desired: Pair[A, B];
                              success: static MemoryOrder;
                              failure: static MemoryOrder): bool
```

Low-level 16-byte strong CAS emit. Backend-dispatched (see <tt class="docutils literal"><span class="pre"><span class="Identifier">dwcasLoad</span></span></tt>). On gcc maps to <tt class="docutils literal"><span class="pre"><span class="Identifier">__sync_val_compare_and_swap</span></span></tt> (always-strong); on clang / llvm_gcc maps to <tt class="docutils literal"><span class="pre"><span class="Identifier">__atomic_compare_exchange_n</span></span></tt> with the weak flag = 0. Prefer <tt class="docutils literal"><span class="pre"><span class="Identifier">compareExchangeStrong</span><span class="Punctuation">(</span><span class="Identifier">Atomic</span><span class="Punctuation">[</span><span class="Identifier">Pair</span><span class="Punctuation">[</span><span class="Identifier">A</span><span class="Punctuation">,</span> <span class="Identifier">B</span><span class="Punctuation">]</span><span class="Punctuation">]</span><span class="Punctuation">)</span></span></tt> for the validated, warning-emitting surface.

### `dwcasCasWeak`

```nim
template dwcasCasWeak[A, B](loc: var Atomic[Pair[A, B]];
                            expected: var Pair[A, B]; desired: Pair[A, B];
                            success: static MemoryOrder;
                            failure: static MemoryOrder): bool
```

Low-level 16-byte weak CAS emit. Backend-dispatched (see <tt class="docutils literal"><span class="pre"><span class="Identifier">dwcasLoad</span></span></tt>). On gcc, <tt class="docutils literal"><span class="pre"><span class="Identifier">__sync_val_compare_and_swap</span></span></tt> is always-strong on both x86_64 (<tt class="docutils literal"><span class="pre"><span class="Identifier">cmpxchg16b</span></span></tt>) and aarch64+LSE (<tt class="docutils literal"><span class="pre"><span class="Identifier">casp</span></span></tt>), so the weak/strong distinction is a no-op; on clang / llvm_gcc maps to <tt class="docutils literal"><span class="pre"><span class="Identifier">__atomic_compare_exchange_n</span></span></tt> with weak=1, where ARMv8.0 LL/SC (no LSE) <tt class="docutils literal"><span class="pre"><span class="Identifier">stlxp</span></span></tt> may genuinely fail spuriously, while aarch64 FEAT_LSE / LSE2 (<tt class="docutils literal"><span class="pre"><span class="Identifier">caspal</span></span></tt>, objdump-verified on Apple Silicon) is always-strong. Prefer <tt class="docutils literal"><span class="pre"><span class="Identifier">compareExchangeWeak</span><span class="Punctuation">(</span><span class="Identifier">Atomic</span><span class="Punctuation">[</span><span class="Identifier">Pair</span><span class="Punctuation">[</span><span class="Identifier">A</span><span class="Punctuation">,</span> <span class="Identifier">B</span><span class="Punctuation">]</span><span class="Punctuation">]</span><span class="Punctuation">)</span></span></tt> for the validated, warning-emitting surface.

### `dwcasOrderRelaxedCAS`

```nim
template dwcasOrderRelaxedCAS(body: untyped): untyped
```

<pre>Wraps a DWCAS call site, suppressing the moSeqCst-upgrade warning emitted
by the 16-byte ops (load / store / exchange / compareExchange*) for that
site only. Use when the upgrade is intentional and audited (e.g. the LCRQ
producer publish CAS passing `moRelease` / `moRelaxed`). The warning
continues to fire at unwrapped call sites.

See `docs/design/2026-04-25-custom-atomics.md` §3 and the user guide
`docs/guide/atomics.md` §5 (Memory-order policy) for the memory-model
rationale.</pre>

