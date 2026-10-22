## ===========================================================================
## Concurrency Topology: SPSC, MPSC, SPMC, MPMC Bounded Concurrent Hash Table
## (`BTable[K, V, Cap, ccProd, ccCons]`)
## ===========================================================================
##
## A preallocated, zero-SMR, zero-hot-path-heap-allocation bounded concurrent
## hash table backed by an open-addressing linear-probing slot array with
## per-slot atomic state & sequence counters (`Empty`, `Occupied`, `Tombstone`)
## and a preallocated flat-combining publication array.
##
## Key properties:
## - **Preallocated Open-Addressing Probe Table**: Preallocates `2 * nextPowerOfTwo(Cap)`
##   probe slots inside `BTableCore[K, V, Cap]` at initialization time so maximum
##   load factor never exceeds 50% at capacity `Cap`.
## - **Tombstone-Aware Linear Probing**: `put` / `insert` records `firstTombstone`
##   and continues probing until seeing `key` or `Empty` (or exhausting all probe
##   slots) before reusing `firstTombstone`, preventing duplicate keys even when
##   every slot is `Occupied` or `Tombstone`.
## - **Zero Hot-Path Heap Allocation & Zero SMR**: `tryPut`, `put`, `tryInsert`,
##   `insert`, `tryGet`, `get`, `contains`, `remove`, `computeIfAbsent`,
##   `atomicUpdate`, and `upsert` never allocate dynamic nodes or touch NEBR/DEBRA.
## - **ARC/ORC Memory Safety**: Deleted and overwritten slots immediately invoke
##   `reset()` on displaced keys/values under the combiner/slot synchronization
##   protocol, guaranteeing zero leaks and zero TSan data races.

import std/[options, hashes]
export options, hashes
import ./atomics
import ./atomics/backoff
import ./cardinality
export cardinality
import ./internal/aligned_alloc
import ./internal/typestates_dsl
import ./role_tags
import ./endpoint_types
export role_tags, endpoint_types

const
  BTableSlotEmpty* = 0'u32
  BTableSlotOccupied* = 1'u32
  BTableSlotTombstone* = 2'u32

  BTableMaxCombinerSlots* = 64
  BTableMaxCombineRounds* = 8

  btPubFree = 0'u32
  btPubIdle = 1'u32
  btPubPending = 2'u32

proc calcBTableProbeSlots*(cap: int): int {.compileTime.} =
  var target = if cap <= 8: 16 else: cap * 2
  var p = 16
  while p < target:
    p = p shl 1
  p

type
  BTableOpKind = enum
    btOpTryPut
    btOpTryInsert
    btOpTryGet
    btOpContains
    btOpRemove
    btOpTake

  BTableSlot*[K, V] = object
    state*: Atomic[uint32]
    seq*: Atomic[uint64]
    hashVal*: uint32
    key*: K
    val*: V

  BTablePubSlot[K, V] = object
    status {.align: 128.}: Atomic[uint32]
    ownerTid: Atomic[uint64]
    opKind: BTableOpKind
    inKey: K
    inVal: V
    outVal: V
    ok: bool
    inserted: bool
    full: bool

  BTableCore*[K, V; Cap: static int; ProbeSlots: static int] = object
    combinerLock* {.align: CacheLineBytes.}: Atomic[uint64]
    count* {.align: CacheLineBytes.}: Atomic[int]
    activePubSlots* {.align: CacheLineBytes.}: Atomic[int]
    rc* {.align: CacheLineBytes.}: Atomic[int]
    liveCount*: int
    effCap*: int
    pubSlots*: array[BTableMaxCombinerSlots, BTablePubSlot[K, V]]
    slots*: array[ProbeSlots, BTableSlot[K, V]]

  BTableLifecycleCtx*[
    K, V;
    Cap: static int;
    ccProd: static PinScopeCardinality = ccMulti;
    ccCons: static PinScopeCardinality = ccMulti
  ] = object of RootObj

  BTableInit*[
    K, V;
    Cap: static int;
    ccProd: static PinScopeCardinality = ccMulti;
    ccCons: static PinScopeCardinality = ccMulti
  ] = distinct BTableLifecycleCtx[K, V, Cap, ccProd, ccCons]

  BTableDestroyed*[
    K, V;
    Cap: static int;
    ccProd: static PinScopeCardinality = ccMulti;
    ccCons: static PinScopeCardinality = ccMulti
  ] = distinct BTableLifecycleCtx[K, V, Cap, ccProd, ccCons]

typestate BTableLifecycle[
  K,
  V,
  Cap: static int,
  ccProd: static PinScopeCardinality,
  ccCons: static PinScopeCardinality
]:
  inheritsFromRootObj = true
  consumeOnTransition = false
  strictTransitions = false
  states:
    BTableInit[K, V, Cap, ccProd, ccCons]
    BTableDestroyed[K, V, Cap, ccProd, ccCons]
  initial:
    BTableInit[K, V, Cap, ccProd, ccCons]
  terminal:
    BTableDestroyed[K, V, Cap, ccProd, ccCons]
  transitions:
    BTableInit[K, V, Cap, ccProd, ccCons] -> BTableDestroyed[K, V, Cap, ccProd, ccCons]

type
  BTable*[
    K, V;
    Cap: static int;
    ccProd: static PinScopeCardinality = ccMulti;
    ccCons: static PinScopeCardinality = ccMulti
  ] {.BTableLifecycle: BTableInit.} = object
    core*: ptr BTableCore[K, V, Cap, calcBTableProbeSlots(Cap)]

  BoundedTable*[
    K, V;
    Cap: static int;
    ccProd: static PinScopeCardinality = ccMulti;
    ccCons: static PinScopeCardinality = ccMulti
  ] = BTable[K, V, Cap, ccProd, ccCons]

  SpscBoundedTable*[K, V; Cap: static int] = BTable[K, V, Cap, ccSingle, ccSingle]
  MpscBoundedTable*[K, V; Cap: static int] = BTable[K, V, Cap, ccMulti, ccSingle]
  SpmcBoundedTable*[K, V; Cap: static int] = BTable[K, V, Cap, ccSingle, ccMulti]
  MpmcBoundedTable*[K, V; Cap: static int] = BTable[K, V, Cap, ccMulti, ccMulti]

  SpscBTable*[K, V; Cap: static int] = BTable[K, V, Cap, ccSingle, ccSingle]
  MpscBTable*[K, V; Cap: static int] = BTable[K, V, Cap, ccMulti, ccSingle]
  SpmcBTable*[K, V; Cap: static int] = BTable[K, V, Cap, ccSingle, ccMulti]
  MpmcBTable*[K, V; Cap: static int] = BTable[K, V, Cap, ccMulti, ccMulti]



# ---------------------------------------------------------------------------
# Hash Finalizer & Thread ID
# ---------------------------------------------------------------------------

