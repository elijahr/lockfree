## ===========================================================================
## Concurrency Topology: 128-Bit Hardware DWCAS Lock-Free LIFO Stack
## (`TaggedStack[T]` / `Stack128[T]`)
## ===========================================================================
##
## A high-performance, non-blocking MPMC LIFO stack that leverages hardware
## 128-Bit Double-Word Compare-And-Swap (DWCAS) to eliminate the ABA problem
## without requiring Safe Memory Reclamation (SMR) or thread registration.
##
## Key Properties:
## - **Hardware 128-Bit Atomic Top**: The stack top is represented as an
##   `Atomic[Pair[uint64, uint64]]` packing `[node_pointer | 64-bit ABA counter]`.
##   Every push and pop atomically updates the pointer and increments the 64-bit
##   generation counter in a single hardware instruction (`casp` on ARM64,
##   `cmpxchg16b` on x86_64).
## - **Zero SMR / Zero Debra**: SMR engines (Epoch-based or Hazard Pointers)
##   require threads to register, maintain TLS epoch handles, and pin/unpin on
##   every access. `TaggedStack` achieves memory safety via an internal lock-free
##   pooled freelist: popped nodes are recycled to an atomic freelist rather than
##   immediately deallocated to the OS. Because allocated node memory remains
##   valid for the lifetime of the stack, dereferencing `node.next` during a
##   concurrent pop race is guaranteed safe.
## - **Unbounded Growth**: When the freelist is empty, fresh nodes are allocated
##   on demand. On stack destruction (`=destroy`), all allocated nodes across both
##   the active stack and the freelist are reclaimed.
## - **Copy-Safe**: Explicitly marks `=copy` with `{.error.}` to prevent accidental
##   shallow-copy bugs.

import std/options
export options

import ./atomics
import ./atomics/backoff
import ./internal/aligned_alloc

when not supportsDwcas:
  {.error: "TaggedStack / Stack128 requires 128-bit hardware DWCAS support (x86_64 with -mcx16, aarch64 with LSE, or 64-bit vcc).".}

type
  TaggedStackNode[T] = object
    data: T
    next: ptr TaggedStackNode[T]

  TaggedHead = Pair[uint64, uint64]
    ## 16-byte aligned pair storing:
    ## - first:  node pointer cast to uint64 (0 if nil)
    ## - second: 64-bit monotonic ABA sequence counter

  TaggedStack*[T] = object
    ## MPMC Lock-Free LIFO Stack powered by 128-bit hardware DWCAS and pooled recycling.
    ## Thread-safe, non-blocking, and requires zero thread registration or epoch SMR.
    top* {.align: CacheLineBytes.}: Atomic[TaggedHead]
    freeList* {.align: CacheLineBytes.}: Atomic[TaggedHead]
    count* {.align: CacheLineBytes.}: Atomic[int]

  Stack128*[T] = TaggedStack[T]
    ## Semantic alias for `TaggedStack[T]`.

proc `=copy`*[T](dest: var TaggedStack[T], src: TaggedStack[T]) {.
  error: "TaggedStack contains inlined atomic state and cannot be copied. Pass by `var` or `ptr`."
.}

# ---------------------------------------------------------------------------
# Constructors & Lifecycle
# ---------------------------------------------------------------------------

proc initTaggedStack*[T](): TaggedStack[T] =
  ## Initializes an empty value-type `TaggedStack[T]`.
  result.top.store(Pair[uint64, uint64](first: 0'u64, second: 0'u64), moSequentiallyConsistent)
  result.freeList.store(Pair[uint64, uint64](first: 0'u64, second: 0'u64), moSequentiallyConsistent)
  result.count.store(0, moRelaxed)

proc initStack128*[T](): Stack128[T] {.inline.} =
  ## Initializes an empty value-type `Stack128[T]`. Alias for `initTaggedStack[T]()`.
  initTaggedStack[T]()

proc newTaggedStack*[T](): ptr TaggedStack[T] =
  ## Heap-allocates a cacheline-aligned `TaggedStack[T]`. Free with `freeTaggedStack`.
  result = allocAligned[TaggedStack[T]]()
  result[] = initTaggedStack[T]()

proc newStack128*[T](): ptr Stack128[T] {.inline.} =
  ## Heap-allocates a cacheline-aligned `Stack128[T]`. Alias for `newTaggedStack[T]()`.
  newTaggedStack[T]()

proc freeTaggedStack*[T](s: ptr TaggedStack[T]) =
  ## Releases a heap-allocated `TaggedStack[T]` instance created with `newTaggedStack`.
  if s != nil:
    `=destroy`(s[])
    freeAligned(s)

proc freeStack128*[T](s: ptr Stack128[T]) {.inline.} =
  freeTaggedStack[T](s)

