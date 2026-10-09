# Comprehensive Concurrency, Memory Ordering, and SMR Audit Report: Prokopec Ctrie (`Ctrie[K, V]`)

**Author**: Caleb Thorne (`auditor-pegasus`), Verification & Adversarial Auditor  
**Date**: October 8, 2026  
**Target Substrate**: `lockfree` (v0.1.0-consolidated)  
**Target Component**: `src/lockfree/ctrie.nim` (Wave 2C Ctrie Implementation)  
**Deliverable**: `docs/reviews/review_ctrie_concurrency.md`  
**Referenced Specification**: `docs/designs/design_ctrie.md` (`DESIGN-LOCKFREE-CTRIE-001` by `architect-horsetail`)  
**Auditor Verification Invariants**: Prokopec 2012 Invariants, Bagwell HAMT Invariants, Debra SMR Pin-Claim Lifecycle, ARC/ORC Destructor Safety  

---

## 1. Executive Summary & Verdict

This report delivers an adversarial, formal audit of the `Ctrie[K, V]` implementation in `src/lockfree/ctrie.nim`.

The Aleksandar Prokopec Concurrent Hash Trie (Ctrie) is an advanced non-blocking associative structure combining:
1. **A 32-way compressed Hash Array Mapped Trie (HAMT)** utilizing single-cycle hardware popcount instructions (`countBits32`).
2. **Atomic Indirection Nodes (`INode`)** that isolate concurrent mutation hotspots.
3. **Generational Stamping and Lazy Copy-on-Write (`GCopy`)** that achieve $O(1)$ time and $O(1)$ work wait-free point-in-time snapshots.
4. **Bottom-up Tombstone Contraction (`TNode`)** that shrinks single-element subtrees back to parent leaves upon deletion.
5. **In-Tree Debra Safe Memory Reclamation (NEBR)** protecting unmanaged node memory across epoch boundaries.

### Audit Verdict: CONDITIONAL RATIFICATION PENDING REMEDIATION
While the fundamental Prokopec generational state machine, HAMT popcount bit-indexing, and root CAS re-rooting algorithms are soundly implemented, the adversarial audit has intercepted **two critical vulnerabilities (CRIT)** and **three high-severity defects (HIGH)** that must be remediated:

| Finding ID | Severity | Category | Summary |
|:---|:---|:---|:---|
| **CRIT-01** | **CRITICAL** | Memory Safety / ARC | Premature Deallocation and Double-Free of Shared `VBox` in `LNode` Updates and Contractions |
| **CRIT-02** | **CRITICAL** | Concurrency / SMR | Unprotected Pointer Traversal in `Snapshot` Reads and Iterators without Debra SMR Pin |
| **HIGH-01** | **HIGH** | Resource Leak | Leaked Contracted `INode` and `TNode` Instances during Bottom-Up Contraction |
| **HIGH-02** | **HIGH** | Linearizability | Non-Atomic Overwrite Race and Lost Updates in `computeIfAbsent` |
| **HIGH-03** | **HIGH** | Resource Leak | Unbounded Memory Leak of `Generation` Objects and Snapshot Root INodes |
| **MED-01** | **MEDIUM** | Undefined Behavior | Undefined Behavior via Shift Count $\ge 32$ in `createSubINode` |
| **MED-02** | **MEDIUM** | SMR Exhaustion | Debra Thread Registration Slot Leak on TLS Cache Eviction |
| **LOW-01** | **LOW** | Memory Ordering | Weak Refcount Decrement Ordering in `decRef` and `=destroy` |

---

## 2. In-Depth Adversarial Analysis by Focus Area

### 2.1 Generation Renewal & Root INode CAS

#### Formal Invariant (Prokopec 2012 §3.2)
> *A snapshot generation $G_{k}$ is created by swinging the root `INode` to point to a new root stamped with a fresh generation token $G_{k+1}$, while preserving the existing root `CNode`. Any subsequent mutator encountering a `CNode` whose generation does not match the active root generation MUST lazily replicate the path (`GCopy`) rather than mutating in place.*

