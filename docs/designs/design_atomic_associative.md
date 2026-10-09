# Concurrency Architecture & Formal Invariants: Atomic Associative Map Operations

**Document ID**: `DESIGN-LOCKFREE-ASSOCIATIVE-001`  
**Author**: Marcus Vance (`architect-horsetail`), Staff Systems Architect  
**Reviewers**: Caleb Thorne (`auditor-pegasus`), Elena Rostova (`implementer-kite`), Supreme Orchestrator (`orchestrator-whipbird`)  
**Status**: RATIFIED ARCHITECTURAL SPECIFICATION  
**Target Substrate**: `lockfree` (v0.1.0-consolidated)  
**Deliverable**: `docs/designs/design_atomic_associative.md`  

---

## Concurrency Topology & Substrate Banner

```
====================================================================================================
Concurrency Topology: Atomic Associative Map Operations (Wave 5A)
====================================================================================================
| Dimension              | Architectural Specification                                             |
|:-----------------------|:------------------------------------------------------------------------|
| **Target Substrates**  | `Ctrie[K, V]` (Unordered Concurrent HAMT) & `SkipListMap[K, V]` (Ordered)|
| **Compound Operations**| `computeIfAbsent`, `atomicUpdate`, `upsert`, Consistent Snapshot Iterate |
| **Progress Guarantees**| Read-Paths: Wait-Free; CAS Update Paths: Lock-Free with Linear Backoff  |
| **Snapshot Guarantees**| `Ctrie`: O(1) Wait-Free Generational Root Swing; `SkipList`: Epoch-Pinned|
| **Linearization Points**| Exact Atomic CAS Instructions on Value Pointer (`valPtr`) or `INode.main`|
| **SMR Discipline**     | In-tree Debra SMR (NEBR) with Strict Ephemeral Pin Scopes               |
| **Closure Semantics**  | Strict Idempotency Requirement: Closures May Re-Execute During CAS Retries|
| **Payload Storage**    | Atomic Reference-Counted Pointer Box (`VBox[V]`) under ARC/ORC          |
| **Memory Reclamation** | Retired `VBox[V]` Nodes Deferred-Reclaimed via Debra `retire()` Callbacks|
| **Cache Alignment**    | Node Anchors and Roots Aligned to `CacheLineBytes` (64/128-byte boundary)|
| **Typestates Pragma**  | Procedures Decorated with `{.notATransition.}` for Strict Typestate Gate |
| **C ABI Interop**      | Foreign Thread C99 Callback Bindings via `include/lockfree_associative.h`|
====================================================================================================
```

---

## 1. Executive Summary & Problem Formulation

### 1.1 The Compound Associative Mutation Gap
Basic concurrent map operations (`get`, `put`, `delete`) provide atomic point accesses. However, modern high-concurrency systems (caches, distributed state stores, rate limiter registries, metric aggregators, and actor mailboxes) require **compound read-modify-write primitives**:

1. **`computeIfAbsent(key, mappingProc)`**:
   - Lazily compute an expensive resource (e.g. database connection, token bucket, parsed AST) if and only if the key does not already exist.
   - Naive sequence: `if not map.hasKey(k): map[k] = f(k)` creates a disastrous race condition where multiple threads redundantly compute `f(k)` and overwrite each other's state, leaking resources.
2. **`atomicUpdate(key, updateProc)`**:
   - Atomically transform an existing value $V_{\text{old}} \to V_{\text{new}}$ using an arbitrary pure function (e.g. increment counter, append log entry, adjust state machine).
   - Naive sequence: `let v = map[k]; map[k] = f(v)` loses concurrent updates under multi-threaded execution (the classic **Lost Update Anomaly**).
3. **`upsert(key, insertVal, updateProc)`**:
   - Insert `insertVal` if absent, or apply `updateProc(existing)` if present, guaranteeing atomic settlement without torn reads or phantom overwrites.
4. **`Consistent Snapshot Iteration`**:
   - Iterate across all active key-value pairs representing a single coherent point-in-time without taking global locks or stalling concurrent mutators.

### 1.2 Wave 5A Architectural Scope
Wave 5A specifies and standardizes these atomic compound operations across both concurrent map substrates in `lockfree`:
- **`Ctrie[K, V]`**: Prokopec's Concurrent Hash Array Mapped Trie (HAMT) with $O(1)$ wait-free generational snapshots.
- **`SkipListMap[K, V]`**: Fraser / Herlihy concurrent skip list with Harris logical marking and strict total key ordering.

---

## 2. Theoretical Foundations & Linearization Points