proc btableHash[K](key: K): uint32 {.inline.} =
  let h = hash(key)
  var x = uint32(cast[uint](h) and 0xFFFF_FFFF'u)
  x = x xor (x shr 16)
  x = x * 0x85ebca6b'u32
  x = x xor (x shr 13)
  x = x * 0xc2b2ae35'u32
  x = x xor (x shr 16)
  x

var
  gNextBTableThreadId: Atomic[uint64]
  gMyBTableThreadId {.threadvar.}: uint64

proc getBTableThreadId(): uint64 {.inline.} =
  var tid = gMyBTableThreadId
  if unlikely(tid == 0'u64):
    tid = gNextBTableThreadId.fetchAdd(1'u64, moRelaxed) + 1'u64
    gMyBTableThreadId = tid
  tid

# ---------------------------------------------------------------------------
# Open-Addressing Probe & Per-Slot Sequence Operations (Under Combiner Lease)
# ---------------------------------------------------------------------------

proc findSlotIndex[K, V; Cap: static int; ProbeSlots: static int](
    core: ptr BTableCore[K, V, Cap, ProbeSlots],
    key: K,
    hv: uint32
): int {.inline.} =
  ## Probes at most `ProbeSlots` positions for `key`.
  ## Returns the slot index if found, or `-1` if absent.
  const mask = ProbeSlots - 1
  let start = int(hv) and mask
  for step in 0 ..< ProbeSlots:
    let idx = (start + step) and mask
    let st = core.slots[idx].state.load(moRelaxed)
    if st == BTableSlotEmpty:
      return -1
    elif st == BTableSlotOccupied and core.slots[idx].hashVal == hv and core.slots[idx].key == key:
      return idx
  return -1

proc directTryPut[K, V; Cap: static int; ProbeSlots: static int](
    core: ptr BTableCore[K, V, Cap, ProbeSlots],
    key: sink K,
    val: sink V,
    overwriteExisting: bool,
    outInserted: ptr bool = nil,
    outFull: ptr bool = nil
): bool {.inline.} =
  ## Inserts or updates `(key, val)`.
  ## Preserves the Tombstone Probe Invariant: records `firstTombstone` and
  ## continues probing until `key` is found, an `Empty` slot is reached, or all
  ## `ProbeSlots` have been inspected.
  if outInserted != nil:
    outInserted[] = false
  if outFull != nil:
    outFull[] = false
  const mask = ProbeSlots - 1
  let hv = btableHash(key)
  let start = int(hv) and mask
  var firstTombstone = -1
  var targetIdx = -1

  for step in 0 ..< ProbeSlots:
    let idx = (start + step) and mask
    let st = core.slots[idx].state.load(moRelaxed)
    if st == BTableSlotOccupied:
      if core.slots[idx].hashVal == hv and core.slots[idx].key == key:
        if not overwriteExisting:
          return false
        let s0 = core.slots[idx].seq.load(moRelaxed)
        core.slots[idx].seq.store(s0 + 1'u64, moRelease)
        core.slots[idx].val = move(val)
        core.slots[idx].seq.store(s0 + 2'u64, moRelease)
        return true
    elif st == BTableSlotTombstone:
      if firstTombstone < 0:
        firstTombstone = idx
    else: # BTableSlotEmpty
      targetIdx = if firstTombstone >= 0: firstTombstone else: idx
      break

  if targetIdx < 0:
    targetIdx = firstTombstone

  if core.liveCount >= core.effCap or targetIdx < 0:
    if outFull != nil:
      outFull[] = true
    return false

  let s0 = core.slots[targetIdx].seq.load(moRelaxed)
  core.slots[targetIdx].seq.store(s0 + 1'u64, moRelease)
  core.slots[targetIdx].hashVal = hv
  core.slots[targetIdx].key = move(key)
  core.slots[targetIdx].val = move(val)
  core.slots[targetIdx].state.store(BTableSlotOccupied, moRelease)
  core.slots[targetIdx].seq.store(s0 + 2'u64, moRelease)
  inc core.liveCount
  core.count.store(core.liveCount, moRelease)
  if outInserted != nil:
    outInserted[] = true
  return true

proc directTryGet[K, V; Cap: static int; ProbeSlots: static int](
    core: ptr BTableCore[K, V, Cap, ProbeSlots],
    key: K,
    outVal: var V
): bool {.inline.} =
  if core.liveCount <= 0:
    return false
  let hv = btableHash(key)
  let idx = findSlotIndex(core, key, hv)
  if idx < 0:
    return false
  outVal = core.slots[idx].val
  return true

proc directContains[K, V; Cap: static int; ProbeSlots: static int](
    core: ptr BTableCore[K, V, Cap, ProbeSlots],
    key: K
): bool {.inline.} =
  if core.liveCount <= 0:
    return false
  let hv = btableHash(key)
  findSlotIndex(core, key, hv) >= 0

proc directRemove[K, V; Cap: static int; ProbeSlots: static int](
    core: ptr BTableCore[K, V, Cap, ProbeSlots],
    key: K,
    outVal: ptr V
): bool {.inline.} =
  if core.liveCount <= 0:
    return false
  let hv = btableHash(key)
  let idx = findSlotIndex(core, key, hv)
  if idx < 0:
    return false
  let s0 = core.slots[idx].seq.load(moRelaxed)
  core.slots[idx].seq.store(s0 + 1'u64, moRelease)
  if outVal != nil:
    outVal[] = move(core.slots[idx].val)
  reset(core.slots[idx].key)
  reset(core.slots[idx].val)
  core.slots[idx].hashVal = 0'u32
  core.slots[idx].state.store(BTableSlotTombstone, moRelease)
  core.slots[idx].seq.store(s0 + 2'u64, moRelease)
  dec core.liveCount
  core.count.store(core.liveCount, moRelease)
  return true

# ---------------------------------------------------------------------------
# Preallocated Flat-Combining Engine
# ---------------------------------------------------------------------------

proc acquireBTablePubSlot[K, V; Cap: static int; ProbeSlots: static int](
    core: ptr BTableCore[K, V, Cap, ProbeSlots]
): int {.inline.} =
  let tid = getBTableThreadId()
  let startSlot = int(tid mod uint64(BTableMaxCombinerSlots))
  for step in 0 ..< BTableMaxCombinerSlots:
    let idx = (startSlot + step) and (BTableMaxCombinerSlots - 1)
    if core.pubSlots[idx].ownerTid.load(moRelaxed) == tid:
      return idx
  for step in 0 ..< BTableMaxCombinerSlots:
    let idx = (startSlot + step) and (BTableMaxCombinerSlots - 1)
    if core.pubSlots[idx].ownerTid.load(moRelaxed) == 0'u64:
      var expectedTid = 0'u64
      if core.pubSlots[idx].ownerTid.compareExchange(expectedTid, tid, moAcquireRelease, moRelaxed):
        core.pubSlots[idx].status.store(btPubIdle, moRelease)
        discard core.activePubSlots.fetchAdd(1, moRelease)
        return idx
  return -1

proc sweepBTablePubSlots[K, V; Cap: static int; ProbeSlots: static int](
    core: ptr BTableCore[K, V, Cap, ProbeSlots]
) {.inline.} =
  if core.activePubSlots.load(moAcquire) <= 0:
    return
  for _ in 0 ..< BTableMaxCombineRounds:
    var combined = 0
    for i in 0 ..< BTableMaxCombinerSlots:
      if core.pubSlots[i].status.load(moAcquire) == btPubPending:
        case core.pubSlots[i].opKind
        of btOpTryPut:
          core.pubSlots[i].ok = directTryPut(
            core,
            move(core.pubSlots[i].inKey),
            move(core.pubSlots[i].inVal),
            overwriteExisting = true,
            outInserted = addr core.pubSlots[i].inserted,
            outFull = addr core.pubSlots[i].full
          )
          reset(core.pubSlots[i].inKey)
          reset(core.pubSlots[i].inVal)
        of btOpTryInsert:
          core.pubSlots[i].ok = directTryPut(
            core,
            move(core.pubSlots[i].inKey),
            move(core.pubSlots[i].inVal),
            overwriteExisting = false,
            outInserted = addr core.pubSlots[i].inserted,
            outFull = addr core.pubSlots[i].full
          )
          reset(core.pubSlots[i].inKey)
          reset(core.pubSlots[i].inVal)
        of btOpTryGet:
          core.pubSlots[i].ok = directTryGet(core, core.pubSlots[i].inKey, core.pubSlots[i].outVal)
          reset(core.pubSlots[i].inKey)
        of btOpContains:
          core.pubSlots[i].ok = directContains(core, core.pubSlots[i].inKey)
          reset(core.pubSlots[i].inKey)
        of btOpRemove:
          core.pubSlots[i].ok = directRemove(core, core.pubSlots[i].inKey, nil)
          reset(core.pubSlots[i].inKey)
        of btOpTake:
          core.pubSlots[i].ok = directRemove(core, core.pubSlots[i].inKey, addr core.pubSlots[i].outVal)
          reset(core.pubSlots[i].inKey)
        core.pubSlots[i].status.store(btPubIdle, moRelease)
        inc combined
    if combined == 0:
      break

# ---------------------------------------------------------------------------
# ARC/ORC Lifecycle Management (`BTable`)
# ---------------------------------------------------------------------------

proc allocBTableCore[K, V; Cap: static int](): ptr BTableCore[K, V, Cap, calcBTableProbeSlots(Cap)] =
  static:
    doAssert Cap > 0, "BTable capacity Cap must be greater than 0"
  const ProbeSlots = calcBTableProbeSlots(Cap)
  let core = allocAligned[BTableCore[K, V, Cap, ProbeSlots]]()
  core.combinerLock.store(0'u64, moRelaxed)
  core.count.store(0, moRelaxed)
  core.activePubSlots.store(0, moRelaxed)
  core.rc.store(1, moRelaxed)
  core.liveCount = 0
  core.effCap = Cap
  for i in 0 ..< BTableMaxCombinerSlots:
    core.pubSlots[i].status.store(btPubFree, moRelaxed)
    core.pubSlots[i].ownerTid.store(0'u64, moRelaxed)
  for i in 0 ..< ProbeSlots:
    core.slots[i].state.store(BTableSlotEmpty, moRelaxed)
    core.slots[i].seq.store(0'u64, moRelaxed)
    core.slots[i].hashVal = 0'u32
  return core

proc destroyBTableCore[K, V; Cap: static int; ProbeSlots: static int](
    core: ptr BTableCore[K, V, Cap, ProbeSlots]
) {.gcsafe.} =
  if core == nil:
    return
  for i in 0 ..< ProbeSlots:
    if core.slots[i].state.load(moRelaxed) == BTableSlotOccupied:
      reset(core.slots[i].key)
      reset(core.slots[i].val)
  for i in 0 ..< BTableMaxCombinerSlots:
    reset(core.pubSlots[i].inKey)
    reset(core.pubSlots[i].inVal)
    reset(core.pubSlots[i].outVal)
  freeAligned(core)

proc `=destroy`*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](
    self: var BTable[K, V, Cap, ccProd, ccCons]
) {.destructorTransition: BTableInit[K, V, Cap, ccProd, ccCons] -> BTableDestroyed[K, V, Cap, ccProd, ccCons].} =
  if self.core != nil:
    if self.core.rc.fetchSub(1, moAcquireRelease) == 1:
      destroyBTableCore(self.core)

proc `=copy`*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](
    dest: var BTable[K, V, Cap, ccProd, ccCons],
    src: BTable[K, V, Cap, ccProd, ccCons]
) {.notATransition.} =
  if dest.core == src.core:
    return
  if src.core != nil:
    discard src.core.rc.fetchAdd(1, moRelaxed)
  if dest.core != nil:
    if dest.core.rc.fetchSub(1, moAcquireRelease) == 1:
      destroyBTableCore(dest.core)
  dest.core = src.core

proc `=sink`*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](
    dest: var BTable[K, V, Cap, ccProd, ccCons],
    src: BTable[K, V, Cap, ccProd, ccCons]
) {.notATransition.} =
  if dest.core != nil and dest.core != src.core:
    if dest.core.rc.fetchSub(1, moAcquireRelease) == 1:
      destroyBTableCore(dest.core)
  dest.core = src.core

# ---------------------------------------------------------------------------
# Constructors
# ---------------------------------------------------------------------------

proc initBTable*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality = ccMulti;
  ccCons: static PinScopeCardinality = ccMulti
](): BTable[K, V, Cap, ccProd, ccCons] =
  ## Initializes a preallocated bounded concurrent hash table with capacity `Cap`.
  result.core = allocBTableCore[K, V, Cap]()

proc newBTable*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality = ccMulti;
  ccCons: static PinScopeCardinality = ccMulti
](): BTable[K, V, Cap, ccProd, ccCons] {.inline.} =
  initBTable[K, V, Cap, ccProd, ccCons]()

proc initBoundedTable*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality = ccMulti;
  ccCons: static PinScopeCardinality = ccMulti
](): BoundedTable[K, V, Cap, ccProd, ccCons] {.inline.} =
  initBTable[K, V, Cap, ccProd, ccCons]()

proc newBoundedTable*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality = ccMulti;
  ccCons: static PinScopeCardinality = ccMulti
](): BoundedTable[K, V, Cap, ccProd, ccCons] {.inline.} =
  initBTable[K, V, Cap, ccProd, ccCons]()

proc initSpscBTable*[K, V; Cap: static int](): SpscBTable[K, V, Cap] {.inline.} =
  initBTable[K, V, Cap, ccSingle, ccSingle]()

proc initMpscBTable*[K, V; Cap: static int](): MpscBTable[K, V, Cap] {.inline.} =
  initBTable[K, V, Cap, ccMulti, ccSingle]()

proc initSpmcBTable*[K, V; Cap: static int](): SpmcBTable[K, V, Cap] {.inline.} =
  initBTable[K, V, Cap, ccSingle, ccMulti]()

proc initMpmcBTable*[K, V; Cap: static int](): MpmcBTable[K, V, Cap] {.inline.} =
  initBTable[K, V, Cap, ccMulti, ccMulti]()

proc newSpscBTable*[K, V; Cap: static int](): SpscBTable[K, V, Cap] {.inline.} =
  initBTable[K, V, Cap, ccSingle, ccSingle]()

proc newMpscBTable*[K, V; Cap: static int](): MpscBTable[K, V, Cap] {.inline.} =
  initBTable[K, V, Cap, ccMulti, ccSingle]()

proc newSpmcBTable*[K, V; Cap: static int](): SpmcBTable[K, V, Cap] {.inline.} =
  initBTable[K, V, Cap, ccSingle, ccMulti]()

proc newMpmcBTable*[K, V; Cap: static int](): MpmcBTable[K, V, Cap] {.inline.} =
  initBTable[K, V, Cap, ccMulti, ccMulti]()

# ---------------------------------------------------------------------------
# Public Operations (`tryPut`, `put`, `tryInsert`, `insert`, `tryGet`, `get`,
# `lookup`, `contains`, `remove`, `del`, `take`, `computeIfAbsent`,
# `atomicUpdate`, `upsert`, `snapshotPairs`, `clear`)
# ---------------------------------------------------------------------------

proc submitBTableOp[K, V; Cap: static int; ProbeSlots: static int](
    core: ptr BTableCore[K, V, Cap, ProbeSlots],
    kind: BTableOpKind,
    key: sink K,
    val: sink V,
    outVal: ptr V,
    outInserted: ptr bool = nil,
    outFull: ptr bool = nil
): bool {.inline, gcsafe.} =
  if core.combinerLock.load(moRelaxed) == 0'u64:
    var expected = 0'u64
    if core.combinerLock.compareExchange(expected, 1'u64, moAcquire, moRelaxed):
      try:
        case kind
        of btOpTryPut:
          result = directTryPut(core, move(key), move(val), overwriteExisting = true, outInserted = outInserted, outFull = outFull)
        of btOpTryInsert:
          result = directTryPut(core, move(key), move(val), overwriteExisting = false, outInserted = outInserted, outFull = outFull)
        of btOpTryGet:
          result = directTryGet(core, key, outVal[])
        of btOpContains:
          result = directContains(core, key)
        of btOpRemove:
          result = directRemove(core, key, nil)
        of btOpTake:
          result = directRemove(core, key, outVal)
        sweepBTablePubSlots(core)
      finally:
        core.combinerLock.store(0'u64, moRelease)
      return result

  let slotIdx = acquireBTablePubSlot(core)
  if slotIdx >= 0:
    let slot = addr core.pubSlots[slotIdx]
    slot.opKind = kind
    slot.inKey = move(key)
    if kind in {btOpTryPut, btOpTryInsert}:
      slot.inVal = move(val)
    slot.ok = false
    slot.inserted = false
    slot.full = false
    slot.status.store(btPubPending, moRelease)

    while true:
      if slot.status.load(moAcquire) != btPubPending:
        if outInserted != nil:
          outInserted[] = slot.inserted
        if outFull != nil:
          outFull[] = slot.full
        if slot.ok and outVal != nil and kind in {btOpTryGet, btOpTake}:
          outVal[] = move(slot.outVal)
          reset(slot.outVal)
        return slot.ok
      if core.combinerLock.load(moRelaxed) == 0'u64:
        var expected = 0'u64
        if core.combinerLock.compareExchange(expected, 1'u64, moAcquire, moRelaxed):
          try:
            sweepBTablePubSlots(core)
          finally:
            core.combinerLock.store(0'u64, moRelease)
          if slot.status.load(moAcquire) != btPubPending:
            if outInserted != nil:
              outInserted[] = slot.inserted
            if outFull != nil:
              outFull[] = slot.full
            if slot.ok and outVal != nil and kind in {btOpTryGet, btOpTake}:
              outVal[] = move(slot.outVal)
              reset(slot.outVal)
            return slot.ok
      for _ in 0 ..< 128:
        if slot.status.load(moAcquire) != btPubPending:
          if outInserted != nil:
            outInserted[] = slot.inserted
          if outFull != nil:
            outFull[] = slot.full
          if slot.ok and outVal != nil and kind in {btOpTryGet, btOpTake}:
            outVal[] = move(slot.outVal)
            reset(slot.outVal)
          return slot.ok
        cpuPause()
  else:
    while true:
      if core.combinerLock.load(moRelaxed) == 0'u64:
        var expected = 0'u64
        if core.combinerLock.compareExchange(expected, 1'u64, moAcquire, moRelaxed):
          try:
            case kind
            of btOpTryPut:
              result = directTryPut(core, move(key), move(val), overwriteExisting = true, outInserted = outInserted, outFull = outFull)
            of btOpTryInsert:
              result = directTryPut(core, move(key), move(val), overwriteExisting = false, outInserted = outInserted, outFull = outFull)
            of btOpTryGet:
              result = directTryGet(core, key, outVal[])
            of btOpContains:
              result = directContains(core, key)
            of btOpRemove:
              result = directRemove(core, key, nil)
            of btOpTake:
              result = directRemove(core, key, outVal)
            sweepBTablePubSlots(core)
          finally:
            core.combinerLock.store(0'u64, moRelease)
          return result
      cpuPause()

proc tryPut*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BTable[K, V, Cap, ccProd, ccCons], key: sink K, val: sink V): bool {.gcsafe, notATransition.} =
  ## Inserts `(key, val)` or updates `key` if already present.
  ## Returns `true` on success, or `false` if `key` is new and the table is full (`len == Cap`).
  doAssert self.core != nil, "BTable is uninitialized; call initBTable[K, V, Cap]()"
  submitBTableOp(self.core, btOpTryPut, move(key), move(val), nil)

proc tryPutEx*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](
    self: BTable[K, V, Cap, ccProd, ccCons],
    key: sink K,
    val: sink V,
    outInserted: ptr bool,
    outFull: ptr bool
): bool {.gcsafe, notATransition.} =
  ## Inserts `(key, val)` or updates `key` if already present, recording whether
  ## a new entry was inserted (`outInserted[]`) or whether the table was full (`outFull[]`).
  doAssert self.core != nil, "BTable is uninitialized; call initBTable[K, V, Cap]()"
  submitBTableOp(self.core, btOpTryPut, move(key), move(val), nil, outInserted, outFull)

proc put*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BTable[K, V, Cap, ccProd, ccCons], key: sink K, val: sink V): bool {.discardable, inline, gcsafe, notATransition.} =
  ## Inserts or updates `(key, val)`. Returns `false` if `key` is absent and `len == Cap`.
  self.tryPut(move(key), move(val))

proc `[]=`*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BTable[K, V, Cap, ccProd, ccCons], key: sink K, val: sink V) {.inline, gcsafe, notATransition.} =
  discard self.tryPut(move(key), move(val))

proc tryInsert*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BTable[K, V, Cap, ccProd, ccCons], key: sink K, val: sink V): bool {.gcsafe, notATransition.} =
  ## Inserts `(key, val)` only if `key` is not already present and `len < Cap`.
  ## Returns `true` if inserted, or `false` if `key` already exists or the table is full.
  doAssert self.core != nil, "BTable is uninitialized; call initBTable[K, V, Cap]()"
  submitBTableOp(self.core, btOpTryInsert, move(key), move(val), nil)

proc tryInsertEx*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](
    self: BTable[K, V, Cap, ccProd, ccCons],
    key: sink K,
    val: sink V,
    outInserted: ptr bool,
    outFull: ptr bool
): bool {.gcsafe, notATransition.} =
  ## Inserts `(key, val)` only if `key` is not already present and `len < capacity`,
  ## recording whether `key` was inserted (`outInserted[]`) or whether the table was full (`outFull[]`).
  doAssert self.core != nil, "BTable is uninitialized; call initBTable[K, V, Cap]()"
  submitBTableOp(self.core, btOpTryInsert, move(key), move(val), nil, outInserted, outFull)

proc insert*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BTable[K, V, Cap, ccProd, ccCons], key: sink K, val: sink V): bool {.discardable, inline, gcsafe, notATransition.} =
  ## Alias for `tryInsert`.
  self.tryInsert(move(key), move(val))

proc tryGet*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BTable[K, V, Cap, ccProd, ccCons], key: K, outVal: var V): bool {.gcsafe, notATransition.} =
  ## Looks up `key` and copies its value into `outVal`.
  ## Returns `true` if found, or `false` if absent.
  if self.core == nil or self.core.count.load(moAcquire) <= 0:
    return false
  var dummyVal: V
  submitBTableOp(self.core, btOpTryGet, key, move(dummyVal), addr outVal)

proc get*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BTable[K, V, Cap, ccProd, ccCons], key: K): Option[V] {.inline, gcsafe, notATransition.} =
  ## Returns `some(val)` if `key` is present, or `none(V)` if absent.
  var val: V
  if self.tryGet(key, val):
    some(move(val))
  else:
    none(V)

proc lookup*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BTable[K, V, Cap, ccProd, ccCons], key: K): Option[V] {.inline, gcsafe, notATransition.} =
  ## Alias for `get`.
  self.get(key)

proc contains*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BTable[K, V, Cap, ccProd, ccCons], key: K): bool {.gcsafe, notATransition.} =
  ## Returns `true` if `key` is present in the bounded table.
  if self.core == nil or self.core.count.load(moAcquire) <= 0:
    return false
  var dummyVal: V
  submitBTableOp(self.core, btOpContains, key, move(dummyVal), nil)

