# Channel Benchmarks: Buffered MPMC, Unbounded & 0-Buffer Rendezvous

This page compares the `lockfree` channel primitives (`Channel[T]` and `RendezvousChannel[T]`) against standard Nim channels (`system.Channel`, `threading/channels`) and established Rust channel libraries (`crossbeam-channel`, `flume`, `kanal`).

---

## 1. Channel Families & Concurrency Semantics

`lockfree` provides two complementary channel families designed for different synchronization requirements:

1. **Buffered & Unbounded `Channel[T]` (`lockfree/channel`)**:
   - **Bounded (`ckBounded`)**: Wraps the cache-line-padded Vyukov bounded MPMC ring buffer (`BQueue[T]`). In steady state it performs zero heap allocations. Non-blocking calls (`trySend`, `tryRecv`) complete without locks; blocking calls (`send`, `recv`) use adaptive exponential backoff before parking.
   - **Unbounded (`ckUnbounded`)**: Wraps the linked-segment MPMC queue (`Queue[T]`) with epoch-based safe memory reclamation (NEBR) and automatic `{.threadvar.}` endpoint caching. Senders never block on capacity limits.
2. **Zero-Buffer `RendezvousChannel[T]` (`lockfree/rendezvous`)**:
   - **Strict 0-Buffer Synchronous Handoff**: Capacity is zero. A sender waits until a receiver arrives to take the message directly, and a receiver waits until a sender delivers a message.
   - **Scherer-Scott-Michael (SSM) Dual-Queue + Elimination Array**: Under multi-threaded contention (`2p2c`, `4p4c`, `8p8c`), colliding senders and receivers exchange payloads directly in a cache-line-isolated elimination array without contending on the central queue pointers. Idle waiters park on lightweight OS futexes (`ulock_wait` on macOS, `futex` on Linux, `WaitOnAddress` on Windows).

---

## 2. Contenders Compared

| Contender | Language | Channel Variant(s) | Synchronization & Back-Pressure Model |
| :--- | :--- | :--- | :--- |
| **`lockfree` (`Channel[T]`)** | Nim | Bounded (`ckBounded`) & Unbounded (`ckUnbounded`) | Lock-free Vyukov ring (`BQueue`) or LCRQ/segment queue (`Queue`) with adaptive backoff |
| **`lockfree` (`RendezvousChannel[T]`)** | Nim | 0-Buffer Synchronous (`newRendezvousChannel`) | Lock-free SSM dual-queue + elimination backoff array + OS futex parker |
| **`crossbeam`** | Rust | `bounded(N)`, `unbounded()`, `bounded(0)` | Array ring buffer, linked segments, or rendezvous parking list |
| **`flume`** | Rust | `bounded(N)`, `unbounded()`, `bounded(0)` | Spinlock-guarded ring/queue and direct rendezvous slot exchange |
| **`kanal`** | Rust | `bounded(N)`, `unbounded()`, `bounded(0)` | Direct stack-pointer transfer with mutex wait-queue fallback |
| **Nim `system.Channel`** | Nim | `system.Channel[T]` (bounded, `maxItems = 1` for sync) | Global `pthread_mutex_t` + `pthread_cond_t` lock around an internal deque (thread-safe for MPSC & MPMC; blocks when full) |
| **Nim `threading/channels`** | Nim | `threading/channels.Chan[T]` | Mutex-guarded fixed ring buffer with non-blocking `trySend`/`tryRecv` |

### How Nim's `system.Channel` Works Under Contention

Nim's built-in `system.Channel[T]` is thread-safe for both multi-producer single-consumer (MPSC) and multi-producer multi-consumer (MPMC) workloads because every `send`, `trySend`, `recv`, and `tryRecv` acquires a channel-wide OS mutex (`pthread_mutex_t`). While safe across arbitrary producer and consumer counts, this single lock serializes all participating threads onto one cache line and triggers kernel condition-variable wakeups when bounded capacity fills. By contrast, `lockfree` coordinates threads through per-slot atomic sequence numbers and elimination slots, allowing multiple producers and consumers to make progress in parallel.

---

## 3. Key Performance Highlights

