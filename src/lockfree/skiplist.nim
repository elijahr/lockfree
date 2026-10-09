## # Concurrency Topology: MPMC Lock-Free Ordered Key-Value Map (`SkipListMap`)
##
## | Dimension              | Specification                                                    |
## |:-----------------------|:-----------------------------------------------------------------|
## | **Topologies**         | MPMC (Multi-Producer Multi-Consumer Concurrent Key-Value Map)   |
## | **Algorithm**          | Fraser / Herlihy Lock-Free SkipList with Harris Logical Marking  |
## | **Ordering**           | Strict Total Key Order (ascending level-0 traversal)             |
## | **Capacity**           | Dynamically Unbounded                                            |
## | **Coordination**       | Atomic marked next-pointers, CAS insertion/physical unlinking   |
## | **Payload Encoding**   | Type-agnostic pointer-indirection box (`VBox[V]`)                |
## | **Progress Guarantee** | Lock-Free (Put, Delete) / Wait-Free Population (Get, Contains)   |
## | **Memory Reclamation** | Debra SMR (Epoch-Based Reclamation, `MaxThreads` capacity)        |
##
## ## Overview
##
## `SkipListMap[K, V]` is an MPMC lock-free ordered associative table
## implementing Keir Fraser's and Maurice Herlihy's lock-free skip list
## algorithm with Harris-style logical deletion marking and Debra Safe Memory
## Reclamation (SMR).
##
## It maintains keys in strictly sorted order at level 0, supporting concurrent
## insertions (`put`), lookups (`get`, `contains`, `[]`), removals (`delete`,
## `del`), atomic conditional updates (`computeIfAbsent`), and ordered range
## traversals (`pairs`).

when not compileOption("threads"):
  {.error: "lockfree/skiplist requires --threads:on".}

import std/[options]
import pkg/typestates
import ./atomics
import ./backoff
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

template keyCmp[K](a, b: K): int =
  when compiles(cmp(a, b)):
    cmp(a, b)
  else:
    if a < b: -1
    elif b < a: 1
    else: 0

type
  VBox[V] = object
    val: V

  SkipListNode[K, V; MaxLevel: static int] = object
    key: K
    valPtr: Atomic[ptr VBox[V]]
    topLevel: int
    isHead: bool
    isTail: bool
    next: array[MaxLevel, Atomic[uint]]

  SkipListCore[K, V; MaxThreads: static int, MaxLevel: static int] = object
    id: uint64
    head: ptr SkipListNode[K, V, MaxLevel]
    tail: ptr SkipListNode[K, V, MaxLevel]
    manager: ptr DebraManager[MaxThreads, ccMulti]
    count: Atomic[int]
    rc: Atomic[int]
    ownsManager: bool

  SkipListMap*[
    K, V;
    MaxThreads: static int = DefaultMaxThreads,
    MaxLevel: static int = DefaultMaxLevel
  ] = object
    core*: ptr SkipListCore[K, V, MaxThreads, MaxLevel]

  SortedTable*[
    K, V;
    MaxThreads: static int = DefaultMaxThreads,
    MaxLevel: static int = DefaultMaxLevel
  ] = SkipListMap[K, V, MaxThreads, MaxLevel]
  ## # Concurrency Topology: SortedTable
  ## Ergonomic alias for `SkipListMap[K, V, MaxThreads, MaxLevel]`.

  OrderedTable*[
    K, V;
    MaxThreads: static int = DefaultMaxThreads,
    MaxLevel: static int = DefaultMaxLevel
  ] = SkipListMap[K, V, MaxThreads, MaxLevel]
  ## # Concurrency Topology: OrderedTable
  ## Ergonomic alias for `SkipListMap[K, V, MaxThreads, MaxLevel]`.

  ConcurrentSortedTable*[
    K, V;
    MaxThreads: static int = DefaultMaxThreads,
    MaxLevel: static int = DefaultMaxLevel
  ] = SkipListMap[K, V, MaxThreads, MaxLevel]
  ## # Concurrency Topology: ConcurrentSortedTable
  ## Ergonomic alias for `SkipListMap[K, V, MaxThreads, MaxLevel]`.

# ---------------------------------------------------------------------------
# Monotonic Map ID Generator
# ---------------------------------------------------------------------------

var gNextSkipListId {.global.}: Atomic[uint64]

proc allocSkipListId(): uint64 =
  gNextSkipListId.fetchAdd(1, moRelaxed) + 1

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
# Memory Management & Destructors
# ---------------------------------------------------------------------------

proc newVBox[V](val: sink V): ptr VBox[V] {.inline.} =
  result = cast[ptr VBox[V]](allocShared0(sizeof(VBox[V])))
  wasMoved(result.val)
  result.val = val

proc freeVBox[V](box: ptr VBox[V]) {.inline, gcsafe.} =
  if box != nil:
    when not (V is SomeNumber or V is bool or V is char or V is pointer or V is ptr):
      {.cast(gcsafe).}:
        try:
          `=destroy`(box.val)
        except:
          discard
    deallocShared(box)

proc destroyVBoxCallback[V](p: pointer) {.nimcall, raises: [].} =
  let box = cast[ptr VBox[V]](p)
  if box != nil:
    try:
      when not (V is SomeNumber or V is bool or V is char or V is pointer or V is ptr):
        {.cast(gcsafe).}:
          `=destroy`(box.val)
    except:
      discard
    deallocShared(box)

