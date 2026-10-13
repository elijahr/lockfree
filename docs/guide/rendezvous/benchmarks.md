# Rendezvous Channel Benchmarks: 0-Buffer Synchronous Handoff & RPC

Performance benchmarks evaluating `RendezvousChannel[T]` (Scherer-Scott-Michael dual-queue 0-buffer synchronous handoff channel) against Nim `system.Channel[T]` (`maxItems = 1`) and Rust zero-capacity channels (`crossbeam_channel::bounded(0)`, `flume::bounded(0)`, `kanal::bounded(0)`).

---

## 1. Concurrency Model & Topologies

Unlike buffered queues where producers deposit items into ring buffers and continue immediately, a **0-buffer rendezvous channel** enforces strict bilateral synchronization: a sender blocks (or spins) until a matching receiver arrives to accept the payload directly, and vice versa.

`RendezvousChannel[T]` implements the **Scherer-Scott-Michael (SSM) Dual-Queue** with an **Elimination Backoff Array** and adaptive three-phase parking (`Spin` $\to$ `Yield` $\to$ `Futex/Condvar Park`):

1. **Elimination Fast Path**: Under symmetric multi-producer/multi-consumer contention (`2p2c`, `4p4c`, `8p8c`), colliding senders and receivers exchange 64-bit payloads directly in a cache-line-isolated elimination slot without touching the central dual-queue head/tail pointers.
2. **Dual-Queue Reservation Path**: If no partner is waiting in the elimination array, the thread publishes a reservation node (`mode = SEND` or `mode = RECV`) and awaits fulfillment via atomic slot state transition (`EMPTY` $\to$ `OFFERED` $\to$ `CLAIMED`).

### Topographies Evaluated

- **`rendezvous_handoff` (`1p1c`, `2p2c`, `4p4c`, `8p8c`)**: Symmetric producer-consumer pairs performing 100,000 synchronous 0-buffer handoffs per run.
- **`rendezvous_rpc` (`1p1c`)**: Two-way synchronous request/response ping-pong over a request/reply channel pair, measuring both throughput (`ops/ms`) and per-call round-trip latency percentiles (`p50`, `p95`, `p99`, `p999`, `max` in nanoseconds).

---

## 2. Architectural Comparison

| Library Slug | Language | Implementation | Synchronization Mechanism |
| :--- | :--- | :--- | :--- |
| `rendezvous_channel` | Nim | `lockfree/rendezvous` (`RendezvousChannel[T]`) | Lock-free SSM dual-queue + elimination array + adaptive parker |
| `nim_channel_sync` | Nim | `system.Channel[T]` (`open(maxItems = 1)`) | Blocking mutex + condition variable (`pthread_mutex_t` + `pthread_cond_t`) |
| `crossbeam_rendezvous` | Rust | `crossbeam_channel::bounded(0)` | Rendezvous flavor with internal spin + thread parking list |
| `flume_rendezvous` | Rust | `flume::bounded(0)` | Spinlock-guarded wait queue + rendezvous slot exchange |
| `kanal_rendezvous` | Rust | `kanal::bounded(0)` | Direct stack-pointer handoff with mutex wait-queue fallback |

---

## 3. Key Performance Findings

1. **Contention Scaling via Elimination Backoff**:
   On Apple M-series / multi-core hardware, `nim_channel_sync` degrades sharply as thread pairs increase—dropping from **343.4 ops/ms** at `1p1c` down to **113.4 ops/ms** at `4p4c` due to global mutex serialization. In contrast, `RendezvousChannel[T]` scales **upward** with contention as colliding pairs resolve in the elimination array, rising from **421.1 ops/ms** at `1p1c` to **503.4 ops/ms** at `4p4c` (**4.4x faster** than `system.Channel`) and **506.9 ops/ms** at `8p8c`.
2. **Sub-5-Microsecond Synchronous RPC Round-Trip**:
   In the `1p1c` ping-pong RPC benchmark (two full synchronous handoffs per round trip), `RendezvousChannel[T]` achieves a median round-trip latency (`p50`) of **4,542 ns** (~2.2 µs per one-way handoff) and a `p99` of **14,597 ns**.

---

## 4. Interactive Performance Visualizer

<div markdown="0">
  <div id="bench-status" class="bench-status" hidden></div>
  <div id="bench-toolbar" class="bench-toolbar"></div>
</div>

### Synchronous 0-Buffer Handoff Throughput (`rendezvous_handoff`)

<div markdown="0">
  <div id="bench-rendezvous-handoff" class="bench-panel"></div>
</div>

### Synchronous 1:1 RPC Throughput (`rendezvous_rpc`)

<div markdown="0">
  <div id="bench-rendezvous-rpc" class="bench-panel"></div>
</div>

### Synchronous 1:1 RPC Round-Trip Latency (`ns`)

<div markdown="0">
  <div id="bench-rendezvous-latency" class="bench-panel"></div>

  <script src="../../../assets/echarts-5.5.1.min.js"></script>
  <script src="../../../assets/bench-charts.js"></script>
</div>
