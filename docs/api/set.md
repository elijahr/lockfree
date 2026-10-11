# SkipListSet (Concurrent Set)

`lockfree/set` implements a lock-free concurrent Set backed by the Fraser & Herlihy
SkipList algorithm with Harris logical deletion marking and Debra Safe Memory
Reclamation.

## Overview

- **Core Type**: `SkipListSet[T, MaxThreads, MaxLevel]`
- **Ergonomic Aliases**: `Set[T]`, `ConcurrentSet[T]`, `OrderedSet[T]`
- **Lookups**: Wait-free `contains(item)`
- **Mutations**: Lock-free `insert(item)`, `remove(item)`
- **Iteration**: Ascending ordered iteration over stored elements

## Example

```nim
import lockfree

var s = newSkipListSet[int]()

discard s.insert(42)
discard s.insert(17)

assert s.contains(42)
assert not s.contains(99)
```

::: lockfree/set
