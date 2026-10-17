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

  BTableCore*[K, V; Cap: static int; ProbeSlots: static int] = object
    combinerLock* {.align: CacheLineBytes.}: Atomic[uint64]
    count* {.align: CacheLineBytes.}: Atomic[int]
    activePubSlots* {.align: CacheLineBytes.}: Atomic[int]
    rc* {.align: CacheLineBytes.}: Atomic[int]
    liveCount*: int
    pubSlots*: array[BTableMaxCombinerSlots, BTablePubSlot[K, V]]
    slots*: array[ProbeSlots, BTableSlot[K, V]]

  BTable*[
    K, V;
    Cap: static int;
    ccProd: static PinScopeCardinality = ccMulti;
    ccCons: static PinScopeCardinality = ccMulti
  ] = object
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
    overwriteExisting: bool
): bool {.inline.} =
  ## Inserts or updates `(key, val)`.
  ## Preserves the Tombstone Probe Invariant: records `firstTombstone` and
  ## continues probing until `key` is found, an `Empty` slot is reached, or all
  ## `ProbeSlots` have been inspected.
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

  if core.liveCount >= Cap or targetIdx < 0:
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
            overwriteExisting = true
          )
          reset(core.pubSlots[i].inKey)
          reset(core.pubSlots[i].inVal)
        of btOpTryInsert:
          core.pubSlots[i].ok = directTryPut(
            core,
            move(core.pubSlots[i].inKey),
            move(core.pubSlots[i].inVal),
            overwriteExisting = false
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
](self: BTable[K, V, Cap, ccProd, ccCons]) =
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
) =
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
) =
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
    outVal: ptr V
): bool {.inline, gcsafe.} =
  if core.combinerLock.load(moRelaxed) == 0'u64:
    var expected = 0'u64
    if core.combinerLock.compareExchange(expected, 1'u64, moAcquire, moRelaxed):
      try:
        case kind
        of btOpTryPut:
          result = directTryPut(core, move(key), move(val), overwriteExisting = true)
        of btOpTryInsert:
          result = directTryPut(core, move(key), move(val), overwriteExisting = false)
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
    slot.status.store(btPubPending, moRelease)

    while true:
      if slot.status.load(moAcquire) != btPubPending:
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
            if slot.ok and outVal != nil and kind in {btOpTryGet, btOpTake}:
              outVal[] = move(slot.outVal)
              reset(slot.outVal)
            return slot.ok
      for _ in 0 ..< 128:
        if slot.status.load(moAcquire) != btPubPending:
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
              result = directTryPut(core, move(key), move(val), overwriteExisting = true)
            of btOpTryInsert:
              result = directTryPut(core, move(key), move(val), overwriteExisting = false)
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
](self: BTable[K, V, Cap, ccProd, ccCons], key: sink K, val: sink V): bool {.gcsafe.} =
  ## Inserts `(key, val)` or updates `key` if already present.
  ## Returns `true` on success, or `false` if `key` is new and the table is full (`len == Cap`).
  doAssert self.core != nil, "BTable is uninitialized; call initBTable[K, V, Cap]()"
  submitBTableOp(self.core, btOpTryPut, move(key), move(val), nil)

proc put*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BTable[K, V, Cap, ccProd, ccCons], key: sink K, val: sink V): bool {.discardable, inline, gcsafe.} =
  ## Inserts or updates `(key, val)`. Returns `false` if `key` is absent and `len == Cap`.
  self.tryPut(move(key), move(val))

proc `[]=`*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BTable[K, V, Cap, ccProd, ccCons], key: sink K, val: sink V) {.inline, gcsafe.} =
  discard self.tryPut(move(key), move(val))

proc tryInsert*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BTable[K, V, Cap, ccProd, ccCons], key: sink K, val: sink V): bool {.gcsafe.} =
  ## Inserts `(key, val)` only if `key` is not already present and `len < Cap`.
  ## Returns `true` if inserted, or `false` if `key` already exists or the table is full.
  doAssert self.core != nil, "BTable is uninitialized; call initBTable[K, V, Cap]()"
  submitBTableOp(self.core, btOpTryInsert, move(key), move(val), nil)

proc insert*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BTable[K, V, Cap, ccProd, ccCons], key: sink K, val: sink V): bool {.discardable, inline, gcsafe.} =
  ## Alias for `tryInsert`.
  self.tryInsert(move(key), move(val))

proc tryGet*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BTable[K, V, Cap, ccProd, ccCons], key: K, outVal: var V): bool {.gcsafe.} =
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
](self: BTable[K, V, Cap, ccProd, ccCons], key: K): Option[V] {.inline, gcsafe.} =
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
](self: BTable[K, V, Cap, ccProd, ccCons], key: K): Option[V] {.inline, gcsafe.} =
  ## Alias for `get`.
  self.get(key)

proc contains*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BTable[K, V, Cap, ccProd, ccCons], key: K): bool {.gcsafe.} =
  ## Returns `true` if `key` is present in the bounded table.
  if self.core == nil or self.core.count.load(moAcquire) <= 0:
    return false
  var dummyVal: V
  submitBTableOp(self.core, btOpContains, key, move(dummyVal), nil)

proc remove*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BTable[K, V, Cap, ccProd, ccCons], key: K): bool {.discardable, gcsafe.} =
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
](self: BTable[K, V, Cap, ccProd, ccCons], key: K): bool {.discardable, inline, gcsafe.} =
  ## Alias for `remove`.
  self.remove(key)

