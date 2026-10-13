## Benchmarks for BroadcastRing & TopicBus vs Rust tokio::sync::broadcast & bus::Bus:
##   1. 1-to-N Fan-Out (`fanout` across 1p1c, 1p2c, 1p4c, 1p8c, 1p16c):
##      - `broadcast_ring_drop` (Nim BroadcastRing with omDropOldest)
##      - `broadcast_ring_backoff` (Nim BroadcastRing with omBackoff)
##      - `tokio_broadcast` (Rust tokio::sync::broadcast, lagging-overwrite ring)
##      - `rust_bus` (Rust bus::Bus, lossless SPMC broadcast ring)
##   2. MP-to-MC Topic Pub-Sub (`topic_bus` across 2p2c, 2p4c, 4p4c, 4p8c):
##      - `topic_bus_drop` (Nim TopicBus with omDropOldest across 4 topics)
##      - `topic_bus_backoff` (Nim TopicBus with omBackoff across 4 topics)
##      - `tokio_broadcast` (Rust tokio::sync::broadcast MPMC fan-out)
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
  TopicNames = ["topic_0", "topic_1", "topic_2", "topic_3"]

when defined(adapter_rust_ffi_available):
  import ./adapters/crossbeam_link
  proc tokio_bcast_init(capacity: csize_t, numSubs: csize_t): pointer {.importc, cdecl.}
  proc tokio_bcast_send(b: pointer, item: uint64): bool {.importc, cdecl.}
  proc tokio_bcast_try_recv(b: pointer, subIdx: csize_t, outVal: ptr uint64): cint {.importc, cdecl.}
  proc tokio_bcast_destroy(b: pointer) {.importc, cdecl.}

  proc rust_bus_init(capacity: csize_t, numSubs: csize_t): pointer {.importc, cdecl.}
  proc rust_bus_try_broadcast(b: pointer, item: uint64): bool {.importc, cdecl.}
  proc rust_bus_try_recv(b: pointer, subIdx: csize_t, outVal: ptr uint64): bool {.importc, cdecl.}
  proc rust_bus_destroy(b: pointer) {.importc, cdecl.}

# -----------------------------------------------------------------------------
# 1. Nim BroadcastRing 1-to-N Fan-Out Harness (CRIT-A02 compliant poll loop)
# -----------------------------------------------------------------------------
type
  SubWorkerCtx = object
    cursor: BroadcastCursor[int]
    targetCount: int
    readCount: int
    doneFlag: ptr Atomic[bool]
    threadId: int

proc drainCursor(cursor: var BroadcastCursor[int], readCount: var int) {.inline.} =
  while true:
    let res = cursor.poll()
    case res.kind
    of prSuccess:
      inc readCount
    of prLagged:
      # Cursor readSeq was advanced to the ring horizon; immediately retry
      # without exiting the drain loop (CRIT-A02).
      continue
    of prEmpty:
      break

proc subWorkerBody(ctxPtr: ptr SubWorkerCtx) {.thread.} =
  while not ctxPtr.doneFlag[].load(moAcquire):
    let res = ctxPtr.cursor.poll()
    case res.kind
    of prSuccess:
      inc ctxPtr.readCount
    of prLagged:
      # Horizon jump on omDropOldest: immediately poll next available slot
      continue
    of prEmpty:
      benchBackoffOnPeerWait()
  # Drain remaining published slots
  drainCursor(ctxPtr.cursor, ctxPtr.readCount)

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
  result = float(totalRead) * 1_000_000.0 / elapsedNs

