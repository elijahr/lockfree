## # Concurrency Topology: MPMC Lock-Free Concurrent Hash Trie with O(1) Wait-Free Snapshots (`Ctrie[K, V]`)
##
## | Dimension              | Architectural Specification                                             |
## |:-----------------------|:------------------------------------------------------------------------|
## | **Topologies**         | MPMC (Multi-Producer Multi-Consumer Concurrent Associative Map)          |
## | **Algorithm**          | Aleksandar Prokopec Concurrent Hash Trie (Ctrie) with HAMT 32-way Branch |
## | **Snapshots**          | O(1) Time, O(1) Work Wait-Free Point-in-Time Generational Snapshots       |
## | **Tree Depth**         | Maximum 7 levels for 32-bit hashes, 13 levels for 64-bit hashes (5 bits)  |
## | **Key Ordering**       | Hash-partitioned HAMT (unordered key space; sorted iteration via snap)   |
## | **Coordination**       | Atomic MainNode pointers on INodes, CAS compression and GCopy           |
## | **Payload Storage**    | Type-agnostic pointer-indirection box (`VBox[V]`) under ARC/ORC          |
## | **Collision Strategy** | Immutable persistent collision lists (`LNode[K, V]`)                     |
## | **Progress Guarantees**| Lookups: Wait-Free Population; Mutations: Lock-Free; Snapshots: Wait-Free |
## | **SMR Substrate**      | In-tree Debra SMR (NEBR, `src/lockfree/smr/nebr/`, `MaxThreads` capacity) |
## | **Cache Alignment**    | INode and Root pointers aligned to `CacheLineBytes` (64/128-byte boundary)|
##
## ## Overview
##
## `Ctrie[K, V]` is an MPMC lock-free concurrent hash array mapped trie (HAMT)
## implementing Aleksandar Prokopec's Ctrie algorithm with generational
## stamping, non-blocking lazy copy-on-write (`GCopy`), bottom-up tombstone
## contraction, and in-tree Debra Safe Memory Reclamation (SMR).
##
## Key capabilities:
## - **O(1) Wait-Free Snapshots**: `snapshot()` creates an isolated
##   point-in-time read-only view in O(1) time and work by atomically swinging
##   the root to a new generation.
## - **Wait-Free Lookups**: `get`, `contains`, `[]` traverse at most 7 levels
##   without CAS.
## - **Lock-Free Mutations**: `put`, `delete`, `computeIfAbsent` use per-node
##   CAS and lazy generational expansion without global locks.
## - **Memory Reclaiming**: Nodes and displaced values are safely
##   deferred-reclaimed via Debra SMR.

when not compileOption("threads"):
  {.error: "lockfree/ctrie requires --threads:on".}

import std/[options, hashes, bitops]
import pkg/typestates
import ./atomics
import ./smr/nebr
import ./internal/aligned_alloc

const
  DefaultMaxThreads* = 64
  TagMask: uint = 1'u
  TagINode: uint = 0'u
  TagSNode: uint = 1'u
  MaxLevel = 30 # 32-bit hash: 0, 5, 10, 15, 20, 25, 30

template countBits32(x: uint32): int =
  countSetBits(x)

# ---------------------------------------------------------------------------
# Murmur3 Hash Finalizer
# ---------------------------------------------------------------------------

