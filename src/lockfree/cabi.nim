## ==============================================================================
## C ABI / FFI Interop Layer for lockfree
## ==============================================================================
##
## Canonical C99 interface implementation declared in `include/lockfree.h`.
## Wraps bounded (BQueue) and unbounded (Queue) lock-free MPMC queues with:
## - Opaque handles (`lfq_queue_t*`, `lfq_producer_t*`, `lfq_consumer_t*`)
## - Zero-copy 64-bit raw pointer payload transport (`void*` <-> `pointer`)
## - Dynamic thread registration and thread-local slot recycling
## - Optional item cleanup callbacks on queue destroy
## - Strict `cAbiBoundary` exception firewall preventing any Nim exception/panic
##   from escaping across the FFI boundary
## ==============================================================================

import lockfree/atomics
import lockfree/bqueue
import lockfree/queue
import lockfree/strategy
import lockfree/endpoint
import lockfree/exceptions
from lockfree/smr/nebr import registerThread, unregisterThread, ThreadHandle, DebraRegistrationError, reclaimNow
import lockfree/smr/nebr/signal
import std/options

# ------------------------------------------------------------------------------
# Status Codes & Callback Types
# ------------------------------------------------------------------------------

type
  lfq_status_t* {.size: sizeof(cint).} = enum
    LFQ_ERR_PANIC         = -2
    LFQ_ERR_FAILURE       = -1
    LFQ_OK                =  0
    LFQ_ERR_EMPTY         =  1
    LFQ_ERR_FULL          =  2
    LFQ_ERR_CLOSED        =  3
    LFQ_ERR_INVALID_ARG   =  4
    LFQ_ERR_REGISTRY_FULL =  5
    LFQ_ERR_UNSUPPORTED   =  6

  lfq_item_destructor_fn* = proc(item: pointer, userData: pointer) {.cdecl, gcsafe.}

# ------------------------------------------------------------------------------
# Exception Firewall Template
# ------------------------------------------------------------------------------

template cAbiBoundary(body: untyped): lfq_status_t =
  try:
    body
  except NoProducersAvailableError, NoConsumersAvailableError:
    LFQ_ERR_REGISTRY_FULL
  except Defect:
    LFQ_ERR_PANIC
  except CatchableError:
    LFQ_ERR_FAILURE

type
  ThreadRegistrationCount = object
    mgr: pointer
    count: int
    handleIdx: int

var tlsThreadRegistrations {.threadvar.}: seq[ThreadRegistrationCount]

# ------------------------------------------------------------------------------
# Opaque Base Handle Layouts
# ------------------------------------------------------------------------------

type
  lfq_queue* {.exportc: "lfq_queue_t".} = object
    destructor*: lfq_item_destructor_fn
    userData*: pointer
    maxProducers*: int
    maxConsumers*: int
    activeProducers*: Atomic[int]
    activeConsumers*: Atomic[int]
    isClosed*: Atomic[bool]
    destroyFn*: proc(q: ptr lfq_queue_t): lfq_status_t {.nimcall, gcsafe, raises: [].}
    producerAcquireFn*: proc(q: ptr lfq_queue_t, outProd: ptr ptr lfq_producer_t): lfq_status_t {.nimcall, gcsafe, raises: [].}
    consumerAcquireFn*: proc(q: ptr lfq_queue_t, outCons: ptr ptr lfq_consumer_t): lfq_status_t {.nimcall, gcsafe, raises: [].}
    lenFn*: proc(q: ptr lfq_queue_t): csize_t {.nimcall, gcsafe, raises: [].}
    isEmptyFn*: proc(q: ptr lfq_queue_t): bool {.nimcall, gcsafe, raises: [].}

  lfq_queue_t* = lfq_queue

  lfq_producer* {.exportc: "lfq_producer_t".} = object
    queue*: ptr lfq_queue_t
    pushFn*: proc(prod: ptr lfq_producer_t, item: pointer): lfq_status_t {.nimcall, gcsafe, raises: [].}
    releaseFn*: proc(prod: ptr lfq_producer_t): lfq_status_t {.nimcall, gcsafe, raises: [].}
    handleManager*: pointer
    handleIdx*: int

  lfq_producer_t* = lfq_producer

  lfq_consumer* {.exportc: "lfq_consumer_t".} = object
    queue*: ptr lfq_queue_t
    popFn*: proc(cons: ptr lfq_consumer_t, outItem: ptr pointer): lfq_status_t {.nimcall, gcsafe, raises: [].}
    popBatchFn*: proc(cons: ptr lfq_consumer_t, outItems: ptr pointer, maxCount: csize_t): csize_t {.nimcall, gcsafe, raises: [].}
    releaseFn*: proc(cons: ptr lfq_consumer_t): lfq_status_t {.nimcall, gcsafe, raises: [].}
    handleManager*: pointer
    handleIdx*: int

  lfq_consumer_t* = lfq_consumer