```
+----------------------------------------------------------------------------------------------------+
| Operation            | Key State | Outcome    | Linearization Point                                 |
+:---------------------|:----------|:-----------|:----------------------------------------------------+
| `computeIfAbsent`    | Present   | No-op      | Atomic load of existing `SNode` / `SkipListNode`   |
| `computeIfAbsent`    | Absent    | Inserted   | Atomic CAS inserting new node with computed `VBox` |
| `atomicUpdate`       | Absent    | None       | Atomic load establishing absence of key            |
| `atomicUpdate`       | Present   | Transformed| Atomic CAS swinging `valPtr` or `INode.main`       |
| `upsert`             | Absent    | Inserted   | Atomic CAS inserting new node with `insertVal`     |
| `upsert`             | Present   | Transformed| Atomic CAS swinging `valPtr` or `INode.main`       |
| `snapshot` (Ctrie)   | N/A       | Frozen Tree| Atomic CAS on root INode swinging generation        |
| `snapshot` (SkipList)| N/A       | Pinned View| Monotonic epoch acquisition + level-0 scan          |
+----------------------------------------------------------------------------------------------------+
```

### 2.1 Formal Linearization Proofs

#### Linearization of `computeIfAbsent`:
- Let $k$ be the target key, and $f$ be the mapping function.
- **Case 1 (Key Present)**: The traversal encounters a valid, unmarked node containing $k$ with value $V_{\text{existing}}$. The linearization point is the `moAcquire` load of the node pointer that proves $k$ was present. The closure $f$ is NOT invoked.
- **Case 2 (Key Absent)**: The traversal finds no node matching $k$. The thread executes $v = f(k)$ and prepares a new node. The linearization point is the successful `compareExchange` (`moAcqRel`) that inserts the node into the data structure. If the CAS fails because another thread inserted $k$ concurrently, the thread discards $v$ and retries.

#### Linearization of `atomicUpdate`:
- Let $k$ be the key, and $u$ be the update closure $V \to V$.
- **Case 1 (Key Absent)**: The search proves $k$ is not present. Linearizes at the atomic load proving absence. Returns `none(V)`.
- **Case 2 (Key Present)**: The search locates node $N$ with current value box $B_{\text{old}}$. The thread computes $B_{\text{new}} = \text{newVBox}(u(B_{\text{old}}.\text{val}))$.
  - In `SkipListMap`: Linearizes at `N.valPtr.compareExchange(B_{\text{old}}, B_{\text{new}}, moAcqRel)`.
  - In `Ctrie`: Linearizes at `INode.main.compareExchange(oldMain, newMain, moAcqRel)`.
- If another thread modified the value concurrently, the CAS fails; the thread re-reads the fresh value, re-invokes $u$, and retries.

---

## 3. Algorithmic State Machines Across Substrates

### 3.1 `Ctrie[K, V]` Compound Mutations

In `Ctrie[K, V]`, keys are distributed across a 32-way branching HAMT. Updates occur by atomically replacing the `main` pointer of the parent `INode`:

```
                       INode (Level L)
                     +-----------------+
                     | main (Atomic)   |
                     +--------+--------+
                              |
                              v
                   +---------------------+
                   | CNode (Branch)      |
                   | - bmp: uint32       |
                   | - array of branches |
                   +----------+----------+
                              |
               +--------------+--------------+
               |                             |
               v                             v
       SNode (Key, VBox_old)         INode (Level L+1)
```

#### The `Ctrie` Update Protocol:
1. Pointers are read inside an active Debra SMR pin scope (`pin()`).
2. If an `SNode` with matching `key` is found:
   - Read $V_{\text{old}} = \text{snode.vbox.val}$.
   - Compute $V_{\text{new}} = \text{updateProc}(V_{\text{old}})$.
   - Allocate new $B_{\text{new}} = \text{newVBox}(V_{\text{new}})$.
   - Create a cloned `CNode` containing a new `SNode` pointing to $B_{\text{new}}$.
   - Attempt CAS on `INode.main`:
     ```nim
     if inode.main.compareExchangeStrong(curMain, newMain, moAcquireRelease, moAcquire):
       # Success! Retire displaced SNode and CNode to SMR
       manager.retire(oldSNode, destroySNodeCallback)
       manager.retire(curMain, destroyCNodeCallback)
       return some(V_new)
     else:
       # CAS Failed (Concurrent modification or GCopy compression)
       decRef(B_new) # Destroy unused speculative value!
       # Retry traversal from root
     ```

---

### 3.2 `SkipListMap[K, V]` In-Place Value CAS Protocol

