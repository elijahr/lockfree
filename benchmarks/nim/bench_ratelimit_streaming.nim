## Benchmarks for Rate Limiting & Streaming:
##   1. Rate Limiter Contention (`contention` across 1t, 2t, 4t, 8t, 16t):
##      - `token_bucket` (Nim Lock-Free TokenBucket with 128-bit DWCAS nano-tokens)
##      - `leaky_bucket` (Nim Lock-Free LeakyBucket / GCRA virtual scheduling)
##      - `governor_gcra` (Rust governor GCRA rate limiter)
##   2. SPSC Circular Byte Stream Buffers (`spsc_chunk` across 64b, 512b, 4kb, 64kb):
##      - `stream_ring` (Nim Lock-Free StreamRing)
##      - `rtrb_stream` (Rust rtrb wait-free SPSC byte ring buffer)
##      - `boost_spsc_stream` (C++ boost::lockfree::spsc_queue<uint8_t> bulk push/pop)
##
## Emits BMF JSON format with `throughput_ops_ms` and `bandwidth_mb_s`.

import std/[monotimes, os, parseopt, strformat, times]
import ./bench_common
import lockfree/ratelimit
import lockfree/streambuffer

const
  BenchRLRuns* {.intdefine.} = 3
  BenchRLWarmup* {.intdefine.} = 1
  BenchTokenCount* {.intdefine.} = 1_000_000
  BenchStreamBytes* {.intdefine.} = 100_000_000 # 100 MB per run
  StreamCapacity = 262144 # 256 KB buffer

when defined(adapter_rust_ffi_available):
  import ./adapters/crossbeam_link
  proc governor_init(ratePerSec: uint32, burst: uint32): pointer {.importc, cdecl.}
  proc governor_check(g: pointer): bool {.importc, cdecl.}
  proc governor_destroy(g: pointer) {.importc, cdecl.}

  proc rtrb_init(capacity: csize_t): pointer {.importc, cdecl.}
  proc rtrb_write(r: pointer, src: ptr byte, len: csize_t): csize_t {.importc, cdecl.}
  proc rtrb_read(r: pointer, dst: ptr byte, len: csize_t): csize_t {.importc, cdecl.}
  proc rtrb_destroy(r: pointer) {.importc, cdecl.}

when defined(adapter_boost_lockfree_available) and defined(cpp):
  when defined(macosx) or defined(macos):
    {.passC: "-I/opt/homebrew/opt/boost/include".}
    {.passC: "-I/usr/local/include".}
  else:
    {.passC: "-I/usr/include".}
    {.passC: "-I/usr/local/include".}

  {.emit: """/*INCLUDESECTION*/
#include <boost/lockfree/spsc_queue.hpp>
#include <cstdint>

static inline void* bench_boost_stream_init(size_t cap) {
  return static_cast<void*>(new boost::lockfree::spsc_queue<uint8_t>(cap));
}
static inline size_t bench_boost_stream_write(void* p, const void* src, size_t len) {
  return static_cast<boost::lockfree::spsc_queue<uint8_t>*>(p)->push(static_cast<const uint8_t*>(src), len);
}
static inline size_t bench_boost_stream_read(void* p, void* dst, size_t len) {
  return static_cast<boost::lockfree::spsc_queue<uint8_t>*>(p)->pop(static_cast<uint8_t*>(dst), len);
}
static inline void bench_boost_stream_destroy(void* p) {
  delete static_cast<boost::lockfree::spsc_queue<uint8_t>*>(p);
}
""".}

  proc bench_boost_stream_init(cap: csize_t): pointer {.importc, nodecl.}
  proc bench_boost_stream_write(p: pointer, src: pointer, len: csize_t): csize_t {.importc, nodecl.}
  proc bench_boost_stream_read(p: pointer, dst: pointer, len: csize_t): csize_t {.importc, nodecl.}
  proc bench_boost_stream_destroy(p: pointer) {.importc, nodecl.}