proc `[]`*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BTable[K, V, Cap, ccProd, ccCons], key: K): V {.gcsafe, notATransition.} =
  ## Returns the value associated with `key`.
  ## Raises `KeyError` if `key` is not found.
  var val: V
  if self.tryGet(key, val):
    return val
  raise newException(KeyError, "key not found: " & $key)

proc hasKey*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BTable[K, V, Cap, ccProd, ccCons], key: K): bool {.inline, gcsafe, notATransition.} =
  ## Alias for `contains`. Returns `true` if `key` is present in the table.
  self.contains(key)

proc remove*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BTable[K, V, Cap, ccProd, ccCons], key: K): bool {.discardable, gcsafe, notATransition.} =
  ## Removes `key` from the bounded table if present.
  ## Returns `true` if `key` was found and removed, or `false` if absent.
  if self.core == nil or self.core.count.load(moAcquire) <= 0:
    return false
  var dummyVal: V
  submitBTableOp(self.core, btOpRemove, key, move(dummyVal), nil)

proc del*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BTable[K, V, Cap, ccProd, ccCons], key: K): bool {.discardable, inline, gcsafe, notATransition.} =
  ## Alias for `remove`.
  self.remove(key)

proc tryTake*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BTable[K, V, Cap, ccProd, ccCons], key: K, outVal: var V): bool {.gcsafe, notATransition.} =
  ## Atomically removes `key`, copies its removed value into `outVal`, and returns `true`,
  ## or returns `false` if `key` is absent. Safe for `pointer`/`nil` values.
  if self.core == nil or self.core.count.load(moAcquire) <= 0:
    return false
  var dummyVal: V
  submitBTableOp(self.core, btOpTake, key, move(dummyVal), addr outVal)