proc destroyNodeCallback[K, V; MaxLevel: static int](p: pointer) {.nimcall, raises: [].} =
  let n = cast[ptr SkipListNode[K, V, MaxLevel]](p)
  if n != nil:
    let box = n.valPtr.load(moRelaxed)
    if box != nil:
      destroyVBoxCallback[V](cast[pointer](box))
    try:
      when not (K is SomeNumber or K is bool or K is char or K is pointer or K is ptr):
        {.cast(gcsafe).}:
          `=destroy`(n.key)
    except:
      discard
    deallocShared(n)

proc freeNodeDirect[K, V; MaxLevel: static int](n: ptr SkipListNode[K, V, MaxLevel]) {.gcsafe.} =
  if n != nil:
    let box = n.valPtr.load(moRelaxed)
    if box != nil:
      freeVBox[V](box)
    when not (K is SomeNumber or K is bool or K is char or K is pointer or K is ptr):
      {.cast(gcsafe).}:
        try:
          `=destroy`(n.key)
        except:
          discard
    deallocShared(n)

# ---------------------------------------------------------------------------
# Node Key Comparison
# ---------------------------------------------------------------------------

proc cmpNodeKey[K, V; MaxLevel: static int](
    node: ptr SkipListNode[K, V, MaxLevel], key: K
): int {.inline.} =
  if node.isHead:
    return -1
  if node.isTail:
    return 1
  keyCmp(node.key, key)

# ---------------------------------------------------------------------------
# Thread-local PRNG & Random Level Generator
# ---------------------------------------------------------------------------

var gSkiplistRng {.threadvar.}: uint64

proc nextRand(): uint64 {.inline.} =
  if gSkiplistRng == 0'u64:
    gSkiplistRng = cast[uint](addr gSkiplistRng) xor 0x853c49e6748fea9b'u64
    if gSkiplistRng == 0'u64:
      gSkiplistRng = 0x123456789abcdef0'u64
  var x = gSkiplistRng
  x = x xor (x shl 13)
  x = x xor (x shr 7)
  x = x xor (x shl 17)
  gSkiplistRng = x
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
    mapId: uint64
    handleIdx: int

const MaxCachedTlsHandles = 32
var gTlsHandles {.threadvar.}: seq[TlsHandleEntry]

proc getOrRegisterHandle*[K, V; MaxThreads, MaxLevel: static int](
    self: SkipListMap[K, V, MaxThreads, MaxLevel]
): ThreadHandle[MaxThreads, ccMulti] =
  let mapId = self.core.id
  for entry in gTlsHandles:
    if entry.mapId == mapId:
      return ThreadHandle[MaxThreads, ccMulti](idx: entry.handleIdx, manager: self.core.manager)
  let h = registerThread(self.core.manager[])
  if gTlsHandles.len >= MaxCachedTlsHandles:
    gTlsHandles.delete(0)
  gTlsHandles.add(TlsHandleEntry(mapId: mapId, handleIdx: h.idx))
  return h

# ---------------------------------------------------------------------------
# Construction, Copy, and Destruction
# ---------------------------------------------------------------------------

proc newSkipListMap*[
    K, V;
    MaxThreads: static int = DefaultMaxThreads,
    MaxLevel: static int = DefaultMaxLevel
](): SkipListMap[K, V, MaxThreads, MaxLevel] =
  ## Constructs a new empty `SkipListMap` with a dedicated `DebraManager`.
  let core = cast[ptr SkipListCore[K, V, MaxThreads, MaxLevel]](
    allocShared0(sizeof(SkipListCore[K, V, MaxThreads, MaxLevel]))
  )
  let mgr = allocAligned[DebraManager[MaxThreads, ccMulti]]()
  wasMoved(mgr[])
  mgr[] = initDebraManager[MaxThreads, ccMulti]()

  let head = cast[ptr SkipListNode[K, V, MaxLevel]](
    allocShared0(sizeof(SkipListNode[K, V, MaxLevel]))
  )
  let tail = cast[ptr SkipListNode[K, V, MaxLevel]](
    allocShared0(sizeof(SkipListNode[K, V, MaxLevel]))
  )
  head.isHead = true
  head.topLevel = MaxLevel - 1
  tail.isTail = true
  tail.topLevel = MaxLevel - 1

  for level in 0 ..< MaxLevel:
    head.next[level].store(toEntry(tail, false), moRelaxed)
    tail.next[level].store(toEntry(nil, false), moRelaxed)

  core.id = allocSkipListId()
  core.head = head
  core.tail = tail
  core.manager = mgr
  core.count.store(0, moRelaxed)
  core.rc.store(1, moRelaxed)
  core.ownsManager = true

  SkipListMap[K, V, MaxThreads, MaxLevel](core: core)