#### Analysis of `src/lockfree/ctrie.nim`:
1. **Root CAS Mechanism**:
   ```nim
   # Line 905-912:
   let curRoot = self.core.root.load(moAcquire)
   let curMain = curRoot.main.load(moAcquire)
   let freshGen = allocGeneration()
   let newRoot = allocINode[K, V](curMain, freshGen)
   var expCurRoot = curRoot
   if self.core.root.compareExchangeStrong(expCurRoot, newRoot, moSequentiallyConsistent, moAcquire):
     discard self.core.rc.fetchAdd(1, moRelaxed)
     return Snapshot[K, V, MaxThreads](core: self.core, root: curRoot)
   ```
   - **Memory Ordering**: Uses `moSequentiallyConsistent` for root swing, establishing a total order across all snapshots.
   - **Isolation**: Mutators traversing from `newRoot` observe `cn.gen != root.gen` upon encountering the root `CNode` (since `cn.gen` was created under `curRoot.gen`).
   - **GCopy Trigger**: The mutator immediately creates a generational replica via `gcopy(cn, root.gen)` and installs it in `newRoot.main` via CAS.
   - **Snapshot Immutability**: The snapshot holds `curRoot`. Mutator writes are directed exclusively to `newRoot.main` and freshly minted generation branches. `curRoot.main` remains completely immutable.
2. **Defect Intercepted (HIGH-03)**:
   - `allocGeneration()` sets `gen.rc = 1`.
   - `allocINode(curMain, freshGen)` executes `incRef(freshGen)`, incrementing `rc` to 2.
   - Neither the success path nor the retry path in `snapshot()` decrements the initial reference count acquired by `allocGeneration()`.
   - On CAS failure, `freeAligned(newRoot)` does not drop the reference on `newRoot.gen`, leaving `freshGen.rc = 1` permanently leaked.
   - On CAS success, `freshGen.rc = 2`. When `newRoot` is eventually destroyed, `destroyINodeCallback` drops `rc` to 1, leaving `freshGen` permanently leaked on the heap.

---

### 2.2 CNode Expansion & HAMT Bit-Partitioning

#### Formal Invariant (Bagwell 2000 §2)
> *At level $L \in \{0, 5, 10, 15, 20, 25, 30\}$, branch index $\text{pos} = (H \gg L) \ \& \ 0\text{x}1\text{F}$. Occupancy is tracked via bitmap `bmp`. The compacted array offset is $\text{popcount}(\text{bmp} \ \& \ ((1 \ll \text{pos}) - 1))$. Under insertion, slots must maintain strictly sorted bit order without element displacement or lost branches.*

#### Analysis of `src/lockfree/ctrie.nim`:
1. **Popcount Correctness**:
   - `countBits32(cn.bmp and (flag - 1'u32))` correctly compiles to the single-cycle hardware popcount instruction (`POPCNT` on x86, `CNT` on ARM64).
   - Array resizing in lines 584-589 correctly preserves existing children before `idx`, places the new item at `idx`, and offsets subsequent children by $+1$.
2. **Bit-Stealing Collision Expansion**:
   - When an insertion encounters an existing `SNode` with a different key, `createSubINode` is invoked at `level + 5`:
   - If the two keys have different hash bits at the next level ($p_1 \neq p_2$), a 2-element `CNode` is allocated with `bmp = (1 shl p1) or (1 shl p2)`.
   - If $p_1 == p_2$, `createSubINode` recurses down to `level + 5`.
3. **Defect Intercepted (MED-01)**:
   - In `createSubINode` (lines 374-375):
     ```nim
     let p1 = (h1 shr level) and 0x1F'u32
     let p2 = (h2 shr level) and 0x1F'u32
     ```
   - These shifts are executed *before* checking `if level >= MaxLevel or h1 == h2`.
   - If two keys collide in a level-30 `CNode`, `createSubINode` is invoked with `level = 35`.
   - Shifting a 32-bit unsigned integer by 35 is undefined behavior in ISO C11 (§6.5.7/3). On x86 processors, the shift count is masked by 31 (`35 and 31 = 3`), causing the trie to erroneously compare hash bits 3..7 and attempt infinite branch expansion instead of immediately creating an `LNode`.

