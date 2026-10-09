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
##     problem; internal cache-aligned node pooling guarantees zero
##     use-after-free and leak-free reclamation under ARC, ORC, and refc memory
##     managers.

import std/options
export options
import ./atomics
import ./atomics/backoff
import ./backoff
import ./internal/aligned_alloc

const
  EliminationCapacity* = 8
    ## Default number of collision slots in the Elimination-Backoff Array. Must
    ## be a power of 2 for fast modulo bitmasking.
  EliminationSpins* = 32
    ## Spin count for a pusher waiting in an elimination slot for a concurrent
    ## popper.

type
  StackNode[T] = object
    data: T
    next: ptr StackNode[T]

  ExchangeNode[T] = object
    value: T
    state: Atomic[int] # 0 = waiting, 1 = claimed, 2 = completed, 3 = cancelled

  EliminationSlot[T] = object
    node {.align: CacheLineBytes.}: Atomic[ptr ExchangeNode[T]]

  TreiberStack*[T] = object
    top {.align: CacheLineBytes.}: Atomic[Pair[uint64, uint64]]
    freeList {.align: CacheLineBytes.}: Atomic[Pair[uint64, uint64]]
    count {.align: CacheLineBytes.}: Atomic[int]
    elimination: array[EliminationCapacity, EliminationSlot[T]]

  Stack*[T] = TreiberStack[T]
  ConcurrentStack*[T] = TreiberStack[T]

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

proc popFromFreeList[T](self: var TreiberStack[T]): ptr StackNode[T] =
  var oldFree = self.freeList.load(moSequentiallyConsistent)
  while oldFree.first != 0:
    let node = cast[ptr StackNode[T]](oldFree.first)
    let nextNode = node.next
    let newFree = Pair[uint64, uint64](first: cast[uint64](nextNode), second: oldFree.second + 1)
    if self.freeList.compareExchange(oldFree, newFree, moSequentiallyConsistent, moSequentiallyConsistent):
      node.next = nil
      return node
    cpuPause()
    oldFree = self.freeList.load(moSequentiallyConsistent)
  return nil

proc recycleNode[T](self: var TreiberStack[T], node: ptr StackNode[T]) =
  var oldFree = self.freeList.load(moSequentiallyConsistent)
  while true:
    node.next = cast[ptr StackNode[T]](oldFree.first)
    let newFree = Pair[uint64, uint64](first: cast[uint64](node), second: oldFree.second + 1)
    if self.freeList.compareExchange(oldFree, newFree, moSequentiallyConsistent, moSequentiallyConsistent):
      return
    cpuPause()
    oldFree = self.freeList.load(moSequentiallyConsistent)

proc allocOrReuseNode[T](self: var TreiberStack[T], item: sink T): ptr StackNode[T] =
  result = self.popFromFreeList()
  if result == nil:
    result = allocAligned[StackNode[T]]()
  result.data = item
  result.next = nil

proc tryEliminatePush[T](self: var TreiberStack[T], item: var T): bool =
  let idx = threadRandIndex(EliminationCapacity)
  let slot = addr self.elimination[idx]

  if slot.node.load(moRelaxed) != nil:
    return false

  var myNode: ExchangeNode[T]
  myNode.value = item
  myNode.state.store(0, moRelaxed)

  var exp: ptr ExchangeNode[T] = nil
  if not slot.node.compareExchange(exp, addr myNode, moRelease, moRelaxed):
    reset(myNode.value)
    return false

  # Pusher is installed in slot, spin waiting for a peer popper
  for _ in 0 ..< EliminationSpins:
    let st = myNode.state.load(moAcquire)
    if st == 2:
      var clearExp: ptr ExchangeNode[T] = addr myNode
      discard slot.node.compareExchange(clearExp, nil, moRelease, moRelaxed)
      reset(item)
      return true
    cpuPause()

  # Timeout: attempt to cancel (0 -> 3)
  var expState = 0
  if myNode.state.compareExchange(expState, 3, moAcquireRelease, moRelaxed):
    var clearExp: ptr ExchangeNode[T] = addr myNode
    discard slot.node.compareExchange(clearExp, nil, moRelease, moRelaxed)
    reset(myNode.value)
    return false

  # Popper claimed the slot right at timeout boundary (state == 1)
  while myNode.state.load(moAcquire) != 2:
    cpuPause()

  var clearExp: ptr ExchangeNode[T] = addr myNode
  discard slot.node.compareExchange(clearExp, nil, moRelease, moRelaxed)
  reset(item)
  return true

proc tryEliminatePop[T](self: var TreiberStack[T]): Option[T] =
  let idx = threadRandIndex(EliminationCapacity)
  let slot = addr self.elimination[idx]

  let node = slot.node.load(moAcquire)
  if node == nil:
    return none(T)

  var expState = 0
  if not node.state.compareExchange(expState, 1, moAcquireRelease, moRelaxed):
    return none(T)

  # Exclusively claimed: read value and signal completion
  var res = some(move(node.value))
  node.state.store(2, moRelease)

  var clearExp: ptr ExchangeNode[T] = node
  discard slot.node.compareExchange(clearExp, nil, moRelease, moRelaxed)
  return res