proc newSkipListMap*[
    K, V;
    MaxThreads: static int = DefaultMaxThreads,
    MaxLevel: static int = DefaultMaxLevel
](
    manager: ptr DebraManager[MaxThreads, ccMulti]
): SkipListMap[K, V, MaxThreads, MaxLevel] =
  ## Constructs a new empty `SkipListMap` sharing an external `DebraManager`.
  let core = cast[ptr SkipListCore[K, V, MaxThreads, MaxLevel]](
    allocShared0(sizeof(SkipListCore[K, V, MaxThreads, MaxLevel]))
  )
  let head = cast[ptr SkipListNode[K, V, MaxLevel]](
    allocShared0(sizeof(SkipListNode[K, V, MaxLevel]))
  )
  let tail = cast[ptr SkipListNode[K, V, MaxLevel]](
    allocShared0(sizeof(SkipListNode[K, V, MaxLevel]))
  )
  head.isHead = true
  head.topLevel = MaxLevel - 1
  tail.isTail = true
  tail.topLevel = MaxLevel - 1

  for level in 0 ..< MaxLevel:
    head.next[level].store(toEntry(tail, false), moRelaxed)
    tail.next[level].store(toEntry(nil, false), moRelaxed)

  core.id = allocSkipListId()
  core.head = head
  core.tail = tail
  core.manager = manager
  core.count.store(0, moRelaxed)
  core.rc.store(1, moRelaxed)
  core.ownsManager = false

  SkipListMap[K, V, MaxThreads, MaxLevel](core: core)

proc initSkipListMap*[
    K, V;
    MaxThreads: static int = DefaultMaxThreads,
    MaxLevel: static int = DefaultMaxLevel
](): SkipListMap[K, V, MaxThreads, MaxLevel] {.inline.} =
  newSkipListMap[K, V, MaxThreads, MaxLevel]()

proc `=destroy`*[K, V; MaxThreads, MaxLevel: static int](
    self: var SkipListMap[K, V, MaxThreads, MaxLevel]
) {.gcsafe.} =
  if self.core != nil:
    if self.core.rc.fetchSub(1, moRelease) == 1:
      threadFence(moAcquire)
      var curr = toPtr[SkipListNode[K, V, MaxLevel]](self.core.head.next[0].load(moRelaxed))
      while curr != nil and curr != self.core.tail:
        let nextEntry = curr.next[0].load(moRelaxed)
        let nextPtr = toPtr[SkipListNode[K, V, MaxLevel]](nextEntry)
        freeNodeDirect(curr)
        curr = nextPtr
      freeNodeDirect(self.core.head)
      freeNodeDirect(self.core.tail)
      if self.core.ownsManager and self.core.manager != nil:
        reset(self.core.manager[])
        freeAligned(self.core.manager)
      deallocShared(self.core)
    self.core = nil

proc `=copy`*[K, V; MaxThreads, MaxLevel: static int](
    dest: var SkipListMap[K, V, MaxThreads, MaxLevel],
    src: SkipListMap[K, V, MaxThreads, MaxLevel]
) =
  if dest.core != src.core:
    `=destroy`(dest)
    dest.core = src.core
    if dest.core != nil:
      discard dest.core.rc.fetchAdd(1, moRelaxed)

# ---------------------------------------------------------------------------
# Internal Fraser / Herlihy `find` Operation
# ---------------------------------------------------------------------------

proc find[K, V; MaxThreads, MaxLevel: static int](
    self: SkipListMap[K, V, MaxThreads, MaxLevel],
    key: K,
    preds: var array[MaxLevel, ptr SkipListNode[K, V, MaxLevel]],
    succs: var array[MaxLevel, ptr SkipListNode[K, V, MaxLevel]],
    ready: var RetireReady[MaxThreads, ccMulti]
): bool {.notATransition.} =
  while true:
    var pred = self.core.head
    var restart = false
    for level in countdown(MaxLevel - 1, 0):
      if restart:
        break
      var currEntry = pred.next[level].load(moAcquire)
      var curr = toPtr[SkipListNode[K, V, MaxLevel]](currEntry)
      while true:
        if curr == nil:
          break
        let succEntry = curr.next[level].load(moAcquire)
        let succ = toPtr[SkipListNode[K, V, MaxLevel]](succEntry)
        let marked = isMarked(succEntry)
        if marked:
          var expected = toEntry(curr, false)
          let desired = toEntry(succ, false)
          if not pred.next[level].compareExchange(expected, desired, moAcquireRelease, moAcquire):
            restart = true
            break
          if level == 0:
            ready.retire(cast[pointer](curr), destroyNodeCallback[K, V, MaxLevel])
          curr = succ
        else:
          if cmpNodeKey(curr, key) < 0:
            pred = curr
            curr = succ
          else:
            break
      preds[level] = pred
      succs[level] = curr
    if restart:
      continue
    return (succs[0] != nil and not succs[0].isTail and not succs[0].isHead and cmpNodeKey(succs[0], key) == 0)

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc len*[K, V; MaxThreads, MaxLevel: static int](
    self: SkipListMap[K, V, MaxThreads, MaxLevel]
): int {.inline.} =
  ## Returns the number of items currently in the map.
  if self.core == nil: 0
  else: max(0, self.core.count.load(moRelaxed))

proc registerThread*[K, V; MaxThreads, MaxLevel: static int](
    self: var SkipListMap[K, V, MaxThreads, MaxLevel]
): ThreadHandle[MaxThreads, ccMulti] {.inline.} =
  ## Explicitly registers the calling thread with the map's Debra manager.
  registerThread(self.core.manager[])

