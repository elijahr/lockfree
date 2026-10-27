---
title: "lockfree/typestates/storage_n"
description: "API reference for lockfree/typestates/storage_n"
---

<p>N-slot storage for MPSC/SPMC/MPMC queues.</p>
<p>Can ONLY be indexed with PhysicalSlotN<a class="reference internal" href="#N">N</a>, preventing index formula bugs.</p>


## Types

### `StorageN`

```nim
StorageN[N; T] = object
  data*: array[N, T]
```

Storage with exactly N slots.


## Procedures & Functions

### `init`

```nim
proc init[N: static int; T](s: var StorageN[N, T])
```

Initialize all slots to default value.

### ``[]``

```nim
proc `[]`[N: static int; T](s: StorageN[N, T]; idx: PhysicalSlotN[N]): T {.
    inline, notATransition.}
```

Read from storage (requires PhysicalSlotN).

### ``[]``

```nim
proc `[]`[N: static int; T](s: var StorageN[N, T]; idx: PhysicalSlotN[N]): var T {.
    inline, notATransition.}
```

Read as var (requires PhysicalSlotN).

### ``[]=``

```nim
proc `[]=`[N: static int; T](s: var StorageN[N, T]; idx: PhysicalSlotN[N];
                             val: sink T) {.inline, notATransition.}
```

Write to storage (requires PhysicalSlotN).