# ------------------------------------------------------------------------------
# Bounded MPMC Implementation (Vyukov BQueue)
# ------------------------------------------------------------------------------

type
  BoundedQueueImpl[N, P, C: static int] = object
    base: lfq_queue_t
    rawQueue: ptr BQueue[pointer, ccMulti, ccMulti, N, P, C]

  BoundedProducerImpl[N, P, C: static int] = object
    base: lfq_producer_t
    bound: Bound[pointer, AnyThreadTag, BQueue[pointer, ccMulti, ccMulti, N, P, C]]

  BoundedConsumerImpl[N, P, C: static int] = object
    base: lfq_consumer_t
    bound: Bound[pointer, AnyThreadTag, BQueue[pointer, ccMulti, ccMulti, N, P, C]]

proc boundedPush[N, P, C: static int](prod: ptr lfq_producer_t, item: pointer): lfq_status_t {.nimcall, gcsafe, raises: [].} =
  let p = cast[ptr BoundedProducerImpl[N, P, C]](prod)
  cAbiBoundary:
    let ok = p.bound.push(item)
    if ok:
      LFQ_OK
    else:
      LFQ_ERR_FULL

proc boundedPop[N, P, C: static int](cons: ptr lfq_consumer_t, outItem: ptr pointer): lfq_status_t {.nimcall, gcsafe, raises: [].} =
  let c = cast[ptr BoundedConsumerImpl[N, P, C]](cons)
  cAbiBoundary:
    let opt = c.bound.pop()
    if opt.isSome:
      outItem[] = opt.get
      LFQ_OK
    else:
      LFQ_ERR_EMPTY

proc boundedPopBatch[N, P, C: static int](
    cons: ptr lfq_consumer_t, outItems: ptr pointer, maxCount: csize_t
): csize_t {.nimcall, gcsafe, raises: [].} =
  if unlikely(cons == nil or outItems == nil or maxCount == 0):
    return 0
  let c = cast[ptr BoundedConsumerImpl[N, P, C]](cons)
  let arr = cast[ptr UncheckedArray[pointer]](outItems)
  try:
    let n = c.bound.popBatch(toOpenArray(arr, 0, int(maxCount) - 1), int(maxCount))
    return csize_t(n)
  except:
    return 0

proc boundedProducerRelease[N, P, C: static int](prod: ptr lfq_producer_t): lfq_status_t {.nimcall, gcsafe, raises: [].} =
  let p = cast[ptr BoundedProducerImpl[N, P, C]](prod)
  let q = cast[ptr BoundedQueueImpl[N, P, C]](p.base.queue)
  cAbiBoundary:
    let idx = p.bound.idx
    discard close(p.bound)
    if idx >= 0 and idx < P:
      q.rawQueue.producerThreadIds[idx].store(0, moRelease)
    discard q.base.activeProducers.fetchSub(1, moRelaxed)
    deallocShared(p)
    LFQ_OK

proc boundedConsumerRelease[N, P, C: static int](cons: ptr lfq_consumer_t): lfq_status_t {.nimcall, gcsafe, raises: [].} =
  let c = cast[ptr BoundedConsumerImpl[N, P, C]](cons)
  let q = cast[ptr BoundedQueueImpl[N, P, C]](c.base.queue)
  cAbiBoundary:
    let idx = c.bound.idx
    discard close(c.bound)
    if idx >= 0 and idx < C:
      q.rawQueue.consumerThreadIds[idx].store(0, moRelease)
    discard q.base.activeConsumers.fetchSub(1, moRelaxed)
    deallocShared(c)
    LFQ_OK

proc boundedProducerAcquire[N, P, C: static int](
    qBase: ptr lfq_queue_t, outProd: ptr ptr lfq_producer_t
): lfq_status_t {.nimcall, gcsafe, raises: [].} =
  let q = cast[ptr BoundedQueueImpl[N, P, C]](qBase)
  if q.base.maxProducers > 0 and q.base.activeProducers.load(moRelaxed) >= q.base.maxProducers:
    return LFQ_ERR_REGISTRY_FULL
  cAbiBoundary:
    var u = q.rawQueue[].getProducer()
    var b = u.bindToThread()
    let p = cast[ptr BoundedProducerImpl[N, P, C]](allocShared0(sizeof(BoundedProducerImpl[N, P, C])))
    p.base.queue = qBase
    p.base.pushFn = boundedPush[N, P, C]
    p.base.releaseFn = boundedProducerRelease[N, P, C]
    p.base.handleManager = nil
    p.base.handleIdx = b.idx
    p.bound = b
    discard q.base.activeProducers.fetchAdd(1, moRelaxed)
    outProd[] = cast[ptr lfq_producer_t](p)
    LFQ_OK

