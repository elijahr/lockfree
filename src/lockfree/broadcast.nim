## # Concurrency Topology: MPMC / SPMC Multicast Pub-Sub Ring Buffer (`BroadcastRing[T]` / `TopicBus[T]`)
##
## | Dimension              | Architectural Specification                                             |
## |:-----------------------|:------------------------------------------------------------------------|
## | **Topologies**         | SPMC (Single-Publisher Multi-Consumer) / MPMC (Multi-Publisher Multicast) |
## | **Delivery Model**     | 1-to-N Fan-Out Broadcast (Every message delivered to ALL active readers) |
## | **Buffer Geometry**    | Power-of-two circular ring buffer (2^k) with monotonic sequence counters |
## | **Consumer Tracking**  | Independent reader cursors (`BroadcastCursor[T]`) dynamically registered  |
## | **Overflow Policies**  | `omDropOldest` (Lossy real-time ring) vs `omBackoff` (Lossless backpressure) |
## | **Multiplexer**        | `TopicBus[T]` mapping topic keys (`string`) to dedicated BroadcastRings  |
## | **Slot Lifetime**      | Atomic refcounted payload box (`VBox[T]`) with safe ARC/ORC lifecycle    |
## | **Cache Alignment**    | Slots, tail counters, and cursor descriptors aligned to `CacheLineBytes` |
## | **Progress Guarantees**| Publishers: Lock-Free (`omDropOldest`) / Flow-Controlled (`omBackoff`)   |
## |                        | Readers: Wait-Free Population (`omDropOldest`) / Lock-Free (`omBackoff`)  |
##
## ## Overview
##
## `BroadcastRing[T]` is a high-performance lock-free multicast broadcast ring buffer.
## In contrast to point-to-point queues where each item is consumed by exactly one
## reader, `BroadcastRing[T]` delivers every message to all active registered subscribers.
##
## `TopicBus[T]` provides a multiplexed Pub-Sub bus routing messages by topic string to
## automatically provisioned `BroadcastRing[T]` instances backed by `Ctrie`.

when not compileOption("threads"):
  {.error: "lockfree/broadcast requires --threads:on".}

import std/[options]
import ./atomics
import ./ctrie
import ./internal/aligned_alloc

const
  DefaultRingCapacity* = 1024
  DefaultMaxReaders* = 64
  CacheLine* = aligned_alloc.CacheLineBytes
  moAcqRel* = moAcquireRelease
  moSeqCst* = moSequentiallyConsistent

when defined(windows):
  proc c_aligned_malloc(size: csize_t, alignment: csize_t): pointer {.
    importc: "_aligned_malloc", header: "<malloc.h>".}
else:
  proc c_posix_memalign(memptr: ptr pointer, alignment: csize_t, size: csize_t): cint {.
    importc: "posix_memalign", header: "<stdlib.h>".}

proc allocAlignedMemory(size: int, alignment: int = CacheLine): pointer {.inline.} =
  when defined(windows):
    result = c_aligned_malloc(csize_t(size), csize_t(alignment))
    if result == nil:
      raise newException(OutOfMemDefect, "_aligned_malloc failed")
  else:
    var p: pointer
    if c_posix_memalign(addr p, csize_t(alignment), csize_t(size)) != 0:
      raise newException(OutOfMemDefect, "posix_memalign failed")
    result = p
  zeroMem(result, size)

proc nextPowerOfTwo(n: int): int {.inline.} =
  var v = n - 1
  v = v or (v shr 1)
  v = v or (v shr 2)
  v = v or (v shr 4)
  v = v or (v shr 8)
  v = v or (v shr 16)
  when sizeof(int) == 8:
    v = v or (v shr 32)
  result = max(16, v + 1)

# ---------------------------------------------------------------------------
# Enums & Result Types
# ---------------------------------------------------------------------------

type
  OverflowMode* = enum
    omDropOldest  ## Overwrite oldest unread items; slow consumers lag and skip
    omBackoff     ## Stalls publisher until slowest active cursor advances

  SubscriptionOrigin* = enum
    soFromLatest   ## Start reading from messages published AFTER subscription
    soFromEarliest ## Replay available ring history up to current capacity

  PollResultKind* = enum
    prSuccess     ## Item successfully read
    prEmpty       ## No new messages available at this cursor
    prLagged      ## Reader lagged behind overwritten horizon; skipped messages

  PollResult*[T] = object
    case kind*: PollResultKind
    of prSuccess:
      val*: T
    of prEmpty:
      discard
    of prLagged:
      skippedCount*: uint64

