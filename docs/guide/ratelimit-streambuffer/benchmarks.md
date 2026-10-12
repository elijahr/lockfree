# Rate Limiting & Streaming Benchmarks: TokenBucket & StreamRing

Performance benchmarks evaluating `TokenBucket` (hardware 128-bit DWCAS rate limiter) and `StreamRing` (zero-copy circular byte stream ring).

---

## 1. TokenBucket: High-Concurrency DWCAS Contention

`TokenBucket` implements a lock-free token bucket rate limiter using double-width atomic compare-and-swap (128-bit DWCAS on x86_64 `cmpxchg16b` and ARM64 `casp`). It packs fractional nano-token balances and monotonic timestamps into a single atomic struct, achieving zero-drift pacing without mutexes.

### Contention Topographies Evaluated

Under a high refill rate (1 billion tokens/sec), concurrent threads hammer `tryAcquire(1)` to measure raw hardware atomic throughput under contention across:

- **1t**: 1 Thread (Baseline single-core rate)
- **2t**: 2 Concurrent Threads
- **4t**: 4 Concurrent Threads
- **8t**: 8 Concurrent Threads
- **16t**: 16 Concurrent Threads

> [!NOTE] Contention Saturation vs. Rate-Shaping Pacing
> This benchmark is configured with a high refill rate (`1,000,000,000` tokens/sec) and capacity (`10,000,000` tokens) specifically to isolate **raw 128-bit hardware DWCAS instruction saturation under multi-core cacheline contention**. It does not measure wall-clock sleep pacing or downstream token exhaustion rejection, which are tested separately in unit tests.

### Contention Visualizer

<div markdown="0">
  <div id="bench-tokenbucket-contention" class="bench-panel"></div>
</div>

---

## 2. StreamRing: SPSC Zero-Copy Chunk Streaming

`StreamRing` implements a lock-free circular byte stream buffer designed for zero-copy audio, video, and network packet streaming. It provides `tryWrite` and `tryRead` directly over contiguous memory slices.

### Chunk Sizes Evaluated

Benchmarked over continuous 100 MB stream transfers across chunk sizes:

- **64B**: High-frequency real-time packet headers
- **512B**: Audio frames and audio callback chunks
- **4KB**: Standard OS page / memory mapping chunk size
- **64KB**: High-throughput network socket jumbo buffers

### Streaming Throughput Visualizer

<div markdown="0">
  <div id="bench-streambuffer-throughput" class="bench-panel"></div>

  <script src="../../../assets/echarts-5.5.1.min.js"></script>
  <script src="../../../assets/bench-charts.js"></script>
</div>

---

## Key Performance Findings

1. **Hardware DWCAS Scalability**:
   `TokenBucket` sustains between **32,000 and 69,000 token acquisitions/ms** (32M to 69M tokens/sec) even when 16 threads contend on the same 128-bit atomic memory slot.
2. **Extreme Zero-Copy Bandwidth**:
   `StreamRing` delivers exceptional memory throughput:
   - At **64B** chunks: >200,000 chunk transfers/ms (~12.3 GB/s bandwidth).
   - At **64KB** chunks: **41.9 GB/s bandwidth**, approaching hardware memory bus saturation limits.