# -----------------------------------------------------------------------------
# 2. Rust FFI 1-to-N Fan-Out Harness (tokio::sync::broadcast & bus::Bus)
# -----------------------------------------------------------------------------
when defined(adapter_rust_ffi_available):
  type
    RustBcastKind = enum
      rbkTokio
      rbkBus

    RustSubCtx = object
      kind: RustBcastKind
      handle: pointer
      subIdx: int
      readCount: int
      doneFlag: ptr Atomic[bool]

  proc rustSubWorkerBody(ctxPtr: ptr RustSubCtx) {.thread.} =
    var outVal = 0'u64
    case ctxPtr.kind
    of rbkTokio:
      while not ctxPtr.doneFlag[].load(moAcquire):
        let code = tokio_bcast_try_recv(ctxPtr.handle, csize_t(ctxPtr.subIdx), addr outVal)
        if code == 1:
          inc ctxPtr.readCount
        elif code == -1:
          continue
        else:
          benchBackoffOnPeerWait()
      while true:
        let code = tokio_bcast_try_recv(ctxPtr.handle, csize_t(ctxPtr.subIdx), addr outVal)
        if code == 1:
          inc ctxPtr.readCount
        elif code == -1:
          continue
        else:
          break
    of rbkBus:
      while not ctxPtr.doneFlag[].load(moAcquire):
        if rust_bus_try_recv(ctxPtr.handle, csize_t(ctxPtr.subIdx), addr outVal):
          inc ctxPtr.readCount
        else:
          benchBackoffOnPeerWait()
      while rust_bus_try_recv(ctxPtr.handle, csize_t(ctxPtr.subIdx), addr outVal):
        inc ctxPtr.readCount

  proc runRustFanoutBenchmark(kind: RustBcastKind, numSubscribers: int, msgCount: int): float =
    let handle =
      case kind
      of rbkTokio: tokio_bcast_init(csize_t(RingCapacity), csize_t(numSubscribers))
      of rbkBus: rust_bus_init(csize_t(RingCapacity), csize_t(numSubscribers))
    defer:
      case kind
      of rbkTokio: tokio_bcast_destroy(handle)
      of rbkBus: rust_bus_destroy(handle)

    var done = Atomic[bool]()
    done.store(false, moRelaxed)

    var threads = newSeq[Thread[ptr RustSubCtx]](numSubscribers)
    var ctxs = newSeq[RustSubCtx](numSubscribers)
    for i in 0 ..< numSubscribers:
      ctxs[i] = RustSubCtx(
        kind: kind,
        handle: handle,
        subIdx: i,
        readCount: 0,
        doneFlag: addr done
      )

    let t0 = getMonoTime()
    for i in 0 ..< numSubscribers:
      createThread(threads[i], rustSubWorkerBody, addr ctxs[i])

    for i in 0 ..< msgCount:
      case kind
      of rbkTokio:
        discard tokio_bcast_send(handle, uint64(i))
      of rbkBus:
        while not rust_bus_try_broadcast(handle, uint64(i)):
          benchBackoffOnPeerWait()

    done.store(true, moRelease)
    for i in 0 ..< numSubscribers:
      joinThread(threads[i])
    let elapsedNs = float(inNanoseconds(getMonoTime() - t0))

    var totalRead = 0
    for i in 0 ..< numSubscribers:
      totalRead += ctxs[i].readCount

    if elapsedNs <= 0.0:
      return 0.0
    result = float(totalRead) * 1_000_000.0 / elapsedNs

# -----------------------------------------------------------------------------
# 3. TopicBus MP-to-MC Pub-Sub Harness (2p2c, 2p4c, 4p4c, 4p8c)
# -----------------------------------------------------------------------------
type
  TopicPubCtx = object
    busPtr: ptr TopicBus[int]
    tokioPtr: pointer
    useTokio: bool
    msgCount: int
    threadId: int

  TopicSubCtx = object
    cursor: BroadcastCursor[int]
    tokioPtr: pointer
    useTokio: bool
    subIdx: int
    readCount: int
    doneFlag: ptr Atomic[bool]

proc topicPubWorkerBody(ctxPtr: ptr TopicPubCtx) {.thread.} =
  let ctx = ctxPtr[]
  let topic = TopicNames[ctx.threadId mod TopicNames.len]
  if ctx.useTokio:
    when defined(adapter_rust_ffi_available):
      for i in 0 ..< ctx.msgCount:
        discard tokio_bcast_send(ctx.tokioPtr, uint64(i))
  else:
    for i in 0 ..< ctx.msgCount:
      ctx.busPtr[].publish(topic, i)

