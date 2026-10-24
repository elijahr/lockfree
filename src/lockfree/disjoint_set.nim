## ===========================================================================
## Concurrency Topology: Wait-Free / Lock-Free Concurrent Disjoint-Set
## (Union-Find / DSU — Anderson & Woll 1991 / Jayanti & Tarjan 2016)
## ===========================================================================
##
## A preallocated, zero-SMR, zero-hot-path-allocation concurrent Disjoint-Set
## (Union-Find / DSU) data structure for parallel graph connectivity, Kruskal
## minimum spanning trees, connected-component labeling, and concurrent
## dependency-graph cycle detection / subgraph partitioning.
##
## Key architectural properties:
## - **64-Bit Packed Slot Representation (`[rank: uint32 | parent: uint32]`)**:
##   Each element `i in 0 ..< size` occupies a single `Atomic[uint64]` word in a
##   contiguous 64-byte cache-line-aligned flat array (`slots`). Packing both the
##   32-bit upper-bound tree rank and the 32-bit parent index into one 64-bit
##   atomic word enables single-word `compareExchange` to atomically verify root
##   status (`parent == i`) and expected rank simultaneously.
## - **Wait-Free `find` with Atomic CAS Path Splitting / Halving**:
##   `find(x)` traverses parent pointers toward the set representative while
##   performing one-shot non-blocking atomic CAS path splitting (`parent(x) :=
##   parent(parent(x))`) that preserves `rank(x)`. Because parent pointers only
##   advance toward strictly higher-rank (or deterministically higher-index)
##   ancestors, the parent graph is a strict acyclic forest with height at most
##   `floor(log2(size)) + 1` and amortized `O(alpha(size))` step complexity.
## - **Lock-Free Rank-Based `union` with Deterministic Tie-Breaking**:
##   `union(x, y)` locates root representatives `u = find(x)` and `v = find(y)`.
##   If `u != v`, the lower-rank root is linked under the higher-rank root via
##   atomic CAS. When `rank(u) == rank(v)`, ties are broken deterministically by
##   element index (`min(u, v) -> max(u, v)`), making concurrent cycle formation
##   mathematically impossible without locks, followed by a best-effort atomic
##   rank increment on the winning root and an atomic decrement of `setCount`.
## - **Linearizable `sameSet(x, y)` (Anderson & Woll Root Re-Verification)**:
##   When `u = find(x)` and `v = find(y)` differ (`u != v`), `sameSet` re-reads
##   `slots[u]` to verify `u` was still a root after `find(y)` observed `v`. If
##   `u` was concurrently linked during `find(y)`, `sameSet` retries, ensuring
##   strict linearizability under concurrent `union` operations.
## - **Zero SMR / Zero Dynamic Node Reclamation**:
##   All slots live in a single flat array for the lifetime of the `DisjointSet`;
##   no epoch-based reclamation (NEBR/DEBRA) or hazard pointers are required.

import ./atomics
import ./atomics/backoff
import ./backoff
import ./internal/aligned_alloc

const
  CacheLine* = aligned_alloc.CacheLineBytes
  MaxDisjointSetSize* = int(int32.high)
    ## Maximum number of elements supported by 32-bit packed parent indices.

when defined(windows):
  proc c_aligned_malloc(size: csize_t, alignment: csize_t): pointer {.
    importc: "_aligned_malloc", header: "<malloc.h>".}
  proc c_aligned_free(memblock: pointer) {.
    importc: "_aligned_free", header: "<malloc.h>".}
else:
  proc posix_memalign(memptr: ptr pointer, alignment: csize_t, size: csize_t): cint {.
    importc, header: "<stdlib.h>".}
  from system/ansi_c import c_free

proc allocAlignedSlots(count: int): ptr UncheckedArray[Atomic[uint64]] =
  if count <= 0:
    return nil
  let byteCount = count * sizeof(Atomic[uint64])
  const align = CacheLineBytes
  when defined(windows):
    let p = c_aligned_malloc(csize_t(byteCount), csize_t(align))
    if p == nil:
      raise newException(OutOfMemDefect, "_aligned_malloc failed for DisjointSet slots")
    zeroMem(p, byteCount)
    result = cast[ptr UncheckedArray[Atomic[uint64]]](p)
  else:
    var p: pointer
    if posix_memalign(addr p, csize_t(align), csize_t(byteCount)) != 0:
      raise newException(OutOfMemDefect, "posix_memalign failed for DisjointSet slots")
    zeroMem(p, byteCount)
    result = cast[ptr UncheckedArray[Atomic[uint64]]](p)

