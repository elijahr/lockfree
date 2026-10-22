## ===========================================================================
## Concurrency Topology: SPSC, MPSC, SPMC, MPMC Bounded Priority Queue
## (`BPriorityQueue[T, Cap, ccProd, ccCons]`)
## ===========================================================================
##
## A preallocated, zero-SMR, zero-hot-path-heap-allocation bounded concurrent
## min-priority queue backed by a contiguous binary min-heap of capacity `Cap`
## and a preallocated flat-combining publication array.
##
## Key properties:
## - **Preallocated Contiguous Binary Heap**: All `Cap` heap entries and
##   combiner publication slots are allocated inside `BPriorityQueueCore[T, Cap]`
##   at construction time (`initBPriorityQueue`).
## - **Zero Hot-Path Heap Allocation & Zero SMR**: `tryPush`, `push`,
##   `tryPopMin`, `popMin`, `peekMin`, and `clear` perform zero heap allocations
##   and never touch NEBR/DEBRA epoch reclamation.
## - **Strict FIFO Tie-Breaking**: Equal priorities are ordered deterministically
##   by a monotonically increasing 64-bit `seqId`, preserving insertion order.
## - **ARC/ORC Memory Safety**: Popped and cleared heap slots immediately invoke
##   `reset()`, releasing managed payloads (`string`, `seq`, `ref`) without leak
##   or TSan data races.

import std/options
export options
import ./atomics
import ./atomics/backoff
import ./cardinality
export cardinality
import ./internal/aligned_alloc

when compileOption("threads"):
  import ./priority_queue
  export Prioritized, `<`, `<=`, `==`, cmp
else:
  type
    Prioritized*[P, V] = object
      priority*: P
      value*: V

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
      if a.priority < b.priority: -1
      elif b.priority < a.priority: 1
      else: 0

const
  BPQMaxCombinerSlots* = 64
  BPQMaxCombineRounds* = 8

  bpqSlotFree = 0'u32
  bpqSlotIdle = 1'u32
  bpqSlotPending = 2'u32

type
  BPQOpKind = enum
    bpqOpPush
    bpqOpPopMin
    bpqOpPeekMin

  BHeapEntry*[T] = object
    key*: T
    seqId*: uint64

  BPQPubSlot[T] = object
    status {.align: 128.}: Atomic[uint32]
    ownerTid: Atomic[uint64]
    opKind: BPQOpKind
    inVal: T
    outVal: T
    ok: bool

  BPriorityQueueCore*[T; Cap: static int] = object
    combinerLock* {.align: CacheLineBytes.}: Atomic[uint64]
    count* {.align: CacheLineBytes.}: Atomic[int]
    activePubSlots* {.align: CacheLineBytes.}: Atomic[int]
    rc* {.align: CacheLineBytes.}: Atomic[int]
    nextSeqId*: uint64
    heapSize*: int
    effCap*: int
    pubSlots*: array[BPQMaxCombinerSlots, BPQPubSlot[T]]
    heap*: array[Cap, BHeapEntry[T]]

  BPriorityQueue*[
    T;
    Cap: static int;
    ccProd: static PinScopeCardinality = ccMulti;
    ccCons: static PinScopeCardinality = ccMulti
  ] = object
    core*: ptr BPriorityQueueCore[T, Cap]

  BoundedPriorityQueue*[
    T;
    Cap: static int;
    ccProd: static PinScopeCardinality = ccMulti;
    ccCons: static PinScopeCardinality = ccMulti
  ] = BPriorityQueue[T, Cap, ccProd, ccCons]

  SpscBoundedPriorityQueue*[T; Cap: static int] = BPriorityQueue[T, Cap, ccSingle, ccSingle]
  MpscBoundedPriorityQueue*[T; Cap: static int] = BPriorityQueue[T, Cap, ccMulti, ccSingle]
  SpmcBoundedPriorityQueue*[T; Cap: static int] = BPriorityQueue[T, Cap, ccSingle, ccMulti]
  MpmcBoundedPriorityQueue*[T; Cap: static int] = BPriorityQueue[T, Cap, ccMulti, ccMulti]

  SpscBPriorityQueue*[T; Cap: static int] = BPriorityQueue[T, Cap, ccSingle, ccSingle]
  MpscBPriorityQueue*[T; Cap: static int] = BPriorityQueue[T, Cap, ccMulti, ccSingle]
  SpmcBPriorityQueue*[T; Cap: static int] = BPriorityQueue[T, Cap, ccSingle, ccMulti]
  MpmcBPriorityQueue*[T; Cap: static int] = BPriorityQueue[T, Cap, ccMulti, ccMulti]

