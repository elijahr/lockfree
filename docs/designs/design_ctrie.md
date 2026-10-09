# Concurrency Architecture & Formal Invariants: Prokopec Ctrie (`Ctrie[K, V]`)

**Document ID**: `DESIGN-LOCKFREE-CTRIE-001`  
**Author**: Marcus Vance (`architect-horsetail`), Staff Systems Architect  
**Reviewers**: Caleb Thorne (`auditor-pegasus`), Elena Rostova (`implementer-kite`), Supreme Orchestrator (`orchestrator-whipbird`)  
**Status**: RATIFIED ARCHITECTURAL SPECIFICATION  
**Target Substrate**: `lockfree` (v0.1.0-consolidated)  
**Deliverable**: `docs/designs/design_ctrie.md`  

---

## Concurrency Topology & Substrate Banner

```
====================================================================================================
Concurrency Topology: MPMC Lock-Free Concurrent Hash Trie with O(1) Wait-Free Snapshots (Ctrie[K, V])
====================================================================================================
| Dimension              | Architectural Specification                                             |
|:-----------------------|:------------------------------------------------------------------------|
| **Topologies**         | MPMC (Multi-Producer Multi-Consumer Concurrent Associative Map)          |
| **Algorithm**          | Aleksandar Prokopec Concurrent Hash Trie (Ctrie) with HAMT 32-way Branch |
| **Snapshots**          | O(1) Time, O(1) Work Wait-Free Point-in-Time Generational Snapshots       |
| **Tree Depth**         | Maximum 7 levels for 32-bit hashes, 13 levels for 64-bit hashes (5 bits)  |
| **Key Ordering**       | Hash-partitioned HAMT (unordered key space; sorted iteration via snap)   |
| **Coordination**       | Atomic MainNode pointers on INodes, CAS compression and GCopy           |
| **Payload Storage**    | Type-agnostic pointer-indirection box (`VBox[V]`) under ARC/ORC          |
| **Collision Strategy** | Immutable persistent collision lists (`LNode[K, V]`)                     |
| **Progress Guarantees**| Lookups: Wait-Free Population; Mutations: Lock-Free; Snapshots: Wait-Free |
| **SMR Substrate**      | In-tree Debra SMR (NEBR, `src/lockfree/smr/nebr/`, `MaxThreads` capacity) |
| **Cache Alignment**    | INode and Root pointers aligned to `CacheLineBytes` (64/128-byte boundary)|
====================================================================================================
```

---

## 1. Executive Summary & Theoretical Foundations

### 1.1 Motivation & Architectural Gap Analysis
Within the `lockfree` concurrent container family, existing associative structures satisfy specific but distinct trade-offs:
- **`SkipListMap[K, V]`**: Provides strictly ordered $O(\log N)$ concurrent operations via Fraser/Herlihy skiplists. While optimal for range queries and ordered scans, skiplists require multi-level unlinking during removals, incur high pointer traversal overhead on deep levels, and cannot produce consistent whole-map point-in-time snapshots without global locking or expensive full-table copies.
- **`Table[K, V]` (C-ABI / Facade)**: Fast concurrent hash table based on hopscotch or flat-combining, but lacks non-blocking linearizable snapshots.

The **Prokopec Concurrent Hash Trie (`Ctrie`)** fills this fundamental architectural gap by providing:
1. **$O(1)$ Expected-Time Operations**: High-branching (32-way) Hash Array Mapped Trie (HAMT) reduces search path depth to $\le 6$ hops for billions of entries.
2. **$O(1)$ Wait-Free Point-in-Time Snapshots**: Snapshots are created in $O(1)$ atomic steps by lazily bumping the root generation token. Neither keys nor branch nodes are copied during snapshot creation.
3. **Wait-Free Linearizable Snapshot Traversal**: Readers iterating across a snapshot operate on an immutable, consistent point-in-time view without stalling concurrent mutators on the active trie.
4. **Self-Compacting Memory Footprint**: Deletion uses tombstone propagation (`TNode`) to contract singleton branches back into parent array nodes, preventing memory leaks and trie bloat.

