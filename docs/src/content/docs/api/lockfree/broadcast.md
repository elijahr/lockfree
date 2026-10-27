---
title: "lockfree/broadcast"
description: "API reference for lockfree/broadcast"
---

<h1><a class="toc-backref" id="concurrency-topologycolon-mpmc-slash-spmc-multicast-pubminussub-ring-buffer-nimbroadcastring-t-slash-nimtopicbus-t" href="#concurrency-topologycolon-mpmc-slash-spmc-multicast-pubminussub-ring-buffer-nimbroadcastring-t-slash-nimtopicbus-t">Concurrency Topology: MPMC / SPMC Multicast Pub-Sub Ring Buffer (<tt class="docutils literal"><span class="pre"><span class="Identifier">BroadcastRing</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">TopicBus</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>)</a></h1><table border="1" class="docutils"><tr><th>Dimension</th><th>Architectural Specification</th></tr>
<tr><td><strong>Topologies</strong></td><td>SPMC (Single-Publisher Multi-Consumer) / MPMC (Multi-Publisher Multicast)</td></tr>
<tr><td><strong>Delivery Model</strong></td><td>1-to-N Fan-Out Broadcast (Every message delivered to ALL active readers)</td></tr>
<tr><td><strong>Buffer Geometry</strong></td><td>Power-of-two circular ring buffer (2^k) with monotonic sequence counters</td></tr>
<tr><td><strong>Consumer Tracking</strong></td><td>Independent reader cursors (<tt class="docutils literal"><span class="pre"><span class="Identifier">BroadcastCursor</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>) dynamically registered</td></tr>
<tr><td><strong>Overflow Policies</strong></td><td><tt class="docutils literal"><span class="pre"><span class="Identifier">omDropOldest</span></span></tt> (Lossy real-time ring) vs <tt class="docutils literal"><span class="pre"><span class="Identifier">omBackoff</span></span></tt> (Lossless backpressure)</td></tr>
<tr><td><strong>Multiplexer</strong></td><td><tt class="docutils literal"><span class="pre"><span class="Identifier">TopicBus</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> mapping topic keys (<tt class="docutils literal"><span class="pre"><span class="Identifier">string</span></span></tt>) to dedicated BroadcastRings</td></tr>
<tr><td><strong>Slot Lifetime</strong></td><td>Atomic refcounted payload box (<tt class="docutils literal"><span class="pre"><span class="Identifier">VBox</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>) with safe ARC/ORC lifecycle</td></tr>
<tr><td><strong>Cache Alignment</strong></td><td>Slots, tail counters, and cursor descriptors aligned to <tt class="docutils literal"><span class="pre"><span class="Identifier">CacheLineBytes</span></span></tt></td></tr>
<tr><td><strong>Progress Guarantees</strong></td><td>Publishers: Lock-Free (<tt class="docutils literal"><span class="pre"><span class="Identifier">omDropOldest</span></span></tt>) / Flow-Controlled (<tt class="docutils literal"><span class="pre"><span class="Identifier">omBackoff</span></span></tt>)</td></tr>
<tr><td></td><td>Readers: Wait-Free Population (<tt class="docutils literal"><span class="pre"><span class="Identifier">omDropOldest</span></span></tt>) / Lock-Free (<tt class="docutils literal"><span class="pre"><span class="Identifier">omBackoff</span></span></tt>)</td></tr>
</table>
<h2><a class="toc-backref" id="concurrency-topologycolon-mpmc-slash-spmc-multicast-pubminussub-ring-buffer-nimbroadcastring-t-slash-nimtopicbus-t-overview" href="#concurrency-topologycolon-mpmc-slash-spmc-multicast-pubminussub-ring-buffer-nimbroadcastring-t-slash-nimtopicbus-t-overview">Overview</a></h2><p><tt class="docutils literal"><span class="pre"><span class="Identifier">BroadcastRing</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> is a high-performance lock-free multicast broadcast ring buffer. In contrast to point-to-point queues where each item is consumed by exactly one reader, <tt class="docutils literal"><span class="pre"><span class="Identifier">BroadcastRing</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> delivers every message to all active registered subscribers.</p>
<p><tt class="docutils literal"><span class="pre"><span class="Identifier">TopicBus</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> provides a multiplexed Pub-Sub bus routing messages by topic string to automatically provisioned <tt class="docutils literal"><span class="pre"><span class="Identifier">BroadcastRing</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> instances backed by <tt class="docutils literal"><span class="pre"><span class="Identifier">Ctrie</span></span></tt>.</p>


## Types

### `OverflowMode`

```nim
OverflowMode = enum
  omDropOldest,             ## Overwrite oldest unread items; slow consumers lag and skip
  omBackoff                  ## Stalls publisher until slowest active cursor advances
```

### `SubscriptionOrigin`

```nim
SubscriptionOrigin = enum
  soFromLatest,             ## Start reading from messages published AFTER subscription
  soFromEarliest             ## Replay available ring history up to current capacity
```

### `PollResultKind`

```nim
PollResultKind = enum
  prSuccess,                ## Item successfully read
  prEmpty,                  ## No new messages available at this cursor
  prLagged                   ## Reader lagged behind overwritten horizon; skipped messages
```

### `PollResult`

```nim
PollResult[T] = object
  case kind*: PollResultKind
  of prSuccess:
    val*: T
  of prEmpty:
    nil
  of prLagged:
    skippedCount*: uint64
```

### `VBox`

```nim
VBox[T] = object
  rc*: Atomic[int32]
  val*: T
```

### `BroadcastSlot`

```nim
BroadcastSlot[T] = object
  seq* {.align: 128.}: Atomic[uint64] ## Monotonic sequence number published into this slot
  writeSeq*: Atomic[uint64]  ## Pre-write sequence stamp for inline seqlock
  vbox*: Atomic[ptr VBox[T]] ## Pointer to heap-allocated payload box
  retiredBox*: Atomic[ptr VBox[T]] ## Quarantined previous box from prior lap
  inlineBits*: Atomic[uint64] ## Atomic inline storage for trivial <=64-bit types
```

### `BroadcastRingConfig`

```nim
BroadcastRingConfig = object
  capacity*: int             ## Power of two (e.g. 1024, 65536)
  overflowMode*: OverflowMode ## omDropOldest or omBackoff
  maxReaders*: int           ## Maximum concurrent registered cursors (default 64)
```

### `BroadcastRingCore`

```nim
BroadcastRingCore[T] = object
  capacity*: int
  mask*: uint64
  overflowMode*: OverflowMode
  maxReaders*: int
  publisherTail*: Atomic[uint64] ## Monotonically incrementing publication ticket
  publishedHead*: Atomic[uint64] ## Highest fully published sequence number
  slots*: BroadcastSlotBuffer[T]
  cursors*: CursorDescriptorBuffer
  activeCursorMask*: Atomic[uint64] ## Bitmask of active cursors (0..<min(maxReaders, 64))
  activeCursorCount*: Atomic[int32]
  rc*: Atomic[int]
```

### `BroadcastRing`

```nim
BroadcastRing[T] = object
  core*: ptr BroadcastRingCore[T]
```

### `BroadcastCursor`

```nim
BroadcastCursor[T] = object
  cursorId*: int             ## Slot in the ring's cursor table
  readSeq*: uint64           ## Reader's local non-atomic sequence counter
  lagCount*: uint64          ## Total number of messages skipped due to overflow
  ring*: BroadcastRing[T]    ## Handle keeping ring alive
```

### `TopicBusConfig`

```nim
TopicBusConfig = object
  defaultRingCapacity*: int
  defaultOverflowMode*: OverflowMode
  defaultMaxReaders*: int
```

### `TopicBus`

```nim
TopicBus[T] = object
  core*: ptr TopicBusCore[T]
```


## Constants

### `DefaultRingCapacity`

```nim
DefaultRingCapacity = 1024
```

### `DefaultMaxReaders`

```nim
DefaultMaxReaders = 64
```

### `CacheLine`

```nim
CacheLine = 128
```

### `moAcqRel`

```nim
moAcqRel = moAcquireRelease
```

### `moSeqCst`

```nim
moSeqCst = moSequentiallyConsistent
```


## Procedures & Functions

### `initBroadcastRing`

```nim
proc initBroadcastRing[T](capacity: int = DefaultRingCapacity;
                          overflowMode: OverflowMode = omDropOldest;
                          maxReaders: int = DefaultMaxReaders): BroadcastRing[T]
```

Constructs a new concurrent multicast broadcast ring.

### ``=destroy``

```nim
proc `=destroy`[T](self: var BroadcastRing[T]) {.gcsafe, raises: [].}
```

### ``=copy``

```nim
proc `=copy`[T](dest: var BroadcastRing[T]; src: BroadcastRing[T])
```

### ``=sink``

```nim
proc `=sink`[T](dest: var BroadcastRing[T]; src: BroadcastRing[T])
```

### `isNil`

```nim
proc isNil[T](self: BroadcastRing[T]): bool {.inline.}
```

### `capacity`

```nim
proc capacity[T](self: BroadcastRing[T]): int {.inline.}
```

### `subscriberCount`

```nim
proc subscriberCount[T](self: BroadcastRing[T]): int {.inline.}
```

### `len`

```nim
proc len[T](self: BroadcastRing[T]): int {.inline.}
```

Returns the number of published messages currently residing in the ring.

### `publish`

```nim
proc publish[T](self: BroadcastRing[T]; item: sink T)
```

Publishes a message to all active subscribers. In <tt class="docutils literal"><span class="pre"><span class="Identifier">omDropOldest</span></span></tt>, overwrites oldest messages if the ring is full without blocking. In <tt class="docutils literal"><span class="pre"><span class="Identifier">omBackoff</span></span></tt>, stalls/spins until the slowest active subscriber advances.

### `tryPublish`

```nim
proc tryPublish[T](self: BroadcastRing[T]; item: sink T): bool
```

Non-blocking publish attempt. Returns true if published. In <tt class="docutils literal"><span class="pre"><span class="Identifier">omBackoff</span></span></tt>, returns false if the ring is currently full.

### `subscribe`

```nim
proc subscribe[T](self: BroadcastRing[T];
                  origin: SubscriptionOrigin = soFromLatest): BroadcastCursor[T]
```

Dynamically registers a new reader cursor.

### `unsubscribe`

```nim
proc unsubscribe[T](cursor: var BroadcastCursor[T])
```

Deregisters the cursor, freeing its slot in the cursor table.

### ``=destroy``

```nim
proc `=destroy`[T](self: var BroadcastCursor[T]) {.gcsafe, raises: [].}
```

### `isNil`

```nim
proc isNil[T](cursor: BroadcastCursor[T]): bool {.inline.}
```

### `lag`

```nim
proc lag[T](cursor: BroadcastCursor[T]): uint64 {.inline.}
```

### `poll`

```nim
proc poll[T](cursor: var BroadcastCursor[T]): PollResult[T]
```

Polls the next message from this cursor's position. Returns: prSuccess with the value if available. prEmpty if the publisher has not yet published this sequence. prLagged with skippedCount if the reader fell behind the ring horizon (omDropOldest).

### `tryRead`

```nim
proc tryRead[T](cursor: var BroadcastCursor[T]; outVal: var T): bool
```

Convenience read helper. If a message is available, writes to <tt class="docutils literal"><span class="pre"><span class="Identifier">outVal</span></span></tt> and returns true. If empty, returns false. If lagged, advances cursor and returns false.

### `initTopicBus`

```nim
proc initTopicBus[T](config: TopicBusConfig = TopicBusConfig(
    defaultRingCapacity: 1024, defaultOverflowMode: omDropOldest,
    defaultMaxReaders: 64)): TopicBus[T]
```

Initializes a new TopicBus multiplexing messages across topic-specific broadcast rings.

### ``=destroy``

```nim
proc `=destroy`[T](bus: var TopicBus[T]) {.raises: [].}
```

### ``=copy``

```nim
proc `=copy`[T](dest: var TopicBus[T]; src: TopicBus[T])
```

### ``=sink``

```nim
proc `=sink`[T](dest: var TopicBus[T]; src: TopicBus[T])
```

### `isNil`

```nim
proc isNil[T](bus: TopicBus[T]): bool {.inline.}
```

### `getOrCreateRing`

```nim
proc getOrCreateRing[T](bus: TopicBus[T]; topic: string): BroadcastRing[T]
```

### `publish`

```nim
proc publish[T](bus: TopicBus[T]; topic: string; item: sink T)
```

Publishes a message to the broadcast ring associated with <tt class="docutils literal"><span class="pre"><span class="Identifier">topic</span></span></tt>.

### `subscribe`

```nim
proc subscribe[T](bus: TopicBus[T]; topic: string;
                  origin: SubscriptionOrigin = soFromLatest): BroadcastCursor[T]
```

Dynamically subscribes to <tt class="docutils literal"><span class="pre"><span class="Identifier">topic</span></span></tt>, returning an independent reader cursor.

### `topicCount`

```nim
proc topicCount[T](bus: TopicBus[T]): int {.inline.}
```

### `hasTopic`

```nim
proc hasTopic[T](bus: TopicBus[T]; topic: string): bool {.inline.}
```


## Templates

### `isInlineBroadcastType`

```nim
template isInlineBroadcastType(T: typedesc): bool
```

