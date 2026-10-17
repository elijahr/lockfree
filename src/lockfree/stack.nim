## ===========================================================================
## Concurrency Topology: MPMC (Multi-Producer Multi-Consumer) Lock-Free LIFO
## Stack with Elimination-Backoff
## ===========================================================================
##
## A high-performance, non-blocking MPMC LIFO stack based on the classic Treiber
## stack (Treiber, 1986) augmented with an Elimination-Backoff Array (Hendler,
## Shavit, Yerushalmi, 2004).
##
## Topology:
##   - Producers: Multi-Producer (MP) — concurrent lock-free push operations.
##   - Consumers: Multi-Consumer (MC) — concurrent lock-free pop operations.
##   - Ordering: LIFO (Last-In First-Out) linearizable semantics.
##   - Contention Management: Elimination-Backoff Array allows concurrent pairs
##     of push and pop operations to exchange payloads and cancel out without
##     touching the central stack top pointer.
##   - Memory Safety: Tagged atomic pointers (128-bit DWCAS) eliminate the ABA
##     problem on the stack top pointer; NEBR epoch-based safe memory
##     reclamation (DebraManager) and per-node claim synchronization guarantee
##     zero use-after-free, zero data races during concurrent preemption, and
##     tear-free reclamation under ARC, ORC, atomicArc, and refc memory managers.

import std/options
export options
import ./atomics
import ./atomics/backoff
import ./backoff
import ./internal/aligned_alloc

when compileOption("threads"):
  import ./smr/nebr
  import pkg/typestates

const
  EliminationCapacity* = 8
    ## Default number of collision slots in the Elimination-Backoff Array. Must
    ## be a power of 2 for fast modulo bitmasking.
  EliminationSpins* = 32
    ## Spin count for a pusher waiting in an elimination slot for a concurrent
    ## popper.
  DefaultStackMaxThreads* = 64
    ## Maximum concurrent threads registered with a stack's NEBR SMR manager.

  ElimStateEmpty = 0
  ElimStateBusy = 1
  ElimStateWaiting = 2
  ElimStateClaimed = 3
  ElimStateDone = 4

  NodeClaimFree = 0'i32
  NodeClaimPeek = 1'i32
  NodeClaimPopped = -1'i32

type
  StackNode[T] = object
    data: T
    next: Atomic[ptr StackNode[T]]
    claim: Atomic[int32]

  EliminationSlot[T] = object
    state {.align: CacheLineBytes.}: Atomic[int]
    value: T

  TreiberStack*[T] = object
    top {.align: CacheLineBytes.}: Atomic[Pair[uint64, uint64]]
    count {.align: CacheLineBytes.}: Atomic[int]
    smr {.align: CacheLineBytes.}: Atomic[pointer]
    elimination: array[EliminationCapacity, EliminationSlot[T]]

  Stack*[T] = TreiberStack[T]
  ConcurrentStack*[T] = TreiberStack[T]