proc boundedConsumerAcquire[N, P, C: static int](
    qBase: ptr lfq_queue_t, outCons: ptr ptr lfq_consumer_t
): lfq_status_t {.nimcall, gcsafe, raises: [].} =
  let q = cast[ptr BoundedQueueImpl[N, P, C]](qBase)
  if q.base.maxConsumers > 0 and q.base.activeConsumers.load(moRelaxed) >= q.base.maxConsumers:
    return LFQ_ERR_REGISTRY_FULL
  cAbiBoundary:
    var u = q.rawQueue[].getConsumer()
    var b = u.bindToThread()
    let c = cast[ptr BoundedConsumerImpl[N, P, C]](allocShared0(sizeof(BoundedConsumerImpl[N, P, C])))
    c.base.queue = qBase
    c.base.popFn = boundedPop[N, P, C]
    c.base.popBatchFn = boundedPopBatch[N, P, C]
    c.base.releaseFn = boundedConsumerRelease[N, P, C]
    c.base.handleManager = nil
    c.base.handleIdx = b.idx
    c.bound = b
    discard q.base.activeConsumers.fetchAdd(1, moRelaxed)
    outCons[] = cast[ptr lfq_consumer_t](c)
    LFQ_OK

proc boundedQueueLen[N, P, C: static int](qBase: ptr lfq_queue_t): csize_t {.nimcall, gcsafe, raises: [].} =
  let q = cast[ptr BoundedQueueImpl[N, P, C]](qBase)
  try:
    let t = q.rawQueue.tail.load(moRelaxed)
    let h = q.rawQueue.head.load(moRelaxed)
    if t > h:
      let diff = t - h
      if diff > uint64(N): csize_t(N) else: csize_t(diff)
    else:
      0
  except:
    0

proc boundedQueueIsEmpty[N, P, C: static int](qBase: ptr lfq_queue_t): bool {.nimcall, gcsafe, raises: [].} =
  let q = cast[ptr BoundedQueueImpl[N, P, C]](qBase)
  try:
    let t = q.rawQueue.tail.load(moRelaxed)
    let h = q.rawQueue.head.load(moRelaxed)
    t <= h
  except:
    true

proc boundedQueueDestroy[N, P, C: static int](qBase: ptr lfq_queue_t): lfq_status_t {.nimcall, gcsafe, raises: [].} =
  if qBase.activeProducers.load(moAcquire) > 0 or qBase.activeConsumers.load(moAcquire) > 0:
    return LFQ_ERR_FAILURE
  let q = cast[ptr BoundedQueueImpl[N, P, C]](qBase)
  cAbiBoundary:
    if q.base.destructor != nil:
      try:
        var u = q.rawQueue[].getConsumer()
        var b = u.bindToThread()
        while true:
          let opt = b.pop()
          if opt.isSome:
            q.base.destructor(opt.get, q.base.userData)
          else:
            break
        discard close(b)
      except:
        discard
    `=destroy`(q.rawQueue[])
    deallocShared(q.rawQueue)
    deallocShared(q)
    LFQ_OK

proc createBoundedInstance[N, P, C: static int](
    destructor: lfq_item_destructor_fn,
    userData: pointer,
    maxProducers: int,
    maxConsumers: int
): ptr lfq_queue_t =
  let q = cast[ptr BoundedQueueImpl[N, P, C]](allocShared0(sizeof(BoundedQueueImpl[N, P, C])))
  let raw = cast[ptr BQueue[pointer, ccMulti, ccMulti, N, P, C]](allocShared0(sizeof(BQueue[pointer, ccMulti, ccMulti, N, P, C])))
  raw[] = newBQueue[pointer, ccMulti, ccMulti, N, P, C]()
  q.rawQueue = raw
  q.base.destructor = destructor
  q.base.userData = userData
  q.base.maxProducers = maxProducers
  q.base.maxConsumers = maxConsumers
  q.base.activeProducers.store(0, moRelaxed)
  q.base.activeConsumers.store(0, moRelaxed)
  q.base.isClosed.store(false, moRelaxed)
  q.base.destroyFn = boundedQueueDestroy[N, P, C]
  q.base.producerAcquireFn = boundedProducerAcquire[N, P, C]
  q.base.consumerAcquireFn = boundedConsumerAcquire[N, P, C]
  q.base.lenFn = boundedQueueLen[N, P, C]
  q.base.isEmptyFn = boundedQueueIsEmpty[N, P, C]
  return cast[ptr lfq_queue_t](q)

# ------------------------------------------------------------------------------
# Unbounded MPMC Implementation (Strict-LCRQ Queue)
# ------------------------------------------------------------------------------