proc unregisterThread*[K, V; MaxThreads, MaxLevel: static int](
    self: var SkipListMap[K, V, MaxThreads, MaxLevel],
    handle: ThreadHandle[MaxThreads, ccMulti]
) {.inline.} =
  ## Unregisters the thread handle, releasing its slot in the Debra registry.
  unregisterThread(self.core.manager[], handle)

proc get*[K, V; MaxThreads, MaxLevel: static int](
    self: SkipListMap[K, V, MaxThreads, MaxLevel],
    key: K,
    handle: ThreadHandle[MaxThreads, ccMulti]
): Option[V] =
  ## Looks up `key` in the map using the provided thread handle. Wait-free
  ## population guarantee: does not perform CAS or mutate state.
  let pinned = unpinned(handle).pin()
  try:
    var pred = self.core.head
    var curr: ptr SkipListNode[K, V, MaxLevel] = nil
    for level in countdown(MaxLevel - 1, 0):
      var currEntry = pred.next[level].load(moAcquire)
      curr = toPtr[SkipListNode[K, V, MaxLevel]](currEntry)
      while curr != nil and curr != self.core.tail:
        let succEntry = curr.next[level].load(moAcquire)
        let succ = toPtr[SkipListNode[K, V, MaxLevel]](succEntry)
        if cmpNodeKey(curr, key) < 0:
          pred = curr
          curr = succ
        else:
          break
    let target = curr
    if target != nil and not target.isTail and not target.isHead and cmpNodeKey(target, key) == 0:
      let succ0 = target.next[0].load(moAcquire)
      if not isMarked(succ0):
        let box = target.valPtr.load(moAcquire)
        if box != nil:
          return some(box.val)
    return none(V)
  finally:
    unpinGuard(pinned)

proc get*[K, V; MaxThreads, MaxLevel: static int](
    self: SkipListMap[K, V, MaxThreads, MaxLevel],
    key: K
): Option[V] {.inline.} =
  ## Looks up `key` in the map using automatic thread registration.
  let h = self.getOrRegisterHandle()
  self.get(key, h)

proc `[]`*[K, V; MaxThreads, MaxLevel: static int](
    self: SkipListMap[K, V, MaxThreads, MaxLevel],
    key: K
): V {.inline.} =
  ## Returns the value associated with `key`. Raises `KeyError` if absent.
  let opt = self.get(key)
  if opt.isSome:
    return opt.get
  raise newException(KeyError, "key not found in SkipListMap")

proc getOrDefault*[K, V; MaxThreads, MaxLevel: static int](
    self: SkipListMap[K, V, MaxThreads, MaxLevel],
    key: K,
    defaultVal: V = default(V)
): V {.inline.} =
  ## Returns the value associated with `key`, or `defaultVal` if absent.
  let opt = self.get(key)
  if opt.isSome: opt.get else: defaultVal

proc contains*[K, V; MaxThreads, MaxLevel: static int](
    self: SkipListMap[K, V, MaxThreads, MaxLevel],
    key: K,
    handle: ThreadHandle[MaxThreads, ccMulti]
): bool {.inline.} =
  ## Returns true if `key` is present in the map.
  self.get(key, handle).isSome

proc contains*[K, V; MaxThreads, MaxLevel: static int](
    self: SkipListMap[K, V, MaxThreads, MaxLevel],
    key: K
): bool {.inline.} =
  ## Returns true if `key` is present in the map (auto-dispatched thread
  ## handle).
  self.get(key).isSome

proc put*[K, V; MaxThreads, MaxLevel: static int](
    self: var SkipListMap[K, V, MaxThreads, MaxLevel],
    key: K,
    val: V,
    handle: ThreadHandle[MaxThreads, ccMulti]
): bool =
  ## Inserts or updates `(key, val)`. Returns `true` if a new key was inserted,
  ## `false` if an existing key was updated.
  let pinned = unpinned(handle).pin()
  var ready = retireReady(pinned)
  try:
    var preds: array[MaxLevel, ptr SkipListNode[K, V, MaxLevel]]
    var succs: array[MaxLevel, ptr SkipListNode[K, V, MaxLevel]]
    let topLevel = randomLevel(MaxLevel)

    while true:
      let found = self.find(key, preds, succs, ready)
      if found:
        let existingNode = succs[0]
        let newBox = newVBox(val)
        var oldBox = existingNode.valPtr.load(moAcquire)
        var updated = false
        while true:
          if isMarked(existingNode.next[0].load(moAcquire)):
            freeVBox(newBox)
            break
          if existingNode.valPtr.compareExchange(oldBox, newBox, moAcquireRelease, moAcquire):
            ready.retire(cast[pointer](oldBox), destroyVBoxCallback[V])
            handle.advanceEvery(32)
            updated = true
            break
        if updated:
          return false
        continue

      let newNode = cast[ptr SkipListNode[K, V, MaxLevel]](
        allocShared0(sizeof(SkipListNode[K, V, MaxLevel]))
      )
      newNode.isHead = false
      newNode.isTail = false
      newNode.topLevel = topLevel
      wasMoved(newNode.key)
      newNode.key = key
      newNode.valPtr.store(newVBox(val), moRelaxed)

      for level in 0 .. topLevel:
        newNode.next[level].store(toEntry(succs[level], false), moRelaxed)

      let pred0 = preds[0]
      let succ0 = succs[0]
      var expected0 = toEntry(succ0, false)
      let desired0 = toEntry(newNode, false)
      if not pred0.next[0].compareExchange(expected0, desired0, moAcquireRelease, moAcquire):
        freeVBox(newNode.valPtr.load(moRelaxed))
        when not (K is SomeNumber or K is bool or K is char or K is pointer or K is ptr):
          `=destroy`(newNode.key)
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
          discard self.find(key, preds, succs, ready)

      handle.advanceEvery(32)
      return true
  finally:
    unpinGuard(toPinned(ready))