---

### 2.3 SNode Hash Collision Resolution & LNode Lifecycle

#### Formal Invariant (Prokopec 2012 §4.1)
> *Keys with identical 32-bit hashes that reach depth `MaxLevel` (30) must be resolved via immutable persistent collision chains (`LNode`). Modifications to an `LNode` create a new list version and CAS the branch `INode.main`. When a deletion leaves an `LNode` with exactly 1 element, it MUST contract to an `SNode`.*

#### Analysis of `src/lockfree/ctrie.nim`:
1. **List CAS Synchronization**:
   - Updates and deletions to `LNode` allocate a fresh `LNodeEntry` chain and atomically swap `cur.main` via `compareExchangeStrong(expMain, newLn, moAcquireRelease, moAcquire)`.
2. **Catastrophic Defect Intercepted (CRIT-01)**:
   - In `put` on `mnkLNode` (lines 664-672):
     ```nim
     while curr != nil:
       if curr.key == key:
         found = true
         oldVal = curr.vbox.val
         let vb = newVBox(val)
         newHead = allocLNodeEntry(key, vb, newHead)
       else:
         newHead = allocLNodeEntry(curr.key, curr.vbox, newHead)
       curr = curr.next
     ```
   - For all non-updated keys, `newHead` copies `curr.vbox` from `ln`.
   - Once CAS succeeds, line 681 retires `ln`:
     ```nim
     ready.retire(cast[pointer](ln), destroyLNodeCallback[K, V])
     ```
   - `destroyLNodeCallback` (lines 309-324) iterates through `ln.head` and executes:
     ```nim
     if curr.vbox != nil:
       destroyVBoxCallback[V](cast[pointer](curr.vbox))
     ```
   - **`VBox` is not reference counted**. Therefore, `curr.vbox` is destroyed and freed while `newLn` is still using it!
   - This exact same use-after-free and double-free occurs during `delete` on `mnkLNode` (lines 818-850) and during contraction from `LNode` to `SNode` (lines 833-845).
   - Furthermore, `newHead` allocated in line 824 is leaked when contracting to `SNode`.

---

### 2.4 ARC/ORC and Safe Memory Reclamation (Debra SMR)

#### Formal Invariant (Debra NEBR Protocol)
> *Every dereference of unmanaged node pointers (`INode`, `CNode`, `SNode`, `LNode`, `VBox`) MUST be protected within an active epoch pin. No pointer retired to the SMR limbo list may be physically freed until all threads observing that epoch have advanced.*

#### Analysis of `src/lockfree/ctrie.nim`:
1. **Mutator Pin Discipline**:
   - `put`, `delete`, and `clean` correctly acquire thread handles via `getOrRegisterHandle()` and enter epoch pins via `unpinned(th).pin()`. Displaced nodes are retired via `ready.retire()`.
2. **Catastrophic Defect Intercepted (CRIT-02)**:
   - `Snapshot.get(key)` (lines 923-966) contains **zero** Debra SMR pin calls.
   - `Snapshot.pairs` (lines 973-1003) contains **zero** Debra SMR pin calls.
   - `Ctrie.pairs` (lines 1025-1032) contains **zero** Debra SMR pin calls.
   - Any reader executing `snap.get(k)` or iterating across `snap.pairs` or `ctrie.pairs` traverses unmanaged `INode.main`, `CNode.children`, and `VBox` pointers completely unprotected. Concurrent writers modifying the active trie retire older nodes; Debra SMR reclaims them; the snapshot iterator dereferences freed memory, triggering use-after-free and memory corruption under concurrent read/write stress.