proc take*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BTable[K, V, Cap, ccProd, ccCons], key: K): Option[V] {.gcsafe, notATransition.} =
  ## Atomically removes `key` and returns `some(removedVal)`, or `none(V)` if absent.
  var outVal: V
  if self.tryTake(key, outVal):
    some(move(outVal))
  else:
    none(V)

proc tryComputeIfAbsent*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](
    self: BTable[K, V, Cap, ccProd, ccCons],
    key: K,
    factory: proc(k: K): V {.gcsafe.},
    outVal: var V
): bool {.gcsafe, notATransition.} =
  ## Atomically looks up `key`; if absent and `len < Cap`, computes `factory(key)`,
  ## inserts it, stores the value in `outVal`, and returns `true`. Returns `false`
  ## only if `key` is absent and the table is full (`len == Cap`). Safe for `pointer`/`nil` values.
  doAssert self.core != nil, "BTable is uninitialized; call initBTable[K, V, Cap]()"
  let core = self.core
  while true:
    if core.combinerLock.load(moRelaxed) == 0'u64:
      var expected = 0'u64
      if core.combinerLock.compareExchange(expected, 1'u64, moAcquire, moRelaxed):
        try:
          var existing: V
          if directTryGet(core, key, existing):
            outVal = move(existing)
            result = true
          elif core.liveCount < core.effCap:
            var computed = factory(key)
            let copyComputed = computed
            if directTryPut(core, key, move(computed), overwriteExisting = false):
              outVal = copyComputed
              result = true
            else:
              result = false
          else:
            result = false
          sweepBTablePubSlots(core)
        finally:
          core.combinerLock.store(0'u64, moRelease)
        return result
    cpuPause()

proc tryComputeIfAbsent*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](
    self: BTable[K, V, Cap, ccProd, ccCons],
    key: K,
    factory: proc(k: K): V {.gcsafe.}
): Option[V] {.gcsafe, notATransition.} =
  ## Atomically looks up `key`; if absent and `len < Cap`, computes `factory(key)`,
  ## inserts it, and returns `some(val)`. Returns `none(V)` only if `key` is absent
  ## and the table is full (`len == Cap`).
  var val: V
  if self.tryComputeIfAbsent(key, factory, val):
    some(move(val))
  else:
    none(V)

proc tryComputeIfAbsent*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](
    self: BTable[K, V, Cap, ccProd, ccCons],
    key: K,
    factory: proc(): V {.gcsafe.}
): Option[V] {.inline, gcsafe, notATransition.} =
  self.tryComputeIfAbsent(key, proc(k: K): V {.gcsafe.} = factory())