proc put*[K, V; MaxThreads, MaxLevel: static int](
    self: var SkipListMap[K, V, MaxThreads, MaxLevel],
    key: K,
    val: V
): bool {.inline.} =
  ## Inserts or updates `(key, val)` using automatic thread registration.
  let h = self.getOrRegisterHandle()
  self.put(key, val, h)

proc `[]=`*[K, V; MaxThreads, MaxLevel: static int](
    self: var SkipListMap[K, V, MaxThreads, MaxLevel],
    key: K,
    val: V
) {.inline.} =
  ## Table assignment syntax `map[key] = val`.
  discard self.put(key, val)

proc delete*[K, V; MaxThreads, MaxLevel: static int](
    self: var SkipListMap[K, V, MaxThreads, MaxLevel],
    key: K,
    handle: ThreadHandle[MaxThreads, ccMulti]
): bool =
  ## Logically marks and physically splices `key` out of the map. Returns `true`
  ## if `key` was found and removed, `false` otherwise.
  let pinned = unpinned(handle).pin()
  var ready = retireReady(pinned)
  try:
    var preds: array[MaxLevel, ptr SkipListNode[K, V, MaxLevel]]
    var succs: array[MaxLevel, ptr SkipListNode[K, V, MaxLevel]]

    while true:
      let found = self.find(key, preds, succs, ready)
      if not found:
        return false
      let nodeToDelete = succs[0]

      for level in countdown(nodeToDelete.topLevel, 1):
        var succEntry = nodeToDelete.next[level].load(moAcquire)
        while not isMarked(succEntry):
          let succPtr = toPtr[SkipListNode[K, V, MaxLevel]](succEntry)
          let markedEntry = toEntry(succPtr, true)
          if nodeToDelete.next[level].compareExchange(succEntry, markedEntry, moAcquireRelease, moAcquire):
            break
          succEntry = nodeToDelete.next[level].load(moAcquire)

      var succEntry0 = nodeToDelete.next[0].load(moAcquire)
      while true:
        if isMarked(succEntry0):
          return false
        let succPtr0 = toPtr[SkipListNode[K, V, MaxLevel]](succEntry0)
        let markedEntry0 = toEntry(succPtr0, true)
        if nodeToDelete.next[0].compareExchange(succEntry0, markedEntry0, moAcquireRelease, moAcquire):
          discard self.core.count.fetchSub(1, moRelaxed)
          discard self.find(key, preds, succs, ready)
          handle.advanceEvery(32)
          return true
        succEntry0 = nodeToDelete.next[0].load(moAcquire)
  finally:
    unpinGuard(toPinned(ready))

proc delete*[K, V; MaxThreads, MaxLevel: static int](
    self: var SkipListMap[K, V, MaxThreads, MaxLevel],
    key: K
): bool {.inline.} =
  ## Deletes `key` using automatic thread registration.
  let h = self.getOrRegisterHandle()
  self.delete(key, h)

proc del*[K, V; MaxThreads, MaxLevel: static int](
    self: var SkipListMap[K, V, MaxThreads, MaxLevel],
    key: K
) {.inline.} =
  ## Table deletion syntax `del(map, key)`.
  discard self.delete(key)

proc computeIfAbsent*[K, V; MaxThreads, MaxLevel: static int](
    self: var SkipListMap[K, V, MaxThreads, MaxLevel],
    key: K,
    fn: proc(k: K): V {.closure, gcsafe.},
    handle: ThreadHandle[MaxThreads, ccMulti]
): V =
  ## If `key` is not already associated with a value, attempts to compute its
  ## value using `fn(key)` and enters it into the map. Returns current value.
  let existing = self.get(key, handle)
  if existing.isSome:
    return existing.get

  let newVal = fn(key)
  let pinned = unpinned(handle).pin()
  var ready = retireReady(pinned)
  try:
    var preds: array[MaxLevel, ptr SkipListNode[K, V, MaxLevel]]
    var succs: array[MaxLevel, ptr SkipListNode[K, V, MaxLevel]]
    let topLevel = randomLevel(MaxLevel)

    while true:
      let found = self.find(key, preds, succs, ready)
      if found:
        let existingNode = succs[0]
        let box = existingNode.valPtr.load(moAcquire)
        if box != nil:
          return box.val
        continue

      let newNode = cast[ptr SkipListNode[K, V, MaxLevel]](
        allocShared0(sizeof(SkipListNode[K, V, MaxLevel]))
      )
      newNode.isHead = false
      newNode.isTail = false
      newNode.topLevel = topLevel
      wasMoved(newNode.key)
      newNode.key = key
      newNode.valPtr.store(newVBox(newVal), moRelaxed)

      for level in 0 .. topLevel:
        newNode.next[level].store(toEntry(succs[level], false), moRelaxed)

      let pred0 = preds[0]
      let succ0 = succs[0]
      var expected0 = toEntry(succ0, false)
      let desired0 = toEntry(newNode, false)
      if not pred0.next[0].compareExchange(expected0, desired0, moAcquireRelease, moAcquire):
        freeVBox(newNode.valPtr.load(moRelaxed))
        when not (K is SomeNumber or K is bool or K is char or K is pointer or K is ptr):
          `=destroy`(newNode.key)
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
          discard self.find(key, preds, succs, ready)

      handle.advanceEvery(32)
      return newVal
  finally:
    unpinGuard(toPinned(ready))