type
  UnboundedQueueImpl[S, MaxThreads: static int] = object
    base: lfq_queue_t
    rawQueue: ptr Queue[pointer, ccMulti, ccMulti, stEager, S, MaxThreads]

  UnboundedProducerImpl[S, MaxThreads: static int] = object
    base: lfq_producer_t
    bound: Bound[pointer, AnyThreadTag, Queue[pointer, ccMulti, ccMulti, stEager, S, MaxThreads]]

  UnboundedConsumerImpl[S, MaxThreads: static int] = object
    base: lfq_consumer_t
    bound: Bound[pointer, AnyThreadTag, Queue[pointer, ccMulti, ccMulti, stEager, S, MaxThreads]]

proc unboundedPush[S, MaxThreads: static int](prod: ptr lfq_producer_t, item: pointer): lfq_status_t {.nimcall, gcsafe, raises: [].} =
  let p = cast[ptr UnboundedProducerImpl[S, MaxThreads]](prod)
  cAbiBoundary:
    {.cast(gcsafe).}:
      p.bound.push(item)
      LFQ_OK

proc unboundedPop[S, MaxThreads: static int](cons: ptr lfq_consumer_t, outItem: ptr pointer): lfq_status_t {.nimcall, gcsafe, raises: [].} =
  let c = cast[ptr UnboundedConsumerImpl[S, MaxThreads]](cons)
  cAbiBoundary:
    {.cast(gcsafe).}:
      let opt = c.bound.pop()
      if opt.isSome:
        outItem[] = opt.get
        LFQ_OK
      else:
        LFQ_ERR_EMPTY

proc unboundedPopBatch[S, MaxThreads: static int](
    cons: ptr lfq_consumer_t, outItems: ptr pointer, maxCount: csize_t
): csize_t {.nimcall, gcsafe, raises: [].} =
  if unlikely(cons == nil or outItems == nil or maxCount == 0):
    return 0
  let c = cast[ptr UnboundedConsumerImpl[S, MaxThreads]](cons)
  let arr = cast[ptr UncheckedArray[pointer]](outItems)
  try:
    {.cast(gcsafe).}:
      let n = c.bound.popBatch(toOpenArray(arr, 0, int(maxCount) - 1), int(maxCount))
      return csize_t(n)
  except:
    return 0

