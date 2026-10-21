# Concurrent Disjoint-Set (`DisjointSet` / `UnionFind`)

`lockfree/disjoint_set` provides an allocation-free, lock-free (with wait-free find) Concurrent Disjoint-Set Union (DSU / Union-Find) data structure. It is designed for high-concurrency graph algorithms (such as Borůvka's or Kruskal's minimum spanning tree), connected-component labeling, percolation simulations, and parallel equivalence partitioning (e.g. CDCL SAT solvers and type inference engines).

---

## 1. Algorithmic Principles & Concurrency Guarantees

Classical disjoint-set structures use union-by-rank and path compression, which can mutate pointers along search paths during find operations. Under concurrent multithreaded access, standard two-pass path compression introduces data races and cyclic parent pointers.

`DisjointSet` employs the lock-free algorithm based on **Jayanti & Tarjan** and **Anderson & Woll**:

1. **Packed 64-Bit Atomic Words**: Each element occupies a single 64-bit atomic word combining `rank: uint32` (high 32 bits) and `parent: uint32` (low 32 bits).
   ```
   [ 32-bit rank | 32-bit parent index ]
   ```
   This allows an atomic Compare-And-Swap (CAS) to update parentage and rank simultaneously without multi-word synchronization.

2. **Wait-Free Path Splitting (`find`)**: Rather than two-pass full path compression, `find` executes one-pass *path splitting*: every traversed node has its parent pointer swung directly to its grandparent using a single atomic CAS:
   ```nim
   let grandParent = ...
   discard node.compareExchange(oldEntry, pack(rank, grandParent), moAcquireRelease, moAcquire)
   ```
   This guarantees that find operations are wait-free and paths monotonically decrease in length even when CAS fails due to concurrent modifications.

3. **Rank-Based Union (`union`)**: When uniting sets $X$ and $Y$, both roots $r_x$ and $r_y$ are determined. The root with lower rank is attached as a child to the higher-rank root. If both roots possess identical rank, one root attempts a CAS to increment its rank before linking.

4. **Anderson-Woll Verification (`sameSet`)**: In concurrent executions, roots may be concurrently updated while `sameSet(x, y)` checks equivalence. `sameSet` performs stable root re-verification, guaranteeing linearizable equality checks.

---

## 2. API & Usage

### Basic Usage

```nim
import lockfree

# Initialize a DisjointSet with 1,000 elements (indices 0..999)
var ds = initDisjointSet(1000)

# Verify initial singleton sets
assert ds.find(10) == 10
assert not ds.sameSet(10, 20)
assert ds.setsCount == 1000

# Union elements
let merged = ds.union(10, 20)
assert merged == true
assert ds.sameSet(10, 20)
assert ds.setsCount == 999

# Union additional elements transitively
ds.union(20, 30)
assert ds.sameSet(10, 30)
assert ds.find(10) == ds.find(30)
```

### Multithreaded Parallel Connected Components

```nim
import lockfree

var dsu = initDisjointSet(100_000)

# Multiple worker threads concurrently process edges:
proc worker(threadId: int) {.thread.} =
  for edge in getThreadEdges(threadId):
    dsu.union(edge.u, edge.v)

# Check component connectivity from any thread:
if dsu.sameSet(nodeA, nodeB):
  echo "Nodes belong to the same component"
```

---

## 3. Constructors: `init*` vs `new*`

Following the Nim standard library idioms:
- `initDisjointSet(count: int)`: Value constructor allocating internal backing array.
- `newDisjointSet(count: int)`: Convenience constructor returning a value object (identical to `initDisjointSet`).
- `UnionFind`: Type alias for `DisjointSet`.

---

## 4. Complexity & Performance

| Operation | Concurrent Progress Guarantee | Time Complexity | Allocations |
| :--- | :--- | :--- | :--- |
| `find(x)` | Wait-Free | $O(\alpha(N))$ amortized | 0 |
| `union(x, y)` | Lock-Free | $O(\alpha(N))$ amortized | 0 |
| `sameSet(x, y)` | Wait-Free | $O(\alpha(N))$ amortized | 0 |
| `setsCount` | Wait-Free | $O(1)$ | 0 |
| `reset()` | Single-Threaded | $O(N)$ | 0 |
