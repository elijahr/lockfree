# Queue Benchmarks: Throughput, Latency & Contention

This page compares the `lockfree` queue engines against alternative concurrent queues in Nim, C, C++, and Rust.

---

## How to Read These Charts

Every chart organizes measurements along three dimensions:

1. **Library**: Which queue implementation is being tested (`lockfree` is highlighted in bold indigo `#6366f1`).
2. **Topology**: How many threads are allowed to push and pop:
   - **SPSC** (Single-Producer Single-Consumer): Exactly one producer thread and one consumer thread (`1p1c`). Because only one thread touches the head and only one touches the tail, SPSC queues can be wait-free without atomic compare-and-swap loops.
   - **SPMC** (Single-Producer Multi-Consumer): One producer feeding multiple concurrent consumers.
   - **MPSC** (Multi-Producer Single-Consumer): Multiple concurrent producers feeding one consumer (`1p1c`, `2p1c`, `4p1c`, `8p1c`).
   - **MPMC** (Multi-Producer Multi-Consumer): Multiple concurrent producers and multiple concurrent consumers (`1p1c`, `2p2c`, `4p4c`, `8p8c`).
3. **Contention Shape (`NpMc`)**: The number of active producer (`Np`) and consumer (`Mc`) threads sharing a single queue instance. For example, `4p4c` runs four producer threads and four consumer threads concurrently on the same queue.

### Directionality & Units

- **Throughput Charts (`ops/ms`)**: Measure completed enqueue + dequeue operations per millisecond. **Higher is better (`↑`)**.
- **Latency Charts (`ns`)**: Measure round-trip ping-pong time in nanoseconds across the `p50`, `p95`, `p99`, `p999`, and `max` percentiles. **Lower is better (`↓`)**.

### Bounded vs. Unbounded Queues

