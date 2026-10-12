## Benchmarks for Rate Limiting & Streaming: TokenBucket & StreamRing.
##
## Evaluates:
##   1. TokenBucket high-concurrency token acquisition contention (1, 2, 4, 8, 16 threads).
##   2. StreamRing SPSC circular byte stream throughput & bandwidth across chunk sizes (64B, 512B, 4KB, 64KB).
##
## Emits BMF JSON format with `throughput_ops_ms` and `bandwidth_mb_s`.

import std/[monotimes, os, parseopt, strformat, times]
import ./bench_common
import lockfree/ratelimit
import lockfree/streambuffer
import lockfree/atomics

const
  BenchRLRuns* {.intdefine.} = 3
  BenchRLWarmup* {.intdefine.} = 1
  BenchTokenCount* {.intdefine.} = 1_000_000
  BenchStreamBytes* {.intdefine.} = 100_000_000 # 100 MB per run

# -----------------------------------------------------------------------------
# 1. TokenBucket Contention Harness
# -----------------------------------------------------------------------------
type
  TokenWorkerCtx = object
    tbPtr: ptr TokenBucket
    opsCount: int
    threadId: int

proc tokenWorkerBody(ctxPtr: ptr TokenWorkerCtx) {.thread.} =
  let ops = ctxPtr.opsCount
  for _ in 0 ..< ops:
    while not ctxPtr.tbPtr[].tryAcquire(1):
      benchBackoffOnPeerWait()

proc runTokenBucketBenchmark(numThreads: int, totalTokens: int): float =
  var tb = initTokenBucket(
    capacityTokens = 10_000_000,
    refillRatePerSec = 1_000_000_000, # 1 billion tokens/sec: measure atomic CAS contention
    initialTokens = 10_000_000
  )

  var threads = newSeq[Thread[ptr TokenWorkerCtx]](numThreads)
  var ctxs = newSeq[TokenWorkerCtx](numThreads)

  let base = totalTokens div numThreads
  let rem = totalTokens mod numThreads

  for i in 0 ..< numThreads:
    ctxs[i] = TokenWorkerCtx(
      tbPtr: addr tb,
      opsCount: base + (if i < rem: 1 else: 0),
      threadId: i
    )

  let t0 = getMonoTime()
  for i in 0 ..< numThreads:
    createThread(threads[i], tokenWorkerBody, addr ctxs[i])
  for i in 0 ..< numThreads:
    joinThread(threads[i])
  let elapsedNs = float(inNanoseconds(getMonoTime() - t0))

  if elapsedNs <= 0.0:
    return 0.0
  result = float(totalTokens) * 1_000_000.0 / elapsedNs

# -----------------------------------------------------------------------------
# 2. StreamRing SPSC Chunk Streaming Harness
# -----------------------------------------------------------------------------
type
  StreamProducerCtx = object
    ringPtr: ptr StreamRing
    totalBytes: int
    chunkSize: int

  StreamConsumerCtx = object
    ringPtr: ptr StreamRing
    totalBytes: int
    chunkSize: int

proc streamProducerBody(ctxPtr: ptr StreamProducerCtx) {.thread.} =
  let chunk = newSeq[byte](ctxPtr.chunkSize)
  var written = 0
  while written < ctxPtr.totalBytes:
    let toWrite = min(ctxPtr.chunkSize, ctxPtr.totalBytes - written)
    let n = ctxPtr.ringPtr[].tryWrite(chunk.toOpenArray(0, toWrite - 1))
    if n > 0:
      written += n
    else:
      benchBackoffOnPeerWait()

proc streamConsumerBody(ctxPtr: ptr StreamConsumerCtx) {.thread.} =
  var buf = newSeq[byte](ctxPtr.chunkSize)
  var readBytes = 0
  while readBytes < ctxPtr.totalBytes:
    let toRead = min(ctxPtr.chunkSize, ctxPtr.totalBytes - readBytes)
    let n = ctxPtr.ringPtr[].tryRead(buf.toOpenArray(0, toRead - 1))
    if n > 0:
      readBytes += n
    else:
      benchBackoffOnPeerWait()

