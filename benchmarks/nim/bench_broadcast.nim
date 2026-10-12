## Benchmarks for BroadcastRing: 1-to-N Fan-Out Multicast Throughput.
##
## Evaluates:
##   - BroadcastRing with omDropOldest (non-blocking lossy on lag)
##   - BroadcastRing with omBackoff (lossless backpressure)
## Across subscriber counts: 1, 2, 4, 8, 16 subscribers.
##
## Emits BMF JSON format with `throughput_ops_ms`.

import std/[monotimes, os, parseopt, strformat, times]
import ./bench_common
import lockfree/broadcast
import lockfree/atomics

const
  BenchBroadcastRuns* {.intdefine.} = 3
  BenchBroadcastWarmup* {.intdefine.} = 1
  BenchBroadcastMsgCount* {.intdefine.} = 200_000
  RingCapacity = 16384

type
  SubWorkerCtx = object
    cursor: BroadcastCursor[int]
    targetCount: int
    readCount: int
    doneFlag: ptr Atomic[bool]
    threadId: int

proc subWorkerBody(ctxPtr: ptr SubWorkerCtx) {.thread.} =
  while not ctxPtr.doneFlag[].load(moAcquire):
    var val: int
    if ctxPtr.cursor.tryRead(val):
      inc ctxPtr.readCount
    else:
      benchBackoffOnPeerWait()
  # Drain remaining
  var val: int
  while ctxPtr.cursor.tryRead(val):
    inc ctxPtr.readCount

proc runBroadcastBenchmark(overflowMode: OverflowMode, numSubscribers: int, msgCount: int): float =
  let ring = initBroadcastRing[int](capacity = RingCapacity, overflowMode = overflowMode)
  var done = Atomic[bool]()
  done.store(false, moRelaxed)

  var threads = newSeq[Thread[ptr SubWorkerCtx]](numSubscribers)
  var ctxs = newSeq[SubWorkerCtx](numSubscribers)

  for i in 0 ..< numSubscribers:
    ctxs[i] = SubWorkerCtx(
      cursor: ring.subscribe(soFromEarliest),
      targetCount: msgCount,
      readCount: 0,
      doneFlag: addr done,
      threadId: i
    )

  let t0 = getMonoTime()
  for i in 0 ..< numSubscribers:
    createThread(threads[i], subWorkerBody, addr ctxs[i])

  # Publisher loop
  for i in 0 ..< msgCount:
    while not ring.tryPublish(i):
      benchBackoffOnPeerWait()

  done.store(true, moRelease)
  for i in 0 ..< numSubscribers:
    joinThread(threads[i])
  let elapsedNs = float(inNanoseconds(getMonoTime() - t0))

  for i in 0 ..< numSubscribers:
    ctxs[i].cursor.unsubscribe()

  var totalRead = 0
  for i in 0 ..< numSubscribers:
    totalRead += ctxs[i].readCount

  if elapsedNs <= 0.0:
    return 0.0
  # Throughput = total messages successfully delivered to all subscribers / ms
  result = float(totalRead) * 1_000_000.0 / elapsedNs

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

  echo "BroadcastRing 1-to-N Fan-Out Multicast Benchmark"
  echo "================================================"

  var emitter = initBMFEmitter()
  let subConfigs = [(1, "1p1c"), (2, "1p2c"), (4, "1p4c"), (8, "1p8c"), (16, "1p16c")]
  let modes = [
    (omDropOldest, "broadcast_ring_drop"),
    (omBackoff, "broadcast_ring_backoff")
  ]

  for (mode, libSlug) in modes:
    echo &"\n--- Mode: {libSlug} ---"
    for (numSubs, shape) in subConfigs:
      var samples = newSeq[float](BenchBroadcastRuns)
      for r in 0 ..< BenchBroadcastRuns:
        samples[r] = runBroadcastBenchmark(mode, numSubs, BenchBroadcastMsgCount)
      let m = mean(samples)
      let s = stddev(samples)
      let slug = &"{libSlug}/fanout/{shape}"
      emitter.addMeasure(slug, "throughput_ops_ms", m, m - s, m + s)
      echo &"{slug}: mean = {m:10.1f} ops/ms, stddev = {s:8.1f}"

  if outputPath.len > 0:
    emitter.emit(outputPath)
    echo &"\nEmitted results to {outputPath}"

when isMainModule:
  main()