when compileOption("threads"):
  type
    StackSmr = object
      id: uint64
      manager: ptr DebraManager[DefaultStackMaxThreads, ccMulti]

    TlsStackHandleEntry = object
      stackId: uint64
      handleIdx: int

  const MaxCachedTlsStackHandles = 32
  var gNextStackId {.global.}: Atomic[uint64]
  var gTlsStackHandles {.threadvar.}: seq[TlsStackHandleEntry]

  proc allocStackId(): uint64 {.inline.} =
    gNextStackId.fetchAdd(1'u64, moRelaxed) + 1'u64

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

  proc ensureSmr[T](self: var TreiberStack[T]): ptr StackSmr {.inline.} =
    var p = cast[ptr StackSmr](self.smr.load(moAcquire))
    if p != nil:
      return p
    let fresh = cast[ptr StackSmr](allocShared0(sizeof(StackSmr)))
    fresh.id = allocStackId()
    fresh.manager = allocAligned[DebraManager[DefaultStackMaxThreads, ccMulti]]()
    fresh.manager[] = initDebraManager[DefaultStackMaxThreads, ccMulti]()
    var expected: pointer = nil
    if self.smr.compareExchange(expected, cast[pointer](fresh), moAcquireRelease, moAcquire):
      return fresh
    {.cast(gcsafe).}:
      reset(fresh.manager[])
    freeAligned(fresh.manager)
    deallocShared(fresh)
    return cast[ptr StackSmr](expected)

  proc getOrRegisterHandle[T](
      self: var TreiberStack[T]
  ): ThreadHandle[DefaultStackMaxThreads, ccMulti] {.inline.} =
    let smr = self.ensureSmr()
    let stackId = smr.id
    let manager = smr.manager
    for entry in gTlsStackHandles:
      if entry.stackId == stackId:
        return ThreadHandle[DefaultStackMaxThreads, ccMulti](
          idx: entry.handleIdx, manager: manager
        )
    let activeMask = manager.activeThreadMask.load(moAcquire)
    for idx in 0 ..< DefaultStackMaxThreads:
      if (activeMask and (1'u64 shl idx)) != 0'u64:
        if isCurrent(manager.threads[idx].threadId.load(moAcquire)):
          if gTlsStackHandles.len >= MaxCachedTlsStackHandles:
            gTlsStackHandles.delete(0)
          gTlsStackHandles.add(TlsStackHandleEntry(stackId: stackId, handleIdx: idx))
          return ThreadHandle[DefaultStackMaxThreads, ccMulti](idx: idx, manager: manager)
    let h = registerThread(manager[])
    if gTlsStackHandles.len >= MaxCachedTlsStackHandles:
      gTlsStackHandles.delete(0)
    gTlsStackHandles.add(TlsStackHandleEntry(stackId: stackId, handleIdx: h.idx))
    return h

  proc registerThread*[T](self: var TreiberStack[T]) =
    ## Explicitly registers the calling thread with the stack's NEBR SMR manager.
    discard self.getOrRegisterHandle()

  proc unregisterThread*[T](self: var TreiberStack[T]) =
    ## Drains any pending retired nodes in the calling thread's limbo bags and
    ## unregisters the thread from the stack's NEBR SMR manager.
    let smr = cast[ptr StackSmr](self.smr.load(moAcquire))
    if smr == nil or smr.manager == nil:
      return
    let stackId = smr.id
    let manager = smr.manager
    var foundIdx = -1
    for i in 0 ..< gTlsStackHandles.len:
      if gTlsStackHandles[i].stackId == stackId:
        foundIdx = gTlsStackHandles[i].handleIdx
        gTlsStackHandles.delete(i)
        break
    if foundIdx < 0:
      let activeMask = manager.activeThreadMask.load(moAcquire)
      for idx in 0 ..< DefaultStackMaxThreads:
        if (activeMask and (1'u64 shl idx)) != 0'u64:
          if isCurrent(manager.threads[idx].threadId.load(moAcquire)):
            foundIdx = idx
            break
    if foundIdx >= 0:
      var h = ThreadHandle[DefaultStackMaxThreads, ccMulti](idx: foundIdx, manager: manager)
      var spins = InitialSpin
      while manager.threads[foundIdx].limboBagTail != nil or
          manager.threads[foundIdx].currentBag != nil:
        discard manager.globalEpoch.fetchAdd(1'u64, moRelease)
        discard reclaimNow(h)
        if manager.threads[foundIdx].limboBagTail != nil or
            manager.threads[foundIdx].currentBag != nil:
          backoffOnRetry(spins)
      unregisterThread(manager[], h)

  proc reclaimStackNodeCallback[T](p: pointer) {.nimcall, raises: [].} =
    let node = cast[ptr StackNode[T]](p)
    if node != nil:
      freeAligned(node)

  proc claimNodeForPop[T](node: ptr StackNode[T]) {.inline.} =
    var exp = NodeClaimFree
    while not node.claim.compareExchange(exp, NodeClaimPopped, moAcquireRelease, moAcquire):
      cpuPause()
      exp = NodeClaimFree

var gThreadSeed {.threadvar.}: uint64

proc threadRandIndex(cap: static int): int {.inline.} =
  if gThreadSeed == 0:
    var local: int
    gThreadSeed = cast[uint64](addr local) xor 0x9e3779b97f4a7c15'u64
  # Xorshift64star
  gThreadSeed = gThreadSeed xor (gThreadSeed shr 12)
  gThreadSeed = gThreadSeed xor (gThreadSeed shl 25)
  gThreadSeed = gThreadSeed xor (gThreadSeed shr 27)
  let val = gThreadSeed * 0x2545F4914F6CDD1D'u64
  return int((val shr 32) and uint64(cap - 1))

proc allocNode[T](item: sink T): ptr StackNode[T] {.inline.} =
  result = allocAligned[StackNode[T]]()
  result.data = move(item)
  result.next.store(nil, moRelaxed)
  result.claim.store(NodeClaimFree, moRelaxed)

proc tryEliminatePush[T](self: var TreiberStack[T], item: var T): bool =
  let idx = threadRandIndex(EliminationCapacity)
  let slot = addr self.elimination[idx]

  var exp = ElimStateEmpty
  if not slot.state.compareExchange(exp, ElimStateBusy, moAcquire, moRelaxed):
    return false

  # Claimed slot exclusively. Install value and publish to poppers.
  slot.value = move(item)
  slot.state.store(ElimStateWaiting, moRelease)

  # Spin waiting for a peer popper
  for _ in 0 ..< EliminationSpins:
    let st = slot.state.load(moAcquire)
    if st == ElimStateDone:
      slot.state.store(ElimStateEmpty, moRelease)
      return true
    cpuPause()

  # Timeout: attempt to cancel (Waiting -> Busy)
  var expWait = ElimStateWaiting
  if slot.state.compareExchange(expWait, ElimStateBusy, moAcquireRelease, moRelaxed):
    item = move(slot.value)
    slot.state.store(ElimStateEmpty, moRelease)
    return false

  # Popper claimed the slot right at timeout boundary (state == Claimed)
  while slot.state.load(moAcquire) != ElimStateDone:
    cpuPause()

  slot.state.store(ElimStateEmpty, moRelease)
  return true

proc tryEliminatePop[T](self: var TreiberStack[T]): Option[T] =
  let idx = threadRandIndex(EliminationCapacity)
  let slot = addr self.elimination[idx]

  if slot.state.load(moAcquire) != ElimStateWaiting:
    return none(T)

  var expWait = ElimStateWaiting
  if not slot.state.compareExchange(expWait, ElimStateClaimed, moAcquireRelease, moRelaxed):
    return none(T)

  # Exclusively claimed: read value and signal completion
  var res = some(move(slot.value))
  slot.state.store(ElimStateDone, moRelease)
  return res

proc tryPushTreiber[T](self: var TreiberStack[T], node: ptr StackNode[T]): bool =
  var oldTop = self.top.load(moSequentiallyConsistent)
  node.next.store(cast[ptr StackNode[T]](oldTop.first), moRelease)
  let newTop = Pair[uint64, uint64](first: cast[uint64](node), second: oldTop.second + 1)
  if self.top.compareExchange(oldTop, newTop, moSequentiallyConsistent, moSequentiallyConsistent):
    discard self.count.fetchAdd(1, moRelaxed)
    return true
  return false

proc tryPopTreiber[T](self: var TreiberStack[T], item: var T): bool =
  when compileOption("threads"):
    let handle = self.getOrRegisterHandle()
    let pinned = unpinned(handle).pin()
    var ready = retireReady(pinned)
    defer:
      unpinGuard(toPinned(ready))

    var oldTop = self.top.load(moSequentiallyConsistent)
    while true:
      if oldTop.first == 0:
        return false
      let node = cast[ptr StackNode[T]](oldTop.first)
      let nextNode = node.next.load(moAcquire)
      let newTop = Pair[uint64, uint64](first: cast[uint64](nextNode), second: oldTop.second + 1)
      if self.top.compareExchange(oldTop, newTop, moSequentiallyConsistent, moSequentiallyConsistent):
        claimNodeForPop(node)
        item = move(node.data)
        ready.retire(cast[pointer](node), reclaimStackNodeCallback[T])
        handle.advanceEvery(32)
        discard self.count.fetchSub(1, moRelaxed)
        return true
      cpuPause()
      oldTop = self.top.load(moSequentiallyConsistent)
  else:
    var oldTop = self.top.load(moSequentiallyConsistent)
    while true:
      if oldTop.first == 0:
        return false
      let node = cast[ptr StackNode[T]](oldTop.first)
      let nextNode = node.next.load(moAcquire)
      let newTop = Pair[uint64, uint64](first: cast[uint64](nextNode), second: oldTop.second + 1)
      if self.top.compareExchange(oldTop, newTop, moSequentiallyConsistent, moSequentiallyConsistent):
        item = move(node.data)
        freeAligned(node)
        discard self.count.fetchSub(1, moRelaxed)
        return true
      cpuPause()
      oldTop = self.top.load(moSequentiallyConsistent)

proc push*[T](self: var TreiberStack[T], item: sink T) =
  ## Pushes an item onto the stack. Thread-safe, non-blocking MPMC.
  when compileOption("threads"):
    discard self.ensureSmr()
  var node = allocNode(item)
  if self.tryPushTreiber(node):
    return

  # Contention backoff path: try elimination array
  var spins = InitialSpin
  while true:
    if self.tryEliminatePush(node.data):
      reset(node.data)
      freeAligned(node)
      return

    if self.tryPushTreiber(node):
      return

    backoffOnRetry(spins)

proc push*[T](self: var TreiberStack[T], items: openArray[T]) =
  ## Pushes multiple items onto the stack in order.
  for item in items:
    self.push(item)

proc pop*[T](self: var TreiberStack[T]): Option[T] =
  ## Pops an item from the stack in LIFO order. Returns `some(item)` if
  ## available, or `none(T)` if the stack is empty.
  var val: T
  if self.tryPopTreiber(val):
    return some(val)

  # Check elimination array
  let elim = self.tryEliminatePop()
  if elim.isSome:
    return elim

  if self.top.load(moSequentiallyConsistent).first == 0:
    return none(T)

  var spins = InitialSpin
  while true:
    if self.tryPopTreiber(val):
      return some(val)
    let elimOpt = self.tryEliminatePop()
    if elimOpt.isSome:
      return elimOpt
    if self.top.load(moSequentiallyConsistent).first == 0:
      return none(T)
    backoffOnRetry(spins)

proc peek*[T](self: var TreiberStack[T]): Option[T] =
  ## Returns a copy of the item at the top of the stack without removing it, or
  ## `none(T)` if the stack is currently empty.
  when compileOption("threads"):
    let handle = self.getOrRegisterHandle()
    let pinned = unpinned(handle).pin()
    var ready = retireReady(pinned)
    defer:
      unpinGuard(toPinned(ready))

    var oldTop = self.top.load(moSequentiallyConsistent)
    while true:
      if oldTop.first == 0:
        return none(T)
      let node = cast[ptr StackNode[T]](oldTop.first)
      var expClaim = NodeClaimFree
      if node.claim.compareExchange(expClaim, NodeClaimPeek, moAcquireRelease, moAcquire):
        let curTop = self.top.load(moSequentiallyConsistent)
        if curTop == oldTop:
          let val = node.data
          node.claim.store(NodeClaimFree, moRelease)
          return some(val)
        node.claim.store(NodeClaimFree, moRelease)
        oldTop = curTop
      else:
        cpuPause()
        oldTop = self.top.load(moSequentiallyConsistent)
  else:
    let oldTop = self.top.load(moSequentiallyConsistent)
    if oldTop.first == 0:
      return none(T)
    let node = cast[ptr StackNode[T]](oldTop.first)
    return some(node.data)

proc peek*[T](self: TreiberStack[T]): Option[T] {.inline.} =
  cast[ptr TreiberStack[T]](unsafeAddr self)[].peek()

proc len*[T](self: var TreiberStack[T]): int {.inline.} =
  ## Returns the approximate number of items currently in the stack.
  let c = self.count.load(moAcquire)
  if c < 0: 0 else: c

proc len*[T](self: TreiberStack[T]): int {.inline.} =
  cast[ptr TreiberStack[T]](unsafeAddr self)[].len()

proc isEmpty*[T](self: var TreiberStack[T]): bool {.inline.} =
  ## Returns `true` if the stack is currently empty, `false` otherwise.
  self.top.load(moSequentiallyConsistent).first == 0

proc isEmpty*[T](self: TreiberStack[T]): bool {.inline.} =
  cast[ptr TreiberStack[T]](unsafeAddr self)[].isEmpty()

proc drain*[T](self: var TreiberStack[T]): seq[T] =
  ## Atomically detaches all items currently in the stack and returns them in
  ## LIFO order.
  when compileOption("threads"):
    let handle = self.getOrRegisterHandle()
    let pinned = unpinned(handle).pin()
    var ready = retireReady(pinned)
    defer:
      unpinGuard(toPinned(ready))

    var oldTop = self.top.load(moSequentiallyConsistent)
    while true:
      if oldTop.first == 0:
        return @[]
      let newTop = Pair[uint64, uint64](first: 0, second: oldTop.second + 1)
      if self.top.compareExchange(oldTop, newTop, moSequentiallyConsistent, moSequentiallyConsistent):
        var cur = cast[ptr StackNode[T]](oldTop.first)
        var drainedCount = 0
        while cur != nil:
          let next = cur.next.load(moAcquire)
          claimNodeForPop(cur)
          result.add(move(cur.data))
          ready.retire(cast[pointer](cur), reclaimStackNodeCallback[T])
          inc drainedCount
          cur = next
        handle.advanceEvery(32)
        discard self.count.fetchSub(drainedCount, moRelaxed)
        return result
      cpuPause()
      oldTop = self.top.load(moSequentiallyConsistent)
  else:
    var oldTop = self.top.load(moSequentiallyConsistent)
    while true:
      if oldTop.first == 0:
        return @[]
      let newTop = Pair[uint64, uint64](first: 0, second: oldTop.second + 1)
      if self.top.compareExchange(oldTop, newTop, moSequentiallyConsistent, moSequentiallyConsistent):
        var cur = cast[ptr StackNode[T]](oldTop.first)
        var drainedCount = 0
        while cur != nil:
          let next = cur.next.load(moAcquire)
          result.add(move(cur.data))
          freeAligned(cur)
          inc drainedCount
          cur = next
        discard self.count.fetchSub(drainedCount, moRelaxed)
        return result
      cpuPause()
      oldTop = self.top.load(moSequentiallyConsistent)

proc drainInto*[T](self: var TreiberStack[T], dest: var seq[T]) =
  ## Atomically detaches all items currently in the stack and appends them to
  ## `dest` in LIFO order.
  when compileOption("threads"):
    let handle = self.getOrRegisterHandle()
    let pinned = unpinned(handle).pin()
    var ready = retireReady(pinned)
    defer:
      unpinGuard(toPinned(ready))

    var oldTop = self.top.load(moSequentiallyConsistent)
    while true:
      if oldTop.first == 0:
        return
      let newTop = Pair[uint64, uint64](first: 0, second: oldTop.second + 1)
      if self.top.compareExchange(oldTop, newTop, moSequentiallyConsistent, moSequentiallyConsistent):
        var cur = cast[ptr StackNode[T]](oldTop.first)
        var drainedCount = 0
        while cur != nil:
          let next = cur.next.load(moAcquire)
          claimNodeForPop(cur)
          dest.add(move(cur.data))
          ready.retire(cast[pointer](cur), reclaimStackNodeCallback[T])
          inc drainedCount
          cur = next
        handle.advanceEvery(32)
        discard self.count.fetchSub(drainedCount, moRelaxed)
        return
      cpuPause()
      oldTop = self.top.load(moSequentiallyConsistent)
  else:
    var oldTop = self.top.load(moSequentiallyConsistent)
    while true:
      if oldTop.first == 0:
        return
      let newTop = Pair[uint64, uint64](first: 0, second: oldTop.second + 1)
      if self.top.compareExchange(oldTop, newTop, moSequentiallyConsistent, moSequentiallyConsistent):
        var cur = cast[ptr StackNode[T]](oldTop.first)
        var drainedCount = 0
        while cur != nil:
          let next = cur.next.load(moAcquire)
          dest.add(move(cur.data))
          freeAligned(cur)
          inc drainedCount
          cur = next
        discard self.count.fetchSub(drainedCount, moRelaxed)
        return
      cpuPause()
      oldTop = self.top.load(moSequentiallyConsistent)

proc initTreiberStack*[T](): TreiberStack[T] =
  ## Creates an empty `TreiberStack[T]`.
  when compileOption("threads"):
    discard result.ensureSmr()

proc newTreiberStack*[T](): TreiberStack[T] =
  ## Creates an empty `TreiberStack[T]`.
  when compileOption("threads"):
    discard result.ensureSmr()

proc initStack*[T](): Stack[T] =
  ## Creates an empty `Stack[T]`.
  when compileOption("threads"):
    discard result.ensureSmr()

proc newStack*[T](): Stack[T] =
  ## Creates an empty `Stack[T]`.
  when compileOption("threads"):
    discard result.ensureSmr()

proc newConcurrentStack*[T](): ref ConcurrentStack[T] =
  ## Allocates an empty `ConcurrentStack[T]` on the heap.
  new(result)
  when compileOption("threads"):
    discard result[].ensureSmr()

proc `=destroy`*[T](self: var TreiberStack[T]) =
  ## Cleans up all resources, freeing active and retired nodes.
  var curTop = cast[ptr StackNode[T]](self.top.load(moSequentiallyConsistent).first)
  while curTop != nil:
    let next = curTop.next.load(moRelaxed)
    reset(curTop.data)
    freeAligned(curTop)
    curTop = next
  self.top.store(Pair[uint64, uint64](first: 0, second: 0), moSequentiallyConsistent)
  self.count.store(0, moRelaxed)

  for i in 0 ..< EliminationCapacity:
    let st = self.elimination[i].state.load(moRelaxed)
    if st == ElimStateWaiting or st == ElimStateBusy:
      reset(self.elimination[i].value)
    self.elimination[i].state.store(ElimStateEmpty, moRelaxed)

  when compileOption("threads"):
    let smrPtr = cast[ptr StackSmr](self.smr.exchange(nil, moAcquireRelease))
    if smrPtr != nil:
      {.cast(gcsafe).}:
        let stackId = smrPtr.id
        var i = 0
        while i < gTlsStackHandles.len:
          if gTlsStackHandles[i].stackId == stackId:
            gTlsStackHandles.delete(i)
          else:
            inc i
        if smrPtr.manager != nil:
          reset(smrPtr.manager[])
          freeAligned(smrPtr.manager)
          smrPtr.manager = nil
      deallocShared(smrPtr)

proc `=copy`*[T](dest: var TreiberStack[T], src: TreiberStack[T]) {.error: "Copying a ConcurrentStack is disallowed; share via reference or pointer across threads.".}

