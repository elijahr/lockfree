# ChaseLevDeque (Work-Stealing Deque)

`lockfree/deque` implements the Chase-Lev dynamic circular work-stealing deque
with C11 atomic memory orderings and bulk-stealing extensions.

## Overview

- **Core Type**: `ChaseLevDeque[T]`
- **Ergonomic Aliases**: `Deque[T]`, `ConcurrentDeque[T]`
- **Topology**: Single-Worker (Owner) / Multi-Thief
- **Worker (Owner)**: Operates at the bottom via `pushBottom(item)` and `popBottom()` in LIFO order (cache-local).
- **Thieves**: Concurrent worker threads steal from the top via `steal()` or `stealBatch()` in FIFO order.
- **Dynamic Growth**: Circular buffer grows automatically when full.

## Example

```nim
import lockfree

var deque = newChaseLevDeque[int](initialCapacity = 64)

# Worker operations:
deque.pushBottom(10)
deque.pushBottom(20)

# Thief operation:
var stolen: int
let res = deque.steal(stolen)
assert res == StealOk and stolen == 10
```

::: lockfree/deque
