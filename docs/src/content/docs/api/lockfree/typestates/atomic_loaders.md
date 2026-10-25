---
title: "lockfree/typestates/atomic_loaders"
description: "API reference for lockfree/typestates/atomic_loaders"
---

Type-safe atomic load/store for queue pointers.


## Procedures & Functions

### `loadAcquireN`

```nim
proc loadAcquireN[N: static int](a: var Atomic[int]): RawLoadedN[N] {.inline.}
```

### `loadSequentialN`

```nim
proc loadSequentialN[N: static int](a: var Atomic[int]): RawLoadedN[N] {.inline.}
```

### `loadAcquireN1`

```nim
proc loadAcquireN1[N: static int](a: var Atomic[int]): RawLoadedN1[N] {.inline.}
```

### `loadSequentialN1`

```nim
proc loadSequentialN1[N: static int](a: var Atomic[int]): RawLoadedN1[N] {.
    inline.}
```

### `storeReleaseN`

```nim
proc storeReleaseN[N: static int](a: var Atomic[int]; v: WrappedValueN[N]) {.
    inline, notATransition.}
```

### `storeReleaseN1`

```nim
proc storeReleaseN1[N: static int](a: var Atomic[int]; v: WrappedValueN1[N]) {.
    inline, notATransition.}
```

