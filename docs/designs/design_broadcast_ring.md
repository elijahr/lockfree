# Concurrency Architecture & Formal Invariants: BroadcastRing[T] & TopicBus[T]

**Document ID**: `DESIGN-LOCKFREE-BROADCAST-001`  
**Author**: Marcus Vance (`architect-horsetail`), Staff Systems Architect  
**Reviewers**: Caleb Thorne (`auditor-pegasus`), Elena Rostova (`implementer-kite`), Supreme Orchestrator (`orchestrator-whipbird`)  
**Status**: RATIFIED ARCHITECTURAL SPECIFICATION  
**Target Substrate**: `lockfree` (v0.1.0-consolidated)  
**Deliverable**: `docs/designs/design_broadcast_ring.md`  

---

## Concurrency Topology & Substrate Banner

```
====================================================================================================
Concurrency Topology: MPMC / SPMC Multicast Pub-Sub Ring Buffer (BroadcastRing[T] / TopicBus[T])
====================================================================================================
| Dimension              | Architectural Specification                                             |
|:-----------------------|:------------------------------------------------------------------------|
| **Topologies**         | SPMC (Single-Publisher Multi-Consumer) / MPMC (Multi-Publisher Multicast) |
| **Delivery Model**     | 1-to-N Fan-Out Broadcast (Every message delivered to ALL active readers) |
| **Buffer Geometry**    | Power-of-two circular ring buffer (2^k) with monotonic sequence counters |
| **Consumer Tracking**  | Independent reader cursors (BroadcastCursor[T]) dynamically registered  |
| **Overflow Policies**  | omDropOldest (Lossy real-time ring) vs omBackoff (Lossless backpressure) |
| **Multiplexer**        | TopicBus[T] mapping topic keys (string/hash) to dedicated BroadcastRings|
| **Slot Lifetime**      | Atomic refcounted payload box (VBox[T]) with Debra SMR deferred reclaim |
| **Memory Reclamation** | Debra SMR (NEBR, src/lockfree/smr/nebr/) for slot & cursor lifecycle     |
| **Cache Alignment**    | Slots, tail counters, and cursor descriptors aligned to CacheLineBytes    |
| **Progress Guarantees**| Publishers: Lock-Free (omDropOldest) / Blocking Flow-Control (omBackoff)|
|                        | Readers: Wait-Free Population (omDropOldest) / Lock-Free (omBackoff)    |
====================================================================================================
```

---

## 1. Executive Summary & Problem Statement

### 1.1 Contrast: Point-to-Point Queues vs Multicast Broadcast Rings
All existing queue implementations in `lockfree` (`BQueue`, `Queue`, `ChaseLevDeque`, `TreiberStack`) operate under a **point-to-point (1-to-1)** delivery model:
$$\forall m \in \text{Messages}, \quad |\{\text{Consumers that receive } m\}| = 1$$
When consumer $C_1$ pops an element, that element is irrevocably consumed and invisible to consumer $C_2$.

However, modern low-latency systems architectures (market data feeds, telemetry ingestion, order matching event replication, distributed state-machine broadcasting, and microservice actor event loops) require a **multicast pub-sub (1-to-N)** delivery model:
$$\forall m \in \text{Messages}, \quad \forall C_i \in \text{ActiveSubscribers}, \quad C_i \text{ receives } m$$

### 1.2 Core Architectural Requirements
1. **Zero-Locking Fan-Out**: A single publisher writing a message must not iterate over a list of mutex-locked client queues. The message must be written **once** into a cache-aligned circular ring buffer, where $N$ independent reader threads can read it concurrently without contention on the publisher's write head.
2. **Independent Reader Cursors**: Readers consume at independent velocities. Fast readers must not be constrained by slow readers unless explicitly configured for backpressure.
3. **Formal Slow Consumer Policies**:
   - `omDropOldest`: In real-time market data or sensor streams, freshest data is paramount. The publisher never waits; it overwrites the oldest ring slots. Slow readers detect that their cursor has fallen behind the ring horizon, advance their cursor to the oldest available sequence, and record an explicit `lag` count.
   - `omBackoff`: In transactional or event-sourcing streams, zero loss is permissible. The publisher monitors the slowest active cursor and stalls (exponential backoff / CPU pause / condvar wake) if the ring is full, applying backpressure upstream.