3. **Leaked Contracted Nodes (HIGH-01)**:
   - In `clean` (lines 506-535), when bottom-up contraction untombs a branch and replaces child `cur` with leaf `sn`:
   - `parent.main` is updated via CAS to `newPcn`.
   - `pcn` is retired via `ready.retire(pcn, destroyCNodeCallback)`.
   - **`cur` (the contracted `INode`) and its `TNode` are NEVER retired**. They are unlinked and abandoned in heap memory, causing unbounded memory leaks during deletion workloads.

---

### 2.5 Atomic Conditional Operations (`computeIfAbsent`)

#### Analysis of `src/lockfree/ctrie.nim`:
- Lines 872-885 implement `computeIfAbsent`:
  ```nim
  proc computeIfAbsent*[K, V; MaxThreads: static int](
      self: Ctrie[K, V, MaxThreads],
      key: K,
      computeFn: proc(k: K): V {.closure, gcsafe.}
  ): V =
    let existing = self.get(key)
    if existing.isSome:
      return existing.get
    let computed = computeFn(key)
    let prev = self.put(key, computed)
    if prev.isSome:
      return prev.get
    return computed
  ```
- **Defect Intercepted (HIGH-02)**:
  - `put` is an unconditional insert-or-overwrite operation.
  - If two threads $T_1$ and $T_2$ call `computeIfAbsent(key, fn)` concurrently:
    1. Both observe `existing.isNone`.
    2. $T_1$ computes $V_1 = fn(key)$; $T_2$ computes $V_2 = fn(key)$.
    3. $T_1$ calls `put(key, V_1)` $\to$ successfully inserts $V_1$.
    4. $T_2$ calls `put(key, V_2)` $\to$ **overwrites $V_1$ with $V_2$** in the trie!
    5. $T_2$ receives `prev = some(V_1)` and returns $V_1$.
    6. Both $T_1$ and $T_2$ return $V_1$, but the trie now holds $V_2$!
    7. Any subsequent call to `get(key)` returns $V_2$.
  - This violates atomic linearizability. A proper `putIfAbsent` primitive is required.

---

## 3. Comprehensive Defect Remediation Blueprint

### Remediation 1 (CRIT-01): Atomic Reference Counting on `VBox[V]`
Introduce an atomic reference count on `VBox[V]`. When an `SNode` or `LNodeEntry` shares a `VBox`, increment `rc`. When an entry is destroyed by SMR, decrement `rc` with release-acquire ordering; destroy `val` and free the box only when `rc` drops to 0.

```nim
type
  VBox*[V] = object
    rc*: Atomic[int]
    val*: V

proc newVBox[V](val: sink V): ptr VBox[V] {.inline.} =
  result = cast[ptr VBox[V]](allocShared0(sizeof(VBox[V])))
  result.rc.store(1, moRelaxed)
  wasMoved(result.val)
  result.val = val

proc incRef[V](box: ptr VBox[V]) {.inline.} =
  if box != nil:
    discard box.rc.fetchAdd(1, moRelaxed)

proc decRef[V](box: ptr VBox[V]) {.inline.} =
  if box != nil:
    if box.rc.fetchSub(1, moAcquireRelease) == 1:
      try:
        when not (V is SomeNumber or V is bool or V is char or V is pointer or V is ptr):
          `=destroy`(box.val)
      except:
        discard
      deallocShared(box)
```

### Remediation 2 (CRIT-02): Pin Protection for Snapshot Operations
Wrap `Snapshot.get` and `Snapshot.pairs` with Debra SMR pin guards:

```nim
proc get*[K, V; MaxThreads: static int](
    snap: Snapshot[K, V, MaxThreads],
    key: K
): Option[V] =
  if unlikely(snap.root == nil or snap.core == nil): return none(V)
  let th = Ctrie[K, V, MaxThreads](core: snap.core).getOrRegisterHandle()
  let pinned = unpinned(th).pin()
  try:
    # ... traversal ...
  finally:
    unpinGuard(pinned)
```

