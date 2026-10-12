# Broadcast & Multicast Benchmarks: 1-to-N Fan-Out Scaling

Performance benchmarks evaluating `BroadcastRing` for lock-free circular 1-to-N publisher-subscriber messaging.

---

## 1. Concurrency Model & Modes

`BroadcastRing[T]` implements a high-throughput circular broadcast ring where a single publisher streams sequence messages to $N$ concurrent subscribers. Each subscriber maintains an independent lock-free `BroadcastCursor` reading at its own pace.

### Overflow Modes Evaluated

1. **`omDropOldest` (Lossy Streaming)**:
   The publisher never blocks or waits. If a slow subscriber falls behind by more than the ring's capacity ($C$), its cursor detects the overrun, records lag drops, and advances automatically to the oldest valid item. Ideal for real-time telemetry, tick data, and video/audio frame broadcasting.
2. **`omBackoff` (Lossless Backpressure)**:
   The publisher monitors the slowest subscriber cursor. If the ring is full, the publisher yields/backs off until the slowest subscriber makes progress, guaranteeing zero message loss across all subscribers.

---

## 2. Fan-Out Topographies Evaluated

- **1p1c**: 1 Publisher, 1 Subscriber
- **1p2c**: 1 Publisher, 2 Subscribers
- **1p4c**: 1 Publisher, 4 Subscribers
- **1p8c**: 1 Publisher, 8 Subscribers
- **1p16c**: 1 Publisher, 16 Subscribers

Throughput measures **Aggregate Message Deliveries** across all active subscribers ($\sum_{i=1}^N \text{Delivered}_i / \text{elapsed ms}$). This metric accurately reflects total multicast event dissemination capacity rather than publisher-only write frequency (e.g. at 1p16c, aggregate throughput reflects 16 concurrent subscriber deliveries per published message).

---

## 3. Multicast Throughput Visualizer

<div markdown="0">
  <div id="bench-broadcast-fanout" class="bench-panel"></div>

  <script src="../../../assets/echarts-5.5.1.min.js"></script>
  <script src="../../../assets/bench-charts.js"></script>
</div>

---

## Key Performance Findings

1. **Massive Multicast Fan-Out Bandwidth**:
   Under `omDropOldest`, aggregate delivered throughput reaches **24,000 to 41,000 ops/ms** across 16 concurrent subscribers. Because subscriber reads advance private atomic monotonic indices without modifying publisher state, read-side contention is minimal.
2. **Backpressure Cost & Safety**:
   `omBackoff` enforces lossless delivery at the cost of bounding the publisher to the slowest subscriber's speed, sustaining **6,000 to 17,000 ops/ms** without dropping a single frame.
