## Lock-Free Concurrent Priority Queue (`SkipListPriorityQueue[T]`).
##
## Implements the Lindén-Jonsson lock-free concurrent priority queue
## ("A Skiplist-Based Concurrent Priority Queue with Minimal Memory Contention",
## Jonatan Lindén & Bengt Jonsson, OPODIS 2013) backed by `DebraManager`
## (Neutralization-Based Reclamation / DEBRA+) for safe lock-free node reclamation.
##
## Key concurrency properties:
## - **Minimized Pop Contention**: `popMin` logically deletes the minimum node
##   by atomically flipping `node.deleted` (`false -> true`) along level 0 without
##   modifying `head.next[0]` on every pop.
## - **Batch Physical Restructuring**: When the prefix of logically deleted nodes
##   exceeds `DefaultRestructureThreshold` (or when the queue drains), the prefix
##   towers are marked from top level down to level 0 and physically spliced out
##   in a single multi-level pass, retiring unlinked nodes to `DebraManager`
##   strictly once on the thread that wins the level-0 unlink CAS.
## - **Strict FIFO Tie-Breaking**: Equal priorities are ordered deterministically
##   by a monotonically increasing 64-bit `seqId`, preserving all duplicate
##   priorities in insertion order.

when not compileOption("threads"):
  {.error: "lockfree/priority_queue requires --threads:on".}

import std/[options]
import pkg/typestates
import ./atomics
import ./backoff
import ./smr/nebr
import ./internal/aligned_alloc

export options

const
  DefaultPQueueMaxThreads* = 64
  DefaultPQueueMaxLevel* = 16
  DefaultRestructureThreshold* = 32
  MarkBit: uint = 1'u
  PtrMask: uint = not MarkBit

type
  Prioritized*[P, V] = object
    ## Key-value wrapper for priority queues where only `priority` participates
    ## in ordering and `value` can be any arbitrary type (including `pointer`,
    ## `ref`, or structs that do not implement `<` or `cmp`).
    priority*: P
    value*: V

  PQueueNode[T; MaxLevel: static int] = object
    key*: T
    seqId*: uint64
    topLevel*: int
    deleted*: Atomic[bool]
    inserting*: Atomic[bool]
    next*: array[MaxLevel, Atomic[uint]]

  SkipListPriorityQueueCore[T; MaxThreads: static int; MaxLevel: static int] = object
    id*: uint64
    head*: ptr PQueueNode[T, MaxLevel]
    tail*: ptr PQueueNode[T, MaxLevel]
    nextSeqId*: Atomic[uint64]
    restructuring*: Atomic[bool]
    rc*: Atomic[int]
    manager*: ptr DebraManager[MaxThreads, ccMulti]
    ownsManager*: bool

  SkipListPriorityQueue*[
    T;
    MaxThreads: static int = DefaultPQueueMaxThreads;
    MaxLevel: static int = DefaultPQueueMaxLevel;
  ] = object
    core*: ptr SkipListPriorityQueueCore[T, MaxThreads, MaxLevel]

  PriorityQueue*[
    T;
    MaxThreads: static int = DefaultPQueueMaxThreads;
    MaxLevel: static int = DefaultPQueueMaxLevel;
  ] = SkipListPriorityQueue[T, MaxThreads, MaxLevel]

  ConcurrentPriorityQueue*[
    T;
    MaxThreads: static int = DefaultPQueueMaxThreads;
    MaxLevel: static int = DefaultPQueueMaxLevel;
  ] = SkipListPriorityQueue[T, MaxThreads, MaxLevel]

  LockFreePriorityQueue*[
    T;
    MaxThreads: static int = DefaultPQueueMaxThreads;
    MaxLevel: static int = DefaultPQueueMaxLevel;
  ] = SkipListPriorityQueue[T, MaxThreads, MaxLevel]

proc `<`*[P, V](a, b: Prioritized[P, V]): bool {.inline.} =
  a.priority < b.priority

proc `<=`*[P, V](a, b: Prioritized[P, V]): bool {.inline.} =
  a.priority <= b.priority

proc `==`*[P, V](a, b: Prioritized[P, V]): bool {.inline.} =
  a.priority == b.priority

