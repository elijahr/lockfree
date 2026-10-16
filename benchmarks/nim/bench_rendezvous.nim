## Benchmarks for RendezvousChannel[T]: Synchronous 0-Buffer Handoff & Ping-Pong RPC.
##
## Evaluates:
##   1. Synchronous 0-buffer MPMC handoff throughput (`rendezvous_handoff`)
##      across 1p1c, 2p2c, 4p4c, 8p8c with strict bilateral message conservation
##      (sum(producers) == sum(consumers)).
##   2. Synchronous 1p1c ping-pong RPC round-trip throughput and latency
##      percentiles (`rendezvous_rpc`, p50/p95/p99/p999/max ns).
##
## Compares:
##   - `rendezvous_channel`: lockfree `RendezvousChannel[uint64]` (Scherer & Scott dual queue)
##   - `nim_channel_sync`: Nim stdlib `system.Channel[uint64]` with `maxItems = 1`
##   - Optional Rust FFI (`-d:adapter_rust_ffi_available` or `-d:adapter_rust_rendezvous_available`):
##     `crossbeam_rendezvous` (`crossbeam_channel::bounded(0)`),
##     `flume_rendezvous` (`flume::bounded(0)`),
##     `kanal_rendezvous` (`kanal::bounded(0)`).

import std/[monotimes, os, parseopt, strformat, times]
import ./bench_common
import lockfree/rendezvous
import lockfree/atomics

const
  BenchRendezvousRuns* {.intdefine.} = 3
  BenchRendezvousWarmup* {.intdefine.} = 1
  BenchRendezvousMsgCount* {.intdefine.} = 50_000
  BenchRendezvousRpcCount* {.intdefine.} = 20_000

when defined(adapter_rust_ffi_available) or defined(adapter_rust_rendezvous_available):
  import ./adapters/crossbeam_link
  proc cb_rendezvous_init(): pointer {.importc, cdecl.}
  proc cb_rendezvous_send(q: pointer, item: uint64): bool {.importc, cdecl.}
  proc cb_rendezvous_recv(q: pointer, outVal: ptr uint64): bool {.importc, cdecl.}
  proc cb_rendezvous_destroy(q: pointer) {.importc, cdecl.}

  proc flume_rendezvous_init(): pointer {.importc, cdecl.}
  proc flume_rendezvous_send(q: pointer, item: uint64): bool {.importc, cdecl.}
  proc flume_rendezvous_recv(q: pointer, outVal: ptr uint64): bool {.importc, cdecl.}
  proc flume_rendezvous_destroy(q: pointer) {.importc, cdecl.}

  proc kanal_rendezvous_init(): pointer {.importc, cdecl.}
  proc kanal_rendezvous_send(q: pointer, item: uint64): bool {.importc, cdecl.}
  proc kanal_rendezvous_recv(q: pointer, outVal: ptr uint64): bool {.importc, cdecl.}
  proc kanal_rendezvous_destroy(q: pointer) {.importc, cdecl.}

type
  RendezvousKind = enum
    rkLockfree
    rkNimChannelSync
    rkCrossbeam
    rkFlume
    rkKanal

  HandoffWorkerCtx = object
    kind: RendezvousKind
    lfChan: RendezvousChannel[uint64]
    nimChan: ptr system.Channel[uint64]
    ffiPtr: pointer
    isProducer: bool
    startIdx: int
    count: int
    checksum: uint64

