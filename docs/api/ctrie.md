# Ctrie (Concurrent Hash Array Mapped Trie)

`lockfree/ctrie` implements Aleksandar Prokopec's lock-free Concurrent Hash Array
Mapped Trie (HAMT) with wait-free point-in-time snapshots and Debra Safe Memory
Reclamation.

## Overview

- **Core Type**: `Ctrie[K, V, MaxThreads]`
- **Ergonomic Aliases**: `Table[K, V]`, `ConcurrentTable[K, V]`, `ConcurrentMap[K, V]`
- **Lookups**: Wait-free, bounded depth ($O(1)$)
- **Mutations**: Lock-free (`put`, `putIfAbsent`, `atomicUpdate`, `upsert`, `remove`)
- **Snapshots**: Wait-free $O(1)$ generational root swing (`snapshot()`, `snapshotPairs()`)
- **Memory Management**: Backed by Debra/NEBR epoch-based memory reclamation

## Example

```nim
import lockfree

var table = newCtrie[string, int]()

discard table.put("alpha", 1)
discard table.putIfAbsent("beta", 2)

let val = table.get("alpha")
assert val.isSome and val.get() == 1

# O(1) point-in-time atomic snapshot
let snap = table.snapshot()
```

::: lockfree/ctrie
