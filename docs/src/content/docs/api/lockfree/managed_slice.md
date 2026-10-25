---
title: "lockfree/managed_slice"
description: "API reference for lockfree/managed_slice"
---

<p>lockfree/managed_slice</p>
<p>Internal slot encoding for <tt class="docutils literal"><span class="pre">string</span></tt> and <tt class="docutils literal"><span class="pre">seq[U]</span></tt> payloads under Path C (<tt class="docutils literal"><span class="pre"><span class="Identifier">Queue</span><span class="Punctuation">[</span><span class="Identifier">string</span><span class="Punctuation">,</span> <span class="Operator">...</span><span class="Punctuation">]</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">Queue</span><span class="Punctuation">[</span><span class="Identifier">seq</span><span class="Punctuation">[</span><span class="Identifier">U</span><span class="Punctuation">]</span><span class="Punctuation">,</span> <span class="Operator">...</span><span class="Punctuation">]</span></span></tt>). Unified encoding using the heap-box pattern.</p>

<h1><a class="toc-backref" id="never-userminusfacing" href="#never-userminusfacing">NEVER user-facing</a></h1><p><tt class="docutils literal"><span class="pre">ManagedSlice[T]</span></tt> is the wire-format the queue stores in its slot array. The user-facing API is <tt class="docutils literal"><span class="pre">string</span></tt> / <tt class="docutils literal"><span class="pre">seq[U]</span></tt>. ManagedSlice MUST NOT leak into public docs, examples, or signatures.</p>

<h1><a class="toc-backref" id="design-patterncolon-heapminusboxed-payload-pointer" href="#design-patterncolon-heapminusboxed-payload-pointer">Design pattern: heap-boxed payload pointer</a></h1><p>The slot bits are a <tt class="docutils literal"><span class="pre">distinct uint</span></tt> pointer at a heap-allocated box (<tt class="docutils literal"><span class="pre">alloc0Shared</span></tt>) that holds the V2 payload (<tt class="docutils literal"><span class="pre">NimStringV2</span></tt> / <tt class="docutils literal"><span class="pre">NimSeqV2[U]</span></tt>). Box layout deliberately mirrors a <tt class="docutils literal"><span class="pre">ptr object</span></tt> with a single <tt class="docutils literal"><span class="pre">v</span></tt> field of the payload type so that under arc/orc/atomicArc/refc the compiler-emitted destructor for <tt class="docutils literal"><span class="pre">v</span></tt> runs the V2 <tt class="docutils literal"><span class="pre">frees()</span></tt> path automatically when <tt class="docutils literal"><span class="pre">=destroy</span></tt> is called explicitly in <tt class="docutils literal"><span class="pre">disposeSlot</span></tt>.</p>

<h1><a class="toc-backref" id="path-c-mm-matrix" href="#path-c-mm-matrix">Path C MM matrix</a></h1><ul class="simple"><li>arc / orc / atomicArc / refc — sink-assign payload into the zero-initialised box on <tt class="docutils literal"><span class="pre">wrap</span></tt> (compiler emits <tt class="docutils literal"><span class="pre">=sink</span></tt>); <tt class="docutils literal"><span class="pre">move</span></tt> the payload out and <tt class="docutils literal"><span class="pre">deallocShared</span></tt> the box on <tt class="docutils literal"><span class="pre">unwrap</span></tt>; <tt class="docutils literal"><span class="pre">=destroy</span></tt> the box payload + <tt class="docutils literal"><span class="pre">deallocShared</span></tt> the box on <tt class="docutils literal"><span class="pre">disposeSlot</span></tt> (destructor walk).</li>
<li>none — strict bit-transport contract. The source binding is NOT zeroed on <tt class="docutils literal"><span class="pre">wrap</span></tt> and the destination is NOT destroyed on <tt class="docutils literal"><span class="pre">disposeSlot</span></tt>. The user owns lifetime; we are a pointer-bit transport only.</li>
</ul>

<h1><a class="toc-backref" id="abi-stability" href="#abi-stability">ABI stability</a></h1><p><tt class="docutils literal"><span class="pre">sizeof(ManagedSlice[T])</span></tt> == <tt class="docutils literal"><span class="pre">sizeof(uint)</span></tt> on every supported platform — asserted at compile time in the <tt class="docutils literal"><span class="pre">static:</span></tt> block below.</p>


## Types

### `ManagedSlice`

```nim
ManagedSlice[T] = distinct uint
```

Slot encoding for a <tt class="docutils literal"><span class="pre">string</span></tt> (<tt class="docutils literal"><span class="pre">T = char</span></tt>) or <tt class="docutils literal"><span class="pre">seq[U]</span></tt> (<tt class="docutils literal"><span class="pre">T = U</span></tt>) payload. Internal — see module doc-comment. Sized and aligned identically to <tt class="docutils literal"><span class="pre">uint</span></tt>.


## Procedures & Functions

### `wrap`

```nim
proc wrap(s: sink string): ManagedSlice[char] {.inline, raises: [], tags: [],
    forbids: [].}
```

Pack a <tt class="docutils literal"><span class="pre">string</span></tt> into the slot encoding. Allocates a shared heap box and transfers the payload in. The caller's binding is consumed (<tt class="docutils literal"><span class="pre">sink</span></tt>).

### `wrap`

```nim
proc wrap[U](s: sink seq[U]): ManagedSlice[U] {.inline.}
```

<p>Pack a <tt class="docutils literal"><span class="pre">seq[U]</span></tt> into the slot encoding. Allocates a shared heap box and transfers the payload in.</p>
<p><tt class="docutils literal"><span class="pre"><span class="Identifier">seq</span><span class="Punctuation">[</span><span class="Keyword">ref</span> <span class="Identifier">U</span><span class="Punctuation">]</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">seq</span><span class="Punctuation">[</span><span class="Identifier">seq</span><span class="Punctuation">[</span><span class="Identifier">U</span><span class="Punctuation">]</span><span class="Punctuation">]</span></span></tt> are ACCEPTED. The box-pattern transport handles inner-element lifecycle correctly via Nim's compiler-emitted seq <tt class="docutils literal"><span class="pre">=destroy</span></tt> when the box is reconstructed at pop or destroy-walk. The library's transport is the outer seq value (boxed here); inner refs/seqs are the seq's lifecycle problem. No <tt class="docutils literal"><span class="pre">supportsCopyMem(U)</span></tt> guard is applied here or in path_c_admit.nim.</p>

### `unwrap`

```nim
proc unwrap(ms: ManagedSlice[char]): string {.inline, raises: [], tags: [],
    forbids: [].}
```

Unpack a <tt class="docutils literal"><span class="pre">string</span></tt> from the slot encoding. Frees the heap box. On arc/orc/atomicArc/refc the payload pointer is moved out (no refcount bump on the V2 payload); on mm:none the payload bits are copied out and the source bits are not zeroed.

### `unwrapSeq`

```nim
proc unwrapSeq[U](ms: ManagedSlice[U]): seq[U] {.inline.}
```

<p>Unpack a <tt class="docutils literal"><span class="pre">seq[U]</span></tt> from the slot encoding. Frees the heap box.</p>
<p>Distinctly named (<tt class="docutils literal"><span class="pre">unwrapSeq</span></tt>, not <tt class="docutils literal"><span class="pre">unwrap</span></tt>) so the seq path is never shadowed by the non-generic <tt class="docutils literal"><span class="pre">unwrap(ManagedSlice[char])</span></tt> (string/StringBox) overload. <tt class="docutils literal"><span class="pre">ManagedSlice[char]</span></tt> is the slot encoding for BOTH <tt class="docutils literal"><span class="pre">string</span></tt> (<tt class="docutils literal"><span class="pre">T = char</span></tt>) and <tt class="docutils literal"><span class="pre">seq[char]</span></tt> (<tt class="docutils literal"><span class="pre">U = char</span></tt>); they collapse to the same instantiation, so Nim overload resolution would pick the non-generic string <tt class="docutils literal"><span class="pre">unwrap</span></tt> for a <tt class="docutils literal"><span class="pre">seq[char]</span></tt> slot, applying the StringBox layout to a SeqBox. The distinct name forces the SeqBox path explicitly. See <tt class="docutils literal"><span class="pre">internal/path_c_wrap.nim</span></tt>.</p>

### `disposeSlot`

```nim
proc disposeSlot(ms: ManagedSlice[char]) {.inline, raises: [], tags: [],
    forbids: [].}
```

<p>Destroy-walk dispose for an unpopped string slot. Safe on the nil slot (0).</p>
<p>Non-generic (string / StringBox) overload. <tt class="docutils literal"><span class="pre">disposeSeqSlot</span></tt> is the distinctly-named SEQ counterpart so a <tt class="docutils literal"><span class="pre">seq[char]</span></tt> slot is never routed here by overload resolution (StringBox vs SeqBox layout). See <tt class="docutils literal"><span class="pre">internal/path_c_wrap.nim</span></tt>.</p>

### `disposeSeqSlot`

```nim
proc disposeSeqSlot[U](ms: ManagedSlice[U]) {.inline.}
```

<p>Destroy-walk dispose for an unpopped seq slot. Safe on the nil slot (0).</p>
<p>Distinctly named (<tt class="docutils literal"><span class="pre">disposeSeqSlot</span></tt>, not <tt class="docutils literal"><span class="pre">disposeSlot</span></tt>) so the seq path is never shadowed by the non-generic <tt class="docutils literal"><span class="pre">disposeSlot(ManagedSlice[char])</span></tt> (string/StringBox) overload. <tt class="docutils literal"><span class="pre">ManagedSlice[char]</span></tt> is the slot encoding for BOTH <tt class="docutils literal"><span class="pre">string</span></tt> and <tt class="docutils literal"><span class="pre">seq[char]</span></tt>; they collapse to the same instantiation, so Nim overload resolution would pick the non-generic string <tt class="docutils literal"><span class="pre">disposeSlot</span></tt> for a <tt class="docutils literal"><span class="pre">seq[char]</span></tt> slot, running the StringBox destructor over a SeqBox. The distinct name forces the SeqBox path explicitly. See <tt class="docutils literal"><span class="pre">internal/path_c_wrap.nim</span></tt>.</p>