proc handoffWorkerBody(ctx: ptr HandoffWorkerCtx) {.thread.} =
  if ctx.isProducer:
    for i in 0 ..< ctx.count:
      let payload = uint64(ctx.startIdx + i + 1)
      case ctx.kind
      of rkLockfree:
        discard ctx.lfChan.send(payload)
      of rkNimChannelSync:
        while not ctx.nimChan[].trySend(payload):
          benchBackoffOnPeerWait()
      else:
        when defined(adapter_rust_ffi_available) or defined(adapter_rust_rendezvous_available):
          case ctx.kind
          of rkCrossbeam:
            discard cb_rendezvous_send(ctx.ffiPtr, payload)
          of rkFlume:
            discard flume_rendezvous_send(ctx.ffiPtr, payload)
          of rkKanal:
            discard kanal_rendezvous_send(ctx.ffiPtr, payload)
          else:
            discard
  else:
    var localSum = 0'u64
    for _ in 0 ..< ctx.count:
      var val = 0'u64
      case ctx.kind
      of rkLockfree:
        discard ctx.lfChan.recv(val)
      of rkNimChannelSync:
        while true:
          let r = ctx.nimChan[].tryRecv()
          if r.dataAvailable:
            val = r.msg
            break
          benchBackoffOnPeerWait()
      else:
        when defined(adapter_rust_ffi_available) or defined(adapter_rust_rendezvous_available):
          case ctx.kind
          of rkCrossbeam:
            discard cb_rendezvous_recv(ctx.ffiPtr, addr val)
          of rkFlume:
            discard flume_rendezvous_recv(ctx.ffiPtr, addr val)
          of rkKanal:
            discard kanal_rendezvous_recv(ctx.ffiPtr, addr val)
          else:
            discard
      localSum = localSum xor val
    ctx.checksum = localSum

proc runOneHandoff(
    kind: RendezvousKind,
    numProducers: int,
    numConsumers: int,
    messageCount: int
): float =
  doAssert numProducers > 0 and numConsumers > 0 and messageCount > 0
  var lfChan: RendezvousChannel[uint64]
  var nimChan = cast[ptr system.Channel[uint64]](allocShared0(sizeof(system.Channel[uint64])))
  var ffiPtr: pointer = nil

  case kind
  of rkLockfree:
    lfChan = initRendezvousChannel[uint64]()
  of rkNimChannelSync:
    nimChan[].open(maxItems = 1)
  else:
    when defined(adapter_rust_ffi_available) or defined(adapter_rust_rendezvous_available):
      case kind
      of rkCrossbeam:
        ffiPtr = cb_rendezvous_init()
      of rkFlume:
        ffiPtr = flume_rendezvous_init()
      of rkKanal:
        ffiPtr = kanal_rendezvous_init()
      else:
        discard

  # Bilateral message conservation: sum(producer counts) == sum(consumer counts) == messageCount
  let baseP = messageCount div numProducers
  let remP = messageCount mod numProducers
  let baseC = messageCount div numConsumers
  let remC = messageCount mod numConsumers

  let totalThreads = numProducers + numConsumers
  var threads = newSeq[Thread[ptr HandoffWorkerCtx]](totalThreads)
  var ctxs = newSeq[HandoffWorkerCtx](totalThreads)

  var nextStart = 0
  var totalSent = 0
  for i in 0 ..< numProducers:
    let cnt = baseP + (if i < remP: 1 else: 0)
    ctxs[i] = HandoffWorkerCtx(
      kind: kind,
      lfChan: lfChan,
      nimChan: nimChan,
      ffiPtr: ffiPtr,
      isProducer: true,
      startIdx: nextStart,
      count: cnt,
      checksum: 0
    )
    nextStart += cnt
    totalSent += cnt

  var totalRecv = 0
  for i in 0 ..< numConsumers:
    let cnt = baseC + (if i < remC: 1 else: 0)
    let idx = numProducers + i
    ctxs[idx] = HandoffWorkerCtx(
      kind: kind,
      lfChan: lfChan,
      nimChan: nimChan,
      ffiPtr: ffiPtr,
      isProducer: false,
      startIdx: 0,
      count: cnt,
      checksum: 0
    )
    totalRecv += cnt

  doAssert totalSent == messageCount and totalRecv == messageCount,
    "Bilateral message conservation invariant violated"

  let t0 = getMonoTime()
  for i in 0 ..< totalThreads:
    createThread(threads[i], handoffWorkerBody, addr ctxs[i])
  for i in 0 ..< totalThreads:
    joinThread(threads[i])
  let elapsedNs = float(inNanoseconds(getMonoTime() - t0))

  case kind
  of rkLockfree:
    lfChan.close()
  of rkNimChannelSync:
    nimChan[].close()
  else:
    when defined(adapter_rust_ffi_available) or defined(adapter_rust_rendezvous_available):
      case kind
      of rkCrossbeam:
        cb_rendezvous_destroy(ffiPtr)
      of rkFlume:
        flume_rendezvous_destroy(ffiPtr)
      of rkKanal:
        kanal_rendezvous_destroy(ffiPtr)
      else:
        discard
  deallocShared(nimChan)

  if elapsedNs <= 0.0:
    return 0.0
  result = float(messageCount) * 1_000_000.0 / elapsedNs

