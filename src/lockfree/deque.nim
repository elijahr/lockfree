## ============================================================================
## Concurrency Topology: Single-Worker (pushBottom / popBottom at bottom)
## Multi-Thief (steal / stealBatch at top)
## ============================================================================
##
## Dynamic circular work-stealing deque implementing the Chase-Lev algorithm
## with formal C11 / weak-memory-model fences (Le, Pop, Cohen, Nardelli PPoPP
## '13) and bulk multi-item stealing (stealBatch).
##
## Architectural Invariants:
## 1. Concurrency Topology:
##    - Worker: operates at `bottom` using LIFO order (pushBottom / popBottom).
##      Minimizes communication latency and maximizes cache locality for
##      divide-and-conquer / fork-join task parallelism.
##    - Thieves: operate at `top` using FIFO order (steal / stealBatch). Steals
##      the oldest (typically largest granularity) tasks from the top,
##      amortizing scheduling overhead across cores.
## 2. Dynamic Circular Buffer with SMR-safe Retired Chains:
##    - Automatically doubles buffer capacity when worker pushes to a full
##      deque.
##    - Previous buffers are retained in an unmanaged retired chain until deque
##      destruction, guaranteeing concurrent thieves reading slots during or
##      after resizing never experience use-after-free or ABA faults.
## 3. Strict Memory Ordering:
##    - Worker push publishes elements via `moRelease` fence prior to relaxed
##      bottom store.
##    - Worker pop issues `moSequentiallyConsistent` fence between bottom
##      decrement and top load.
##    - Thieves synchronize via `moAcquire` top/bottom loads,
##      `moSequentiallyConsistent` fences, and atomic CAS
##      (`compareExchangeStrong`) on `top`.
## 4. Cacheline Alignment:
##    - `top`, `bottom`, and `buffer` are placed on distinct `CacheLineBytes`
##      boundaries, preventing false sharing between the active worker and
##      competing thieves.
## 5. ARC/ORC Full Lifecycle Compliance:
##    - Supports POD types, `ref T`, `string`, and `seq[T]` via `SlotEncoding`
##      and Path-C transfer-ownership contracts without memory leaks.

import std/options
import lockfree/atomics
import ./internal/aligned_alloc
import ./internal/path_c_admit
import ./internal/slot_encoding
import ./internal/path_c_wrap

const moSeqCst* = moSequentiallyConsistent
  ## Ergonomic alias for `moSequentiallyConsistent`.

type
  DequeBuffer[E] = object
    capacity: int
    mask: int
    data: ptr UncheckedArray[E]
    nextOld: ptr DequeBuffer[E]

  ChaseLevDequeCore[T] = object
    top* {.align: CacheLineBytes.}: Atomic[int64]
    bottom* {.align: CacheLineBytes.}: Atomic[int64]
    buffer* {.align: CacheLineBytes.}: Atomic[ptr DequeBuffer[SlotEncoding(T)]]
    oldBuffersHead: ptr DequeBuffer[SlotEncoding(T)]
    rc: Atomic[int]

  ChaseLevDeque*[T] = object
    ## Lock-free Single-Worker / Multi-Thief work-stealing deque.
    core*: ptr ChaseLevDequeCore[T]

  # Ergonomic aliases per mandate
  Deque*[T] = ChaseLevDeque[T]
  ConcurrentDeque*[T] = ChaseLevDeque[T]

proc newDequeBuffer[E](cap: int): ptr DequeBuffer[E] =
  result = cast[ptr DequeBuffer[E]](allocShared0(sizeof(DequeBuffer[E])))
  result.capacity = cap
  result.mask = cap - 1
  result.data = cast[ptr UncheckedArray[E]](allocShared0(sizeof(E) * cap))
  result.nextOld = nil

proc freeDequeBuffer[E](buf: ptr DequeBuffer[E]) =
  if buf != nil:
    if buf.data != nil:
      deallocShared(buf.data)
      buf.data = nil
    deallocShared(buf)

proc growBuffer[T](core: ptr ChaseLevDequeCore[T], b, t: int64): ptr DequeBuffer[SlotEncoding(T)] =
  let oldBuf = core.buffer.load(moRelaxed)
  let newCap = oldBuf.capacity * 2
  let newBuf = newDequeBuffer[SlotEncoding(T)](newCap)

  # Copy live elements from t to b
  var i = t
  while i < b:
    let oldIdx = int(i and int64(oldBuf.mask))
    let newIdx = int(i and int64(newBuf.mask))
    newBuf.data[newIdx] = oldBuf.data[oldIdx]
    inc i

  # Push oldBuf onto retired chain for cleanup when core is destroyed
  oldBuf.nextOld = core.oldBuffersHead
  core.oldBuffersHead = oldBuf

  # Publish new buffer to concurrent thieves with release ordering
  core.buffer.store(newBuf, moRelease)
  return newBuf