# -----------------------------------------------------------------------------
# 1. Rate Limiter Contention Harness (TokenBucket vs LeakyBucket vs Governor)
# -----------------------------------------------------------------------------
type
  RateLimiterKind = enum
    rlkTokenBucket
    rlkLeakyBucket
    rlkGovernor

  RLWorkerCtx = object
    kind: RateLimiterKind
    tbPtr: ptr TokenBucket
    lbPtr: ptr LeakyBucket
    govPtr: pointer
    opsCount: int
    threadId: int

proc rlWorkerBody(ctxPtr: ptr RLWorkerCtx) {.thread.} =
  let ctx = ctxPtr[]
  let ops = ctx.opsCount
  case ctx.kind
  of rlkTokenBucket:
    for _ in 0 ..< ops:
      while not ctx.tbPtr[].tryAcquire(1):
        benchBackoffOnPeerWait()
  of rlkLeakyBucket:
    for _ in 0 ..< ops:
      while not ctx.lbPtr[].tryConsume(1):
        benchBackoffOnPeerWait()
  of rlkGovernor:
    when defined(adapter_rust_ffi_available):
      for _ in 0 ..< ops:
        while not governor_check(ctx.govPtr):
          benchBackoffOnPeerWait()

proc runRateLimiterBenchmark(kind: RateLimiterKind, numThreads: int, totalTokens: int): float =
  var tb: TokenBucket
  var lb: LeakyBucket
  var govPtr: pointer = nil

  # Identical burst = 10_000_000 and rate = 1_000_000_000 across all 3 limiters (HIGH-A04)
  case kind
  of rlkTokenBucket:
    tb = initTokenBucket(
      capacityTokens = 10_000_000,
      refillRatePerSec = 1_000_000_000,
      initialTokens = 10_000_000
    )
  of rlkLeakyBucket:
    lb = initLeakyBucketWithBurst(
      burstTokens = 10_000_000,
      leakRatePerSec = 1_000_000_000
    )
  of rlkGovernor:
    when defined(adapter_rust_ffi_available):
      govPtr = governor_init(1_000_000_000'u32, 10_000_000'u32)

  defer:
    if kind == rlkGovernor:
      when defined(adapter_rust_ffi_available):
        governor_destroy(govPtr)

  var threads = newSeq[Thread[ptr RLWorkerCtx]](numThreads)
  var ctxs = newSeq[RLWorkerCtx](numThreads)

  let base = totalTokens div numThreads
  let rem = totalTokens mod numThreads

  for i in 0 ..< numThreads:
    ctxs[i] = RLWorkerCtx(
      kind: kind,
      tbPtr: addr tb,
      lbPtr: addr lb,
      govPtr: govPtr,
      opsCount: base + (if i < rem: 1 else: 0),
      threadId: i
    )

  let t0 = getMonoTime()
  for i in 0 ..< numThreads:
    createThread(threads[i], rlWorkerBody, addr ctxs[i])
  for i in 0 ..< numThreads:
    joinThread(threads[i])
  let elapsedNs = float(inNanoseconds(getMonoTime() - t0))

  if elapsedNs <= 0.0:
    return 0.0
  result = float(totalTokens) * 1_000_000.0 / elapsedNs

# -----------------------------------------------------------------------------
# 2. SPSC Chunk Streaming Harness (StreamRing vs RTRB vs Boost SPSC)
# -----------------------------------------------------------------------------
type
  StreamKind = enum
    skStreamRing
    skRtrb
    skBoostSpsc

  StreamWorkerCtx = object
    kind: StreamKind
    ringPtr: ptr StreamRing
    ffiPtr: pointer
    isProducer: bool
    totalBytes: int
    chunkSize: int

