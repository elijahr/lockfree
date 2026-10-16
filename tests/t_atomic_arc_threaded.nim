## ==============================================================================
## Multithreaded Concurrency & TSan Stress Tests for AtomicArc[T] & ArcGuard[T]
## ==============================================================================

import unittest2
import lockfree/atomic_arc
import lockfree/atomics
import lockfree/atomics/backoff

type
  SharedPayload = object
    epoch: int
    magic: uint64
    checksum: uint64
    liveCounter: ptr Atomic[int]
    destroyCounter: ptr Atomic[int]

const PayloadMagic = 0xCAFE_BABE_DEAD_BEEF'u64

proc `=destroy`(p: var SharedPayload) =
  if p.destroyCounter != nil:
    doAssert p.magic == PayloadMagic, "Use-after-free or corrupted magic in SharedPayload destructor"
    p.magic = 0'u64
    discard p.liveCounter[].fetchSub(1, moSequentiallyConsistent)
    discard p.destroyCounter[].fetchAdd(1, moSequentiallyConsistent)
    p.destroyCounter = nil
    p.liveCounter = nil

proc `=copy`(dest: var SharedPayload, src: SharedPayload) =
  if dest.destroyCounter != src.destroyCounter or dest.epoch != src.epoch:
    `=destroy`(dest)
  dest.epoch = src.epoch
  dest.magic = src.magic
  dest.checksum = src.checksum
  dest.liveCounter = nil
  dest.destroyCounter = nil

proc `=sink`(dest: var SharedPayload, src: SharedPayload) =
  `=destroy`(dest)
  dest.epoch = src.epoch
  dest.magic = src.magic
  dest.checksum = src.checksum
  dest.liveCounter = src.liveCounter
  dest.destroyCounter = src.destroyCounter

proc newSharedPayload(
    epoch: int,
    liveCounter: ptr Atomic[int],
    destroyCounter: ptr Atomic[int]
): SharedPayload =
  discard liveCounter[].fetchAdd(1, moSequentiallyConsistent)
  result.epoch = epoch
  result.magic = PayloadMagic
  result.checksum = uint64(epoch) * 0x9E3779B97F4A7C15'u64
  result.liveCounter = liveCounter
  result.destroyCounter = destroyCounter

type
  ReaderWriterCtx = object
    arc: ptr AtomicArc[SharedPayload]
    stopFlag: ptr Atomic[bool]
    liveCounter: ptr Atomic[int]
    destroyCounter: ptr Atomic[int]
    totalCreated: ptr Atomic[int]
    readerLoads: ptr Atomic[int]
    casSuccesses: ptr Atomic[int]
    workerId: int
    iterations: int

proc readerThreadProc(ctx: ptr ReaderWriterCtx) {.thread.} =
  var localLoads = 0
  while not ctx.stopFlag[].load(moAcquire):
    let g = ctx.arc[].load()
    if not g.isNil:
      let p = g.rawPtr
      doAssert p != nil
      doAssert p.magic == PayloadMagic, "Reader observed corrupted magic (premature reclamation!)"
      doAssert p.checksum == uint64(p.epoch) * 0x9E3779B97F4A7C15'u64
      # Clone and drop to exercise concurrent internalCount fetchAdd/fetchSub
      let g2 = g.clone()
      doAssert g2.get().epoch == p.epoch
      inc localLoads
  discard ctx.readerLoads[].fetchAdd(localLoads, moRelaxed)

proc storeWriterThreadProc(ctx: ptr ReaderWriterCtx) {.thread.} =
  let base = ctx.workerId * 1_000_000
  for i in 1 .. ctx.iterations:
    let ep = base + i
    discard ctx.totalCreated[].fetchAdd(1, moRelaxed)
    if (i and 3) == 0:
      let prev = ctx.arc[].swap(
        newSharedPayload(ep, ctx.liveCounter, ctx.destroyCounter)
      )
      if not prev.isNil:
        doAssert prev.get().magic == PayloadMagic
    else:
      ctx.arc[].store(
        newSharedPayload(ep, ctx.liveCounter, ctx.destroyCounter)
      )

proc casWriterThreadProc(ctx: ptr ReaderWriterCtx) {.thread.} =
  let base = ctx.workerId * 1_000_000
  var cur = ctx.arc[].load()
  for i in 1 .. ctx.iterations:
    let ep = base + i
    discard ctx.totalCreated[].fetchAdd(1, moRelaxed)
    let desired = initArcGuard[SharedPayload](
      newSharedPayload(ep, ctx.liveCounter, ctx.destroyCounter)
    )
    while not ctx.arc[].compareExchange(cur, desired):
      if not cur.isNil:
        doAssert cur.get().magic == PayloadMagic
      cpuPause()
    discard ctx.casSuccesses[].fetchAdd(1, moRelaxed)
    cur = desired