# ---------------------------------------------------------------------------
# Payload Box: VBox[T] (ARC/ORC Refcount Safety)
# ---------------------------------------------------------------------------

type
  VBox*[T] = object
    rc*: Atomic[int32]
    val*: T

proc allocVBox[T](item: sink T): ptr VBox[T] {.inline.} =
  result = cast[ptr VBox[T]](allocShared0(sizeof(VBox[T])))
  result.rc.store(1, moRelaxed)
  result.val = item

proc incRef[T](box: ptr VBox[T]) {.inline.} =
  if box != nil:
    discard box.rc.fetchAdd(1, moRelaxed)

proc decRef[T](box: ptr VBox[T]) {.inline, gcsafe.} =
  {.cast(gcsafe).}:
    if box != nil:
      if box.rc.fetchSub(1, moRelease) == 1:
        threadFence(moAcquire)
        `=destroy`(box.val)
        deallocShared(box)

# ---------------------------------------------------------------------------
# Ring Slot & Cursor Descriptors
# ---------------------------------------------------------------------------

type
  BroadcastSlot*[T] = object
    seq*: Atomic[uint64]               ## Monotonic sequence number published into this slot
    vbox*: Atomic[ptr VBox[T]]         ## Pointer to heap-allocated payload box
    pad: array[CacheLine - sizeof(Atomic[uint64]) - sizeof(Atomic[pointer]), byte]

  BroadcastSlotBuffer[T] = ptr UncheckedArray[BroadcastSlot[T]]

  CursorState = enum
    csUnused
    csActive

  CursorDescriptor = object
    state*: Atomic[CursorState]
    currentSeq*: Atomic[uint64]        ## Monotonic sequence reader is waiting to consume
    pad: array[CacheLine - sizeof(Atomic[CursorState]) - sizeof(Atomic[uint64]), byte]

  CursorDescriptorBuffer = ptr UncheckedArray[CursorDescriptor]

  BroadcastRingConfig* = object
    capacity*: int                     ## Power of two (e.g. 1024, 65536)
    overflowMode*: OverflowMode        ## omDropOldest or omBackoff
    maxReaders*: int                   ## Maximum concurrent registered cursors (default 64)

  BroadcastRingCore*[T] = object
    capacity*: int
    mask*: uint64
    overflowMode*: OverflowMode
    maxReaders*: int

    publisherTail*: Atomic[uint64]     ## Monotonically incrementing publication ticket
    publishedHead*: Atomic[uint64]     ## Highest fully published sequence number
    padTail: array[CacheLine - 2 * sizeof(Atomic[uint64]), byte]

    slots*: BroadcastSlotBuffer[T]
    cursors*: CursorDescriptorBuffer
    activeCursorCount*: Atomic[int32]
    rc*: Atomic[int]

  BroadcastRing*[T] = object
    core*: ptr BroadcastRingCore[T]

  BroadcastCursor*[T] = object
    cursorId*: int                     ## Slot in the ring's cursor table
    readSeq*: uint64                   ## Reader's local non-atomic sequence counter
    lagCount*: uint64                  ## Total number of messages skipped due to overflow
    ring*: BroadcastRing[T]            ## Handle keeping ring alive

# ---------------------------------------------------------------------------
# BroadcastRing[T] Construction & Lifecycle
# ---------------------------------------------------------------------------

proc initBroadcastRing*[T](
    capacity: int = DefaultRingCapacity,
    overflowMode: OverflowMode = omDropOldest,
    maxReaders: int = DefaultMaxReaders
): BroadcastRing[T] =
  ## Constructs a new concurrent multicast broadcast ring.
  let cap = nextPowerOfTwo(capacity)
  let maxR = max(1, maxReaders)

  let core = cast[ptr BroadcastRingCore[T]](allocShared0(sizeof(BroadcastRingCore[T])))
  core.capacity = cap
  core.mask = (cap - 1).uint64
  core.overflowMode = overflowMode
  core.maxReaders = maxR
  core.publisherTail.store(0, moRelaxed)
  core.publishedHead.store(0, moRelaxed)
  core.activeCursorCount.store(0, moRelaxed)
  core.rc.store(1, moRelaxed)

  # Allocate cache-aligned slots
  let slotsSize = cap * sizeof(BroadcastSlot[T])
  core.slots = cast[BroadcastSlotBuffer[T]](allocAlignedMemory(slotsSize, CacheLine))
  for i in 0 ..< cap:
    core.slots[i].seq.store(0, moRelaxed)
    core.slots[i].vbox.store(nil, moRelaxed)

  # Allocate cache-aligned cursor table
  let cursorsSize = maxR * sizeof(CursorDescriptor)
  core.cursors = cast[CursorDescriptorBuffer](allocAlignedMemory(cursorsSize, CacheLine))
  for i in 0 ..< maxR:
    core.cursors[i].state.store(csUnused, moRelaxed)
    core.cursors[i].currentSeq.store(0, moRelaxed)

  result.core = core