In `SkipListMap[K, V]`, nodes are arranged in a multi-level linked list ordered by key. Keys are immutable once inserted, but **values can be updated in-place via atomic CAS on `valPtr`**:

```
[ SkipListNode ]
- key: K (Immutable)
- topLevel: int
- next: array[MaxLevel, Atomic[uint]]
- valPtr: Atomic[ptr VBox[V]]  <--- ATOMIC LINEARIZATION POINT
```

#### The In-Place Value Update Advantage:
- Because the skip list topology (tower height, key ordering, next pointers) remains completely unchanged when only the value is modified, `atomicUpdate` does NOT require modifying skip list pointers or rebuilding towers!
- It executes an in-place CAS directly on `node.valPtr`:

```nim
proc atomicUpdate*[K, V; MT, ML: static int](
    self: var SkipListMap[K, V, MT, ML],
    key: K,
    updateProc: proc(v: V): V {.closure.}
): Option[V] =
  let pinGuard = self.core.manager.pin()
  var spins = InitialSpin
  
  while true:
    # 1. Search for key at Level 0
    let (node, found) = self.searchNode(key)
    if not found or node.isMarked():
      return none(V)
      
    # 2. Read current VBox
    let oldBox = node.valPtr.load(moAcquire)
    if oldBox == nil:
      return none(V) # Node is being deleted
      
    # 3. Speculatively compute new value
    let newVal = updateProc(oldBox.val)
    let newBox = newVBox(newVal)
    
    # 4. Atomic CAS to swap value pointers
    var expected = oldBox
    if node.valPtr.compareExchange(expected, newBox, moAcqRel):
      # Success! Retire oldBox to Debra SMR
      self.core.manager.retire(oldBox, destroyVBoxCallback[V])
      return some(newVal)
    else:
      # Contention: Another thread updated or deleted this key
      decRef(newBox) # Prevent memory leak of speculative value!
      backoffOnRetry(spins)
```

**Complexity**: $O(\log N)$ search + $O(1)$ lock-free CAS update.

---

## 4. Safe Memory Reclamation (SMR / NEBR) Discipline

### 4.1 Strict Ephemeral Pin Scopes
All compound operations interact with shared pointers that may be concurrently retired and freed by other threads.

To guarantee complete memory safety:
1. **Pin Before Dereference**:
   A thread MUST acquire an active Debra SMR pin before reading any node pointer:
   ```nim
   let pinGuard = self.manager.pin()
   ```
2. **Never Hold Pins Across Thread Blocking / Suspension**:
   Pin scopes are strictly synchronous. As proven in Wave 3C (`DESIGN-LOCKFREE-ASYNC-BRIDGE-001`), yielding or blocking while holding a pin stalls the global epoch and leads to memory bloat.
3. **Retire Displaced Nodes & Values**:
   When an `atomicUpdate` replaces a value:
   - The old `VBox[V]` is NOT immediately freed (`free()`), because concurrent reader threads may currently be reading `oldBox.val`!
   - The thread delegates the pointer to Debra SMR:
     ```nim
     self.manager.retire(oldBox, destroyVBoxCallback[V])
     ```
   - Debra guarantees that `destroyVBoxCallback` is only invoked when all threads have advanced past the epoch in which `oldBox` was displaced.

### 4.2 Typestates Pragma Compliance
Under the strict typestates enforcement of the `lockfree` substrate (`/Users/eek/.nimble/bin/typestates verify -W src/`), any procedure participating in SMR operations without altering the manager's typestate MUST be marked:
```nim
proc computeIfAbsent*[K, V](...) {.notATransition.}
```
This ensures zero compilation warnings or type-state transition failures under strict verification.

---

## 5. Closure Idempotency Contract

### 5.1 The Contention Re-execution Phenomenon
In lock-free algorithms, optimistic computation is followed by an atomic CAS. If $N$ threads concurrently attempt `atomicUpdate` or `computeIfAbsent` on the same key:
- Exactly 1 thread succeeds on its CAS.
- $N - 1$ threads fail their CAS, back off, reload the latest state, and **re-execute the closure**!

```
Thread A: val = 10 -> f(10) = 11 -> CAS SUCCESS -> Value is 11
Thread B: val = 10 -> f(10) = 11 -> CAS FAILS!
Thread B (Retry): val = 11 -> f(11) = 12 -> CAS SUCCESS -> Value is 12
```

### 5.2 The Invariant of Functional Purity
To prevent catastrophic side-effect bugs, Wave 5A establishes the **Closure Idempotency Contract**:

> **ARCHITECTURAL INVARIANT**:  
> The user-supplied closure (`mappingProc` or `updateProc`) MUST be a **pure function** free of external side-effects.  
> It MUST NOT:
> 1. Perform network, socket, or file I/O.
> 2. Mutate external non-thread-local state.
> 3. Increment non-idempotent counters outside the map.
> 4. Allocate external resources that cannot be safely rolled back upon CAS failure.

---

## 6. ARC/ORC Memory Management & Discard Safety

### 6.1 The Speculative Allocation Leak Hazard
When a thread prepares to perform a CAS in `computeIfAbsent` or `atomicUpdate`:
1. It calls `newVBox(mappingProc(key))`.
2. This allocates heap memory for `VBox[V]` and initializes `val: V`.
3. Under Nim ARC/ORC, types like `string`, `seq[T]`, and `ref Object` hold internal reference counts or heap allocations.
4. **Hazard**: If the CAS fails, the thread cannot simply overwrite its local pointer! Doing so leaks the newly allocated `VBox` and all heap memory owned by `val`!

### 6.2 The Guaranteed Discard Protocol
Wave 5A enforces the **Guaranteed Discard Protocol**:

```
Compute Speculative Value
         |
         v
   newBox = allocVBox(newVal)
         |
         v
[Atomic CAS Attempt]
         |
    +----+----+
    |         |
 SUCCESS    FAILURE
    |         |
    v         v
 Retire    decRef(newBox)   <--- IMMEDIATELY DESTROYS SPECULATIVE VAL
 oldBox       |                  AND RECLAIMS HEAP MEMORY
              v
       [Backoff & Retry]
```

```nim
proc decRef[V](box: ptr VBox[V]) {.inline.} =
  if box != nil:
    if box.rc.fetchSub(1, moAcquireRelease) == 1:
      when not (V is SomeNumber or V is bool or V is char or V is pointer or V is ptr):
        {.cast(gcsafe).}:
          `=destroy`(box.val)
      deallocShared(box)
```
- On CAS success: `newBox` ownership is transferred to the map; `oldBox` is retired to SMR.
- On CAS failure: `decRef(newBox)` is executed immediately, triggering `=destroy(newBox.val)` and `deallocShared(newBox)`. Zero memory leaks under all interleavings!

---

## 7. Consistent Snapshot Iteration

### 7.1 `Ctrie[K, V]` Generational Snapshots ($O(1)$ Time & Work)
`Ctrie` achieves instantaneous, lock-free, wait-free point-in-time snapshots via **Generational Stamping** (Prokopec 2012):
1. `ctrie.snapshot(): Ctrie[K, V]`:
   - Allocates a new generation identifier `gen_new`.
   - Prepares a fresh root `INode` pointing to the current main node.
   - Atomically swaps the root with `moAcqRel`.
2. **Lazy Copy-On-Write (`GCopy`)**:
   - Mutator threads encountering nodes stamped with an older generation lazily clone only the path from the root to the modified leaf.
   - Unmodified branches are shared immutably between the snapshot and the active tree!
3. **Iteration**:
   - `pairs(snap)` traverses the frozen trie without needing SMR pins, without locks, and with zero interference with concurrent writers.

### 7.2 `SkipListMap[K, V]` Consistent Iteration
Unlike `Ctrie`, a concurrent skip list does not have a single root node that can be swung to freeze the tree. Wave 5A specifies two complementary snapshot iteration models for `SkipListMap`:

#### Model 1: Ephemeral Pinned Streaming Iterator (`iterator pairs`)
- Traverses Level-0 nodes from `head` to `tail` inside a single Debra SMR pin scope.
- Filters out logically marked nodes (`isMarked(node.next[0])`).
- Reads `node.valPtr` with `moAcquire`.
- **Guarantee**: Provides weakly consistent, lock-free iteration. Guarantees every element visited was present at some point during the traversal and reflects a valid linearizable state. Zero heap allocations!

#### Model 2: Materialized Consistent Snapshot (`proc snapshotPairs`)
- For callers requiring strict point-in-time isolation:
- Traverses Level-0 under Debra SMR and copies `(K, V)` pairs into a newly allocated `seq[(K, V)]`.
- Guarantees the resulting sequence is fully detached from concurrent writers.

---

## 8. C ABI & Interoperability Layer

Wave 5A exports C99 bindings to allow foreign threads (e.g. C/C++, Rust, Go) to perform atomic associative map updates:

### Header Specification: `include/lockfree_associative.h`
```c
#ifndef LOCKFREE_ASSOCIATIVE_H
#define LOCKFREE_ASSOCIATIVE_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void* lfq_ctrie_t;
typedef void* lfq_skiplist_t;

// C-compatible callback signatures
typedef void* (*lfq_mapping_fn)(const void* key, size_t key_len, void* user_data);
typedef void* (*lfq_update_fn)(const void* old_val, size_t old_val_len, void* user_data);

// Ctrie Atomic Operations
bool lfq_ctrie_compute_if_absent(
    lfq_ctrie_t trie,
    const void* key, size_t key_len,
    lfq_mapping_fn mapping_fn, void* user_data,
    void** out_val, size_t* out_val_len
);

bool lfq_ctrie_atomic_update(
    lfq_ctrie_t trie,
    const void* key, size_t key_len,
    lfq_update_fn update_fn, void* user_data,
    void** out_val, size_t* out_val_len
);

// SkipListMap Atomic Operations
bool lfq_skiplist_compute_if_absent(
    lfq_skiplist_t map,
    const void* key, size_t key_len,
    lfq_mapping_fn mapping_fn, void* user_data,
    void** out_val, size_t* out_val_len
);

bool lfq_skiplist_atomic_update(
    lfq_skiplist_t map,
    const void* key, size_t key_len,
    lfq_update_fn update_fn, void* user_data,
    void** out_val, size_t* out_val_len
);

#ifdef __cplusplus
}
#endif

#endif // LOCKFREE_ASSOCIATIVE_H
```

---

## 9. Formal Memory Ordering & Synchronization Proofs

### 9.1 Memory Ordering Invariant Table

| Operation | Atomic Target | Order | Formal Justification |
|:---|:---|:---|:---|
| `valPtr` CAS (SkipList) | `Atomic[ptr VBox[V]]` | `moAcqRel` | Synchronizes the publisher of $V_{\text{new}}$ with subsequent readers; linearizes the update. |
| `valPtr` Load (SkipList) | `Atomic[ptr VBox[V]]` | `moAcquire` | Establishes happens-before: reader observes fully initialized memory of `VBox[V]`. |
| `INode.main` CAS (Ctrie) | `Atomic[ptr MainNode]` | `moAcqRel` | Publishes new HAMT branch or leaf; linearizes tree mutation. |
| `INode.main` Load (Ctrie) | `Atomic[ptr MainNode]` | `moAcquire` | Traversal observes valid branch structure and child nodes. |
| `VBox.rc` fetchSub | `Atomic[int]` | `moAcqRel` | Ensures all reads of `val` complete before the final refcount drop triggers `=destroy`. |

### 9.2 Linearization Points & Invariants
1. **Absence Confirmation**: Linearizes at the atomic load of the terminal child/next pointer that proves the key does not exist.
2. **Presence Confirmation**: Linearizes at the atomic load of the node whose key matches the query.
3. **Atomic Modification**: Linearizes at the single atomic CAS instruction (`compareExchange`) that swaps the value pointer or root/branch pointer.

---

## 10. Verification Strategy & Two-Key Gate Criteria

Wave 5A requires exhaustive concurrency stress testing, lost-update verification, and memory safety audits:

1. **High-Contention Atomic Counter Stress (`tests/t_associative_contention.nim`)**:
   - 32 threads concurrently execute `atomicUpdate(k, v => v + 1)` 100,000 times on the same shared key.
   - Assert: Final value MUST equal exactly $32 \times 100,000 = 3,200,000$.
   - Proves zero lost updates under extreme CAS contention.
2. **`computeIfAbsent` Race Fuzzing (`tests/t_associative_compute.nim`)**:
   - 64 threads simultaneously invoke `computeIfAbsent(k, heavyInit)` on a missing key.
   - Assert: Exactly one computed instance is retained in the map; all other threads receive that instance. Zero resource leaks.
3. **Concurrent Snapshot Mutation Audit (`tests/t_associative_snapshot.nim`)**:
   - Thread A continuously mutates keys (insertions, deletions, updates).
   - Thread B takes snapshots and iterates.
   - Assert: Snapshots observe strictly monotonic key sets without torn values or internal trie inconsistency.
4. **ThreadSanitizer & ARC Leak Gate**:
   - Compile and execute under `--mm:orc` with `-fsanitize=thread`.
   - Assert zero data races and zero memory leaks.
5. **Two-Key Integration Gate**:
   - Key 1 Mechanical Gate: Clean merge-tree SHA against `main`.
   - Key 2 Semantic Gate: 100% green compilation and test suite execution via `nimble test`.