# ---------------------------------------------------------------------------
# Thread ID & Comparison Helpers
# ---------------------------------------------------------------------------

var
  gNextBpqThreadId: Atomic[uint64]
  gMyBpqThreadId {.threadvar.}: uint64

proc getBpqThreadId(): uint64 {.inline.} =
  var tid = gMyBpqThreadId
  if unlikely(tid == 0'u64):
    tid = gNextBpqThreadId.fetchAdd(1'u64, moRelaxed) + 1'u64
    gMyBpqThreadId = tid
  tid

proc compareBpqKeys[T](a, b: T): int {.inline.} =
  when compiles(cmp(a, b)):
    cmp(a, b)
  else:
    if a < b: -1
    elif b < a: 1
    else: 0

proc heapEntryLess[T](a, b: BHeapEntry[T]): bool {.inline.} =
  let c = compareBpqKeys(a.key, b.key)
  if c < 0:
    true
  elif c > 0:
    false
  else:
    a.seqId < b.seqId

# ---------------------------------------------------------------------------
# Binary Min-Heap Operations (Executed Under Combiner Lease)
# ---------------------------------------------------------------------------

proc siftUp[T; Cap: static int](core: ptr BPriorityQueueCore[T, Cap], idx: int) {.inline.} =
  var child = idx
  while child > 0:
    let parent = (child - 1) shr 1
    if heapEntryLess(core.heap[child], core.heap[parent]):
      swap(core.heap[child], core.heap[parent])
      child = parent
    else:
      break

proc siftDown[T; Cap: static int](core: ptr BPriorityQueueCore[T, Cap], idx: int, n: int) {.inline.} =
  var parent = idx
  while true:
    let left = (parent shl 1) + 1
    if left >= n:
      break
    let right = left + 1
    var smallest = parent
    if heapEntryLess(core.heap[left], core.heap[smallest]):
      smallest = left
    if right < n and heapEntryLess(core.heap[right], core.heap[smallest]):
      smallest = right
    if smallest == parent:
      break
    swap(core.heap[parent], core.heap[smallest])
    parent = smallest

proc heapPushDirect[T; Cap: static int](
    core: ptr BPriorityQueueCore[T, Cap], item: sink T
): bool {.inline.} =
  let n = core.heapSize
  if n >= core.effCap:
    return false
  inc core.nextSeqId
  core.heap[n] = BHeapEntry[T](key: move(item), seqId: core.nextSeqId)
  core.heapSize = n + 1
  siftUp(core, n)
  core.count.store(core.heapSize, moRelease)
  return true

proc heapPopMinDirect[T; Cap: static int](
    core: ptr BPriorityQueueCore[T, Cap], outVal: var T
): bool {.inline.} =
  let n = core.heapSize
  if n <= 0:
    return false
  outVal = move(core.heap[0].key)
  let newN = n - 1
  core.heapSize = newN
  if newN > 0:
    core.heap[0] = move(core.heap[newN])
    reset(core.heap[newN].key)
    core.heap[newN].seqId = 0'u64
    siftDown(core, 0, newN)
  else:
    reset(core.heap[0].key)
    core.heap[0].seqId = 0'u64
  core.count.store(newN, moRelease)
  return true

proc heapPeekMinDirect[T; Cap: static int](
    core: ptr BPriorityQueueCore[T, Cap], outVal: var T
): bool {.inline.} =
  if core.heapSize <= 0:
    return false
  outVal = core.heap[0].key
  return true

# ---------------------------------------------------------------------------
# Preallocated Flat-Combining Engine
# ---------------------------------------------------------------------------

proc acquirePubSlot[T; Cap: static int](core: ptr BPriorityQueueCore[T, Cap]): int {.inline.} =
  let tid = getBpqThreadId()
  let startSlot = int(tid mod uint64(BPQMaxCombinerSlots))
  # 1. Check if this thread already owns a slot
  for step in 0 ..< BPQMaxCombinerSlots:
    let idx = (startSlot + step) and (BPQMaxCombinerSlots - 1)
    if core.pubSlots[idx].ownerTid.load(moRelaxed) == tid:
      return idx
  # 2. Claim a free slot
  for step in 0 ..< BPQMaxCombinerSlots:
    let idx = (startSlot + step) and (BPQMaxCombinerSlots - 1)
    if core.pubSlots[idx].ownerTid.load(moRelaxed) == 0'u64:
      var expectedTid = 0'u64
      if core.pubSlots[idx].ownerTid.compareExchange(expectedTid, tid, moAcquireRelease, moRelaxed):
        core.pubSlots[idx].status.store(bpqSlotIdle, moRelease)
        discard core.activePubSlots.fetchAdd(1, moRelease)
        return idx
  return -1

proc sweepPubSlots[T; Cap: static int](core: ptr BPriorityQueueCore[T, Cap]) {.inline.} =
  if core.activePubSlots.load(moAcquire) <= 0:
    return
  for _ in 0 ..< BPQMaxCombineRounds:
    var combined = 0
    for i in 0 ..< BPQMaxCombinerSlots:
      if core.pubSlots[i].status.load(moAcquire) == bpqSlotPending:
        case core.pubSlots[i].opKind
        of bpqOpPush:
          core.pubSlots[i].ok = heapPushDirect(core, move(core.pubSlots[i].inVal))
          reset(core.pubSlots[i].inVal)
        of bpqOpPopMin:
          core.pubSlots[i].ok = heapPopMinDirect(core, core.pubSlots[i].outVal)
        of bpqOpPeekMin:
          core.pubSlots[i].ok = heapPeekMinDirect(core, core.pubSlots[i].outVal)
        core.pubSlots[i].status.store(bpqSlotIdle, moRelease)
        inc combined
    if combined == 0:
      break

# ---------------------------------------------------------------------------
# ARC/ORC Lifecycle Management (`BPriorityQueue`)
# ---------------------------------------------------------------------------

proc allocBPQCore[T; Cap: static int](): ptr BPriorityQueueCore[T, Cap] =
  static:
    doAssert Cap > 0, "BPriorityQueue capacity Cap must be greater than 0"
  let core = allocAligned[BPriorityQueueCore[T, Cap]]()
  core.combinerLock.store(0'u64, moRelaxed)
  core.count.store(0, moRelaxed)
  core.activePubSlots.store(0, moRelaxed)
  core.rc.store(1, moRelaxed)
  core.nextSeqId = 0'u64
  core.heapSize = 0
  core.effCap = Cap
  for i in 0 ..< BPQMaxCombinerSlots:
    core.pubSlots[i].status.store(bpqSlotFree, moRelaxed)
    core.pubSlots[i].ownerTid.store(0'u64, moRelaxed)
  return core

proc destroyBPQCore[T; Cap: static int](core: ptr BPriorityQueueCore[T, Cap]) {.gcsafe.} =
  if core == nil:
    return
  for i in 0 ..< core.heapSize:
    reset(core.heap[i].key)
  for i in 0 ..< BPQMaxCombinerSlots:
    reset(core.pubSlots[i].inVal)
    reset(core.pubSlots[i].outVal)
  freeAligned(core)

proc `=destroy`*[
  T;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: var BPriorityQueue[T, Cap, ccProd, ccCons]) =
  if self.core != nil:
    if self.core.rc.fetchSub(1, moAcquireRelease) == 1:
      destroyBPQCore(self.core)

proc `=copy`*[
  T;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](
    dest: var BPriorityQueue[T, Cap, ccProd, ccCons],
    src: BPriorityQueue[T, Cap, ccProd, ccCons]
) =
  if dest.core == src.core:
    return
  if src.core != nil:
    discard src.core.rc.fetchAdd(1, moRelaxed)
  if dest.core != nil:
    if dest.core.rc.fetchSub(1, moAcquireRelease) == 1:
      destroyBPQCore(dest.core)
  dest.core = src.core

proc `=sink`*[
  T;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](
    dest: var BPriorityQueue[T, Cap, ccProd, ccCons],
    src: BPriorityQueue[T, Cap, ccProd, ccCons]
) =
  if dest.core != nil and dest.core != src.core:
    if dest.core.rc.fetchSub(1, moAcquireRelease) == 1:
      destroyBPQCore(dest.core)
  dest.core = src.core

# ---------------------------------------------------------------------------
# Constructors
# ---------------------------------------------------------------------------

proc initBPriorityQueue*[
  T;
  Cap: static int;
  ccProd: static PinScopeCardinality = ccMulti;
  ccCons: static PinScopeCardinality = ccMulti
](): BPriorityQueue[T, Cap, ccProd, ccCons] =
  ## Initializes a preallocated bounded priority queue with capacity `Cap`.
  result.core = allocBPQCore[T, Cap]()

proc newBPriorityQueue*[
  T;
  Cap: static int;
  ccProd: static PinScopeCardinality = ccMulti;
  ccCons: static PinScopeCardinality = ccMulti
](): BPriorityQueue[T, Cap, ccProd, ccCons] {.inline.} =
  initBPriorityQueue[T, Cap, ccProd, ccCons]()

proc initBoundedPriorityQueue*[
  T;
  Cap: static int;
  ccProd: static PinScopeCardinality = ccMulti;
  ccCons: static PinScopeCardinality = ccMulti
](): BoundedPriorityQueue[T, Cap, ccProd, ccCons] {.inline.} =
  initBPriorityQueue[T, Cap, ccProd, ccCons]()

proc newBoundedPriorityQueue*[
  T;
  Cap: static int;
  ccProd: static PinScopeCardinality = ccMulti;
  ccCons: static PinScopeCardinality = ccMulti
](): BoundedPriorityQueue[T, Cap, ccProd, ccCons] {.inline.} =
  initBPriorityQueue[T, Cap, ccProd, ccCons]()

proc initSpscBPriorityQueue*[T; Cap: static int](): SpscBPriorityQueue[T, Cap] {.inline.} =
  initBPriorityQueue[T, Cap, ccSingle, ccSingle]()

proc initMpscBPriorityQueue*[T; Cap: static int](): MpscBPriorityQueue[T, Cap] {.inline.} =
  initBPriorityQueue[T, Cap, ccMulti, ccSingle]()

proc initSpmcBPriorityQueue*[T; Cap: static int](): SpmcBPriorityQueue[T, Cap] {.inline.} =
  initBPriorityQueue[T, Cap, ccSingle, ccMulti]()

proc initMpmcBPriorityQueue*[T; Cap: static int](): MpmcBPriorityQueue[T, Cap] {.inline.} =
  initBPriorityQueue[T, Cap, ccMulti, ccMulti]()

proc newSpscBPriorityQueue*[T; Cap: static int](): SpscBPriorityQueue[T, Cap] {.inline.} =
  initBPriorityQueue[T, Cap, ccSingle, ccSingle]()

proc newMpscBPriorityQueue*[T; Cap: static int](): MpscBPriorityQueue[T, Cap] {.inline.} =
  initBPriorityQueue[T, Cap, ccMulti, ccSingle]()

proc newSpmcBPriorityQueue*[T; Cap: static int](): SpmcBPriorityQueue[T, Cap] {.inline.} =
  initBPriorityQueue[T, Cap, ccSingle, ccMulti]()

proc newMpmcBPriorityQueue*[T; Cap: static int](): MpmcBPriorityQueue[T, Cap] {.inline.} =
  initBPriorityQueue[T, Cap, ccMulti, ccMulti]()

# ---------------------------------------------------------------------------
# Public Operations (`tryPush`, `push`, `tryPopMin`, `popMin`, `peekMin`, `clear`)
# ---------------------------------------------------------------------------

proc tryPush*[
  T;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BPriorityQueue[T, Cap, ccProd, ccCons], item: sink T): bool {.gcsafe.} =
  ## Attempts to insert `item` into the bounded priority queue without heap allocation.
  ## Returns `true` if inserted, or `false` if the priority queue is full (`len == Cap`).
  doAssert self.core != nil, "BPriorityQueue is uninitialized; call initBPriorityQueue[T, Cap]()"
  let core = self.core

  # Fast combiner acquisition
  if core.combinerLock.load(moRelaxed) == 0'u64:
    var expected = 0'u64
    if core.combinerLock.compareExchange(expected, 1'u64, moAcquire, moRelaxed):
      try:
        result = heapPushDirect(core, move(item))
        sweepPubSlots(core)
      finally:
        core.combinerLock.store(0'u64, moRelease)
      return result

  let slotIdx = acquirePubSlot(core)
  if slotIdx >= 0:
    let slot = addr core.pubSlots[slotIdx]
    slot.opKind = bpqOpPush
    slot.inVal = move(item)
    slot.ok = false
    slot.status.store(bpqSlotPending, moRelease)

    while true:
      if slot.status.load(moAcquire) != bpqSlotPending:
        return slot.ok
      if core.combinerLock.load(moRelaxed) == 0'u64:
        var expected = 0'u64
        if core.combinerLock.compareExchange(expected, 1'u64, moAcquire, moRelaxed):
          try:
            sweepPubSlots(core)
          finally:
            core.combinerLock.store(0'u64, moRelease)
          if slot.status.load(moAcquire) != bpqSlotPending:
            return slot.ok
      for _ in 0 ..< 128:
        if slot.status.load(moAcquire) != bpqSlotPending:
          return slot.ok
        cpuPause()
  else:
    # Fallback direct lock spin if >64 concurrent threads
    while true:
      if core.combinerLock.load(moRelaxed) == 0'u64:
        var expected = 0'u64
        if core.combinerLock.compareExchange(expected, 1'u64, moAcquire, moRelaxed):
          try:
            result = heapPushDirect(core, move(item))
            sweepPubSlots(core)
          finally:
            core.combinerLock.store(0'u64, moRelease)
          return result
      cpuPause()

proc push*[
  T;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BPriorityQueue[T, Cap, ccProd, ccCons], item: sink T): bool {.discardable, inline, gcsafe.} =
  ## Inserts `item` into the bounded priority queue. Returns `true` if inserted,
  ## or `false` if full (`len == Cap`).
  self.tryPush(item)

proc tryPopMin*[
  T;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BPriorityQueue[T, Cap, ccProd, ccCons], outVal: var T): bool {.gcsafe.} =
  ## Attempts to remove the minimum element into `outVal`.
  ## Equal priorities are popped in strict FIFO insertion order.
  ## Returns `true` if an element was popped, or `false` if empty.
  doAssert self.core != nil, "BPriorityQueue is uninitialized; call initBPriorityQueue[T, Cap]()"
  let core = self.core

  if core.combinerLock.load(moRelaxed) == 0'u64:
    var expected = 0'u64
    if core.combinerLock.compareExchange(expected, 1'u64, moAcquire, moRelaxed):
      try:
        result = heapPopMinDirect(core, outVal)
        sweepPubSlots(core)
      finally:
        core.combinerLock.store(0'u64, moRelease)
      return result

  let slotIdx = acquirePubSlot(core)
  if slotIdx >= 0:
    let slot = addr core.pubSlots[slotIdx]
    slot.opKind = bpqOpPopMin
    slot.ok = false
    slot.status.store(bpqSlotPending, moRelease)

    while true:
      if slot.status.load(moAcquire) != bpqSlotPending:
        if slot.ok:
          outVal = move(slot.outVal)
          reset(slot.outVal)
        return slot.ok
      if core.combinerLock.load(moRelaxed) == 0'u64:
        var expected = 0'u64
        if core.combinerLock.compareExchange(expected, 1'u64, moAcquire, moRelaxed):
          try:
            sweepPubSlots(core)
          finally:
            core.combinerLock.store(0'u64, moRelease)
          if slot.status.load(moAcquire) != bpqSlotPending:
            if slot.ok:
              outVal = move(slot.outVal)
              reset(slot.outVal)
            return slot.ok
      for _ in 0 ..< 128:
        if slot.status.load(moAcquire) != bpqSlotPending:
          if slot.ok:
            outVal = move(slot.outVal)
            reset(slot.outVal)
          return slot.ok
        cpuPause()
  else:
    while true:
      if core.combinerLock.load(moRelaxed) == 0'u64:
        var expected = 0'u64
        if core.combinerLock.compareExchange(expected, 1'u64, moAcquire, moRelaxed):
          try:
            result = heapPopMinDirect(core, outVal)
            sweepPubSlots(core)
          finally:
            core.combinerLock.store(0'u64, moRelease)
          return result
      cpuPause()

proc popMin*[
  T;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BPriorityQueue[T, Cap, ccProd, ccCons]): Option[T] {.inline, gcsafe.} =
  ## Removes and returns `some(minItem)`, or `none(T)` if empty.
  var val: T
  if self.tryPopMin(val):
    some(move(val))
  else:
    none(T)

proc peekMin*[
  T;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BPriorityQueue[T, Cap, ccProd, ccCons]): Option[T] {.gcsafe.} =
  ## Returns `some(minItem)` without removing it, or `none(T)` if empty.
  if self.core == nil:
    return none(T)
  let core = self.core
  if core.count.load(moAcquire) <= 0:
    return none(T)

  var val: T
  var ok = false
  if core.combinerLock.load(moRelaxed) == 0'u64:
    var expected = 0'u64
    if core.combinerLock.compareExchange(expected, 1'u64, moAcquire, moRelaxed):
      try:
        ok = heapPeekMinDirect(core, val)
        sweepPubSlots(core)
      finally:
        core.combinerLock.store(0'u64, moRelease)
      return (if ok: some(move(val)) else: none(T))

  let slotIdx = acquirePubSlot(core)
  if slotIdx >= 0:
    let slot = addr core.pubSlots[slotIdx]
    slot.opKind = bpqOpPeekMin
    slot.ok = false
    slot.status.store(bpqSlotPending, moRelease)

    while true:
      if slot.status.load(moAcquire) != bpqSlotPending:
        if slot.ok:
          val = move(slot.outVal)
          reset(slot.outVal)
          return some(move(val))
        return none(T)
      if core.combinerLock.load(moRelaxed) == 0'u64:
        var expected = 0'u64
        if core.combinerLock.compareExchange(expected, 1'u64, moAcquire, moRelaxed):
          try:
            sweepPubSlots(core)
          finally:
            core.combinerLock.store(0'u64, moRelease)
          if slot.status.load(moAcquire) != bpqSlotPending:
            if slot.ok:
              val = move(slot.outVal)
              reset(slot.outVal)
              return some(move(val))
            return none(T)
      for _ in 0 ..< 128:
        if slot.status.load(moAcquire) != bpqSlotPending:
          if slot.ok:
            val = move(slot.outVal)
            reset(slot.outVal)
            return some(move(val))
          return none(T)
        cpuPause()
  else:
    while true:
      if core.combinerLock.load(moRelaxed) == 0'u64:
        var expected = 0'u64
        if core.combinerLock.compareExchange(expected, 1'u64, moAcquire, moRelaxed):
          try:
            ok = heapPeekMinDirect(core, val)
            sweepPubSlots(core)
          finally:
            core.combinerLock.store(0'u64, moRelease)
          return (if ok: some(move(val)) else: none(T))
      cpuPause()

template pop*[T; Cap: static int; ccProd, ccCons: static PinScopeCardinality](
    pq: BPriorityQueue[T, Cap, ccProd, ccCons]
): untyped =
  pq.popMin()

template peek*[T; Cap: static int; ccProd, ccCons: static PinScopeCardinality](
    pq: BPriorityQueue[T, Cap, ccProd, ccCons]
): untyped =
  pq.peekMin()

proc clear*[
  T;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BPriorityQueue[T, Cap, ccProd, ccCons]) {.gcsafe.} =
  ## Removes and destroys all elements currently in the bounded priority queue.
  if self.core == nil:
    return
  let core = self.core
  while true:
    if core.combinerLock.load(moRelaxed) == 0'u64:
      var expected = 0'u64
      if core.combinerLock.compareExchange(expected, 1'u64, moAcquire, moRelaxed):
        try:
          for i in 0 ..< core.heapSize:
            reset(core.heap[i].key)
            core.heap[i].seqId = 0'u64
          core.heapSize = 0
          core.count.store(0, moRelease)
          sweepPubSlots(core)
        finally:
          core.combinerLock.store(0'u64, moRelease)
        return
    cpuPause()

proc len*[
  T;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BPriorityQueue[T, Cap, ccProd, ccCons]): int {.inline.} =
  ## Returns the current number of active elements in the priority queue (`0 .. capacity`).
  if self.core == nil:
    0
  else:
    clamp(self.core.count.load(moAcquire), 0, self.core.effCap)

proc capacity*[
  T;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BPriorityQueue[T, Cap, ccProd, ccCons]): int {.inline.} =
  ## Returns the effective capacity of the bounded priority queue (defaults to `Cap`).
  if self.core == nil:
    Cap
  else:
    self.core.effCap

proc setEffectiveCapacity*[
  T;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BPriorityQueue[T, Cap, ccProd, ccCons], effCap: int) =
  ## Sets the effective maximum entry count (`1 .. Cap`) on an empty `BPriorityQueue`.
  if self.core != nil:
    self.core.effCap = clamp(effCap, 1, Cap)

proc isEmpty*[
  T;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BPriorityQueue[T, Cap, ccProd, ccCons]): bool {.inline.} =
  ## Returns `true` if the priority queue currently contains no active elements.
  self.len() == 0

proc isFull*[
  T;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BPriorityQueue[T, Cap, ccProd, ccCons]): bool {.inline.} =
  ## Returns `true` if the priority queue has reached its effective capacity.
  self.len() >= self.capacity()