4. **Dynamic Reader Registration**: Readers must be able to join and leave the broadcast stream at runtime without reallocating the ring or requiring stop-the-world synchronization.
5. **TopicBus Multiplexer**: A unified routing layer mapping topic names (`string` or hierarchical prefixes like `"market.crypto.btc"`) to dedicated or shared broadcast rings.
6. **ARC/ORC Destructor Safety**: Unlike point-to-point queues where a pop transfers ownership of `T` to the sole consumer, in a broadcast ring multiple consumers read the same slot. Memory reclamation must safely deallocate `T` only when the publisher overwrites the slot **and** all consumers reading that slot have finished.

---

## 2. Memory Geometry & Node Layout

```
                               BroadcastRing Buffer (Capacity = 2^k)
               +-------------------------------------------------------------------+
Slot Index:    | Slot 0         | Slot 1         | Slot 2         | Slot 3         |
Sequence:      | Seq = 4        | Seq = 1        | Seq = 2        | Seq = 3        |
Payload:       | VBox("msg4")   | VBox("msg1")   | VBox("msg2")   | VBox("msg3")   |
               +----------------+----------------+----------------+----------------+
                 ^                                                  ^
                 | (overwritten by publisher)                       |
                 |                                                  +-- Publisher Tail = 4
                 +-- Slow Reader Cursor (Lagged!)                   |
                                                                    +-- Fast Reader Cursor (Seq = 3)
```

### 2.1 The Slot Structure (`BroadcastSlot[T]`)
Every slot in the ring must be padded and aligned to `CacheLineBytes` (64 bytes on x86_64, 128 bytes on Apple Silicon) to prevent false sharing between writers advancing the tail and readers inspecting adjacent slots.

```nim
type
  BroadcastSlot[T] = object
    seq*: Atomic[uint64]               ## Monotonic sequence number committed to this slot
    vbox*: Atomic[ptr VBox[T]]         ## Pointer to immutable heap-allocated payload box
    # Explicit cache-line padding
    pad: array[CacheLineBytes - sizeof(Atomic[uint64]) - sizeof(Atomic[pointer]), byte]

  BroadcastSlotBuffer[T] = ptr UncheckedArray[BroadcastSlot[T]]
```

#### Monotonic Sequence Numbering Invariant
Let $C$ be the ring capacity (power of 2).
- Initially, each slot $i \in [0, C-1]$ is initialized with:
  $$\text{slot}[i].\text{seq} = i$$
  and $\text{slot}[i].\text{vbox} = \text{nil}$.
- A publisher claiming sequence number $S$ writes to slot index:
  $$\text{idx} = S \ \& \ (C - 1)$$
- When publication completes, the publisher stores the updated sequence:
  $$\text{slot}[\text{idx}].\text{seq}.\text{store}(S + 1, \text{moRelease})$$
- A reader inspecting sequence $S$ at index $\text{idx} = S \ \& \ (C - 1)$ verifies that:
  $$\text{slot}[\text{idx}].\text{seq}.\text{load}(\text{moAcquire}) == S + 1$$
  If the loaded sequence equals $S + 1$, the slot holds the exact message intended for sequence $S$.

### 2.2 Reader Cursor Descriptors (`BroadcastCursor[T]`)
Each subscriber allocates a lightweight, thread-safe cursor descriptor:

```nim
type
  CursorState = enum
    csUnused
    csActive
    csDeregistered

  CursorDescriptor = object
    state*: Atomic[CursorState]
    currentSeq*: Atomic[uint64]        ## Current sequence the reader is waiting to consume
    lastHeartbeat*: Atomic[uint64]     ## Timestamp for dead-consumer detection
    pad: array[CacheLineBytes - sizeof(Atomic[CursorState]) - sizeof(Atomic[uint64]) - sizeof(Atomic[uint64]), byte]

  BroadcastCursor*[T] = object
    cursorId*: int                     ## Slot in the ring's cursor table
    readSeq*: uint64                   ## Reader's local non-atomic sequence counter
    lagCount*: uint64                  ## Total number of messages skipped due to overflow
    ring*: ptr BroadcastRingCore[T]     ## Pointer to ring substrate
```

### 2.3 The Ring Core (`BroadcastRingCore[T]`)

```nim
type
  OverflowMode* = enum
    omDropOldest                       ## Overwrite oldest unread items; slow consumers lag
    omBackoff                          ## Stalls publisher until slowest active cursor advances

  SubscriptionOrigin* = enum
    soFromLatest                       ## Start reading from messages published AFTER subscription
    soFromEarliest                     ## Replay available ring history up to current capacity

  BroadcastRingConfig* = object
    capacity*: int                     ## Power of two (e.g. 1024, 65536)
    overflowMode*: OverflowMode        ## omDropOldest or omBackoff
    maxReaders*: int                   ## Maximum concurrent registered cursors (default 64)
    backoffSpins*: int                 ## Spins before yielding in omBackoff (default 100)

  BroadcastRingCore[T] = object
    capacity*: int
    mask*: uint64
    overflowMode*: OverflowMode
    maxReaders*: int
    
    # Publisher head / tail
    publisherTail*: Atomic[uint64]     ## Monotonically incrementing publication ticket
    publishedHead*: Atomic[uint64]     ## Maximum sequence fully committed and readable
    alignPadPub: array[CacheLineBytes - 2 * sizeof(Atomic[uint64]), byte]

    # Ring buffer slots
    slots*: BroadcastSlotBuffer[T]

    # Reader cursor registry
    cursors*: ptr UncheckedArray[CursorDescriptor]
    activeCursorCount*: Atomic[int32]

    # Memory reclamation substrate
    smr*: ptr DebraManager[64, ccMulti]
    rc*: Atomic[int]
```

---

## 3. Slow Consumer & Overflow Policies

The central design trade-off in circular multicast rings is the conflict between **writer latency** and **reader retention**.

```
+-----------------------------------------------------------------------------------+
| Policy: omDropOldest (Lossy / Ring Buffer / Real-Time Telemetry)                  |
| Invariant: Publisher NEVER waits. Publisher tail advances monotonically.          |
| Detection: Reader detects slot.seq > readSeq + 1 (slot was overwritten).          |
| Resolution: Reader jumps readSeq = slot.seq - 1, increments lagCount += skipped.  |
+-----------------------------------------------------------------------------------+

+-----------------------------------------------------------------------------------+
| Policy: omBackoff (Lossless / Flow-Controlled / Transactional Event Sourcing)     |
| Invariant: Publisher CANNOT overwrite unread slots.                               |
| Condition: publisherTail - min(active_cursors.currentSeq) < capacity.             |
| Resolution: If ring full, publisher spins / pauses / yields until slowest catches |
+-----------------------------------------------------------------------------------+
```

### 3.1 Policy 1: `omDropOldest` (Lossy High-Throughput Mode)
Designed for financial tickers, sensor streaming, and real-time gaming where stale data is useless and stalling the publisher is fatal.

#### Mathematical Invariant
At any instantaneous moment:
$$\text{Horizon}_{\text{oldest}} = \max(0, \ \text{publishedHead} - \text{capacity})$$
If a consumer has $\text{readSeq} < \text{Horizon}_{\text{oldest}}$, the slot at $\text{readSeq} \ \& \ \text{mask}$ has been overwritten by a newer generation.