proc `=destroy`*[T](self: var BroadcastRing[T]) {.gcsafe.} =
  if self.core != nil:
    if self.core.rc.fetchSub(1, moRelease) == 1:
      threadFence(moAcquire)
      for i in 0 ..< self.core.capacity:
        let vb = self.core.slots[i].vbox.load(moRelaxed)
        if vb != nil:
          decRef(vb)
          self.core.slots[i].vbox.store(nil, moRelaxed)
      freeAligned(self.core.slots)
      freeAligned(self.core.cursors)
      deallocShared(self.core)
    self.core = nil

proc `=copy`*[T](dest: var BroadcastRing[T], src: BroadcastRing[T]) =
  if dest.core != src.core:
    `=destroy`(dest)
    dest.core = src.core
    if dest.core != nil:
      discard dest.core.rc.fetchAdd(1, moRelaxed)

proc `=sink`*[T](dest: var BroadcastRing[T], src: BroadcastRing[T]) =
  `=destroy`(dest)
  dest.core = src.core

proc isNil*[T](self: BroadcastRing[T]): bool {.inline.} =
  self.core == nil

proc capacity*[T](self: BroadcastRing[T]): int {.inline.} =
  if self.core == nil: 0 else: self.core.capacity

proc subscriberCount*[T](self: BroadcastRing[T]): int {.inline.} =
  if self.core == nil: 0 else: max(0, self.core.activeCursorCount.load(moRelaxed))

proc len*[T](self: BroadcastRing[T]): int {.inline.} =
  ## Returns the number of published messages currently residing in the ring.
  if self.core == nil: return 0
  let head = self.core.publishedHead.load(moAcquire)
  return min(self.core.capacity, int(head))

# ---------------------------------------------------------------------------
# Publishing Operations
# ---------------------------------------------------------------------------

proc publish*[T](self: BroadcastRing[T], item: sink T) =
  ## Publishes a message to all active subscribers.
  ## In `omDropOldest`, overwrites oldest messages if the ring is full without blocking.
  ## In `omBackoff`, stalls/spins until the slowest active subscriber advances.
  let core = self.core
  let cap = core.capacity.uint64

  # Claim next monotonic sequence ticket
  let targetSeq = core.publisherTail.fetchAdd(1, moAcqRel)
  let idx = targetSeq and core.mask
  let slot = addr core.slots[idx]

  # If omBackoff, wait until the slowest active reader has read past this slot
  if core.overflowMode == omBackoff:
    while true:
      var slowestSeq = targetSeq
      var hasActive = false
      for i in 0 ..< core.maxReaders:
        if core.cursors[i].state.load(moAcquire) == csActive:
          hasActive = true
          let cseq = core.cursors[i].currentSeq.load(moAcquire)
          if cseq < slowestSeq:
            slowestSeq = cseq
      if not hasActive or (targetSeq - slowestSeq < cap):
        break
      cpuRelax()

  # Vyukov-style turn invariant: ensure prior write to this slot completed
  let expectedSeq = if targetSeq < cap: 0'u64 else: targetSeq - cap + 1
  while slot.seq.load(moAcquire) != expectedSeq:
    cpuRelax()

  # Allocate new VBox and store into slot
  let newBox = allocVBox(item)
  let oldBox = slot.vbox.load(moRelaxed)
  slot.vbox.store(newBox, moRelaxed)

  # Publish sequence number with release ordering
  slot.seq.store(targetSeq + 1, moRelease)

  # Advance publishedHead if this write reaches head
  var curHead = core.publishedHead.load(moRelaxed)
  while targetSeq + 1 > curHead:
    if core.publishedHead.compareExchangeWeak(curHead, targetSeq + 1, moRelease, moRelaxed):
      break

  # Clean up overwritten VBox
  if oldBox != nil:
    decRef(oldBox)

