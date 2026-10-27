---
title: "lockfree/atomics/dsl"
description: "API reference for lockfree/atomics/dsl"
---

<p>debra/atomics/dsl</p>
<p>Symmetric <tt class="docutils literal"><span class="pre"><span class="Operator">.</span><span class="Identifier">relaxed</span><span class="Operator">/.</span><span class="Identifier">acquire</span><span class="Operator">/.</span><span class="Identifier">release</span><span class="Operator">/.</span><span class="Identifier">sequential</span></span></tt> shorthand for load and store. Mirrors <tt class="docutils literal"><span class="pre"><span class="Identifier">commit</span> <span class="DecNumber">8</span><span class="Identifier">fb4717</span> <span class="Identifier">src</span><span class="Operator">/</span><span class="Identifier">lockfree</span><span class="Operator">/</span><span class="Identifier">atomic_dsl</span><span class="Operator">.</span><span class="Identifier">nim</span></span></tt> so the lockfree port is a one-line <tt class="docutils literal"><span class="pre"><span class="Keyword">import</span></span></tt> swap.</p>
<p>Symmetry rule (design doc section 2):</p>
<ul class="simple"><li><tt class="docutils literal"><span class="pre"><span class="Operator">.</span><span class="Identifier">relaxed</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt> load, moRelaxed</li>
<li><tt class="docutils literal"><span class="pre"><span class="Operator">.</span><span class="Identifier">relaxed</span><span class="Punctuation">(</span><span class="Identifier">v</span><span class="Punctuation">)</span></span></tt> store, moRelaxed</li>
<li><tt class="docutils literal"><span class="pre"><span class="Operator">.</span><span class="Identifier">acquire</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt> load, moAcquire (load-only)</li>
<li><tt class="docutils literal"><span class="pre"><span class="Operator">.</span><span class="Identifier">release</span><span class="Punctuation">(</span><span class="Identifier">v</span><span class="Punctuation">)</span></span></tt> store, moRelease (store-only)</li>
<li><tt class="docutils literal"><span class="pre"><span class="Operator">.</span><span class="Identifier">sequential</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt> load, moSequentiallyConsistent</li>
<li><tt class="docutils literal"><span class="pre"><span class="Operator">.</span><span class="Identifier">sequential</span><span class="Punctuation">(</span><span class="Identifier">v</span><span class="Punctuation">)</span></span></tt> store, moSequentiallyConsistent</li>
</ul>
<p><tt class="docutils literal"><span class="pre"><span class="Identifier">compareExchange</span></span></tt> and friends stay out of the DSL. This module is opt-in; <tt class="docutils literal"><span class="pre"><span class="Keyword">import</span> <span class="Identifier">debra</span><span class="Operator">/</span><span class="Identifier">atomics</span></span></tt> does NOT bring it in.</p>

<h3><a class="toc-backref" id="name-coexistence-with-nimstdslashlocks" href="#name-coexistence-with-nimstdslashlocks">Name coexistence with <tt class="docutils literal"><span class="pre"><span class="Identifier">std</span><span class="Operator">/</span><span class="Identifier">locks</span></span></tt></a></h3><p>The exported <tt class="docutils literal"><span class="pre"><span class="Identifier">acquire</span></span></tt>/<tt class="docutils literal"><span class="pre"><span class="Identifier">release</span></span></tt> take <tt class="docutils literal"><span class="pre"><span class="Keyword">var</span> <span class="Identifier">Atomic</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> and intentionally coexist with <tt class="docutils literal"><span class="pre"><span class="Identifier">system</span></span></tt>/<tt class="docutils literal"><span class="pre"><span class="Identifier">std</span><span class="Operator">/</span><span class="Identifier">locks</span></span></tt> <tt class="docutils literal"><span class="pre"><span class="Identifier">acquire</span></span></tt>/<tt class="docutils literal"><span class="pre"><span class="Identifier">release</span></span></tt> (which take a <tt class="docutils literal"><span class="pre"><span class="Identifier">Lock</span></span></tt>). At a call site that imports both, the two overload sets are disambiguated purely by the first argument's type, so <tt class="docutils literal"><span class="pre"><span class="Identifier">acquire</span><span class="Punctuation">(</span><span class="Identifier">x</span><span class="Punctuation">)</span></span></tt> resolves to the lock primitive when <tt class="docutils literal"><span class="pre"><span class="Identifier">x</span><span class="Punctuation">:</span> <span class="Identifier">Lock</span></span></tt> and to the atomic acquire-load when <tt class="docutils literal"><span class="pre"><span class="Identifier">x</span><span class="Punctuation">:</span> <span class="Identifier">Atomic</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>. This compiles unambiguously, but a reader must check the argument's type to know which <tt class="docutils literal"><span class="pre"><span class="Identifier">acquire</span></span></tt> is meant. This overlap is deliberate (it keeps the DSL terse and symmetric); if you mix <tt class="docutils literal"><span class="pre"><span class="Identifier">std</span><span class="Operator">/</span><span class="Identifier">locks</span></span></tt> and this DSL in one module and want the distinction visible at the call site, qualify the lock calls (<tt class="docutils literal"><span class="pre"><span class="Identifier">locks</span><span class="Operator">.</span><span class="Identifier">acquire</span><span class="Punctuation">(</span><span class="Identifier">l</span><span class="Punctuation">)</span></span></tt>).</p>


## Procedures & Functions

### `relaxed`

```nim
proc relaxed[T](loc: var Atomic[T]): T {.inline.}
```

Load <tt class="docutils literal"><span class="pre"><span class="Identifier">loc</span></span></tt> with moRelaxed.

### `relaxed`

```nim
proc relaxed[T](loc: var Atomic[T]; value: T) {.inline.}
```

Store <tt class="docutils literal"><span class="pre"><span class="Identifier">value</span></span></tt> into <tt class="docutils literal"><span class="pre"><span class="Identifier">loc</span></span></tt> with moRelaxed.

### `acquire`

```nim
proc acquire[T](loc: var Atomic[T]): T {.inline.}
```

Load <tt class="docutils literal"><span class="pre"><span class="Identifier">loc</span></span></tt> with moAcquire. Load-only by design: moAcquire is not a valid store order.

### `release`

```nim
proc release[T](loc: var Atomic[T]; value: T) {.inline.}
```

Store <tt class="docutils literal"><span class="pre"><span class="Identifier">value</span></span></tt> into <tt class="docutils literal"><span class="pre"><span class="Identifier">loc</span></span></tt> with moRelease. Store-only by design: moRelease is not a valid load order.

### `sequential`

```nim
proc sequential[T](loc: var Atomic[T]): T {.inline.}
```

Load <tt class="docutils literal"><span class="pre"><span class="Identifier">loc</span></span></tt> with moSequentiallyConsistent.

### `sequential`

```nim
proc sequential[T](loc: var Atomic[T]; value: T) {.inline.}
```

Store <tt class="docutils literal"><span class="pre"><span class="Identifier">value</span></span></tt> into <tt class="docutils literal"><span class="pre"><span class="Identifier">loc</span></span></tt> with moSequentiallyConsistent.

