## ===========================================================================
## Concurrency Topology: MPMC (Multi-Producer Multi-Consumer) Lock-Free Ordered Set
## ===========================================================================
##
## | Dimension              | Specification                                                    |
## |:-----------------------|:-----------------------------------------------------------------|
## | **Topologies**         | MPMC (Multi-Producer Multi-Consumer Concurrent Ordered Set)      |
## | **Algorithm**          | Fraser / Herlihy Lock-Free SkipList with Harris Logical Marking  |
## | **Ordering**           | Strict Total Key Order (ascending level-0 traversal)             |
## | **Capacity**           | Dynamically Unbounded                                            |
## | **Coordination**       | Atomic marked next-pointers, CAS insertion/physical unlinking   |
## | **Progress Guarantee** | Lock-Free (Insert, Remove) / Wait-Free Population (Contains)     |
## | **Memory Reclamation** | Debra SMR (Epoch-Based Reclamation, `MaxThreads` capacity)        |
## | **Set Algebra**        | Concurrent intersect, union, difference, and isSubsetOf          |
##
## ## Overview
##
## `SkipListSet[T]` is an MPMC lock-free ordered set based on Fraser and Herlihy's
## lock-free skip list algorithm with Harris-style logical deletion marking and
## Debra Safe Memory Reclamation (SMR).
##
## Elements are maintained in strictly ascending sorted order at level 0. The set
## supports concurrent membership queries (`contains`), insertions (`insert`, `incl`),
## removals (`remove`, `excl`), size queries (`len`, `isEmpty`), sorted iteration (`items`),
## and concurrent set algebra (`intersect`, `union`, `difference`, `isSubsetOf`).

when not compileOption("threads"):
  {.error: "lockfree/set requires --threads:on".}

import std/[options]
import pkg/typestates
import ./atomics
import ./smr/nebr
import ./internal/aligned_alloc

const
  DefaultMaxThreads* = 64
  DefaultMaxLevel* = 16
  MarkBit: uint = 1'u

template isMarked(val: uint): bool =
  (val and MarkBit) != 0'u

template toPtr[T](val: uint): ptr T =
  cast[ptr T](val and (not MarkBit))

template toEntry(p: pointer or ptr, marked: bool): uint =
  let u = cast[uint](p)
  if marked: (u or MarkBit) else: u

template itemCmp[T](a, b: T): int =
  when compiles(cmp(a, b)):
    cmp(a, b)
  else:
    if a < b: -1
    elif b < a: 1
    else: 0

type
  SkipListNode[T; MaxLevel: static int] = object
    val: T
    topLevel: int
    isHead: bool
    isTail: bool
    next: array[MaxLevel, Atomic[uint]]

  SkipListSetCore[T; MaxThreads: static int, MaxLevel: static int] = object
    id: uint64
    head: ptr SkipListNode[T, MaxLevel]
    tail: ptr SkipListNode[T, MaxLevel]
    manager: ptr DebraManager[MaxThreads, ccMulti]
    count: Atomic[int]
    rc: Atomic[int]
    ownsManager: bool

  SkipListSet*[
    T;
    MaxThreads: static int = DefaultMaxThreads,
    MaxLevel: static int = DefaultMaxLevel
  ] = object
    core*: ptr SkipListSetCore[T, MaxThreads, MaxLevel]

  Set*[
    T;
    MaxThreads: static int = DefaultMaxThreads,
    MaxLevel: static int = DefaultMaxLevel
  ] = SkipListSet[T, MaxThreads, MaxLevel]
  ## # Concurrency Topology: Set
  ## Ergonomic alias for `SkipListSet[T, MaxThreads, MaxLevel]`.

  ConcurrentSet*[
    T;
    MaxThreads: static int = DefaultMaxThreads,
    MaxLevel: static int = DefaultMaxLevel
  ] = SkipListSet[T, MaxThreads, MaxLevel]
  ## # Concurrency Topology: ConcurrentSet
  ## Ergonomic alias for `SkipListSet[T, MaxThreads, MaxLevel]`.

  OrderedSet*[
    T;
    MaxThreads: static int = DefaultMaxThreads,
    MaxLevel: static int = DefaultMaxLevel
  ] = SkipListSet[T, MaxThreads, MaxLevel]
  ## # Concurrency Topology: OrderedSet
  ## Ergonomic alias for `SkipListSet[T, MaxThreads, MaxLevel]`.