proc streamWorkerBody(ctxPtr: ptr StreamWorkerCtx) {.thread.} =
  let ctx = ctxPtr[]
  var buf = newSeq[byte](ctx.chunkSize)
  if ctx.isProducer:
    for i in 0 ..< ctx.chunkSize:
      buf[i] = byte(i and 0xFF)
    var written = 0
    while written < ctx.totalBytes:
      let toWrite = min(ctx.chunkSize, ctx.totalBytes - written)
      var n = 0
      case ctx.kind
      of skStreamRing:
        n = ctx.ringPtr[].tryWrite(buf.toOpenArray(0, toWrite - 1))
      of skRtrb:
        when defined(adapter_rust_ffi_available):
          n = int(rtrb_write(ctx.ffiPtr, addr buf[0], csize_t(toWrite)))
      of skBoostSpsc:
        when defined(adapter_boost_lockfree_available) and defined(cpp):
          n = int(bench_boost_stream_write(ctx.ffiPtr, addr buf[0], csize_t(toWrite)))
      if n > 0:
        written += n
      else:
        benchBackoffOnPeerWait()
  else:
    var readBytes = 0
    while readBytes < ctx.totalBytes:
      let toRead = min(ctx.chunkSize, ctx.totalBytes - readBytes)
      var n = 0
      case ctx.kind
      of skStreamRing:
        n = ctx.ringPtr[].tryRead(buf.toOpenArray(0, toRead - 1))
      of skRtrb:
        when defined(adapter_rust_ffi_available):
          n = int(rtrb_read(ctx.ffiPtr, addr buf[0], csize_t(toRead)))
      of skBoostSpsc:
        when defined(adapter_boost_lockfree_available) and defined(cpp):
          n = int(bench_boost_stream_read(ctx.ffiPtr, addr buf[0], csize_t(toRead)))
      if n > 0:
        readBytes += n
      else:
        benchBackoffOnPeerWait()

proc runStreamBenchmark(kind: StreamKind, chunkSize: int, totalBytes: int): (float, float) =
  var ring: StreamRing
  var ffiPtr: pointer = nil

  case kind
  of skStreamRing:
    ring = initStreamRing(capacity = StreamCapacity)
  of skRtrb:
    when defined(adapter_rust_ffi_available):
      ffiPtr = rtrb_init(csize_t(StreamCapacity))
  of skBoostSpsc:
    when defined(adapter_boost_lockfree_available) and defined(cpp):
      ffiPtr = bench_boost_stream_init(csize_t(StreamCapacity))

  defer:
    if kind == skRtrb:
      when defined(adapter_rust_ffi_available):
        rtrb_destroy(ffiPtr)
    elif kind == skBoostSpsc:
      when defined(adapter_boost_lockfree_available) and defined(cpp):
        bench_boost_stream_destroy(ffiPtr)

  var prodCtx = StreamWorkerCtx(
    kind: kind,
    ringPtr: addr ring,
    ffiPtr: ffiPtr,
    isProducer: true,
    totalBytes: totalBytes,
    chunkSize: chunkSize
  )
  var consCtx = StreamWorkerCtx(
    kind: kind,
    ringPtr: addr ring,
    ffiPtr: ffiPtr,
    isProducer: false,
    totalBytes: totalBytes,
    chunkSize: chunkSize
  )

  var prodThread: Thread[ptr StreamWorkerCtx]
  var consThread: Thread[ptr StreamWorkerCtx]

  let t0 = getMonoTime()
  createThread(prodThread, streamWorkerBody, addr prodCtx)
  createThread(consThread, streamWorkerBody, addr consCtx)
  joinThread(prodThread)
  joinThread(consThread)
  let elapsedNs = float(inNanoseconds(getMonoTime() - t0))

  if elapsedNs <= 0.0:
    return (0.0, 0.0)

  let numChunks = float(totalBytes) / float(chunkSize)
  let opsMs = numChunks * 1_000_000.0 / elapsedNs
  let mbS = (float(totalBytes) / (1024.0 * 1024.0)) / (elapsedNs / 1_000_000_000.0)
  result = (opsMs, mbS)

proc matchesFilter(libSlug: string, filters: seq[string]): bool {.inline.} =
  filters.len == 0 or libSlug in filters

