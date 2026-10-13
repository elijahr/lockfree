# Rate Limiting & Streaming Benchmarks: TokenBucket, LeakyBucket & StreamRing

Performance benchmarks evaluating `TokenBucket` and `LeakyBucket` (hardware 128-bit DWCAS rate limiters) and `StreamRing` (zero-copy circular byte stream ring) against Rust's `governor` GCRA rate limiter (`governor_gcra`), Rust's `rtrb` ring buffer (`rtrb_stream`), and C++ `boost::lockfree::spsc_queue` byte streaming (`boost_spsc_stream`).

---

## 1. TokenBucket & LeakyBucket: High-Concurrency DWCAS Contention

`TokenBucket` and `LeakyBucket` implement lock-free rate limiters using double-width atomic compare-and-swap (128-bit DWCAS on x86_64 `cmpxchg16b` and ARM64 `casp`) or packed 64-bit CAS state transitions. They pack fractional nano-token balances / water-level timestamps into a single atomic word, achieving zero-drift pacing without mutexes.

### Architectural Comparison

| Library Slug | Language | Primitive | Algorithm | Progress Guarantee |
| :--- | :--- | :--- | :--- | :--- |
| `token_bucket` | Nim | `TokenBucket` (`lockfree/ratelimit`) | 128-bit DWCAS fractional nano-token bucket | Lock-Free (CAS loop) |
| `leaky_bucket` | Nim | `LeakyBucket` (`lockfree/ratelimit`) | Atomic water-level / emission-interval meter | Lock-Free (CAS loop) |
| `governor_gcra` | Rust | `governor::RateLimiter` (Direct In-Memory) | Generic Cell Rate Algorithm (GCRA) atomic state | Lock-Free (64-bit CAS) |
| `stream_ring` | Nim | `StreamRing` (`lockfree/streambuffer`) | Zero-copy SPSC circular byte slice buffer | Wait-Free (Read & Write) |
| `rtrb_stream` | Rust | `rtrb::RingBuffer<u8>` | Wait-free SPSC chunked byte ring buffer | Wait-Free (Read & Write) |
| `boost_spsc_stream` | C++ | `boost::lockfree::spsc_queue<uint8_t>` | Array-backed SPSC bulk push/pop ring | Wait-Free (Read & Write) |

### Contention Topographies Evaluated

Under a high refill rate (1 billion tokens/sec), concurrent threads hammer `tryAcquire(1)` to measure raw hardware atomic throughput under contention across:

- **1t**: 1 Thread (Baseline single-core rate)
- **2t**: 2 Concurrent Threads
- **4t**: 4 Concurrent Threads
- **8t**: 8 Concurrent Threads
- **16t**: 16 Concurrent Threads

> [!NOTE] Contention Saturation vs. Rate-Shaping Pacing
> This benchmark is configured with a high refill rate (`1,000,000,000` tokens/sec) and capacity (`10,000,000` tokens) specifically to isolate **raw hardware atomic instruction saturation under multi-core cacheline contention**. It does not measure wall-clock sleep pacing or downstream token exhaustion rejection, which are tested separately in unit tests.

### Interactive Performance Visualizer

<div markdown="0">
  <div id="bench-status" class="bench-status" hidden></div>
  <div id="bench-toolbar" class="bench-toolbar"></div>
</div>

### Rate Limiter Contention Visualizer (`contention`)

<div markdown="0">
  <div id="bench-tokenbucket-contention" class="bench-panel"></div>
</div>

---

## 2. StreamRing: SPSC Zero-Copy Chunk Streaming

`StreamRing` implements a lock-free circular byte stream buffer designed for zero-copy audio, video, and network packet streaming. It provides `tryWrite` and `tryRead` directly over contiguous memory slices.

### Chunk Sizes Evaluated

Benchmarked over continuous 100 MB stream transfers across chunk sizes:

- **64B**: High-frequency real-time packet headers
- **256B / 512B**: Audio frames and audio callback chunks
- **1024B / 4KB**: Standard OS page / memory mapping chunk size
- **4096B / 64KB**: High-throughput network socket jumbo buffers

### Streaming Throughput Visualizer (`spsc_chunk`)

<div markdown="0">
  <div id="bench-streambuffer-throughput" class="bench-panel"></div>

  <script src="../../../assets/echarts-5.5.1.min.js"></script>
  <script src="../../../assets/bench-charts.js"></script>
</div>

---

## Key Performance Findings

1. **Hardware DWCAS & GCRA Scalability**:
   `TokenBucket` and `LeakyBucket` sustain between **32,000 and 92,000 token acquisitions/ms** (32M to 92M tokens/sec) even when 16 threads contend on the same atomic memory slot, matching or outperforming Rust's `governor` GCRA limiter.
2. **Extreme Zero-Copy Bandwidth**:
   `StreamRing` delivers exceptional memory throughput:
   - At **64B** chunks: >200,000 chunk transfers/ms (~12.3 GB/s bandwidth).
   - At **4KB–64KB** chunks: **41.9 GB/s bandwidth**, approaching hardware memory bus saturation limits alongside Rust `rtrb` and C++ `boost::lockfree::spsc_queue`.