proc `=destroy`*[T](self: var ChaseLevDeque[T]) =
  if self.core != nil:
    if self.core.rc.fetchSub(1, moRelease) == 1:
      threadFence(moAcquire)
      let core = self.core
      let buf = core.buffer.load(moRelaxed)
      let t = core.top.load(moRelaxed)
      let b = core.bottom.load(moRelaxed)

      # Dispose any remaining unpopped / unstolen elements in the active buffer
      if buf != nil and buf.data != nil:
        var i = t
        while i < b:
          let idx = int(i and int64(buf.mask))
          disposeSlotEncoded[T](buf.data[idx])
          inc i
        freeDequeBuffer(buf)

      # Free retired buffer memory (elements were already migrated to active
      # buffer)
      var curr = core.oldBuffersHead
      while curr != nil:
        let nxt = curr.nextOld
        freeDequeBuffer(curr)
        curr = nxt

      freeAligned(core)
    self.core = nil

proc `=copy`*[T](dest: var ChaseLevDeque[T], src: ChaseLevDeque[T]) =
  if dest.core != src.core:
    `=destroy`(dest)
    dest.core = src.core
    if dest.core != nil:
      discard dest.core.rc.fetchAdd(1, moRelaxed)

proc `=sink`*[T](dest: var ChaseLevDeque[T], src: ChaseLevDeque[T]) =
  if dest.core != src.core:
    `=destroy`(dest)
    dest.core = src.core

proc initChaseLevDeque*[T](initialCapacity: int = 64): ChaseLevDeque[T] =
  ## Initializes a new `ChaseLevDeque[T]` with power-of-two capacity (minimum
  ## 16).
  pathCAdmit(T)
  var cap = 1
  while cap < initialCapacity:
    cap = cap shl 1
  if cap < 16:
    cap = 16

  let core = allocAligned[ChaseLevDequeCore[T]]()
  core.top.store(0, moRelaxed)
  core.bottom.store(0, moRelaxed)
  core.rc.store(1, moRelaxed)
  let initialBuf = newDequeBuffer[SlotEncoding(T)](cap)
  core.buffer.store(initialBuf, moRelaxed)
  core.oldBuffersHead = nil

  result.core = core

proc initDeque*[T](initialCapacity: int = 64): Deque[T] {.inline.} =
  ## Ergonomic alias constructor for `ChaseLevDeque[T]`.
  initChaseLevDeque[T](initialCapacity)

proc initConcurrentDeque*[T](initialCapacity: int = 64): ConcurrentDeque[T] {.inline.} =
  ## Ergonomic alias constructor for `ChaseLevDeque[T]`.
  initChaseLevDeque[T](initialCapacity)

proc isNil*[T](self: ChaseLevDeque[T]): bool {.inline.} =
  ## Returns true if the deque handle has an uninitialized or destroyed core.
  self.core == nil

proc capacity*[T](self: ChaseLevDeque[T]): int =
  ## Returns the current slot capacity of the active circular buffer.
  if unlikely(self.core == nil): return 0
  let buf = self.core.buffer.load(moRelaxed)
  if buf != nil: buf.capacity else: 0

proc len*[T](self: ChaseLevDeque[T]): int =
  ## Returns an approximate count of items currently in the deque. Non-blocking
  ## estimation: max(0, bottom - top).
  if unlikely(self.core == nil): return 0
  let b = self.core.bottom.load(moRelaxed)
  let t = self.core.top.load(moRelaxed)
  let diff = b - t
  if diff < 0: 0 else: int(diff)

proc isEmpty*[T](self: ChaseLevDeque[T]): bool {.inline.} =
  ## Returns true if the deque currently contains zero items.
  self.len == 0

proc pushBottom*[T](self: ChaseLevDeque[T], item: sink T) =
  ## Pushes an item to the bottom of the deque. ONLY the single owner-worker
  ## thread may invoke pushBottom.
  pathCAdmit(T)
  assert self.core != nil, "ChaseLevDeque is uninitialized"
  let core = self.core
  var b = core.bottom.load(moRelaxed)
  var t = core.top.load(moAcquire)
  var buf = core.buffer.load(moRelaxed)

  if b - t >= int64(buf.capacity):
    buf = growBuffer(core, b, t)

  let idx = int(b and int64(buf.mask))
  buf.data[idx] = wrapOrIdentity(item)
  threadFence(moRelease)
  core.bottom.store(b + 1, moRelaxed)

