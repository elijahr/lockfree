---
title: "lockfree/managed_ref"
description: "API reference for lockfree/managed_ref"
---

<p>lockfree/managed_ref</p>
<p>Internal slot encoding for <tt class="docutils literal"><span class="pre">ref T</span></tt> payloads under Path C (<tt class="docutils literal"><span class="pre"><span class="Identifier">Queue</span><span class="Punctuation">[</span><span class="Keyword">ref</span> <span class="Identifier">Foo</span><span class="Punctuation">,</span> <span class="Operator">...</span><span class="Punctuation">]</span></span></tt>). <tt class="docutils literal"><span class="pre"><span class="Identifier">ManagedRef</span><span class="Punctuation">[</span><span class="Identifier">X</span><span class="Punctuation">]</span></span></tt> is the internal type with per-MM refcount shim arms and bit-cast guarantees.</p>

<h1><a class="toc-backref" id="never-userminusfacing" href="#never-userminusfacing">NEVER user-facing</a></h1><p><tt class="docutils literal"><span class="pre">ManagedRef[X]</span></tt> is the wire-format the queue stores in its slot array. The user-facing API is <tt class="docutils literal"><span class="pre">ref T</span></tt>. <tt class="docutils literal"><span class="pre">ManagedRef</span></tt> MUST NOT leak into public docs, examples, or signatures.</p>

<h1><a class="toc-backref" id="why-distinct-uint-and-not-distinct-ptr-x" href="#why-distinct-uint-and-not-distinct-ptr-x">Why <tt class="docutils literal"><span class="pre">distinct uint</span></tt> and not <tt class="docutils literal"><span class="pre">distinct ptr X</span></tt></a></h1><ol class="simple"><li><tt class="docutils literal"><span class="pre">Atomic[uint]</span></tt> and <tt class="docutils literal"><span class="pre">Atomic[Pair[uint, uint]]</span></tt> compile and produce the right <tt class="docutils literal"><span class="pre">cmpxchg16b</span></tt> / <tt class="docutils literal"><span class="pre">ldxp+stxp</span></tt> instructions across every atomics backend we target. <tt class="docutils literal"><span class="pre">Atomic[ptr X]</span></tt> is less well-trodden and the strict-LCRQ DWCAS arm cannot tolerate &quot;may or may not compile&quot;.</li>
<li><tt class="docutils literal"><span class="pre">distinct uint</span></tt> opacifies the slot at the compiler's lifecycle pass — no implicit <tt class="docutils literal"><span class="pre">=destroy</span></tt> / <tt class="docutils literal"><span class="pre">=copy</span></tt> is emitted on the slot value because the compiler sees POD bits. Refcount operations happen at the EXPLICIT call sites in the queue wrappers (push, pop, queue-destroy walk), never silently behind the queue's back.</li>
<li><tt class="docutils literal"><span class="pre">cast[uint](myRef) ↔ cast[ManagedRef[X]](bits) ↔ cast[ref X](toBits(mref))</span></tt> is a no-op at runtime and preserves pointer identity, which is the precondition for the per-MM refcount calls to find the correct heap header.</li>
</ol>

<h1><a class="toc-backref" id="abi-stability" href="#abi-stability">ABI stability</a></h1><p><tt class="docutils literal"><span class="pre">sizeof(ManagedRef[X])</span></tt> and <tt class="docutils literal"><span class="pre">alignof(ManagedRef[X])</span></tt> are equal to <tt class="docutils literal"><span class="pre">sizeof(uint)</span></tt> and <tt class="docutils literal"><span class="pre">alignof(uint)</span></tt> on every supported platform. This is the wire-format invariant the queue's atomic slot operations depend on, and it is asserted at compile time in the <tt class="docutils literal"><span class="pre">static:</span></tt> block below. Across-MM ABI promises (arc ↔ orc ↔ atomicArc ↔ none) follow from this identity plus the same field layout in <tt class="docutils literal"><span class="pre">Queue[T, ...]</span></tt>. What we explicitly do NOT promise: refc bit-compat, cross-Nim-version, cross-minor-version.</p>