#### Reader Overrun Detection Algorithm
```nim
proc tryReadNext*[T](
    cursor: var BroadcastCursor[T],
    outVal: var T
): PollResult =
  let targetSeq = cursor.readSeq
  let idx = targetSeq and cursor.ring.mask
  let slot = addr cursor.ring.slots[idx]

  let slotSeq = slot.seq.load(moAcquire)

  if slotSeq == targetSeq + 1:
    # 1. Normal path: slot contains exactly the expected sequence
    let vbox = slot.vbox.load(moAcquire)
    if vbox != nil:
      outVal = vbox.val
      inc cursor.readSeq
      # Update public cursor position for monitoring
      cursor.ring.cursors[cursor.cursorId].currentSeq.store(cursor.readSeq, moRelease)
      return prSuccess
    else:
      return prEmpty

  elif slotSeq > targetSeq + 1:
    # 2. Overrun detected! Publisher has overwritten this slot one or more times.
    let newestInSlot = slotSeq - 1
    let skipped = newestInSlot - targetSeq
    cursor.lagCount += skipped
    # Fast-forward cursor to the oldest valid sequence currently readable
    cursor.readSeq = newestInSlot
    cursor.ring.cursors[cursor.cursorId].currentSeq.store(cursor.readSeq, moRelease)
    return prLagged(skipped = skipped)

  else:
    # 3. slotSeq <= targetSeq: Publisher has not yet published this sequence
    return prEmpty
```

### 3.2 Policy 2: `omBackoff` (Lossless Reliable Mode)
Designed for audit logs, message brokers, and inter-process RPC where dropped messages corrupt system consistency.

#### Mathematical Invariant
$$\forall C_i \in \text{ActiveCursors}, \quad \text{publisherTail} - C_i.\text{currentSeq} \le \text{capacity}$$

#### Publisher Flow-Control Algorithm
```nim
proc publishLossless*[T](ring: ptr BroadcastRingCore[T], item: sink T) =
  let targetSeq = ring.publisherTail.fetchAdd(1, moAcqRel)
  let idx = targetSeq and ring.mask
  let slot = addr ring.slots[idx]

  # Flow-control check: verify slowest active reader has cleared this slot
  var backoff = initBackoff()
  while true:
    var slowestSeq = targetSeq # Upper bound
    let numCursors = ring.maxReaders
    for i in 0 ..< numCursors:
      if ring.cursors[i].state.load(moAcquire) == csActive:
        let cseq = ring.cursors[i].currentSeq.load(moAcquire)
        if cseq < slowestSeq:
          slowestSeq = cseq

    if targetSeq - slowestSeq < ring.capacity.uint64:
      break # Slot is free to be written!
    
    # Ring is full! Backoff to give slow consumer CPU time
    backoff.pause()

  # Write payload box
  let oldVBox = slot.vbox.load(moRelaxed)
  let newVBox = newVBox(item)
  slot.vbox.store(newVBox, moRelaxed)
  slot.seq.store(targetSeq + 1, moRelease)

  # Retire old VBox via Debra SMR
  if oldVBox != nil:
    debraRetire(ring.smr, oldVBox, disposeVBoxCallback[T])
```

---

## 4. Dynamic Cursor Lifecycle & Registration Table

Subscribers register and deregister dynamically. The cursor table uses a fixed-capacity descriptor array (`maxReaders`, default 64) with atomic state transitions to guarantee zero heap allocations on the hot path.

```
Cursor Table Entry State Machine:

       +------------------+
       |     csUnused     | <---------------------+
       +--------+---------+                       |
                |                                 |
                | CAS(csUnused -> csActive)       | Reclaimed / Reset
                v                                 |
       +------------------+                       |
       |     csActive     |                       |
       +--------+---------+                       |
                |                                 |
                | unsubscribe()                   |
                v                                 |
       +------------------+                       |
       |  csDeregistered  | ----------------------+
       +------------------+
```