# ---------------------------------------------------------------------------
# Monotonic Set ID Generator
# ---------------------------------------------------------------------------

var gNextSkipListSetId {.global.}: Atomic[uint64]

proc allocSkipListSetId(): uint64 =
  gNextSkipListSetId.fetchAdd(1, moRelaxed) + 1

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
# Memory Management & Node Reclamation
# ---------------------------------------------------------------------------

proc destroyNodeCallback[T; MaxLevel: static int](p: pointer) {.nimcall, raises: [].} =
  let n = cast[ptr SkipListNode[T, MaxLevel]](p)
  if n != nil:
    try:
      when not (T is SomeNumber or T is bool or T is char or T is pointer or T is ptr):
        `=destroy`(n.val)
    except:
      discard
    deallocShared(n)

proc freeNodeDirect[T; MaxLevel: static int](n: ptr SkipListNode[T, MaxLevel]) {.gcsafe.} =
  if n != nil:
    when not (T is SomeNumber or T is bool or T is char or T is pointer or T is ptr):
      `=destroy`(n.val)
    deallocShared(n)

# ---------------------------------------------------------------------------
# Node Value Comparison
# ---------------------------------------------------------------------------

proc cmpNodeVal[T; MaxLevel: static int](
    node: ptr SkipListNode[T, MaxLevel], item: T
): int {.inline.} =
  if node.isHead:
    return -1
  if node.isTail:
    return 1
  itemCmp(node.val, item)

# ---------------------------------------------------------------------------
# Thread-local PRNG & Random Level Generator
# ---------------------------------------------------------------------------

var gSkiplistSetRng {.threadvar.}: uint64

proc nextRand(): uint64 {.inline.} =
  if gSkiplistSetRng == 0'u64:
    gSkiplistSetRng = cast[uint](addr gSkiplistSetRng) xor 0xa5a55a5aa5a55a5a'u64
    if gSkiplistSetRng == 0'u64:
      gSkiplistSetRng = 0x9876543210fedcba'u64
  var x = gSkiplistSetRng
  x = x xor (x shl 13)
  x = x xor (x shr 7)
  x = x xor (x shl 17)
  gSkiplistSetRng = x
  return x