<h1><a class="toc-backref" id="perminusmm-shim-arms" href="#perminusmm-shim-arms">Per-MM shim arms</a></h1><p>The <tt class="docutils literal"><span class="pre">incRefSlot</span></tt> / <tt class="docutils literal"><span class="pre">decRefSlot</span></tt> templates dispatch on the compile-time MM define:</p>
<ul class="simple"><li><tt class="docutils literal"><span class="pre">arc</span></tt> / <tt class="docutils literal"><span class="pre">orc</span></tt> / <tt class="docutils literal"><span class="pre">atomicArc</span></tt> — bump/drop the cell's refcount via the same per-MM mechanism the compiler would emit for a <tt class="docutils literal"><span class="pre">ref X</span></tt>. The atomicArc arm collapses with arc in the <tt class="docutils literal"><span class="pre">when</span></tt> because the C-RTL substitutes the atomic op transparently.</li>
<li><tt class="docutils literal"><span class="pre">refc</span></tt> — tracing GC: <tt class="docutils literal"><span class="pre">GC_ref</span></tt> / <tt class="docutils literal"><span class="pre">GC_unref</span></tt>.</li>
<li><tt class="docutils literal"><span class="pre">none</span></tt> — strict bit-transport contract: no-op. The user owns lifetime; the queue is pointer-bit transport only.</li>
<li><tt class="docutils literal"><span class="pre">nimony</span></tt> — uses <tt class="docutils literal"><span class="pre">arcInc</span></tt> / <tt class="docutils literal"><span class="pre">arcDec</span></tt> from nimony's <tt class="docutils literal"><span class="pre">std/system/arcops</span></tt>. The signature shape differs from Nim 2.x's <tt class="docutils literal"><span class="pre">nimIncRef</span></tt> family: nimony's <tt class="docutils literal"><span class="pre">arcInc(memLoc: var int)</span></tt> and <tt class="docutils literal"><span class="pre">arcDec(memLoc: var int): bool</span></tt> operate on the refcount field directly (a <tt class="docutils literal"><span class="pre">var int</span></tt> lvalue), NOT a heap-pointer. The arm below uses <tt class="docutils literal"><span class="pre">cast[ptr int](bits)[]</span></tt> to materialise a <tt class="docutils literal"><span class="pre">var int</span></tt> lvalue at the bits location. See partial-port boundary block below for heap-header offset and dispose-symbol caveats.</li>
</ul>
<p>Implementation note: <tt class="docutils literal"><span class="pre">nimIncRef</span></tt> / <tt class="docutils literal"><span class="pre">nimDecRefIsLast</span></tt> / <tt class="docutils literal"><span class="pre">nimDestroyAndDispose</span></tt> are the underlying symbol path. Those are <tt class="docutils literal"><span class="pre">compilerRtl</span></tt> and emitted <tt class="docutils literal"><span class="pre">static</span></tt> in their TU, so a cross-module call site requires a thin wrapper. <tt class="docutils literal"><span class="pre">GC_ref</span></tt> / <tt class="docutils literal"><span class="pre">GC_unref</span></tt> are the exported wrappers around that exact path — under arc/orc/atomicArc they delegate to <tt class="docutils literal"><span class="pre">nimIncRef</span></tt> / <tt class="docutils literal"><span class="pre">=destroy</span></tt> (which in turn calls <tt class="docutils literal"><span class="pre">nimDecRefIsLast</span></tt> and <tt class="docutils literal"><span class="pre">nimDestroyAndDispose</span></tt>); under refc they hit the tracing-GC path. The semantic is identical; the symbol path differs only in being public. The bit-cast guarantee makes either choice equivalent.</p>


## Types

### `ManagedRef`

```nim
ManagedRef[X] = distinct uint
```

Slot encoding for a <tt class="docutils literal"><span class="pre">ref X</span></tt> payload. Internal — see module doc-comment. Sized and aligned identically to <tt class="docutils literal"><span class="pre">uint</span></tt>.


## Procedures & Functions

### `toManagedRef`

```nim
proc toManagedRef[X](r: sink ref X): ManagedRef[X] {.inline.}
```

Pack a <tt class="docutils literal"><span class="pre">ref X</span></tt> into the slot encoding. Pointer-bit transfer only — does NOT touch refcount. The queue wrapper (<tt class="docutils literal"><span class="pre">path_c_wrap.nim:wrapOrIdentity</span></tt>) is responsible for the paired <tt class="docutils literal"><span class="pre">incRefSlot</span></tt> that claims +1 of the cell's refcount lifetime for the slot. See path_c_wrap.nim.

### `toRef`

```nim
proc toRef[X](mref: ManagedRef[X]): ref X {.inline.}
```

Unpack the slot encoding back to <tt class="docutils literal"><span class="pre">ref X</span></tt>. Pointer-bit transfer only — does NOT touch refcount. Pop is destructive (<tt class="docutils literal"><span class="pre">move</span></tt>); the queue's +1 refcount share (claimed at push) is inherited by the caller's binding. See path_c_wrap.nim.

### `toBits`

```nim
proc toBits[X](mref: ManagedRef[X]): uint {.inline.}
```

Expose the raw pointer bits. Used by the queue's atomic slot operations (<tt class="docutils literal"><span class="pre">Atomic[uint]</span></tt> ops on the slot array). Identity codegen.

### `fromBits`

```nim
proc fromBits[X](_: typedesc[ManagedRef[X]]; bits: uint): ManagedRef[X] {.inline.}
```

Reconstruct a <tt class="docutils literal"><span class="pre">ManagedRef[X]</span></tt> from raw bits read out of the slot array. Identity codegen.

### `nilManagedRef`

```nim
proc nilManagedRef[X](_: typedesc[X]): ManagedRef[X] {.inline.}
```

The all-zero slot — semantically equivalent to a nil <tt class="docutils literal"><span class="pre">ref X</span></tt>. A generic proc rather than a <tt class="docutils literal"><span class="pre">const</span></tt> because the generic <tt class="docutils literal"><span class="pre">ManagedRef[X]</span></tt> cannot be a top-level <tt class="docutils literal"><span class="pre">const</span></tt> without binding <tt class="docutils literal"><span class="pre">X</span></tt>. Call as <tt class="docutils literal"><span class="pre">nilManagedRef(Foo)</span></tt> (typedesc passed explicitly) from generic queue code where <tt class="docutils literal"><span class="pre">X</span></tt> is bound by context.

### `reset`

```nim
proc reset[X](mref: var ManagedRef[X]) {.inline.}
```

Zero the slot AND drop the refcount in one balanced operation. Used by the queue's destructor walk and by push-failure rollback. No-op when <tt class="docutils literal"><span class="pre">mref</span></tt> is already nil.


## Templates

### `incRefSlot`

```nim
template incRefSlot[X](mref: ManagedRef[X])
```

Bump the refcount of the cell pointed at by <tt class="docutils literal"><span class="pre">mref</span></tt>. No-op when <tt class="docutils literal"><span class="pre">mref</span></tt> is the nil slot. Per-MM dispatch.

### `decRefSlot`

```nim
template decRefSlot[X](mref: ManagedRef[X])
```

Drop the refcount of the cell pointed at by <tt class="docutils literal"><span class="pre">mref</span></tt>. No-op when <tt class="docutils literal"><span class="pre">mref</span></tt> is the nil slot. Per-MM dispatch.

