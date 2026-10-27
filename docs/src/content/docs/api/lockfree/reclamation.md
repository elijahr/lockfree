---
title: "lockfree/reclamation"
description: "API reference for lockfree/reclamation"
---

<p>Reclamation-kind phantom enum for the v5.0.0 unified <tt class="docutils literal"><span class="pre"><span class="Identifier">Queue</span></span></tt> generic.</p>
<p><tt class="docutils literal"><span class="pre"><span class="Identifier">RK</span></span></tt> selects between two field-layout branches inside the <tt class="docutils literal"><span class="pre"><span class="Identifier">Queue</span></span></tt> type:</p>
<ul class="simple"><li><tt class="docutils literal"><span class="pre"><span class="Identifier">rkNone</span></span></tt> — bounded family. Vyukov-style seq counters; no debra, no segments.</li>
<li><tt class="docutils literal"><span class="pre"><span class="Identifier">rkEbr</span></span></tt> — unbounded family. LCRQ-style segmented body + nebr epoch-based reclamation.</li>
</ul>
<p>No default is supplied: the choice of <tt class="docutils literal"><span class="pre"><span class="Identifier">rkNone</span></span></tt> vs <tt class="docutils literal"><span class="pre"><span class="Identifier">rkEbr</span></span></tt> is semantically load-bearing — bounded queues have no segments to retire, and the unbounded SPSC shape is committed-flag-free, so the right reclamation kind is part of the queue's identity, not a configuration dial.</p>


## Types

### `ReclamationKind`

```nim
ReclamationKind = enum
  rkNone,                   ## Bounded queues: no reclamation machinery (Vyukov seqlocks).
  rkEbr                      ## Unbounded queues: EBR via nebr.
```

