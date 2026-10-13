# Broadcast & TopicBus Benchmarks: 1-to-N Multicast & Pub/Sub Scaling

Performance benchmarks evaluating `BroadcastRing[T]` (lock-free circular 1-to-N multicast ring) and `TopicBus[T]` (multi-topic lock-free pub/sub router) against Rust's `tokio::sync::broadcast` (`tokio_broadcast`) and `bus::Bus` (`rust_bus`).

---

## 1. Concurrency Model & Overflow Modes

`BroadcastRing[T]` implements a high-throughput circular broadcast ring where publishers stream sequence messages to $N$ concurrent subscribers. Each subscriber maintains an independent lock-free `BroadcastCursor` reading at its own pace. `TopicBus[T]` layers a concurrent `Ctrie`-backed topic routing table over per-topic `BroadcastRing[T]` instances for multi-topic pub/sub messaging.

### Overflow Modes Evaluated

1. **`omDropOldest` (`broadcast_ring_drop`, `topic_bus_drop` — Lossy Streaming)**:
   The publisher never blocks or waits. If a slow subscriber falls behind by more than the ring's capacity ($C$), its cursor detects the overrun, records lag drops, and advances automatically to the oldest valid item. Ideal for real-time telemetry, tick data, and video/audio frame broadcasting.
2. **`omBackoff` (`broadcast_ring_backoff`, `topic_bus_backoff` — Lossless Backpressure)**:
   The publisher monitors the slowest subscriber cursor. If the ring is full, the publisher yields/backs off until the slowest subscriber makes progress, guaranteeing zero message loss across all subscribers.

### Architectural Comparison

| Library Slug | Language | Implementation | Overflow Semantics | Read-Side Synchronization |
| :--- | :--- | :--- | :--- | :--- |
| `broadcast_ring_drop` | Nim | `BroadcastRing[T]` (`omDropOldest`) | Wait-free publisher; lag-detecting cursor | Private monotonic cursor (`moAcquire`) |
| `broadcast_ring_backoff` | Nim | `BroadcastRing[T]` (`omBackoff`) | Lossless publisher backpressure | Atomic cursor min-scan |
| `topic_bus_drop` / `backoff` | Nim | `TopicBus[T]` (`lockfree/broadcast`) | Per-topic `BroadcastRing` routing | Wait-free `Ctrie` topic lookup + cursor |
| `tokio_broadcast` | Rust | `tokio::sync::broadcast::channel` | Lagging receivers return `RecvError::Lagged` | Per-slot mutex/atomic tail counter |
| `rust_bus` | Rust | `bus::Bus<T>` | Lossless bounded SPMC broadcast | Atomic subscriber readiness bitmask |

---

## 2. Topographies Evaluated

- **1-to-N Multicast (`fanout`: `1p1c`, `1p2c`, `1p4c`, `1p8c`, `1p16c`)**: 1 Publisher broadcasting to 1..16 concurrent subscribers.
- **Multi-Topic Pub/Sub (`topic_bus`: `1p4c`, `2p4c`, `4p4c`, `4p8c`)**: Concurrent publishers routing messages across topics to subscriber groups.

Throughput measures **Aggregate Message Deliveries** across all active subscribers ($\sum_{i=1}^N \text{Delivered}_i / \text{elapsed ms}$). This metric accurately reflects total multicast event dissemination capacity rather than publisher-only write frequency.

---

## 3. Interactive Performance Visualizer

<div markdown="0">
  <div id="bench-status" class="bench-status" hidden></div>
  <div id="bench-toolbar" class="bench-toolbar"></div>
</div>

### 1-to-N Multicast Fan-Out (`fanout`)

<div markdown="0">
  <div id="bench-broadcast-fanout" class="bench-panel"></div>
</div>

### Multi-Topic Pub/Sub Routing (`topic_bus`)

<div markdown="0">
  <div id="bench-broadcast-topicbus" class="bench-panel"></div>

  <script src="../../../assets/echarts-5.5.1.min.js"></script>
  <script src="../../../assets/bench-charts.js"></script>
</div>

---

## Key Performance Findings

1. **Massive Multicast Fan-Out Bandwidth**:
   Under `omDropOldest`, aggregate delivered throughput reaches **24,000 to 64,000 ops/ms** across 16 concurrent subscribers. Because subscriber reads advance private atomic monotonic indices without modifying publisher state, read-side contention is minimal compared to per-slot mutex designs like `tokio::sync::broadcast`.
2. **Backpressure Cost & TopicBus Scalability**:
   `omBackoff` enforces lossless delivery at the cost of bounding the publisher to the slowest subscriber's speed, sustaining **6,000 to 17,000 ops/ms** without dropping a single frame, while `TopicBus` isolates topic contention across independent rings.