### Remediation 3 (HIGH-01): Clean Retires Contracted INodes and TNodes
In `clean`, upon successful CAS on `parent.main`, submit `cur` to `ready.retire`:

```nim
if parent.main.compareExchangeStrong(expPMain, cast[ptr MainNode[K, V]](newPcn), moAcquireRelease, moAcquire):
  if pcn.gen == parent.gen:
    ready.retire(cast[pointer](pcn), destroyCNodeCallback[K, V])
  # Clean up contracted INode and its TNode
  let curMain = cur.main.load(moRelaxed)
  if curMain != nil and curMain.kind == mnkTNode:
    ready.retire(cast[pointer](curMain), destroyTNodeCallback[K, V])
  ready.retire(cast[pointer](cur), destroyINodeCallback[K, V])
```

### Remediation 4 (HIGH-02): Dedicated `putIfAbsent` Primitive
Add an `onlyIfAbsent: bool` parameter to the internal mutation loop, or implement `putIfAbsent`:

```nim
proc putIfAbsent*[K, V; MaxThreads: static int](
    self: Ctrie[K, V, MaxThreads],
    key: K,
    val: V
): Option[V]
```
When `onlyIfAbsent` is true, discovering an existing matching key immediately aborts mutation and returns `some(sn.vbox.val)` without updating the leaf.

### Remediation 5 (MED-01): Pre-Shift Exhaustion Check in `createSubINode`
Move the level and hash equality check to the entrance of `createSubINode` before any bit shifts:

```nim
proc createSubINode[K, V](
    sn1, sn2: ptr SNode[K, V],
    level: int,
    gen: ptr Generation
): ptr INode[K, V] =
  let h1 = sn1.hash
  let h2 = sn2.hash
  if level >= MaxLevel or h1 == h2:
    # All 32 hash bits exhausted: construct immutable LNode
    incRef(sn1.vbox)
    incRef(sn2.vbox)
    let e1 = allocLNodeEntry(sn1.key, sn1.vbox, nil)
    let e2 = allocLNodeEntry(sn2.key, sn2.vbox, e1)
    let ln = allocLNode[K, V](h1, e2)
    return allocINode[K, V](cast[ptr MainNode[K, V]](ln), gen)

  let p1 = (h1 shr level) and 0x1F'u32
  let p2 = (h2 shr level) and 0x1F'u32
  # ... continue ...
```

---

## 4. Verification & Testing Matrix

| Test Suite / Metric | Command | Baseline Result | Expected Post-Remediation |
|:---|:---|:---|:---|
| **Ctrie Unit Suite** | `nim c -r tests/t_ctrie.nim` | 501/501 OK | All tests PASS with refcounted VBox |
| **Negative Controls** | `nim c -r tests/should_fail/runner.nim` | 23/23 PASS | 23/23 PASS |
| **Two-Key Integration Gate** | `vine gate --json` | Key 1 PASS, Key 2 PASS | Key 1 PASS, Key 2 PASS |
| **TSAN Concurrency Matrix** | `nim c --threads:on --mm:orc -d:tsan tests/t_ctrie.nim` | Clean | 0 Data Races |

---

## 5. Auditor Ratification & Recommendation

As Verification & Adversarial Auditor, I recommend:
1. **Immediate Ratification of Audit Report**: Commit `docs/reviews/review_ctrie_concurrency.md` to `main`.
2. **Staged Implementation of Remediations**: Assign the remediations for `CRIT-01`, `CRIT-02`, `HIGH-01`, `HIGH-02`, and `MED-01` to `implementer-kite` or apply under strict Two-Key Gate verification.
3. **Report to Supreme Orchestrator**: Transmit completion status on `task-ctrie-audit` and re-arm the single-shot Rhizo listener.

**Auditor Sign-off**:  
*Caleb Thorne (`auditor-pegasus`), Verification & Adversarial Auditor, 2026-10-08*