### 4.1 Registration Ceremony (`subscribe`)
```nim
proc subscribe*[T](
    ring: BroadcastRing[T],
    origin: SubscriptionOrigin = soFromLatest
): BroadcastCursor[T] =
  let core = ring.core
  var allocatedId = -1

  for i in 0 ..< core.maxReaders:
    var expected = csUnused
    if core.cursors[i].state.compareExchangeStrong(expected, csActive, moAcqRel, moRelaxed):
      allocatedId = i
      break

  if allocatedId == -1:
    raise newException(OverflowDefect, "BroadcastRing: maximum registered subscribers exceeded")

  # Determine starting sequence
  var initialSeq: uint64 = 0
  case origin
  of soFromLatest:
    initialSeq = core.publisherTail.load(moAcquire)
  of soFromEarliest:
    let tail = core.publisherTail.load(moAcquire)
    let cap = core.capacity.uint64
    initialSeq = if tail > cap: tail - cap else: 0

  core.cursors[allocatedId].currentSeq.store(initialSeq, moRelease)
  discard core.activeCursorCount.fetchAdd(1, moRelaxed)

  result = BroadcastCursor[T](
    cursorId: allocatedId,
    readSeq: initialSeq,
    lagCount: 0,
    ring: core
  )
```

### 4.2 Deregistration Ceremony (`unsubscribe`)
```nim
proc unsubscribe*[T](cursor: var BroadcastCursor[T]) =
  if cursor.ring != nil and cursor.cursorId >= 0:
    let core = cursor.ring
    let id = cursor.cursorId
    # Mark slot unused so it can be reclaimed by subsequent subscribers
    core.cursors[id].state.store(csUnused, moRelease)
    discard core.activeCursorCount.fetchSub(1, moRelaxed)
    cursor.cursorId = -1
    cursor.ring = nil
```

---

## 5. ARC/ORC Destructor & Slot Memory Reclamation

A fundamental challenge of multicast broadcasting in Nim is that multiple reader threads may hold references to the value in `slot.vbox` at the exact moment the publisher decides to overwrite that slot.

### 5.1 The `VBox[T]` Refcounted Indirection Box
Directly embedding `T` in `BroadcastSlot[T]` causes data races when `T` contains managed references (strings, sequences, reference types) because `copyNormal` or `=copy` executes non-atomic refcount increments while the publisher executes `=destroy` on the overwritten slot.

To achieve strict thread-safety under ARC/ORC:
1. Payloads are placed inside an unmanaged `VBox[T]` allocated from the thread-local slab:
   ```nim
   type
     VBox[T] = object
       rc*: Atomic[int32]              ## Shared reader reference count
       val*: T                         ## ARC/ORC managed payload
   ```
2. When the publisher writes to `slot.vbox`, it stores a pointer to a fresh `VBox[T]` with `rc = 1`.
3. When the publisher later overwrites `slot.vbox`, it decrements `oldVBox.rc`.
4. If readers are currently processing `oldVBox`, they increment `vbox.rc` upon reading, and decrement it when finished.
5. In addition, `oldVBox` is enrolled into the thread's **Debra SMR limbo list**. The physical deallocation of `VBox[T]` and the invocation of `=destroy(vbox.val)` is deferred until:
   - All active readers have departed the epoch in which `oldVBox` was retired.
   - `vbox.rc == 0`.

This dual-layer invariant (Debra SMR Epoch Pinning + Atomic VBox Reference Balancing) guarantees **zero use-after-free**, **zero memory leaks**, and **zero double-destructions** under all concurrency scenarios.

---

## 6. TopicBus[T] Multiplexer Architecture

In real-world event-driven systems, applications rarely publish to a single monolithic broadcast ring. Instead, they organize event streams into topics (e.g., `"trades.btc"`, `"trades.eth"`, `"orders.system"`).