proc unboundedProducerRelease[S, MaxThreads: static int](prod: ptr lfq_producer_t): lfq_status_t {.nimcall, gcsafe, raises: [].} =
  let p = cast[ptr UnboundedProducerImpl[S, MaxThreads]](prod)
  let q = cast[ptr UnboundedQueueImpl[S, MaxThreads]](p.base.queue)
  cAbiBoundary:
    {.cast(gcsafe).}:
      let mgrPtr = p.base.handleManager
      let hIdx = p.base.handleIdx
      for i in 0 ..< tlsThreadRegistrations.len:
        if tlsThreadRegistrations[i].mgr == mgrPtr:
          dec tlsThreadRegistrations[i].count
          if tlsThreadRegistrations[i].count <= 0:
            tlsThreadRegistrations.delete(i)
            # Restore NEBR threadvars for this manager so unregisterThread doAssert passes
            threadLocalManager = mgrPtr
            threadLocalIdx = hIdx
            threadLocalRegistered = true

            type Handle = typeof(registerThread(q.rawQueue[].manager[]))
            let h = Handle(idx: hIdx, manager: q.rawQueue[].manager)
            for _ in 0 .. 3:
              discard q.rawQueue[].manager.globalEpoch.fetchAdd(1'u64, moRelease)
              discard reclaimNow(h)
            unregisterThread(q.rawQueue[].manager[], h)

            if tlsThreadRegistrations.len > 0:
              threadLocalManager = tlsThreadRegistrations[^1].mgr
              threadLocalIdx = tlsThreadRegistrations[^1].handleIdx
              threadLocalRegistered = true
          break

      discard q.base.activeProducers.fetchSub(1, moRelaxed)
      deallocShared(p)
      LFQ_OK

proc unboundedConsumerRelease[S, MaxThreads: static int](cons: ptr lfq_consumer_t): lfq_status_t {.nimcall, gcsafe, raises: [].} =
  let c = cast[ptr UnboundedConsumerImpl[S, MaxThreads]](cons)
  let q = cast[ptr UnboundedQueueImpl[S, MaxThreads]](c.base.queue)
  cAbiBoundary:
    {.cast(gcsafe).}:
      let mgrPtr = c.base.handleManager
      let hIdx = c.base.handleIdx
      for i in 0 ..< tlsThreadRegistrations.len:
        if tlsThreadRegistrations[i].mgr == mgrPtr:
          dec tlsThreadRegistrations[i].count
          if tlsThreadRegistrations[i].count <= 0:
            tlsThreadRegistrations.delete(i)
            # Restore NEBR threadvars for this manager so unregisterThread doAssert passes
            threadLocalManager = mgrPtr
            threadLocalIdx = hIdx
            threadLocalRegistered = true

            type Handle = typeof(registerThread(q.rawQueue[].manager[]))
            let h = Handle(idx: hIdx, manager: q.rawQueue[].manager)
            for _ in 0 .. 3:
              discard q.rawQueue[].manager.globalEpoch.fetchAdd(1'u64, moRelease)
              discard reclaimNow(h)
            unregisterThread(q.rawQueue[].manager[], h)

            if tlsThreadRegistrations.len > 0:
              threadLocalManager = tlsThreadRegistrations[^1].mgr
              threadLocalIdx = tlsThreadRegistrations[^1].handleIdx
              threadLocalRegistered = true
          break

      discard q.base.activeConsumers.fetchSub(1, moRelaxed)
      deallocShared(c)
      LFQ_OK

proc unboundedProducerAcquire[S, MaxThreads: static int](
    qBase: ptr lfq_queue_t, outProd: ptr ptr lfq_producer_t
): lfq_status_t {.nimcall, gcsafe, raises: [].} =
  let q = cast[ptr UnboundedQueueImpl[S, MaxThreads]](qBase)
  if q.base.maxProducers > 0 and q.base.activeProducers.load(moRelaxed) >= q.base.maxProducers:
    return LFQ_ERR_REGISTRY_FULL
  cAbiBoundary:
    {.cast(gcsafe).}:
      let mgrPtr = cast[pointer](q.rawQueue[].manager)
      var handleIdx = -1
      var found = false
      for i in 0 ..< tlsThreadRegistrations.len:
        if tlsThreadRegistrations[i].mgr == mgrPtr:
          inc tlsThreadRegistrations[i].count
          handleIdx = tlsThreadRegistrations[i].handleIdx
          found = true
          break

      if not found:
        var h: typeof(registerThread(q.rawQueue[].manager[]))
        try:
          h = registerThread(q.rawQueue[].manager[])
        except DebraRegistrationError:
          return LFQ_ERR_REGISTRY_FULL
        handleIdx = h.idx
        tlsThreadRegistrations.add(ThreadRegistrationCount(mgr: mgrPtr, count: 1, handleIdx: handleIdx))

      var b: Bound[pointer, AnyThreadTag, Queue[pointer, ccMulti, ccMulti, stEager, S, MaxThreads]]
      b.queue = q.rawQueue
      b.handleManager = mgrPtr
      b.handleIdx = handleIdx
      when defined(debug):
        b.attachedTid = getThreadId()

      let p = cast[ptr UnboundedProducerImpl[S, MaxThreads]](allocShared0(sizeof(UnboundedProducerImpl[S, MaxThreads])))
      p.base.queue = qBase
      p.base.pushFn = unboundedPush[S, MaxThreads]
      p.base.releaseFn = unboundedProducerRelease[S, MaxThreads]
      p.base.handleManager = mgrPtr
      p.base.handleIdx = handleIdx
      p.bound = b
      discard q.base.activeProducers.fetchAdd(1, moRelaxed)
      outProd[] = cast[ptr lfq_producer_t](p)
      LFQ_OK

proc unboundedConsumerAcquire[S, MaxThreads: static int](
    qBase: ptr lfq_queue_t, outCons: ptr ptr lfq_consumer_t
): lfq_status_t {.nimcall, gcsafe, raises: [].} =
  let q = cast[ptr UnboundedQueueImpl[S, MaxThreads]](qBase)
  if q.base.maxConsumers > 0 and q.base.activeConsumers.load(moRelaxed) >= q.base.maxConsumers:
    return LFQ_ERR_REGISTRY_FULL
  cAbiBoundary:
    {.cast(gcsafe).}:
      let mgrPtr = cast[pointer](q.rawQueue[].manager)
      var handleIdx = -1
      var found = false
      for i in 0 ..< tlsThreadRegistrations.len:
        if tlsThreadRegistrations[i].mgr == mgrPtr:
          inc tlsThreadRegistrations[i].count
          handleIdx = tlsThreadRegistrations[i].handleIdx
          found = true
          break

      if not found:
        var h: typeof(registerThread(q.rawQueue[].manager[]))
        try:
          h = registerThread(q.rawQueue[].manager[])
        except DebraRegistrationError:
          return LFQ_ERR_REGISTRY_FULL
        handleIdx = h.idx
        tlsThreadRegistrations.add(ThreadRegistrationCount(mgr: mgrPtr, count: 1, handleIdx: handleIdx))

      var b: Bound[pointer, AnyThreadTag, Queue[pointer, ccMulti, ccMulti, stEager, S, MaxThreads]]
      b.queue = q.rawQueue
      b.handleManager = mgrPtr
      b.handleIdx = handleIdx
      when defined(debug):
        b.attachedTid = getThreadId()

      let c = cast[ptr UnboundedConsumerImpl[S, MaxThreads]](allocShared0(sizeof(UnboundedConsumerImpl[S, MaxThreads])))
      c.base.queue = qBase
      c.base.popFn = unboundedPop[S, MaxThreads]
      c.base.popBatchFn = unboundedPopBatch[S, MaxThreads]
      c.base.releaseFn = unboundedConsumerRelease[S, MaxThreads]
      c.base.handleManager = mgrPtr
      c.base.handleIdx = handleIdx
      c.bound = b
      discard q.base.activeConsumers.fetchAdd(1, moRelaxed)
      outCons[] = cast[ptr lfq_consumer_t](c)
      LFQ_OK

proc unboundedQueueLen[S, MaxThreads: static int](qBase: ptr lfq_queue_t): csize_t {.nimcall, gcsafe, raises: [].} =
  let q = cast[ptr UnboundedQueueImpl[S, MaxThreads]](qBase)
  try:
    {.cast(gcsafe).}:
      let count = q.rawQueue[].len
      if count < 0: 0.csize_t else: csize_t(count)
  except:
    0

proc unboundedQueueIsEmpty[S, MaxThreads: static int](qBase: ptr lfq_queue_t): bool {.nimcall, gcsafe, raises: [].} =
  let q = cast[ptr UnboundedQueueImpl[S, MaxThreads]](qBase)
  try:
    {.cast(gcsafe).}:
      q.rawQueue[].len <= 0
  except:
    true

proc unboundedQueueDestroy[S, MaxThreads: static int](qBase: ptr lfq_queue_t): lfq_status_t {.nimcall, gcsafe, raises: [].} =
  if qBase.activeProducers.load(moAcquire) > 0 or qBase.activeConsumers.load(moAcquire) > 0:
    return LFQ_ERR_FAILURE
  let q = cast[ptr UnboundedQueueImpl[S, MaxThreads]](qBase)
  cAbiBoundary:
    {.cast(gcsafe).}:
      if q.base.destructor != nil:
        try:
          var h: typeof(registerThread(q.rawQueue[].manager[]))
          let registered =
            try:
              h = registerThread(q.rawQueue[].manager[])
              true
            except:
              false

          if registered:
            var b: Bound[pointer, AnyThreadTag, Queue[pointer, ccMulti, ccMulti, stEager, S, MaxThreads]]
            b.queue = q.rawQueue
            b.handleManager = cast[pointer](q.rawQueue[].manager)
            b.handleIdx = h.idx
            while true:
              let opt = b.pop()
              if opt.isSome:
                q.base.destructor(opt.get, q.base.userData)
              else:
                break
            for _ in 0 .. 3:
              discard q.rawQueue[].manager.globalEpoch.fetchAdd(1'u64, moRelease)
              discard reclaimNow(h)
            unregisterThread(q.rawQueue[].manager[], h)
            if tlsThreadRegistrations.len > 0:
              threadLocalManager = tlsThreadRegistrations[^1].mgr
              threadLocalIdx = tlsThreadRegistrations[^1].handleIdx
              threadLocalRegistered = true
        except:
          discard
      `=destroy`(q.rawQueue[])
      deallocShared(q.rawQueue)
      deallocShared(q)
      LFQ_OK


proc createUnboundedInstance[S, MaxThreads: static int](
    destructor: lfq_item_destructor_fn,
    userData: pointer,
    maxProducers: int,
    maxConsumers: int
): ptr lfq_queue_t =
  let q = cast[ptr UnboundedQueueImpl[S, MaxThreads]](allocShared0(sizeof(UnboundedQueueImpl[S, MaxThreads])))
  let raw = cast[ptr Queue[pointer, ccMulti, ccMulti, stEager, S, MaxThreads]](allocShared0(sizeof(Queue[pointer, ccMulti, ccMulti, stEager, S, MaxThreads])))
  raw[] = newUnboundedMpmcQueue[pointer, stEager, S, MaxThreads]()
  q.rawQueue = raw
  q.base.destructor = destructor
  q.base.userData = userData
  q.base.maxProducers = maxProducers
  q.base.maxConsumers = maxConsumers
  q.base.activeProducers.store(0, moRelaxed)
  q.base.activeConsumers.store(0, moRelaxed)
  q.base.isClosed.store(false, moRelaxed)
  q.base.destroyFn = unboundedQueueDestroy[S, MaxThreads]
  q.base.producerAcquireFn = unboundedProducerAcquire[S, MaxThreads]
  q.base.consumerAcquireFn = unboundedConsumerAcquire[S, MaxThreads]
  q.base.lenFn = unboundedQueueLen[S, MaxThreads]
  q.base.isEmptyFn = unboundedQueueIsEmpty[S, MaxThreads]
  return cast[ptr lfq_queue_t](q)

# ------------------------------------------------------------------------------
# Exported Canonical C99 API
# ------------------------------------------------------------------------------

proc lfq_unbounded_mpmc_create*(
    segment_size: csize_t,
    max_threads: csize_t,
    destructor: lfq_item_destructor_fn,
    user_data: pointer,
    out_queue: ptr ptr lfq_queue_t
): lfq_status_t {.exportc: "lfq_unbounded_mpmc_create", cdecl, gcsafe, raises: [].} =
  if out_queue == nil:
    return LFQ_ERR_INVALID_ARG

  var seg = int(segment_size)
  var th = int(max_threads)
  if seg == 0: seg = 64
  if th == 0: th = 64

  if seg < 2 or th < 1:
    return LFQ_ERR_INVALID_ARG

  cAbiBoundary:
    var q: ptr lfq_queue_t = nil
    if seg <= 16 and th <= 4:
      q = createUnboundedInstance[16, 4](destructor, user_data, th, th)
    elif seg <= 16 and th <= 16:
      q = createUnboundedInstance[16, 16](destructor, user_data, th, th)
    elif seg <= 32 and th <= 32:
      q = createUnboundedInstance[32, 32](destructor, user_data, th, th)
    elif seg <= 64 and th <= 64:
      q = createUnboundedInstance[64, 64](destructor, user_data, th, th)
    elif seg <= 128 and th <= 128:
      q = createUnboundedInstance[128, 128](destructor, user_data, th, th)
    elif seg <= 256 and th <= 256:
      q = createUnboundedInstance[256, 256](destructor, user_data, th, th)
    else:
      return LFQ_ERR_UNSUPPORTED

    out_queue[] = q
    LFQ_OK

template dispatchBoundedCapacity(P_TIER, C_TIER: static int, capacity, p, c: int, destructor: lfq_item_destructor_fn, user_data: pointer, out_q: var ptr lfq_queue_t): lfq_status_t =
  if capacity <= 4:
    out_q = createBoundedInstance[4, P_TIER, C_TIER](destructor, user_data, p, c)
    LFQ_OK
  elif capacity <= 8:
    out_q = createBoundedInstance[8, P_TIER, C_TIER](destructor, user_data, p, c)
    LFQ_OK
  elif capacity <= 16:
    out_q = createBoundedInstance[16, P_TIER, C_TIER](destructor, user_data, p, c)
    LFQ_OK
  elif capacity <= 32:
    out_q = createBoundedInstance[32, P_TIER, C_TIER](destructor, user_data, p, c)
    LFQ_OK
  elif capacity <= 64:
    out_q = createBoundedInstance[64, P_TIER, C_TIER](destructor, user_data, p, c)
    LFQ_OK
  elif capacity <= 128:
    out_q = createBoundedInstance[128, P_TIER, C_TIER](destructor, user_data, p, c)
    LFQ_OK
  elif capacity <= 256:
    out_q = createBoundedInstance[256, P_TIER, C_TIER](destructor, user_data, p, c)
    LFQ_OK
  elif capacity <= 512:
    out_q = createBoundedInstance[512, P_TIER, C_TIER](destructor, user_data, p, c)
    LFQ_OK
  elif capacity <= 1024:
    out_q = createBoundedInstance[1024, P_TIER, C_TIER](destructor, user_data, p, c)
    LFQ_OK
  elif capacity <= 2048:
    out_q = createBoundedInstance[2048, P_TIER, C_TIER](destructor, user_data, p, c)
    LFQ_OK
  elif capacity <= 4096:
    out_q = createBoundedInstance[4096, P_TIER, C_TIER](destructor, user_data, p, c)
    LFQ_OK
  elif capacity <= 8192:
    out_q = createBoundedInstance[8192, P_TIER, C_TIER](destructor, user_data, p, c)
    LFQ_OK
  elif capacity <= 16384:
    out_q = createBoundedInstance[16384, P_TIER, C_TIER](destructor, user_data, p, c)
    LFQ_OK
  elif capacity <= 32768:
    out_q = createBoundedInstance[32768, P_TIER, C_TIER](destructor, user_data, p, c)
    LFQ_OK
  elif capacity <= 65536:
    out_q = createBoundedInstance[65536, P_TIER, C_TIER](destructor, user_data, p, c)
    LFQ_OK
  else:
    LFQ_ERR_UNSUPPORTED

proc lfq_bounded_mpmc_create*(
    capacity: csize_t,
    max_producers: csize_t,
    max_consumers: csize_t,
    destructor: lfq_item_destructor_fn,
    user_data: pointer,
    out_queue: ptr ptr lfq_queue_t
): lfq_status_t {.exportc: "lfq_bounded_mpmc_create", cdecl, gcsafe, raises: [].} =
  if out_queue == nil or capacity == 0:
    return LFQ_ERR_INVALID_ARG

  var cap = int(capacity)
  var p = int(max_producers)
  var c = int(max_consumers)
  if p == 0: p = 64
  if c == 0: c = 64

  cAbiBoundary:
    var q: ptr lfq_queue_t = nil
    var st: lfq_status_t
    if p <= 64 and c <= 64:
      st = dispatchBoundedCapacity(64, 64, cap, p, c, destructor, user_data, q)
    elif p <= 256 and c <= 256:
      st = dispatchBoundedCapacity(256, 256, cap, p, c, destructor, user_data, q)
    else:
      return LFQ_ERR_UNSUPPORTED

    if st != LFQ_OK:
      return st

    out_queue[] = q
    LFQ_OK

proc lfq_queue_close*(queue: ptr lfq_queue_t): lfq_status_t {.exportc: "lfq_queue_close", cdecl, gcsafe, raises: [].} =
  if unlikely(queue == nil):
    return LFQ_ERR_INVALID_ARG
  queue.isClosed.store(true, moRelease)
  return LFQ_OK

proc lfq_queue_destroy*(queue: ptr lfq_queue_t): lfq_status_t {.exportc: "lfq_queue_destroy", cdecl, gcsafe, raises: [].} =
  if unlikely(queue == nil):
    return LFQ_ERR_INVALID_ARG
  if queue.activeProducers.load(moAcquire) > 0 or queue.activeConsumers.load(moAcquire) > 0:
    return LFQ_ERR_FAILURE
  cAbiBoundary:
    queue.destroyFn(queue)

proc lfq_producer_acquire*(
    queue: ptr lfq_queue_t,
    out_prod: ptr ptr lfq_producer_t
): lfq_status_t {.exportc: "lfq_producer_acquire", cdecl, gcsafe, raises: [].} =
  if unlikely(queue == nil or out_prod == nil):
    return LFQ_ERR_INVALID_ARG
  if unlikely(queue.isClosed.load(moAcquire)):
    return LFQ_ERR_CLOSED
  cAbiBoundary:
    queue.producerAcquireFn(queue, out_prod)

proc lfq_producer_release*(prod: ptr lfq_producer_t): lfq_status_t {.exportc: "lfq_producer_release", cdecl, gcsafe, raises: [].} =
  if unlikely(prod == nil):
    return LFQ_ERR_INVALID_ARG
  cAbiBoundary:
    prod.releaseFn(prod)

proc lfq_consumer_acquire*(
    queue: ptr lfq_queue_t,
    out_cons: ptr ptr lfq_consumer_t
): lfq_status_t {.exportc: "lfq_consumer_acquire", cdecl, gcsafe, raises: [].} =
  if unlikely(queue == nil or out_cons == nil):
    return LFQ_ERR_INVALID_ARG
  cAbiBoundary:
    queue.consumerAcquireFn(queue, out_cons)

proc lfq_consumer_release*(cons: ptr lfq_consumer_t): lfq_status_t {.exportc: "lfq_consumer_release", cdecl, gcsafe, raises: [].} =
  if unlikely(cons == nil):
    return LFQ_ERR_INVALID_ARG
  cAbiBoundary:
    cons.releaseFn(cons)

proc lfq_push*(prod: ptr lfq_producer_t, item: pointer): lfq_status_t {.exportc: "lfq_push", cdecl, gcsafe, raises: [].} =
  if unlikely(prod == nil or prod.queue == nil):
    return LFQ_ERR_INVALID_ARG
  if unlikely(prod.queue.isClosed.load(moAcquire)):
    return LFQ_ERR_CLOSED
  cAbiBoundary:
    prod.pushFn(prod, item)

proc lfq_pop*(cons: ptr lfq_consumer_t, out_item: ptr pointer): lfq_status_t {.exportc: "lfq_pop", cdecl, gcsafe, raises: [].} =
  if unlikely(cons == nil or out_item == nil):
    return LFQ_ERR_INVALID_ARG
  cAbiBoundary:
    cons.popFn(cons, out_item)

proc lfq_pop_batch*(
    cons: ptr lfq_consumer_t,
    out_items: ptr pointer,
    max_count: csize_t
): csize_t {.exportc: "lfq_pop_batch", cdecl, gcsafe, raises: [].} =
  if unlikely(cons == nil or out_items == nil or max_count == 0):
    return 0
  try:
    return cons.popBatchFn(cons, out_items, max_count)
  except:
    return 0

proc lfq_queue_len*(queue: ptr lfq_queue_t): csize_t {.exportc: "lfq_queue_len", cdecl, gcsafe, raises: [].} =
  if unlikely(queue == nil):
    return 0
  try:
    return queue.lenFn(queue)
  except:
    return 0

proc lfq_queue_is_empty*(queue: ptr lfq_queue_t): bool {.exportc: "lfq_queue_is_empty", cdecl, gcsafe, raises: [].} =
  if unlikely(queue == nil):
    return true
  try:
    return queue.isEmptyFn(queue)
  except:
    return true

proc lfq_queue_is_closed*(queue: ptr lfq_queue_t): bool {.exportc: "lfq_queue_is_closed", cdecl, gcsafe, raises: [].} =
  if unlikely(queue == nil):
    return true
  return queue.isClosed.load(moAcquire)