proc computeIfAbsent*[K, V; MaxThreads, MaxLevel: static int](
    self: var SkipListMap[K, V, MaxThreads, MaxLevel],
    key: K,
    fn: proc(k: K): V {.closure, gcsafe.}
): V {.inline.} =
  let h = self.getOrRegisterHandle()
  self.computeIfAbsent(key, fn, h)

proc computeIfAbsent*[K, V; MaxThreads, MaxLevel: static int](
    self: var SkipListMap[K, V, MaxThreads, MaxLevel],
    key: K,
    fn: proc(): V {.closure, gcsafe.}
): V {.inline.} =
  self.computeIfAbsent(key, proc(k: K): V = fn())

proc atomicUpdate*[K, V; MaxThreads, MaxLevel: static int](
    self: var SkipListMap[K, V, MaxThreads, MaxLevel],
    key: K,
    updateProc: proc(v: V): V {.closure, gcsafe.},
    handle: ThreadHandle[MaxThreads, ccMulti]
): Option[V] =
  ## Atomically transforms an existing value associated with `key` via in-place
  ## CAS on `node.valPtr`. If `key` is absent, returns `none(V)`.
  ## If `key` is present, updates `val` to `newVal = updateProc(oldVal)` and returns `some(newVal)`.
  ## Lock-free, O(log N) search + O(1) in-place value CAS.
  if unlikely(self.core == nil): return none(V)
  let pinned = unpinned(handle).pin()
  var ready = retireReady(pinned)
  var spins = InitialSpin
  try:
    var preds: array[MaxLevel, ptr SkipListNode[K, V, MaxLevel]]
    var succs: array[MaxLevel, ptr SkipListNode[K, V, MaxLevel]]

    while true:
      let found = self.find(key, preds, succs, ready)
      if not found:
        return none(V)

      let existingNode = succs[0]
      if isMarked(existingNode.next[0].load(moAcquire)):
        backoffOnRetry(spins)
        continue

      let oldBox = existingNode.valPtr.load(moAcquire)
      if oldBox == nil:
        backoffOnRetry(spins)
        continue

      let newVal = updateProc(oldBox.val)
      let newBox = newVBox(newVal)

      if isMarked(existingNode.next[0].load(moAcquire)):
        freeVBox(newBox)
        backoffOnRetry(spins)
        continue

      var expected = oldBox
      if existingNode.valPtr.compareExchange(expected, newBox, moAcquireRelease, moAcquire):
        ready.retire(cast[pointer](oldBox), destroyVBoxCallback[V])
        handle.advanceEvery(32)
        return some(newVal)
      else:
        freeVBox(newBox)
        backoffOnRetry(spins)
        continue
  finally:
    unpinGuard(toPinned(ready))

proc atomicUpdate*[K, V; MaxThreads, MaxLevel: static int](
    self: var SkipListMap[K, V, MaxThreads, MaxLevel],
    key: K,
    updateProc: proc(v: V): V {.closure, gcsafe.}
): Option[V] {.inline.} =
  let h = self.getOrRegisterHandle()
  self.atomicUpdate(key, updateProc, h)