proc getHash*[K](key: K): uint32 {.inline.} =
  let h = hash(key)
  var x = uint32(cast[uint](h) and 0xFFFFFFFF'u)
  x = x xor (x shr 16)
  x = x * 0x85ebca6b'u32
  x = x xor (x shr 13)
  x = x * 0xc2b2ae35'u32
  x = x xor (x shr 16)
  return x

# ---------------------------------------------------------------------------
# Monotonic IDs & Generations
# ---------------------------------------------------------------------------

var gNextCtrieId {.global.}: Atomic[uint64]
var gNextGenId {.global.}: Atomic[uint64]

proc allocCtrieId(): uint64 =
  gNextCtrieId.fetchAdd(1, moRelaxed) + 1

proc allocGenId(): uint64 =
  gNextGenId.fetchAdd(1, moRelaxed) + 1

type
  Generation* = object
    id*: uint64
    rc*: Atomic[int]

proc allocGeneration(): ptr Generation {.inline.} =
  result = cast[ptr Generation](allocShared0(sizeof(Generation)))
  result.id = allocGenId()
  result.rc.store(1, moRelaxed)

proc incRef(gen: ptr Generation) {.inline.} =
  if gen != nil:
    discard gen.rc.fetchAdd(1, moRelaxed)

proc decRef(gen: ptr Generation) {.inline.} =
  if gen != nil:
    if gen.rc.fetchSub(1, moAcquireRelease) == 1:
      deallocShared(gen)

# ---------------------------------------------------------------------------
# SMR Typestate Conversion Helpers
# ---------------------------------------------------------------------------

proc toPinned[MaxThreads: static int, CC: static PinScopeCardinality](
    ready: RetireReady[MaxThreads, CC]
): Pinned[MaxThreads, CC] {.inline, notATransition.} =
  let ctx = RetireContext[MaxThreads, CC](ready)
  Pinned[MaxThreads, CC](EpochGuardContext[MaxThreads, CC](handle: ctx.handle, epoch: ctx.epoch))

template unpinGuard[MaxThreads: static int, CC: static PinScopeCardinality](
    p: Pinned[MaxThreads, CC]
) =
  var res = p.unpin()
  match res:
    Unpinned(u):
      discard u.close()
    Neutralized(n):
      discard n.acknowledge().close()

# ---------------------------------------------------------------------------
# Node Hierarchy & Representation
# ---------------------------------------------------------------------------

type
  VBox*[V] = object
    rc*: Atomic[int]
    val*: V

  MainNodeKind* = enum
    mnkCNode  ## Compressed Hash Array Node
    mnkTNode  ## Tomb Node (Contracted singleton)
    mnkLNode  ## Collision List Node

  MainNode*[K, V] = object
    kind*: MainNodeKind

  BranchNode*[K, V] = distinct uint

  SNode*[K, V] = object
    key*: K
    vbox*: ptr VBox[V]
    hash*: uint32

  CNode*[K, V] = object
    kind*: MainNodeKind
    bmp*: uint32
    gen*: ptr Generation
    csize*: int
    children*: UncheckedArray[BranchNode[K, V]]

  TNode*[K, V] = object
    kind*: MainNodeKind
    snode*: ptr SNode[K, V]

  LNodeEntry*[K, V] = object
    key*: K
    vbox*: ptr VBox[V]
    next*: ptr LNodeEntry[K, V]

  LNode*[K, V] = object
    kind*: MainNodeKind
    hash*: uint32
    head*: ptr LNodeEntry[K, V]

  INode*[K, V] = object
    main*: Atomic[ptr MainNode[K, V]]
    gen*: ptr Generation
    rc*: Atomic[int]

  CtrieCore*[K, V; MaxThreads: static int] = object
    id*: uint64
    root*: Atomic[ptr INode[K, V]]
    manager*: ptr DebraManager[MaxThreads, ccMulti]
    count*: Atomic[int]
    rc*: Atomic[int]
    ownsManager*: bool

  Ctrie*[K, V; MaxThreads: static int = DefaultMaxThreads] = object
    ## # Concurrency Topology: MPMC (Multi-Producer Multi-Consumer)
    ## Aleksandar Prokopec Lock-Free Concurrent Hash Array Mapped Trie with O(1)
    ## Snapshots.
    core*: ptr CtrieCore[K, V, MaxThreads]

  Table*[K, V; MaxThreads: static int = DefaultMaxThreads] = Ctrie[K, V, MaxThreads]
  ## # Concurrency Topology: Table (MPMC Ergonomic Alias)
  ## Ergonomic MPMC alias for `Ctrie[K, V, MaxThreads]`.

  ConcurrentTable*[K, V; MaxThreads: static int = DefaultMaxThreads] = Ctrie[K, V, MaxThreads]
  ## # Concurrency Topology: ConcurrentTable (MPMC Ergonomic Alias)
  ## Ergonomic MPMC alias for `Ctrie[K, V, MaxThreads]`.

  ConcurrentMap*[K, V; MaxThreads: static int = DefaultMaxThreads] = Ctrie[K, V, MaxThreads]
  ## # Concurrency Topology: ConcurrentMap (MPMC Ergonomic Alias)
  ## Ergonomic MPMC alias for `Ctrie[K, V, MaxThreads]`.

  ConcurrentTrie*[K, V; MaxThreads: static int = DefaultMaxThreads] = Ctrie[K, V, MaxThreads]
  ## # Concurrency Topology: ConcurrentTrie (MPMC Ergonomic Alias)
  ## Ergonomic MPMC alias for `Ctrie[K, V, MaxThreads]`.

  Snapshot*[K, V; MaxThreads: static int = DefaultMaxThreads] = object
    ## # Concurrency Topology: Snapshot (O(1) Wait-Free Point-in-Time Generation)
    ## Thread-safe, wait-free immutable view of a Ctrie generation.
    core*: ptr CtrieCore[K, V, MaxThreads]
    root*: ptr INode[K, V]

template isSNode*[K, V](b: BranchNode[K, V]): bool =
  (uint(b) and TagMask) == TagSNode

template isINode*[K, V](b: BranchNode[K, V]): bool =
  (uint(b) and TagMask) == TagINode

template toSNode*[K, V](b: BranchNode[K, V]): ptr SNode[K, V] =
  cast[ptr SNode[K, V]](uint(b) and (not TagMask))

template toINode*[K, V](b: BranchNode[K, V]): ptr INode[K, V] =
  cast[ptr INode[K, V]](uint(b) and (not TagMask))

template makeBranchNode*[K, V](p: ptr SNode[K, V]): BranchNode[K, V] =
  BranchNode[K, V](cast[uint](p) or TagSNode)

template makeBranchNode*[K, V](p: ptr INode[K, V]): BranchNode[K, V] =
  BranchNode[K, V](cast[uint](p) or TagINode)

# ---------------------------------------------------------------------------
# Memory Management & Allocators
# ---------------------------------------------------------------------------

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

proc freeVBox[V](box: ptr VBox[V]) {.inline, gcsafe.} =
  decRef(box)

proc destroyVBoxCallback[V](p: pointer) {.nimcall, raises: [].} =
  let box = cast[ptr VBox[V]](p)
  decRef(box)

proc allocSNode[K, V](key: sink K, val: sink V, h: uint32): ptr SNode[K, V] {.inline.} =
  result = cast[ptr SNode[K, V]](allocShared0(sizeof(SNode[K, V])))
  wasMoved(result.key)
  result.key = key
  result.vbox = newVBox(val)
  result.hash = h

proc allocSNodeWithVBox[K, V](key: sink K, vbox: ptr VBox[V], h: uint32): ptr SNode[K, V] {.inline.} =
  result = cast[ptr SNode[K, V]](allocShared0(sizeof(SNode[K, V])))
  wasMoved(result.key)
  result.key = key
  result.vbox = vbox
  result.hash = h

proc destroySNodeCallback[K, V](p: pointer) {.nimcall, raises: [].} =
  let sn = cast[ptr SNode[K, V]](p)
  if sn != nil:
    if sn.vbox != nil:
      decRef(sn.vbox)
    try:
      when not (K is SomeNumber or K is bool or K is char or K is pointer or K is ptr):
        `=destroy`(sn.key)
    except:
      discard
    deallocShared(sn)

proc allocCNode[K, V](bmp: uint32, gen: ptr Generation, csize: int): ptr CNode[K, V] {.inline.} =
  let totalBytes = sizeof(CNode[K, V]) + sizeof(BranchNode[K, V]) * csize
  result = cast[ptr CNode[K, V]](allocShared0(totalBytes))
  result.kind = mnkCNode
  result.bmp = bmp
  result.gen = gen
  result.csize = csize
  incRef(gen)

proc destroyCNodeCallback[K, V](p: pointer) {.nimcall, raises: [].} =
  let cn = cast[ptr CNode[K, V]](p)
  if cn != nil:
    decRef(cn.gen)
    deallocShared(cn)

proc allocTNode[K, V](sn: ptr SNode[K, V]): ptr TNode[K, V] {.inline.} =
  result = cast[ptr TNode[K, V]](allocShared0(sizeof(TNode[K, V])))
  result.kind = mnkTNode
  result.snode = sn

proc destroyTNodeCallback[K, V](p: pointer) {.nimcall, raises: [].} =
  let tn = cast[ptr TNode[K, V]](p)
  if tn != nil:
    deallocShared(tn)

proc allocLNodeEntry[K, V](key: sink K, vbox: ptr VBox[V], next: ptr LNodeEntry[K, V]): ptr LNodeEntry[K, V] {.inline.} =
  result = cast[ptr LNodeEntry[K, V]](allocShared0(sizeof(LNodeEntry[K, V])))
  wasMoved(result.key)
  result.key = key
  result.vbox = vbox
  result.next = next

proc allocLNode[K, V](h: uint32, head: ptr LNodeEntry[K, V]): ptr LNode[K, V] {.inline.} =
  result = cast[ptr LNode[K, V]](allocShared0(sizeof(LNode[K, V])))
  result.kind = mnkLNode
  result.hash = h
  result.head = head

proc destroyLNodeCallback[K, V](p: pointer) {.nimcall, raises: [].} =
  let ln = cast[ptr LNode[K, V]](p)
  if ln != nil:
    var curr = ln.head
    while curr != nil:
      let nxt = curr.next
      if curr.vbox != nil:
        decRef(curr.vbox)
      try:
        when not (K is SomeNumber or K is bool or K is char or K is pointer or K is ptr):
          `=destroy`(curr.key)
      except:
        discard
      deallocShared(curr)
      curr = nxt
    deallocShared(ln)

proc allocINode[K, V](main: ptr MainNode[K, V], gen: ptr Generation): ptr INode[K, V] {.inline.} =
  result = allocAligned[INode[K, V]]()
  result.main.store(main, moRelaxed)
  result.gen = gen
  result.rc.store(1, moRelaxed)
  incRef(gen)

proc incRef[K, V](inode: ptr INode[K, V]) {.inline.} =
  if inode != nil:
    discard inode.rc.fetchAdd(1, moRelaxed)

proc decRef[K, V](inode: ptr INode[K, V]): bool {.inline.} =
  if inode != nil:
    result = inode.rc.fetchSub(1, moAcquireRelease) == 1
  else:
    result = false

proc destroyINodeCallback[K, V](p: pointer) {.nimcall, raises: [].} =
  let inode = cast[ptr INode[K, V]](p)
  if inode != nil:
    decRef(inode.gen)
    freeAligned(inode)

# ---------------------------------------------------------------------------
# Thread Handle TLS Auto-Registration
# ---------------------------------------------------------------------------

type
  TlsHandleEntry = object
    trieId: uint64
    handleIdx: int

const MaxCachedTlsHandles = 32
var gCtrieTlsHandles {.threadvar.}: seq[TlsHandleEntry]

proc getOrRegisterHandleCore[MaxThreads: static int](
    trieId: uint64,
    manager: ptr DebraManager[MaxThreads, ccMulti]
): ThreadHandle[MaxThreads, ccMulti] {.inline.} =
  for entry in gCtrieTlsHandles:
    if entry.trieId == trieId:
      return ThreadHandle[MaxThreads, ccMulti](idx: entry.handleIdx, manager: manager)
  let h = registerThread(manager[])
  if gCtrieTlsHandles.len >= MaxCachedTlsHandles:
    gCtrieTlsHandles.delete(0)
  gCtrieTlsHandles.add(TlsHandleEntry(trieId: trieId, handleIdx: h.idx))
  return h

proc getOrRegisterHandle*[K, V; MaxThreads: static int](
    self: Ctrie[K, V, MaxThreads]
): ThreadHandle[MaxThreads, ccMulti] {.inline.} =
  getOrRegisterHandleCore[MaxThreads](self.core.id, self.core.manager)

proc getOrRegisterHandle*[K, V; MaxThreads: static int](
    snap: Snapshot[K, V, MaxThreads]
): ThreadHandle[MaxThreads, ccMulti] {.inline.} =
  getOrRegisterHandleCore[MaxThreads](snap.core.id, snap.core.manager)

# ---------------------------------------------------------------------------
# Sub-INode / Branch Generation Helper
# ---------------------------------------------------------------------------

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
  if p1 != p2:
    let bmp = (1'u32 shl p1) or (1'u32 shl p2)
    let cn = allocCNode[K, V](bmp, gen, 2)
    if p1 < p2:
      cn.children[0] = makeBranchNode(sn1)
      cn.children[1] = makeBranchNode(sn2)
    else:
      cn.children[0] = makeBranchNode(sn2)
      cn.children[1] = makeBranchNode(sn1)
    return allocINode[K, V](cast[ptr MainNode[K, V]](cn), gen)
  else:
    # Recurse down to next level
    let nextSub = createSubINode(sn1, sn2, level + 5, gen)
    let bmp = 1'u32 shl p1
    let cn = allocCNode[K, V](bmp, gen, 1)
    cn.children[0] = makeBranchNode(nextSub)
    return allocINode[K, V](cast[ptr MainNode[K, V]](cn), gen)

proc isLNodeSubtree[K, V](inode: ptr INode[K, V]): bool {.inline.} =
  if inode == nil: return false
  var cur = inode
  while true:
    let m = cur.main.load(moRelaxed)
    if m == nil: return false
    case m.kind
    of mnkLNode: return true
    of mnkCNode:
      let cn = cast[ptr CNode[K, V]](m)
      if cn.csize == 1 and cn.children[0].isINode:
        cur = cn.children[0].toINode
      else:
        return false
    else: return false

proc freeUnlinkedSubTree[K, V](inode: ptr INode[K, V]) =
  if inode == nil: return
  let m = inode.main.load(moRelaxed)
  if m != nil:
    case m.kind
    of mnkCNode:
      let cn = cast[ptr CNode[K, V]](m)
      for i in 0 ..< cn.csize:
        if cn.children[i].isINode:
          freeUnlinkedSubTree[K, V](cn.children[i].toINode)
      decRef(cn.gen)
      deallocShared(cn)
    of mnkLNode:
      destroyLNodeCallback[K, V](cast[pointer](m))
    of mnkTNode:
      destroyTNodeCallback[K, V](cast[pointer](m))
  decRef(inode.gen)
  freeAligned(inode)

# ---------------------------------------------------------------------------
# Lazy Generational Copy (GCopy)
# ---------------------------------------------------------------------------

proc freeUnlinkedCNode[K, V](cn: ptr CNode[K, V], targetGen: ptr Generation) =
  if cn != nil:
    for i in 0 ..< cn.csize:
      let child = cn.children[i]
      if child.isINode:
        let inode = child.toINode
        if inode.gen == targetGen:
          destroyINodeCallback[K, V](cast[pointer](inode))
    decRef(cn.gen)
    deallocShared(cn)

proc gcopy[K, V](cnode: ptr CNode[K, V], targetGen: ptr Generation): ptr CNode[K, V] {.inline.} =
  let sz = cnode.csize
  result = allocCNode[K, V](cnode.bmp, targetGen, sz)
  for i in 0 ..< sz:
    let child = cnode.children[i]
    if child.isINode:
      let oldInode = child.toINode
      if oldInode.gen != targetGen:
        let freshInode = allocINode[K, V](oldInode.main.load(moAcquire), targetGen)
        result.children[i] = makeBranchNode(freshInode)
      else:
        result.children[i] = child
    else:
      result.children[i] = child

# ---------------------------------------------------------------------------
# Core Operations: Lookup, Insert, Delete, Contraction
# ---------------------------------------------------------------------------

proc get*[K, V; MaxThreads: static int](
    self: Ctrie[K, V, MaxThreads],
    key: K
): Option[V] =
  ## Retrieves the value mapped to `key`, or `none(V)` if absent. Wait-free.
  if unlikely(self.core == nil): return none(V)
  let h = getHash(key)
  let th = self.getOrRegisterHandle()
  let pinned = unpinned(th).pin()
  try:
    var cur = self.core.root.load(moAcquire)
    var level = 0
    while true:
      let main = cur.main.load(moAcquire)
      if unlikely(main == nil): return none(V)
      case main.kind
      of mnkCNode:
        let cn = cast[ptr CNode[K, V]](main)
        let pos = (h shr level) and 0x1F'u32
        let flag = 1'u32 shl pos
        if (cn.bmp and flag) == 0:
          return none(V)
        let idx = countBits32(cn.bmp and (flag - 1'u32))
        let child = cn.children[idx]
        if child.isSNode:
          let sn = child.toSNode
          if sn.hash == h and sn.key == key:
            return some(sn.vbox.val)
          return none(V)
        else:
          cur = child.toINode
          level += 5
      of mnkLNode:
        let ln = cast[ptr LNode[K, V]](main)
        if ln.hash != h: return none(V)
        var curr = ln.head
        while curr != nil:
          if curr.key == key:
            return some(curr.vbox.val)
          curr = curr.next
        return none(V)
      of mnkTNode:
        let tn = cast[ptr TNode[K, V]](main)
        if tn.snode != nil and tn.snode.hash == h and tn.snode.key == key:
          return some(tn.snode.vbox.val)
        return none(V)
  finally:
    unpinGuard(pinned)

proc contains*[K, V; MaxThreads: static int](
    self: Ctrie[K, V, MaxThreads],
    key: K
): bool {.inline.} =
  self.get(key).isSome

proc hasKey*[K, V; MaxThreads: static int](
    self: Ctrie[K, V, MaxThreads],
    key: K
): bool {.inline.} =
  self.contains(key)

proc `[]`*[K, V; MaxThreads: static int](
    self: Ctrie[K, V, MaxThreads],
    key: K
): V {.inline.} =
  let res = self.get(key)
  if res.isSome:
    return res.get
  raise newException(KeyError, "key not found")

proc clean[K, V; MaxThreads: static int](
    self: Ctrie[K, V, MaxThreads],
    parent: ptr INode[K, V],
    cur: ptr INode[K, V],
    sn: ptr SNode[K, V],
    ready: var RetireReady[MaxThreads, ccMulti]
) {.notATransition.} =
  if parent == nil: return
  let pMain = parent.main.load(moAcquire)
  if pMain != nil and pMain.kind == mnkCNode:
    let pcn = cast[ptr CNode[K, V]](pMain)
    var idx = -1
    for i in 0 ..< pcn.csize:
      if pcn.children[i].isINode and pcn.children[i].toINode == cur:
        idx = i
        break
    if idx >= 0:
      let newPcn = allocCNode[K, V](pcn.bmp, parent.gen, pcn.csize)
      for i in 0 ..< pcn.csize:
        if i == idx:
          newPcn.children[i] = makeBranchNode(sn)
        else:
          newPcn.children[i] = pcn.children[i]
      var expPMain = pMain
      if parent.main.compareExchangeStrong(expPMain, cast[ptr MainNode[K, V]](newPcn), moAcquireRelease, moAcquire):
        if pcn.gen == parent.gen:
          ready.retire(cast[pointer](pcn), destroyCNodeCallback[K, V])
        let curMain = cur.main.load(moRelaxed)
        if curMain != nil and curMain.kind == mnkTNode:
          ready.retire(cast[pointer](curMain), destroyTNodeCallback[K, V])
        ready.retire(cast[pointer](cur), destroyINodeCallback[K, V])
      else:
        destroyCNodeCallback[K, V](cast[pointer](newPcn))

proc putInternal[K, V; MaxThreads: static int](
    self: Ctrie[K, V, MaxThreads],
    key: K,
    val: V,
    onlyIfAbsent: bool
): Option[V] {.discardable.} =
  if unlikely(self.core == nil): return none(V)
  let h = getHash(key)
  let th = self.getOrRegisterHandle()
  let pinned = unpinned(th).pin()
  var ready = retireReady(pinned)
  try:
    while true:
      let root = self.core.root.load(moAcquire)
      var cur = root
      var parent: ptr INode[K, V] = nil
      var level = 0
      var restarted = false

      while not restarted:
        let main = cur.main.load(moAcquire)
        if unlikely(main == nil):
          restarted = true
          break
        case main.kind
        of mnkCNode:
          let cn = cast[ptr CNode[K, V]](main)
          if cn.gen != root.gen:
            # Older snapshot generation: perform GCopy
            let newCn = gcopy(cn, root.gen)
            var expMain = main
            if cur.main.compareExchangeStrong(expMain, cast[ptr MainNode[K, V]](newCn), moAcquireRelease, moAcquire):
              # Branch successfully stamped with current generation
              discard
            else:
              freeUnlinkedCNode[K, V](newCn, root.gen)
            restarted = true
            break

          let pos = (h shr level) and 0x1F'u32
          let flag = 1'u32 shl pos
          let present = (cn.bmp and flag) != 0

          if not present:
            # Case A: Slot is empty. Insert fresh SNode.
            let sn = allocSNode(key, val, h)
            let idx = countBits32(cn.bmp and (flag - 1'u32))
            let newCn = allocCNode[K, V](cn.bmp or flag, root.gen, cn.csize + 1)
            for i in 0 ..< idx:
              newCn.children[i] = cn.children[i]
            newCn.children[idx] = makeBranchNode(sn)
            for i in idx ..< cn.csize:
              newCn.children[i + 1] = cn.children[i]

            var expMain = main
            if cur.main.compareExchangeStrong(expMain, cast[ptr MainNode[K, V]](newCn), moAcquireRelease, moAcquire):
              if cn.gen == root.gen:
                ready.retire(cast[pointer](cn), destroyCNodeCallback[K, V])
              discard self.core.count.fetchAdd(1, moRelaxed)
              return none(V)
            else:
              destroyCNodeCallback[K, V](cast[pointer](newCn))
              destroySNodeCallback[K, V](cast[pointer](sn))
              restarted = true
              break
          else:
            # Case B: Slot is occupied.
            let idx = countBits32(cn.bmp and (flag - 1'u32))
            let child = cn.children[idx]
            if child.isINode:
              parent = cur
              cur = child.toINode
              level += 5
            else:
              # SNode leaf
              let sn = child.toSNode
              if sn.key == key:
                if onlyIfAbsent:
                  return some(sn.vbox.val)

                # Key match: update value
                let oldVal = sn.vbox.val
                let newSn = allocSNode(key, val, h)
                let newCn = allocCNode[K, V](cn.bmp, root.gen, cn.csize)
                for i in 0 ..< cn.csize:
                  if i == idx:
                    newCn.children[i] = makeBranchNode(newSn)
                  else:
                    newCn.children[i] = cn.children[i]

                var expMain = main
                if cur.main.compareExchangeStrong(expMain, cast[ptr MainNode[K, V]](newCn), moAcquireRelease, moAcquire):
                  ready.retire(cast[pointer](sn), destroySNodeCallback[K, V])
                  if cn.gen == root.gen:
                    ready.retire(cast[pointer](cn), destroyCNodeCallback[K, V])
                  return some(oldVal)
                else:
                  destroyCNodeCallback[K, V](cast[pointer](newCn))
                  destroySNodeCallback[K, V](cast[pointer](newSn))
                  restarted = true
                  break
              else:
                # Collision: expand branch into sub-INode
                let newSn = allocSNode(key, val, h)
                let subINode = createSubINode(sn, newSn, level + 5, root.gen)
                let convertedToLNode = isLNodeSubtree(subINode)
                let newCn = allocCNode[K, V](cn.bmp, root.gen, cn.csize)
                for i in 0 ..< cn.csize:
                  if i == idx:
                    newCn.children[i] = makeBranchNode(subINode)
                  else:
                    newCn.children[i] = cn.children[i]

                var expMain = main
                if cur.main.compareExchangeStrong(expMain, cast[ptr MainNode[K, V]](newCn), moAcquireRelease, moAcquire):
                  if cn.gen == root.gen:
                    ready.retire(cast[pointer](cn), destroyCNodeCallback[K, V])
                  if convertedToLNode:
                    ready.retire(cast[pointer](sn), destroySNodeCallback[K, V])
                    destroySNodeCallback[K, V](cast[pointer](newSn))
                  discard self.core.count.fetchAdd(1, moRelaxed)
                  return none(V)
                else:
                  destroyCNodeCallback[K, V](cast[pointer](newCn))
                  freeUnlinkedSubTree[K, V](subINode)
                  destroySNodeCallback[K, V](cast[pointer](newSn))
                  restarted = true
                  break

        of mnkLNode:
          let ln = cast[ptr LNode[K, V]](main)
          if onlyIfAbsent:
            var checkCurr = ln.head
            while checkCurr != nil:
              if checkCurr.key == key:
                return some(checkCurr.vbox.val)
              checkCurr = checkCurr.next

          var found = false
          var oldVal: V
          var curr = ln.head
          var newHead: ptr LNodeEntry[K, V] = nil
          while curr != nil:
            if curr.key == key:
              found = true
              oldVal = curr.vbox.val
              let vb = newVBox(val)
              newHead = allocLNodeEntry(key, vb, newHead)
            else:
              incRef(curr.vbox)
              newHead = allocLNodeEntry(curr.key, curr.vbox, newHead)
            curr = curr.next

          if not found:
            let vb = newVBox(val)
            newHead = allocLNodeEntry(key, vb, newHead)

          let newLn = allocLNode[K, V](h, newHead)
          var expMain = main
          if cur.main.compareExchangeStrong(expMain, cast[ptr MainNode[K, V]](newLn), moAcquireRelease, moAcquire):
            ready.retire(cast[pointer](ln), destroyLNodeCallback[K, V])
            if not found:
              discard self.core.count.fetchAdd(1, moRelaxed)
              return none(V)
            else:
              return some(oldVal)
          else:
            destroyLNodeCallback[K, V](cast[pointer](newLn))
            restarted = true
            break

        of mnkTNode:
          let tn = cast[ptr TNode[K, V]](main)
          self.clean(parent, cur, tn.snode, ready)
          restarted = true
          break
  finally:
    unpinGuard(toPinned(ready))

proc put*[K, V; MaxThreads: static int](
    self: Ctrie[K, V, MaxThreads],
    key: K,
    val: V
): Option[V] {.discardable.} =
  ## Inserts or updates `key` with `val`. Returns previous value if replaced.
  ## Lock-free.
  self.putInternal(key, val, onlyIfAbsent = false)

proc putIfAbsent*[K, V; MaxThreads: static int](
    self: Ctrie[K, V, MaxThreads],
    key: K,
    val: V
): Option[V] {.discardable.} =
  ## Inserts `key` with `val` if not already present. Returns `none(V)` if
  ## inserted, or `some(existingVal)` if already present. Lock-free.
  self.putInternal(key, val, onlyIfAbsent = true)

proc `[]=`*[K, V; MaxThreads: static int](
    self: Ctrie[K, V, MaxThreads],
    key: K,
    val: V
) {.inline.} =
  discard self.put(key, val)

proc delete*[K, V; MaxThreads: static int](
    self: Ctrie[K, V, MaxThreads],
    key: K
): Option[V] {.discardable.} =
  ## Removes `key` from the Ctrie, executing bottom-up contraction if
  ## appropriate. Lock-free.
  if unlikely(self.core == nil): return none(V)
  let h = getHash(key)
  let th = self.getOrRegisterHandle()
  let pinned = unpinned(th).pin()
  var ready = retireReady(pinned)
  try:
    while true:
      let root = self.core.root.load(moAcquire)
      var cur = root
      var parent: ptr INode[K, V] = nil
      var level = 0
      var restarted = false

      while not restarted:
        let main = cur.main.load(moAcquire)
        if unlikely(main == nil): return none(V)
        case main.kind
        of mnkCNode:
          let cn = cast[ptr CNode[K, V]](main)
          if cn.gen != root.gen:
            let newCn = gcopy(cn, root.gen)
            var expMain = main
            if cur.main.compareExchangeStrong(expMain, cast[ptr MainNode[K, V]](newCn), moAcquireRelease, moAcquire):
              discard
            else:
              freeUnlinkedCNode[K, V](newCn, root.gen)
            restarted = true
            break

          let pos = (h shr level) and 0x1F'u32
          let flag = 1'u32 shl pos
          if (cn.bmp and flag) == 0:
            return none(V) # Key absent

          let idx = countBits32(cn.bmp and (flag - 1'u32))
          let child = cn.children[idx]
          if child.isINode:
            parent = cur
            cur = child.toINode
            level += 5
          else:
            let sn = child.toSNode
            if sn.key != key:
              return none(V)
            let val = sn.vbox.val

            if cn.csize == 2 and cur != root:
              # Contraction to TNode
              let remainingIdx = if idx == 0: 1 else: 0
              let remChild = cn.children[remainingIdx]
              if remChild.isSNode:
                let tn = allocTNode(remChild.toSNode)
                var expMain = main
                if cur.main.compareExchangeStrong(expMain, cast[ptr MainNode[K, V]](tn), moAcquireRelease, moAcquire):
                  ready.retire(cast[pointer](sn), destroySNodeCallback[K, V])
                  if cn.gen == root.gen:
                    ready.retire(cast[pointer](cn), destroyCNodeCallback[K, V])
                  self.clean(parent, cur, remChild.toSNode, ready)
                  discard self.core.count.fetchSub(1, moRelaxed)
                  return some(val)
                else:
                  destroyTNodeCallback[K, V](cast[pointer](tn))
                  restarted = true
                  break
              else:
                # Surviving child is INode: standard contraction
                let newCn = allocCNode[K, V](cn.bmp and (not flag), root.gen, 1)
                newCn.children[0] = remChild
                var expMain = main
                if cur.main.compareExchangeStrong(expMain, cast[ptr MainNode[K, V]](newCn), moAcquireRelease, moAcquire):
                  ready.retire(cast[pointer](sn), destroySNodeCallback[K, V])
                  if cn.gen == root.gen:
                    ready.retire(cast[pointer](cn), destroyCNodeCallback[K, V])
                  discard self.core.count.fetchSub(1, moRelaxed)
                  return some(val)
                else:
                  destroyCNodeCallback[K, V](cast[pointer](newCn))
                  restarted = true
                  break
            else:
              let newSize = cn.csize - 1
              let newCn = allocCNode[K, V](cn.bmp and (not flag), root.gen, newSize)
              var dst = 0
              for i in 0 ..< cn.csize:
                if i != idx:
                  newCn.children[dst] = cn.children[i]
                  inc dst

              var expMain = main
              if cur.main.compareExchangeStrong(expMain, cast[ptr MainNode[K, V]](newCn), moAcquireRelease, moAcquire):
                ready.retire(cast[pointer](sn), destroySNodeCallback[K, V])
                if cn.gen == root.gen:
                  ready.retire(cast[pointer](cn), destroyCNodeCallback[K, V])
                discard self.core.count.fetchSub(1, moRelaxed)
                return some(val)
              else:
                destroyCNodeCallback[K, V](cast[pointer](newCn))
                restarted = true
                break

        of mnkLNode:
          let ln = cast[ptr LNode[K, V]](main)
          var checkCurr = ln.head
          var keyFound = false
          while checkCurr != nil:
            if checkCurr.key == key:
              keyFound = true
              break
            checkCurr = checkCurr.next

          if not keyFound:
            return none(V)

          var val: V
          var count = 0
          var newHead: ptr LNodeEntry[K, V] = nil
          var curr = ln.head
          while curr != nil:
            if curr.key == key:
              val = curr.vbox.val
            else:
              incRef(curr.vbox)
              newHead = allocLNodeEntry(curr.key, curr.vbox, newHead)
              inc count
            curr = curr.next

          if count == 1:
            # Contract to SNode and TNode
            let sn = allocSNodeWithVBox(newHead.key, newHead.vbox, ln.hash)
            wasMoved(newHead.key)
            deallocShared(newHead)
            newHead = nil

            let tn = allocTNode(sn)
            var expMain = main
            if cur.main.compareExchangeStrong(expMain, cast[ptr MainNode[K, V]](tn), moAcquireRelease, moAcquire):
              ready.retire(cast[pointer](ln), destroyLNodeCallback[K, V])
              self.clean(parent, cur, sn, ready)
              discard self.core.count.fetchSub(1, moRelaxed)
              return some(val)
            else:
              destroyTNodeCallback[K, V](cast[pointer](tn))
              destroySNodeCallback[K, V](cast[pointer](sn))
              restarted = true
              break
          else:
            let newLn = allocLNode[K, V](ln.hash, newHead)
            var expMain = main
            if cur.main.compareExchangeStrong(expMain, cast[ptr MainNode[K, V]](newLn), moAcquireRelease, moAcquire):
              ready.retire(cast[pointer](ln), destroyLNodeCallback[K, V])
              discard self.core.count.fetchSub(1, moRelaxed)
              return some(val)
            else:
              destroyLNodeCallback[K, V](cast[pointer](newLn))
              restarted = true
              break

        of mnkTNode:
          let tn = cast[ptr TNode[K, V]](main)
          self.clean(parent, cur, tn.snode, ready)
          restarted = true
          break
  finally:
    unpinGuard(toPinned(ready))

proc del*[K, V; MaxThreads: static int](
    self: Ctrie[K, V, MaxThreads],
    key: K
) {.inline.} =
  discard self.delete(key)

proc computeIfAbsent*[K, V; MaxThreads: static int](
    self: Ctrie[K, V, MaxThreads],
    key: K,
    computeFn: proc(k: K): V {.closure, gcsafe.}
): V =
  ## Returns the existing value mapped to `key`, or atomically computes and
  ## inserts it.
  let existing = self.get(key)
  if existing.isSome:
    return existing.get
  let computed = computeFn(key)
  let prev = self.putIfAbsent(key, computed)
  if prev.isSome:
    return prev.get
  return computed

proc len*[K, V; MaxThreads: static int](self: Ctrie[K, V, MaxThreads]): int {.inline.} =
  if self.core == nil: 0 else: max(0, self.core.count.load(moRelaxed))

proc isEmpty*[K, V; MaxThreads: static int](self: Ctrie[K, V, MaxThreads]): bool {.inline.} =
  self.len == 0

# ---------------------------------------------------------------------------
# Wait-Free O(1) Snapshotting
# ---------------------------------------------------------------------------

proc snapshot*[K, V; MaxThreads: static int](
    self: Ctrie[K, V, MaxThreads]
): Snapshot[K, V, MaxThreads] =
  ## Atomically creates an O(1) wait-free point-in-time generation snapshot.
  let th = self.getOrRegisterHandle()
  let pinned = unpinned(th).pin()
  try:
    while true:
      let curRoot = self.core.root.load(moAcquire)
      let curMain = curRoot.main.load(moAcquire)
      let freshGen = allocGeneration()
      let newRoot = allocINode[K, V](curMain, freshGen)
      var expCurRoot = curRoot
      if self.core.root.compareExchangeStrong(expCurRoot, newRoot, moSequentiallyConsistent, moAcquire):
        decRef(freshGen)
        discard self.core.rc.fetchAdd(1, moRelaxed)
        return Snapshot[K, V, MaxThreads](core: self.core, root: curRoot)
      else:
        destroyINodeCallback[K, V](cast[pointer](newRoot))
        decRef(freshGen)
  finally:
    unpinGuard(pinned)

# ---------------------------------------------------------------------------
# Snapshot Queries & Iteration
# ---------------------------------------------------------------------------

proc get*[K, V; MaxThreads: static int](
    snap: Snapshot[K, V, MaxThreads],
    key: K
): Option[V] =
  ## Wait-free read from snapshot generation.
  if unlikely(snap.root == nil or snap.core == nil): return none(V)
  let th = snap.getOrRegisterHandle()
  let pinned = unpinned(th).pin()
  try:
    let h = getHash(key)
    var cur = snap.root
    var level = 0
    while true:
      let main = cur.main.load(moAcquire)
      if unlikely(main == nil): return none(V)
      case main.kind
      of mnkCNode:
        let cn = cast[ptr CNode[K, V]](main)
        let pos = (h shr level) and 0x1F'u32
        let flag = 1'u32 shl pos
        if (cn.bmp and flag) == 0:
          return none(V)
        let idx = countBits32(cn.bmp and (flag - 1'u32))
        let child = cn.children[idx]
        if child.isSNode:
          let sn = child.toSNode
          if sn.hash == h and sn.key == key:
            return some(sn.vbox.val)
          return none(V)
        else:
          cur = child.toINode
          level += 5
      of mnkLNode:
        let ln = cast[ptr LNode[K, V]](main)
        if ln.hash != h: return none(V)
        var curr = ln.head
        while curr != nil:
          if curr.key == key:
            return some(curr.vbox.val)
          curr = curr.next
        return none(V)
      of mnkTNode:
        let tn = cast[ptr TNode[K, V]](main)
        if tn.snode != nil and tn.snode.hash == h and tn.snode.key == key:
          return some(tn.snode.vbox.val)
        return none(V)
  finally:
    unpinGuard(pinned)

proc contains*[K, V; MaxThreads: static int](
    snap: Snapshot[K, V, MaxThreads],
    key: K
): bool {.inline.} =
  snap.get(key).isSome

iterator pairs*[K, V; MaxThreads: static int](
    snap: Snapshot[K, V, MaxThreads]
): (K, V) =
  ## Iterates across all (key, val) entries in this snapshot view.
  if snap.root != nil and snap.core != nil:
    let th = snap.getOrRegisterHandle()
    let pinned = unpinned(th).pin()
    try:
      var stack: seq[ptr INode[K, V]] = @[snap.root]
      while stack.len > 0:
        let inode = stack.pop()
        let main = inode.main.load(moAcquire)
        if main != nil:
          case main.kind
          of mnkCNode:
            let cn = cast[ptr CNode[K, V]](main)
            for i in 0 ..< cn.csize:
              let child = cn.children[i]
              if child.isSNode:
                let sn = child.toSNode
                yield (sn.key, sn.vbox.val)
              else:
                stack.add(child.toINode)
          of mnkLNode:
            let ln = cast[ptr LNode[K, V]](main)
            var curr = ln.head
            while curr != nil:
              yield (curr.key, curr.vbox.val)
              curr = curr.next
          of mnkTNode:
            let tn = cast[ptr TNode[K, V]](main)
            if tn.snode != nil:
              yield (tn.snode.key, tn.snode.vbox.val)
    finally:
      unpinGuard(pinned)

iterator keys*[K, V; MaxThreads: static int](
    snap: Snapshot[K, V, MaxThreads]
): K =
  for k, _ in snap.pairs:
    yield k

iterator values*[K, V; MaxThreads: static int](
    snap: Snapshot[K, V, MaxThreads]
): V =
  for _, v in snap.pairs:
    yield v

proc len*[K, V; MaxThreads: static int](snap: Snapshot[K, V, MaxThreads]): int =
  var n = 0
  for _ in snap.pairs:
    inc n
  return n

proc isEmpty*[K, V; MaxThreads: static int](snap: Snapshot[K, V, MaxThreads]): bool {.inline.} =
  snap.len == 0

iterator pairs*[K, V; MaxThreads: static int](
    self: Ctrie[K, V, MaxThreads]
): (K, V) =
  ## Snapshot-isolated linearizable iteration over the active Ctrie.
  let snap = self.snapshot()
  for k, v in snap.pairs:
    yield (k, v)

iterator keys*[K, V; MaxThreads: static int](
    self: Ctrie[K, V, MaxThreads]
): K =
  for k, _ in self.pairs:
    yield k

iterator values*[K, V; MaxThreads: static int](
    self: Ctrie[K, V, MaxThreads]
): V =
  for _, v in self.pairs:
    yield v

# ---------------------------------------------------------------------------
# Destruction & Lifecycle
# ---------------------------------------------------------------------------

proc freeTreeRecursive[K, V](
    inode: ptr INode[K, V],
    visitedInodes: var seq[ptr INode[K, V]]
) =
  if inode == nil or inode in visitedInodes: return
  visitedInodes.add(inode)
  let main = inode.main.load(moRelaxed)
  if main != nil:
    case main.kind
    of mnkCNode:
      let cn = cast[ptr CNode[K, V]](main)
      for i in 0 ..< cn.csize:
        let child = cn.children[i]
        if child.isSNode:
          destroySNodeCallback[K, V](cast[pointer](child.toSNode))
        elif child.isINode:
          freeTreeRecursive(child.toINode, visitedInodes)
      decRef(cn.gen)
      deallocShared(cn)
    of mnkTNode:
      let tn = cast[ptr TNode[K, V]](main)
      if tn.snode != nil:
        destroySNodeCallback[K, V](cast[pointer](tn.snode))
      deallocShared(tn)
    of mnkLNode:
      destroyLNodeCallback[K, V](cast[pointer](main))
  decRef(inode.gen)
  freeAligned(inode)

proc destroyCore[K, V; MaxThreads: static int](core: ptr CtrieCore[K, V, MaxThreads]) =
  if core != nil:
    let r = core.root.load(moRelaxed)
    if r != nil:
      var visited: seq[ptr INode[K, V]] = @[]
      freeTreeRecursive[K, V](r, visited)
    if core.ownsManager and core.manager != nil:
      reset(core.manager[])
      freeAligned(core.manager)
    deallocShared(core)

proc `=copy`*[K, V; MaxThreads: static int](
    dest: var Ctrie[K, V, MaxThreads],
    src: Ctrie[K, V, MaxThreads]
) =
  if dest.core != src.core:
    if dest.core != nil:
      if dest.core.rc.fetchSub(1, moAcquireRelease) == 1:
        destroyCore[K, V, MaxThreads](dest.core)
    dest.core = src.core
    if dest.core != nil:
      discard dest.core.rc.fetchAdd(1, moRelaxed)

proc `=destroy`*[K, V; MaxThreads: static int](self: var Ctrie[K, V, MaxThreads]) =
  if self.core != nil:
    if self.core.rc.fetchSub(1, moAcquireRelease) == 1:
      destroyCore[K, V, MaxThreads](self.core)
    self.core = nil

proc `=copy`*[K, V; MaxThreads: static int](
    dest: var Snapshot[K, V, MaxThreads],
    src: Snapshot[K, V, MaxThreads]
) =
  if dest.core != src.core:
    if dest.core != nil:
      if dest.core.rc.fetchSub(1, moAcquireRelease) == 1:
        destroyCore[K, V, MaxThreads](dest.core)
    dest.core = src.core
    dest.root = src.root
    if dest.core != nil:
      discard dest.core.rc.fetchAdd(1, moRelaxed)

proc `=destroy`*[K, V; MaxThreads: static int](self: var Snapshot[K, V, MaxThreads]) =
  if self.core != nil:
    if self.core.rc.fetchSub(1, moAcquireRelease) == 1:
      destroyCore[K, V, MaxThreads](self.core)
    self.core = nil
    self.root = nil

# ---------------------------------------------------------------------------
# Constructors
# ---------------------------------------------------------------------------

proc initCtrie*[K, V](
    capacityHint: int = 16,
    maxThreads: static int = DefaultMaxThreads
): Ctrie[K, V, maxThreads] =
  ## Initializes a new concurrent lock-free Ctrie[K, V].
  let core = cast[ptr CtrieCore[K, V, maxThreads]](allocShared0(sizeof(CtrieCore[K, V, maxThreads])))
  core.id = allocCtrieId()
  let mgr = allocAligned[DebraManager[maxThreads, ccMulti]]()
  wasMoved(mgr[])
  mgr[] = initDebraManager[maxThreads, ccMulti]()
  core.manager = mgr
  core.ownsManager = true
  core.rc.store(1, moRelaxed)
  core.count.store(0, moRelaxed)

  let gen = allocGeneration()
  let emptyCn = allocCNode[K, V](0'u32, gen, 0)
  let rootINode = allocINode[K, V](cast[ptr MainNode[K, V]](emptyCn), gen)
  core.root.store(rootINode, moRelaxed)

  Ctrie[K, V, maxThreads](core: core)

proc getOrDefault*[K, V; MaxThreads: static int](
    self: Ctrie[K, V, MaxThreads],
    key: K,
    defaultVal: V
): V {.inline.} =
  let res = self.get(key)
  if res.isSome: res.get else: defaultVal

proc getOrDefault*[K, V; MaxThreads: static int](
    snap: Snapshot[K, V, MaxThreads],
    key: K,
    defaultVal: V
): V {.inline.} =
  let res = snap.get(key)
  if res.isSome: res.get else: defaultVal

proc initTable*[K, V](
    capacityHint: int = 16,
    maxThreads: static int = DefaultMaxThreads
): Table[K, V, maxThreads] {.inline.} =
  initCtrie[K, V](capacityHint, maxThreads)

proc initConcurrentTable*[K, V](
    capacityHint: int = 16,
    maxThreads: static int = DefaultMaxThreads
): ConcurrentTable[K, V, maxThreads] {.inline.} =
  initCtrie[K, V](capacityHint, maxThreads)

proc initConcurrentMap*[K, V](
    capacityHint: int = 16
): ConcurrentMap[K, V, DefaultMaxThreads] {.inline.} =
  initCtrie[K, V](capacityHint, DefaultMaxThreads)

proc initConcurrentTrie*[K, V](
    capacityHint: int = 16
): ConcurrentTrie[K, V, DefaultMaxThreads] {.inline.} =
  initCtrie[K, V](capacityHint, DefaultMaxThreads)

proc newCtrie*[K, V](
    capacityHint: int = 16,
    maxThreads: static int = DefaultMaxThreads
): Ctrie[K, V, maxThreads] {.inline.} =
  initCtrie[K, V](capacityHint, maxThreads)

proc newTable*[K, V](
    capacityHint: int = 16,
    maxThreads: static int = DefaultMaxThreads
): Table[K, V, maxThreads] {.inline.} =
  initTable[K, V](capacityHint, maxThreads)

proc newConcurrentTable*[K, V](
    capacityHint: int = 16,
    maxThreads: static int = DefaultMaxThreads
): ConcurrentTable[K, V, maxThreads] {.inline.} =
  initConcurrentTable[K, V](capacityHint, maxThreads)

proc newConcurrentMap*[K, V](
    capacityHint: int = 16
): ConcurrentMap[K, V, DefaultMaxThreads] {.inline.} =
  initConcurrentMap[K, V](capacityHint)

proc newConcurrentTrie*[K, V](
    capacityHint: int = 16
): ConcurrentTrie[K, V, DefaultMaxThreads] {.inline.} =
  initConcurrentTrie[K, V](capacityHint)