# -----------------------------------------------------------------------------
# Ping-Pong RPC Round-Trip Harness (1p1c)
# -----------------------------------------------------------------------------
type
  RpcWorkerCtx = object
    kind: RendezvousKind
    reqLf: RendezvousChannel[uint64]
    repLf: RendezvousChannel[uint64]
    reqNim: ptr system.Channel[uint64]
    repNim: ptr system.Channel[uint64]
    reqFfi: pointer
    repFfi: pointer
    isClient: bool
    count: int
    hist: ptr Histogram
    checksum: uint64

proc rpcWorkerBody(ctx: ptr RpcWorkerCtx) {.thread.} =
  if ctx.isClient:
    var acc = 0'u64
    for i in 0 ..< ctx.count:
      let t0 = getMonoTime()
      let token = uint64(i + 1)
      var reply = 0'u64
      case ctx.kind
      of rkLockfree:
        discard ctx.reqLf.send(token)
        discard ctx.repLf.recv(reply)
      of rkNimChannelSync:
        ctx.reqNim[].send(token)
        reply = ctx.repNim[].recv()
      else:
        when defined(adapter_rust_ffi_available) or defined(adapter_rust_rendezvous_available):
          case ctx.kind
          of rkCrossbeam:
            discard cb_rendezvous_send(ctx.reqFfi, token)
            discard cb_rendezvous_recv(ctx.repFfi, addr reply)
          of rkFlume:
            discard flume_rendezvous_send(ctx.reqFfi, token)
            discard flume_rendezvous_recv(ctx.repFfi, addr reply)
          of rkKanal:
            discard kanal_rendezvous_send(ctx.reqFfi, token)
            discard kanal_rendezvous_recv(ctx.repFfi, addr reply)
          else:
            discard
      let t1 = getMonoTime()
      doAssert reply == token + 1
      acc = acc + reply
      let rttNs = float(inNanoseconds(t1 - t0))
      if rttNs > 0.0 and ctx.hist != nil:
        ctx.hist[].record(rttNs)
    ctx.checksum = acc
  else:
    for _ in 0 ..< ctx.count:
      var req = 0'u64
      case ctx.kind
      of rkLockfree:
        discard ctx.reqLf.recv(req)
        discard ctx.repLf.send(req + 1)
      of rkNimChannelSync:
        req = ctx.reqNim[].recv()
        ctx.repNim[].send(req + 1)
      else:
        when defined(adapter_rust_ffi_available) or defined(adapter_rust_rendezvous_available):
          case ctx.kind
          of rkCrossbeam:
            discard cb_rendezvous_recv(ctx.reqFfi, addr req)
            discard cb_rendezvous_send(ctx.repFfi, req + 1)
          of rkFlume:
            discard flume_rendezvous_recv(ctx.reqFfi, addr req)
            discard flume_rendezvous_send(ctx.repFfi, req + 1)
          of rkKanal:
            discard kanal_rendezvous_recv(ctx.reqFfi, addr req)
            discard kanal_rendezvous_send(ctx.repFfi, req + 1)
          else:
            discard

