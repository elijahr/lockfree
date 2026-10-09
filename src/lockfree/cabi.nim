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
import lockfree/stack
import lockfree/deque
import lockfree/skiplist
import lockfree/set
import lockfree/taskpool
import lockfree/ctrie
import lockfree/broadcast
import lockfree/rendezvous
import lockfree/ratelimit
export ratelimit
import lockfree/streambuffer
export streambuffer
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
  lfq_entry_destructor_fn* = proc(key: pointer, val: pointer, userData: pointer) {.cdecl, gcsafe.}

# ------------------------------------------------------------------------------
# Exception Firewall Template
# ------------------------------------------------------------------------------

template cAbiBoundary(body: untyped): lfq_status_t =
  try:
    body
  except NoProducersAvailableError, NoConsumersAvailableError:
    LFQ_ERR_REGISTRY_FULL
  except ChannelClosedDefect:
    LFQ_ERR_CLOSED
  except Defect:
    LFQ_ERR_PANIC
  except Exception:
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
    try:
      let idx = p.bound.idx
      discard close(p.bound)
      if idx >= 0 and idx < P:
        q.rawQueue.producerThreadIds[idx].store(0, moRelease)
    finally:
      discard q.base.activeProducers.fetchSub(1, moRelaxed)
      deallocShared(p)
    LFQ_OK