proc tryPublish*[T](self: BroadcastRing[T], item: sink T): bool =
  ## Non-blocking publish attempt.
  ## Returns true if published. In `omBackoff`, returns false if the ring is currently full.
  let core = self.core
  let cap = core.capacity.uint64

  if core.overflowMode == omBackoff:
    let curTail = core.publisherTail.load(moAcquire)
    var slowestSeq = curTail
    var hasActive = false
    for i in 0 ..< core.maxReaders:
      if core.cursors[i].state.load(moAcquire) == csActive:
        hasActive = true
        let cseq = core.cursors[i].currentSeq.load(moAcquire)
        if cseq < slowestSeq:
          slowestSeq = cseq
    if hasActive and (curTail - slowestSeq >= cap):
      return false

  self.publish(item)
  return true

# ---------------------------------------------------------------------------
# Subscription & Cursor Operations
# ---------------------------------------------------------------------------

proc subscribe*[T](
    self: BroadcastRing[T],
    origin: SubscriptionOrigin = soFromLatest
): BroadcastCursor[T] =
  ## Dynamically registers a new reader cursor.
  let core = self.core
  var allocatedId = -1

  for i in 0 ..< core.maxReaders:
    var expected = csUnused
    if core.cursors[i].state.compareExchangeStrong(expected, csActive, moAcqRel, moRelaxed):
      allocatedId = i
      break

  if allocatedId == -1:
    raise newException(OverflowDefect, "BroadcastRing: maximum registered subscribers (" &
      $core.maxReaders & ") exceeded")

  # Determine initial sequence position
  var initialSeq: uint64 = 0
  let tail = core.publisherTail.load(moAcquire)
  case origin
  of soFromLatest:
    initialSeq = tail
  of soFromEarliest:
    let cap = core.capacity.uint64
    initialSeq = if tail > cap: tail - cap else: 0

  core.cursors[allocatedId].currentSeq.store(initialSeq, moRelease)
  discard core.activeCursorCount.fetchAdd(1, moRelaxed)

  result = BroadcastCursor[T](
    cursorId: allocatedId,
    readSeq: initialSeq,
    lagCount: 0,
    ring: self
  )

proc unsubscribe*[T](cursor: var BroadcastCursor[T]) =
  ## Deregisters the cursor, freeing its slot in the cursor table.
  if cursor.ring.core != nil and cursor.cursorId >= 0:
    let core = cursor.ring.core
    let id = cursor.cursorId
    cursor.cursorId = -1
    core.cursors[id].state.store(csUnused, moRelease)
    discard core.activeCursorCount.fetchSub(1, moRelaxed)

proc `=destroy`*[T](self: var BroadcastCursor[T]) {.gcsafe.} =
  `=destroy`(self.ring)

proc isNil*[T](cursor: BroadcastCursor[T]): bool {.inline.} =
  cursor.cursorId < 0 or cursor.ring.core == nil

proc lag*[T](cursor: BroadcastCursor[T]): uint64 {.inline.} =
  cursor.lagCount

proc poll*[T](cursor: var BroadcastCursor[T]): PollResult[T] =
  ## Polls the next message from this cursor's position.
  ## Returns:
  ##   prSuccess with the value if available.
  ##   prEmpty if the publisher has not yet published this sequence.
  ##   prLagged with skippedCount if the reader fell behind the ring horizon (omDropOldest).
  if cursor.cursorId < 0 or cursor.ring.core == nil:
    return PollResult[T](kind: prEmpty)

  let core = cursor.ring.core
  let targetSeq = cursor.readSeq
  let idx = targetSeq and core.mask
  let slot = addr core.slots[idx]

  let slotSeq = slot.seq.load(moAcquire)

  if slotSeq == targetSeq + 1:
    # 1. Normal path: slot contains the exact expected sequence
    let vbox = slot.vbox.load(moAcquire)
    if vbox != nil:
      incRef(vbox)
      # Optimistic verification: ensure slot was not overwritten during load
      if slot.seq.load(moAcquire) == targetSeq + 1:
        let val = vbox.val
        decRef(vbox)
        inc cursor.readSeq
        core.cursors[cursor.cursorId].currentSeq.store(cursor.readSeq, moRelease)
        return PollResult[T](kind: prSuccess, val: val)
      else:
        # Overwritten concurrently; drop ref and fall through to lag handling
        decRef(vbox)

  if slotSeq > targetSeq + 1:
    # 2. Overrun path: publisher has overwritten this slot
    let newestInSlot = slotSeq - 1
    let skipped = newestInSlot - targetSeq
    cursor.lagCount += skipped
    cursor.readSeq = newestInSlot
    core.cursors[cursor.cursorId].currentSeq.store(cursor.readSeq, moRelease)
    return PollResult[T](kind: prLagged, skippedCount: skipped)

  # 3. Not yet published
  return PollResult[T](kind: prEmpty)

