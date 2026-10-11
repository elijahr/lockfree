# Broadcast Ring & Topic Bus

`lockfree/broadcast` provides lock-free multicast fan-out and pub-sub primitives
designed for real-time market feeds, telemetry streams, and event distribution.

---

## 1. Broadcast Ring (`BroadcastRing[T]`)

Unlike a standard FIFO queue where each item is dequeued by exactly one consumer,
a `BroadcastRing` multicasts every published item to **all** active readers.

### Architecture

- **Independent Reader Cursors**: Readers attach by allocating a `BroadcastCursor[T]`. Each cursor maintains its own monotonic sequence position.
- **Fixed-Size Ring Buffer**: The ring buffer has a compile-time capacity $N$ (a power of two).
- **Overflow Policies**:
  - `omDropOldest`: Lossy ring. When a slow reader lags behind the publisher by more than $N$ items, the publisher overwrites the oldest slot. The reader's cursor detects the gap and skips ahead to the oldest available sequence. Readers are protected against Use-After-Free (UAF) by Sequential Consistency hazard pointers.
  - `omBackpressure`: Lossless ring. The publisher will not overwrite slots occupied by the slowest active cursor, returning `false` or spinning until readers make progress.

### Example

```nim
import lockfree

var ring = newBroadcastRing[int, 1024](policy = omDropOldest)

# Multiple readers create cursors
var cursor1 = ring.createCursor()
var cursor2 = ring.createCursor()

# Publisher multicasts items
discard ring.publish(100)
discard ring.publish(200)

var val1, val2: int
assert cursor1.tryRead(val1) == crSuccess and val1 == 100
assert cursor2.tryRead(val2) == crSuccess and val2 == 100
```

---

## 2. Topic Bus (`TopicBus[T]`)

`TopicBus[T]` maps dynamic string topic keys to underlying `BroadcastRing`
instances using atomic hash indexing, enabling fine-grained pub-sub messaging.

### Example

```nim
import lockfree

var bus = newTopicBus[string, 256](policy = omDropOldest)

var cursor = bus.subscribe("market.orders")
bus.publish("market.orders", "BUY AAPL 100")

var msg: string
if cursor.tryRead(msg) == crSuccess:
  echo "Topic message: ", msg
```

See the [Broadcast API Reference](../api/broadcast.md) for detailed cursor operations.