suite "AtomicArc[T] Multithreaded Concurrency & Zero-Leak Stress":

  test "8-Reader / 4-Writer high-contention load + store + swap (zero premature reclamation)":
    const
      NumReaders = 8
      NumWriters = 4
      WritesPerWriter = 1_500

    var liveCount: Atomic[int]
    var destroyCount: Atomic[int]
    var totalCreated: Atomic[int]
    var readerLoads: Atomic[int]
    var casSuccesses: Atomic[int]
    var stopFlag: Atomic[bool]

    liveCount.store(0, moRelaxed)
    destroyCount.store(0, moRelaxed)
    totalCreated.store(1, moRelaxed)
    readerLoads.store(0, moRelaxed)
    casSuccesses.store(0, moRelaxed)
    stopFlag.store(false, moRelaxed)

    var arc = initAtomicArc[SharedPayload](
      newSharedPayload(1, addr liveCount, addr destroyCount)
    )

    var readers: array[NumReaders, Thread[ptr ReaderWriterCtx]]
    var writers: array[NumWriters, Thread[ptr ReaderWriterCtx]]
    var rCtxs: array[NumReaders, ReaderWriterCtx]
    var wCtxs: array[NumWriters, ReaderWriterCtx]

    for i in 0 ..< NumReaders:
      rCtxs[i] = ReaderWriterCtx(
        arc: addr arc,
        stopFlag: addr stopFlag,
        liveCounter: addr liveCount,
        destroyCounter: addr destroyCount,
        totalCreated: addr totalCreated,
        readerLoads: addr readerLoads,
        casSuccesses: addr casSuccesses,
        workerId: i + 1,
        iterations: 0
      )
      createThread(readers[i], readerThreadProc, addr rCtxs[i])

    for i in 0 ..< NumWriters:
      wCtxs[i] = ReaderWriterCtx(
        arc: addr arc,
        stopFlag: addr stopFlag,
        liveCounter: addr liveCount,
        destroyCounter: addr destroyCount,
        totalCreated: addr totalCreated,
        readerLoads: addr readerLoads,
        casSuccesses: addr casSuccesses,
        workerId: i + 10,
        iterations: WritesPerWriter
      )
      createThread(writers[i], storeWriterThreadProc, addr wCtxs[i])

    for i in 0 ..< NumWriters:
      joinThread(writers[i])

    stopFlag.store(true, moRelease)
    for i in 0 ..< NumReaders:
      joinThread(readers[i])

    # Clear the final slot and verify 100% deterministic reclamation
    arc.storeNil()
    check liveCount.load(moSequentiallyConsistent) == 0
    check destroyCount.load(moSequentiallyConsistent) == totalCreated.load(moSequentiallyConsistent)
    check readerLoads.load(moRelaxed) > 0

  test "4-Reader / 4-CAS-Updater compareExchange contention under heavy load churn":
    const
      NumReaders = 4
      NumUpdaters = 4
      UpdatesPerThread = 500

    var liveCount: Atomic[int]
    var destroyCount: Atomic[int]
    var totalCreated: Atomic[int]
    var readerLoads: Atomic[int]
    var casSuccesses: Atomic[int]
    var stopFlag: Atomic[bool]

    liveCount.store(0, moRelaxed)
    destroyCount.store(0, moRelaxed)
    totalCreated.store(1, moRelaxed)
    readerLoads.store(0, moRelaxed)
    casSuccesses.store(0, moRelaxed)
    stopFlag.store(false, moRelaxed)

    var arc = initAtomicArc[SharedPayload](
      newSharedPayload(1, addr liveCount, addr destroyCount)
    )

    var readers: array[NumReaders, Thread[ptr ReaderWriterCtx]]
    var updaters: array[NumUpdaters, Thread[ptr ReaderWriterCtx]]
    var rCtxs: array[NumReaders, ReaderWriterCtx]
    var uCtxs: array[NumUpdaters, ReaderWriterCtx]

    for i in 0 ..< NumReaders:
      rCtxs[i] = ReaderWriterCtx(
        arc: addr arc,
        stopFlag: addr stopFlag,
        liveCounter: addr liveCount,
        destroyCounter: addr destroyCount,
        totalCreated: addr totalCreated,
        readerLoads: addr readerLoads,
        casSuccesses: addr casSuccesses,
        workerId: i + 1,
        iterations: 0
      )
      createThread(readers[i], readerThreadProc, addr rCtxs[i])

    for i in 0 ..< NumUpdaters:
      uCtxs[i] = ReaderWriterCtx(
        arc: addr arc,
        stopFlag: addr stopFlag,
        liveCounter: addr liveCount,
        destroyCounter: addr destroyCount,
        totalCreated: addr totalCreated,
        readerLoads: addr readerLoads,
        casSuccesses: addr casSuccesses,
        workerId: i + 100,
        iterations: UpdatesPerThread
      )
      createThread(updaters[i], casWriterThreadProc, addr uCtxs[i])

    for i in 0 ..< NumUpdaters:
      joinThread(updaters[i])

    stopFlag.store(true, moRelease)
    for i in 0 ..< NumReaders:
      joinThread(readers[i])

    check casSuccesses.load(moSequentiallyConsistent) == NumUpdaters * UpdatesPerThread
    arc.storeNil()
    check liveCount.load(moSequentiallyConsistent) == 0
    check destroyCount.load(moSequentiallyConsistent) == totalCreated.load(moSequentiallyConsistent)