### 1.2 Theoretical Foundations
This specification adapts and extends:
- **Aleksandar Prokopec, Nathan G. Bronson, Phil Bagwell, Martin Odersky (2012)**: *"Concurrent Tries with Efficient Non-Blocking Snapshots"*, PPoPP '12.
- **Phil Bagwell (2000)**: *"Ideal Hash Trees"*, Technical Report, EPFL.
- **Timothy L. Harris (2001)**: *"A Pragmatic Implementation of Non-Blocking Linked-Lists"*, DISC '01.

---

## 2. Node Taxonomy & Memory Layout

A Ctrie is a multi-way digital trie organized into three primary layers: **Indirection Nodes (`INode`)**, **Branch Nodes (`CNode`, `LNode`, `TNode`)**, and **Leaf Nodes (`SNode`)**.

```
                   +-----------------------------------+
                   |           Root INode              |
                   | gen: G0                           |
                   | main: ptr CNode (Generation G0)   |
                   +-----------------+-----------------+
                                     |
                                     v
                  +-------------------------------------+
                  |              CNode                  |
                  | bmp: 0b...10010 (popcount = 2)      |
                  | gen: G0                             |
                  | array: [ Child 0 | Child 1 ]        |
                  +--------+------------------+---------+
                           |                  |
              +------------+                  +-------------+
              |                                             |
              v                                             v
     +-----------------+                           +-----------------+
     |      INode      |                           |     SNode       |
     | gen: G0         |                           | key: "apple"    |
     | main: ptr CNode |                           | val: 100        |
     +--------+--------+                           | hash: 0x9AF2    |
              |                                    +-----------------+
              v
     +-----------------+
     |      CNode      |
     | array: [...]    |
     +-----------------+
```

### 2.1 Indirection Node (`INode[K, V]`)
The `INode` is the invariant anchor of every branch. It introduces a level of indirection that isolates concurrent updates: mutators swap the `main` pointer of an `INode` via `compareExchangeStrong` rather than modifying parent nodes.

```nim
type
  INode[K, V] = object
    main*: Atomic[ptr MainNode[K, V]]  ## Points to CNode, TNode, or LNode
    gen*: ptr Generation               ## Generational identity token
    alignPad: array[CacheLineBytes - sizeof(Atomic[pointer]) - sizeof(pointer), byte]
```
- **Alignment**: Every `INode` is aligned to `CacheLineBytes` (64 bytes on x86_64, 128 bytes on Apple Silicon) to eliminate false sharing between concurrent threads modifying adjacent branches.
- **Generation Invariant**: `gen` stamps the snapshot epoch under which this `INode` was created or updated.

### 2.2 Branch Node Hierarchy (`MainNode[K, V]`)
A `MainNode` is an abstract polymorphic node pointed to by `INode.main`. In our high-performance systems implementation, we use tagged pointers or a compact discriminator byte to eliminate dynamic dispatch overhead:

```nim
type
  MainNodeKind = enum
    mnkCNode  ## Compressed Hash Array Node
    mnkTNode  ## Tomb Node (Contracted singleton)
    mnkLNode  ## Collision List Node

  MainNode[K, V] = object
    kind*: MainNodeKind
    # Variant payload follows in unmanaged memory
```

#### 2.2.1 Compressed Array Node (`CNode[K, V]`)
A `CNode` represents a 32-way branch compressed via Bagwell's bitmap popcount technique. It stores only non-empty branches in a contiguous trailing array.

```nim
type
  CNode[K, V] = object
    kind*: MainNodeKind                 ## Always mnkCNode
    bmp*: uint32                        ## 32-bit occupancy bitmask
    gen*: ptr Generation                ## Generational stamp of this branch
    csize*: int                         ## Number of active children (popcount of bmp)
    children*: UncheckedArray[BranchNode[K, V]] ## Contiguous trailing array
```