proc computeIfAbsent*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](
    self: BTable[K, V, Cap, ccProd, ccCons],
    key: K,
    factory: proc(k: K): V {.gcsafe.}
): V {.inline, gcsafe, notATransition.} =
  ## Atomically returns existing value for `key` or computes and inserts `factory(key)`.
  var val: V
  let ok = self.tryComputeIfAbsent(key, factory, val)
  doAssert ok, "BTable.computeIfAbsent: table is at capacity Cap"
  val

proc computeIfAbsent*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](
    self: BTable[K, V, Cap, ccProd, ccCons],
    key: K,
    factory: proc(): V {.gcsafe.}
): V {.inline, gcsafe, notATransition.} =
  self.computeIfAbsent(key, proc(k: K): V {.gcsafe.} = factory())

proc tryAtomicUpdate*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](
    self: BTable[K, V, Cap, ccProd, ccCons],
    key: K,
    updater: proc(k: K, oldVal: V): V {.gcsafe.},
    outVal: var V
): bool {.gcsafe, notATransition.} =
  ## Atomically updates the value for `key` in-place via `updater(key, oldVal)`,
  ## stores the new value in `outVal`, and returns `true` if `key` existed, or
  ## `false` if `key` was absent. Safe for `pointer`/`nil` values.
  if self.core == nil:
    return false
  let core = self.core
  while true:
    if core.combinerLock.load(moRelaxed) == 0'u64:
      var expected = 0'u64
      if core.combinerLock.compareExchange(expected, 1'u64, moAcquire, moRelaxed):
        try:
          let hv = btableHash(key)
          let idx = findSlotIndex(core, key, hv)
          if idx >= 0:
            let newVal = updater(key, core.slots[idx].val)
            let s0 = core.slots[idx].seq.load(moRelaxed)
            core.slots[idx].seq.store(s0 + 1'u64, moRelease)
            core.slots[idx].val = newVal
            core.slots[idx].seq.store(s0 + 2'u64, moRelease)
            outVal = newVal
            result = true
          else:
            result = false
          sweepBTablePubSlots(core)
        finally:
          core.combinerLock.store(0'u64, moRelease)
        return result
    cpuPause()

proc atomicUpdate*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](
    self: BTable[K, V, Cap, ccProd, ccCons],
    key: K,
    updater: proc(k: K, oldVal: V): V {.gcsafe.}
): Option[V] {.gcsafe, notATransition.} =
  ## Atomically updates the value for `key` in-place via `updater(key, oldVal)`.
  ## Returns `some(newVal)` if `key` existed, or `none(V)` if `key` was absent.
  var val: V
  if self.tryAtomicUpdate(key, updater, val):
    some(move(val))
  else:
    none(V)

proc atomicUpdate*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](
    self: BTable[K, V, Cap, ccProd, ccCons],
    key: K,
    updater: proc(oldVal: V): V {.gcsafe.}
): Option[V] {.inline, gcsafe, notATransition.} =
  self.atomicUpdate(key, proc(k: K, oldVal: V): V {.gcsafe.} = updater(oldVal))

proc tryUpsert*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](
    self: BTable[K, V, Cap, ccProd, ccCons],
    key: K,
    initialVal: V,
    updater: proc(k: K, oldVal: V): V {.gcsafe.},
    outVal: var V
): bool {.gcsafe, notATransition.} =
  ## Atomically inserts `(key, initialVal)` if absent (when `len < Cap`), or
  ## updates the existing entry via `updater(key, oldVal)`, storing the resulting
  ## value in `outVal` and returning `true`, or `false` if `key` was absent and
  ## `len == Cap`. Safe for `pointer`/`nil` values.
  doAssert self.core != nil, "BTable is uninitialized; call initBTable[K, V, Cap]()"
  let core = self.core
  while true:
    if core.combinerLock.load(moRelaxed) == 0'u64:
      var expected = 0'u64
      if core.combinerLock.compareExchange(expected, 1'u64, moAcquire, moRelaxed):
        try:
          let hv = btableHash(key)
          let idx = findSlotIndex(core, key, hv)
          if idx >= 0:
            let newVal = updater(key, core.slots[idx].val)
            let s0 = core.slots[idx].seq.load(moRelaxed)
            core.slots[idx].seq.store(s0 + 1'u64, moRelease)
            core.slots[idx].val = newVal
            core.slots[idx].seq.store(s0 + 2'u64, moRelease)
            outVal = newVal
            result = true
          else:
            var copyInit = initialVal
            if directTryPut(core, key, move(copyInit), overwriteExisting = false):
              outVal = initialVal
              result = true
            else:
              result = false
          sweepBTablePubSlots(core)
        finally:
          core.combinerLock.store(0'u64, moRelease)
        return result
    cpuPause()

proc tryUpsert*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](
    self: BTable[K, V, Cap, ccProd, ccCons],
    key: K,
    initialVal: V,
    updater: proc(k: K, oldVal: V): V {.gcsafe.}
): Option[V] {.gcsafe, notATransition.} =
  ## Atomically inserts `(key, initialVal)` if absent (when `len < Cap`), or
  ## updates the existing entry via `updater(key, oldVal)`.
  ## Returns `some(finalVal)`, or `none(V)` if `key` was absent and `len == Cap`.
  var val: V
  if self.tryUpsert(key, initialVal, updater, val):
    some(move(val))
  else:
    none(V)

proc tryUpsert*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](
    self: BTable[K, V, Cap, ccProd, ccCons],
    key: K,
    initialVal: V,
    updater: proc(oldVal: V): V {.gcsafe.}
): Option[V] {.inline, gcsafe, notATransition.} =
  self.tryUpsert(key, initialVal, proc(k: K, oldVal: V): V {.gcsafe.} = updater(oldVal))

proc upsert*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](
    self: BTable[K, V, Cap, ccProd, ccCons],
    key: K,
    initialVal: V,
    updater: proc(k: K, oldVal: V): V {.gcsafe.}
): V {.inline, gcsafe, notATransition.} =
  var val: V
  let ok = self.tryUpsert(key, initialVal, updater, val)
  doAssert ok, "BTable.upsert: table is at capacity Cap"
  val

proc upsert*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](
    self: BTable[K, V, Cap, ccProd, ccCons],
    key: K,
    initialVal: V,
    updater: proc(oldVal: V): V {.gcsafe.}
): V {.inline, gcsafe, notATransition.} =
  let opt = self.tryUpsert(key, initialVal, updater)
  doAssert opt.isSome, "BTable.upsert: table is at capacity Cap"
  opt.get()

proc snapshotPairs*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BTable[K, V, Cap, ccProd, ccCons]): seq[(K, V)] {.gcsafe, notATransition.} =
  ## Returns a point-in-time snapshot of all `(key, val)` pairs currently in the table.
  result = @[]
  if self.core == nil:
    return
  const ProbeSlots = calcBTableProbeSlots(Cap)
  let core = self.core
  while true:
    if core.combinerLock.load(moRelaxed) == 0'u64:
      var expected = 0'u64
      if core.combinerLock.compareExchange(expected, 1'u64, moAcquire, moRelaxed):
        try:
          for i in 0 ..< ProbeSlots:
            if core.slots[i].state.load(moRelaxed) == BTableSlotOccupied:
              result.add((core.slots[i].key, core.slots[i].val))
          sweepBTablePubSlots(core)
        finally:
          core.combinerLock.store(0'u64, moRelease)
        return
    cpuPause()

proc snapshotKeys*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BTable[K, V, Cap, ccProd, ccCons]): seq[K] {.gcsafe, notATransition.} =
  result = @[]
  for pair in self.snapshotPairs():
    result.add(pair[0])

proc snapshotValues*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BTable[K, V, Cap, ccProd, ccCons]): seq[V] {.gcsafe, notATransition.} =
  result = @[]
  for pair in self.snapshotPairs():
    result.add(pair[1])

