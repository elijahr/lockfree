---
title: "lockfree/typestates/fullness_checks"
description: "API reference for lockfree/typestates/fullness_checks"
---

Type-safe fullness checks.


## Procedures & Functions

### `usedN`

```nim
proc usedN[N: static int](head, tail: WrappedValueN[N]): int {.notATransition.}
```

### `availableN`

```nim
proc availableN[N: static int](head, tail: WrappedValueN[N]): int {.
    notATransition.}
```

### `fullN`

```nim
proc fullN[N: static int](head, tail: WrappedValueN[N]): bool {.notATransition.}
```

### `emptyN`

```nim
proc emptyN[N: static int](head, tail: WrappedValueN[N]): bool {.notATransition.}
```

### `usedN1`

```nim
proc usedN1[N: static int](head, tail: WrappedValueN1[N]): int {.notATransition.}
```

### `availableN1`

```nim
proc availableN1[N: static int](head, tail: WrappedValueN1[N]): int {.
    notATransition.}
```

### `fullN1`

```nim
proc fullN1[N: static int](head, tail: WrappedValueN1[N]): bool {.notATransition.}
```

### `emptyN1`

```nim
proc emptyN1[N: static int](head, tail: WrappedValueN1[N]): bool {.
    notATransition.}
```