proc topicSubWorkerBody(ctxPtr: ptr TopicSubCtx) {.thread.} =
  if ctxPtr.useTokio:
    when defined(adapter_rust_ffi_available):
      var outVal = 0'u64
      while not ctxPtr.doneFlag[].load(moAcquire):
        let code = tokio_bcast_try_recv(ctxPtr.tokioPtr, csize_t(ctxPtr.subIdx), addr outVal)
        if code == 1:
          inc ctxPtr.readCount
        elif code == -1:
          continue
        else:
          benchBackoffOnPeerWait()
      while true:
        let code = tokio_bcast_try_recv(ctxPtr.tokioPtr, csize_t(ctxPtr.subIdx), addr outVal)
        if code == 1:
          inc ctxPtr.readCount
        elif code == -1:
          continue
        else:
          break
  else:
    while not ctxPtr.doneFlag[].load(moAcquire):
      let res = ctxPtr.cursor.poll()
      case res.kind
      of prSuccess:
        inc ctxPtr.readCount
      of prLagged:
        continue
      of prEmpty:
        benchBackoffOnPeerWait()
    drainCursor(ctxPtr.cursor, ctxPtr.readCount)

proc runTopicBusBenchmark(
    overflowMode: OverflowMode,
    useTokio: bool,
    numProducers: int,
    numConsumers: int,
    totalMsgs: int
): float =
  var bus: TopicBus[int]
  var tokioPtr: pointer = nil

  if useTokio:
    when defined(adapter_rust_ffi_available):
      tokioPtr = tokio_bcast_init(csize_t(RingCapacity), csize_t(numConsumers))
  else:
    bus = initTopicBus[int](TopicBusConfig(
      defaultRingCapacity: RingCapacity,
      defaultOverflowMode: overflowMode,
      defaultMaxReaders: 64
    ))

  defer:
    if useTokio:
      when defined(adapter_rust_ffi_available):
        tokio_bcast_destroy(tokioPtr)

  var done = Atomic[bool]()
  done.store(false, moRelaxed)

  var pubThreads = newSeq[Thread[ptr TopicPubCtx]](numProducers)
  var pubCtxs = newSeq[TopicPubCtx](numProducers)
  var subThreads = newSeq[Thread[ptr TopicSubCtx]](numConsumers)
  var subCtxs = newSeq[TopicSubCtx](numConsumers)

  let msgsPerProd = totalMsgs div numProducers
  for i in 0 ..< numProducers:
    pubCtxs[i] = TopicPubCtx(
      busPtr: addr bus,
      tokioPtr: tokioPtr,
      useTokio: useTokio,
      msgCount: msgsPerProd,
      threadId: i
    )

  for i in 0 ..< numConsumers:
    let topic = TopicNames[i mod TopicNames.len]
    subCtxs[i] = TopicSubCtx(
      cursor: (if useTokio: BroadcastCursor[int]() else: bus.subscribe(topic, soFromEarliest)),
      tokioPtr: tokioPtr,
      useTokio: useTokio,
      subIdx: i,
      readCount: 0,
      doneFlag: addr done
    )

  let t0 = getMonoTime()
  for i in 0 ..< numConsumers:
    createThread(subThreads[i], topicSubWorkerBody, addr subCtxs[i])
  for i in 0 ..< numProducers:
    createThread(pubThreads[i], topicPubWorkerBody, addr pubCtxs[i])

  for i in 0 ..< numProducers:
    joinThread(pubThreads[i])
  done.store(true, moRelease)
  for i in 0 ..< numConsumers:
    joinThread(subThreads[i])
  let elapsedNs = float(inNanoseconds(getMonoTime() - t0))

  if not useTokio:
    for i in 0 ..< numConsumers:
      subCtxs[i].cursor.unsubscribe()

  var totalRead = 0
  for i in 0 ..< numConsumers:
    totalRead += subCtxs[i].readCount

  if elapsedNs <= 0.0:
    return 0.0
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

  echo "BroadcastRing & TopicBus Fan-Out Benchmark (Nim vs Rust)"
  echo "========================================================"

  var emitter = initBMFEmitter()
  let subConfigs = [(1, "1p1c"), (2, "1p2c"), (4, "1p4c"), (8, "1p8c"), (16, "1p16c")]
  let modes = [
    (omDropOldest, "broadcast_ring_drop"),
    (omBackoff, "broadcast_ring_backoff")
  ]

  for (mode, libSlug) in modes:
    echo &"\n--- Mode: {libSlug} (fanout) ---"
    for (numSubs, shape) in subConfigs:
      for _ in 0 ..< BenchBroadcastWarmup:
        discard runBroadcastBenchmark(mode, numSubs, BenchBroadcastMsgCount)
      var samples = newSeq[float](BenchBroadcastRuns)
      for r in 0 ..< BenchBroadcastRuns:
        samples[r] = runBroadcastBenchmark(mode, numSubs, BenchBroadcastMsgCount)
      let m = mean(samples)
      let s = stddev(samples)
      let slug = &"{libSlug}/fanout/{shape}"
      emitter.addMeasure(slug, "throughput_ops_ms", m, m - s, m + s)
      echo &"{slug}: mean = {m:10.1f} ops/ms, stddev = {s:8.1f}"

  when defined(adapter_rust_ffi_available):
    for (rKind, libSlug) in [(rbkTokio, "tokio_broadcast"), (rbkBus, "rust_bus")]:
      echo &"\n--- Mode: {libSlug} (fanout) ---"
      for (numSubs, shape) in subConfigs:
        for _ in 0 ..< BenchBroadcastWarmup:
          discard runRustFanoutBenchmark(rKind, numSubs, BenchBroadcastMsgCount)
        var samples = newSeq[float](BenchBroadcastRuns)
        for r in 0 ..< BenchBroadcastRuns:
          samples[r] = runRustFanoutBenchmark(rKind, numSubs, BenchBroadcastMsgCount)
        let m = mean(samples)
        let s = stddev(samples)
        let slug = &"{libSlug}/fanout/{shape}"
        emitter.addMeasure(slug, "throughput_ops_ms", m, m - s, m + s)
        echo &"{slug}: mean = {m:10.1f} ops/ms, stddev = {s:8.1f}"

  # MP-to-MC TopicBus Fan-Out
  let topicShapes = [(2, 2, "2p2c"), (2, 4, "2p4c"), (4, 4, "4p4c"), (4, 8, "4p8c")]
  var topicTargets = @[
    (omDropOldest, false, "topic_bus_drop"),
    (omBackoff, false, "topic_bus_backoff")
  ]
  when defined(adapter_rust_ffi_available):
    topicTargets.add((omDropOldest, true, "tokio_broadcast"))

  for (mode, useTokio, libSlug) in topicTargets:
    echo &"\n--- Mode: {libSlug} (topic_bus) ---"
    for (np, nc, shape) in topicShapes:
      for _ in 0 ..< BenchBroadcastWarmup:
        discard runTopicBusBenchmark(mode, useTokio, np, nc, BenchBroadcastMsgCount)
      var samples = newSeq[float](BenchBroadcastRuns)
      for r in 0 ..< BenchBroadcastRuns:
        samples[r] = runTopicBusBenchmark(mode, useTokio, np, nc, BenchBroadcastMsgCount)
      let m = mean(samples)
      let s = stddev(samples)
      let slug = &"{libSlug}/topic_bus/{shape}"
      emitter.addMeasure(slug, "throughput_ops_ms", m, m - s, m + s)
      echo &"{slug}: mean = {m:10.1f} ops/ms, stddev = {s:8.1f}"

  if outputPath.len > 0:
    emitter.emit(outputPath)
    echo &"\nEmitted results to {outputPath}"

when isMainModule:
  main()
