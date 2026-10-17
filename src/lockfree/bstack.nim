## ===========================================================================
## Concurrency Topology: SPSC, MPSC, SPMC, MPMC Bounded Lock-Free LIFO Stack
## (`BStack[T, Cap, ccProd, ccCons]`)
## ===========================================================================
##
## A preallocated, zero-SMR, zero-heap-allocation bounded lock-free LIFO stack
## supporting all four producer/consumer cardinality topologies (`ccSingle` /
## `ccMulti`) and an integrated cache-line-aligned Elimination-Backoff Array
## (Hendler, Shavit, Yerushalmi, 2004) for MPMC high-contention pairs.
##
## Key properties:
## - **Preallocated Contiguous Storage**: All `Cap` stack slots and elimination
##   slots are preallocated inside `BStackCore[T, Cap]` at initialization time.
## - **Zero Hot-Path Heap Allocation**: `tryPush`, `push`, `tryPop`, `pop`,
##   and `peek` never allocate or free heap memory.
## - **Zero SMR / Zero NEBR**: Slots remain valid for the lifetime of the stack
##   and use 64-bit tagged index CAS (`[32-bit ABA tag | 32-bit slot index]`)
##   on both `top` and `freeHead` to prevent ABA without epoch reclamation.
## - **ARC/ORC Memory Safety**: Popped or cleared slots invoke `reset()` before
##   returning indices to `freeHead`, ensuring deterministic destruction of
##   managed payloads (`string`, `seq`, `ref`) and zero TSan data races.

import std/options
export options
import ./atomics
import ./atomics/backoff
import ./backoff
import ./cardinality
export cardinality
import ./internal/aligned_alloc

const
  BStackEliminationCapacity* = 8
    ## Number of collision slots in the Elimination-Backoff Array (power of 2).
  BStackEliminationSpins* = 32
    ## Spin count for a pusher waiting in an elimination slot for a popper.

  ElimEmpty = 0'i32
  ElimBusy = 1'i32
  ElimWaiting = 2'i32
  ElimClaimed = 3'i32
  ElimDone = 4'i32

  NilSlotIdx = -1'i32

type
  BStackSlot[T] = object
    next {.align: CacheLineBytes.}: Atomic[int32]
    slotLock: Atomic[uint32]
    inTop: Atomic[bool]
    data: T

  BStackElimSlot[T] = object
    state {.align: CacheLineBytes.}: Atomic[int32]
    value: T

  BStackCore*[T; Cap: static int] = object
    top* {.align: CacheLineBytes.}: Atomic[uint64]
    freeHead* {.align: CacheLineBytes.}: Atomic[uint64]
    count* {.align: CacheLineBytes.}: Atomic[int]
    rc* {.align: CacheLineBytes.}: Atomic[int]
    elimination*: array[BStackEliminationCapacity, BStackElimSlot[T]]
    slots*: array[Cap, BStackSlot[T]]

  BStack*[
    T;
    Cap: static int;
    ccProd: static PinScopeCardinality = ccMulti;
    ccCons: static PinScopeCardinality = ccMulti
  ] = object
    core*: ptr BStackCore[T, Cap]

  BoundedStack*[
    T;
    Cap: static int;
    ccProd: static PinScopeCardinality = ccMulti;
    ccCons: static PinScopeCardinality = ccMulti
  ] = BStack[T, Cap, ccProd, ccCons]

  SpscBoundedStack*[T; Cap: static int] = BStack[T, Cap, ccSingle, ccSingle]
  MpscBoundedStack*[T; Cap: static int] = BStack[T, Cap, ccMulti, ccSingle]
  SpmcBoundedStack*[T; Cap: static int] = BStack[T, Cap, ccSingle, ccMulti]
  MpmcBoundedStack*[T; Cap: static int] = BStack[T, Cap, ccMulti, ccMulti]

  SpscBStack*[T; Cap: static int] = BStack[T, Cap, ccSingle, ccSingle]
  MpscBStack*[T; Cap: static int] = BStack[T, Cap, ccMulti, ccSingle]
  SpmcBStack*[T; Cap: static int] = BStack[T, Cap, ccSingle, ccMulti]
  MpmcBStack*[T; Cap: static int] = BStack[T, Cap, ccMulti, ccMulti]