proc upsert*[K, V; MaxThreads, MaxLevel: static int](
    self: var SkipListMap[K, V, MaxThreads, MaxLevel],
    key: K,
    insertVal: V,
    updateProc: proc(oldVal: V): V {.closure, gcsafe.},
    handle: ThreadHandle[MaxThreads, ccMulti]
): V =
  ## Atomically inserts `insertVal` if `key` is absent, or updates `key`
  ## with `updateProc(oldVal)` via in-place CAS if present.
  ## Returns the settled value.
  ## Lock-free.
  if unlikely(self.core == nil): return insertVal
  let pinned = unpinned(handle).pin()
  var ready = retireReady(pinned)
  var spins = InitialSpin
  try:
    var preds: array[MaxLevel, ptr SkipListNode[K, V, MaxLevel]]
    var succs: array[MaxLevel, ptr SkipListNode[K, V, MaxLevel]]
    let topLevel = randomLevel(MaxLevel)

    while true:
      let found = self.find(key, preds, succs, ready)
      if found:
        let existingNode = succs[0]
        if isMarked(existingNode.next[0].load(moAcquire)):
          backoffOnRetry(spins)
          continue

        let oldBox = existingNode.valPtr.load(moAcquire)
        if oldBox == nil:
          backoffOnRetry(spins)
          continue

        let newVal = updateProc(oldBox.val)
        let newBox = newVBox(newVal)

        if isMarked(existingNode.next[0].load(moAcquire)):
          freeVBox(newBox)
          backoffOnRetry(spins)
          continue

        var expected = oldBox
        if existingNode.valPtr.compareExchange(expected, newBox, moAcquireRelease, moAcquire):
          ready.retire(cast[pointer](oldBox), destroyVBoxCallback[V])
          handle.advanceEvery(32)
          return newVal
        else:
          freeVBox(newBox)
          backoffOnRetry(spins)
          continue

      # Not found: insert fresh node with insertVal
      let newNode = cast[ptr SkipListNode[K, V, MaxLevel]](
        allocShared0(sizeof(SkipListNode[K, V, MaxLevel]))
      )
      newNode.isHead = false
      newNode.isTail = false
      newNode.topLevel = topLevel
      wasMoved(newNode.key)
      newNode.key = key
      newNode.valPtr.store(newVBox(insertVal), moRelaxed)

      for level in 0 .. topLevel:
        newNode.next[level].store(toEntry(succs[level], false), moRelaxed)

      let pred0 = preds[0]
      let succ0 = succs[0]
      var expected0 = toEntry(succ0, false)
      let desired0 = toEntry(newNode, false)
      if not pred0.next[0].compareExchange(expected0, desired0, moAcquireRelease, moAcquire):
        freeVBox(newNode.valPtr.load(moRelaxed))
        when not (K is SomeNumber or K is bool or K is char or K is pointer or K is ptr):
          `=destroy`(newNode.key)
        deallocShared(newNode)
        backoffOnRetry(spins)
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
          discard self.find(key, preds, succs, ready)

      handle.advanceEvery(32)
      return insertVal
  finally:
    unpinGuard(toPinned(ready))

proc upsert*[K, V; MaxThreads, MaxLevel: static int](
    self: var SkipListMap[K, V, MaxThreads, MaxLevel],
    key: K,
    insertVal: V,
    updateProc: proc(oldVal: V): V {.closure, gcsafe.}
): V {.inline.} =
  let h = self.getOrRegisterHandle()
  self.upsert(key, insertVal, updateProc, h)

# ---------------------------------------------------------------------------
# Ordered Iterators (Ascending Level-0 Walk)
# ---------------------------------------------------------------------------

iterator pairs*[K, V; MaxThreads, MaxLevel: static int](
    self: SkipListMap[K, V, MaxThreads, MaxLevel],
    handle: ThreadHandle[MaxThreads, ccMulti]
): (K, V) =
  ## Iterates over all `(key, value)` pairs in strictly ascending key order.
  let pinned = unpinned(handle).pin()
  try:
    var currEntry = self.core.head.next[0].load(moAcquire)
    var curr = toPtr[SkipListNode[K, V, MaxLevel]](currEntry)
    while curr != nil and curr != self.core.tail:
      let succEntry = curr.next[0].load(moAcquire)
      if not isMarked(succEntry):
        let box = curr.valPtr.load(moAcquire)
        if box != nil:
          yield (curr.key, box.val)
      curr = toPtr[SkipListNode[K, V, MaxLevel]](succEntry)
  finally:
    unpinGuard(pinned)

iterator pairs*[K, V; MaxThreads, MaxLevel: static int](
    self: SkipListMap[K, V, MaxThreads, MaxLevel]
): (K, V) =
  ## Iterates over all `(key, value)` pairs in strictly ascending key order
  ## (auto handle).
  let h = self.getOrRegisterHandle()
  for p in self.pairs(h):
    yield p

iterator keys*[K, V; MaxThreads, MaxLevel: static int](
    self: SkipListMap[K, V, MaxThreads, MaxLevel]
): K =
  ## Iterates over all keys in strictly ascending order.
  for k, _ in self.pairs():
    yield k

iterator values*[K, V; MaxThreads, MaxLevel: static int](
    self: SkipListMap[K, V, MaxThreads, MaxLevel]
): V =
  ## Iterates over all values in strictly ascending key order.
  for _, v in self.pairs():
    yield v

iterator items*[K, V; MaxThreads, MaxLevel: static int](
    self: SkipListMap[K, V, MaxThreads, MaxLevel]
): (K, V) =
  ## Default iterator over key-value tuples.
  for p in self.pairs():
    yield p

proc snapshotPairs*[K, V; MaxThreads, MaxLevel: static int](
    self: SkipListMap[K, V, MaxThreads, MaxLevel],
    handle: ThreadHandle[MaxThreads, ccMulti]
): seq[(K, V)] =
  ## Returns a point-in-time materialized sequence of all (key, value) pairs
  ## in strictly ascending key order under Debra SMR protection.
  if unlikely(self.core == nil or self.core.head == nil): return @[]
  let pinned = unpinned(handle).pin()
  try:
    var res: seq[(K, V)] = @[]
    var currEntry = self.core.head.next[0].load(moAcquire)
    var curr = toPtr[SkipListNode[K, V, MaxLevel]](currEntry)
    while curr != nil and curr != self.core.tail:
      let succEntry = curr.next[0].load(moAcquire)
      if not isMarked(succEntry):
        let box = curr.valPtr.load(moAcquire)
        if box != nil:
          res.add((curr.key, box.val))
      curr = toPtr[SkipListNode[K, V, MaxLevel]](succEntry)
    return res
  finally:
    unpinGuard(pinned)