proc tryPushTreiber[T](self: var TreiberStack[T], node: ptr StackNode[T]): bool =
  var oldTop = self.top.load(moSequentiallyConsistent)
  node.next = cast[ptr StackNode[T]](oldTop.first)
  let newTop = Pair[uint64, uint64](first: cast[uint64](node), second: oldTop.second + 1)
  if self.top.compareExchange(oldTop, newTop, moSequentiallyConsistent, moSequentiallyConsistent):
    discard self.count.fetchAdd(1, moRelaxed)
    return true
  return false

proc tryPopTreiber[T](self: var TreiberStack[T], item: var T): bool =
  var oldTop = self.top.load(moSequentiallyConsistent)
  while true:
    if oldTop.first == 0:
      return false
    let node = cast[ptr StackNode[T]](oldTop.first)
    let nextNode = node.next
    let newTop = Pair[uint64, uint64](first: cast[uint64](nextNode), second: oldTop.second + 1)
    if self.top.compareExchange(oldTop, newTop, moSequentiallyConsistent, moSequentiallyConsistent):
      item = move(node.data)
      self.recycleNode(node)
      discard self.count.fetchSub(1, moRelaxed)
      return true
    cpuPause()
    oldTop = self.top.load(moSequentiallyConsistent)

proc push*[T](self: var TreiberStack[T], item: sink T) =
  ## Pushes an item onto the stack. Thread-safe, non-blocking MPMC.
  var node = self.allocOrReuseNode(item)
  if self.tryPushTreiber(node):
    return

  # Contention backoff path: try elimination array
  var spins = InitialSpin
  while true:
    if self.tryEliminatePush(node.data):
      self.recycleNode(node)
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
  var oldTop = self.top.load(moSequentiallyConsistent)
  while true:
    if oldTop.first == 0:
      return none(T)
    let node = cast[ptr StackNode[T]](oldTop.first)
    let val = node.data
    let curTop = self.top.load(moSequentiallyConsistent)
    if curTop == oldTop:
      return some(val)
    oldTop = curTop
    cpuPause()

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
  var oldTop = self.top.load(moSequentiallyConsistent)
  while true:
    if oldTop.first == 0:
      return @[]
    let newTop = Pair[uint64, uint64](first: 0, second: oldTop.second + 1)
    if self.top.compareExchange(oldTop, newTop, moSequentiallyConsistent, moSequentiallyConsistent):
      var cur = cast[ptr StackNode[T]](oldTop.first)
      var drainedCount = 0
      while cur != nil:
        let next = cur.next
        result.add(move(cur.data))
        self.recycleNode(cur)
        inc drainedCount
        cur = next
      discard self.count.fetchSub(drainedCount, moRelaxed)
      return result
    cpuPause()
    oldTop = self.top.load(moSequentiallyConsistent)

proc drainInto*[T](self: var TreiberStack[T], dest: var seq[T]) =
  ## Atomically detaches all items currently in the stack and appends them to
  ## `dest` in LIFO order.
  var oldTop = self.top.load(moSequentiallyConsistent)
  while true:
    if oldTop.first == 0:
      return
    let newTop = Pair[uint64, uint64](first: 0, second: oldTop.second + 1)
    if self.top.compareExchange(oldTop, newTop, moSequentiallyConsistent, moSequentiallyConsistent):
      var cur = cast[ptr StackNode[T]](oldTop.first)
      var drainedCount = 0
      while cur != nil:
        let next = cur.next
        dest.add(move(cur.data))
        self.recycleNode(cur)
        inc drainedCount
        cur = next
      discard self.count.fetchSub(drainedCount, moRelaxed)
      return
    cpuPause()
    oldTop = self.top.load(moSequentiallyConsistent)

proc initTreiberStack*[T](): TreiberStack[T] =
  ## Creates an empty `TreiberStack[T]`.
  discard

proc newTreiberStack*[T](): TreiberStack[T] =
  ## Creates an empty `TreiberStack[T]`.
  discard

proc initStack*[T](): Stack[T] =
  ## Creates an empty `Stack[T]`.
  discard

proc newStack*[T](): Stack[T] =
  ## Creates an empty `Stack[T]`.
  discard

proc newConcurrentStack*[T](): ref ConcurrentStack[T] =
  ## Allocates an empty `ConcurrentStack[T]` on the heap.
  new(result)

proc `=destroy`*[T](self: var TreiberStack[T]) =
  ## Cleans up all resources, freeing active and pooled nodes.
  var curTop = cast[ptr StackNode[T]](self.top.load(moSequentiallyConsistent).first)
  while curTop != nil:
    let next = curTop.next
    reset(curTop.data)
    freeAligned(curTop)
    curTop = next
  self.top.store(Pair[uint64, uint64](first: 0, second: 0), moSequentiallyConsistent)

  var curFree = cast[ptr StackNode[T]](self.freeList.load(moSequentiallyConsistent).first)
  while curFree != nil:
    let next = curFree.next
    freeAligned(curFree)
    curFree = next
  self.freeList.store(Pair[uint64, uint64](first: 0, second: 0), moSequentiallyConsistent)
  self.count.store(0, moRelaxed)

proc `=copy`*[T](dest: var TreiberStack[T], src: TreiberStack[T]) {.error: "Copying a ConcurrentStack is disallowed; share via reference or pointer across threads.".}