- **Bounded MPMC Throughput**: At `4p4c` (4 producers, 4 consumers), `lockfree` bounded MPMC sustains over **37,000 ops/ms**, outperforming `system.Channel` by up to **21.9x** and matching or exceeding Rust's `crossbeam`, `flume`, and `kanal`.
- **MPSC Fan-In Scaling**: When multiple producers fan into a single consumer (`2p1c`, `4p1c`, `8p1c`), `lockfree` avoids the global mutex bottleneck of `system.Channel`, sustaining high throughput across all producer counts.
- **0-Buffer Rendezvous Scaling**: As contention grows from `1p1c` to `4p4c` and `8p8c`, `system.Channel` (`maxItems = 1`) drops from **343.4 ops/ms** to **113.4 ops/ms**, whereas `RendezvousChannel[T]` scales upward from **421.1 ops/ms** to **506.9 ops/ms** (**4.4x faster**) as colliding pairs resolve directly inside the elimination array.
- **Low-Latency Synchronous RPC**: Two-way request/reply round trips over `RendezvousChannel[T]` complete in a median (`p50`) of **4,542 ns** (~2.2 µs per one-way handoff).

---

## 4. Interactive Channel Benchmarks

Use the filter toolbar below to slice measurements by thread topology (`1p1c`, `2p2c`, `4p4c`, `8p8c`), switch between logarithmic and linear Y-axes, or toggle individual libraries in each chart legend.

<div markdown="0">
  <div id="bench-status" class="bench-status" hidden></div>
  <div id="bench-toolbar" class="bench-toolbar"></div>
</div>

### Bounded MPMC Channel & Queue Throughput (`mpmc_bounded`)

Compares bounded MPMC throughput across `1p1c`, `2p2c`, `4p4c`, and `8p8c` contention shapes (`Throughput: Higher is better ↑`).

<div markdown="0">
  <div id="bench-throughput-mpmc-bounded" class="bench-panel"></div>
</div>

### Unbounded MPMC Channel & Queue Throughput (`mpmc_unbounded`)

Compares unbounded MPMC throughput where producers never block on capacity (`Throughput: Higher is better ↑`).

<div markdown="0">
  <div id="bench-throughput-mpmc-unbounded" class="bench-panel"></div>
</div>

### Multi-Producer Single-Consumer (MPSC) Throughput (`mpsc`)

Compares fan-in workloads (`1p1c`, `2p1c`, `4p1c`, `8p1c`) where multiple producers send into a single consumer (`Throughput: Higher is better ↑`).

<div markdown="0">
  <div id="bench-throughput-mpsc" class="bench-panel"></div>
</div>

---

### 0-Buffer Synchronous Rendezvous Handoff (`rendezvous_handoff`)

Compares strict zero-buffer bilateral handoff throughput (`RendezvousChannel[T]` vs `crossbeam_channel::bounded(0)`, `flume::bounded(0)`, `kanal::bounded(0)`, and `system.Channel` with `maxItems = 1`) (`Throughput: Higher is better ↑`).

<div markdown="0">
  <div id="bench-rendezvous-handoff" class="bench-panel"></div>
</div>

---

### Synchronous 1:1 RPC Round-Trip Throughput (`rendezvous_rpc`)

Measures two-way request/response ping-pong throughput over a pair of synchronous rendezvous channels (`Throughput: Higher is better ↑`).

<div markdown="0">
  <div id="bench-rendezvous-rpc" class="bench-panel"></div>
</div>

---

### Synchronous 1:1 RPC Round-Trip Latency (`ns`)

Measures full two-way request/response round-trip time in nanoseconds (`p50`, `p95`, `p99`, `p999`, `max`) (`Latency: Lower is better ↓`). Use the toggle above the chart to switch between the **Percentile Ladder** and **Grouped Bars** views.

<div markdown="0">
  <div id="bench-rendezvous-latency" class="bench-panel"></div>

  <script src="../../../assets/d3-7.9.0.min.js"></script>
  <script src="../../../assets/plot-0.6.17.umd.min.js"></script>
  <script src="../../../assets/bench-charts.js"></script>
</div>
