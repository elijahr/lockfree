# Concurrent Maps & Sets

`lockfree` ships two production-grade concurrent associative data structures:
`Ctrie[K, V]` (Aleksandar Prokopec Concurrent Hash Array Mapped Trie) and
`SkipListMap[K, V]` (Fraser & Herlihy Lock-Free SkipList with Harris Logical
Marking), along with `SkipListSet[T]`.

Both structures are protected by Debra Safe Memory Reclamation, eliminating ABA
vulnerabilities and use-after-free conditions.

---

## 1. Concurrent Hash Trie (`Ctrie[K, V]`)

`Ctrie` is an unbounded, non-blocking concurrent hash map. It exposes standard
dictionary semantics and wait-free point-in-time snapshots.

### Highlights

- **Aliases**: `Table[K, V]`, `ConcurrentTable[K, V]`, `ConcurrentMap[K, V]`.
- **Lookups**: **Wait-free**, bounded by 7 trie levels for 32-bit Murmur3 hashes.
- **Mutations**: **Lock-free** CAS on internal node pointers.
- **$O(1)$ Atomic Snapshots**: Takes point-in-time read-only snapshots in $O(1)$ time by swinging the root node into a new generation. Writers lazily copy nodes on demand without blocking.
- **Atomic Associative Primitives**: `putIfAbsent`, `computeIfAbsent`, `atomicUpdate`, `upsert`.

### Example

```nim
import lockfree

var table = newCtrie[string, int]()

discard table.put("user_101", 42)
discard table.putIfAbsent("user_102", 99)

# Atomic update with transformation proc
let updated = table.atomicUpdate("user_101", proc(v: int): int = v + 1)
assert updated.isSome and updated.get() == 43

# Instantaneous snapshot
let snap = table.snapshot()
for (k, v) in snap.pairs():
  echo k, " => ", v
```

---

## 2. Lock-Free SkipList Map (`SkipListMap[K, V]`)

`SkipListMap` provides a thread-safe ordered key-value dictionary with strict
ascending key iteration.

### Highlights

- **Aliases**: `SortedTable[K, V]`, `OrderedTable[K, V]`, `ConcurrentSortedTable[K, V]`.
- **Key Ordering**: Total key order via `<` or `cmp`.
- **Lookups**: **Wait-free** probabilistic $O(\log N)$.
- **Mutations**: **Lock-free** Harris-style logical deletion marking before unlinking.
- **Ordered Traversal**: Supports `pairs()`, `keys()`, and `values()` in sorted order.

### Example

```nim
import lockfree

var sortedMap = newSkipListMap[int, string]()

discard sortedMap.insert(30, "thirty")
discard sortedMap.insert(10, "ten")
discard sortedMap.insert(20, "twenty")

# Iterates in sorted order: 10, 20, 30
for (k, v) in sortedMap.pairs():
  echo k, " -> ", v
```

---

## 3. Concurrent Set (`SkipListSet[T]`)

`SkipListSet` is a lock-free concurrent set backed by the SkipList engine.

### Example

```nim
import lockfree

var seen = newSkipListSet[string]()

discard seen.insert("itemA")
discard seen.insert("itemB")

if seen.contains("itemA"):
  discard seen.remove("itemA")
```

---

## Choosing Between `Ctrie` and `SkipListMap`

| Dimension | `Ctrie` (`Table`) | `SkipListMap` (`SortedTable`) |
| :--- | :--- | :--- |
| **Ordering** | Unordered (Hash-partitioned) | Strict Total Key Order |
| **Lookup Latency** | Wait-free ($O(1)$ bounded depth) | Wait-free ($O(\log N)$ average) |
| **Snapshots** | $O(1)$ instantaneous root generation | $O(N)$ sequential copy |
| **Requirement** | `hash` and `==` | `cmp` or `<` |
| **Primary Use** | High-throughput caches, lookup tables | Time-series, ordered indices, range queries |