proc clear*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BTable[K, V, Cap, ccProd, ccCons]) {.gcsafe, notATransition.} =
  ## Removes and destroys all entries in the bounded table, resetting all slots
  ## to `BTableSlotEmpty`.
  if self.core == nil:
    return
  const ProbeSlots = calcBTableProbeSlots(Cap)
  let core = self.core
  while true:
    if core.combinerLock.load(moRelaxed) == 0'u64:
      var expected = 0'u64
      if core.combinerLock.compareExchange(expected, 1'u64, moAcquire, moRelaxed):
        try:
          for i in 0 ..< ProbeSlots:
            if core.slots[i].state.load(moRelaxed) != BTableSlotEmpty:
              let s0 = core.slots[i].seq.load(moRelaxed)
              core.slots[i].seq.store(s0 + 1'u64, moRelease)
              reset(core.slots[i].key)
              reset(core.slots[i].val)
              core.slots[i].hashVal = 0'u32
              core.slots[i].state.store(BTableSlotEmpty, moRelease)
              core.slots[i].seq.store(s0 + 2'u64, moRelease)
          core.liveCount = 0
          core.count.store(0, moRelease)
          sweepBTablePubSlots(core)
        finally:
          core.combinerLock.store(0'u64, moRelease)
        return
    cpuPause()

proc clearWith*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](
    self: BTable[K, V, Cap, ccProd, ccCons],
    destructor: proc(key: K, val: V, userData: pointer) {.cdecl, gcsafe.},
    userData: pointer
) {.gcsafe, notATransition.} =
  ## Clears all entries in the bounded table, invoking `destructor(key, val, userData)`
  ## (when non-nil) on each occupied slot before resetting all slots to `BTableSlotEmpty`.
  if self.core == nil:
    return
  if destructor == nil:
    self.clear()
    return
  const ProbeSlots = calcBTableProbeSlots(Cap)
  let core = self.core
  while true:
    if core.combinerLock.load(moRelaxed) == 0'u64:
      var expected = 0'u64
      if core.combinerLock.compareExchange(expected, 1'u64, moAcquire, moRelaxed):
        try:
          for i in 0 ..< ProbeSlots:
            let st = core.slots[i].state.load(moRelaxed)
            if st != BTableSlotEmpty:
              let k = core.slots[i].key
              let v = core.slots[i].val
              let s0 = core.slots[i].seq.load(moRelaxed)
              core.slots[i].seq.store(s0 + 1'u64, moRelease)
              reset(core.slots[i].key)
              reset(core.slots[i].val)
              core.slots[i].hashVal = 0'u32
              core.slots[i].state.store(BTableSlotEmpty, moRelease)
              core.slots[i].seq.store(s0 + 2'u64, moRelease)
              if st == BTableSlotOccupied:
                try:
                  destructor(k, v, userData)
                except:
                  discard
          core.liveCount = 0
          core.count.store(0, moRelease)
          sweepBTablePubSlots(core)
        finally:
          core.combinerLock.store(0'u64, moRelease)
        return
    cpuPause()


proc len*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BTable[K, V, Cap, ccProd, ccCons]): int {.inline, notATransition.} =
  ## Returns the current number of active key-value entries in the table (`0 .. capacity`).
  if self.core == nil:
    0
  else:
    clamp(self.core.count.load(moAcquire), 0, self.core.effCap)

proc capacity*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BTable[K, V, Cap, ccProd, ccCons]): int {.inline, notATransition.} =
  ## Returns the effective maximum entry capacity of the bounded table (defaults to `Cap`).
  if self.core == nil:
    Cap
  else:
    self.core.effCap

proc setEffectiveCapacity*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BTable[K, V, Cap, ccProd, ccCons], effCap: int) {.notATransition.} =
  ## Sets the effective maximum entry count (`1 .. Cap`) on an empty `BTable`.
  if self.core != nil:
    self.core.effCap = clamp(effCap, 1, Cap)

proc probeCapacity*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BTable[K, V, Cap, ccProd, ccCons]): int {.inline, notATransition.} =
  ## Returns the underlying preallocated open-addressing probe table size (`2 * nextPowerOfTwo(Cap)`).
  calcBTableProbeSlots(Cap)

proc isEmpty*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BTable[K, V, Cap, ccProd, ccCons]): bool {.inline, notATransition.} =
  ## Returns `true` if the table currently contains no entries.
  self.len() == 0

proc isFull*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BTable[K, V, Cap, ccProd, ccCons]): bool {.inline, notATransition.} =
  ## Returns `true` if the table has reached its effective capacity.
  self.len() >= self.capacity()

# ---------------------------------------------------------------------------
# Bound Endpoint Operations (`TableWriterTag` / `TableReaderTag`)
# ---------------------------------------------------------------------------

proc tryPut*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](
    ep: Bound[(K, V), TableWriterTag, BTable[K, V, Cap, ccProd, ccCons]],
    key: sink K,
    val: sink V
): bool {.inline, gcsafe, notATransition.} =
  ep.queue[].tryPut(move(key), move(val))