proc freeAlignedSlots(p: pointer) {.inline.} =
  if p == nil:
    return
  when defined(windows):
    c_aligned_free(p)
  else:
    c_free(p)

# ---------------------------------------------------------------------------
# 64-Bit Packed Word Encoding: [rank: uint32 (high 32) | parent: uint32 (low 32)]
# ---------------------------------------------------------------------------

proc packRankParent*(rank: uint32, parent: uint32): uint64 {.inline.} =
  ## Packs a 32-bit tree rank and 32-bit parent index into a 64-bit atomic word.
  (uint64(rank) shl 32) or uint64(parent)

proc unpackRank*(word: uint64): uint32 {.inline.} =
  ## Extracts the 32-bit upper-bound tree rank from a packed 64-bit slot word.
  uint32(word shr 32)

proc unpackParent*(word: uint64): uint32 {.inline.} =
  ## Extracts the 32-bit parent index from a packed 64-bit slot word.
  uint32(word and 0xFFFF_FFFF'u64)

# ---------------------------------------------------------------------------
# Core Data Types & ARC/ORC Reference-Counted Lifecycle
# ---------------------------------------------------------------------------

type
  DisjointSetCore* = object
    setCount* {.align: CacheLineBytes.}: Atomic[int]
    rc* {.align: CacheLineBytes.}: Atomic[int]
    size*: int
    slots*: ptr UncheckedArray[Atomic[uint64]]

  DisjointSet* = object
    ## Wait-free / lock-free concurrent Disjoint-Set (Union-Find / DSU).
    ## Uses atomic reference counting on `core` so instances can be safely
    ## moved, copied, or shared across threads by value or pointer.
    core*: ptr DisjointSetCore

  UnionFind* = DisjointSet
    ## Alias for `DisjointSet`.

  ConcurrentDisjointSet* = DisjointSet
    ## Alias for `DisjointSet`.

proc destroyDisjointSetCore(core: ptr DisjointSetCore) {.gcsafe.} =
  if core == nil:
    return
  if core.slots != nil:
    freeAlignedSlots(cast[pointer](core.slots))
    core.slots = nil
  freeAligned(core)

proc `=destroy`*(self: var DisjointSet) {.raises: [].} =
  if self.core != nil:
    if self.core.rc.fetchSub(1, moAcquireRelease) == 1:
      destroyDisjointSetCore(self.core)

proc destroy*(self: var DisjointSet) {.inline.} =
  ## Explicitly releases a reference to the shared disjoint set core.
  `=destroy`(self)

proc `=copy`*(dest: var DisjointSet, src: DisjointSet) =
  if dest.core == src.core:
    return
  if src.core != nil:
    discard src.core.rc.fetchAdd(1, moRelaxed)
  if dest.core != nil:
    if dest.core.rc.fetchSub(1, moAcquireRelease) == 1:
      destroyDisjointSetCore(dest.core)
  dest.core = src.core

proc `=sink`*(dest: var DisjointSet, src: DisjointSet) =
  if dest.core != nil and dest.core != src.core:
    if dest.core.rc.fetchSub(1, moAcquireRelease) == 1:
      destroyDisjointSetCore(dest.core)
  dest.core = src.core

# ---------------------------------------------------------------------------
# Constructors & Initialization
# ---------------------------------------------------------------------------

proc initDisjointSet*(size: int): DisjointSet =
  ## Initializes a concurrent `DisjointSet` with `size` disjoint singleton sets
  ## (`0 ..< size`), where each element `i` starts with `parent = i` and `rank = 0`.
  ## Raises `ValueError` if `size < 0` or `size > MaxDisjointSetSize`.
  if size < 0 or size > MaxDisjointSetSize:
    raise newException(
      ValueError,
      "DisjointSet size must be in 0 .. " & $MaxDisjointSetSize & ", got " & $size
    )
  let core = allocAligned[DisjointSetCore]()
  core.size = size
  core.setCount.store(size, moRelaxed)
  core.rc.store(1, moRelaxed)
  if size > 0:
    let slots = allocAlignedSlots(size)
    for i in 0 ..< size:
      slots[i].store(packRankParent(0'u32, uint32(i)), moRelaxed)
    core.slots = slots
  else:
    core.slots = nil
  threadFence(moRelease)
  result.core = core

proc newDisjointSet*(size: int): DisjointSet {.inline.} =
  ## Alias for `initDisjointSet(size)`.
  initDisjointSet(size)

# ---------------------------------------------------------------------------
# Bounds Validation Helper
# ---------------------------------------------------------------------------

template checkElementBounds(core: ptr DisjointSetCore, x: int) =
  if unlikely(core == nil):
    raise newException(IndexDefect, "DisjointSet is uninitialized (nil core)")
  if unlikely(x < 0 or x >= core.size):
    raise newException(
      IndexDefect,
      "DisjointSet index " & $x & " out of bounds for size " & $core.size
    )

# ---------------------------------------------------------------------------
# Core Operations: find, union, sameSet, numSets
# ---------------------------------------------------------------------------

proc find*(self: DisjointSet, x: int): int {.gcsafe.} =
  ## Returns the canonical root representative of the set containing `x`.
  ##
  ## Performs wait-free / bounded-step atomic CAS path splitting / halving
  ## during traversal: for each non-root node `cur` with parent `p` and
  ## grandparent `gp != p`, attempts a single non-blocking CAS to swing
  ## `parent(cur)` directly to `gp` while preserving `rank(cur)`, then advances
  ## `cur = gp`.
  let core = self.core
  checkElementBounds(core, x)
  let slots = core.slots
  var cur = x
  while true:
    let wordCur = slots[cur].load(moAcquire)
    let p = int(unpackParent(wordCur))
    if p == cur:
      return cur
    let wordP = slots[p].load(moAcquire)
    let gp = int(unpackParent(wordP))
    if gp != p:
      var expected = wordCur
      let desired = packRankParent(unpackRank(wordCur), uint32(gp))
      discard slots[cur].compareExchangeWeak(
        expected, desired, moRelease, moRelaxed
      )
    cur = gp

proc findNoCompress*(self: DisjointSet, x: int): int {.gcsafe.} =
  ## Returns the canonical root representative of the set containing `x`
  ## using pure read-only atomic loads without mutating parent pointers.
  let core = self.core
  checkElementBounds(core, x)
  let slots = core.slots
  var cur = x
  while true:
    let wordCur = slots[cur].load(moAcquire)
    let p = int(unpackParent(wordCur))
    if p == cur:
      return cur
    cur = p

proc tryUnion*(self: DisjointSet, x, y: int, outRoot: var int): bool {.gcsafe.} =
  ## Atomically merges the set containing `x` and the set containing `y` using
  ## rank-based linking with deterministic index tie-breaking (Anderson-Woll /
  ## Jayanti-Tarjan).
  ##
  ## Sets `outRoot` to the canonical representative of the unified set.
  ## Returns `true` if `x` and `y` belonged to distinct sets and were merged by
  ## this call, or `false` if they were already in the same set.
  let core = self.core
  checkElementBounds(core, x)
  checkElementBounds(core, y)
  let slots = core.slots

  var spins = InitialSpin
  while true:
    let u = self.find(x)
    let v = self.find(y)

    let wordU = slots[u].load(moAcquire)
    let wordV = slots[v].load(moAcquire)

    # Verify both `u` and `v` are still roots at the time their words were read.
    if int(unpackParent(wordU)) != u or int(unpackParent(wordV)) != v:
      backoffOnRetry(spins)
      continue

    if u == v:
      outRoot = u
      return false

    let rankU = unpackRank(wordU)
    let rankV = unpackRank(wordV)

    # Link lower-rank root under higher-rank root.
    # When ranks are equal, break ties deterministically by index (`min -> max`)
    # so concurrent equal-rank unions can never form a cycle.
    var child: int
    var root: int
    var wordChild: uint64
    var wordRoot: uint64
    var rankChild: uint32
    var rankRoot: uint32

    if rankU < rankV or (rankU == rankV and u < v):
      child = u
      root = v
      wordChild = wordU
      wordRoot = wordV
      rankChild = rankU
      rankRoot = rankV
    else:
      child = v
      root = u
      wordChild = wordV
      wordRoot = wordU
      rankChild = rankV
      rankRoot = rankU

    var expectedChild = wordChild
    let desiredChild = packRankParent(rankChild, uint32(root))
    if slots[child].compareExchange(
      expectedChild, desiredChild, moAcquireRelease, moAcquire
    ):
      if rankChild == rankRoot:
        # Best-effort CAS to bump the winning root's rank by 1 while it remains
        # a root at `rankRoot`. If another thread already bumped its rank or
        # linked it under an even higher root, the CAS harmlessly fails.
        var expectedRoot = wordRoot
        let desiredRoot = packRankParent(rankRoot + 1'u32, uint32(root))
        discard slots[root].compareExchange(
          expectedRoot, desiredRoot, moAcquireRelease, moRelaxed
        )
      discard core.setCount.fetchSub(1, moAcquireRelease)
      outRoot = root
      return true

    backoffOnRetry(spins)

proc union*(self: DisjointSet, x, y: int): bool {.discardable, inline, gcsafe.} =
  ## Atomically merges the set containing `x` and the set containing `y`.
  ## Returns `true` if two distinct sets were merged, or `false` if `x` and `y`
  ## were already in the same set (useful for concurrent cycle detection).
  var mergedRoot = 0
  self.tryUnion(x, y, mergedRoot)

proc sameSet*(self: DisjointSet, x, y: int): bool {.gcsafe.} =
  ## Linearizable query returning `true` iff `x` and `y` belong to the same set.
  ##
  ## Uses Anderson & Woll's root re-verification protocol: when `u = find(x)`
  ## and `v = find(y)` differ, verifies that `u` is still a root after `find(y)`
  ## completes so concurrent unions cannot cause false negatives.
  let core = self.core
  checkElementBounds(core, x)
  checkElementBounds(core, y)
  if x == y:
    return true
  let slots = core.slots
  while true:
    let u = self.find(x)
    let v = self.find(y)
    if u == v:
      return true
    let wordU = slots[u].load(moAcquire)
    if int(unpackParent(wordU)) == u:
      return false
    cpuPause()

proc connected*(self: DisjointSet, x, y: int): bool {.inline, gcsafe.} =
  ## Alias for `sameSet(x, y)`.
  self.sameSet(x, y)

proc numSets*(self: DisjointSet): int {.inline, gcsafe.} =
  ## Returns the current number of disjoint sets in `self`.
  if self.core == nil:
    return 0
  self.core.setCount.load(moAcquire)

proc len*(self: DisjointSet): int {.inline, gcsafe.} =
  ## Returns the total number of elements managed by `self`.
  if self.core == nil:
    return 0
  self.core.size

proc size*(self: DisjointSet): int {.inline, gcsafe.} =
  ## Alias for `len(self)`.
  self.len()

proc rank*(self: DisjointSet, x: int): uint32 {.inline, gcsafe.} =
  ## Returns the current upper-bound rank stored in slot `x`.
  let core = self.core
  checkElementBounds(core, x)
  unpackRank(core.slots[x].load(moAcquire))

proc isRoot*(self: DisjointSet, x: int): bool {.inline, gcsafe.} =
  ## Returns `true` iff `x` is currently the canonical root of its set.
  let core = self.core
  checkElementBounds(core, x)
  int(unpackParent(core.slots[x].load(moAcquire))) == x

proc clear*(self: DisjointSet) {.gcsafe.} =
  ## Resets all elements `0 ..< len` back to singleton sets (`parent = i`,
  ## `rank = 0`) and restores `numSets` to `len`.
  if self.core == nil:
    return
  let core = self.core
  let n = core.size
  for i in 0 ..< n:
    core.slots[i].store(packRankParent(0'u32, uint32(i)), moRelaxed)
  core.setCount.store(n, moRelease)

# ---------------------------------------------------------------------------
# Pointer Receiver Convenience Overloads (`ptr DisjointSet`)
# ---------------------------------------------------------------------------

proc find*(self: ptr DisjointSet, x: int): int {.inline, gcsafe.} =
  self[].find(x)

proc findNoCompress*(self: ptr DisjointSet, x: int): int {.inline, gcsafe.} =
  self[].findNoCompress(x)

proc tryUnion*(self: ptr DisjointSet, x, y: int, outRoot: var int): bool {.inline, gcsafe.} =
  self[].tryUnion(x, y, outRoot)

proc union*(self: ptr DisjointSet, x, y: int): bool {.discardable, inline, gcsafe.} =
  self[].union(x, y)

proc sameSet*(self: ptr DisjointSet, x, y: int): bool {.inline, gcsafe.} =
  self[].sameSet(x, y)

proc connected*(self: ptr DisjointSet, x, y: int): bool {.inline, gcsafe.} =
  self[].connected(x, y)

proc numSets*(self: ptr DisjointSet): int {.inline, gcsafe.} =
  self[].numSets()

proc len*(self: ptr DisjointSet): int {.inline, gcsafe.} =
  self[].len()

proc size*(self: ptr DisjointSet): int {.inline, gcsafe.} =
  self[].size()

proc rank*(self: ptr DisjointSet, x: int): uint32 {.inline, gcsafe.} =
  self[].rank(x)

proc isRoot*(self: ptr DisjointSet, x: int): bool {.inline, gcsafe.} =
  self[].isRoot(x)

proc clear*(self: ptr DisjointSet) {.inline, gcsafe.} =
  self[].clear()