proc tryRead*[T](cursor: var BroadcastCursor[T], outVal: var T): bool =
  ## Convenience read helper.
  ## If a message is available, writes to `outVal` and returns true.
  ## If empty, returns false.
  ## If lagged, advances cursor and returns false.
  let res = cursor.poll()
  case res.kind
  of prSuccess:
    outVal = res.val
    return true
  of prEmpty, prLagged:
    return false

# ---------------------------------------------------------------------------
# TopicBus[T] Multiplexer
# ---------------------------------------------------------------------------

type
  TopicBusConfig* = object
    defaultRingCapacity*: int
    defaultOverflowMode*: OverflowMode
    defaultMaxReaders*: int

  TopicBusCore[T] = object
    config*: TopicBusConfig
    topics*: Ctrie[string, BroadcastRing[T]]
    rc*: Atomic[int]

  TopicBus*[T] = object
    core*: ptr TopicBusCore[T]

proc initTopicBus*[T](
    config: TopicBusConfig = TopicBusConfig(
      defaultRingCapacity: DefaultRingCapacity,
      defaultOverflowMode: omDropOldest,
      defaultMaxReaders: DefaultMaxReaders
    )
): TopicBus[T] =
  ## Initializes a new TopicBus multiplexing messages across topic-specific broadcast rings.
  let core = cast[ptr TopicBusCore[T]](allocShared0(sizeof(TopicBusCore[T])))
  core.config = config
  core.topics = initCtrie[string, BroadcastRing[T]]()
  core.rc.store(1, moRelaxed)
  result.core = core

proc `=destroy`*[T](bus: var TopicBus[T]) =
  if bus.core != nil:
    if bus.core.rc.fetchSub(1, moRelease) == 1:
      threadFence(moAcquire)
      `=destroy`(bus.core.topics)
      deallocShared(bus.core)
    bus.core = nil

proc `=copy`*[T](dest: var TopicBus[T], src: TopicBus[T]) =
  if dest.core != src.core:
    `=destroy`(dest)
    dest.core = src.core
    if dest.core != nil:
      discard dest.core.rc.fetchAdd(1, moRelaxed)

proc `=sink`*[T](dest: var TopicBus[T], src: TopicBus[T]) =
  `=destroy`(dest)
  dest.core = src.core

proc isNil*[T](bus: TopicBus[T]): bool {.inline.} =
  bus.core == nil

proc getOrCreateRing[T](bus: TopicBus[T], topic: string): BroadcastRing[T] =
  let existing = bus.core.topics.get(topic)
  if existing.isSome:
    return existing.get
  let newRing = initBroadcastRing[T](
    capacity = bus.core.config.defaultRingCapacity,
    overflowMode = bus.core.config.defaultOverflowMode,
    maxReaders = bus.core.config.defaultMaxReaders
  )
  let prev = bus.core.topics.put(topic, newRing)
  if prev.isSome:
    return prev.get
  return newRing

proc publish*[T](bus: TopicBus[T], topic: string, item: sink T) =
  ## Publishes a message to the broadcast ring associated with `topic`.
  let ring = bus.getOrCreateRing(topic)
  ring.publish(item)

proc subscribe*[T](
    bus: TopicBus[T],
    topic: string,
    origin: SubscriptionOrigin = soFromLatest
): BroadcastCursor[T] =
  ## Dynamically subscribes to `topic`, returning an independent reader cursor.
  let ring = bus.getOrCreateRing(topic)
  return ring.subscribe(origin)

proc topicCount*[T](bus: TopicBus[T]): int {.inline.} =
  if bus.core == nil: 0 else: bus.core.topics.len

proc hasTopic*[T](bus: TopicBus[T], topic: string): bool {.inline.} =
  if bus.core == nil: false else: bus.core.topics.contains(topic)