```
                              TopicBus[T] Architecture
                            +--------------------------+
                            |       TopicBus[T]        |
                            +------------+-------------+
                                         |
                       +-----------------+-----------------+
                       | ConcurrentMap[string, BroadcastRing[T]]
                       v                                   v
             +--------------------+              +--------------------+
             | BroadcastRing[T]   |              | BroadcastRing[T]   |
             | Topic: "market.btc"|              | Topic: "market.eth"|
             +---------+----------+              +---------+----------+
                       |                                   |
              +--------+--------+                 +--------+--------+
              |                 |                 |                 |
              v                 v                 v                 v
          Cursor A          Cursor B          Cursor C          Cursor D
```

### 6.1 Dynamic Topic Provisioning
`TopicBus[T]` multiplexes topics over dedicated `BroadcastRing[T]` instances using the high-performance `ConcurrentMap[string, BroadcastRing[T]]` (Ctrie) substrate:

```nim
type
  TopicBusConfig* = object
    defaultRingCapacity*: int          ## Default capacity for auto-provisioned rings (e.g. 4096)
    defaultOverflowMode*: OverflowMode ## omDropOldest or omBackoff
    defaultMaxReaders*: int            ## Maximum subscribers per topic (default 64)

  TopicBus*[T] = object
    config*: TopicBusConfig
    topics*: ConcurrentMap[string, BroadcastRing[T]]
```

### 6.2 Topic Operations
```nim
proc publish*[T](bus: TopicBus[T], topic: string, msg: sink T) =
  # Look up or create topic broadcast ring atomically
  var ring = bus.topics.get(topic)
  if ring.isNone:
    ring = some(bus.topics.computeIfAbsent(topic, proc(k: string): BroadcastRing[T] =
      initBroadcastRing[T](
        capacity = bus.config.defaultRingCapacity,
        overflowMode = bus.config.defaultOverflowMode,
        maxReaders = bus.config.defaultMaxReaders
      )
    ))
  ring.get().publish(msg)

proc subscribe*[T](
    bus: TopicBus[T],
    topic: string,
    origin: SubscriptionOrigin = soFromLatest
): BroadcastCursor[T] =
  let ring = bus.topics.computeIfAbsent(topic, proc(k: string): BroadcastRing[T] =
    initBroadcastRing[T](
      capacity = bus.config.defaultRingCapacity,
      overflowMode = bus.config.defaultOverflowMode,
      maxReaders = bus.config.defaultMaxReaders
    )
  )
  return ring.subscribe(origin)
```

---

## 7. Memory Ordering, Fences & Synchronization Invariants

| Component | Atomic Variable | Operation | Required Ordering | Formal Architectural Rationale |
|:---|:---|:---|:---|:---|
| **Publisher** | `ring.publisherTail` | `fetchAdd(1)` | `moAcqRel` | Claims unique slot index; synchronizes against other concurrent publishers. |
| **Publisher** | `slot.vbox` | `store(newVBox)` | `moRelaxed` | Precedes the sequence release fence; ordering enforced by `slot.seq`. |
| **Publisher** | `slot.seq` | `store(seq + 1)` | `moRelease` | Publishes written payload memory to all concurrent reader threads. |
| **Reader** | `slot.seq` | `load()` | `moAcquire` | Synchronizes with publisher's release; guarantees payload fields are fully visible. |
| **Reader** | `cursor.currentSeq` | `store(readSeq)` | `moRelease` | Exposes reader's progress to the publisher for `omBackoff` flow-control checks. |
| **Subscriber**| `cursor.state` | `compareExchange`| `moAcqRel` | Serializes registration and deregistration in the cursor table. |

---

## 8. Complete Nim API Specification