proc put*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](
    ep: Bound[(K, V), TableWriterTag, BTable[K, V, Cap, ccProd, ccCons]],
    key: sink K,
    val: sink V
): bool {.discardable, inline, gcsafe, notATransition.} =
  ep.queue[].put(move(key), move(val))

proc `[]=`*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](
    ep: Bound[(K, V), TableWriterTag, BTable[K, V, Cap, ccProd, ccCons]],
    key: sink K,
    val: sink V
) {.inline, gcsafe, notATransition.} =
  ep.queue[][move(key)] = move(val)

proc tryInsert*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](
    ep: Bound[(K, V), TableWriterTag, BTable[K, V, Cap, ccProd, ccCons]],
    key: sink K,
    val: sink V
): bool {.inline, gcsafe, notATransition.} =
  ep.queue[].tryInsert(move(key), move(val))

proc insert*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](
    ep: Bound[(K, V), TableWriterTag, BTable[K, V, Cap, ccProd, ccCons]],
    key: sink K,
    val: sink V
): bool {.discardable, inline, gcsafe, notATransition.} =
  ep.queue[].insert(move(key), move(val))

proc remove*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](
    ep: Bound[(K, V), TableWriterTag, BTable[K, V, Cap, ccProd, ccCons]],
    key: K
): bool {.discardable, inline, gcsafe, notATransition.} =
  ep.queue[].remove(key)

proc del*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](
    ep: Bound[(K, V), TableWriterTag, BTable[K, V, Cap, ccProd, ccCons]],
    key: K
): bool {.discardable, inline, gcsafe, notATransition.} =
  ep.queue[].del(key)

proc take*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](
    ep: Bound[(K, V), TableWriterTag, BTable[K, V, Cap, ccProd, ccCons]],
    key: K
): Option[V] {.inline, gcsafe, notATransition.} =
  ep.queue[].take(key)

proc clear*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](
    ep: Bound[(K, V), TableWriterTag, BTable[K, V, Cap, ccProd, ccCons]]
) {.inline, gcsafe, notATransition.} =
  ep.queue[].clear()

