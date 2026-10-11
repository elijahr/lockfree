# SkipListMap (Concurrent Sorted Table)

`lockfree/skiplist` implements a lock-free concurrent SkipList based on Fraser &
Herlihy's algorithm with Harris-style logical deletion marking and Debra Safe
Memory Reclamation.

## Overview

- **Core Type**: `SkipListMap[K, V, MaxThreads, MaxLevel]`
- **Ergonomic Aliases**: `SortedTable[K, V]`, `OrderedTable[K, V]`, `ConcurrentSortedTable[K, V]`
- **Key Ordering**: Strict total key order ascending; supports range queries and ordered iteration
- **Lookups**: Wait-free probabilistic $O(\log N)$
- **Mutations**: Lock-free (`insert`, `delete`, `putIfAbsent`, `atomicUpdate`, `upsert`)
- **Memory Management**: Backed by Debra/NEBR epoch-based memory reclamation

## Example

```nim
import lockfree

var sortedMap = newSkipListMap[int, string]()

discard sortedMap.insert(10, "ten")
discard sortedMap.insert(20, "twenty")
discard sortedMap.insert(5, "five")

# Ordered pairs iteration
for (k, v) in sortedMap.pairs():
  echo k, ": ", v
```

::: lockfree/skiplist