proc popBottom*[T](self: ChaseLevDeque[T]): Option[T] =
  ## Pops an item from the bottom of the deque (LIFO order). ONLY the single
  ## owner-worker thread may invoke popBottom. Returns `none(T)` if the deque is
  ## empty.
  if unlikely(self.core == nil): return none(T)
  let core = self.core
  var b = core.bottom.load(moRelaxed)
  var buf = core.buffer.load(moRelaxed)

  b = b - 1
  core.bottom.store(b, moRelaxed)
  threadFence(moSequentiallyConsistent)

  var t = core.top.load(moRelaxed)
  if t <= b:
    let idx = int(b and int64(buf.mask))
    if t == b:
      # Exactly 1 element remaining: race with concurrent thieves on the last
      # item
      var expectedTop = t
      if core.top.compareExchangeStrong(expectedTop, t + 1, moSequentiallyConsistent, moRelaxed):
        let encoded = buf.data[idx]
        buf.data[idx] = default(SlotEncoding(T))
        core.bottom.store(b + 1, moRelaxed)
        return some(unwrapOrIdentity[T](encoded))
      else:
        # A thief won the CAS race for the last element
        core.bottom.store(b + 1, moRelaxed)
        return none(T)
    else:
      # More than 1 element remaining: worker owns slot b without thief
      # contention
      let encoded = buf.data[idx]
      buf.data[idx] = default(SlotEncoding(T))
      return some(unwrapOrIdentity[T](encoded))
  else:
    # Deque was already empty
    core.bottom.store(b + 1, moRelaxed)
    return none(T)

proc tryPopBottom*[T](self: ChaseLevDeque[T], item: var T): bool =
  ## Attempts to pop an item from the bottom. Returns true on success and
  ## assigns to `item`.
  let res = self.popBottom()
  if res.isSome:
    item = res.get()
    return true
  return false

proc steal*[T](self: ChaseLevDeque[T]): Option[T] =
  ## Steals an item from the top of the deque (FIFO order). May be invoked
  ## concurrently by ANY number of thief threads. Returns `none(T)` if the deque
  ## is empty or on CAS contention with peers.
  if unlikely(self.core == nil): return none(T)
  let core = self.core
  var t = core.top.load(moAcquire)
  threadFence(moSequentiallyConsistent)
  var b = core.bottom.load(moAcquire)

  if t >= b:
    return none(T)

  var expectedTop = t
  if core.top.compareExchangeStrong(expectedTop, t + 1, moSequentiallyConsistent, moRelaxed):
    var buf = core.buffer.load(moAcquire)
    let idx = int(t and int64(buf.mask))
    let encoded = buf.data[idx]
    return some(unwrapOrIdentity[T](encoded))
  else:
    return none(T)

proc trySteal*[T](self: ChaseLevDeque[T], item: var T): bool =
  ## Attempts to steal an item from top. Returns true on success and assigns to
  ## `item`.
  let res = self.steal()
  if res.isSome:
    item = res.get()
    return true
  return false

proc stealBatch*[T](self: ChaseLevDeque[T], dest: var openArray[T], maxItems: int = -1): int =
  ## Steals a batch of items from the top of the deque via per-slot CAS to
  ## prevent racing with popBottom jumping top past bottom (CVE-2021-32810).
  ## Writes stolen items to `dest[0 ..< stolenCount]` in FIFO order and returns
  ## `stolenCount`. If `maxItems <= 0`, defaults to stealing up to
  ## `min(dest.len, (available + 1) div 2)`.
  if unlikely(self.core == nil or dest.len == 0): return 0
  let core = self.core
  var t = core.top.load(moAcquire)
  threadFence(moSequentiallyConsistent)
  var b = core.bottom.load(moAcquire)

  var n = b - t
  if n <= 0:
    return 0

  var limit = if maxItems > 0: min(maxItems, int(n)) else: max(1, int((n + 1) div 2))
  limit = min(limit, dest.len)
  if limit <= 0:
    return 0

  var stolen = 0
  while stolen < limit:
    t = core.top.load(moAcquire)
    threadFence(moSequentiallyConsistent)
    b = core.bottom.load(moAcquire)
    if t >= b:
      break

    var expectedTop = t
    if core.top.compareExchangeStrong(expectedTop, t + 1, moSequentiallyConsistent, moRelaxed):
      var buf = core.buffer.load(moAcquire)
      let idx = int(t and int64(buf.mask))
      let encoded = buf.data[idx]
      dest[stolen] = unwrapOrIdentity[T](encoded)
      inc stolen
    else:
      break

  return stolen

proc stealBatch*[T](self: ChaseLevDeque[T], maxItems: int = -1): seq[T] =
  ## Steals a batch of items from the top of the deque into a new `seq[T]`. If
  ## `maxItems <= 0`, defaults to stealing up to `(available + 1) div 2`.
  if unlikely(self.core == nil): return @[]
  let core = self.core
  var t = core.top.load(moAcquire)
  threadFence(moSequentiallyConsistent)
  var b = core.bottom.load(moAcquire)

  var n = b - t
  if n <= 0:
    return @[]

  var limit = if maxItems > 0: min(maxItems, int(n)) else: max(1, int((n + 1) div 2))
  var res = newSeq[T](limit)
  let actual = self.stealBatch(res, limit)
  if actual < limit:
    res.setLen(actual)
  return res

proc `$`*[T](self: ChaseLevDeque[T]): string =
  if self.core == nil:
    "ChaseLevDeque(uninitialized)"
  else:
    "ChaseLevDeque[len=" & $self.len & ", cap=" & $self.capacity & "]"