- **Bounded Queues (`BQueue[T]`)**: Use a fixed-capacity ring buffer allocated once at initialization with cache-line padded cells. When the buffer is full, `tryPush` returns `false` immediately without allocating memory or blocking the caller.
- **128-Bit DWCAS Bounded Queues (`BQueue128[T]`)**: Use dense 16-byte slots with single-instruction hardware Double-Word CAS (DWCAS) for atomic publish without producer stalls, achieving up to 129.4M ops/s on low-contention topologies. See the [BQueue128 Guide](bqueue128.md#empirical-benchmarks-architectural-trade-offs) for a complete empirical trade-off analysis.
- **Unbounded Queues (`Queue[T]`)**: Use linked ring segments reclaimed automatically via Epoch-Based Safe Memory Reclamation (NEBR). Producers never encounter a full queue, trading a small per-operation reclamation cost for elastic capacity. See [Bounded vs. Unbounded](../bounded-vs-unbounded.md) for a detailed comparison.

### How `system.Channel` Handles MPSC and MPMC Thread Safety

Nim's standard `system.Channel[T]` is thread-safe for both MPSC and MPMC workloads because it protects its internal buffer with an operating-system mutex (`pthread_mutex_t`) and condition variable (`pthread_cond_t`). Every send and receive acquires that shared lock:

- **Thread-Safety**: Multiple producers and multiple consumers can safely share a `system.Channel[T]` without data races because the mutex serializes every access.
- **Blocking Back-Pressure**: When a bounded `system.Channel[T]` reaches capacity, `send` blocks the calling producer thread on the condition variable until a consumer removes an item.
- **Performance Impact**: Under multi-threaded contention (`2p2c`, `4p4c`, `8p8c`), all threads compete for the same mutex cache line. In the charts below, libraries that block when full are marked with an asterisk (`*`) and a `(blocking)` label.

---

## When to Choose `lockfree`

- **Single-Producer Single-Consumer (`newSpscQueue`)**: Ideal for audio callbacks, render pipelines, and dedicated I/O reader threads. Both `tryPush` and `tryPop` are wait-free (`O(1)`) and sustain over **45,000 ops/ms** (>45 million operations per second).
- **High-Contention Multi-Producer Multi-Consumer (`newMpmcQueue`)**: Ideal for work distribution, thread pools, and telemetry pipelines. At `4p4c`, `lockfree` sustains over **37,000 ops/ms**—up to **21.9x faster** than `system.Channel` at the same thread count.
- **Multi-Producer Fan-In (`newMpscQueue`)**: Ideal when many worker threads submit events or logs to a single consumer thread without mutex serialization.

### When Another Primitive Fits Better

- **You want automatic thread sleeping on a full or empty channel**: Use [`Channel[T]`](../channels/benchmarks.md) (`send` / `recv` with adaptive backoff) or [`RendezvousChannel[T]`](../channels/benchmarks.md) (for 0-buffer synchronous handoffs).
- **You are transferring GC-managed `ref` objects across threads**: Wrap managed references in [`ManagedRef[T]`](../managed-ref.md) or [`ManagedSlice[T]`](../managed-slice.md) so ownership is transferred safely under ARC/ORC/atomicArc.

---

## Benchmark Methodology

- **Throughput Suite**: `N` producer threads and `M` consumer threads share one queue and transfer `1,000,000` 64-bit integer payloads per run across 33 iterations after warmup. Throughput is reported in operations per millisecond (`ops/ms`).
- **Latency Suite**: Two threads exchange a 64-bit token back and forth across two queues for `100,000` round trips per run. Round-trip time (RTT) is recorded in nanoseconds (`ns`) at `p50`, `p95`, `p99`, `p999`, and `max`.

### Running the Benchmarks Locally

```bash
# Quick verification run (10 iterations)
nimble benchmarks

# Full statistical benchmark suite (33 iterations)
python3 benchmarks/runner.py run --runs=33
```

---

## Queues Compared

### `lockfree` Queue Families

| Benchmark Slug | Topology | Constructor | Capacity Model |
| :--- | :--- | :--- | :--- |
| `lockfree_spsc` | SPSC (`1p1c`) | `newSpscQueue` | Bounded ring buffer |
| `lockfree_spmc` | SPMC | `newSpmcQueue` | Bounded ring buffer |
| `lockfree_mpsc` | MPSC (`1p1c`..`8p1c`) | `newMpscQueue` | Bounded ring buffer |
| `lockfree_mpmc` | MPMC (`1p1c`..`8p8c`) | `newMpmcQueue` | Bounded ring buffer (Vyukov) |
| `lockfree_bqueue128` | MPMC / SPSC (`1p1c`..`8p8c`) | `initBQueue128` / `allocAlignedBQueue128` | Bounded ring buffer (128-bit DWCAS) |
| `lockfree_unbounded_spsc` | SPSC (`1p1c`) | `newUnboundedSpscQueue` | Unbounded linked segments |
| `lockfree_unbounded_spmc` | SPMC | `newUnboundedSpmcQueue` | Unbounded linked segments |
| `lockfree_unbounded_mpsc` | MPSC (`1p1c`..`8p1c`) | `newUnboundedMpscQueue` | Unbounded linked segments |
| `lockfree_unbounded_mpmc` | MPMC (`1p1c`..`8p8c`) | `newUnboundedMpmcQueue` | Unbounded linked segments (LCRQ + NEBR) |

### External Reference Libraries

| Library | Language | Implementation Tested | Topologies Covered |
| :--- | :--- | :--- | :--- |
| **MoodyCamel** | C++ | `moodycamel::ConcurrentQueue` | Unbounded MPMC |
| **Boost.LockFree** | C++ | `boost::lockfree::spsc_queue`, `boost::lockfree::queue` | Bounded SPSC, Bounded MPMC |
| **atomic_queue** | C++ | `atomic_queue::AtomicQueueB` | Bounded SPSC, Bounded MPMC |
| **rigtorp** | C++ | `rigtorp::SPSCQueue`, `rigtorp::MPMCQueue` | Bounded SPSC, Bounded MPMC |
| **crossbeam** | Rust | `crossbeam_queue::ArrayQueue`, `crossbeam_queue::SegQueue` | Bounded MPMC, Unbounded MPMC |
| **flume** | Rust | `flume::bounded`, `flume::unbounded` | Bounded MPMC, Unbounded MPMC |
| **kanal** | Rust | `kanal::bounded`, `kanal::unbounded` | Bounded SPSC, Bounded MPMC, Unbounded MPMC |
| **liblfds** | C | `lfds711_queue_bss` (SPSC), `lfds711_queue_bmm` (MPMC) | Bounded SPSC, Bounded MPMC |
| **Nim `system.Channel`** | Nim | `system.Channel[T]` (mutex-guarded, blocks when full\*) | MPSC, Bounded MPMC |
| **Nim `threading/channels`** | Nim | `threading/channels.Chan[T]` (mutex-guarded) | Bounded MPMC |
| **Loony** | Nim | `LoonyQueue` | Unbounded MPMC |

\* `system.Channel` serializes producers and consumers with an OS mutex and blocks producers when the buffer is full. Its bars and lines are marked with an asterisk (`*`) and a `(blocking)` indicator.

---

## Interactive Results

Click any library in a chart's legend to show or hide its series. Use the toolbar to filter by contention shape or switch between logarithmic and linear Y-axes.

#### Headline: `lockfree` vs. Alternatives (`4p4c` Bounded MPMC)

<div markdown="0">
  <div id="bench-status" class="bench-status" hidden></div>
  <div id="bench-toolbar" class="bench-toolbar"></div>

  <div id="bench-hero" class="bench-panel bench-panel-hero">
    <noscript>
      Charts require JavaScript. Raw benchmark data is available at
      <code>../../assets/bench-results/latest.json</code>.
    </noscript>
  </div>
</div>

---

### 1. Single-Producer Single-Consumer (SPSC)

Dedicated wait-free ring buffer comparison at `1p1c`. Includes specialized SPSC queues alongside general MPSC and MPMC queues running in single-producer, single-consumer mode to measure the marginal synchronization overhead of general multi-threading primitives.

<div markdown="0">
  <div id="bench-throughput-spsc" class="bench-panel"></div>
</div>

---

### 2. Multi-Producer Single-Consumer (MPSC)

Throughput scaling across `1p1c`, `2p1c`, `4p1c`, and `8p1c` producer fan-in shapes. Compares dedicated MPSC queues against multi-producer multi-consumer queues under concurrent push contention feeding a single consumer thread.

<div markdown="0">
  <div id="bench-throughput-mpsc" class="bench-panel"></div>
</div>

---

### 3. Multi-Producer Multi-Consumer (Bounded MPMC)

Throughput scaling across symmetric contention shapes (`1p1c`, `2p2c`, `4p4c`, `8p8c`) for fixed-capacity ring buffers. When full, producers return `false` immediately without blocking or heap allocation.

<div markdown="0">
  <div id="bench-throughput-mpmc-bounded" class="bench-panel"></div>
</div>

---

### 4. Multi-Producer Multi-Consumer (Unbounded MPMC)

Throughput scaling for elastic linked-segment queues with safe memory reclamation across `1p1c`, `2p2c`, `4p4c`, and `8p8c`. Compares `lockfree.uqueue.Queue` against `loony.LoonyQueue` and cross-language alternatives (`moodycamel`, `crossbeam`).

<div markdown="0">
  <div id="bench-throughput-mpmc-unbounded" class="bench-panel"></div>
</div>

---

### 5. Round-Trip Latency Distribution

Token exchange latency in nanoseconds measured across percentiles (`p50`, `p95`, `p99`, `p999`, and `max`). **Lower is better ↓**. Use the toggle to switch between the percentile ladder and grouped bar view.

<div markdown="0">
  <div id="bench-latency" class="bench-panel"></div>

  <script src="../../../assets/d3-7.9.0.min.js"></script>
  <script src="../../../assets/plot-0.6.17.umd.min.js"></script>
  <script src="../../../assets/bench-charts.js"></script>
</div>

---

## Fairness & Hardware Notes

- **Cache-Line Alignment**: `lockfree`, `MoodyCamel`, `Boost.LockFree`, `atomic_queue`, and `rigtorp` align internal head, tail, and sequence indices to cache-line boundaries (64 bytes on x86_64, 128 bytes on Apple Silicon) to prevent false sharing.
- **Memory Ordering**: `lockfree` uses `moAcquire` / `moRelease` operations on hot paths; libraries that default to `seq_cst` incur additional memory-fence overhead.
- **Payload & Capacity Parity**: All queue benchmarks transfer identical 8-byte `uint64` payloads and use matched ring-buffer capacities across bounded implementations.
- **High Thread Counts (`8p8c`)**: On 4-vCPU CI runners, `8p8c` (16 total threads) measures operating-system scheduler oversubscription alongside queue contention.