proc tryGet*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality;
  Tag: TableWriterTag | TableReaderTag
](
    ep: Bound[(K, V), Tag, BTable[K, V, Cap, ccProd, ccCons]],
    key: K,
    outVal: var V
): bool {.inline, gcsafe, notATransition.} =
  ep.queue[].tryGet(key, outVal)

proc get*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality;
  Tag: TableWriterTag | TableReaderTag
](
    ep: Bound[(K, V), Tag, BTable[K, V, Cap, ccProd, ccCons]],
    key: K
): Option[V] {.inline, gcsafe, notATransition.} =
  ep.queue[].get(key)

proc lookup*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality;
  Tag: TableWriterTag | TableReaderTag
](
    ep: Bound[(K, V), Tag, BTable[K, V, Cap, ccProd, ccCons]],
    key: K
): Option[V] {.inline, gcsafe, notATransition.} =
  ep.queue[].lookup(key)

proc contains*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality;
  Tag: TableWriterTag | TableReaderTag
](
    ep: Bound[(K, V), Tag, BTable[K, V, Cap, ccProd, ccCons]],
    key: K
): bool {.inline, gcsafe, notATransition.} =
  ep.queue[].contains(key)

proc `[]`*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality;
  Tag: TableWriterTag | TableReaderTag
](
    ep: Bound[(K, V), Tag, BTable[K, V, Cap, ccProd, ccCons]],
    key: K
): V {.inline, gcsafe, notATransition.} =
  ep.queue[][key]

proc hasKey*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality;
  Tag: TableWriterTag | TableReaderTag
](
    ep: Bound[(K, V), Tag, BTable[K, V, Cap, ccProd, ccCons]],
    key: K
): bool {.inline, gcsafe, notATransition.} =
  ep.queue[].hasKey(key)

proc len*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality;
  Tag: TableWriterTag | TableReaderTag
](
    ep: Bound[(K, V), Tag, BTable[K, V, Cap, ccProd, ccCons]]
): int {.inline, notATransition.} =
  ep.queue[].len

proc capacity*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality;
  Tag: TableWriterTag | TableReaderTag
](
    ep: Bound[(K, V), Tag, BTable[K, V, Cap, ccProd, ccCons]]
): int {.inline, notATransition.} =
  ep.queue[].capacity

proc isEmpty*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality;
  Tag: TableWriterTag | TableReaderTag
](
    ep: Bound[(K, V), Tag, BTable[K, V, Cap, ccProd, ccCons]]
): bool {.inline, notATransition.} =
  ep.queue[].isEmpty

proc isFull*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality;
  Tag: TableWriterTag | TableReaderTag
](
    ep: Bound[(K, V), Tag, BTable[K, V, Cap, ccProd, ccCons]]
): bool {.inline, notATransition.} =
  ep.queue[].isFull

# ---------------------------------------------------------------------------
# Role-Violation & Lifecycle-Violation Compile-Time Guards (`BTable`)
# ---------------------------------------------------------------------------

proc tryPut*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](
    ep: Bound[(K, V), TableReaderTag, BTable[K, V, Cap, ccProd, ccCons]],
    key: sink K,
    val: sink V
): bool {.
  error:
    "Cannot call 'tryPut' on a read-only BTable endpoint (Bound[(K, V), TableReaderTag, BTable[...]]). " &
    "Use a writer endpoint (getWriter / withBoundWriter) to mutate entries.",
  notATransition
.}

proc put*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](
    ep: Bound[(K, V), TableReaderTag, BTable[K, V, Cap, ccProd, ccCons]],
    key: sink K,
    val: sink V
): bool {.
  error:
    "Cannot call 'put' on a read-only BTable endpoint (Bound[(K, V), TableReaderTag, BTable[...]]). " &
    "Use a writer endpoint (getWriter / withBoundWriter) to mutate entries.",
  notATransition
.}

proc tryInsert*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](
    ep: Bound[(K, V), TableReaderTag, BTable[K, V, Cap, ccProd, ccCons]],
    key: sink K,
    val: sink V
): bool {.
  error:
    "Cannot call 'tryInsert' on a read-only BTable endpoint (Bound[(K, V), TableReaderTag, BTable[...]]). " &
    "Use a writer endpoint (getWriter / withBoundWriter) to mutate entries.",
  notATransition
.}

proc insert*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](
    ep: Bound[(K, V), TableReaderTag, BTable[K, V, Cap, ccProd, ccCons]],
    key: sink K,
    val: sink V
): bool {.
  error:
    "Cannot call 'insert' on a read-only BTable endpoint (Bound[(K, V), TableReaderTag, BTable[...]]). " &
    "Use a writer endpoint (getWriter / withBoundWriter) to mutate entries.",
  notATransition
.}

proc remove*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](
    ep: Bound[(K, V), TableReaderTag, BTable[K, V, Cap, ccProd, ccCons]],
    key: K
): bool {.
  error:
    "Cannot call 'remove' on a read-only BTable endpoint (Bound[(K, V), TableReaderTag, BTable[...]]). " &
    "Use a writer endpoint (getWriter / withBoundWriter) to mutate entries.",
  notATransition
.}

proc del*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](
    ep: Bound[(K, V), TableReaderTag, BTable[K, V, Cap, ccProd, ccCons]],
    key: K
): bool {.
  error:
    "Cannot call 'del' on a read-only BTable endpoint (Bound[(K, V), TableReaderTag, BTable[...]]). " &
    "Use a writer endpoint (getWriter / withBoundWriter) to mutate entries.",
  notATransition
.}

proc take*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](
    ep: Bound[(K, V), TableReaderTag, BTable[K, V, Cap, ccProd, ccCons]],
    key: K
): Option[V] {.
  error:
    "Cannot call 'take' on a read-only BTable endpoint (Bound[(K, V), TableReaderTag, BTable[...]]). " &
    "Use a writer endpoint (getWriter / withBoundWriter) to mutate entries.",
  notATransition
.}

proc clear*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](
    ep: Bound[(K, V), TableReaderTag, BTable[K, V, Cap, ccProd, ccCons]]
) {.
  error:
    "Cannot call 'clear' on a read-only BTable endpoint (Bound[(K, V), TableReaderTag, BTable[...]]). " &
    "Use a writer endpoint (getWriter / withBoundWriter) to mutate entries.",
  notATransition
.}

proc put*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality;
  Tag
](
    ep: Unbound[(K, V), Tag, BTable[K, V, Cap, ccProd, ccCons]],
    key: sink K,
    val: sink V
): bool {.
  error:
    "Cannot call 'put' on an Unbound BTable endpoint. " &
    "Bind the endpoint to the current thread first via `bindToThread(ep)` or `withBoundWriter`.",
  notATransition
.}

proc get*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality;
  Tag
](
    ep: Unbound[(K, V), Tag, BTable[K, V, Cap, ccProd, ccCons]],
    key: K
): Option[V] {.
  error:
    "Cannot call 'get' on an Unbound BTable endpoint. " &
    "Bind the endpoint to the current thread first via `bindToThread(ep)` or `withBoundReader`.",
  notATransition
.}

verifyTypestates()