proc snapshotPairs*[K, V; MaxThreads, MaxLevel: static int](
    self: SkipListMap[K, V, MaxThreads, MaxLevel]
): seq[(K, V)] {.inline.} =
  let h = self.getOrRegisterHandle()
  self.snapshotPairs(h)

proc snapshotKeys*[K, V; MaxThreads, MaxLevel: static int](
    self: SkipListMap[K, V, MaxThreads, MaxLevel],
    handle: ThreadHandle[MaxThreads, ccMulti]
): seq[K] =
  ## Returns a point-in-time materialized sequence of all keys in strictly
  ## ascending key order under Debra SMR protection.
  if unlikely(self.core == nil or self.core.head == nil): return @[]
  let pinned = unpinned(handle).pin()
  try:
    var res: seq[K] = @[]
    var currEntry = self.core.head.next[0].load(moAcquire)
    var curr = toPtr[SkipListNode[K, V, MaxLevel]](currEntry)
    while curr != nil and curr != self.core.tail:
      let succEntry = curr.next[0].load(moAcquire)
      if not isMarked(succEntry):
        let box = curr.valPtr.load(moAcquire)
        if box != nil:
          res.add(curr.key)
      curr = toPtr[SkipListNode[K, V, MaxLevel]](succEntry)
    return res
  finally:
    unpinGuard(pinned)

proc snapshotKeys*[K, V; MaxThreads, MaxLevel: static int](
    self: SkipListMap[K, V, MaxThreads, MaxLevel]
): seq[K] {.inline.} =
  let h = self.getOrRegisterHandle()
  self.snapshotKeys(h)

proc snapshotValues*[K, V; MaxThreads, MaxLevel: static int](
    self: SkipListMap[K, V, MaxThreads, MaxLevel],
    handle: ThreadHandle[MaxThreads, ccMulti]
): seq[V] =
  ## Returns a point-in-time materialized sequence of all values in strictly
  ## ascending key order under Debra SMR protection.
  if unlikely(self.core == nil or self.core.head == nil): return @[]
  let pinned = unpinned(handle).pin()
  try:
    var res: seq[V] = @[]
    var currEntry = self.core.head.next[0].load(moAcquire)
    var curr = toPtr[SkipListNode[K, V, MaxLevel]](currEntry)
    while curr != nil and curr != self.core.tail:
      let succEntry = curr.next[0].load(moAcquire)
      if not isMarked(succEntry):
        let box = curr.valPtr.load(moAcquire)
        if box != nil:
          res.add(box.val)
      curr = toPtr[SkipListNode[K, V, MaxLevel]](succEntry)
    return res
  finally:
    unpinGuard(pinned)

proc snapshotValues*[K, V; MaxThreads, MaxLevel: static int](
    self: SkipListMap[K, V, MaxThreads, MaxLevel]
): seq[V] {.inline.} =
  let h = self.getOrRegisterHandle()
  self.snapshotValues(h)

# ---------------------------------------------------------------------------
# Constructor Aliases
# ---------------------------------------------------------------------------

proc newSortedTable*[
    K, V;
    MaxThreads: static int = DefaultMaxThreads,
    MaxLevel: static int = DefaultMaxLevel
](): SortedTable[K, V, MaxThreads, MaxLevel] {.inline.} =
  ## Smart constructor for `SortedTable[K, V]`.
  newSkipListMap[K, V, MaxThreads, MaxLevel]()

proc initSortedTable*[
    K, V;
    MaxThreads: static int = DefaultMaxThreads,
    MaxLevel: static int = DefaultMaxLevel
](): SortedTable[K, V, MaxThreads, MaxLevel] {.inline.} =
  ## Initializer for `SortedTable[K, V]`.
  initSkipListMap[K, V, MaxThreads, MaxLevel]()

proc newOrderedTable*[
    K, V;
    MaxThreads: static int = DefaultMaxThreads,
    MaxLevel: static int = DefaultMaxLevel
](): OrderedTable[K, V, MaxThreads, MaxLevel] {.inline.} =
  ## Smart constructor for `OrderedTable[K, V]`.
  newSkipListMap[K, V, MaxThreads, MaxLevel]()

proc initOrderedTable*[
    K, V;
    MaxThreads: static int = DefaultMaxThreads,
    MaxLevel: static int = DefaultMaxLevel
](): OrderedTable[K, V, MaxThreads, MaxLevel] {.inline.} =
  ## Initializer for `OrderedTable[K, V]`.
  initSkipListMap[K, V, MaxThreads, MaxLevel]()

proc newConcurrentSortedTable*[
    K, V;
    MaxThreads: static int = DefaultMaxThreads,
    MaxLevel: static int = DefaultMaxLevel
](): ConcurrentSortedTable[K, V, MaxThreads, MaxLevel] {.inline.} =
  ## Smart constructor for `ConcurrentSortedTable[K, V]`.
  newSkipListMap[K, V, MaxThreads, MaxLevel]()

proc initConcurrentSortedTable*[
    K, V;
    MaxThreads: static int = DefaultMaxThreads,
    MaxLevel: static int = DefaultMaxLevel
](): ConcurrentSortedTable[K, V, MaxThreads, MaxLevel] {.inline.} =
  ## Initializer for `ConcurrentSortedTable[K, V]`.
  initSkipListMap[K, V, MaxThreads, MaxLevel]()