proc runStreamBenchmark(chunkSize: int, totalBytes: int): (float, float) =
  var ring = initStreamRing(capacity = 262144) # 256 KB buffer

  var prodCtx = StreamProducerCtx(
    ringPtr: addr ring,
    totalBytes: totalBytes,
    chunkSize: chunkSize
  )
  var consCtx = StreamConsumerCtx(
    ringPtr: addr ring,
    totalBytes: totalBytes,
    chunkSize: chunkSize
  )

  var prodThread: Thread[ptr StreamProducerCtx]
  var consThread: Thread[ptr StreamConsumerCtx]

  let t0 = getMonoTime()
  createThread(prodThread, streamProducerBody, addr prodCtx)
  createThread(consThread, streamConsumerBody, addr consCtx)
  joinThread(prodThread)
  joinThread(consThread)
  let elapsedNs = float(inNanoseconds(getMonoTime() - t0))

  if elapsedNs <= 0.0:
    return (0.0, 0.0)

  let numChunks = float(totalBytes) / float(chunkSize)
  let ops_ms = numChunks * 1_000_000.0 / elapsedNs
  let mb_s = (float(totalBytes) / (1024.0 * 1024.0)) / (elapsedNs / 1_000_000_000.0)
  result = (ops_ms, mb_s)

proc main() =
  var outputPath = ""
  var p = initOptParser(commandLineParams())
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdLongOption, cmdShortOption:
      if p.key in ["o", "output", "bmf-out"]:
        outputPath = p.val
    of cmdArgument: discard

  echo "Rate Limiting & Streaming Benchmark (TokenBucket & StreamRing)"
  echo "=============================================================="

  var emitter = initBMFEmitter()

  # 1. TokenBucket Contention
  echo "\n--- TokenBucket Multi-Threaded Contention ---"
  let threadConfigs = [1, 2, 4, 8, 16]
  for threads in threadConfigs:
    var samples = newSeq[float](BenchRLRuns)
    for r in 0 ..< BenchRLRuns:
      samples[r] = runTokenBucketBenchmark(threads, BenchTokenCount)
    let m = mean(samples)
    let s = stddev(samples)
    let slug = &"token_bucket/contention/{threads}t"
    emitter.addMeasure(slug, "throughput_ops_ms", m, m - s, m + s)
    echo &"{slug}: mean = {m:10.1f} ops/ms, stddev = {s:8.1f}"

  # 2. StreamRing SPSC Chunk Streaming
  echo "\n--- StreamRing SPSC Chunk Streaming ---"
  let chunkConfigs = [
    (64, "64b"),
    (512, "512b"),
    (4096, "4kb"),
    (65536, "64kb")
  ]
  for (cSize, slugSize) in chunkConfigs:
    var opsSamples = newSeq[float](BenchRLRuns)
    var mbSamples = newSeq[float](BenchRLRuns)
    for r in 0 ..< BenchRLRuns:
      let (ops, mb) = runStreamBenchmark(cSize, BenchStreamBytes)
      opsSamples[r] = ops
      mbSamples[r] = mb
    let opsM = mean(opsSamples)
    let opsS = stddev(opsSamples)
    let mbM = mean(mbSamples)
    let mbS = stddev(mbSamples)

    let slug = &"stream_ring/spsc_chunk/{slugSize}"
    emitter.addMeasure(slug, "throughput_ops_ms", opsM, opsM - opsS, opsM + opsS)
    emitter.addMeasure(slug, "bandwidth_mb_s", mbM, mbM - mbS, mbM + mbS)
    echo &"{slug}: {opsM:10.1f} chunks/ms, {mbM:8.1f} MB/s"

  if outputPath.len > 0:
    emitter.emit(outputPath)
    echo &"\nEmitted results to {outputPath}"

when isMainModule:
  main()