```nim
type
  PollResultKind* = enum
    prSuccess                          ## Item successfully read
    prEmpty                            ## No new messages available
    prLagged                           ## Reader lagged behind horizon; skipped messages

  PollResult*[T] = object
    case kind*: PollResultKind
    of prSuccess:
      val*: T
    of prEmpty:
      discard
    of prLagged:
      skippedCount*: uint64

# =============================================================================
# BroadcastRing[T] Surface
# =============================================================================

proc initBroadcastRing*[T](
    capacity: int = 1024,
    overflowMode: OverflowMode = omDropOldest,
    maxReaders: int = 64
): BroadcastRing[T]

proc publish*[T](ring: BroadcastRing[T], item: sink T) {.inline.}
proc tryPublish*[T](ring: BroadcastRing[T], item: sink T): bool

proc subscribe*[T](
    ring: BroadcastRing[T],
    origin: SubscriptionOrigin = soFromLatest
): BroadcastCursor[T]

proc unsubscribe*[T](cursor: var BroadcastCursor[T])

proc poll*[T](cursor: var BroadcastCursor[T]): PollResult[T]
proc tryRead*[T](cursor: var BroadcastCursor[T], outVal: var T): bool

proc len*[T](ring: BroadcastRing[T]): int
proc capacity*[T](ring: BroadcastRing[T]): int
proc subscriberCount*[T](ring: BroadcastRing[T]): int

# =============================================================================
# TopicBus[T] Surface
# =============================================================================

proc initTopicBus*[T](config: TopicBusConfig = default(TopicBusConfig)): TopicBus[T]

proc publish*[T](bus: TopicBus[T], topic: string, item: sink T)
proc subscribe*[T](
    bus: TopicBus[T],
    topic: string,
    origin: SubscriptionOrigin = soFromLatest
): BroadcastCursor[T]

proc topicCount*[T](bus: TopicBus[T]): int
proc hasTopic*[T](bus: TopicBus[T], topic: string): bool
```

---

## 9. Verification, Stress Testing & Audit Plan

```
+-----------------------------------------------------------------------------------+
| Stage 1: Architectural Specification & Formal Invariants (design_broadcast_ring.md) |
| Author: architect-horsetail | Two-Key Gate Pass & Orchestrator Ratification       |
+-----------------------------------------+-----------------------------------------+
                                          |
                                          v
+-----------------------------------------------------------------------------------+
| Stage 2: Core Ring Buffer Implementation (src/lockfree/broadcast.nim)             |
| Cache-aligned slots, monotonic sequence numbering, VBox[T] lifecycle, cursors     |
+-----------------------------------------+-----------------------------------------+
                                          |
                                          v
+-----------------------------------------------------------------------------------+
| Stage 3: TopicBus Multiplexer & Topic Routing (src/lockfree/topicbus.nim)         |
| ConcurrentMap topic dynamic provisioning, wildcard routing, clean teardown        |
+-----------------------------------------+-----------------------------------------+
                                          |
                                          v
+-----------------------------------------------------------------------------------+
| Stage 4: Concurrency Stress Test Suite (tests/t_broadcast.nim & tests/t_topicbus) |
| 1-Publisher / 8-Reader throughput benchmark, lag detection under omDropOldest,     |
| flow-control backpressure validation under omBackoff, ARC/ORC destructor checks   |
+-----------------------------------------------------------------------------------+
```

### 9.1 Verification Invariants for Auditor Review
1. **Zero Message Loss under `omBackoff`**: When 4 concurrent readers consume 1,000,000 messages from 2 concurrent publishers under `omBackoff`, every reader must receive every message exactly once with zero gaps in sequence numbers.
2. **Deterministic Lag Accounting under `omDropOldest`**: When a reader is deliberately paused for 100ms during heavy publication, the sum of received messages + `lagCount` must equal the total number of published messages.
3. **Leak-Free Destruction**: Under ARC and ORC, creating rings with reference types (`ref object`, `string`, `seq[int]`), publishing 500,000 items, and allowing them to overwrite under `omDropOldest` must result in a net destructor count equal to the number of allocated objects (zero memory leaks).
4. **TSan Verification**: All reads and writes to `BroadcastSlot[T]` must pass ThreadSanitizer (`-d:tsan`) with zero data race reports.

---

**Architectural Sign-off**:  
*Marcus Vance (`architect-horsetail`), Staff Systems Architect, 2026-10-08*