proc runOneRpc(kind: RendezvousKind, count: int): (float, LatencyMetrics) =
  var reqLf, repLf: RendezvousChannel[uint64]
  var reqNim = cast[ptr system.Channel[uint64]](allocShared0(sizeof(system.Channel[uint64])))
  var repNim = cast[ptr system.Channel[uint64]](allocShared0(sizeof(system.Channel[uint64])))
  var reqFfi: pointer = nil
  var repFfi: pointer = nil

  case kind
  of rkLockfree:
    reqLf = initRendezvousChannel[uint64]()
    repLf = initRendezvousChannel[uint64]()
  of rkNimChannelSync:
    reqNim[].open(maxItems = 1)
    repNim[].open(maxItems = 1)
  else:
    when defined(adapter_rust_ffi_available) or defined(adapter_rust_rendezvous_available):
      case kind
      of rkCrossbeam:
        reqFfi = cb_rendezvous_init()
        repFfi = cb_rendezvous_init()
      of rkFlume:
        reqFfi = flume_rendezvous_init()
        repFfi = flume_rendezvous_init()
      of rkKanal:
        reqFfi = kanal_rendezvous_init()
        repFfi = kanal_rendezvous_init()
      else:
        discard

  var hist = initHistogram()
  var clientCtx = RpcWorkerCtx(
    kind: kind,
    reqLf: reqLf, repLf: repLf,
    reqNim: reqNim, repNim: repNim,
    reqFfi: reqFfi, repFfi: repFfi,
    isClient: true,
    count: count,
    hist: addr hist,
    checksum: 0'u64
  )
  var serverCtx = RpcWorkerCtx(
    kind: kind,
    reqLf: reqLf, repLf: repLf,
    reqNim: reqNim, repNim: repNim,
    reqFfi: reqFfi, repFfi: repFfi,
    isClient: false,
    count: count,
    hist: nil,
    checksum: 0'u64
  )

  var clientThread, serverThread: Thread[ptr RpcWorkerCtx]
  let t0 = getMonoTime()
  createThread(serverThread, rpcWorkerBody, addr serverCtx)
  createThread(clientThread, rpcWorkerBody, addr clientCtx)
  joinThread(clientThread)
  joinThread(serverThread)
  let elapsedNs = float(inNanoseconds(getMonoTime() - t0))
  doAssert clientCtx.checksum > 0'u64

  case kind
  of rkLockfree:
    reqLf.close()
    repLf.close()
  of rkNimChannelSync:
    reqNim[].close()
    repNim[].close()
  else:
    when defined(adapter_rust_ffi_available) or defined(adapter_rust_rendezvous_available):
      case kind
      of rkCrossbeam:
        cb_rendezvous_destroy(reqFfi)
        cb_rendezvous_destroy(repFfi)
      of rkFlume:
        flume_rendezvous_destroy(reqFfi)
        flume_rendezvous_destroy(repFfi)
      of rkKanal:
        kanal_rendezvous_destroy(reqFfi)
        kanal_rendezvous_destroy(repFfi)
      else:
        discard
  deallocShared(reqNim)
  deallocShared(repNim)

  let opsMs = if elapsedNs > 0.0: float(count) * 1_000_000.0 / elapsedNs else: 0.0
  let pcts = hist.percentiles([0.50, 0.95, 0.99, 0.999, 1.0])
  let lat = LatencyMetrics(
    p50_ns: pcts[0],
    p95_ns: pcts[1],
    p99_ns: pcts[2],
    p999_ns: pcts[3],
    max_ns: pcts[4],
    samples: hist.seenAll
  )
  result = (opsMs, lat)

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

  var targets = @[
    (rkLockfree, "rendezvous_channel"),
    (rkNimChannelSync, "nim_channel_sync")
  ]
  when defined(adapter_rust_ffi_available) or defined(adapter_rust_rendezvous_available):
    targets.add((rkCrossbeam, "crossbeam_rendezvous"))
    targets.add((rkFlume, "flume_rendezvous"))
    targets.add((rkKanal, "kanal_rendezvous"))

  if filters.len > 0:
    var supported: seq[string] = @[]
    for (_, slug) in targets: supported.add(slug)
    for f in filters:
      if f notin supported:
        echo &"Unknown target: {f} (supported: {supported})"
        quit 1

  echo "RendezvousChannel Synchronous 0-Buffer Handoff & RPC Benchmark"
  echo "=============================================================="

  var emitter = initBMFEmitter()
  let shapes = [(1, 1, "1p1c"), (2, 2, "2p2c"), (4, 4, "4p4c"), (8, 8, "8p8c")]

  echo "\n--- 1. Synchronous 0-Buffer Handoff Throughput (rendezvous_handoff) ---"
  for (kind, libSlug) in targets:
    if not matchesFilter(libSlug, filters): continue
    for (np, nc, shape) in shapes:
      for _ in 0 ..< BenchRendezvousWarmup:
        discard runOneHandoff(kind, np, nc, BenchRendezvousMsgCount)
      var samples = newSeq[float](BenchRendezvousRuns)
      for r in 0 ..< BenchRendezvousRuns:
        samples[r] = runOneHandoff(kind, np, nc, BenchRendezvousMsgCount)
      let m = mean(samples)
      let s = stddev(samples)
      let slug = &"{libSlug}/rendezvous_handoff/{shape}"
      emitter.addMeasure(slug, "throughput_ops_ms", m, m - s, m + s)
      echo &"{slug}: mean = {m:10.1f} ops/ms, stddev = {s:8.1f}"

  echo "\n--- 2. Synchronous Ping-Pong RPC Round-Trip (rendezvous_rpc/1p1c) ---"
  for (kind, libSlug) in targets:
    if not matchesFilter(libSlug, filters): continue
    for _ in 0 ..< BenchRendezvousWarmup:
      discard runOneRpc(kind, BenchRendezvousRpcCount)
    var opsSamples = newSeq[float](BenchRendezvousRuns)
    var p50s, p95s, p99s, p999s, maxs = newSeq[float](BenchRendezvousRuns)
    for r in 0 ..< BenchRendezvousRuns:
      let (ops, lat) = runOneRpc(kind, BenchRendezvousRpcCount)
      opsSamples[r] = ops
      p50s[r] = lat.p50_ns
      p95s[r] = lat.p95_ns
      p99s[r] = lat.p99_ns
      p999s[r] = lat.p999_ns
      maxs[r] = lat.max_ns
    let m = mean(opsSamples)
    let s = stddev(opsSamples)
    let p50 = mean(p50s)
    let p95 = mean(p95s)
    let p99 = mean(p99s)
    let p999 = mean(p999s)
    let pmax = mean(maxs)

    let rpcSlug = &"{libSlug}/rendezvous_rpc/1p1c"
    emitter.addMeasure(rpcSlug, "throughput_ops_ms", m, m - s, m + s)
    emitter.addMeasure(rpcSlug, "latency_p50_ns", p50)
    emitter.addMeasure(rpcSlug, "latency_p95_ns", p95)
    emitter.addMeasure(rpcSlug, "latency_p99_ns", p99)
    emitter.addMeasure(rpcSlug, "latency_p999_ns", p999)
    emitter.addMeasure(rpcSlug, "latency_max_ns", pmax)

    # Also attach the 5 latency percentile keys to the 1p1c handoff slug so
    # collectLatencySeries in bench-charts.js finds all 5 keys on the first slug.
    let handoff1p1cSlug = &"{libSlug}/rendezvous_handoff/1p1c"
    emitter.addMeasure(handoff1p1cSlug, "latency_p50_ns", p50)
    emitter.addMeasure(handoff1p1cSlug, "latency_p95_ns", p95)
    emitter.addMeasure(handoff1p1cSlug, "latency_p99_ns", p99)
    emitter.addMeasure(handoff1p1cSlug, "latency_p999_ns", p999)
    emitter.addMeasure(handoff1p1cSlug, "latency_max_ns", pmax)

    echo &"{rpcSlug}: mean = {m:10.1f} ops/ms | RTT p50 = {p50:6.0f} ns, p99 = {p99:6.0f} ns, p999 = {p999:7.0f} ns"

  if outputPath.len > 0:
    emitter.emit(outputPath)
    echo &"\nEmitted results to {outputPath}"

when isMainModule:
  main()
