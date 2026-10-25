---
title: "lockfree/smr/nebr/typestates/cardinality"
description: "API reference for lockfree/smr/nebr/typestates/cardinality"
---

<p>Cardinality axis for the typestate surface (introduced in 0.8.0).</p>
<p><tt class="docutils literal"><span class="pre"><span class="Identifier">PinScopeCardinality</span></span></tt> is the second generic-parameter axis (the <strong>CC</strong> axis) that nim-debra threads through <tt class="docutils literal"><span class="pre"><span class="Identifier">DebraManager</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">ThreadHandle</span></span></tt>, and the EBR typestate graphs. It exposes consumer-cardinality at the type level so downstream lock-free data structures can statically gate single-writer atomic primitives (<tt class="docutils literal"><span class="pre"><span class="Identifier">retireOnPublish</span></span></tt>) from CAS-based primitives (<tt class="docutils literal"><span class="pre"><span class="Identifier">retireOnCAS</span></span></tt>).</p>
<p>Values:</p>
<ul class="simple"><li><tt class="docutils literal"><span class="pre"><span class="Identifier">ccSingle</span></span></tt> - single consumer / no retire-race. <strong>Default</strong> for every call shape in 0.7.x-compat code. Used for producer-side pins and true single-consumer queue contexts.</li>
<li><tt class="docutils literal"><span class="pre"><span class="Identifier">ccMulti</span></span></tt> - multi-consumer / retire-race possible. Required for consumer pins on multi-consumer queues.</li>
</ul>
<p>The CC parameter defaults to <tt class="docutils literal"><span class="pre"><span class="Identifier">ccSingle</span></span></tt> everywhere Nim's <tt class="docutils literal"><span class="pre"><span class="Keyword">static</span></span></tt> defaulting reaches, so existing 0.7.x callers compile unchanged.</p>


## Types

### `PinScopeCardinality`

```nim
PinScopeCardinality = enum
  ccSingle, ccMulti
```