proc randomLevel(maxLevel: int): int {.inline.} =
  let r = nextRand()
  var level = 0
  var temp = r
  while (temp and 1'u64) != 0'u64 and level < maxLevel - 1:
    level.inc()
    temp = temp shr 1
  return level

# ---------------------------------------------------------------------------
# Thread Handle TLS Auto-Registration
# ---------------------------------------------------------------------------

type
  TlsHandleEntry = object
    setId: uint64
    handleIdx: int

const MaxCachedTlsHandles = 32
var gTlsHandles {.threadvar.}: seq[TlsHandleEntry]

proc getOrRegisterHandle*[T; MaxThreads, MaxLevel: static int](
    self: SkipListSet[T, MaxThreads, MaxLevel]
): ThreadHandle[MaxThreads, ccMulti] =
  let setId = self.core.id
  for entry in gTlsHandles:
    if entry.setId == setId:
      return ThreadHandle[MaxThreads, ccMulti](idx: entry.handleIdx, manager: self.core.manager)
  let h = registerThread(self.core.manager[])
  if gTlsHandles.len >= MaxCachedTlsHandles:
    gTlsHandles.delete(0)
  gTlsHandles.add(TlsHandleEntry(setId: setId, handleIdx: h.idx))
  return h

# ---------------------------------------------------------------------------
# Construction, Copy, and Destruction
# ---------------------------------------------------------------------------

proc newSkipListSet*[
    T;
    MaxThreads: static int = DefaultMaxThreads,
    MaxLevel: static int = DefaultMaxLevel
](): SkipListSet[T, MaxThreads, MaxLevel] =
  ## Constructs a new empty `SkipListSet` with a dedicated `DebraManager`.
  let core = cast[ptr SkipListSetCore[T, MaxThreads, MaxLevel]](
    allocShared0(sizeof(SkipListSetCore[T, MaxThreads, MaxLevel]))
  )
  let mgr = allocAligned[DebraManager[MaxThreads, ccMulti]]()
  wasMoved(mgr[])
  mgr[] = initDebraManager[MaxThreads, ccMulti]()

  let head = cast[ptr SkipListNode[T, MaxLevel]](
    allocShared0(sizeof(SkipListNode[T, MaxLevel]))
  )
  let tail = cast[ptr SkipListNode[T, MaxLevel]](
    allocShared0(sizeof(SkipListNode[T, MaxLevel]))
  )
  head.isHead = true
  head.topLevel = MaxLevel - 1
  tail.isTail = true
  tail.topLevel = MaxLevel - 1

  for level in 0 ..< MaxLevel:
    head.next[level].store(toEntry(tail, false), moRelaxed)
    tail.next[level].store(toEntry(nil, false), moRelaxed)

  core.id = allocSkipListSetId()
  core.head = head
  core.tail = tail
  core.manager = mgr
  core.count.store(0, moRelaxed)
  core.rc.store(1, moRelaxed)
  core.ownsManager = true

  SkipListSet[T, MaxThreads, MaxLevel](core: core)

proc newSkipListSet*[
    T;
    MaxThreads: static int = DefaultMaxThreads,
    MaxLevel: static int = DefaultMaxLevel
](
    manager: ptr DebraManager[MaxThreads, ccMulti]
): SkipListSet[T, MaxThreads, MaxLevel] =
  ## Constructs a new empty `SkipListSet` sharing an external `DebraManager`.
  let core = cast[ptr SkipListSetCore[T, MaxThreads, MaxLevel]](
    allocShared0(sizeof(SkipListSetCore[T, MaxThreads, MaxLevel]))
  )
  let head = cast[ptr SkipListNode[T, MaxLevel]](
    allocShared0(sizeof(SkipListNode[T, MaxLevel]))
  )
  let tail = cast[ptr SkipListNode[T, MaxLevel]](
    allocShared0(sizeof(SkipListNode[T, MaxLevel]))
  )
  head.isHead = true
  head.topLevel = MaxLevel - 1
  tail.isTail = true
  tail.topLevel = MaxLevel - 1

  for level in 0 ..< MaxLevel:
    head.next[level].store(toEntry(tail, false), moRelaxed)
    tail.next[level].store(toEntry(nil, false), moRelaxed)

  core.id = allocSkipListSetId()
  core.head = head
  core.tail = tail
  core.manager = manager
  core.count.store(0, moRelaxed)
  core.rc.store(1, moRelaxed)
  core.ownsManager = false

  SkipListSet[T, MaxThreads, MaxLevel](core: core)

proc initSkipListSet*[
    T;
    MaxThreads: static int = DefaultMaxThreads,
    MaxLevel: static int = DefaultMaxLevel
](): SkipListSet[T, MaxThreads, MaxLevel] {.inline.} =
  newSkipListSet[T, MaxThreads, MaxLevel]()

proc `=destroy`*[T; MaxThreads, MaxLevel: static int](
    self: var SkipListSet[T, MaxThreads, MaxLevel]
) {.gcsafe.} =
  if self.core != nil:
    if self.core.rc.fetchSub(1, moRelease) == 1:
      threadFence(moAcquire)
      var curr = toPtr[SkipListNode[T, MaxLevel]](self.core.head.next[0].load(moRelaxed))
      while curr != nil and curr != self.core.tail:
        let nextEntry = curr.next[0].load(moRelaxed)
        let nextPtr = toPtr[SkipListNode[T, MaxLevel]](nextEntry)
        freeNodeDirect(curr)
        curr = nextPtr
      freeNodeDirect(self.core.head)
      freeNodeDirect(self.core.tail)
      if self.core.ownsManager and self.core.manager != nil:
        reset(self.core.manager[])
        freeAligned(self.core.manager)
      deallocShared(self.core)
    self.core = nil

proc `=copy`*[T; MaxThreads, MaxLevel: static int](
    dest: var SkipListSet[T, MaxThreads, MaxLevel],
    src: SkipListSet[T, MaxThreads, MaxLevel]
) =
  if dest.core != src.core:
    `=destroy`(dest)
    dest.core = src.core
    if dest.core != nil:
      discard dest.core.rc.fetchAdd(1, moRelaxed)

# ---------------------------------------------------------------------------
# Internal Fraser / Herlihy `find` Operation
# ---------------------------------------------------------------------------

proc find[T; MaxThreads, MaxLevel: static int](
    self: SkipListSet[T, MaxThreads, MaxLevel],
    item: T,
    preds: var array[MaxLevel, ptr SkipListNode[T, MaxLevel]],
    succs: var array[MaxLevel, ptr SkipListNode[T, MaxLevel]],
    ready: var RetireReady[MaxThreads, ccMulti]
): bool {.notATransition.} =
  while true:
    var pred = self.core.head
    var restart = false
    for level in countdown(MaxLevel - 1, 0):
      if restart:
        break
      var currEntry = pred.next[level].load(moAcquire)
      var curr = toPtr[SkipListNode[T, MaxLevel]](currEntry)
      while true:
        if curr == nil:
          break
        let succEntry = curr.next[level].load(moAcquire)
        let succ = toPtr[SkipListNode[T, MaxLevel]](succEntry)
        let marked = isMarked(succEntry)
        if marked:
          var expected = toEntry(curr, false)
          let desired = toEntry(succ, false)
          if not pred.next[level].compareExchange(expected, desired, moAcquireRelease, moAcquire):
            restart = true
            break
          if level == 0:
            ready.retire(cast[pointer](curr), destroyNodeCallback[T, MaxLevel])
          curr = succ
        else:
          if cmpNodeVal(curr, item) < 0:
            pred = curr
            curr = succ
          else:
            break
      preds[level] = pred
      succs[level] = curr
    if restart:
      continue
    return (succs[0] != nil and not succs[0].isTail and not succs[0].isHead and cmpNodeVal(succs[0], item) == 0)

# ---------------------------------------------------------------------------
# Public Set Operations
# ---------------------------------------------------------------------------

proc len*[T; MaxThreads, MaxLevel: static int](
    self: SkipListSet[T, MaxThreads, MaxLevel]
): int {.inline.} =
  ## Returns the approximate number of items currently in the set.
  if self.core == nil: 0
  else: max(0, self.core.count.load(moRelaxed))

proc isEmpty*[T; MaxThreads, MaxLevel: static int](
    self: SkipListSet[T, MaxThreads, MaxLevel]
): bool {.inline.} =
  ## Returns `true` if the set contains zero elements.
  self.len == 0

proc registerThread*[T; MaxThreads, MaxLevel: static int](
    self: var SkipListSet[T, MaxThreads, MaxLevel]
): ThreadHandle[MaxThreads, ccMulti] {.inline.} =
  ## Explicitly registers the calling thread with the set's Debra manager.
  registerThread(self.core.manager[])

proc unregisterThread*[T; MaxThreads, MaxLevel: static int](
    self: var SkipListSet[T, MaxThreads, MaxLevel],
    handle: ThreadHandle[MaxThreads, ccMulti]
) {.inline.} =
  ## Unregisters the thread handle, releasing its slot in the Debra registry.
  unregisterThread(self.core.manager[], handle)

proc contains*[T; MaxThreads, MaxLevel: static int](
    self: SkipListSet[T, MaxThreads, MaxLevel],
    item: T,
    handle: ThreadHandle[MaxThreads, ccMulti]
): bool =
  ## Returns `true` if `item` is present in the set using the provided thread handle.
  ## Wait-free population guarantee: does not perform CAS or mutate state.
  let pinned = unpinned(handle).pin()
  try:
    var pred = self.core.head
    var curr: ptr SkipListNode[T, MaxLevel] = nil
    for level in countdown(MaxLevel - 1, 0):
      var currEntry = pred.next[level].load(moAcquire)
      curr = toPtr[SkipListNode[T, MaxLevel]](currEntry)
      while curr != nil and curr != self.core.tail:
        let succEntry = curr.next[level].load(moAcquire)
        let succ = toPtr[SkipListNode[T, MaxLevel]](succEntry)
        if cmpNodeVal(curr, item) < 0:
          pred = curr
          curr = succ
        else:
          break
    let target = curr
    if target != nil and not target.isTail and not target.isHead and cmpNodeVal(target, item) == 0:
      let succ0 = target.next[0].load(moAcquire)
      return not isMarked(succ0)
    return false
  finally:
    unpinGuard(pinned)

proc contains*[T; MaxThreads, MaxLevel: static int](
    self: SkipListSet[T, MaxThreads, MaxLevel],
    item: T
): bool {.inline.} =
  ## Returns `true` if `item` is present in the set (auto-dispatched thread handle).
  let h = self.getOrRegisterHandle()
  self.contains(item, h)

proc insert*[T; MaxThreads, MaxLevel: static int](
    self: var SkipListSet[T, MaxThreads, MaxLevel],
    item: sink T,
    handle: ThreadHandle[MaxThreads, ccMulti]
): bool =
  ## Inserts `item` into the set.
  ## Returns `true` if a new item was inserted, `false` if `item` was already present.
  let pinned = unpinned(handle).pin()
  var ready = retireReady(pinned)
  try:
    var preds: array[MaxLevel, ptr SkipListNode[T, MaxLevel]]
    var succs: array[MaxLevel, ptr SkipListNode[T, MaxLevel]]
    let topLevel = randomLevel(MaxLevel)

    while true:
      let found = self.find(item, preds, succs, ready)
      if found:
        return false

      let newNode = cast[ptr SkipListNode[T, MaxLevel]](
        allocShared0(sizeof(SkipListNode[T, MaxLevel]))
      )
      newNode.isHead = false
      newNode.isTail = false
      newNode.topLevel = topLevel
      wasMoved(newNode.val)
      newNode.val = item

      for level in 0 .. topLevel:
        newNode.next[level].store(toEntry(succs[level], false), moRelaxed)

      let pred0 = preds[0]
      let succ0 = succs[0]
      var expected0 = toEntry(succ0, false)
      let desired0 = toEntry(newNode, false)
      if not pred0.next[0].compareExchange(expected0, desired0, moAcquireRelease, moAcquire):
        when not (T is SomeNumber or T is bool or T is char or T is pointer or T is ptr):
          `=destroy`(newNode.val)
        deallocShared(newNode)
        continue

      discard self.core.count.fetchAdd(1, moRelaxed)

      for level in 1 .. topLevel:
        if isMarked(newNode.next[0].load(moAcquire)):
          break
        while true:
          let pred = preds[level]
          let succ = succs[level]
          newNode.next[level].store(toEntry(succ, false), moRelaxed)
          var expected = toEntry(succ, false)
          let desired = toEntry(newNode, false)
          if pred.next[level].compareExchange(expected, desired, moAcquireRelease, moAcquire):
            break
          discard self.find(item, preds, succs, ready)

      handle.advanceEvery(32)
      return true
  finally:
    unpinGuard(toPinned(ready))

proc insert*[T; MaxThreads, MaxLevel: static int](
    self: var SkipListSet[T, MaxThreads, MaxLevel],
    item: sink T
): bool {.inline.} =
  ## Inserts `item` into the set using automatic thread registration.
  let h = self.getOrRegisterHandle()
  self.insert(item, h)

proc incl*[T; MaxThreads, MaxLevel: static int](
    self: var SkipListSet[T, MaxThreads, MaxLevel],
    item: sink T
) {.inline.} =
  ## Syntax sugar: `set.incl(item)`.
  discard self.insert(item)

proc remove*[T; MaxThreads, MaxLevel: static int](
    self: var SkipListSet[T, MaxThreads, MaxLevel],
    item: T,
    handle: ThreadHandle[MaxThreads, ccMulti]
): bool =
  ## Logically marks and physically unlinks `item` from the set.
  ## Returns `true` if `item` was found and removed, `false` otherwise.
  let pinned = unpinned(handle).pin()
  var ready = retireReady(pinned)
  try:
    var preds: array[MaxLevel, ptr SkipListNode[T, MaxLevel]]
    var succs: array[MaxLevel, ptr SkipListNode[T, MaxLevel]]

    while true:
      let found = self.find(item, preds, succs, ready)
      if not found:
        return false
      let nodeToDelete = succs[0]

      for level in countdown(nodeToDelete.topLevel, 1):
        var succEntry = nodeToDelete.next[level].load(moAcquire)
        while not isMarked(succEntry):
          let succPtr = toPtr[SkipListNode[T, MaxLevel]](succEntry)
          let markedEntry = toEntry(succPtr, true)
          if nodeToDelete.next[level].compareExchange(succEntry, markedEntry, moAcquireRelease, moAcquire):
            break
          succEntry = nodeToDelete.next[level].load(moAcquire)

      var succEntry0 = nodeToDelete.next[0].load(moAcquire)
      while true:
        if isMarked(succEntry0):
          return false
        let succPtr0 = toPtr[SkipListNode[T, MaxLevel]](succEntry0)
        let markedEntry0 = toEntry(succPtr0, true)
        if nodeToDelete.next[0].compareExchange(succEntry0, markedEntry0, moAcquireRelease, moAcquire):
          discard self.core.count.fetchSub(1, moRelaxed)
          discard self.find(item, preds, succs, ready)
          handle.advanceEvery(32)
          return true
        succEntry0 = nodeToDelete.next[0].load(moAcquire)
  finally:
    unpinGuard(toPinned(ready))

proc remove*[T; MaxThreads, MaxLevel: static int](
    self: var SkipListSet[T, MaxThreads, MaxLevel],
    item: T
): bool {.inline.} =
  ## Removes `item` from the set using automatic thread registration.
  let h = self.getOrRegisterHandle()
  self.remove(item, h)

proc excl*[T; MaxThreads, MaxLevel: static int](
    self: var SkipListSet[T, MaxThreads, MaxLevel],
    item: T
) {.inline.} =
  ## Syntax sugar: `set.excl(item)`.
  discard self.remove(item)

# ---------------------------------------------------------------------------
# Ordered Iterator (Ascending Level-0 Walk)
# ---------------------------------------------------------------------------

iterator items*[T; MaxThreads, MaxLevel: static int](
    self: SkipListSet[T, MaxThreads, MaxLevel],
    handle: ThreadHandle[MaxThreads, ccMulti]
): T =
  ## Iterates over all elements in strictly ascending sorted order.
  let pinned = unpinned(handle).pin()
  try:
    var currEntry = self.core.head.next[0].load(moAcquire)
    var curr = toPtr[SkipListNode[T, MaxLevel]](currEntry)
    while curr != nil and curr != self.core.tail:
      let succEntry = curr.next[0].load(moAcquire)
      if not isMarked(succEntry):
        yield curr.val
      curr = toPtr[SkipListNode[T, MaxLevel]](succEntry)
  finally:
    unpinGuard(pinned)

iterator items*[T; MaxThreads, MaxLevel: static int](
    self: SkipListSet[T, MaxThreads, MaxLevel]
): T =
  ## Iterates over all elements in strictly ascending sorted order (auto handle).
  let h = self.getOrRegisterHandle()
  for x in self.items(h):
    yield x

proc toSeq*[T; MaxThreads, MaxLevel: static int](
    self: SkipListSet[T, MaxThreads, MaxLevel]
): seq[T] =
  ## Collects all elements into a `seq[T]` in ascending sorted order.
  for x in self:
    result.add(x)

# ---------------------------------------------------------------------------
# Concurrent Set Algebra
# ---------------------------------------------------------------------------

proc intersect*[T; MaxThreads, MaxLevel: static int](
    a, b: SkipListSet[T, MaxThreads, MaxLevel]
): SkipListSet[T, MaxThreads, MaxLevel] =
  ## Computes the set intersection (A ∩ B).
  result = newSkipListSet[T, MaxThreads, MaxLevel]()
  for x in a:
    if b.contains(x):
      discard result.insert(x)

template `*`*[T; MaxThreads, MaxLevel: static int](
    a, b: SkipListSet[T, MaxThreads, MaxLevel]
): SkipListSet[T, MaxThreads, MaxLevel] =
  intersect(a, b)

proc union*[T; MaxThreads, MaxLevel: static int](
    a, b: SkipListSet[T, MaxThreads, MaxLevel]
): SkipListSet[T, MaxThreads, MaxLevel] =
  ## Computes the set union (A ∪ B).
  result = newSkipListSet[T, MaxThreads, MaxLevel]()
  for x in a:
    discard result.insert(x)
  for x in b:
    discard result.insert(x)

template `+`*[T; MaxThreads, MaxLevel: static int](
    a, b: SkipListSet[T, MaxThreads, MaxLevel]
): SkipListSet[T, MaxThreads, MaxLevel] =
  union(a, b)

proc difference*[T; MaxThreads, MaxLevel: static int](
    a, b: SkipListSet[T, MaxThreads, MaxLevel]
): SkipListSet[T, MaxThreads, MaxLevel] =
  ## Computes the set difference (A \ B).
  result = newSkipListSet[T, MaxThreads, MaxLevel]()
  for x in a:
    if not b.contains(x):
      discard result.insert(x)

template `-`*[T; MaxThreads, MaxLevel: static int](
    a, b: SkipListSet[T, MaxThreads, MaxLevel]
): SkipListSet[T, MaxThreads, MaxLevel] =
  difference(a, b)

proc isSubsetOf*[T; MaxThreads, MaxLevel: static int](
    a, b: SkipListSet[T, MaxThreads, MaxLevel]
): bool =
  ## Returns `true` if all elements of `a` are present in `b` (A ⊆ B).
  for x in a:
    if not b.contains(x):
      return false
  return true

template `<=`*[T; MaxThreads, MaxLevel: static int](
    a, b: SkipListSet[T, MaxThreads, MaxLevel]
): bool =
  isSubsetOf(a, b)

proc `<`*[T; MaxThreads, MaxLevel: static int](
    a, b: SkipListSet[T, MaxThreads, MaxLevel]
): bool {.inline.} =
  ## Returns `true` if `a` is a strict subset of `b` (A ⊂ B).
  a.len < b.len and a.isSubsetOf(b)

proc `==`*[T; MaxThreads, MaxLevel: static int](
    a, b: SkipListSet[T, MaxThreads, MaxLevel]
): bool =
  ## Returns `true` if sets `a` and `b` contain identical elements.
  if a.core == b.core: return true
  if a.len != b.len: return false
  return a.isSubsetOf(b)

proc toSkipListSet*[T](
    items: openArray[T]
): SkipListSet[T, DefaultMaxThreads, DefaultMaxLevel] =
  ## Constructs a new `SkipListSet` with default threads and level populated with items from `items`.
  result = newSkipListSet[T, DefaultMaxThreads, DefaultMaxLevel]()
  for item in items:
    discard result.insert(item)

# ---------------------------------------------------------------------------
# Constructor Aliases
# ---------------------------------------------------------------------------

proc newSet*[
    T;
    MaxThreads: static int = DefaultMaxThreads,
    MaxLevel: static int = DefaultMaxLevel
](): Set[T, MaxThreads, MaxLevel] {.inline.} =
  ## Smart constructor for `Set[T]`.
  newSkipListSet[T, MaxThreads, MaxLevel]()

proc initSet*[
    T;
    MaxThreads: static int = DefaultMaxThreads,
    MaxLevel: static int = DefaultMaxLevel
](): Set[T, MaxThreads, MaxLevel] {.inline.} =
  ## Initializer for `Set[T]`.
  initSkipListSet[T, MaxThreads, MaxLevel]()

proc newConcurrentSet*[
    T;
    MaxThreads: static int = DefaultMaxThreads,
    MaxLevel: static int = DefaultMaxLevel
](): ConcurrentSet[T, MaxThreads, MaxLevel] {.inline.} =
  ## Smart constructor for `ConcurrentSet[T]`.
  newSkipListSet[T, MaxThreads, MaxLevel]()

proc initConcurrentSet*[
    T;
    MaxThreads: static int = DefaultMaxThreads,
    MaxLevel: static int = DefaultMaxLevel
](): ConcurrentSet[T, MaxThreads, MaxLevel] {.inline.} =
  ## Initializer for `ConcurrentSet[T]`.
  initSkipListSet[T, MaxThreads, MaxLevel]()

proc newOrderedSet*[
    T;
    MaxThreads: static int = DefaultMaxThreads,
    MaxLevel: static int = DefaultMaxLevel
](): OrderedSet[T, MaxThreads, MaxLevel] {.inline.} =
  ## Smart constructor for `OrderedSet[T]`.
  newSkipListSet[T, MaxThreads, MaxLevel]()

proc initOrderedSet*[
    T;
    MaxThreads: static int = DefaultMaxThreads,
    MaxLevel: static int = DefaultMaxLevel
](): OrderedSet[T, MaxThreads, MaxLevel] {.inline.} =
  ## Initializer for `OrderedSet[T]`.
  initSkipListSet[T, MaxThreads, MaxLevel]()