# ---------------------------------------------------------------------------
# Node Recycling Freelist Helpers
# ---------------------------------------------------------------------------

proc popFreeNode[T](self: var TaggedStack[T]): ptr TaggedStackNode[T] {.inline.} =
  ## Tries to reuse a node from the pooled freelist via 128-bit CAS.
  var spins = InitialSpin
  var oldHead = self.freeList.load(moSequentiallyConsistent)
  while true:
    if oldHead.first == 0'u64:
      return nil
    let node = cast[ptr TaggedStackNode[T]](oldHead.first)
    let nextNode = node.next
    let newHead = Pair[uint64, uint64](first: cast[uint64](nextNode), second: oldHead.second + 1'u64)
    if self.freeList.compareExchangeWeak(oldHead, newHead, moSequentiallyConsistent, moSequentiallyConsistent):
      node.next = nil
      return node
    backoffOnRetry(spins)

proc pushFreeNode[T](self: var TaggedStack[T], node: ptr TaggedStackNode[T]) {.inline.} =
  ## Returns an unused node to the pooled freelist via 128-bit CAS.
  reset(node.data)
  var spins = InitialSpin
  var oldHead = self.freeList.load(moSequentiallyConsistent)
  while true:
    node.next = cast[ptr TaggedStackNode[T]](oldHead.first)
    let newHead = Pair[uint64, uint64](first: cast[uint64](node), second: oldHead.second + 1'u64)
    if self.freeList.compareExchangeWeak(oldHead, newHead, moSequentiallyConsistent, moSequentiallyConsistent):
      return
    backoffOnRetry(spins)

proc allocateNode[T](self: var TaggedStack[T], item: sink T): ptr TaggedStackNode[T] {.inline.} =
  result = self.popFreeNode()
  if result == nil:
    result = allocAligned[TaggedStackNode[T]]()
  result.data = move(item)
  result.next = nil

# ---------------------------------------------------------------------------
# Core Stack Operations
# ---------------------------------------------------------------------------

proc tryPush*[T](self: var TaggedStack[T], item: sink T): bool =
  ## Attempts to push an item onto the stack. Thread-safe and lock-free.
  ## Returns `true` on success.
  let node = self.allocateNode(item)
  var oldTop = self.top.load(moSequentiallyConsistent)
  node.next = cast[ptr TaggedStackNode[T]](oldTop.first)
  let newTop = Pair[uint64, uint64](first: cast[uint64](node), second: oldTop.second + 1'u64)
  if self.top.compareExchangeWeak(oldTop, newTop, moSequentiallyConsistent, moSequentiallyConsistent):
    discard self.count.fetchAdd(1, moRelaxed)
    return true
  # On contention, push node back to free list and report false (for speculative tryPush)
  self.pushFreeNode(node)
  return false

proc push*[T](self: var TaggedStack[T], item: sink T) =
  ## Pushes an item onto the stack, retrying with exponential backoff on contention.
  ## Thread-safe, non-blocking MPMC.
  let node = self.allocateNode(item)
  var spins = InitialSpin
  var oldTop = self.top.load(moSequentiallyConsistent)
  while true:
    node.next = cast[ptr TaggedStackNode[T]](oldTop.first)
    let newTop = Pair[uint64, uint64](first: cast[uint64](node), second: oldTop.second + 1'u64)
    if self.top.compareExchangeWeak(oldTop, newTop, moSequentiallyConsistent, moSequentiallyConsistent):
      discard self.count.fetchAdd(1, moRelaxed)
      return
    backoffOnRetry(spins)

proc push*[T](self: var TaggedStack[T], items: openArray[T]) =
  ## Pushes multiple items onto the stack in sequence.
  for item in items:
    self.push(item)

proc tryPop*[T](self: var TaggedStack[T], item: var T): bool =
  ## Attempts to pop an item from the stack in LIFO order.
  ## Returns `true` and assigns `item` if an element was popped; returns `false` if empty.
  var spins = InitialSpin
  var oldTop = self.top.load(moSequentiallyConsistent)
  while true:
    if oldTop.first == 0'u64:
      return false
    let node = cast[ptr TaggedStackNode[T]](oldTop.first)
    let nextNode = node.next
    let newTop = Pair[uint64, uint64](first: cast[uint64](nextNode), second: oldTop.second + 1'u64)
    if self.top.compareExchangeWeak(oldTop, newTop, moSequentiallyConsistent, moSequentiallyConsistent):
      item = move(node.data)
      self.pushFreeNode(node)
      discard self.count.fetchSub(1, moRelaxed)
      return true
    backoffOnRetry(spins)

proc pop*[T](self: var TaggedStack[T]): Option[T] =
  ## Pops an item from the stack in LIFO order. Returns `some(item)` if available,
  ## or `none(T)` if the stack is empty.
  var val: T
  if self.tryPop(val):
    return some(val)
  return none(T)

proc peek*[T](self: var TaggedStack[T]): Option[T] =
  ## Returns a copy of the item at the top of the stack without removing it,
  ## or `none(T)` if empty. Note that concurrent pops may race with peek.
  let oldTop = self.top.load(moSequentiallyConsistent)
  if oldTop.first == 0'u64:
    return none(T)
  let node = cast[ptr TaggedStackNode[T]](oldTop.first)
  return some(node.data)

proc peek*[T](self: TaggedStack[T]): Option[T] {.inline.} =
  cast[ptr TaggedStack[T]](unsafeAddr self)[].peek()

proc len*[T](self: var TaggedStack[T]): int {.inline.} =
  ## Returns the approximate number of items in the stack.
  let c = self.count.load(moAcquire)
  if c < 0: 0 else: c

proc len*[T](self: TaggedStack[T]): int {.inline.} =
  cast[ptr TaggedStack[T]](unsafeAddr self)[].len()

proc isEmpty*[T](self: var TaggedStack[T]): bool {.inline.} =
  ## Returns `true` if the stack is currently empty.
  self.top.load(moSequentiallyConsistent).first == 0'u64

proc isEmpty*[T](self: TaggedStack[T]): bool {.inline.} =
  cast[ptr TaggedStack[T]](unsafeAddr self)[].isEmpty()

proc clear*[T](self: var TaggedStack[T]) =
  ## Atomically detaches and discards all items currently in the stack.
  var spins = InitialSpin
  var oldTop = self.top.load(moSequentiallyConsistent)
  while true:
    if oldTop.first == 0'u64:
      return
    let newTop = Pair[uint64, uint64](first: 0'u64, second: oldTop.second + 1'u64)
    if self.top.compareExchangeWeak(oldTop, newTop, moSequentiallyConsistent, moSequentiallyConsistent):
      var cur = cast[ptr TaggedStackNode[T]](oldTop.first)
      var detachedCount = 0
      while cur != nil:
        let next = cur.next
        self.pushFreeNode(cur)
        inc detachedCount
        cur = next
      discard self.count.fetchSub(detachedCount, moRelaxed)
      return
    backoffOnRetry(spins)

proc drain*[T](self: var TaggedStack[T]): seq[T] =
  ## Atomically detaches all items from the stack and returns them in LIFO order.
  var spins = InitialSpin
  var oldTop = self.top.load(moSequentiallyConsistent)
  while true:
    if oldTop.first == 0'u64:
      return @[]
    let newTop = Pair[uint64, uint64](first: 0'u64, second: oldTop.second + 1'u64)
    if self.top.compareExchangeWeak(oldTop, newTop, moSequentiallyConsistent, moSequentiallyConsistent):
      var cur = cast[ptr TaggedStackNode[T]](oldTop.first)
      var detachedCount = 0
      while cur != nil:
        let next = cur.next
        result.add(move(cur.data))
        self.pushFreeNode(cur)
        inc detachedCount
        cur = next
      discard self.count.fetchSub(detachedCount, moRelaxed)
      return result
    backoffOnRetry(spins)

proc drainInto*[T](self: var TaggedStack[T], dest: var seq[T]) =
  ## Atomically detaches all items and appends them into `dest` in LIFO order.
  let items = self.drain()
  for item in items:
    dest.add(item)

iterator items*[T](self: var TaggedStack[T]): T =
  ## Warning: Destructively drains the stack in LIFO order.
  var val: T
  while self.tryPop(val):
    yield val

proc `=destroy`*[T](self: var TaggedStack[T]) =
  ## Reclaims all active nodes and pooled freelist nodes.
  # 1. Drain active stack
  var curTop = cast[ptr TaggedStackNode[T]](self.top.load(moSequentiallyConsistent).first)
  while curTop != nil:
    let next = curTop.next
    `=destroy`(curTop.data)
    freeAligned(curTop)
    curTop = next
  self.top.store(Pair[uint64, uint64](first: 0'u64, second: 0'u64), moSequentiallyConsistent)

  # 2. Free pooled freelist nodes
  var curFree = cast[ptr TaggedStackNode[T]](self.freeList.load(moSequentiallyConsistent).first)
  while curFree != nil:
    let next = curFree.next
    `=destroy`(curFree.data)
    freeAligned(curFree)
    curFree = next
  self.freeList.store(Pair[uint64, uint64](first: 0'u64, second: 0'u64), moSequentiallyConsistent)
  self.count.store(0, moRelaxed)
