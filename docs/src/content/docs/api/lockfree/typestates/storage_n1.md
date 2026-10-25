---
title: "lockfree/typestates/storage_n1"
description: "API reference for lockfree/typestates/storage_n1"
---

N+1-slot storage for SPSC queue.


## Types

### `StorageN1`

```nim
StorageN1[N; T] = object
  data*: array[N + 1, T]
```

Storage with N+1 slots (for SPSC full/empty detection).


## Procedures & Functions

### `init`

```nim
proc init[N: static int; T](s: var StorageN1[N, T])
```

### ``[]``

```nim
proc `[]`[N: static int; T](s: StorageN1[N, T]; idx: PhysicalSlotN1[N]): T {.
    inline, notATransition.}
```

### ``[]``

```nim
proc `[]`[N: static int; T](s: var StorageN1[N, T]; idx: PhysicalSlotN1[N]): var T {.
    inline, notATransition.}
```

### ``[]=``

```nim
proc `[]=`[N: static int; T](s: var StorageN1[N, T]; idx: PhysicalSlotN1[N];
                             val: sink T) {.inline, notATransition.}
```