proc take*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BTable[K, V, Cap, ccProd, ccCons], key: K): Option[V] {.gcsafe.} =
  ## Atomically removes `key` and returns `some(removedVal)`, or `none(V)` if absent.
  if self.core == nil or self.core.count.load(moAcquire) <= 0:
    return none(V)
  var dummyVal: V
  var outVal: V
  if submitBTableOp(self.core, btOpTake, key, move(dummyVal), addr outVal):
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
    factory: proc(k: K): V {.gcsafe.}
): Option[V] {.gcsafe.} =
  ## Atomically looks up `key`; if absent and `len < Cap`, computes `factory(key)`,
  ## inserts it, and returns `some(val)`. Returns `none(V)` only if `key` is absent
  ## and the table is full (`len == Cap`).
  doAssert self.core != nil, "BTable is uninitialized; call initBTable[K, V, Cap]()"
  let core = self.core
  while true:
    if core.combinerLock.load(moRelaxed) == 0'u64:
      var expected = 0'u64
      if core.combinerLock.compareExchange(expected, 1'u64, moAcquire, moRelaxed):
        try:
          var existing: V
          if directTryGet(core, key, existing):
            result = some(move(existing))
          elif core.liveCount < Cap:
            var computed = factory(key)
            let copyComputed = computed
            if directTryPut(core, key, move(computed), overwriteExisting = false):
              result = some(copyComputed)
            else:
              result = none(V)
          else:
            result = none(V)
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
    factory: proc(): V {.gcsafe.}
): Option[V] {.inline, gcsafe.} =
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
): V {.inline, gcsafe.} =
  ## Atomically returns existing value for `key` or computes and inserts `factory(key)`.
  let opt = self.tryComputeIfAbsent(key, factory)
  doAssert opt.isSome, "BTable.computeIfAbsent: table is at capacity Cap"
  opt.get()

proc computeIfAbsent*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](
    self: BTable[K, V, Cap, ccProd, ccCons],
    key: K,
    factory: proc(): V {.gcsafe.}
): V {.inline, gcsafe.} =
  let opt = self.tryComputeIfAbsent(key, factory)
  doAssert opt.isSome, "BTable.computeIfAbsent: table is at capacity Cap"
  opt.get()

proc atomicUpdate*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](
    self: BTable[K, V, Cap, ccProd, ccCons],
    key: K,
    updater: proc(k: K, oldVal: V): V {.gcsafe.}
): Option[V] {.gcsafe.} =
  ## Atomically updates the value for `key` in-place via `updater(key, oldVal)`.
  ## Returns `some(newVal)` if `key` existed, or `none(V)` if `key` was absent.
  if self.core == nil:
    return none(V)
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
            result = some(newVal)
          else:
            result = none(V)
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
    updater: proc(oldVal: V): V {.gcsafe.}
): Option[V] {.inline, gcsafe.} =
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
    updater: proc(k: K, oldVal: V): V {.gcsafe.}
): Option[V] {.gcsafe.} =
  ## Atomically inserts `(key, initialVal)` if absent (when `len < Cap`), or
  ## updates the existing entry via `updater(key, oldVal)`.
  ## Returns `some(finalVal)`, or `none(V)` if `key` was absent and `len == Cap`.
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
            result = some(newVal)
          else:
            var copyInit = initialVal
            if directTryPut(core, key, move(copyInit), overwriteExisting = false):
              result = some(initialVal)
            else:
              result = none(V)
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
    updater: proc(oldVal: V): V {.gcsafe.}
): Option[V] {.inline, gcsafe.} =
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
): V {.inline, gcsafe.} =
  let opt = self.tryUpsert(key, initialVal, updater)
  doAssert opt.isSome, "BTable.upsert: table is at capacity Cap"
  opt.get()

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
): V {.inline, gcsafe.} =
  let opt = self.tryUpsert(key, initialVal, updater)
  doAssert opt.isSome, "BTable.upsert: table is at capacity Cap"
  opt.get()

proc snapshotPairs*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BTable[K, V, Cap, ccProd, ccCons]): seq[(K, V)] {.gcsafe.} =
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
](self: BTable[K, V, Cap, ccProd, ccCons]): seq[K] {.gcsafe.} =
  result = @[]
  for pair in self.snapshotPairs():
    result.add(pair[0])

proc snapshotValues*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BTable[K, V, Cap, ccProd, ccCons]): seq[V] {.gcsafe.} =
  result = @[]
  for pair in self.snapshotPairs():
    result.add(pair[1])

proc clear*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BTable[K, V, Cap, ccProd, ccCons]) {.gcsafe.} =
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

proc len*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BTable[K, V, Cap, ccProd, ccCons]): int {.inline.} =
  ## Returns the current number of active key-value entries in the table (`0 .. Cap`).
  if self.core == nil:
    0
  else:
    clamp(self.core.count.load(moAcquire), 0, Cap)

proc capacity*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BTable[K, V, Cap, ccProd, ccCons]): int {.inline.} =
  ## Returns the compile-time maximum entry capacity `Cap` of the bounded table.
  Cap

proc probeCapacity*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BTable[K, V, Cap, ccProd, ccCons]): int {.inline.} =
  ## Returns the underlying preallocated open-addressing probe table size (`2 * nextPowerOfTwo(Cap)`).
  calcBTableProbeSlots(Cap)

proc isEmpty*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BTable[K, V, Cap, ccProd, ccCons]): bool {.inline.} =
  ## Returns `true` if the table currently contains no entries.
  self.len() == 0

proc isFull*[
  K, V;
  Cap: static int;
  ccProd: static PinScopeCardinality;
  ccCons: static PinScopeCardinality
](self: BTable[K, V, Cap, ccProd, ccCons]): bool {.inline.} =
  ## Returns `true` if the table has reached capacity `Cap`.
  self.len() >= Cap