proc boundedConsumerRelease[N, P, C: static int](cons: ptr lfq_consumer_t): lfq_status_t {.nimcall, gcsafe, raises: [].} =
  let c = cast[ptr BoundedConsumerImpl[N, P, C]](cons)
  let q = cast[ptr BoundedQueueImpl[N, P, C]](c.base.queue)
  cAbiBoundary:
    try:
      let idx = c.bound.idx
      discard close(c.bound)
      if idx >= 0 and idx < C:
        q.rawQueue.consumerThreadIds[idx].store(0, moRelease)
    finally:
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
      try:
        let mgrPtr = p.base.handleManager
        let hIdx = p.base.handleIdx
        for i in 0 ..< tlsThreadRegistrations.len:
          if tlsThreadRegistrations[i].mgr == mgrPtr:
            dec tlsThreadRegistrations[i].count
            if tlsThreadRegistrations[i].count <= 0:
              tlsThreadRegistrations.delete(i)
              type Handle = typeof(registerThread(q.rawQueue[].manager[]))
              let h = Handle(idx: hIdx, manager: q.rawQueue[].manager)
              for _ in 0 .. 3:
                discard q.rawQueue[].manager.globalEpoch.fetchAdd(1'u64, moRelease)
                discard reclaimNow(h)

              let slot = addr q.rawQueue[].manager.threads[hIdx]
              if slot.limboBagTail == nil and slot.currentBag == nil:
                # Restore NEBR threadvars for this manager so unregisterThread
                # passes contract
                threadLocalManager = mgrPtr
                threadLocalIdx = hIdx
                threadLocalRegistered = true
                try:
                  unregisterThread(q.rawQueue[].manager[], h)
                except:
                  discard

              if tlsThreadRegistrations.len > 0:
                threadLocalManager = tlsThreadRegistrations[^1].mgr
                threadLocalIdx = tlsThreadRegistrations[^1].handleIdx
                threadLocalRegistered = true
              else:
                threadLocalManager = nil
                threadLocalIdx = 0
                threadLocalRegistered = false
            break
      finally:
        discard q.base.activeProducers.fetchSub(1, moRelaxed)
        deallocShared(p)
      LFQ_OK

proc unboundedConsumerRelease[S, MaxThreads: static int](cons: ptr lfq_consumer_t): lfq_status_t {.nimcall, gcsafe, raises: [].} =
  let c = cast[ptr UnboundedConsumerImpl[S, MaxThreads]](cons)
  let q = cast[ptr UnboundedQueueImpl[S, MaxThreads]](c.base.queue)
  cAbiBoundary:
    {.cast(gcsafe).}:
      try:
        let mgrPtr = c.base.handleManager
        let hIdx = c.base.handleIdx
        for i in 0 ..< tlsThreadRegistrations.len:
          if tlsThreadRegistrations[i].mgr == mgrPtr:
            dec tlsThreadRegistrations[i].count
            if tlsThreadRegistrations[i].count <= 0:
              tlsThreadRegistrations.delete(i)
              type Handle = typeof(registerThread(q.rawQueue[].manager[]))
              let h = Handle(idx: hIdx, manager: q.rawQueue[].manager)
              for _ in 0 .. 3:
                discard q.rawQueue[].manager.globalEpoch.fetchAdd(1'u64, moRelease)
                discard reclaimNow(h)

              let slot = addr q.rawQueue[].manager.threads[hIdx]
              if slot.limboBagTail == nil and slot.currentBag == nil:
                # Restore NEBR threadvars for this manager so unregisterThread
                # passes contract
                threadLocalManager = mgrPtr
                threadLocalIdx = hIdx
                threadLocalRegistered = true
                try:
                  unregisterThread(q.rawQueue[].manager[], h)
                except:
                  discard

              if tlsThreadRegistrations.len > 0:
                threadLocalManager = tlsThreadRegistrations[^1].mgr
                threadLocalIdx = tlsThreadRegistrations[^1].handleIdx
                threadLocalRegistered = true
              else:
                threadLocalManager = nil
                threadLocalIdx = 0
                threadLocalRegistered = false
            break
      finally:
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

proc lfq_queue_push*(prod: ptr lfq_producer_t, item: pointer): lfq_status_t {.exportc: "lfq_queue_push", cdecl, gcsafe, raises: [].} =
  lfq_push(prod, item)

proc lfq_queue_pop*(cons: ptr lfq_consumer_t, out_item: ptr pointer): lfq_status_t {.exportc: "lfq_queue_pop", cdecl, gcsafe, raises: [].} =
  lfq_pop(cons, out_item)

# ------------------------------------------------------------------------------
# 2. Stack (MPMC LIFO Stack with Elimination-Backoff)
# ------------------------------------------------------------------------------

type
  lfq_stack* {.exportc: "lfq_stack_t".} = object
    destructor*: lfq_item_destructor_fn
    userData*: pointer
    raw*: ptr TreiberStack[pointer]

  lfq_stack_t* = lfq_stack

proc lfq_stack_create*(
    destructor: lfq_item_destructor_fn,
    user_data: pointer,
    out_stack: ptr ptr lfq_stack_t
): lfq_status_t {.exportc: "lfq_stack_create", cdecl, gcsafe, raises: [].} =
  if unlikely(out_stack == nil):
    return LFQ_ERR_INVALID_ARG
  cAbiBoundary:
    let s = cast[ptr lfq_stack_t](allocShared0(sizeof(lfq_stack_t)))
    let raw = cast[ptr TreiberStack[pointer]](allocShared0(sizeof(TreiberStack[pointer])))
    raw[] = initTreiberStack[pointer]()
    s.destructor = destructor
    s.userData = user_data
    s.raw = raw
    out_stack[] = s
    LFQ_OK

proc lfq_stack_destroy*(stack: ptr lfq_stack_t): lfq_status_t {.exportc: "lfq_stack_destroy", cdecl, gcsafe, raises: [].} =
  if unlikely(stack == nil or stack.raw == nil):
    return LFQ_ERR_INVALID_ARG
  cAbiBoundary:
    if stack.destructor != nil:
      try:
        while true:
          let opt = stack.raw[].pop()
          if opt.isSome:
            stack.destructor(opt.get, stack.userData)
          else:
            break
      except:
        discard
    `=destroy`(stack.raw[])
    deallocShared(stack.raw)
    deallocShared(stack)
    LFQ_OK

proc lfq_stack_push*(stack: ptr lfq_stack_t, item: pointer): lfq_status_t {.exportc: "lfq_stack_push", cdecl, gcsafe, raises: [].} =
  if unlikely(stack == nil or stack.raw == nil):
    return LFQ_ERR_INVALID_ARG
  cAbiBoundary:
    stack.raw[].push(item)
    LFQ_OK

proc lfq_stack_pop*(stack: ptr lfq_stack_t, out_item: ptr pointer): lfq_status_t {.exportc: "lfq_stack_pop", cdecl, gcsafe, raises: [].} =
  if unlikely(stack == nil or stack.raw == nil or out_item == nil):
    return LFQ_ERR_INVALID_ARG
  cAbiBoundary:
    let opt = stack.raw[].pop()
    if opt.isSome:
      out_item[] = opt.get
      LFQ_OK
    else:
      LFQ_ERR_EMPTY

proc lfq_stack_peek*(stack: ptr lfq_stack_t, out_item: ptr pointer): lfq_status_t {.exportc: "lfq_stack_peek", cdecl, gcsafe, raises: [].} =
  if unlikely(stack == nil or stack.raw == nil or out_item == nil):
    return LFQ_ERR_INVALID_ARG
  cAbiBoundary:
    let opt = stack.raw[].peek()
    if opt.isSome:
      out_item[] = opt.get
      LFQ_OK
    else:
      LFQ_ERR_EMPTY

proc lfq_stack_drain*(
    stack: ptr lfq_stack_t,
    out_items: ptr pointer,
    max_count: csize_t
): csize_t {.exportc: "lfq_stack_drain", cdecl, gcsafe, raises: [].} =
  if unlikely(stack == nil or stack.raw == nil or out_items == nil or max_count == 0):
    return 0
  let arr = cast[ptr UncheckedArray[pointer]](out_items)
  var count: csize_t = 0
  try:
    while count < max_count:
      let opt = stack.raw[].pop()
      if opt.isSome:
        arr[count] = opt.get
        inc count
      else:
        break
  except:
    discard
  return count

proc lfq_stack_len*(stack: ptr lfq_stack_t): csize_t {.exportc: "lfq_stack_len", cdecl, gcsafe, raises: [].} =
  if unlikely(stack == nil or stack.raw == nil):
    return 0
  try:
    let count = stack.raw[].len
    if count < 0: 0.csize_t else: csize_t(count)
  except:
    0

proc lfq_stack_is_empty*(stack: ptr lfq_stack_t): bool {.exportc: "lfq_stack_is_empty", cdecl, gcsafe, raises: [].} =
  if unlikely(stack == nil or stack.raw == nil):
    return true
  try:
    return stack.raw[].isEmpty()
  except:
    return true

# ------------------------------------------------------------------------------
# 3. Deque (Single-Worker / Multi-Thief Work-Stealing Deque)
# ------------------------------------------------------------------------------

type
  lfq_deque* {.exportc: "lfq_deque_t".} = object
    destructor*: lfq_item_destructor_fn
    userData*: pointer
    raw*: ptr ChaseLevDeque[pointer]

  lfq_deque_t* = lfq_deque

proc lfq_deque_create*(
    initial_capacity: csize_t,
    destructor: lfq_item_destructor_fn,
    user_data: pointer,
    out_deque: ptr ptr lfq_deque_t
): lfq_status_t {.exportc: "lfq_deque_create", cdecl, gcsafe, raises: [].} =
  if unlikely(out_deque == nil):
    return LFQ_ERR_INVALID_ARG
  var cap = int(initial_capacity)
  if cap <= 0: cap = 64
  cAbiBoundary:
    let d = cast[ptr lfq_deque_t](allocShared0(sizeof(lfq_deque_t)))
    let raw = cast[ptr ChaseLevDeque[pointer]](allocShared0(sizeof(ChaseLevDeque[pointer])))
    raw[] = initChaseLevDeque[pointer](cap)
    d.destructor = destructor
    d.userData = user_data
    d.raw = raw
    out_deque[] = d
    LFQ_OK

proc lfq_deque_destroy*(deque: ptr lfq_deque_t): lfq_status_t {.exportc: "lfq_deque_destroy", cdecl, gcsafe, raises: [].} =
  if unlikely(deque == nil or deque.raw == nil):
    return LFQ_ERR_INVALID_ARG
  cAbiBoundary:
    if deque.destructor != nil:
      try:
        while true:
          let opt = deque.raw[].popBottom()
          if opt.isSome:
            deque.destructor(opt.get, deque.userData)
          else:
            break
      except:
        discard
    `=destroy`(deque.raw[])
    deallocShared(deque.raw)
    deallocShared(deque)
    LFQ_OK

proc lfq_deque_push*(deque: ptr lfq_deque_t, item: pointer): lfq_status_t {.exportc: "lfq_deque_push", cdecl, gcsafe, raises: [].} =
  if unlikely(deque == nil or deque.raw == nil):
    return LFQ_ERR_INVALID_ARG
  cAbiBoundary:
    deque.raw[].pushBottom(item)
    LFQ_OK

proc lfq_deque_pop*(deque: ptr lfq_deque_t, out_item: ptr pointer): lfq_status_t {.exportc: "lfq_deque_pop", cdecl, gcsafe, raises: [].} =
  if unlikely(deque == nil or deque.raw == nil or out_item == nil):
    return LFQ_ERR_INVALID_ARG
  cAbiBoundary:
    let opt = deque.raw[].popBottom()
    if opt.isSome:
      out_item[] = opt.get
      LFQ_OK
    else:
      LFQ_ERR_EMPTY

proc lfq_deque_steal*(deque: ptr lfq_deque_t, out_item: ptr pointer): lfq_status_t {.exportc: "lfq_deque_steal", cdecl, gcsafe, raises: [].} =
  if unlikely(deque == nil or deque.raw == nil or out_item == nil):
    return LFQ_ERR_INVALID_ARG
  cAbiBoundary:
    let opt = deque.raw[].steal()
    if opt.isSome:
      out_item[] = opt.get
      LFQ_OK
    else:
      LFQ_ERR_EMPTY

proc lfq_deque_steal_batch*(
    deque: ptr lfq_deque_t,
    out_items: ptr pointer,
    max_count: csize_t
): csize_t {.exportc: "lfq_deque_steal_batch", cdecl, gcsafe, raises: [].} =
  if unlikely(deque == nil or deque.raw == nil or out_items == nil or max_count == 0):
    return 0
  let arr = cast[ptr UncheckedArray[pointer]](out_items)
  try:
    let n = deque.raw[].stealBatch(toOpenArray(arr, 0, int(max_count) - 1), int(max_count))
    return csize_t(n)
  except:
    return 0

proc lfq_deque_len*(deque: ptr lfq_deque_t): csize_t {.exportc: "lfq_deque_len", cdecl, gcsafe, raises: [].} =
  if unlikely(deque == nil or deque.raw == nil):
    return 0
  try:
    let count = deque.raw[].len
    if count < 0: 0.csize_t else: csize_t(count)
  except:
    0

proc lfq_deque_capacity*(deque: ptr lfq_deque_t): csize_t {.exportc: "lfq_deque_capacity", cdecl, gcsafe, raises: [].} =
  if unlikely(deque == nil or deque.raw == nil):
    return 0
  try:
    let cap = deque.raw[].capacity
    if cap < 0: 0.csize_t else: csize_t(cap)
  except:
    0

proc lfq_deque_is_empty*(deque: ptr lfq_deque_t): bool {.exportc: "lfq_deque_is_empty", cdecl, gcsafe, raises: [].} =
  if unlikely(deque == nil or deque.raw == nil):
    return true
  try:
    return deque.raw[].isEmpty()
  except:
    return true

# ------------------------------------------------------------------------------
# 4. Table (MPMC Ordered Key-Value Map based on SkipListMap)
# ------------------------------------------------------------------------------

type
  lfq_table* {.exportc: "lfq_table_t".} = object
    destructor*: lfq_entry_destructor_fn
    userData*: pointer
    raw*: ptr SkipListMap[pointer, pointer]

  lfq_table_t* = lfq_table

proc lfq_table_create*(
    destructor: lfq_entry_destructor_fn,
    user_data: pointer,
    out_table: ptr ptr lfq_table_t
): lfq_status_t {.exportc: "lfq_table_create", cdecl, gcsafe, raises: [].} =
  if unlikely(out_table == nil):
    return LFQ_ERR_INVALID_ARG
  cAbiBoundary:
    let t = cast[ptr lfq_table_t](allocShared0(sizeof(lfq_table_t)))
    let raw = cast[ptr SkipListMap[pointer, pointer]](allocShared0(sizeof(SkipListMap[pointer, pointer])))
    raw[] = initSkipListMap[pointer, pointer]()
    t.destructor = destructor
    t.userData = user_data
    t.raw = raw
    out_table[] = t
    LFQ_OK

proc lfq_table_destroy*(table: ptr lfq_table_t): lfq_status_t {.exportc: "lfq_table_destroy", cdecl, gcsafe, raises: [].} =
  if unlikely(table == nil or table.raw == nil):
    return LFQ_ERR_INVALID_ARG
  cAbiBoundary:
    if table.destructor != nil:
      try:
        for k, v in table.raw[].pairs:
          table.destructor(k, v, table.userData)
      except:
        discard
    `=destroy`(table.raw[])
    deallocShared(table.raw)
    deallocShared(table)
    LFQ_OK

proc lfq_table_put*(
    table: ptr lfq_table_t,
    key: pointer,
    val: pointer,
    out_inserted: ptr bool
): lfq_status_t {.exportc: "lfq_table_put", cdecl, gcsafe, raises: [].} =
  if unlikely(table == nil or table.raw == nil):
    return LFQ_ERR_INVALID_ARG
  cAbiBoundary:
    let inserted = table.raw[].put(key, val)
    if out_inserted != nil:
      out_inserted[] = inserted
    LFQ_OK

proc lfq_table_get*(
    table: ptr lfq_table_t,
    key: pointer,
    out_val: ptr pointer
): lfq_status_t {.exportc: "lfq_table_get", cdecl, gcsafe, raises: [].} =
  if unlikely(table == nil or table.raw == nil or out_val == nil):
    return LFQ_ERR_INVALID_ARG
  cAbiBoundary:
    let opt = table.raw[].get(key)
    if opt.isSome:
      out_val[] = opt.get
      LFQ_OK
    else:
      LFQ_ERR_EMPTY

proc lfq_table_delete*(
    table: ptr lfq_table_t,
    key: pointer,
    out_deleted: ptr bool
): lfq_status_t {.exportc: "lfq_table_delete", cdecl, gcsafe, raises: [].} =
  if unlikely(table == nil or table.raw == nil):
    return LFQ_ERR_INVALID_ARG
  cAbiBoundary:
    let deleted = table.raw[].delete(key)
    if out_deleted != nil:
      out_deleted[] = deleted
    if deleted:
      LFQ_OK
    else:
      LFQ_ERR_EMPTY

proc lfq_table_remove*(
    table: ptr lfq_table_t,
    key: pointer,
    out_removed: ptr bool
): lfq_status_t {.exportc: "lfq_table_remove", cdecl, gcsafe, raises: [].} =
  lfq_table_delete(table, key, out_removed)

proc lfq_table_contains*(table: ptr lfq_table_t, key: pointer): bool {.exportc: "lfq_table_contains", cdecl, gcsafe, raises: [].} =
  if unlikely(table == nil or table.raw == nil):
    return false
  try:
    return table.raw[].contains(key)
  except:
    return false

proc lfq_table_len*(table: ptr lfq_table_t): csize_t {.exportc: "lfq_table_len", cdecl, gcsafe, raises: [].} =
  if unlikely(table == nil or table.raw == nil):
    return 0
  try:
    let count = table.raw[].len
    if count < 0: 0.csize_t else: csize_t(count)
  except:
    0

proc lfq_table_is_empty*(table: ptr lfq_table_t): bool {.exportc: "lfq_table_is_empty", cdecl, gcsafe, raises: [].} =
  if unlikely(table == nil or table.raw == nil):
    return true
  try:
    return table.raw[].len == 0
  except:
    return true

# ------------------------------------------------------------------------------
# 5. Set (MPMC Ordered Set based on SkipListSet)
# ------------------------------------------------------------------------------

type
  lfq_set* {.exportc: "lfq_set_t".} = object
    destructor*: lfq_item_destructor_fn
    userData*: pointer
    raw*: ptr SkipListSet[pointer]

  lfq_set_t* = lfq_set

proc lfq_set_create*(
    destructor: lfq_item_destructor_fn,
    user_data: pointer,
    out_set: ptr ptr lfq_set_t
): lfq_status_t {.exportc: "lfq_set_create", cdecl, gcsafe, raises: [].} =
  if unlikely(out_set == nil):
    return LFQ_ERR_INVALID_ARG
  cAbiBoundary:
    let s = cast[ptr lfq_set_t](allocShared0(sizeof(lfq_set_t)))
    let raw = cast[ptr SkipListSet[pointer]](allocShared0(sizeof(SkipListSet[pointer])))
    raw[] = initSkipListSet[pointer]()
    s.destructor = destructor
    s.userData = user_data
    s.raw = raw
    out_set[] = s
    LFQ_OK

proc lfq_set_destroy*(set: ptr lfq_set_t): lfq_status_t {.exportc: "lfq_set_destroy", cdecl, gcsafe, raises: [].} =
  if unlikely(set == nil or set.raw == nil):
    return LFQ_ERR_INVALID_ARG
  cAbiBoundary:
    if set.destructor != nil:
      try:
        for item in set.raw[].items:
          set.destructor(item, set.userData)
      except:
        discard
    `=destroy`(set.raw[])
    deallocShared(set.raw)
    deallocShared(set)
    LFQ_OK

proc lfq_set_insert*(
    set: ptr lfq_set_t,
    item: pointer,
    out_inserted: ptr bool
): lfq_status_t {.exportc: "lfq_set_insert", cdecl, gcsafe, raises: [].} =
  if unlikely(set == nil or set.raw == nil):
    return LFQ_ERR_INVALID_ARG
  cAbiBoundary:
    let inserted = set.raw[].insert(item)
    if out_inserted != nil:
      out_inserted[] = inserted
    LFQ_OK

proc lfq_set_remove*(
    set: ptr lfq_set_t,
    item: pointer,
    out_removed: ptr bool
): lfq_status_t {.exportc: "lfq_set_remove", cdecl, gcsafe, raises: [].} =
  if unlikely(set == nil or set.raw == nil):
    return LFQ_ERR_INVALID_ARG
  cAbiBoundary:
    let removed = set.raw[].remove(item)
    if out_removed != nil:
      out_removed[] = removed
    if removed:
      LFQ_OK
    else:
      LFQ_ERR_EMPTY

proc lfq_set_contains*(set: ptr lfq_set_t, item: pointer): bool {.exportc: "lfq_set_contains", cdecl, gcsafe, raises: [].} =
  if unlikely(set == nil or set.raw == nil):
    return false
  try:
    return set.raw[].contains(item)
  except:
    return false

proc lfq_set_len*(set: ptr lfq_set_t): csize_t {.exportc: "lfq_set_len", cdecl, gcsafe, raises: [].} =
  if unlikely(set == nil or set.raw == nil):
    return 0
  try:
    let count = set.raw[].len
    if count < 0: 0.csize_t else: csize_t(count)
  except:
    0

proc lfq_set_is_empty*(set: ptr lfq_set_t): bool {.exportc: "lfq_set_is_empty", cdecl, gcsafe, raises: [].} =
  if unlikely(set == nil or set.raw == nil):
    return true
  try:
    return set.raw[].isEmpty()
  except:
    return true

# ------------------------------------------------------------------------------
# 6. TaskPool (Work-Stealing Task Scheduler)
# ------------------------------------------------------------------------------

type
  lfq_taskpool* {.exportc: "lfq_taskpool_t".} = object
    raw*: ptr TaskPool

  lfq_taskpool_t* = lfq_taskpool
  lfq_task_fn* = proc(arg: pointer) {.cdecl, gcsafe.}
  lfq_for_task_fn* = proc(index: csize_t, arg: pointer) {.cdecl, gcsafe.}

proc lfq_taskpool_create*(
    num_threads: csize_t,
    out_pool: ptr ptr lfq_taskpool_t
): lfq_status_t {.exportc: "lfq_taskpool_create", cdecl, gcsafe, raises: [].} =
  if unlikely(out_pool == nil):
    return LFQ_ERR_INVALID_ARG
  cAbiBoundary:
    let p = cast[ptr lfq_taskpool_t](allocShared0(sizeof(lfq_taskpool_t)))
    let raw = cast[ptr TaskPool](allocShared0(sizeof(TaskPool)))
    raw[] = initTaskPool(int(num_threads))
    p.raw = raw
    out_pool[] = p
    LFQ_OK

proc lfq_taskpool_destroy*(pool: ptr lfq_taskpool_t): lfq_status_t {.exportc: "lfq_taskpool_destroy", cdecl, gcsafe, raises: [].} =
  if unlikely(pool == nil or pool.raw == nil):
    return LFQ_ERR_INVALID_ARG
  cAbiBoundary:
    `=destroy`(pool.raw[])
    deallocShared(pool.raw)
    deallocShared(pool)
    LFQ_OK

proc lfq_taskpool_spawn*(
    pool: ptr lfq_taskpool_t,
    task: lfq_task_fn,
    arg: pointer
): lfq_status_t {.exportc: "lfq_taskpool_spawn", cdecl, gcsafe, raises: [].} =
  if unlikely(pool == nil or pool.raw == nil or task == nil):
    return LFQ_ERR_INVALID_ARG
  cAbiBoundary:
    pool.raw[].spawn(task, arg)
    LFQ_OK

type
  LfqParallelForAdapter = object
    fn: lfq_for_task_fn
    arg: pointer

proc lfqParallelForHelper(i: int, arg: pointer) {.cdecl, gcsafe.} =
  let adapter = cast[ptr LfqParallelForAdapter](arg)
  if adapter != nil and adapter.fn != nil:
    adapter.fn(csize_t(i), adapter.arg)

proc lfq_taskpool_parallel_for*(
    pool: ptr lfq_taskpool_t,
    start: csize_t,
    stop: csize_t,
    task: lfq_for_task_fn,
    arg: pointer,
    chunk_size: csize_t
): lfq_status_t {.exportc: "lfq_taskpool_parallel_for", cdecl, gcsafe, raises: [].} =
  if unlikely(pool == nil or pool.raw == nil or task == nil or stop < start):
    return LFQ_ERR_INVALID_ARG
  cAbiBoundary:
    var adapter = LfqParallelForAdapter(fn: task, arg: arg)
    pool.raw[].parallelFor(int(start), int(stop), lfqParallelForHelper, cast[pointer](addr adapter), int(chunk_size))
    LFQ_OK

proc lfq_taskpool_sync*(pool: ptr lfq_taskpool_t): lfq_status_t {.exportc: "lfq_taskpool_sync", cdecl, gcsafe, raises: [].} =
  if unlikely(pool == nil or pool.raw == nil):
    return LFQ_ERR_INVALID_ARG
  cAbiBoundary:
    pool.raw[].sync()
    LFQ_OK

proc lfq_taskpool_num_workers*(pool: ptr lfq_taskpool_t): csize_t {.exportc: "lfq_taskpool_num_workers", cdecl, gcsafe, raises: [].} =
  if unlikely(pool == nil or pool.raw == nil):
    return 0
  try:
    csize_t(pool.raw[].numWorkers)
  except:
    0

# ------------------------------------------------------------------------------
# 7. Ctrie (MPMC Concurrent Hash Trie with Wait-Free Snapshots)
# ------------------------------------------------------------------------------

type
  lfq_ctrie* {.exportc: "lfq_ctrie_t".} = object
    destructor*: lfq_entry_destructor_fn
    userData*: pointer
    raw*: ptr Ctrie[pointer, pointer]

  lfq_ctrie_t* = lfq_ctrie

  lfq_ctrie_snapshot_handle* {.exportc: "lfq_ctrie_snapshot_t".} = object
    raw*: ptr Snapshot[pointer, pointer]

  lfq_ctrie_snapshot_t* = lfq_ctrie_snapshot_handle

proc lfq_ctrie_create*(
    destructor: lfq_entry_destructor_fn,
    user_data: pointer,
    out_ctrie: ptr ptr lfq_ctrie_t
): lfq_status_t {.exportc: "lfq_ctrie_create", cdecl, gcsafe, raises: [].} =
  if unlikely(out_ctrie == nil):
    return LFQ_ERR_INVALID_ARG
  cAbiBoundary:
    let c = cast[ptr lfq_ctrie_t](allocShared0(sizeof(lfq_ctrie_t)))
    let raw = cast[ptr Ctrie[pointer, pointer]](allocShared0(sizeof(Ctrie[pointer, pointer])))
    raw[] = initCtrie[pointer, pointer]()
    c.destructor = destructor
    c.userData = user_data
    c.raw = raw
    out_ctrie[] = c
    LFQ_OK

proc lfq_ctrie_destroy*(ctrie: ptr lfq_ctrie_t): lfq_status_t {.exportc: "lfq_ctrie_destroy", cdecl, gcsafe, raises: [].} =
  if unlikely(ctrie == nil or ctrie.raw == nil):
    return LFQ_ERR_INVALID_ARG
  cAbiBoundary:
    if ctrie.destructor != nil:
      try:
        for k, v in ctrie.raw[].pairs:
          ctrie.destructor(k, v, ctrie.userData)
      except:
        discard
    `=destroy`(ctrie.raw[])
    deallocShared(ctrie.raw)
    deallocShared(ctrie)
    LFQ_OK

proc lfq_ctrie_insert*(
    ctrie: ptr lfq_ctrie_t,
    key: pointer,
    val: pointer,
    out_inserted: ptr bool
): lfq_status_t {.exportc: "lfq_ctrie_insert", cdecl, gcsafe, raises: [].} =
  if unlikely(ctrie == nil or ctrie.raw == nil):
    return LFQ_ERR_INVALID_ARG
  cAbiBoundary:
    let prev = ctrie.raw[].put(key, val)
    if out_inserted != nil:
      out_inserted[] = prev.isNone
    LFQ_OK

proc lfq_ctrie_put*(
    ctrie: ptr lfq_ctrie_t,
    key: pointer,
    val: pointer,
    out_inserted: ptr bool
): lfq_status_t {.exportc: "lfq_ctrie_put", cdecl, gcsafe, raises: [].} =
  lfq_ctrie_insert(ctrie, key, val, out_inserted)

proc lfq_ctrie_lookup*(
    ctrie: ptr lfq_ctrie_t,
    key: pointer,
    out_val: ptr pointer
): lfq_status_t {.exportc: "lfq_ctrie_lookup", cdecl, gcsafe, raises: [].} =
  if unlikely(ctrie == nil or ctrie.raw == nil or out_val == nil):
    return LFQ_ERR_INVALID_ARG
  cAbiBoundary:
    let opt = ctrie.raw[].get(key)
    if opt.isSome:
      out_val[] = opt.get
      LFQ_OK
    else:
      LFQ_ERR_EMPTY

proc lfq_ctrie_get*(
    ctrie: ptr lfq_ctrie_t,
    key: pointer,
    out_val: ptr pointer
): lfq_status_t {.exportc: "lfq_ctrie_get", cdecl, gcsafe, raises: [].} =
  lfq_ctrie_lookup(ctrie, key, out_val)

proc lfq_ctrie_remove*(
    ctrie: ptr lfq_ctrie_t,
    key: pointer,
    out_removed: ptr bool
): lfq_status_t {.exportc: "lfq_ctrie_remove", cdecl, gcsafe, raises: [].} =
  if unlikely(ctrie == nil or ctrie.raw == nil):
    return LFQ_ERR_INVALID_ARG
  cAbiBoundary:
    let opt = ctrie.raw[].delete(key)
    let removed = opt.isSome
    if out_removed != nil:
      out_removed[] = removed
    if removed:
      LFQ_OK
    else:
      LFQ_ERR_EMPTY

proc lfq_ctrie_delete*(
    ctrie: ptr lfq_ctrie_t,
    key: pointer,
    out_deleted: ptr bool
): lfq_status_t {.exportc: "lfq_ctrie_delete", cdecl, gcsafe, raises: [].} =
  lfq_ctrie_remove(ctrie, key, out_deleted)

proc lfq_ctrie_contains*(ctrie: ptr lfq_ctrie_t, key: pointer): bool {.exportc: "lfq_ctrie_contains", cdecl, gcsafe, raises: [].} =
  if unlikely(ctrie == nil or ctrie.raw == nil):
    return false
  try:
    ctrie.raw[].contains(key)
  except:
    false

proc lfq_ctrie_len*(ctrie: ptr lfq_ctrie_t): csize_t {.exportc: "lfq_ctrie_len", cdecl, gcsafe, raises: [].} =
  if unlikely(ctrie == nil or ctrie.raw == nil):
    return 0
  try:
    let count = ctrie.raw[].len
    if count < 0: 0.csize_t else: csize_t(count)
  except:
    0

proc lfq_ctrie_is_empty*(ctrie: ptr lfq_ctrie_t): bool {.exportc: "lfq_ctrie_is_empty", cdecl, gcsafe, raises: [].} =
  if unlikely(ctrie == nil or ctrie.raw == nil):
    return true
  try:
    ctrie.raw[].len == 0
  except:
    true

# --- Snapshot procs ---

proc lfq_ctrie_snapshot*(
    ctrie: ptr lfq_ctrie_t,
    out_snapshot: ptr ptr lfq_ctrie_snapshot_t
): lfq_status_t {.exportc: "lfq_ctrie_snapshot", cdecl, gcsafe, raises: [].} =
  if unlikely(ctrie == nil or ctrie.raw == nil or out_snapshot == nil):
    return LFQ_ERR_INVALID_ARG
  cAbiBoundary:
    let snapObj = ctrie.raw[].snapshot()
    let s = cast[ptr lfq_ctrie_snapshot_t](allocShared0(sizeof(lfq_ctrie_snapshot_t)))
    let raw = cast[ptr Snapshot[pointer, pointer]](allocShared0(sizeof(Snapshot[pointer, pointer])))
    raw[] = snapObj
    s.raw = raw
    out_snapshot[] = s
    LFQ_OK

proc lfq_ctrie_snapshot_create*(
    ctrie: ptr lfq_ctrie_t,
    out_snapshot: ptr ptr lfq_ctrie_snapshot_t
): lfq_status_t {.exportc: "lfq_ctrie_snapshot_create", cdecl, gcsafe, raises: [].} =
  lfq_ctrie_snapshot(ctrie, out_snapshot)

proc lfq_ctrie_snapshot_destroy*(snapshot: ptr lfq_ctrie_snapshot_t): lfq_status_t {.exportc: "lfq_ctrie_snapshot_destroy", cdecl, gcsafe, raises: [].} =
  if unlikely(snapshot == nil or snapshot.raw == nil):
    return LFQ_ERR_INVALID_ARG
  cAbiBoundary:
    `=destroy`(snapshot.raw[])
    deallocShared(snapshot.raw)
    deallocShared(snapshot)
    LFQ_OK

proc lfq_ctrie_snapshot_lookup*(
    snapshot: ptr lfq_ctrie_snapshot_t,
    key: pointer,
    out_val: ptr pointer
): lfq_status_t {.exportc: "lfq_ctrie_snapshot_lookup", cdecl, gcsafe, raises: [].} =
  if unlikely(snapshot == nil or snapshot.raw == nil or out_val == nil):
    return LFQ_ERR_INVALID_ARG
  cAbiBoundary:
    let opt = snapshot.raw[].get(key)
    if opt.isSome:
      out_val[] = opt.get
      LFQ_OK
    else:
      LFQ_ERR_EMPTY

proc lfq_ctrie_snapshot_get*(
    snapshot: ptr lfq_ctrie_snapshot_t,
    key: pointer,
    out_val: ptr pointer
): lfq_status_t {.exportc: "lfq_ctrie_snapshot_get", cdecl, gcsafe, raises: [].} =
  lfq_ctrie_snapshot_lookup(snapshot, key, out_val)

proc lfq_ctrie_snapshot_contains*(snapshot: ptr lfq_ctrie_snapshot_t, key: pointer): bool {.exportc: "lfq_ctrie_snapshot_contains", cdecl, gcsafe, raises: [].} =
  if unlikely(snapshot == nil or snapshot.raw == nil):
    return false
  try:
    snapshot.raw[].contains(key)
  except:
    false

proc lfq_ctrie_snapshot_len*(snapshot: ptr lfq_ctrie_snapshot_t): csize_t {.exportc: "lfq_ctrie_snapshot_len", cdecl, gcsafe, raises: [].} =
  if unlikely(snapshot == nil or snapshot.raw == nil):
    return 0
  try:
    let count = snapshot.raw[].len
    if count < 0: 0.csize_t else: csize_t(count)
  except:
    0

proc lfq_ctrie_snapshot_is_empty*(snapshot: ptr lfq_ctrie_snapshot_t): bool {.exportc: "lfq_ctrie_snapshot_is_empty", cdecl, gcsafe, raises: [].} =
  if unlikely(snapshot == nil or snapshot.raw == nil):
    return true
  try:
    snapshot.raw[].len == 0
  except:
    true

# ------------------------------------------------------------------------------
# 8. BroadcastRing (MPMC / SPMC Multicast Broadcast Ring Buffer)
# ------------------------------------------------------------------------------

type
  lfq_overflow_mode_t* {.size: sizeof(cint).} = enum
    LFQ_OVERFLOW_DROP_OLDEST = 0
    LFQ_OVERFLOW_BACKOFF     = 1

  lfq_sub_origin_t* {.size: sizeof(cint).} = enum
    LFQ_SUB_FROM_LATEST   = 0
    LFQ_SUB_FROM_EARLIEST = 1

  lfq_poll_result_t* {.size: sizeof(cint).} = enum
    LFQ_POLL_SUCCESS = 0
    LFQ_POLL_EMPTY   = 1
    LFQ_POLL_LAGGED  = 2

  lfq_broadcast_handle* {.exportc: "lfq_broadcast_t".} = object
    raw*: ptr BroadcastRing[pointer]

  lfq_broadcast_t* = lfq_broadcast_handle

  lfq_broadcast_cursor_handle* {.exportc: "lfq_broadcast_cursor_t".} = object
    raw*: ptr BroadcastCursor[pointer]

  lfq_broadcast_cursor_t* = lfq_broadcast_cursor_handle

proc lfq_broadcast_create*(
    capacity: csize_t,
    overflow_mode: lfq_overflow_mode_t,
    max_readers: csize_t,
    out_broadcast: ptr ptr lfq_broadcast_t
): lfq_status_t {.exportc: "lfq_broadcast_create", cdecl, gcsafe, raises: [].} =
  if unlikely(out_broadcast == nil):
    return LFQ_ERR_INVALID_ARG
  cAbiBoundary:
    let om = if overflow_mode == LFQ_OVERFLOW_BACKOFF: omBackoff else: omDropOldest
    let cap = if capacity == 0: DefaultRingCapacity else: int(capacity)
    let maxR = if max_readers == 0: DefaultMaxReaders else: int(max_readers)
    let b = cast[ptr lfq_broadcast_t](allocShared0(sizeof(lfq_broadcast_t)))
    let raw = cast[ptr BroadcastRing[pointer]](allocShared0(sizeof(BroadcastRing[pointer])))
    raw[] = initBroadcastRing[pointer](cap, om, maxR)
    b.raw = raw
    out_broadcast[] = b
    LFQ_OK

proc lfq_broadcast_destroy*(
    broadcast: ptr lfq_broadcast_t
): lfq_status_t {.exportc: "lfq_broadcast_destroy", cdecl, gcsafe, raises: [].} =
  if unlikely(broadcast == nil or broadcast.raw == nil):
    return LFQ_ERR_INVALID_ARG
  cAbiBoundary:
    {.cast(gcsafe).}:
      `=destroy`(broadcast.raw[])
    deallocShared(broadcast.raw)
    deallocShared(broadcast)
    LFQ_OK

proc lfq_broadcast_publish*(
    broadcast: ptr lfq_broadcast_t,
    item: pointer
): lfq_status_t {.exportc: "lfq_broadcast_publish", cdecl, gcsafe, raises: [].} =
  if unlikely(broadcast == nil or broadcast.raw == nil):
    return LFQ_ERR_INVALID_ARG
  cAbiBoundary:
    broadcast.raw[].publish(item)
    LFQ_OK

proc lfq_broadcast_subscribe*(
    broadcast: ptr lfq_broadcast_t,
    origin: lfq_sub_origin_t,
    out_cursor: ptr ptr lfq_broadcast_cursor_t
): lfq_status_t {.exportc: "lfq_broadcast_subscribe", cdecl, gcsafe, raises: [].} =
  if unlikely(broadcast == nil or broadcast.raw == nil or out_cursor == nil):
    return LFQ_ERR_INVALID_ARG
  cAbiBoundary:
    let so = if origin == LFQ_SUB_FROM_EARLIEST: soFromEarliest else: soFromLatest
    let curObj = broadcast.raw[].subscribe(so)
    let c = cast[ptr lfq_broadcast_cursor_t](allocShared0(sizeof(lfq_broadcast_cursor_t)))
    let raw = cast[ptr BroadcastCursor[pointer]](allocShared0(sizeof(BroadcastCursor[pointer])))
    raw[] = curObj
    c.raw = raw
    out_cursor[] = c
    LFQ_OK

proc lfq_broadcast_unsubscribe*(
    cursor: ptr lfq_broadcast_cursor_t
): lfq_status_t {.exportc: "lfq_broadcast_unsubscribe", cdecl, gcsafe, raises: [].} =
  if unlikely(cursor == nil or cursor.raw == nil):
    return LFQ_ERR_INVALID_ARG
  cAbiBoundary:
    cursor.raw[].unsubscribe()
    {.cast(gcsafe).}:
      `=destroy`(cursor.raw[])
    deallocShared(cursor.raw)
    deallocShared(cursor)
    LFQ_OK

proc lfq_broadcast_poll*(
    cursor: ptr lfq_broadcast_cursor_t,
    out_item: ptr pointer,
    out_skipped_count: ptr csize_t,
    out_result: ptr lfq_poll_result_t
): lfq_status_t {.exportc: "lfq_broadcast_poll", cdecl, gcsafe, raises: [].} =
  if unlikely(cursor == nil or cursor.raw == nil or out_item == nil):
    return LFQ_ERR_INVALID_ARG
  cAbiBoundary:
    let res = cursor.raw[].poll()
    case res.kind
    of prSuccess:
      out_item[] = res.val
      if out_skipped_count != nil:
        out_skipped_count[] = 0
      if out_result != nil:
        out_result[] = LFQ_POLL_SUCCESS
      LFQ_OK
    of prEmpty:
      out_item[] = nil
      if out_skipped_count != nil:
        out_skipped_count[] = 0
      if out_result != nil:
        out_result[] = LFQ_POLL_EMPTY
      LFQ_ERR_EMPTY
    of prLagged:
      out_item[] = nil
      if out_skipped_count != nil:
        out_skipped_count[] = csize_t(res.skippedCount)
      if out_result != nil:
        out_result[] = LFQ_POLL_LAGGED
      LFQ_OK

proc lfq_broadcast_try_read*(
    cursor: ptr lfq_broadcast_cursor_t,
    out_item: ptr pointer
): lfq_status_t {.exportc: "lfq_broadcast_try_read", cdecl, gcsafe, raises: [].} =
  if unlikely(cursor == nil or cursor.raw == nil or out_item == nil):
    return LFQ_ERR_INVALID_ARG
  cAbiBoundary:
    var val: pointer = nil
    if cursor.raw[].tryRead(val):
      out_item[] = val
      LFQ_OK
    else:
      LFQ_ERR_EMPTY

proc lfq_broadcast_len*(
    broadcast: ptr lfq_broadcast_t
): csize_t {.exportc: "lfq_broadcast_len", cdecl, gcsafe, raises: [].} =
  if unlikely(broadcast == nil or broadcast.raw == nil):
    return 0
  try:
    csize_t(broadcast.raw[].len)
  except:
    0

proc lfq_broadcast_capacity*(
    broadcast: ptr lfq_broadcast_t
): csize_t {.exportc: "lfq_broadcast_capacity", cdecl, gcsafe, raises: [].} =
  if unlikely(broadcast == nil or broadcast.raw == nil):
    return 0
  try:
    csize_t(broadcast.raw[].capacity)
  except:
    0

proc lfq_broadcast_subscriber_count*(
    broadcast: ptr lfq_broadcast_t
): csize_t {.exportc: "lfq_broadcast_subscriber_count", cdecl, gcsafe, raises: [].} =
  if unlikely(broadcast == nil or broadcast.raw == nil):
    return 0
  try:
    csize_t(broadcast.raw[].subscriberCount)
  except:
    0

proc lfq_broadcast_is_empty*(
    broadcast: ptr lfq_broadcast_t
): bool {.exportc: "lfq_broadcast_is_empty", cdecl, gcsafe, raises: [].} =
  if unlikely(broadcast == nil or broadcast.raw == nil):
    return true
  try:
    broadcast.raw[].len == 0
  except:
    true

proc lfq_broadcast_cursor_lag*(
    cursor: ptr lfq_broadcast_cursor_t
): csize_t {.exportc: "lfq_broadcast_cursor_lag", cdecl, gcsafe, raises: [].} =
  if unlikely(cursor == nil or cursor.raw == nil):
    return 0
  try:
    csize_t(cursor.raw[].lag)
  except:
    0

# ------------------------------------------------------------------------------
# 9. RendezvousChannel (Zero-Buffer Synchronous Dual Channel)
# ------------------------------------------------------------------------------

type
  lfq_rendezvous_handle {.exportc: "lfq_rendezvous_t".} = object
    raw*: ptr RendezvousChannel[pointer]

  lfq_rendezvous_t* = lfq_rendezvous_handle
  lf_rendezvous_t* = lfq_rendezvous_handle

proc lfq_rendezvous_create*(
    out_chan: ptr ptr lfq_rendezvous_t
): lfq_status_t {.exportc: "lfq_rendezvous_create", cdecl, gcsafe, raises: [].} =
  if unlikely(out_chan == nil):
    return LFQ_ERR_INVALID_ARG
  cAbiBoundary:
    let handle = cast[ptr lfq_rendezvous_t](allocShared0(sizeof(lfq_rendezvous_t)))
    let raw = cast[ptr RendezvousChannel[pointer]](allocShared0(sizeof(RendezvousChannel[pointer])))
    raw[] = initRendezvousChannel[pointer]()
    handle.raw = raw
    out_chan[] = handle
    LFQ_OK

proc lfq_rendezvous_destroy*(
    chan: ptr lfq_rendezvous_t
): lfq_status_t {.exportc: "lfq_rendezvous_destroy", cdecl, gcsafe, raises: [].} =
  if unlikely(chan == nil or chan.raw == nil):
    return LFQ_ERR_INVALID_ARG
  cAbiBoundary:
    {.cast(gcsafe).}:
      `=destroy`(chan.raw[])
    deallocShared(chan.raw)
    deallocShared(chan)
    LFQ_OK

proc lfq_rendezvous_close*(
    chan: ptr lfq_rendezvous_t
): lfq_status_t {.exportc: "lfq_rendezvous_close", cdecl, gcsafe, raises: [].} =
  if unlikely(chan == nil or chan.raw == nil):
    return LFQ_ERR_INVALID_ARG
  cAbiBoundary:
    chan.raw[].close()
    LFQ_OK

proc lfq_rendezvous_is_closed*(
    chan: ptr lfq_rendezvous_t
): bool {.exportc: "lfq_rendezvous_is_closed", cdecl, gcsafe, raises: [].} =
  if unlikely(chan == nil or chan.raw == nil):
    return true
  try:
    chan.raw[].isClosed()
  except:
    true

proc lfq_rendezvous_send*(
    chan: ptr lfq_rendezvous_t,
    payload: pointer,
    out_corr_id: ptr uint64
): lfq_status_t {.exportc: "lfq_rendezvous_send", cdecl, gcsafe, raises: [].} =
  if unlikely(chan == nil or chan.raw == nil):
    return LFQ_ERR_INVALID_ARG
  if unlikely(chan.raw[].isClosed()):
    return LFQ_ERR_CLOSED
  cAbiBoundary:
    let cid = chan.raw[].send(payload)
    if out_corr_id != nil:
      out_corr_id[] = cid
    LFQ_OK

proc lfq_rendezvous_recv*(
    chan: ptr lfq_rendezvous_t,
    out_payload: ptr pointer,
    out_corr_id: ptr uint64
): lfq_status_t {.exportc: "lfq_rendezvous_recv", cdecl, gcsafe, raises: [].} =
  if unlikely(chan == nil or chan.raw == nil or out_payload == nil):
    return LFQ_ERR_INVALID_ARG
  if unlikely(chan.raw[].isClosed()):
    return LFQ_ERR_CLOSED
  cAbiBoundary:
    var val: pointer = nil
    let cid = chan.raw[].recv(val)
    out_payload[] = val
    if out_corr_id != nil:
      out_corr_id[] = cid
    LFQ_OK

proc lfq_rendezvous_try_send*(
    chan: ptr lfq_rendezvous_t,
    payload: pointer,
    out_corr_id: ptr uint64
): lfq_status_t {.exportc: "lfq_rendezvous_try_send", cdecl, gcsafe, raises: [].} =
  if unlikely(chan == nil or chan.raw == nil):
    return LFQ_ERR_INVALID_ARG
  if unlikely(chan.raw[].isClosed()):
    return LFQ_ERR_CLOSED
  cAbiBoundary:
    var cid: uint64 = 0
    if chan.raw[].trySend(payload, cid):
      if out_corr_id != nil:
        out_corr_id[] = cid
      LFQ_OK
    else:
      if chan.raw[].isClosed():
        LFQ_ERR_CLOSED
      else:
        LFQ_ERR_EMPTY

proc lfq_rendezvous_try_recv*(
    chan: ptr lfq_rendezvous_t,
    out_payload: ptr pointer,
    out_corr_id: ptr uint64
): lfq_status_t {.exportc: "lfq_rendezvous_try_recv", cdecl, gcsafe, raises: [].} =
  if unlikely(chan == nil or chan.raw == nil or out_payload == nil):
    return LFQ_ERR_INVALID_ARG
  if unlikely(chan.raw[].isClosed()):
    return LFQ_ERR_CLOSED
  cAbiBoundary:
    var val: pointer = nil
    var cid: uint64 = 0
    if chan.raw[].tryRecv(val, cid):
      out_payload[] = val
      if out_corr_id != nil:
        out_corr_id[] = cid
      LFQ_OK
    else:
      if chan.raw[].isClosed():
        LFQ_ERR_CLOSED
      else:
        LFQ_ERR_EMPTY

proc lfq_rendezvous_send_timeout*(
    chan: ptr lfq_rendezvous_t,
    payload: pointer,
    timeout_ms: int32,
    out_corr_id: ptr uint64
): lfq_status_t {.exportc: "lfq_rendezvous_send_timeout", cdecl, gcsafe, raises: [].} =
  if unlikely(chan == nil or chan.raw == nil):
    return LFQ_ERR_INVALID_ARG
  if unlikely(chan.raw[].isClosed()):
    return LFQ_ERR_CLOSED
  cAbiBoundary:
    var cid: uint64 = 0
    if chan.raw[].sendWithTimeout(payload, int(timeout_ms), cid):
      if out_corr_id != nil:
        out_corr_id[] = cid
      LFQ_OK
    else:
      if chan.raw[].isClosed():
        LFQ_ERR_CLOSED
      else:
        LFQ_ERR_EMPTY

proc lfq_rendezvous_recv_timeout*(
    chan: ptr lfq_rendezvous_t,
    out_payload: ptr pointer,
    timeout_ms: int32,
    out_corr_id: ptr uint64
): lfq_status_t {.exportc: "lfq_rendezvous_recv_timeout", cdecl, gcsafe, raises: [].} =
  if unlikely(chan == nil or chan.raw == nil or out_payload == nil):
    return LFQ_ERR_INVALID_ARG
  if unlikely(chan.raw[].isClosed()):
    return LFQ_ERR_CLOSED
  cAbiBoundary:
    var val: pointer = nil
    var cid: uint64 = 0
    if chan.raw[].recvWithTimeout(val, int(timeout_ms), cid):
      out_payload[] = val
      if out_corr_id != nil:
        out_corr_id[] = cid
      LFQ_OK
    else:
      if chan.raw[].isClosed():
        LFQ_ERR_CLOSED
      else:
        LFQ_ERR_EMPTY

# ------------------------------------------------------------------------------
# Section 9.1 C-Style API Functions
# ------------------------------------------------------------------------------

proc lf_rendezvous_create*(): ptr lfq_rendezvous_t {.exportc: "lf_rendezvous_create", cdecl, gcsafe, raises: [].} =
  var res: ptr lfq_rendezvous_t = nil
  if lfq_rendezvous_create(addr res) == LFQ_OK:
    res
  else:
    nil

proc lf_rendezvous_destroy*(chan: ptr lfq_rendezvous_t) {.exportc: "lf_rendezvous_destroy", cdecl, gcsafe, raises: [].} =
  discard lfq_rendezvous_destroy(chan)

proc lf_rendezvous_close*(chan: ptr lfq_rendezvous_t) {.exportc: "lf_rendezvous_close", cdecl, gcsafe, raises: [].} =
  discard lfq_rendezvous_close(chan)

proc lf_rendezvous_send*(
    chan: ptr lfq_rendezvous_t,
    payload: pointer,
    out_corr_id: ptr uint64
): cint {.exportc: "lf_rendezvous_send", cdecl, gcsafe, raises: [].} =
  cint(lfq_rendezvous_send(chan, payload, out_corr_id))

proc lf_rendezvous_recv*(
    chan: ptr lfq_rendezvous_t,
    out_payload: ptr pointer,
    out_corr_id: ptr uint64
): cint {.exportc: "lf_rendezvous_recv", cdecl, gcsafe, raises: [].} =
  cint(lfq_rendezvous_recv(chan, out_payload, out_corr_id))

proc lf_rendezvous_try_send*(
    chan: ptr lfq_rendezvous_t,
    payload: pointer,
    out_corr_id: ptr uint64
): bool {.exportc: "lf_rendezvous_try_send", cdecl, gcsafe, raises: [].} =
  lfq_rendezvous_try_send(chan, payload, out_corr_id) == LFQ_OK

proc lf_rendezvous_try_recv*(
    chan: ptr lfq_rendezvous_t,
    out_payload: ptr pointer,
    out_corr_id: ptr uint64
): bool {.exportc: "lf_rendezvous_try_recv", cdecl, gcsafe, raises: [].} =
  lfq_rendezvous_try_recv(chan, out_payload, out_corr_id) == LFQ_OK

proc lf_rendezvous_send_timeout*(
    chan: ptr lfq_rendezvous_t,
    payload: pointer,
    timeout_ms: cint,
    out_corr_id: ptr uint64
): bool {.exportc: "lf_rendezvous_send_timeout", cdecl, gcsafe, raises: [].} =
  lfq_rendezvous_send_timeout(chan, payload, int32(timeout_ms), out_corr_id) == LFQ_OK

proc lf_rendezvous_recv_timeout*(
    chan: ptr lfq_rendezvous_t,
    out_payload: ptr pointer,
    timeout_ms: cint,
    out_corr_id: ptr uint64
): bool {.exportc: "lf_rendezvous_recv_timeout", cdecl, gcsafe, raises: [].} =
  lfq_rendezvous_recv_timeout(chan, out_payload, int32(timeout_ms), out_corr_id) == LFQ_OK

# ------------------------------------------------------------------------------
# 10. Rate Limiters (Hardware 128-Bit DWCAS TokenBucket & LeakyBucket)
# ------------------------------------------------------------------------------

proc lfq_token_bucket_create*(
    capacity: uint64,
    refill_rate: uint64
): ptr lfq_token_bucket_t {.exportc: "lfq_token_bucket_create", cdecl, gcsafe, raises: [].} =
  try:
    let p = cast[ptr lfq_token_bucket_t](allocShared0(sizeof(lfq_token_bucket_t)))
    if lfq_token_bucket_init(p, capacity, refill_rate) != 0:
      deallocShared(p)
      return nil
    p
  except:
    nil

proc lfq_token_bucket_destroy*(
    bucket: ptr lfq_token_bucket_t
) {.exportc: "lfq_token_bucket_destroy", cdecl, gcsafe, raises: [].} =
  if bucket != nil:
    deallocShared(bucket)

proc lfq_token_bucket_reset*(
    bucket: ptr lfq_token_bucket_t,
    tokens: uint64
) {.exportc: "lfq_token_bucket_reset", cdecl, gcsafe, raises: [].} =
  if bucket != nil:
    try:
      let tb = cast[ptr TokenBucket](bucket)
      tb[].reset(tokens)
    except:
      discard

proc lfq_leaky_bucket_create*(
    burst_tolerance_ns: uint64,
    leak_rate: uint64
): ptr lfq_leaky_bucket_t {.exportc: "lfq_leaky_bucket_create", cdecl, gcsafe, raises: [].} =
  try:
    let p = cast[ptr lfq_leaky_bucket_t](allocShared0(sizeof(lfq_leaky_bucket_t)))
    if lfq_leaky_bucket_init(p, burst_tolerance_ns, leak_rate) != 0:
      deallocShared(p)
      return nil
    p
  except:
    nil

proc lfq_leaky_bucket_destroy*(
    bucket: ptr lfq_leaky_bucket_t
) {.exportc: "lfq_leaky_bucket_destroy", cdecl, gcsafe, raises: [].} =
  if bucket != nil:
    deallocShared(bucket)

proc lfq_leaky_bucket_reset*(
    bucket: ptr lfq_leaky_bucket_t
) {.exportc: "lfq_leaky_bucket_reset", cdecl, gcsafe, raises: [].} =
  if bucket != nil:
    try:
      let lb = cast[ptr LeakyBucket](bucket)
      lb[].reset()
    except:
      discard

# ------------------------------------------------------------------------------
# 11. StreamRing / StreamBuffer (Zero-Copy Streaming I/O)
# ------------------------------------------------------------------------------

type
  lfq_iovec_slice_t* {.exportc: "lfq_iovec_slice_t", bycopy.} = object
    iov_base*: pointer
    iov_len*: csize_t

  lfq_iovec_pair_t* {.exportc: "lfq_iovec_pair_t", bycopy.} = object
    first*: lfq_iovec_slice_t
    second*: lfq_iovec_slice_t

  lfq_stream_ring_handle* {.exportc: "lfq_stream_ring_t".} = object
    raw*: ptr StreamRing

  lfq_stream_ring_t* = lfq_stream_ring_handle
  lfq_streambuffer_t* = lfq_stream_ring_handle

proc lfq_stream_ring_create*(
    capacity: csize_t,
    use_virtual_mirror: bool
): ptr lfq_stream_ring_t {.exportc: "lfq_stream_ring_create", cdecl, gcsafe, raises: [].} =
  try:
    let handle = cast[ptr lfq_stream_ring_t](allocShared0(sizeof(lfq_stream_ring_t)))
    if handle == nil: return nil
    let raw = cast[ptr StreamRing](allocShared0(sizeof(StreamRing)))
    if raw == nil:
      deallocShared(handle)
      return nil
    let cap = if capacity == 0: DefaultStreamCapacity else: int(capacity)
    raw[] = initStreamRing(cap, use_virtual_mirror)
    handle.raw = raw
    handle
  except:
    nil

proc lfq_stream_ring_destroy*(
    ring: ptr lfq_stream_ring_t
) {.exportc: "lfq_stream_ring_destroy", cdecl, gcsafe, raises: [].} =
  if ring != nil:
    if ring.raw != nil:
      try:
        ring.raw[].destroy()
      except:
        discard
      deallocShared(ring.raw)
      ring.raw = nil
    deallocShared(ring)

proc lfq_streambuffer_create*(
    capacity: csize_t,
    use_virtual_mirror: bool
): ptr lfq_streambuffer_t {.exportc: "lfq_streambuffer_create", cdecl, gcsafe, raises: [].} =
  lfq_stream_ring_create(capacity, use_virtual_mirror)

proc lfq_streambuffer_destroy*(
    ring: ptr lfq_streambuffer_t
) {.exportc: "lfq_streambuffer_destroy", cdecl, gcsafe, raises: [].} =
  lfq_stream_ring_destroy(ring)

proc lfq_stream_ring_capacity*(
    ring: ptr lfq_stream_ring_t
): csize_t {.exportc: "lfq_stream_ring_capacity", cdecl, gcsafe, raises: [].} =
  if ring == nil or ring.raw == nil: return 0
  try:
    csize_t(ring.raw[].capacity())
  except:
    0

proc lfq_stream_ring_available_read*(
    ring: ptr lfq_stream_ring_t
): csize_t {.exportc: "lfq_stream_ring_available_read", cdecl, gcsafe, raises: [].} =
  if ring == nil or ring.raw == nil: return 0
  try:
    csize_t(ring.raw[].availableRead())
  except:
    0

proc lfq_stream_ring_available_write*(
    ring: ptr lfq_stream_ring_t
): csize_t {.exportc: "lfq_stream_ring_available_write", cdecl, gcsafe, raises: [].} =
  if ring == nil or ring.raw == nil: return 0
  try:
    csize_t(ring.raw[].availableWrite())
  except:
    0

proc lfq_stream_ring_is_empty*(
    ring: ptr lfq_stream_ring_t
): bool {.exportc: "lfq_stream_ring_is_empty", cdecl, gcsafe, raises: [].} =
  if ring == nil or ring.raw == nil: return true
  try:
    ring.raw[].isEmpty()
  except:
    true

proc lfq_stream_ring_is_full*(
    ring: ptr lfq_stream_ring_t
): bool {.exportc: "lfq_stream_ring_is_full", cdecl, gcsafe, raises: [].} =
  if ring == nil or ring.raw == nil: return false
  try:
    ring.raw[].isFull()
  except:
    false

proc lfq_streambuffer_capacity*(
    ring: ptr lfq_streambuffer_t
): csize_t {.exportc: "lfq_streambuffer_capacity", cdecl, gcsafe, raises: [].} =
  lfq_stream_ring_capacity(ring)

proc lfq_streambuffer_available_read*(
    ring: ptr lfq_streambuffer_t
): csize_t {.exportc: "lfq_streambuffer_available_read", cdecl, gcsafe, raises: [].} =
  lfq_stream_ring_available_read(ring)

proc lfq_streambuffer_available_write*(
    ring: ptr lfq_streambuffer_t
): csize_t {.exportc: "lfq_streambuffer_available_write", cdecl, gcsafe, raises: [].} =
  lfq_stream_ring_available_write(ring)

proc lfq_streambuffer_is_empty*(
    ring: ptr lfq_streambuffer_t
): bool {.exportc: "lfq_streambuffer_is_empty", cdecl, gcsafe, raises: [].} =
  lfq_stream_ring_is_empty(ring)

proc lfq_streambuffer_is_full*(
    ring: ptr lfq_streambuffer_t
): bool {.exportc: "lfq_streambuffer_is_full", cdecl, gcsafe, raises: [].} =
  lfq_stream_ring_is_full(ring)

proc lfq_stream_ring_try_write*(
    ring: ptr lfq_stream_ring_t,
    src: pointer,
    len: csize_t
): csize_t {.exportc: "lfq_stream_ring_try_write", cdecl, gcsafe, raises: [].} =
  if ring == nil or ring.raw == nil or src == nil or len == 0: return 0
  try:
    let s = cast[ptr UncheckedArray[byte]](src)
    let written = ring.raw[].tryWrite(toOpenArray(s, 0, int(len) - 1))
    csize_t(written)
  except:
    0

proc lfq_stream_ring_try_read*(
    ring: ptr lfq_stream_ring_t,
    dst: pointer,
    max_len: csize_t
): csize_t {.exportc: "lfq_stream_ring_try_read", cdecl, gcsafe, raises: [].} =
  if ring == nil or ring.raw == nil or dst == nil or max_len == 0: return 0
  try:
    let d = cast[ptr UncheckedArray[byte]](dst)
    let readBytes = ring.raw[].tryRead(toOpenArray(d, 0, int(max_len) - 1))
    csize_t(readBytes)
  except:
    0

proc lfq_stream_ring_write_blocking*(
    ring: ptr lfq_stream_ring_t,
    src: pointer,
    len: csize_t,
    timeout_ns: int64
): csize_t {.exportc: "lfq_stream_ring_write_blocking", cdecl, gcsafe, raises: [].} =
  if ring == nil or ring.raw == nil or src == nil or len == 0: return 0
  try:
    let s = cast[ptr UncheckedArray[byte]](src)
    let written = ring.raw[].writeBlocking(toOpenArray(s, 0, int(len) - 1), timeout_ns)
    csize_t(written)
  except:
    0

proc lfq_stream_ring_read_blocking*(
    ring: ptr lfq_stream_ring_t,
    dst: pointer,
    max_len: csize_t,
    timeout_ns: int64
): csize_t {.exportc: "lfq_stream_ring_read_blocking", cdecl, gcsafe, raises: [].} =
  if ring == nil or ring.raw == nil or dst == nil or max_len == 0: return 0
  try:
    let d = cast[ptr UncheckedArray[byte]](dst)
    let readBytes = ring.raw[].readBlocking(toOpenArray(d, 0, int(max_len) - 1), timeout_ns)
    csize_t(readBytes)
  except:
    0

proc lfq_streambuffer_try_write*(
    ring: ptr lfq_streambuffer_t,
    src: pointer,
    len: csize_t
): csize_t {.exportc: "lfq_streambuffer_try_write", cdecl, gcsafe, raises: [].} =
  lfq_stream_ring_try_write(ring, src, len)

proc lfq_streambuffer_try_read*(
    ring: ptr lfq_streambuffer_t,
    dst: pointer,
    max_len: csize_t
): csize_t {.exportc: "lfq_streambuffer_try_read", cdecl, gcsafe, raises: [].} =
  lfq_stream_ring_try_read(ring, dst, max_len)

proc lfq_streambuffer_write_blocking*(
    ring: ptr lfq_streambuffer_t,
    src: pointer,
    len: csize_t,
    timeout_ns: int64
): csize_t {.exportc: "lfq_streambuffer_write_blocking", cdecl, gcsafe, raises: [].} =
  lfq_stream_ring_write_blocking(ring, src, len, timeout_ns)

proc lfq_streambuffer_read_blocking*(
    ring: ptr lfq_streambuffer_t,
    dst: pointer,
    max_len: csize_t,
    timeout_ns: int64
): csize_t {.exportc: "lfq_streambuffer_read_blocking", cdecl, gcsafe, raises: [].} =
  lfq_stream_ring_read_blocking(ring, dst, max_len, timeout_ns)

proc lfq_stream_ring_acquire_write_iov*(
    ring: ptr lfq_stream_ring_t,
    requested_len: csize_t
): lfq_iovec_pair_t {.exportc: "lfq_stream_ring_acquire_write_iov", cdecl, gcsafe, raises: [].} =
  if ring == nil or ring.raw == nil or requested_len == 0:
    return lfq_iovec_pair_t()
  try:
    let iov = ring.raw[].acquireWriteIov(int(requested_len))
    result.first.iov_base = cast[pointer](iov.first.data)
    result.first.iov_len = csize_t(iov.first.len)
    result.second.iov_base = cast[pointer](iov.second.data)
    result.second.iov_len = csize_t(iov.second.len)
  except:
    result = lfq_iovec_pair_t()

proc lfq_stream_ring_commit_write*(
    ring: ptr lfq_stream_ring_t,
    bytes_written: csize_t
) {.exportc: "lfq_stream_ring_commit_write", cdecl, gcsafe, raises: [].} =
  if ring != nil and ring.raw != nil and bytes_written > 0:
    try:
      ring.raw[].commitWrite(int(bytes_written))
    except:
      discard

proc lfq_stream_ring_acquire_read_iov*(
    ring: ptr lfq_stream_ring_t,
    requested_len: csize_t
): lfq_iovec_pair_t {.exportc: "lfq_stream_ring_acquire_read_iov", cdecl, gcsafe, raises: [].} =
  if ring == nil or ring.raw == nil or requested_len == 0:
    return lfq_iovec_pair_t()
  try:
    let iov = ring.raw[].acquireReadIov(int(requested_len))
    result.first.iov_base = cast[pointer](iov.first.data)
    result.first.iov_len = csize_t(iov.first.len)
    result.second.iov_base = cast[pointer](iov.second.data)
    result.second.iov_len = csize_t(iov.second.len)
  except:
    result = lfq_iovec_pair_t()

proc lfq_stream_ring_commit_read*(
    ring: ptr lfq_stream_ring_t,
    bytes_read: csize_t
) {.exportc: "lfq_stream_ring_commit_read", cdecl, gcsafe, raises: [].} =
  if ring != nil and ring.raw != nil and bytes_read > 0:
    try:
      ring.raw[].commitRead(int(bytes_read))
    except:
      discard

proc lfq_streambuffer_acquire_write_iov*(
    ring: ptr lfq_streambuffer_t,
    requested_len: csize_t
): lfq_iovec_pair_t {.exportc: "lfq_streambuffer_acquire_write_iov", cdecl, gcsafe, raises: [].} =
  lfq_stream_ring_acquire_write_iov(ring, requested_len)

proc lfq_streambuffer_commit_write*(
    ring: ptr lfq_streambuffer_t,
    bytes_written: csize_t
) {.exportc: "lfq_streambuffer_commit_write", cdecl, gcsafe, raises: [].} =
  lfq_stream_ring_commit_write(ring, bytes_written)

proc lfq_streambuffer_acquire_read_iov*(
    ring: ptr lfq_streambuffer_t,
    requested_len: csize_t
): lfq_iovec_pair_t {.exportc: "lfq_streambuffer_acquire_read_iov", cdecl, gcsafe, raises: [].} =
  lfq_stream_ring_acquire_read_iov(ring, requested_len)

proc lfq_streambuffer_commit_read*(
    ring: ptr lfq_streambuffer_t,
    bytes_read: csize_t
) {.exportc: "lfq_streambuffer_commit_read", cdecl, gcsafe, raises: [].} =
  lfq_stream_ring_commit_read(ring, bytes_read)

# ------------------------------------------------------------------------------
# 12. Atomic Associative Map Operations (Ctrie & SkipListMap)
# ------------------------------------------------------------------------------

type
  lfq_skiplist_t* = lfq_table_t

  lfq_mapping_fn* = proc(key: pointer, key_len: csize_t, user_data: pointer): pointer {.cdecl, gcsafe.}
  lfq_update_fn* = proc(old_val: pointer, old_val_len: csize_t, user_data: pointer): pointer {.cdecl, gcsafe.}

proc lfq_ctrie_compute_if_absent*(
    trie: ptr lfq_ctrie_t,
    key: pointer,
    key_len: csize_t,
    mapping_fn: lfq_mapping_fn,
    user_data: pointer,
    out_val: ptr pointer,
    out_val_len: ptr csize_t
): bool {.exportc: "lfq_ctrie_compute_if_absent", cdecl, gcsafe, raises: [].} =
  if unlikely(trie == nil or trie.raw == nil or mapping_fn == nil):
    return false
  try:
    let res = trie.raw[].computeIfAbsent(key, proc(k: pointer): pointer =
      mapping_fn(k, key_len, user_data)
    )
    if out_val != nil:
      out_val[] = res
    if out_val_len != nil:
      out_val_len[] = csize_t(sizeof(pointer))
    true
  except:
    false

proc lfq_ctrie_atomic_update*(
    trie: ptr lfq_ctrie_t,
    key: pointer,
    key_len: csize_t,
    update_fn: lfq_update_fn,
    user_data: pointer,
    out_val: ptr pointer,
    out_val_len: ptr csize_t
): bool {.exportc: "lfq_ctrie_atomic_update", cdecl, gcsafe, raises: [].} =
  if unlikely(trie == nil or trie.raw == nil or update_fn == nil):
    return false
  try:
    let opt = trie.raw[].atomicUpdate(key, proc(oldVal: pointer): pointer =
      update_fn(oldVal, csize_t(sizeof(pointer)), user_data)
    )
    if opt.isSome:
      if out_val != nil:
        out_val[] = opt.get
      if out_val_len != nil:
        out_val_len[] = csize_t(sizeof(pointer))
      true
    else:
      false
  except:
    false

proc lfq_skiplist_compute_if_absent*(
    map: ptr lfq_table_t,
    key: pointer,
    key_len: csize_t,
    mapping_fn: lfq_mapping_fn,
    user_data: pointer,
    out_val: ptr pointer,
    out_val_len: ptr csize_t
): bool {.exportc: "lfq_skiplist_compute_if_absent", cdecl, gcsafe, raises: [].} =
  if unlikely(map == nil or map.raw == nil or mapping_fn == nil):
    return false
  try:
    let res = map.raw[].computeIfAbsent(key, proc(k: pointer): pointer =
      mapping_fn(k, key_len, user_data)
    )
    if out_val != nil:
      out_val[] = res
    if out_val_len != nil:
      out_val_len[] = csize_t(sizeof(pointer))
    true
  except:
    false

proc lfq_skiplist_atomic_update*(
    map: ptr lfq_table_t,
    key: pointer,
    key_len: csize_t,
    update_fn: lfq_update_fn,
    user_data: pointer,
    out_val: ptr pointer,
    out_val_len: ptr csize_t
): bool {.exportc: "lfq_skiplist_atomic_update", cdecl, gcsafe, raises: [].} =
  if unlikely(map == nil or map.raw == nil or update_fn == nil):
    return false
  try:
    let opt = map.raw[].atomicUpdate(key, proc(oldVal: pointer): pointer =
      update_fn(oldVal, csize_t(sizeof(pointer)), user_data)
    )
    if opt.isSome:
      if out_val != nil:
        out_val[] = opt.get
      if out_val_len != nil:
        out_val_len[] = csize_t(sizeof(pointer))
      true
    else:
      false
  except:
    false

proc lfq_table_compute_if_absent*(
    map: ptr lfq_table_t,
    key: pointer,
    key_len: csize_t,
    mapping_fn: lfq_mapping_fn,
    user_data: pointer,
    out_val: ptr pointer,
    out_val_len: ptr csize_t
): bool {.exportc: "lfq_table_compute_if_absent", cdecl, gcsafe, raises: [].} =
  lfq_skiplist_compute_if_absent(map, key, key_len, mapping_fn, user_data, out_val, out_val_len)

proc lfq_table_atomic_update*(
    map: ptr lfq_table_t,
    key: pointer,
    key_len: csize_t,
    update_fn: lfq_update_fn,
    user_data: pointer,
    out_val: ptr pointer,
    out_val_len: ptr csize_t
): bool {.exportc: "lfq_table_atomic_update", cdecl, gcsafe, raises: [].} =
  lfq_skiplist_atomic_update(map, key, key_len, update_fn, user_data, out_val, out_val_len)







