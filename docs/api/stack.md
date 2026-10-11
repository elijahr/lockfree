# TreiberStack (Concurrent LIFO Stack)

`lockfree/stack` implements a high-throughput lock-free Treiber Stack augmented
with Hendler, Shavit, and Yerushalmi's Elimination-Backoff Array.

## Overview

- **Core Type**: `TreiberStack[T]`
- **Ergonomic Aliases**: `Stack[T]`, `ConcurrentStack[T]`
- **Ordering**: LIFO (Last-In First-Out)
- **Elimination Backoff**: Under high multi-threaded contention, opposing `push` and `pop` operations pair up in elimination slots and exchange items directly without modifying the central top pointer.
- **Progress Guarantee**: Lock-free

## Example

```nim
import lockfree

var stack = newTreiberStack[int]()

stack.push(1)
stack.push(2)

let item = stack.pop()
assert item.isSome and item.get() == 2
```

::: lockfree/stack