# ---------------------------------------------------------------------------
# 64-Bit Tagged Slot Index Encoding: [tag: uint32 (high) | idx: int32 (low)]
# ---------------------------------------------------------------------------

proc packTagIdx(tag: uint32, idx: int32): uint64 {.inline.} =
  (uint64(tag) shl 32) or uint64(cast[uint32](idx))

proc unpackTag(packed: uint64): uint32 {.inline.} =
  uint32(packed shr 32)

proc unpackIdx(packed: uint64): int32 {.inline.} =
  cast[int32](uint32(packed and 0xFFFF_FFFF'u64))

# ---------------------------------------------------------------------------
# Thread-Local PRNG for Elimination Slot Selection
# ---------------------------------------------------------------------------

var gBStackThreadSeed {.threadvar.}: uint64

proc bstackRandSlot(cap: static int): int {.inline.} =
  if unlikely(gBStackThreadSeed == 0'u64):
    var local: int
    gBStackThreadSeed = cast[uint64](addr local) xor 0x9e3779b97f4a7c15'u64
  gBStackThreadSeed = gBStackThreadSeed xor (gBStackThreadSeed shr 12)
  gBStackThreadSeed = gBStackThreadSeed xor (gBStackThreadSeed shl 25)
  gBStackThreadSeed = gBStackThreadSeed xor (gBStackThreadSeed shr 27)
  let val = gBStackThreadSeed * 0x2545F4914F6CDD1D'u64
  int((val shr 32) and uint64(cap - 1))

# ---------------------------------------------------------------------------
# ARC/ORC Lifecycle Management (`BStack`)
# ---------------------------------------------------------------------------

proc allocBStackCore[T; Cap: static int](): ptr BStackCore[T, Cap] =
  static:
    doAssert Cap > 0, "BStack capacity Cap must be greater than 0"
  let core = allocAligned[BStackCore[T, Cap]]()
  core.top.store(packTagIdx(0'u32, NilSlotIdx), moRelaxed)
  core.count.store(0, moRelaxed)
  core.rc.store(1, moRelaxed)
  for i in 0 ..< BStackEliminationCapacity:
    core.elimination[i].state.store(ElimEmpty, moRelaxed)
  for i in 0 ..< Cap:
    let nextIdx = if i + 1 < Cap: int32(i + 1) else: NilSlotIdx
    core.slots[i].next.store(nextIdx, moRelaxed)
    core.slots[i].slotLock.store(0'u32, moRelaxed)
    core.slots[i].inTop.store(false, moRelaxed)
  core.freeHead.store(packTagIdx(0'u32, 0'i32), moRelease)
  return core

proc destroyBStackCore[T; Cap: static int](core: ptr BStackCore[T, Cap]) {.gcsafe.} =
  if core == nil:
    return
  var curPacked = core.top.load(moAcquire)
  var idx = unpackIdx(curPacked)
  while idx >= 0 and idx < int32(Cap):
    let nextIdx = core.slots[idx].next.load(moRelaxed)
    reset(core.slots[idx].data)
    core.slots[idx].inTop.store(false, moRelaxed)
    idx = nextIdx
  for i in 0 ..< BStackEliminationCapacity:
    let st = core.elimination[i].state.load(moRelaxed)
    if st == ElimWaiting or st == ElimBusy:
      reset(core.elimination[i].value)
    core.elimination[i].state.store(ElimEmpty, moRelaxed)
  freeAligned(core)

proc `=destroy`*[
  T;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: var BStack[T, Cap, ccProd, ccCons]) =
  if self.core != nil:
    if self.core.rc.fetchSub(1, moAcquireRelease) == 1:
      destroyBStackCore(self.core)

proc `=copy`*[
  T;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](
    dest: var BStack[T, Cap, ccProd, ccCons],
    src: BStack[T, Cap, ccProd, ccCons]
) =
  if dest.core == src.core:
    return
  if src.core != nil:
    discard src.core.rc.fetchAdd(1, moRelaxed)
  if dest.core != nil:
    if dest.core.rc.fetchSub(1, moAcquireRelease) == 1:
      destroyBStackCore(dest.core)
  dest.core = src.core

proc `=sink`*[
  T;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](
    dest: var BStack[T, Cap, ccProd, ccCons],
    src: BStack[T, Cap, ccProd, ccCons]
) =
  if dest.core != nil and dest.core != src.core:
    if dest.core.rc.fetchSub(1, moAcquireRelease) == 1:
      destroyBStackCore(dest.core)
  dest.core = src.core

# ---------------------------------------------------------------------------
# Constructors
# ---------------------------------------------------------------------------

proc initBStack*[
  T;
  Cap: static int;
  ccProd: static PinScopeCardinality = ccMulti;
  ccCons: static PinScopeCardinality = ccMulti
](): BStack[T, Cap, ccProd, ccCons] =
  ## Initializes a preallocated bounded lock-free stack with capacity `Cap`.
  result.core = allocBStackCore[T, Cap]()

proc newBStack*[
  T;
  Cap: static int;
  ccProd: static PinScopeCardinality = ccMulti;
  ccCons: static PinScopeCardinality = ccMulti
](): BStack[T, Cap, ccProd, ccCons] {.inline.} =
  initBStack[T, Cap, ccProd, ccCons]()

proc initBoundedStack*[
  T;
  Cap: static int;
  ccProd: static PinScopeCardinality = ccMulti;
  ccCons: static PinScopeCardinality = ccMulti
](): BoundedStack[T, Cap, ccProd, ccCons] {.inline.} =
  initBStack[T, Cap, ccProd, ccCons]()

proc newBoundedStack*[
  T;
  Cap: static int;
  ccProd: static PinScopeCardinality = ccMulti;
  ccCons: static PinScopeCardinality = ccMulti
](): BoundedStack[T, Cap, ccProd, ccCons] {.inline.} =
  initBStack[T, Cap, ccProd, ccCons]()

proc initSpscBStack*[T; Cap: static int](): SpscBStack[T, Cap] {.inline.} =
  initBStack[T, Cap, ccSingle, ccSingle]()

proc initMpscBStack*[T; Cap: static int](): MpscBStack[T, Cap] {.inline.} =
  initBStack[T, Cap, ccMulti, ccSingle]()

proc initSpmcBStack*[T; Cap: static int](): SpmcBStack[T, Cap] {.inline.} =
  initBStack[T, Cap, ccSingle, ccMulti]()

proc initMpmcBStack*[T; Cap: static int](): MpmcBStack[T, Cap] {.inline.} =
  initBStack[T, Cap, ccMulti, ccMulti]()

proc newSpscBStack*[T; Cap: static int](): SpscBStack[T, Cap] {.inline.} =
  initBStack[T, Cap, ccSingle, ccSingle]()

proc newMpscBStack*[T; Cap: static int](): MpscBStack[T, Cap] {.inline.} =
  initBStack[T, Cap, ccMulti, ccSingle]()

proc newSpmcBStack*[T; Cap: static int](): SpmcBStack[T, Cap] {.inline.} =
  initBStack[T, Cap, ccSingle, ccMulti]()

proc newMpmcBStack*[T; Cap: static int](): MpmcBStack[T, Cap] {.inline.} =
  initBStack[T, Cap, ccMulti, ccMulti]()

# ---------------------------------------------------------------------------
# Internal Preallocated Slot Pool & Elimination Helpers
# ---------------------------------------------------------------------------

proc acquireFreeSlot[T; Cap: static int](core: ptr BStackCore[T, Cap]): int32 {.inline.} =
  var oldFree = core.freeHead.load(moAcquire)
  while true:
    let idx = unpackIdx(oldFree)
    if idx < 0:
      return NilSlotIdx
    let nextFree = core.slots[idx].next.load(moAcquire)
    let newFree = packTagIdx(unpackTag(oldFree) + 1'u32, nextFree)
    if core.freeHead.compareExchange(oldFree, newFree, moAcquireRelease, moAcquire):
      core.slots[idx].next.store(NilSlotIdx, moRelaxed)
      return idx
    cpuPause()

proc releaseFreeSlot[T; Cap: static int](core: ptr BStackCore[T, Cap], idx: int32) {.inline.} =
  var oldFree = core.freeHead.load(moAcquire)
  while true:
    core.slots[idx].next.store(unpackIdx(oldFree), moRelaxed)
    let newFree = packTagIdx(unpackTag(oldFree) + 1'u32, idx)
    if core.freeHead.compareExchange(oldFree, newFree, moAcquireRelease, moAcquire):
      return
    cpuPause()

proc tryEliminatePush[T; Cap: static int](
    core: ptr BStackCore[T, Cap], item: var T
): bool {.inline.} =
  let slotIdx = bstackRandSlot(BStackEliminationCapacity)
  let slot = addr core.elimination[slotIdx]

  var exp = ElimEmpty
  if not slot.state.compareExchange(exp, ElimBusy, moAcquireRelease, moAcquire):
    return false

  slot.value = move(item)
  slot.state.store(ElimWaiting, moRelease)

  for _ in 0 ..< BStackEliminationSpins:
    if slot.state.load(moAcquire) == ElimDone:
      slot.state.store(ElimEmpty, moRelease)
      return true
    cpuPause()

  var expWait = ElimWaiting
  if slot.state.compareExchange(expWait, ElimBusy, moAcquireRelease, moAcquire):
    item = move(slot.value)
    reset(slot.value)
    slot.state.store(ElimEmpty, moRelease)
    return false

  while slot.state.load(moAcquire) != ElimDone:
    cpuPause()

  slot.state.store(ElimEmpty, moRelease)
  return true

proc tryEliminatePop[T; Cap: static int](
    core: ptr BStackCore[T, Cap], outItem: var T
): bool {.inline.} =
  let slotIdx = bstackRandSlot(BStackEliminationCapacity)
  let slot = addr core.elimination[slotIdx]

  if slot.state.load(moAcquire) != ElimWaiting:
    return false

  var expWait = ElimWaiting
  if not slot.state.compareExchange(expWait, ElimClaimed, moAcquireRelease, moAcquire):
    return false

  outItem = move(slot.value)
  reset(slot.value)
  slot.state.store(ElimDone, moRelease)
  return true

proc lockSlot[T; Cap: static int](core: ptr BStackCore[T, Cap], idx: int32) {.inline.} =
  while unlikely(core.slots[idx].slotLock.exchange(1'u32, moAcquire) != 0'u32):
    cpuPause()

proc unlockSlot[T; Cap: static int](core: ptr BStackCore[T, Cap], idx: int32) {.inline.} =
  core.slots[idx].slotLock.store(0'u32, moRelease)

proc tryLinkTop[T; Cap: static int](
    core: ptr BStackCore[T, Cap], idx: int32
): bool {.inline.} =
  var oldTop = core.top.load(moAcquire)
  core.slots[idx].next.store(unpackIdx(oldTop), moRelaxed)
  core.slots[idx].inTop.store(true, moRelease)
  let newTop = packTagIdx(unpackTag(oldTop) + 1'u32, idx)
  if core.top.compareExchange(oldTop, newTop, moAcquireRelease, moAcquire):
    discard core.count.fetchAdd(1, moRelease)
    return true
  core.slots[idx].inTop.store(false, moRelease)
  return false

proc tryUnlinkTop[T; Cap: static int](
    core: ptr BStackCore[T, Cap], outItem: var T
): bool {.inline.} =
  var oldTop = core.top.load(moAcquire)
  while true:
    let idx = unpackIdx(oldTop)
    if idx < 0:
      return false
    let nextIdx = core.slots[idx].next.load(moAcquire)
    let newTop = packTagIdx(unpackTag(oldTop) + 1'u32, nextIdx)
    if core.top.compareExchange(oldTop, newTop, moAcquireRelease, moAcquire):
      lockSlot(core, idx)
      core.slots[idx].inTop.store(false, moRelease)
      outItem = move(core.slots[idx].data)
      reset(core.slots[idx].data)
      unlockSlot(core, idx)
      discard core.count.fetchSub(1, moRelease)
      releaseFreeSlot(core, idx)
      return true
    cpuPause()

# ---------------------------------------------------------------------------
# Public Operations (`tryPush`, `push`, `tryPop`, `pop`, `peek`, `drain`)
# ---------------------------------------------------------------------------

proc tryPush*[
  T;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BStack[T, Cap, ccProd, ccCons], item: sink T): bool {.gcsafe.} =
  ## Attempts to push `item` onto the bounded stack without allocating heap memory.
  ## Returns `true` on success, or `false` if the stack has reached capacity `Cap`.
  doAssert self.core != nil, "BStack is uninitialized; call initBStack[T, Cap]()"
  let core = self.core

  let idx = acquireFreeSlot(core)
  if idx < 0:
    return false

  lockSlot(core, idx)
  core.slots[idx].data = move(item)
  unlockSlot(core, idx)

  if tryLinkTop(core, idx):
    return true

  var spins = InitialSpin
  while true:
    when ccProd == ccMulti and ccCons == ccMulti:
      lockSlot(core, idx)
      var elimVal = move(core.slots[idx].data)
      reset(core.slots[idx].data)
      unlockSlot(core, idx)
      if tryEliminatePush(core, elimVal):
        releaseFreeSlot(core, idx)
        return true
      lockSlot(core, idx)
      core.slots[idx].data = move(elimVal)
      unlockSlot(core, idx)

    if tryLinkTop(core, idx):
      return true

    backoffOnRetry(spins)

proc push*[
  T;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BStack[T, Cap, ccProd, ccCons], item: sink T): bool {.discardable, inline, gcsafe.} =
  ## Pushes `item` onto the bounded stack. Returns `true` if pushed, or `false`
  ## if the stack is full (`len == Cap`).
  self.tryPush(item)

proc tryPop*[
  T;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BStack[T, Cap, ccProd, ccCons], outItem: var T): bool {.gcsafe.} =
  ## Attempts to pop the top item in LIFO order into `outItem`.
  ## Returns `true` if an item was popped, or `false` if the stack is empty.
  doAssert self.core != nil, "BStack is uninitialized; call initBStack[T, Cap]()"
  let core = self.core

  if tryUnlinkTop(core, outItem):
    return true

  when ccProd == ccMulti and ccCons == ccMulti:
    if tryEliminatePop(core, outItem):
      return true

  return false

proc pop*[
  T;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BStack[T, Cap, ccProd, ccCons]): Option[T] {.inline, gcsafe.} =
  ## Pops and returns `some(item)` in LIFO order, or `none(T)` if empty.
  var val: T
  if self.tryPop(val):
    some(move(val))
  else:
    none(T)

proc peek*[
  T;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BStack[T, Cap, ccProd, ccCons]): Option[T] {.gcsafe.} =
  ## Returns `some(topItem)` without removing it, or `none(T)` if empty.
  if self.core == nil:
    return none(T)
  let core = self.core

  var oldTop = core.top.load(moAcquire)
  while true:
    let idx = unpackIdx(oldTop)
    if idx < 0:
      return none(T)
    lockSlot(core, idx)
    if core.slots[idx].inTop.load(moAcquire) and core.top.load(moAcquire) == oldTop:
      let copyVal = core.slots[idx].data
      unlockSlot(core, idx)
      return some(copyVal)
    unlockSlot(core, idx)
    cpuPause()
    oldTop = core.top.load(moAcquire)

proc drainInto*[
  T;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BStack[T, Cap, ccProd, ccCons], dest: var seq[T]) {.gcsafe.} =
  ## Atomically detaches all items currently in the stack and appends them to
  ## `dest` in LIFO order.
  if self.core == nil:
    return
  let core = self.core
  var oldTop = core.top.load(moAcquire)
  while true:
    let headIdx = unpackIdx(oldTop)
    if headIdx < 0:
      return
    let newTop = packTagIdx(unpackTag(oldTop) + 1'u32, NilSlotIdx)
    if core.top.compareExchange(oldTop, newTop, moAcquireRelease, moAcquire):
      var curIdx = headIdx
      var drained = 0
      while curIdx >= 0:
        let nextIdx = core.slots[curIdx].next.load(moAcquire)
        lockSlot(core, curIdx)
        core.slots[curIdx].inTop.store(false, moRelease)
        dest.add(move(core.slots[curIdx].data))
        reset(core.slots[curIdx].data)
        unlockSlot(core, curIdx)
        releaseFreeSlot(core, curIdx)
        inc drained
        curIdx = nextIdx
      discard core.count.fetchSub(drained, moRelease)
      return
    cpuPause()

proc drain*[
  T;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BStack[T, Cap, ccProd, ccCons]): seq[T] {.gcsafe.} =
  ## Atomically detaches all items currently in the stack and returns them in
  ## LIFO order.
  result = @[]
  self.drainInto(result)

proc clear*[
  T;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BStack[T, Cap, ccProd, ccCons]) {.gcsafe.} =
  ## Removes and destroys all items currently in the stack, returning all slots
  ## to the preallocated free pool.
  if self.core == nil:
    return
  let core = self.core
  var oldTop = core.top.load(moAcquire)
  while true:
    let headIdx = unpackIdx(oldTop)
    if headIdx < 0:
      return
    let newTop = packTagIdx(unpackTag(oldTop) + 1'u32, NilSlotIdx)
    if core.top.compareExchange(oldTop, newTop, moAcquireRelease, moAcquire):
      var curIdx = headIdx
      var cleared = 0
      while curIdx >= 0:
        let nextIdx = core.slots[curIdx].next.load(moAcquire)
        lockSlot(core, curIdx)
        core.slots[curIdx].inTop.store(false, moRelease)
        reset(core.slots[curIdx].data)
        unlockSlot(core, curIdx)
        releaseFreeSlot(core, curIdx)
        inc cleared
        curIdx = nextIdx
      discard core.count.fetchSub(cleared, moRelease)
      return
    cpuPause()

proc len*[
  T;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BStack[T, Cap, ccProd, ccCons]): int {.inline.} =
  ## Returns the current number of elements in the bounded stack (`0 .. Cap`).
  if self.core == nil:
    0
  else:
    clamp(self.core.count.load(moAcquire), 0, Cap)

proc capacity*[
  T;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BStack[T, Cap, ccProd, ccCons]): int {.inline.} =
  ## Returns the compile-time capacity `Cap` of the bounded stack.
  Cap

proc isEmpty*[
  T;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BStack[T, Cap, ccProd, ccCons]): bool {.inline.} =
  ## Returns `true` if the stack currently contains no items.
  if self.core == nil:
    true
  else:
    unpackIdx(self.core.top.load(moAcquire)) < 0

proc isFull*[
  T;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BStack[T, Cap, ccProd, ccCons]): bool {.inline.} =
  ## Returns `true` if all `Cap` preallocated slots are currently in use.
  if self.core == nil:
    false
  else:
    unpackIdx(self.core.freeHead.load(moAcquire)) < 0