proc main() =
  var outputPath = ""
  var filters: seq[string] = @[]
  var p = initOptParser(commandLineParams())
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdLongOption, cmdShortOption:
      if p.key in ["o", "output", "bmf-out"]:
        outputPath = p.val
    of cmdArgument:
      filters.add(p.key)

  var rlTargets = @[
    (rlkTokenBucket, "token_bucket"),
    (rlkLeakyBucket, "leaky_bucket")
  ]
  when defined(adapter_rust_ffi_available):
    rlTargets.add((rlkGovernor, "governor_gcra"))

  var streamTargets = @[
    (skStreamRing, "stream_ring")
  ]
  when defined(adapter_rust_ffi_available):
    streamTargets.add((skRtrb, "rtrb_stream"))
  when defined(adapter_boost_lockfree_available) and defined(cpp):
    streamTargets.add((skBoostSpsc, "boost_spsc_stream"))

  if filters.len > 0:
    var supported: seq[string] = @[]
    for (_, slug) in rlTargets: supported.add(slug)
    for (_, slug) in streamTargets: supported.add(slug)
    for f in filters:
      if f notin supported:
        echo &"Unknown target: {f} (supported: {supported})"
        quit 1

  echo "Rate Limiting & Streaming Benchmark (Nim vs Rust vs C++)"
  echo "========================================================"

  var emitter = initBMFEmitter()

  # 1. Rate Limiter Contention
  echo "\n--- Rate Limiter Multi-Threaded Contention ---"
  let threadConfigs = [1, 2, 4, 8, 16]

  for (rKind, libSlug) in rlTargets:
    if not matchesFilter(libSlug, filters): continue
    for threads in threadConfigs:
      for _ in 0 ..< BenchRLWarmup:
        discard runRateLimiterBenchmark(rKind, threads, BenchTokenCount)
      var samples = newSeq[float](BenchRLRuns)
      for r in 0 ..< BenchRLRuns:
        samples[r] = runRateLimiterBenchmark(rKind, threads, BenchTokenCount)
      let m = mean(samples)
      let s = stddev(samples)
      let slug = &"{libSlug}/contention/{threads}t"
      emitter.addMeasure(slug, "throughput_ops_ms", m, m - s, m + s)
      echo &"{slug}: mean = {m:10.1f} ops/ms, stddev = {s:8.1f}"

  # 2. SPSC Chunk Streaming
  echo "\n--- SPSC Chunk Streaming ---"
  let chunkConfigs = [
    (64, "64b"),
    (512, "512b"),
    (4096, "4kb"),
    (65536, "64kb")
  ]

  for (sKind, libSlug) in streamTargets:
    if not matchesFilter(libSlug, filters): continue
    for (cSize, slugSize) in chunkConfigs:
      for _ in 0 ..< BenchRLWarmup:
        discard runStreamBenchmark(sKind, cSize, BenchStreamBytes)
      var opsSamples = newSeq[float](BenchRLRuns)
      var mbSamples = newSeq[float](BenchRLRuns)
      for r in 0 ..< BenchRLRuns:
        let (ops, mb) = runStreamBenchmark(sKind, cSize, BenchStreamBytes)
        opsSamples[r] = ops
        mbSamples[r] = mb
      let opsM = mean(opsSamples)
      let opsS = stddev(opsSamples)
      let mbM = mean(mbSamples)
      let mbS = stddev(mbSamples)

      let slug = &"{libSlug}/spsc_chunk/{slugSize}"
      emitter.addMeasure(slug, "throughput_ops_ms", opsM, opsM - opsS, opsM + opsS)
      emitter.addMeasure(slug, "bandwidth_mb_s", mbM, mbM - mbS, mbM + mbS)
      echo &"{slug}: {opsM:10.1f} chunks/ms, {mbM:8.1f} MB/s"

  if outputPath.len > 0:
    emitter.emit(outputPath)
    echo &"\nEmitted results to {outputPath}"

when isMainModule:
  main()
