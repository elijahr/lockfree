---
title: "lockfree/strategy"
description: "API reference for lockfree/strategy"
---

<p>Deallocation strategy enum for the v5.0.0 unified <tt class="docutils literal"><span class="pre"><span class="Identifier">Queue</span></span></tt> generic.</p>
<p>Consolidates the triplicated <tt class="docutils literal"><span class="pre"><span class="Identifier">DeallocationStrategy</span></span></tt> enum that previously lived in <tt class="docutils literal"><span class="pre"><span class="Identifier">unbounded_mpsc</span><span class="Operator">.</span><span class="Identifier">nim</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">unbounded_spmc</span><span class="Operator">.</span><span class="Identifier">nim</span></span></tt>, and <tt class="docutils literal"><span class="pre"><span class="Identifier">unbounded_mpmc</span><span class="Operator">.</span><span class="Identifier">nim</span></span></tt>. v4.x callers used the bare-symbol forms <tt class="docutils literal"><span class="pre"><span class="Identifier">Manual</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">Eager</span></span></tt>; those are preserved as constant aliases so the migration to the prefixed <tt class="docutils literal"><span class="pre"><span class="Identifier">stManual</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">stEager</span></span></tt> is non-breaking at the call site.</p>


## Types

### `DeallocationStrategy`

```nim
DeallocationStrategy = enum
  stManual,                 ## Reserved for future batch-retire; no specialization in v5.0.
  stEager                    ## Active in v5.0; per-pop best-effort `reclaimNow(handle)`.
```


## Constants

### `Manual`

```nim
Manual = stManual
```

### `Eager`

```nim
Eager = stEager
```

### `DefaultDeallocationStrategy`

```nim
DefaultDeallocationStrategy = stEager
```