proc cmp*[P, V](a, b: Prioritized[P, V]): int {.inline.} =
  when compiles(system.cmp(a.priority, b.priority)):
    system.cmp(a.priority, b.priority)
  else:
    if a.priority < b.priority:
      -1
    elif b.priority < a.priority:
      1
    else:
      0

# ---------------------------------------------------------------------------
# Monotonic PriorityQueue ID Generator
# ---------------------------------------------------------------------------

var gNextPQueueId {.global.}: Atomic[uint64]

proc allocPQueueId(): uint64 {.inline.} =
  gNextPQueueId.fetchAdd(1'u64, moRelaxed) + 1'u64

# ---------------------------------------------------------------------------
# Pointer Marking Helpers
# ---------------------------------------------------------------------------

template isMarked(entry: uint): bool =
  (entry and MarkBit) != 0'u

template toPtr[T; MaxLevel: static int](entry: uint): ptr PQueueNode[T, MaxLevel] =
  cast[ptr PQueueNode[T, MaxLevel]](entry and PtrMask)

template toEntry[T; MaxLevel: static int](
    p: ptr PQueueNode[T, MaxLevel], marked: bool = false
): uint =
  cast[uint](p) or (if marked: MarkBit else: 0'u)

# ---------------------------------------------------------------------------
# SMR Typestate Conversion Helpers
# ---------------------------------------------------------------------------

proc toPinned[MaxThreads: static int, CC: static PinScopeCardinality](
    ready: RetireReady[MaxThreads, CC]
): Pinned[MaxThreads, CC] {.inline, notATransition.} =
  let ctx = RetireContext[MaxThreads, CC](ready)
  Pinned[MaxThreads, CC](
    EpochGuardContext[MaxThreads, CC](handle: ctx.handle, epoch: ctx.epoch)
  )

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
# Node Allocation & Reclamation Callbacks
# ---------------------------------------------------------------------------

proc allocNode[T; MaxLevel: static int](topLevel: int): ptr PQueueNode[T, MaxLevel] =
  result = cast[ptr PQueueNode[T, MaxLevel]](
    allocShared0(sizeof(PQueueNode[T, MaxLevel]))
  )
  result.topLevel = topLevel

proc freeNodeDirect[T; MaxLevel: static int](
    node: ptr PQueueNode[T, MaxLevel], destroyKey: bool = true
) {.gcsafe.} =
  if node != nil:
    if destroyKey:
      when not (T is SomeNumber or T is bool or T is char or T is pointer or T is ptr):
        {.cast(gcsafe).}:
          try:
            `=destroy`(node.key)
          except:
            discard
    deallocShared(node)

proc destroyNodeCallback[T; MaxLevel: static int](p: pointer) {.nimcall, raises: [].} =
  let node = cast[ptr PQueueNode[T, MaxLevel]](p)
  if node != nil:
    try:
      when not (T is SomeNumber or T is bool or T is char or T is pointer or T is ptr):
        {.cast(gcsafe).}:
          `=destroy`(node.key)
    except:
      discard
    deallocShared(node)

# ---------------------------------------------------------------------------
# Thread-Local Random Level Generator & DEBRA Handle Cache
# ---------------------------------------------------------------------------

type TlsPQueueHandleEntry = object
  pqId: uint64
  handleIdx: int

const MaxCachedTlsHandles = 32
var gTlsHandles {.threadvar.}: seq[TlsPQueueHandleEntry]
var gRngState {.threadvar.}: uint64

proc nextRandom(): uint64 {.inline.} =
  if gRngState == 0'u64:
    gRngState = cast[uint64](addr gRngState) xor 0x9E3779B97F4A7C15'u64
    if gRngState == 0'u64:
      gRngState = 0xCAFEBABE12345678'u64
  var x = gRngState
  x = x xor (x shl 13)
  x = x xor (x shr 7)
  x = x xor (x shl 17)
  gRngState = x
  result = x

proc randomLevel(maxLevel: int): int {.inline.} =
  var lvl = 0
  var r = nextRandom()
  while (r and 1'u64) == 1'u64 and lvl < maxLevel - 1:
    inc lvl
    r = r shr 1
  result = lvl

proc getOrRegisterHandle*[T; MaxThreads: static int; MaxLevel: static int](
    pq: SkipListPriorityQueue[T, MaxThreads, MaxLevel]
): ThreadHandle[MaxThreads, ccMulti] =
  let pqId = pq.core.id
  let manager = pq.core.manager
  for entry in gTlsHandles:
    if entry.pqId == pqId:
      return ThreadHandle[MaxThreads, ccMulti](idx: entry.handleIdx, manager: manager)
  let activeMask = manager.activeThreadMask.load(moAcquire)
  for idx in 0 ..< MaxThreads:
    if (activeMask and (1'u64 shl idx)) != 0'u64:
      if isCurrent(manager.threads[idx].threadId.load(moAcquire)):
        if gTlsHandles.len >= MaxCachedTlsHandles:
          gTlsHandles.delete(0)
        gTlsHandles.add(TlsPQueueHandleEntry(pqId: pqId, handleIdx: idx))
        return ThreadHandle[MaxThreads, ccMulti](idx: idx, manager: manager)
  let h = registerThread(manager[])
  if gTlsHandles.len >= MaxCachedTlsHandles:
    gTlsHandles.delete(0)
  gTlsHandles.add(TlsPQueueHandleEntry(pqId: pqId, handleIdx: h.idx))
  return h

proc registerThread*[T; MaxThreads: static int; MaxLevel: static int](
    pq: SkipListPriorityQueue[T, MaxThreads, MaxLevel]
) =
  ## Explicitly registers the calling thread with the priority queue's SMR manager.
  discard pq.getOrRegisterHandle()

proc unregisterThread*[T; MaxThreads: static int; MaxLevel: static int](
    pq: SkipListPriorityQueue[T, MaxThreads, MaxLevel]
) =
  ## Drains any pending retired nodes in the calling thread's limbo bags and
  ## unregisters the thread from the priority queue's SMR manager.
  if pq.core == nil or pq.core.manager == nil:
    return
  let pqId = pq.core.id
  let manager = pq.core.manager
  var foundIdx = -1
  for i in 0 ..< gTlsHandles.len:
    if gTlsHandles[i].pqId == pqId:
      foundIdx = gTlsHandles[i].handleIdx
      gTlsHandles.delete(i)
      break
  if foundIdx < 0:
    let activeMask = manager.activeThreadMask.load(moAcquire)
    for idx in 0 ..< MaxThreads:
      if (activeMask and (1'u64 shl idx)) != 0'u64:
        if isCurrent(manager.threads[idx].threadId.load(moAcquire)):
          foundIdx = idx
          break
  if foundIdx >= 0:
    var h = ThreadHandle[MaxThreads, ccMulti](idx: foundIdx, manager: manager)
    var spins = InitialSpin
    while manager.threads[foundIdx].limboBagTail != nil or
        manager.threads[foundIdx].currentBag != nil:
      discard manager.globalEpoch.fetchAdd(1'u64, moRelease)
      discard reclaimNow(h)
      if manager.threads[foundIdx].limboBagTail != nil or
          manager.threads[foundIdx].currentBag != nil:
        backoffOnRetry(spins)
    unregisterThread(manager[], h)

# ---------------------------------------------------------------------------
# Lifecycle & Constructors
# ---------------------------------------------------------------------------

proc `=destroy`*[T; MaxThreads: static int; MaxLevel: static int](
    self: var SkipListPriorityQueue[T, MaxThreads, MaxLevel]
) {.gcsafe.} =
  if self.core != nil:
    if self.core.rc.fetchSub(1, moRelease) == 1:
      threadFence(moAcquire)
      let pqId = self.core.id
      var i = 0
      while i < gTlsHandles.len:
        if gTlsHandles[i].pqId == pqId:
          gTlsHandles.delete(i)
        else:
          inc i

      if self.core.head != nil:
        var curr = toPtr[T, MaxLevel](self.core.head.next[0].load(moRelaxed))
        while curr != nil and curr != self.core.tail:
          let nextNode = toPtr[T, MaxLevel](curr.next[0].load(moRelaxed))
          freeNodeDirect(curr, destroyKey = true)
          curr = nextNode
        freeNodeDirect(self.core.head, destroyKey = false)
        self.core.head = nil

      if self.core.tail != nil:
        freeNodeDirect(self.core.tail, destroyKey = false)
        self.core.tail = nil

      if self.core.ownsManager and self.core.manager != nil:
        reset(self.core.manager[])
        freeAligned(self.core.manager)
        self.core.manager = nil

      deallocShared(self.core)
    self.core = nil

proc `=copy`*[T; MaxThreads: static int; MaxLevel: static int](
    dest: var SkipListPriorityQueue[T, MaxThreads, MaxLevel],
    src: SkipListPriorityQueue[T, MaxThreads, MaxLevel],
) =
  if dest.core != src.core:
    `=destroy`(dest)
    dest.core = src.core
    if dest.core != nil:
      discard dest.core.rc.fetchAdd(1, moRelaxed)

proc newSkipListPriorityQueue*[
    T;
    MaxThreads: static int = DefaultPQueueMaxThreads;
    MaxLevel: static int = DefaultPQueueMaxLevel;
](): SkipListPriorityQueue[T, MaxThreads, MaxLevel] =
  ## Allocates and initializes a new lock-free `SkipListPriorityQueue[T]`.
  static:
    doAssert MaxLevel >= 2 and MaxLevel <= 32, "MaxLevel must be in 2..32"
    doAssert MaxThreads >= 1 and MaxThreads <= 64, "MaxThreads must be in 1..64"

  let core = cast[ptr SkipListPriorityQueueCore[T, MaxThreads, MaxLevel]](
    allocShared0(sizeof(SkipListPriorityQueueCore[T, MaxThreads, MaxLevel]))
  )
  let mgr = allocAligned[DebraManager[MaxThreads, ccMulti]]()
  wasMoved(mgr[])
  mgr[] = initDebraManager[MaxThreads, ccMulti]()

  let head = allocNode[T, MaxLevel](MaxLevel - 1)
  let tail = allocNode[T, MaxLevel](MaxLevel - 1)
  head.deleted.store(false, moRelaxed)
  head.inserting.store(false, moRelaxed)
  tail.deleted.store(false, moRelaxed)
  tail.inserting.store(false, moRelaxed)

  let tailEntry = toEntry[T, MaxLevel](tail, false)
  for i in 0 ..< MaxLevel:
    head.next[i].store(tailEntry, moRelaxed)
    tail.next[i].store(0'u, moRelaxed)

  core.id = allocPQueueId()
  core.head = head
  core.tail = tail
  core.nextSeqId.store(0'u64, moRelaxed)
  core.restructuring.store(false, moRelaxed)
  core.rc.store(1, moRelaxed)
  core.manager = mgr
  core.ownsManager = true

  SkipListPriorityQueue[T, MaxThreads, MaxLevel](core: core)

proc initSkipListPriorityQueue*[
    T;
    MaxThreads: static int = DefaultPQueueMaxThreads;
    MaxLevel: static int = DefaultPQueueMaxLevel;
](): SkipListPriorityQueue[T, MaxThreads, MaxLevel] {.inline.} =
  ## Alias for `newSkipListPriorityQueue`.
  newSkipListPriorityQueue[T, MaxThreads, MaxLevel]()

proc newPriorityQueue*[
    T;
    MaxThreads: static int = DefaultPQueueMaxThreads;
    MaxLevel: static int = DefaultPQueueMaxLevel;
](): PriorityQueue[T, MaxThreads, MaxLevel] {.inline.} =
  newSkipListPriorityQueue[T, MaxThreads, MaxLevel]()

proc initPriorityQueue*[
    T;
    MaxThreads: static int = DefaultPQueueMaxThreads;
    MaxLevel: static int = DefaultPQueueMaxLevel;
](): PriorityQueue[T, MaxThreads, MaxLevel] {.inline.} =
  newSkipListPriorityQueue[T, MaxThreads, MaxLevel]()

proc newConcurrentPriorityQueue*[
    T;
    MaxThreads: static int = DefaultPQueueMaxThreads;
    MaxLevel: static int = DefaultPQueueMaxLevel;
](): ConcurrentPriorityQueue[T, MaxThreads, MaxLevel] {.inline.} =
  newSkipListPriorityQueue[T, MaxThreads, MaxLevel]()

proc newLockFreePriorityQueue*[
    T;
    MaxThreads: static int = DefaultPQueueMaxThreads;
    MaxLevel: static int = DefaultPQueueMaxLevel;
](): LockFreePriorityQueue[T, MaxThreads, MaxLevel] {.inline.} =
  newSkipListPriorityQueue[T, MaxThreads, MaxLevel]()

# ---------------------------------------------------------------------------
# Internal Ordering & Physical Unlinking
# ---------------------------------------------------------------------------

proc cmpPriority[T](a, b: T): int {.inline.} =
  when compiles(cmp(a, b)):
    cmp(a, b)
  else:
    if a < b:
      -1
    elif b < a:
      1
    else:
      0

proc compareNode[T; MaxLevel: static int](
    node: ptr PQueueNode[T, MaxLevel], key: T, seqId: uint64
): int {.inline.} =
  let c = cmpPriority(node.key, key)
  if c != 0:
    return c
  if node.seqId < seqId:
    -1
  elif node.seqId > seqId:
    1
  else:
    0

proc markNodeTower[T; MaxLevel: static int](
    node: ptr PQueueNode[T, MaxLevel]
): ptr PQueueNode[T, MaxLevel] {.inline.} =
  ## Marks `node.next[level]` from `node.topLevel` down to `0` with `MarkBit`.
  ## Returns the unmarked level-0 successor observed when `node.next[0]` was marked.
  for level in countdown(node.topLevel, 1):
    while true:
      let succEntry = node.next[level].load(moAcquire)
      if isMarked(succEntry):
        break
      var expected = succEntry
      let desired = succEntry or MarkBit
      if node.next[level].compareExchange(expected, desired, moAcquireRelease, moAcquire):
        break

  while true:
    let succEntry = node.next[0].load(moAcquire)
    if isMarked(succEntry):
      return toPtr[T, MaxLevel](succEntry)
    var expected = succEntry
    let desired = succEntry or MarkBit
    if node.next[0].compareExchange(expected, desired, moAcquireRelease, moAcquire):
      return toPtr[T, MaxLevel](succEntry)

proc find[T; MaxThreads: static int; MaxLevel: static int](
    pq: SkipListPriorityQueue[T, MaxThreads, MaxLevel],
    key: T,
    seqId: uint64,
    preds: var array[MaxLevel, ptr PQueueNode[T, MaxLevel]],
    succs: var array[MaxLevel, ptr PQueueNode[T, MaxLevel]],
    ready: var RetireReady[MaxThreads, ccMulti],
): bool {.notATransition.} =
  ## Traverses from `MaxLevel - 1` down to `0`, physically splicing out any
  ## nodes whose `next[level]` pointer carries `MarkBit`.
  ## Retires physically unlinked nodes to `DebraManager` strictly once on the
  ## thread that wins the `level == 0` unlink CAS.
  var spins = InitialSpin
  while true:
    var pred = pq.core.head
    var restart = false
    for level in countdown(MaxLevel - 1, 0):
      if restart:
        break
      var curr = toPtr[T, MaxLevel](pred.next[level].load(moAcquire))
      while true:
        if curr == pq.core.tail:
          break
        let succEntry = curr.next[level].load(moAcquire)
        let succ = toPtr[T, MaxLevel](succEntry)
        if isMarked(succEntry):
          var expected = toEntry[T, MaxLevel](curr, false)
          let desired = toEntry[T, MaxLevel](succ, false)
          if not pred.next[level].compareExchange(
            expected, desired, moAcquireRelease, moAcquire
          ):
            backoffOnRetry(spins)
            restart = true
            break
          if level == 0:
            ready.retire(cast[pointer](curr), destroyNodeCallback[T, MaxLevel])
          curr = succ
        else:
          let cmpRes = compareNode(curr, key, seqId)
          if cmpRes < 0:
            pred = curr
            curr = succ
          else:
            break
      preds[level] = pred
      succs[level] = curr
    if restart:
      continue
    return (succs[0] != pq.core.tail and compareNode(succs[0], key, seqId) == 0)

proc restructure[T; MaxThreads: static int; MaxLevel: static int](
    pq: SkipListPriorityQueue[T, MaxThreads, MaxLevel],
    ready: var RetireReady[MaxThreads, ccMulti],
) {.notATransition.} =
  ## Batch physical restructuring of the logically deleted prefix.
  ## Walks the contiguous prefix of logically deleted (`deleted == true`,
  ## `inserting == false`) nodes starting at `head.next[0]`, marks their towers
  ## top-down, and invokes `find` on the last marked node to splice the entire
  ## batch out of all skiplist levels and retire the nodes to DEBRA.
  var expectedRestruct = false
  if not pq.core.restructuring.compareExchange(
    expectedRestruct, true, moAcquireRelease, moAcquire
  ):
    return
  defer:
    pq.core.restructuring.store(false, moRelease)

  var curr = toPtr[T, MaxLevel](pq.core.head.next[0].load(moAcquire))
  var lastNode: ptr PQueueNode[T, MaxLevel] = nil
  var batchCount = 0
  const MaxBatchSize = DefaultRestructureThreshold * 4

  while curr != pq.core.tail and batchCount < MaxBatchSize:
    if not curr.deleted.load(moAcquire) or curr.inserting.load(moAcquire):
      break
    let nextNode = markNodeTower[T, MaxLevel](curr)
    lastNode = curr
    inc batchCount
    curr = nextNode

  if lastNode != nil:
    var preds: array[MaxLevel, ptr PQueueNode[T, MaxLevel]]
    var succs: array[MaxLevel, ptr PQueueNode[T, MaxLevel]]
    discard find(pq, lastNode.key, lastNode.seqId, preds, succs, ready)

# ---------------------------------------------------------------------------
# Public Priority Queue Operations
# ---------------------------------------------------------------------------

proc push*[T; MaxThreads: static int; MaxLevel: static int](
    pq: SkipListPriorityQueue[T, MaxThreads, MaxLevel], item: sink T
) =
  ## Inserts `item` into the priority queue.
  ## Duplicate priorities are preserved and popped in strict FIFO order.
  let handle = pq.getOrRegisterHandle()
  let pinned = unpinned(handle).pin()
  var ready = retireReady(pinned)
  defer:
    unpinGuard(toPinned(ready))

  let seqId = pq.core.nextSeqId.fetchAdd(1'u64, moRelaxed) + 1'u64
  let topLevel = randomLevel(MaxLevel)
  let newNode = allocNode[T, MaxLevel](topLevel)
  wasMoved(newNode.key)
  newNode.key = item
  newNode.seqId = seqId
  newNode.deleted.store(false, moRelaxed)
  newNode.inserting.store(true, moRelaxed)

  var preds: array[MaxLevel, ptr PQueueNode[T, MaxLevel]]
  var succs: array[MaxLevel, ptr PQueueNode[T, MaxLevel]]
  var spins = InitialSpin

  while true:
    discard find(pq, newNode.key, seqId, preds, succs, ready)
    for i in 0 .. topLevel:
      newNode.next[i].store(toEntry[T, MaxLevel](succs[i], false), moRelaxed)

    let pred0 = preds[0]
    let succ0 = succs[0]
    var expected0 = toEntry[T, MaxLevel](succ0, false)
    let desired0 = toEntry[T, MaxLevel](newNode, false)

    if pred0.next[0].compareExchange(expected0, desired0, moAcquireRelease, moAcquire):
      break
    backoffOnRetry(spins)

  for level in 1 .. topLevel:
    while true:
      let pred = preds[level]
      let succ = succs[level]
      let curNext = newNode.next[level].load(moAcquire)
      if isMarked(curNext):
        break
      if curNext != toEntry[T, MaxLevel](succ, false):
        newNode.next[level].store(toEntry[T, MaxLevel](succ, false), moRelaxed)

      var expected = toEntry[T, MaxLevel](succ, false)
      let desired = toEntry[T, MaxLevel](newNode, false)
      if pred.next[level].compareExchange(expected, desired, moAcquireRelease, moAcquire):
        break
      discard find(pq, newNode.key, seqId, preds, succs, ready)

  newNode.inserting.store(false, moRelease)
  handle.advanceEvery(32)

proc push*[P, V; MaxThreads: static int; MaxLevel: static int](
    pq: SkipListPriorityQueue[Prioritized[P, V], MaxThreads, MaxLevel],
    priority: P,
    value: sink V,
) {.inline.} =
  ## Convenience overload for pushing a `(priority, value)` pair into a
  ## `SkipListPriorityQueue[Prioritized[P, V]]`.
  pq.push(Prioritized[P, V](priority: priority, value: value))

proc popMin*[T; MaxThreads: static int; MaxLevel: static int](
    pq: SkipListPriorityQueue[T, MaxThreads, MaxLevel]
): Option[T] =
  ## Removes and returns the minimum element (`some(minItem)`), or `none(T)`
  ## if the priority queue is empty.
  ## Equal priorities are popped in strict FIFO insertion order.
  let handle = pq.getOrRegisterHandle()
  let pinned = unpinned(handle).pin()
  var ready = retireReady(pinned)
  defer:
    unpinGuard(toPinned(ready))

  var curr = toPtr[T, MaxLevel](pq.core.head.next[0].load(moAcquire))
  var hops = 0

  while curr != pq.core.tail:
    let succEntry = curr.next[0].load(moAcquire)
    let succ = toPtr[T, MaxLevel](succEntry)
    if isMarked(succEntry) or curr.deleted.load(moAcquire):
      inc hops
      curr = succ
      continue

    var expectedDel = false
    if curr.deleted.compareExchange(expectedDel, true, moAcquireRelease, moAcquire):
      let val = curr.key
      if hops >= DefaultRestructureThreshold:
        restructure(pq, ready)
        handle.advanceEvery(32)
      return some(val)

    inc hops
    curr = succ

  if hops > 0:
    restructure(pq, ready)
    handle.advanceEvery(32)
  return none(T)

proc tryPopMin*[T; MaxThreads: static int; MaxLevel: static int](
    pq: SkipListPriorityQueue[T, MaxThreads, MaxLevel], outVal: var T
): bool =
  ## Attempts to remove the minimum element into `outVal`.
  ## Returns `true` if an element was popped, or `false` if the queue is empty.
  let handle = pq.getOrRegisterHandle()
  let pinned = unpinned(handle).pin()
  var ready = retireReady(pinned)
  defer:
    unpinGuard(toPinned(ready))

  var curr = toPtr[T, MaxLevel](pq.core.head.next[0].load(moAcquire))
  var hops = 0

  while curr != pq.core.tail:
    let succEntry = curr.next[0].load(moAcquire)
    let succ = toPtr[T, MaxLevel](succEntry)
    if isMarked(succEntry) or curr.deleted.load(moAcquire):
      inc hops
      curr = succ
      continue

    var expectedDel = false
    if curr.deleted.compareExchange(expectedDel, true, moAcquireRelease, moAcquire):
      outVal = curr.key
      if hops >= DefaultRestructureThreshold:
        restructure(pq, ready)
        handle.advanceEvery(32)
      return true

    inc hops
    curr = succ

  if hops > 0:
    restructure(pq, ready)
    handle.advanceEvery(32)
  return false

proc peekMin*[T; MaxThreads: static int; MaxLevel: static int](
    pq: SkipListPriorityQueue[T, MaxThreads, MaxLevel]
): Option[T] =
  ## Returns the minimum element (`some(minItem)`) without removing it,
  ## or `none(T)` if the priority queue is empty.
  let handle = pq.getOrRegisterHandle()
  let pinned = unpinned(handle).pin()
  var ready = retireReady(pinned)
  defer:
    unpinGuard(toPinned(ready))

  var curr = toPtr[T, MaxLevel](pq.core.head.next[0].load(moAcquire))
  while curr != pq.core.tail:
    let succEntry = curr.next[0].load(moAcquire)
    if not isMarked(succEntry) and not curr.deleted.load(moAcquire):
      let val = curr.key
      if not curr.deleted.load(moAcquire):
        return some(val)
    curr = toPtr[T, MaxLevel](succEntry)
  return none(T)

template pop*[T; MaxThreads: static int, MaxLevel: static int](
    pq: SkipListPriorityQueue[T, MaxThreads, MaxLevel]
): untyped =
  pq.popMin()

template peek*[T; MaxThreads: static int, MaxLevel: static int](
    pq: SkipListPriorityQueue[T, MaxThreads, MaxLevel]
): untyped =
  pq.peekMin()

proc len*[T; MaxThreads: static int; MaxLevel: static int](
    pq: SkipListPriorityQueue[T, MaxThreads, MaxLevel]
): int =
  ## Returns the current number of active elements in the priority queue by
  ## traversing unmarked, non-deleted level-0 nodes under an SMR guard without
  ## maintaining a hot-path shared atomic counter.
  if pq.core == nil:
    return 0
  let firstEntry = pq.core.head.next[0].load(moAcquire)
  let firstNode = toPtr[T, MaxLevel](firstEntry)
  if firstNode == nil or firstNode == pq.core.tail:
    return 0
  let handle = pq.getOrRegisterHandle()
  let pinned = unpinned(handle).pin()
  try:
    var count = 0
    var curr = toPtr[T, MaxLevel](pq.core.head.next[0].load(moAcquire))
    while curr != nil and curr != pq.core.tail:
      let succEntry = curr.next[0].load(moAcquire)
      if not isMarked(succEntry) and not curr.deleted.load(moAcquire):
        inc count
      curr = toPtr[T, MaxLevel](succEntry)
    return count
  finally:
    unpinGuard(pinned)

proc isEmpty*[T; MaxThreads: static int; MaxLevel: static int](
    pq: SkipListPriorityQueue[T, MaxThreads, MaxLevel]
): bool =
  ## Returns `true` if the priority queue currently contains no active elements.
  if pq.core == nil:
    return true
  let firstEntry = pq.core.head.next[0].load(moAcquire)
  let firstNode = toPtr[T, MaxLevel](firstEntry)
  if firstNode == nil or firstNode == pq.core.tail:
    return true
  let handle = pq.getOrRegisterHandle()
  let pinned = unpinned(handle).pin()
  try:
    var curr = toPtr[T, MaxLevel](pq.core.head.next[0].load(moAcquire))
    while curr != nil and curr != pq.core.tail:
      let succEntry = curr.next[0].load(moAcquire)
      if not isMarked(succEntry) and not curr.deleted.load(moAcquire):
        return false
      curr = toPtr[T, MaxLevel](succEntry)
    return true
  finally:
    unpinGuard(pinned)

proc clear*[T; MaxThreads: static int; MaxLevel: static int](
    pq: SkipListPriorityQueue[T, MaxThreads, MaxLevel]
) =
  ## Removes all elements currently in the priority queue and triggers
  ## physical restructuring of the deleted prefix.
  var dummy: T
  while pq.tryPopMin(dummy):
    discard
  let handle = pq.getOrRegisterHandle()
  let pinned = unpinned(handle).pin()
  var ready = retireReady(pinned)
  defer:
    unpinGuard(toPinned(ready))
  restructure(pq, ready)
  handle.advanceEvery(32)

proc `$`*[T; MaxThreads: static int; MaxLevel: static int](
    pq: SkipListPriorityQueue[T, MaxThreads, MaxLevel]
): string =
  ## Formats the priority queue contents in ascending priority order.
  if pq.core == nil:
    return "SkipListPriorityQueue([])"
  let handle = pq.getOrRegisterHandle()
  let pinned = unpinned(handle).pin()
  var ready = retireReady(pinned)
  defer:
    unpinGuard(toPinned(ready))

  result = "SkipListPriorityQueue(["
  var first = true
  var curr = toPtr[T, MaxLevel](pq.core.head.next[0].load(moAcquire))
  while curr != pq.core.tail:
    let succEntry = curr.next[0].load(moAcquire)
    if not isMarked(succEntry) and not curr.deleted.load(moAcquire):
      let val = curr.key
      if not curr.deleted.load(moAcquire):
        if not first:
          result.add(", ")
        result.add($val)
        first = false
    curr = toPtr[T, MaxLevel](succEntry)
  result.add("])")