#### 2.2.2 Branch Node Union (`BranchNode[K, V]`)
Each element in `CNode.children` is either an `INode` (sub-branch) or an `SNode` (direct leaf entry).
- We use the lowest bit of the pointer as a tag:
  - `tag == 00'u`: Pointer to `INode[K, V]`
  - `tag == 01'u`: Pointer to `SNode[K, V]`
- Tagging eliminates an additional indirection level for singleton leaves, maximizing cache-locality.

#### 2.2.3 Singleton Node (`SNode[K, V]`)
An `SNode` represents a single key-value entry. Once inserted, an `SNode` is immutable.
```nim
type
  SNode[K, V] = object
    key*: K
    vbox*: ptr VBox[V]                  ## ARC/ORC safe indirection box
    hash*: uint32                       ## Precomputed full 32-bit hash code
```

#### 2.2.4 Tombstone Node (`TNode[K, V]`)
A `TNode` marks an `INode` that has been contracted down to a single remaining leaf during deletion. It wraps the surviving `SNode`:
```nim
type
  TNode[K, V] = object
    kind*: MainNodeKind                 ## Always mnkTNode
    snode*: ptr SNode[K, V]             ## The surviving singleton
```
When an `INode.main` points to a `TNode`, any concurrent thread reading or modifying this branch is required to **clean** (contract) the parent `CNode`, replacing the child `INode` with the raw `SNode`.

#### 2.2.5 Collision List Node (`LNode[K, V]`)
When distinct keys produce the exact same 32-bit hash code, tree depth reaches maximum without distinguishing the keys. An `LNode` stores these colliding entries as an immutable persistent linked list or small array:
```nim
type
  LNodeEntry[K, V] = object
    key*: K
    vbox*: ptr VBox[V]
    next*: ptr LNodeEntry[K, V]

  LNode[K, V] = object
    kind*: MainNodeKind                 ## Always mnkLNode
    hash*: uint32                       ## Identical collision hash
    head*: ptr LNodeEntry[K, V]         ## Immutable list of colliding pairs
```

---

## 3. HAMT Indexing & Popcount Mechanics

Every level of the trie consumes 5 bits of the key's hash code, giving a branching factor of $2^5 = 32$.

```
Hash (32 bits): [ Level 5: 2b | Level 4: 5b | Level 3: 5b | Level 2: 5b | Level 1: 5b | Level 0: 5b ]
Bits consumed :      31..30       29..25       24..20       19..15       14..10        9..5        4..0
```

### 3.1 Bitmask Position & Array Offset
Given a 32-bit hash and a level depth $L \in \{0, 5, 10, 15, 20, 25, 30\}$:
1. **Branch Position ($0..31$)**:
   $$\text{pos} = (\text{hash} \gg L) \ \& \ 0\text{x}1\text{F}$$
2. **Bitmask Flag**:
   $$\text{flag} = 1\text{'u32} \ll \text{pos}$$
3. **Presence Check**:
   $$\text{present} = (\text{cnode.bmp} \ \& \ \text{flag}) \neq 0$$
4. **Compacted Array Index**:
   $$\text{idx} = \text{countBits32}(\text{cnode.bmp} \ \& \ (\text{flag} - 1))$$

Because `countBits32` compiles directly to the single-cycle hardware instruction `POPCNT` on x86_64 and `CNT` on ARM64, calculating `idx` is instantaneous ($< 1\text{ ns}$).

### 3.2 Dynamic Array Resizing (Copy-on-Write)
When inserting into a `CNode` where `(bmp and flag) == 0`:
1. Allocate a fresh `CNode` with capacity $\text{csize} + 1$ and new bitmap $\text{bmp}' = \text{bmp} \mid \text{flag}$.
2. Copy children $0 ..< \text{idx}$ directly to the new node.
3. Place the new item at position $\text{idx}$.
4. Copy children $\text{idx} ..< \text{csize}$ into slots $\text{idx} + 1 .. \text{csize}$.
5. Atomic CAS swaps the parent `INode.main` to the new `CNode`.

---

## 4. Generational Stamping & $O(1)$ Wait-Free Snapshots

The core innovation of Aleksandar Prokopec's Ctrie is **Generational Stamping**.

### 4.1 The Generation Token
```nim
type
  Generation = object
    id*: uint64                         ## Monotonic snapshot epoch counter
```
Every root `INode` and every `CNode` carries a pointer to a `Generation`. Two nodes belong to the same generation if and only if their `gen` pointers are identical (`a.gen == b.gen`).

### 4.2 The Snapshot Algorithm: $O(1)$ Atomic Re-Rooting
To create an instantaneous, point-in-time snapshot:
```nim
proc snapshot*[K, V, MaxThreads: static int](self: Ctrie[K, V, MaxThreads]): Ctrie[K, V, MaxThreads] =
  # Enter SMR pin scope to protect pointer dereferences
  withEpoch(self.smr, handle):
    while true:
      let curRoot = self.root.load(moAcquire)
      let curMain = curRoot.main.load(moAcquire)
      
      # Allocate a fresh generation token
      let freshGen = allocGeneration()
      
      # Construct a new root INode sharing the current CNode but stamped with freshGen
      let newRoot = allocINode[K, V](main = curMain, gen = freshGen)
      
      # Atomically swing the active Ctrie root to newRoot
      if self.root.compareExchangeStrong(curRoot, newRoot, moSequentiallyConsistent, moAcquire):
        # Construct and return snapshot Ctrie holding the old root
        return initCtrieFromRoot[K, V, MaxThreads](curRoot, self.smr)
      else:
        # CAS contention on root; free allocated unlinked node and retry
        deallocINode(newRoot)
        deallocGeneration(freshGen)
```
- **Time Complexity**: $O(1)$ — creates 1 `Generation` and 1 `INode`, performs 1 CAS.
- **Space Complexity**: $O(1)$ memory allocation.
- **Wait-Freedom**: If mutators do not contend on the root, this executes in bounded steps.

### 4.3 Lazy Generational Copy (`GCopy`)
When a mutator (insert/delete) traverses down an `INode` whose `gen != root.gen`:
1. The mutator knows this `CNode` belongs to an older snapshot and must **not** be mutated in place.
2. The mutator executes `GCopy`:
   ```nim
   proc gcopy[K, V](cnode: ptr CNode[K, V], targetGen: ptr Generation): ptr CNode[K, V] =
     let sz = cnode.csize
     result = allocCNode[K, V](bmp = cnode.bmp, gen = targetGen, csize = sz)
     for i in 0 ..< sz:
       result.children[i] = cnode.children[i]
   ```
3. The mutator attempts to CAS `inode.main` from the old `cnode` to the newly allocated copy stamped with `targetGen`.
4. If the CAS succeeds, the branch is now part of the current generation. If the CAS fails, another concurrent thread already performed the copy; the losing thread retries its operation on the winning `CNode`.

**Invariant**: Subtrees that are never updated after a snapshot are never copied. Copy-on-write is entirely lazy, amortized, and branch-isolated.

---

## 5. Algorithmic State Machines for Core Operations

```
                   +----------------------------------+
                   |       Traverse from Root         |
                   | level = 0, node = root.main      |
                   +----------------+-----------------+
                                    |
            +-----------------------+-----------------------+
            | (is CNode)                                    | (is TNode)
            v                                               v
+-----------------------+                       +-----------------------+
|  Check cnode.gen      |                       |  Clean Parent CNode   |
|  Matches root.gen?    |                       |  (untomb & contract)  |
+-----------+-----------+                       +-----------------------+
            |
    +-------+-------+
    | No            | Yes
    v               v
+-------+       +-----------------------------------+
| GCopy |       | Bit at pos in bmp?                |
+-------+       +-----------------+-----------------+
                                  |
                  +---------------+---------------+
                  | Bit Not Set                   | Bit Set
                  v                               v
         +-----------------+             +-----------------+
         | Slot is Empty   |             | Inspect Child   |
         | CAS-insert Leaf |             +--------+--------+
         +-----------------+                      |
                                  +---------------+---------------+
                                  | Child is SNode                | Child is INode
                                  v                               v
                         +-----------------+             +-----------------+
                         | Keys match?     |             | Recurse down    |
                         | Yes: Update val |             | level + 5       |
                         | No : Expand sub |             +-----------------+
                         +-----------------+
```

### 5.1 Lookup / Get / Contains (Wait-Free)
```nim
proc get*[K, V, MaxThreads: static int](
    self: Ctrie[K, V, MaxThreads],
    key: K
): Option[V] =
  let h = hash(key).uint32
  withEpoch(self.smr, handle):
    var cur = self.root.load(moAcquire)
    var level = 0
    while true:
      let main = cur.main.load(moAcquire)
      case main.kind
      of mnkCNode:
        let cn = cast[ptr CNode[K, V]](main)
        let pos = (h shr level) and 0x1F
        let flag = 1'u32 shl pos
        if (cn.bmp and flag) == 0:
          return none(V) # Key absent
        let idx = countBits32(cn.bmp and (flag - 1))
        let child = cn.children[idx]
        if child.isSNode:
          let sn = child.toSNode
          if sn.hash == h and sn.key == key:
            return some(sn.vbox.val)
          return none(V)
        else:
          # Recurse into child INode
          cur = child.toINode
          level += 5
      of mnkLNode:
        let ln = cast[ptr LNode[K, V]](main)
        return ln.lookup(key)
      of mnkTNode:
        # Parent is contracting; help contract or read embedded snode
        let tn = cast[ptr TNode[K, V]](main)
        if tn.snode.hash == h and tn.snode.key == key:
          return some(tn.snode.vbox.val)
        return none(V)
```
- **Progress**: Guaranteed wait-free. Lookups never perform CAS, never allocate memory, and traverse at most 7 pointer indirections.

### 5.2 Insert / Put / Incl (Lock-Free)
Insertion handles four mutually exclusive branch states:
1. **Empty Slot**: Bit `pos` is absent in `cn.bmp`. Mutator allocates a new `CNode` with the bit set and the new `SNode` inserted, and CASes `cur.main`.
2. **Key Match at Leaf**: Bit `pos` is present, pointing to an `SNode` whose key equals the new key. Mutator creates a cloned `CNode` replacing the `SNode` with the updated value.
3. **Collision at Leaf (Different Key, Different Hash Bits)**: Bit `pos` is present, pointing to an `SNode` with a different key. Mutator allocates an `INode` containing a sub-`CNode`, distributes both the existing `SNode` and the new `SNode` at `level + 5`, and CASes the slot.
4. **Hash Collision (Different Key, Identical Hash Code)**: Level reaches 30/35 and all hash bits match. Mutator converts the slot to an `LNode` containing both keys.

### 5.3 Removal / Delete / Excl with Contraction
Removal must guarantee that single-element branches do not remain dangling as empty tries:
1. Locate target `SNode` in `CNode`.
2. Allocate new `CNode` without that element (`csize - 1`).
3. If the resulting `CNode` has `csize == 1` and contains a single `SNode`, wrap it in a `TNode` (tombstone).
4. CAS `cur.main` to the `TNode`.
5. Execute bottom-up contraction: The parent `CNode` replaces the tombstoned `INode` with the raw `SNode`, shrinking the trie depth.

---

## 6. Collision Resolution (`LNode`)

When two distinct keys $K_1 \neq K_2$ satisfy $\text{hash}(K_1) == \text{hash}(K_2)$, no amount of trie expansion can separate them.

### 6.1 Formal LNode Invariants
- **Depth Invariant**: `LNode` instances exist **only** when `level >= MaxTrieDepth` (30 for 32-bit hashes).
- **Persistent Copy-on-Write**: `LNode` chains are immutable. Updates (`insert`, `delete`) construct a new `LNode` and CAS `INode.main`.
- **Contraction Invariant**: If a deletion from an `LNode` reduces its length to 1, the `LNode` is immediately converted into an `SNode` (or tombstoned into a `TNode`).

```nim
proc removeLNode[K, V](
    ln: ptr LNode[K, V],
    key: K,
    outSNode: var ptr SNode[K, V]
): ptr MainNode[K, V] =
  # Filter key from immutable collision list
  var newHead: ptr LNodeEntry[K, V] = nil
  var count = 0
  var curr = ln.head
  while curr != nil:
    if curr.key != key:
      newHead = allocLNodeEntry(curr.key, curr.vbox, newHead)
      inc count
    curr = curr.next

  if count == 0:
    return nil # Entire branch empty
  elif count == 1:
    # Contract to singleton SNode
    outSNode = allocSNode(newHead.key, newHead.vbox, ln.hash)
    return cast[ptr MainNode[K, V]](allocTNode(outSNode))
  else:
    return cast[ptr MainNode[K, V]](allocLNode(ln.hash, newHead))
```

---

## 7. Memory Ordering, Fences & Synchronization Invariants

| Memory Operation | Atomic Variable | Required Ordering | Formal Architectural Rationale |
|:---|:---|:---|:---|
| **Root Load** | `Ctrie.root` | `moAcquire` | Synchronizes with root replacement during `snapshot()` or contraction. |
| **Root Swap** | `Ctrie.root` | `moSequentiallyConsistent` / `moAcquire` | Establishes a total global order on snapshot generation bumps. |
| **INode Main Load** | `INode.main` | `moAcquire` | Enforces that all child node memory writes (CNode array, bmp) are visible before pointer dereference. |
| **INode Main CAS** | `INode.main` | `moRelease` (success) / `moAcquire` (failure) | Publishes new `CNode`/`TNode` to readers; failure orders subsequent reload. |
| **Node Publishing** | `CNode.children[i]` | `moRelease` | Prevents speculative stores of newly allocated SNodes/INodes from reordering past array assignment. |
| **VBox Val Load** | `VBox.val` | `moAcquire` | Ensures the payload value initialized under ARC/ORC is fully visible to concurrent thieves/readers. |

---

## 8. Safe Memory Reclamation (Debra SMR Integration)

Ctrie node retirement requires Safe Memory Reclamation to prevent ABA and use-after-free hazards on unmanaged pointers (`CNode`, `INode`, `LNode`, `VBox[V]`).

### 8.1 DEBRA Pin-Claim Discipline
Every reader and writer thread maintains a thread-local Debra registration handle:
```nim
template withCtriePin[K, V, MaxThreads](
    ctrie: Ctrie[K, V, MaxThreads],
    handleVar: untyped,
    body: untyped
) =
  var guard = ctrie.smr.pin()
  let handleVar = guard.handle
  try:
    body
  finally:
    discard guard.unpin()
```
- **Invariant 1 (Pin-Before-Dereference)**: The epoch guard MUST be acquired before loading `ctrie.root`.
- **Invariant 2 (Deferred Retirement)**: When an `INode.main` is updated via CAS, the displaced `oldMain` is **never** freed immediately. It is retired to the Debra limbo queue:
  ```nim
  debraRetire(ctrie.smr, handle, oldMain, deallocMainNodeCallback)
  ```
- **Invariant 3 (ARC/ORC Refcount Safety)**: Payloads (`V`) are boxed inside heap `VBox[V]`. When an entry is replaced or deleted, the `VBox` pointer is retired to Debra. The actual `=destroy(vbox.val)` executes only during physical reclamation when no thread holds an active pin in that epoch.

---

## 9. Nim API Specification & Ergonomics

```nim
type
  Ctrie*[K, V; MaxThreads: static int = DefaultMaxThreads] = object
    core: ptr CtrieCore[K, V, MaxThreads]

  Snapshot*[K, V; MaxThreads: static int = DefaultMaxThreads] = object
    core: ptr CtrieCore[K, V, MaxThreads]

# Constructors
proc initCtrie*[K, V](capacityHint: int = 16, maxThreads: static int = DefaultMaxThreads): Ctrie[K, V, MaxThreads]
proc initConcurrentMap*[K, V](capacityHint: int = 16): Ctrie[K, V, DefaultMaxThreads]

# Core Operations
proc put*[K, V, MaxThreads](self: Ctrie[K, V, MaxThreads], key: K, val: V): Option[V] {.discardable.}
proc get*[K, V, MaxThreads](self: Ctrie[K, V, MaxThreads], key: K): Option[V]
proc contains*[K, V, MaxThreads](self: Ctrie[K, V, MaxThreads], key: K): bool
proc delete*[K, V, MaxThreads](self: Ctrie[K, V, MaxThreads], key: K): Option[V] {.discardable.}
proc len*[K, V, MaxThreads](self: Ctrie[K, V, MaxThreads]): int
proc isEmpty*[K, V, MaxThreads](self: Ctrie[K, V, MaxThreads]): bool

# Atomic Conditional Operations
proc computeIfAbsent*[K, V, MaxThreads](
    self: Ctrie[K, V, MaxThreads],
    key: K,
    computeFn: proc(k: K): V {.closure, gcsafe.}
): V

# Snapshotting & Iteration
proc snapshot*[K, V, MaxThreads](self: Ctrie[K, V, MaxThreads]): Snapshot[K, V, MaxThreads]
iterator pairs*[K, V, MaxThreads](snap: Snapshot[K, V, MaxThreads]): (K, V)
iterator keys*[K, V, MaxThreads](snap: Snapshot[K, V, MaxThreads]): K
iterator values*[K, V, MaxThreads](snap: Snapshot[K, V, MaxThreads]): V

# Aliases
type
  ConcurrentMap*[K, V] = Ctrie[K, V, DefaultMaxThreads]
  ConcurrentTrie*[K, V] = Ctrie[K, V, DefaultMaxThreads]
```

---

## 10. Verification, Audit & Implementation Staging Plan

```
+-----------------------------------------------------------------------------------+
| Stage 1: Architectural Specification & Formal Invariants (docs/designs/design_ctrie.md) |
| Author: architect-horsetail | Verification: Two-Key Gate & Orchestrator Ratification     |
+-----------------------------------------+-----------------------------------------+
                                          |
                                          v
+-----------------------------------------------------------------------------------+
| Stage 2: Core Data Structures & Popcount Indexing (src/lockfree/ctrie.nim)        |
| Nodes (INode, CNode, SNode, LNode, TNode), Allocators, Debra SMR Registration      |
+-----------------------------------------+-----------------------------------------+
                                          |
                                          v
+-----------------------------------------------------------------------------------+
| Stage 3: Generational Snapshotting & Mutation State Machine                        |
| O(1) snapshot(), GCopy lazy copy-on-write, CAS insertion & bottom-up contraction   |
+-----------------------------------------+-----------------------------------------+
                                          |
                                          v
+-----------------------------------------------------------------------------------+
| Stage 4: Comprehensive Stress Testing & TSAN Validation (tests/t_ctrie.nim)        |
| 16-thread MPMC hammer, snapshot consistency under continuous writes, LNode repros |
+-----------------------------------------------------------------------------------+
```

### 10.1 Key Invariants for Auditor Verification
1. **Zero Data Races**: Every pointer transition on `INode.main` and `Ctrie.root` must pass under ThreadSanitizer (`-d:tsan`).
2. **Snapshot Immutability**: Under 16 concurrent worker threads inserting $100{,}000$ unique keys, taking a snapshot at $T_{snap}$ must yield an iterator whose count and values remain strictly constant regardless of subsequent mutations on the parent Ctrie.
3. **Contraction Soundness**: Removing all keys must collapse the trie back to an empty root without dangling tombstones or leaked `INode` chains.
4. **SMR Cleanliness**: All retired nodes must be reclaimed via Debra SMR without leaks or double-frees under ARC and ORC.

---

**Architectural Sign-off**:  
*Marcus Vance (`architect-horsetail`), Staff Systems Architect, 2026-10-08*
