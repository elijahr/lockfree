## ==============================================================================
## C ABI / FFI Interop Layer for lockfree
## ==============================================================================
##
## Canonical C99 interface implementation declared in `include/lockfree.h`.
## Wraps bounded (BQueue) and unbounded (Queue) lock-free MPMC queues with:
## - Opaque handles (`lf_queue_t*`, `lf_producer_t*`, `lf_consumer_t*`)
## - Zero-copy 64-bit raw pointer payload transport (`void*` <-> `pointer`)
## - Dynamic thread registration and thread-local slot recycling
## - Optional item cleanup callbacks on queue destroy
## - Strict `cAbiBoundary` exception firewall preventing any Nim exception/panic
##   from escaping across the FFI boundary
## - C99 POSIX consumers using `<pthread.h>` / `<time.h>` (`nanosleep`) under
##   `-std=c99` on glibc should compile with `-D_POSIX_C_SOURCE=199309L`
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
import lockfree/atomic_arc
import lockfree/internal/aligned_alloc
import lockfree/priority_queue
export priority_queue
import lockfree/flat_combiner
export flat_combiner
import lockfree/bstack
export bstack
import lockfree/bpriority_queue
export bpriority_queue
import lockfree/btable
export btable
import lockfree/bqueue128
export bqueue128
import std/options

# ------------------------------------------------------------------------------
# Status Codes & Callback Types
# ------------------------------------------------------------------------------

type
  lf_status_t* {.size: sizeof(cint).} = enum
    LF_ERR_PANIC         = -2
    LF_ERR_FAILURE       = -1
    LF_OK                =  0
    LF_ERR_EMPTY         =  1
    LF_ERR_FULL          =  2
    LF_ERR_CLOSED          =  3
    LF_ERR_INVALID_ARG     =  4
    LF_ERR_REGISTRY_FULL   =  5
    LF_ERR_UNSUPPORTED     =  6

  lfq_status_t* = lf_status_t

const
  LFQ_ERR_PANIC* = LF_ERR_PANIC
  LFQ_ERR_FAILURE* = LF_ERR_FAILURE
  LFQ_OK* = LF_OK
  LFQ_ERR_EMPTY* = LF_ERR_EMPTY
  LFQ_ERR_FULL* = LF_ERR_FULL
  LFQ_ERR_CLOSED* = LF_ERR_CLOSED
  LFQ_ERR_INVALID_ARG* = LF_ERR_INVALID_ARG
  LFQ_ERR_REGISTRY_FULL* = LF_ERR_REGISTRY_FULL
  LFQ_ERR_UNSUPPORTED* = LF_ERR_UNSUPPORTED

type
  lf_item_destructor_fn* = proc(item: pointer, userData: pointer) {.cdecl, gcsafe.}
  lfq_item_destructor_fn* = lf_item_destructor_fn
  lf_entry_destructor_fn* = proc(key: pointer, val: pointer, userData: pointer) {.cdecl, gcsafe.}
  lfq_entry_destructor_fn* = lf_entry_destructor_fn

# ------------------------------------------------------------------------------
# Exception Firewall Template
# ------------------------------------------------------------------------------

template cAbiBoundary(body: untyped): lf_status_t =
  try:
    body
  except NoProducersAvailableError, NoConsumersAvailableError:
    LF_ERR_REGISTRY_FULL
  except ChannelClosedDefect:
    LF_ERR_CLOSED
  except Defect:
    LF_ERR_PANIC
  except Exception:
    LF_ERR_FAILURE

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
  lf_queue* {.exportc: "lf_queue_t".} = object
    destructor*: lf_item_destructor_fn
    userData*: pointer
    maxProducers*: int
    maxConsumers*: int
    activeProducers*: Atomic[int]
    activeConsumers*: Atomic[int]
    isClosed*: Atomic[bool]
    destroyFn*: proc(q: ptr lf_queue_t): lf_status_t {.nimcall, gcsafe, raises: [].}
    producerAcquireFn*: proc(q: ptr lf_queue_t, outProd: ptr ptr lf_producer_t): lf_status_t {.nimcall, gcsafe, raises: [].}
    consumerAcquireFn*: proc(q: ptr lf_queue_t, outCons: ptr ptr lf_consumer_t): lf_status_t {.nimcall, gcsafe, raises: [].}
    lenFn*: proc(q: ptr lf_queue_t): csize_t {.nimcall, gcsafe, raises: [].}
    isEmptyFn*: proc(q: ptr lf_queue_t): bool {.nimcall, gcsafe, raises: [].}

  lf_queue_t* = lf_queue
  lfq_queue* = lf_queue
  lfq_queue_t* = lf_queue

  lf_producer* {.exportc: "lf_producer_t".} = object
    queue*: ptr lf_queue_t
    pushFn*: proc(prod: ptr lf_producer_t, item: pointer): lf_status_t {.nimcall, gcsafe, raises: [].}
    releaseFn*: proc(prod: ptr lf_producer_t): lf_status_t {.nimcall, gcsafe, raises: [].}
    handleManager*: pointer
    handleIdx*: int

  lf_producer_t* = lf_producer
  lfq_producer* = lf_producer
  lfq_producer_t* = lf_producer

  lf_consumer* {.exportc: "lf_consumer_t".} = object
    queue*: ptr lf_queue_t
    popFn*: proc(cons: ptr lf_consumer_t, outItem: ptr pointer): lf_status_t {.nimcall, gcsafe, raises: [].}
    popBatchFn*: proc(cons: ptr lf_consumer_t, outItems: ptr pointer, maxCount: csize_t): csize_t {.nimcall, gcsafe, raises: [].}
    releaseFn*: proc(cons: ptr lf_consumer_t): lf_status_t {.nimcall, gcsafe, raises: [].}
    handleManager*: pointer
    handleIdx*: int

  lf_consumer_t* = lf_consumer
  lfq_consumer* = lf_consumer
  lfq_consumer_t* = lf_consumer

# ------------------------------------------------------------------------------
# Bounded MPMC Implementation (Vyukov BQueue)
# ------------------------------------------------------------------------------

type
  BoundedQueueImpl[N, P, C: static int] = object
    base: lf_queue_t
    rawQueue: ptr BQueue[pointer, ccMulti, ccMulti, N, P, C]

  BoundedProducerImpl[N, P, C: static int] = object
    base: lf_producer_t
    bound: Bound[pointer, AnyThreadTag, BQueue[pointer, ccMulti, ccMulti, N, P, C]]

  BoundedConsumerImpl[N, P, C: static int] = object
    base: lf_consumer_t
    bound: Bound[pointer, AnyThreadTag, BQueue[pointer, ccMulti, ccMulti, N, P, C]]

proc boundedPush[N, P, C: static int](prod: ptr lf_producer_t, item: pointer): lf_status_t {.nimcall, gcsafe, raises: [].} =
  let p = cast[ptr BoundedProducerImpl[N, P, C]](prod)
  cAbiBoundary:
    let ok = p.bound.push(item)
    if ok:
      LF_OK
    else:
      LF_ERR_FULL

proc boundedPop[N, P, C: static int](cons: ptr lf_consumer_t, outItem: ptr pointer): lf_status_t {.nimcall, gcsafe, raises: [].} =
  let c = cast[ptr BoundedConsumerImpl[N, P, C]](cons)
  cAbiBoundary:
    let opt = c.bound.pop()
    if opt.isSome:
      outItem[] = opt.get
      LF_OK
    else:
      LF_ERR_EMPTY

proc boundedPopBatch[N, P, C: static int](
    cons: ptr lf_consumer_t, outItems: ptr pointer, maxCount: csize_t
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

proc boundedProducerRelease[N, P, C: static int](prod: ptr lf_producer_t): lf_status_t {.nimcall, gcsafe, raises: [].} =
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
    LF_OK

proc boundedConsumerRelease[N, P, C: static int](cons: ptr lf_consumer_t): lf_status_t {.nimcall, gcsafe, raises: [].} =
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
    LF_OK

proc boundedProducerAcquire[N, P, C: static int](
    qBase: ptr lf_queue_t, outProd: ptr ptr lf_producer_t
): lf_status_t {.nimcall, gcsafe, raises: [].} =
  let q = cast[ptr BoundedQueueImpl[N, P, C]](qBase)
  if q.base.maxProducers > 0 and q.base.activeProducers.load(moRelaxed) >= q.base.maxProducers:
    return LF_ERR_REGISTRY_FULL
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
    outProd[] = cast[ptr lf_producer_t](p)
    LF_OK

proc boundedConsumerAcquire[N, P, C: static int](
    qBase: ptr lf_queue_t, outCons: ptr ptr lf_consumer_t
): lf_status_t {.nimcall, gcsafe, raises: [].} =
  let q = cast[ptr BoundedQueueImpl[N, P, C]](qBase)
  if q.base.maxConsumers > 0 and q.base.activeConsumers.load(moRelaxed) >= q.base.maxConsumers:
    return LF_ERR_REGISTRY_FULL
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
    outCons[] = cast[ptr lf_consumer_t](c)
    LF_OK

proc boundedQueueLen[N, P, C: static int](qBase: ptr lf_queue_t): csize_t {.nimcall, gcsafe, raises: [].} =
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

proc boundedQueueIsEmpty[N, P, C: static int](qBase: ptr lf_queue_t): bool {.nimcall, gcsafe, raises: [].} =
  let q = cast[ptr BoundedQueueImpl[N, P, C]](qBase)
  try:
    let t = q.rawQueue.tail.load(moRelaxed)
    let h = q.rawQueue.head.load(moRelaxed)
    t <= h
  except:
    true

proc boundedQueueDestroy[N, P, C: static int](qBase: ptr lf_queue_t): lf_status_t {.nimcall, gcsafe, raises: [].} =
  if qBase.activeProducers.load(moAcquire) > 0 or qBase.activeConsumers.load(moAcquire) > 0:
    return LF_ERR_FAILURE
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
    freeAligned(q.rawQueue)
    deallocShared(q)
    LF_OK

proc createBoundedInstance[N, P, C: static int](
    destructor: lf_item_destructor_fn,
    userData: pointer,
    maxProducers: int,
    maxConsumers: int
): ptr lf_queue_t =
  let q = cast[ptr BoundedQueueImpl[N, P, C]](allocShared0(sizeof(BoundedQueueImpl[N, P, C])))
  let raw = allocAligned[BQueue[pointer, ccMulti, ccMulti, N, P, C]]()
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
  return cast[ptr lf_queue_t](q)

# ------------------------------------------------------------------------------
# Unbounded MPMC Implementation (Strict-LCRQ Queue)
# ------------------------------------------------------------------------------

type
  UnboundedQueueImpl[S, MaxThreads: static int] = object
    base: lf_queue_t
    rawQueue: ptr Queue[pointer, ccMulti, ccMulti, stEager, S, MaxThreads]

  UnboundedProducerImpl[S, MaxThreads: static int] = object
    base: lf_producer_t
    bound: Bound[pointer, AnyThreadTag, Queue[pointer, ccMulti, ccMulti, stEager, S, MaxThreads]]

  UnboundedConsumerImpl[S, MaxThreads: static int] = object
    base: lf_consumer_t
    bound: Bound[pointer, AnyThreadTag, Queue[pointer, ccMulti, ccMulti, stEager, S, MaxThreads]]

proc unboundedPush[S, MaxThreads: static int](prod: ptr lf_producer_t, item: pointer): lf_status_t {.nimcall, gcsafe, raises: [].} =
  let p = cast[ptr UnboundedProducerImpl[S, MaxThreads]](prod)
  cAbiBoundary:
    {.cast(gcsafe).}:
      p.bound.push(item)
      LF_OK

proc unboundedPop[S, MaxThreads: static int](cons: ptr lf_consumer_t, outItem: ptr pointer): lf_status_t {.nimcall, gcsafe, raises: [].} =
  let c = cast[ptr UnboundedConsumerImpl[S, MaxThreads]](cons)
  cAbiBoundary:
    {.cast(gcsafe).}:
      let opt = c.bound.pop()
      if opt.isSome:
        outItem[] = opt.get
        LF_OK
      else:
        LF_ERR_EMPTY

proc unboundedPopBatch[S, MaxThreads: static int](
    cons: ptr lf_consumer_t, outItems: ptr pointer, maxCount: csize_t
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

proc unboundedProducerRelease[S, MaxThreads: static int](prod: ptr lf_producer_t): lf_status_t {.nimcall, gcsafe, raises: [].} =
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
      LF_OK

proc unboundedConsumerRelease[S, MaxThreads: static int](cons: ptr lf_consumer_t): lf_status_t {.nimcall, gcsafe, raises: [].} =
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
      LF_OK

proc unboundedProducerAcquire[S, MaxThreads: static int](
    qBase: ptr lf_queue_t, outProd: ptr ptr lf_producer_t
): lf_status_t {.nimcall, gcsafe, raises: [].} =
  let q = cast[ptr UnboundedQueueImpl[S, MaxThreads]](qBase)
  if q.base.maxProducers > 0 and q.base.activeProducers.load(moRelaxed) >= q.base.maxProducers:
    return LF_ERR_REGISTRY_FULL
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
          return LF_ERR_REGISTRY_FULL
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
      outProd[] = cast[ptr lf_producer_t](p)
      LF_OK

proc unboundedConsumerAcquire[S, MaxThreads: static int](
    qBase: ptr lf_queue_t, outCons: ptr ptr lf_consumer_t
): lf_status_t {.nimcall, gcsafe, raises: [].} =
  let q = cast[ptr UnboundedQueueImpl[S, MaxThreads]](qBase)
  if q.base.maxConsumers > 0 and q.base.activeConsumers.load(moRelaxed) >= q.base.maxConsumers:
    return LF_ERR_REGISTRY_FULL
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
          return LF_ERR_REGISTRY_FULL
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
      outCons[] = cast[ptr lf_consumer_t](c)
      LF_OK

proc unboundedQueueLen[S, MaxThreads: static int](qBase: ptr lf_queue_t): csize_t {.nimcall, gcsafe, raises: [].} =
  let q = cast[ptr UnboundedQueueImpl[S, MaxThreads]](qBase)
  try:
    {.cast(gcsafe).}:
      let count = q.rawQueue[].len
      if count < 0: 0.csize_t else: csize_t(count)
  except:
    0

proc unboundedQueueIsEmpty[S, MaxThreads: static int](qBase: ptr lf_queue_t): bool {.nimcall, gcsafe, raises: [].} =
  let q = cast[ptr UnboundedQueueImpl[S, MaxThreads]](qBase)
  try:
    {.cast(gcsafe).}:
      q.rawQueue[].len <= 0
  except:
    true

proc unboundedQueueDestroy[S, MaxThreads: static int](qBase: ptr lf_queue_t): lf_status_t {.nimcall, gcsafe, raises: [].} =
  if qBase.activeProducers.load(moAcquire) > 0 or qBase.activeConsumers.load(moAcquire) > 0:
    return LF_ERR_FAILURE
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
      freeAligned(q.rawQueue)
      deallocShared(q)
      LF_OK


proc createUnboundedInstance[S, MaxThreads: static int](
    destructor: lf_item_destructor_fn,
    userData: pointer,
    maxProducers: int,
    maxConsumers: int
): ptr lf_queue_t =
  let q = cast[ptr UnboundedQueueImpl[S, MaxThreads]](allocShared0(sizeof(UnboundedQueueImpl[S, MaxThreads])))
  let raw = allocAligned[Queue[pointer, ccMulti, ccMulti, stEager, S, MaxThreads]]()
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
  return cast[ptr lf_queue_t](q)

# ------------------------------------------------------------------------------
# Exported Canonical C99 API
# ------------------------------------------------------------------------------

proc lf_unbounded_mpmc_create*(
    segment_size: csize_t,
    max_threads: csize_t,
    destructor: lf_item_destructor_fn,
    user_data: pointer,
    out_queue: ptr ptr lf_queue_t
): lf_status_t {.exportc: "lf_unbounded_mpmc_create", cdecl, gcsafe, raises: [].} =
  if out_queue == nil:
    return LF_ERR_INVALID_ARG

  var seg = int(segment_size)
  var th = int(max_threads)
  if seg == 0: seg = 64
  if th == 0: th = 64

  if seg < 2 or th < 1:
    return LF_ERR_INVALID_ARG

  cAbiBoundary:
    var q: ptr lf_queue_t = nil
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
      return LF_ERR_UNSUPPORTED

    out_queue[] = q
    LF_OK

template dispatchBoundedCapacity(P_TIER, C_TIER: static int, capacity, p, c: int, destructor: lf_item_destructor_fn, user_data: pointer, out_q: var ptr lf_queue_t): lf_status_t =
  if capacity <= 4:
    out_q = createBoundedInstance[4, P_TIER, C_TIER](destructor, user_data, p, c)
    LF_OK
  elif capacity <= 8:
    out_q = createBoundedInstance[8, P_TIER, C_TIER](destructor, user_data, p, c)
    LF_OK
  elif capacity <= 16:
    out_q = createBoundedInstance[16, P_TIER, C_TIER](destructor, user_data, p, c)
    LF_OK
  elif capacity <= 32:
    out_q = createBoundedInstance[32, P_TIER, C_TIER](destructor, user_data, p, c)
    LF_OK
  elif capacity <= 64:
    out_q = createBoundedInstance[64, P_TIER, C_TIER](destructor, user_data, p, c)
    LF_OK
  elif capacity <= 128:
    out_q = createBoundedInstance[128, P_TIER, C_TIER](destructor, user_data, p, c)
    LF_OK
  elif capacity <= 256:
    out_q = createBoundedInstance[256, P_TIER, C_TIER](destructor, user_data, p, c)
    LF_OK
  elif capacity <= 512:
    out_q = createBoundedInstance[512, P_TIER, C_TIER](destructor, user_data, p, c)
    LF_OK
  elif capacity <= 1024:
    out_q = createBoundedInstance[1024, P_TIER, C_TIER](destructor, user_data, p, c)
    LF_OK
  elif capacity <= 2048:
    out_q = createBoundedInstance[2048, P_TIER, C_TIER](destructor, user_data, p, c)
    LF_OK
  elif capacity <= 4096:
    out_q = createBoundedInstance[4096, P_TIER, C_TIER](destructor, user_data, p, c)
    LF_OK
  elif capacity <= 8192:
    out_q = createBoundedInstance[8192, P_TIER, C_TIER](destructor, user_data, p, c)
    LF_OK
  elif capacity <= 16384:
    out_q = createBoundedInstance[16384, P_TIER, C_TIER](destructor, user_data, p, c)
    LF_OK
  elif capacity <= 32768:
    out_q = createBoundedInstance[32768, P_TIER, C_TIER](destructor, user_data, p, c)
    LF_OK
  elif capacity <= 65536:
    out_q = createBoundedInstance[65536, P_TIER, C_TIER](destructor, user_data, p, c)
    LF_OK
  else:
    LF_ERR_UNSUPPORTED

proc lf_bounded_mpmc_create*(
    capacity: csize_t,
    max_producers: csize_t,
    max_consumers: csize_t,
    destructor: lf_item_destructor_fn,
    user_data: pointer,
    out_queue: ptr ptr lf_queue_t
): lf_status_t {.exportc: "lf_bounded_mpmc_create", cdecl, gcsafe, raises: [].} =
  if out_queue == nil or capacity == 0:
    return LF_ERR_INVALID_ARG

  var cap = int(capacity)
  var p = int(max_producers)
  var c = int(max_consumers)
  if p == 0: p = 64
  if c == 0: c = 64

  cAbiBoundary:
    var q: ptr lf_queue_t = nil
    var st: lf_status_t
    if p <= 64 and c <= 64:
      st = dispatchBoundedCapacity(64, 64, cap, p, c, destructor, user_data, q)
    elif p <= 256 and c <= 256:
      st = dispatchBoundedCapacity(256, 256, cap, p, c, destructor, user_data, q)
    else:
      return LF_ERR_UNSUPPORTED

    if st != LF_OK:
      return st

    out_queue[] = q
    LF_OK

proc lf_queue_close*(queue: ptr lf_queue_t): lf_status_t {.exportc: "lf_queue_close", cdecl, gcsafe, raises: [].} =
  if unlikely(queue == nil):
    return LF_ERR_INVALID_ARG
  queue.isClosed.store(true, moRelease)
  return LF_OK

proc lf_queue_destroy*(queue: ptr lf_queue_t): lf_status_t {.exportc: "lf_queue_destroy", cdecl, gcsafe, raises: [].} =
  if unlikely(queue == nil):
    return LF_ERR_INVALID_ARG
  if queue.activeProducers.load(moAcquire) > 0 or queue.activeConsumers.load(moAcquire) > 0:
    return LF_ERR_FAILURE
  cAbiBoundary:
    queue.destroyFn(queue)

proc lf_producer_acquire*(
    queue: ptr lf_queue_t,
    out_prod: ptr ptr lf_producer_t
): lf_status_t {.exportc: "lf_producer_acquire", cdecl, gcsafe, raises: [].} =
  if unlikely(queue == nil or out_prod == nil):
    return LF_ERR_INVALID_ARG
  if unlikely(queue.isClosed.load(moAcquire)):
    return LF_ERR_CLOSED
  cAbiBoundary:
    queue.producerAcquireFn(queue, out_prod)

proc lf_producer_release*(prod: ptr lf_producer_t): lf_status_t {.exportc: "lf_producer_release", cdecl, gcsafe, raises: [].} =
  if unlikely(prod == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    prod.releaseFn(prod)

proc lf_consumer_acquire*(
    queue: ptr lf_queue_t,
    out_cons: ptr ptr lf_consumer_t
): lf_status_t {.exportc: "lf_consumer_acquire", cdecl, gcsafe, raises: [].} =
  if unlikely(queue == nil or out_cons == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    queue.consumerAcquireFn(queue, out_cons)

proc lf_consumer_release*(cons: ptr lf_consumer_t): lf_status_t {.exportc: "lf_consumer_release", cdecl, gcsafe, raises: [].} =
  if unlikely(cons == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    cons.releaseFn(cons)

proc lf_push*(prod: ptr lf_producer_t, item: pointer): lf_status_t {.exportc: "lf_push", cdecl, gcsafe, raises: [].} =
  if unlikely(prod == nil or prod.queue == nil):
    return LF_ERR_INVALID_ARG
  if unlikely(prod.queue.isClosed.load(moAcquire)):
    return LF_ERR_CLOSED
  cAbiBoundary:
    prod.pushFn(prod, item)

proc lf_pop*(cons: ptr lf_consumer_t, out_item: ptr pointer): lf_status_t {.exportc: "lf_pop", cdecl, gcsafe, raises: [].} =
  if unlikely(cons == nil or out_item == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    cons.popFn(cons, out_item)

proc lf_pop_batch*(
    cons: ptr lf_consumer_t,
    out_items: ptr pointer,
    max_count: csize_t
): csize_t {.exportc: "lf_pop_batch", cdecl, gcsafe, raises: [].} =
  if unlikely(cons == nil or out_items == nil or max_count == 0):
    return 0
  try:
    return cons.popBatchFn(cons, out_items, max_count)
  except:
    return 0

proc lf_queue_len*(queue: ptr lf_queue_t): csize_t {.exportc: "lf_queue_len", cdecl, gcsafe, raises: [].} =
  if unlikely(queue == nil):
    return 0
  try:
    return queue.lenFn(queue)
  except:
    return 0

proc lf_queue_is_empty*(queue: ptr lf_queue_t): bool {.exportc: "lf_queue_is_empty", cdecl, gcsafe, raises: [].} =
  if unlikely(queue == nil):
    return true
  try:
    return queue.isEmptyFn(queue)
  except:
    return true

proc lf_queue_is_closed*(queue: ptr lf_queue_t): bool {.exportc: "lf_queue_is_closed", cdecl, gcsafe, raises: [].} =
  if unlikely(queue == nil):
    return true
  return queue.isClosed.load(moAcquire)

proc lf_queue_push*(prod: ptr lf_producer_t, item: pointer): lf_status_t {.exportc: "lf_queue_push", cdecl, gcsafe, raises: [].} =
  lf_push(prod, item)

proc lf_queue_pop*(cons: ptr lf_consumer_t, out_item: ptr pointer): lf_status_t {.exportc: "lf_queue_pop", cdecl, gcsafe, raises: [].} =
  lf_pop(cons, out_item)

# ------------------------------------------------------------------------------
# 2. Stack (MPMC LIFO Stack with Elimination-Backoff)
# ------------------------------------------------------------------------------

type
  lf_stack* {.exportc: "lf_stack_t".} = object
    destructor*: lf_item_destructor_fn
    userData*: pointer
    raw*: ptr TreiberStack[pointer]

  lf_stack_t* = lf_stack
  lfq_stack* = lf_stack
  lfq_stack_t* = lf_stack

proc lf_stack_create*(
    destructor: lf_item_destructor_fn,
    user_data: pointer,
    out_stack: ptr ptr lf_stack_t
): lf_status_t {.exportc: "lf_stack_create", cdecl, gcsafe, raises: [].} =
  if unlikely(out_stack == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    let s = cast[ptr lf_stack_t](allocShared0(sizeof(lf_stack_t)))
    let raw = allocAligned[TreiberStack[pointer]]()
    raw[] = initTreiberStack[pointer]()
    s.destructor = destructor
    s.userData = user_data
    s.raw = raw
    out_stack[] = s
    LF_OK

proc lf_stack_destroy*(stack: ptr lf_stack_t): lf_status_t {.exportc: "lf_stack_destroy", cdecl, gcsafe, raises: [].} =
  if unlikely(stack == nil or stack.raw == nil):
    return LF_ERR_INVALID_ARG
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
    freeAligned(stack.raw)
    deallocShared(stack)
    LF_OK

proc lf_stack_push*(stack: ptr lf_stack_t, item: pointer): lf_status_t {.exportc: "lf_stack_push", cdecl, gcsafe, raises: [].} =
  if unlikely(stack == nil or stack.raw == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    stack.raw[].push(item)
    LF_OK

proc lf_stack_pop*(stack: ptr lf_stack_t, out_item: ptr pointer): lf_status_t {.exportc: "lf_stack_pop", cdecl, gcsafe, raises: [].} =
  if unlikely(stack == nil or stack.raw == nil or out_item == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    let opt = stack.raw[].pop()
    if opt.isSome:
      out_item[] = opt.get
      LF_OK
    else:
      LF_ERR_EMPTY

proc lf_stack_peek*(stack: ptr lf_stack_t, out_item: ptr pointer): lf_status_t {.exportc: "lf_stack_peek", cdecl, gcsafe, raises: [].} =
  if unlikely(stack == nil or stack.raw == nil or out_item == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    let opt = stack.raw[].peek()
    if opt.isSome:
      out_item[] = opt.get
      LF_OK
    else:
      LF_ERR_EMPTY

proc lf_stack_drain*(
    stack: ptr lf_stack_t,
    out_items: ptr pointer,
    max_count: csize_t
): csize_t {.exportc: "lf_stack_drain", cdecl, gcsafe, raises: [].} =
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

proc lf_stack_len*(stack: ptr lf_stack_t): csize_t {.exportc: "lf_stack_len", cdecl, gcsafe, raises: [].} =
  if unlikely(stack == nil or stack.raw == nil):
    return 0
  try:
    let count = stack.raw[].len
    if count < 0: 0.csize_t else: csize_t(count)
  except:
    0

proc lf_stack_is_empty*(stack: ptr lf_stack_t): bool {.exportc: "lf_stack_is_empty", cdecl, gcsafe, raises: [].} =
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
  lf_deque* {.exportc: "lf_deque_t".} = object
    destructor*: lf_item_destructor_fn
    userData*: pointer
    raw*: ptr ChaseLevDeque[pointer]

  lf_deque_t* = lf_deque
  lfq_deque* = lf_deque
  lfq_deque_t* = lf_deque

proc lf_deque_create*(
    initial_capacity: csize_t,
    destructor: lf_item_destructor_fn,
    user_data: pointer,
    out_deque: ptr ptr lf_deque_t
): lf_status_t {.exportc: "lf_deque_create", cdecl, gcsafe, raises: [].} =
  if unlikely(out_deque == nil):
    return LF_ERR_INVALID_ARG
  var cap = int(initial_capacity)
  if cap <= 0: cap = 64
  cAbiBoundary:
    let d = cast[ptr lf_deque_t](allocShared0(sizeof(lf_deque_t)))
    let raw = cast[ptr ChaseLevDeque[pointer]](allocShared0(sizeof(ChaseLevDeque[pointer])))
    raw[] = initChaseLevDeque[pointer](cap)
    d.destructor = destructor
    d.userData = user_data
    d.raw = raw
    out_deque[] = d
    LF_OK

proc lf_deque_destroy*(deque: ptr lf_deque_t): lf_status_t {.exportc: "lf_deque_destroy", cdecl, gcsafe, raises: [].} =
  if unlikely(deque == nil or deque.raw == nil):
    return LF_ERR_INVALID_ARG
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
    LF_OK

proc lf_deque_push*(deque: ptr lf_deque_t, item: pointer): lf_status_t {.exportc: "lf_deque_push", cdecl, gcsafe, raises: [].} =
  if unlikely(deque == nil or deque.raw == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    deque.raw[].pushBottom(item)
    LF_OK

proc lf_deque_pop*(deque: ptr lf_deque_t, out_item: ptr pointer): lf_status_t {.exportc: "lf_deque_pop", cdecl, gcsafe, raises: [].} =
  if unlikely(deque == nil or deque.raw == nil or out_item == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    let opt = deque.raw[].popBottom()
    if opt.isSome:
      out_item[] = opt.get
      LF_OK
    else:
      LF_ERR_EMPTY

proc lf_deque_steal*(deque: ptr lf_deque_t, out_item: ptr pointer): lf_status_t {.exportc: "lf_deque_steal", cdecl, gcsafe, raises: [].} =
  if unlikely(deque == nil or deque.raw == nil or out_item == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    let opt = deque.raw[].steal()
    if opt.isSome:
      out_item[] = opt.get
      LF_OK
    else:
      LF_ERR_EMPTY

proc lf_deque_steal_batch*(
    deque: ptr lf_deque_t,
    out_items: ptr pointer,
    max_count: csize_t
): csize_t {.exportc: "lf_deque_steal_batch", cdecl, gcsafe, raises: [].} =
  if unlikely(deque == nil or deque.raw == nil or out_items == nil or max_count == 0):
    return 0
  let arr = cast[ptr UncheckedArray[pointer]](out_items)
  try:
    let n = deque.raw[].stealBatch(toOpenArray(arr, 0, int(max_count) - 1), int(max_count))
    return csize_t(n)
  except:
    return 0

proc lf_deque_len*(deque: ptr lf_deque_t): csize_t {.exportc: "lf_deque_len", cdecl, gcsafe, raises: [].} =
  if unlikely(deque == nil or deque.raw == nil):
    return 0
  try:
    let count = deque.raw[].len
    if count < 0: 0.csize_t else: csize_t(count)
  except:
    0

proc lf_deque_capacity*(deque: ptr lf_deque_t): csize_t {.exportc: "lf_deque_capacity", cdecl, gcsafe, raises: [].} =
  if unlikely(deque == nil or deque.raw == nil):
    return 0
  try:
    let cap = deque.raw[].capacity
    if cap < 0: 0.csize_t else: csize_t(cap)
  except:
    0

proc lf_deque_is_empty*(deque: ptr lf_deque_t): bool {.exportc: "lf_deque_is_empty", cdecl, gcsafe, raises: [].} =
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
  lf_table* {.exportc: "lf_table_t".} = object
    destructor*: lf_entry_destructor_fn
    userData*: pointer
    raw*: ptr SkipListMap[pointer, pointer]

  lf_table_t* = lf_table
  lfq_table* = lf_table
  lfq_table_t* = lf_table

proc lf_table_create*(
    destructor: lf_entry_destructor_fn,
    user_data: pointer,
    out_table: ptr ptr lf_table_t
): lf_status_t {.exportc: "lf_table_create", cdecl, gcsafe, raises: [].} =
  if unlikely(out_table == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    let t = cast[ptr lf_table_t](allocShared0(sizeof(lf_table_t)))
    let raw = cast[ptr SkipListMap[pointer, pointer]](allocShared0(sizeof(SkipListMap[pointer, pointer])))
    raw[] = initSkipListMap[pointer, pointer]()
    t.destructor = destructor
    t.userData = user_data
    t.raw = raw
    out_table[] = t
    LF_OK

proc lf_table_destroy*(table: ptr lf_table_t): lf_status_t {.exportc: "lf_table_destroy", cdecl, gcsafe, raises: [].} =
  if unlikely(table == nil or table.raw == nil):
    return LF_ERR_INVALID_ARG
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
    LF_OK

proc lf_table_put*(
    table: ptr lf_table_t,
    key: pointer,
    val: pointer,
    out_inserted: ptr bool
): lf_status_t {.exportc: "lf_table_put", cdecl, gcsafe, raises: [].} =
  if unlikely(table == nil or table.raw == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    let inserted = table.raw[].put(key, val)
    if out_inserted != nil:
      out_inserted[] = inserted
    LF_OK

proc lf_table_get*(
    table: ptr lf_table_t,
    key: pointer,
    out_val: ptr pointer
): lf_status_t {.exportc: "lf_table_get", cdecl, gcsafe, raises: [].} =
  if unlikely(table == nil or table.raw == nil or out_val == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    let opt = table.raw[].get(key)
    if opt.isSome:
      out_val[] = opt.get
      LF_OK
    else:
      LF_ERR_EMPTY

proc lf_table_delete*(
    table: ptr lf_table_t,
    key: pointer,
    out_deleted: ptr bool
): lf_status_t {.exportc: "lf_table_delete", cdecl, gcsafe, raises: [].} =
  if unlikely(table == nil or table.raw == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    let deleted = table.raw[].delete(key)
    if out_deleted != nil:
      out_deleted[] = deleted
    if deleted:
      LF_OK
    else:
      LF_ERR_EMPTY

proc lf_table_remove*(
    table: ptr lf_table_t,
    key: pointer,
    out_removed: ptr bool
): lf_status_t {.exportc: "lf_table_remove", cdecl, gcsafe, raises: [].} =
  lf_table_delete(table, key, out_removed)

proc lf_table_contains*(table: ptr lf_table_t, key: pointer): bool {.exportc: "lf_table_contains", cdecl, gcsafe, raises: [].} =
  if unlikely(table == nil or table.raw == nil):
    return false
  try:
    return table.raw[].contains(key)
  except:
    return false

proc lf_table_len*(table: ptr lf_table_t): csize_t {.exportc: "lf_table_len", cdecl, gcsafe, raises: [].} =
  if unlikely(table == nil or table.raw == nil):
    return 0
  try:
    let count = table.raw[].len
    if count < 0: 0.csize_t else: csize_t(count)
  except:
    0

proc lf_table_is_empty*(table: ptr lf_table_t): bool {.exportc: "lf_table_is_empty", cdecl, gcsafe, raises: [].} =
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
  lf_set* {.exportc: "lf_set_t".} = object
    destructor*: lf_item_destructor_fn
    userData*: pointer
    raw*: ptr SkipListSet[pointer]

  lf_set_t* = lf_set
  lfq_set* = lf_set
  lfq_set_t* = lf_set

proc lf_set_create*(
    destructor: lf_item_destructor_fn,
    user_data: pointer,
    out_set: ptr ptr lf_set_t
): lf_status_t {.exportc: "lf_set_create", cdecl, gcsafe, raises: [].} =
  if unlikely(out_set == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    let s = cast[ptr lf_set_t](allocShared0(sizeof(lf_set_t)))
    let raw = cast[ptr SkipListSet[pointer]](allocShared0(sizeof(SkipListSet[pointer])))
    raw[] = initSkipListSet[pointer]()
    s.destructor = destructor
    s.userData = user_data
    s.raw = raw
    out_set[] = s
    LF_OK

proc lf_set_destroy*(set: ptr lf_set_t): lf_status_t {.exportc: "lf_set_destroy", cdecl, gcsafe, raises: [].} =
  if unlikely(set == nil or set.raw == nil):
    return LF_ERR_INVALID_ARG
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
    LF_OK

proc lf_set_insert*(
    set: ptr lf_set_t,
    item: pointer,
    out_inserted: ptr bool
): lf_status_t {.exportc: "lf_set_insert", cdecl, gcsafe, raises: [].} =
  if unlikely(set == nil or set.raw == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    let inserted = set.raw[].insert(item)
    if out_inserted != nil:
      out_inserted[] = inserted
    LF_OK

proc lf_set_remove*(
    set: ptr lf_set_t,
    item: pointer,
    out_removed: ptr bool
): lf_status_t {.exportc: "lf_set_remove", cdecl, gcsafe, raises: [].} =
  if unlikely(set == nil or set.raw == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    let removed = set.raw[].remove(item)
    if out_removed != nil:
      out_removed[] = removed
    if removed:
      LF_OK
    else:
      LF_ERR_EMPTY

proc lf_set_contains*(set: ptr lf_set_t, item: pointer): bool {.exportc: "lf_set_contains", cdecl, gcsafe, raises: [].} =
  if unlikely(set == nil or set.raw == nil):
    return false
  try:
    return set.raw[].contains(item)
  except:
    return false

proc lf_set_len*(set: ptr lf_set_t): csize_t {.exportc: "lf_set_len", cdecl, gcsafe, raises: [].} =
  if unlikely(set == nil or set.raw == nil):
    return 0
  try:
    let count = set.raw[].len
    if count < 0: 0.csize_t else: csize_t(count)
  except:
    0

proc lf_set_is_empty*(set: ptr lf_set_t): bool {.exportc: "lf_set_is_empty", cdecl, gcsafe, raises: [].} =
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
  lf_taskpool* {.exportc: "lf_taskpool_t".} = object
    raw*: ptr TaskPool

  lf_taskpool_t* = lf_taskpool
  lfq_taskpool* = lf_taskpool
  lfq_taskpool_t* = lf_taskpool
  lf_task_fn* = proc(arg: pointer) {.cdecl, gcsafe.}
  lfq_task_fn* = lf_task_fn
  lf_for_task_fn* = proc(index: csize_t, arg: pointer) {.cdecl, gcsafe.}
  lfq_for_task_fn* = lf_for_task_fn

proc lf_taskpool_create*(
    num_threads: csize_t,
    out_pool: ptr ptr lf_taskpool_t
): lf_status_t {.exportc: "lf_taskpool_create", cdecl, gcsafe, raises: [].} =
  if unlikely(out_pool == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    let p = cast[ptr lf_taskpool_t](allocShared0(sizeof(lf_taskpool_t)))
    let raw = cast[ptr TaskPool](allocShared0(sizeof(TaskPool)))
    raw[] = initTaskPool(int(num_threads))
    p.raw = raw
    out_pool[] = p
    LF_OK

proc lf_taskpool_destroy*(pool: ptr lf_taskpool_t): lf_status_t {.exportc: "lf_taskpool_destroy", cdecl, gcsafe, raises: [].} =
  if unlikely(pool == nil or pool.raw == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    `=destroy`(pool.raw[])
    deallocShared(pool.raw)
    deallocShared(pool)
    LF_OK

proc lf_taskpool_spawn*(
    pool: ptr lf_taskpool_t,
    task: lf_task_fn,
    arg: pointer
): lf_status_t {.exportc: "lf_taskpool_spawn", cdecl, gcsafe, raises: [].} =
  if unlikely(pool == nil or pool.raw == nil or task == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    pool.raw[].spawn(task, arg)
    LF_OK

type
  LfqParallelForAdapter = object
    fn: lf_for_task_fn
    arg: pointer

proc lfqParallelForHelper(i: int, arg: pointer) {.cdecl, gcsafe.} =
  let adapter = cast[ptr LfqParallelForAdapter](arg)
  if adapter != nil and adapter.fn != nil:
    adapter.fn(csize_t(i), adapter.arg)

proc lf_taskpool_parallel_for*(
    pool: ptr lf_taskpool_t,
    start: csize_t,
    stop: csize_t,
    task: lf_for_task_fn,
    arg: pointer,
    chunk_size: csize_t
): lf_status_t {.exportc: "lf_taskpool_parallel_for", cdecl, gcsafe, raises: [].} =
  if unlikely(pool == nil or pool.raw == nil or task == nil or stop < start):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    var adapter = LfqParallelForAdapter(fn: task, arg: arg)
    pool.raw[].parallelFor(int(start), int(stop), lfqParallelForHelper, cast[pointer](addr adapter), int(chunk_size))
    LF_OK

proc lf_taskpool_sync*(pool: ptr lf_taskpool_t): lf_status_t {.exportc: "lf_taskpool_sync", cdecl, gcsafe, raises: [].} =
  if unlikely(pool == nil or pool.raw == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    pool.raw[].sync()
    LF_OK

proc lf_taskpool_num_workers*(pool: ptr lf_taskpool_t): csize_t {.exportc: "lf_taskpool_num_workers", cdecl, gcsafe, raises: [].} =
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
  lf_ctrie* {.exportc: "lf_ctrie_t".} = object
    destructor*: lf_entry_destructor_fn
    userData*: pointer
    raw*: ptr Ctrie[pointer, pointer]

  lf_ctrie_t* = lf_ctrie
  lfq_ctrie* = lf_ctrie
  lfq_ctrie_t* = lf_ctrie

  lf_ctrie_snapshot_handle* {.exportc: "lf_ctrie_snapshot_t".} = object
    raw*: ptr Snapshot[pointer, pointer]

  lf_ctrie_snapshot_t* = lf_ctrie_snapshot_handle
  lfq_ctrie_snapshot_handle* = lf_ctrie_snapshot_handle
  lfq_ctrie_snapshot_t* = lf_ctrie_snapshot_handle

proc lf_ctrie_create*(
    destructor: lf_entry_destructor_fn,
    user_data: pointer,
    out_ctrie: ptr ptr lf_ctrie_t
): lf_status_t {.exportc: "lf_ctrie_create", cdecl, gcsafe, raises: [].} =
  if unlikely(out_ctrie == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    let c = cast[ptr lf_ctrie_t](allocShared0(sizeof(lf_ctrie_t)))
    let raw = cast[ptr Ctrie[pointer, pointer]](allocShared0(sizeof(Ctrie[pointer, pointer])))
    raw[] = initCtrie[pointer, pointer]()
    c.destructor = destructor
    c.userData = user_data
    c.raw = raw
    out_ctrie[] = c
    LF_OK

proc lf_ctrie_destroy*(ctrie: ptr lf_ctrie_t): lf_status_t {.exportc: "lf_ctrie_destroy", cdecl, gcsafe, raises: [].} =
  if unlikely(ctrie == nil or ctrie.raw == nil):
    return LF_ERR_INVALID_ARG
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
    LF_OK

proc lf_ctrie_insert*(
    ctrie: ptr lf_ctrie_t,
    key: pointer,
    val: pointer,
    out_inserted: ptr bool
): lf_status_t {.exportc: "lf_ctrie_insert", cdecl, gcsafe, raises: [].} =
  if unlikely(ctrie == nil or ctrie.raw == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    let prev = ctrie.raw[].put(key, val)
    if out_inserted != nil:
      out_inserted[] = prev.isNone
    LF_OK

proc lf_ctrie_put*(
    ctrie: ptr lf_ctrie_t,
    key: pointer,
    val: pointer,
    out_inserted: ptr bool
): lf_status_t {.exportc: "lf_ctrie_put", cdecl, gcsafe, raises: [].} =
  lf_ctrie_insert(ctrie, key, val, out_inserted)

proc lf_ctrie_lookup*(
    ctrie: ptr lf_ctrie_t,
    key: pointer,
    out_val: ptr pointer
): lf_status_t {.exportc: "lf_ctrie_lookup", cdecl, gcsafe, raises: [].} =
  if unlikely(ctrie == nil or ctrie.raw == nil or out_val == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    let opt = ctrie.raw[].get(key)
    if opt.isSome:
      out_val[] = opt.get
      LF_OK
    else:
      LF_ERR_EMPTY

proc lf_ctrie_get*(
    ctrie: ptr lf_ctrie_t,
    key: pointer,
    out_val: ptr pointer
): lf_status_t {.exportc: "lf_ctrie_get", cdecl, gcsafe, raises: [].} =
  lf_ctrie_lookup(ctrie, key, out_val)

proc lf_ctrie_remove*(
    ctrie: ptr lf_ctrie_t,
    key: pointer,
    out_removed: ptr bool
): lf_status_t {.exportc: "lf_ctrie_remove", cdecl, gcsafe, raises: [].} =
  if unlikely(ctrie == nil or ctrie.raw == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    let opt = ctrie.raw[].delete(key)
    let removed = opt.isSome
    if out_removed != nil:
      out_removed[] = removed
    if removed:
      LF_OK
    else:
      LF_ERR_EMPTY

proc lf_ctrie_delete*(
    ctrie: ptr lf_ctrie_t,
    key: pointer,
    out_deleted: ptr bool
): lf_status_t {.exportc: "lf_ctrie_delete", cdecl, gcsafe, raises: [].} =
  lf_ctrie_remove(ctrie, key, out_deleted)

proc lf_ctrie_contains*(ctrie: ptr lf_ctrie_t, key: pointer): bool {.exportc: "lf_ctrie_contains", cdecl, gcsafe, raises: [].} =
  if unlikely(ctrie == nil or ctrie.raw == nil):
    return false
  try:
    ctrie.raw[].contains(key)
  except:
    false

proc lf_ctrie_len*(ctrie: ptr lf_ctrie_t): csize_t {.exportc: "lf_ctrie_len", cdecl, gcsafe, raises: [].} =
  if unlikely(ctrie == nil or ctrie.raw == nil):
    return 0
  try:
    let count = ctrie.raw[].len
    if count < 0: 0.csize_t else: csize_t(count)
  except:
    0

proc lf_ctrie_is_empty*(ctrie: ptr lf_ctrie_t): bool {.exportc: "lf_ctrie_is_empty", cdecl, gcsafe, raises: [].} =
  if unlikely(ctrie == nil or ctrie.raw == nil):
    return true
  try:
    ctrie.raw[].len == 0
  except:
    true

# --- Snapshot procs ---

proc lf_ctrie_snapshot*(
    ctrie: ptr lf_ctrie_t,
    out_snapshot: ptr ptr lf_ctrie_snapshot_t
): lf_status_t {.exportc: "lf_ctrie_snapshot", cdecl, gcsafe, raises: [].} =
  if unlikely(ctrie == nil or ctrie.raw == nil or out_snapshot == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    let snapObj = ctrie.raw[].snapshot()
    let s = cast[ptr lf_ctrie_snapshot_t](allocShared0(sizeof(lf_ctrie_snapshot_t)))
    let raw = cast[ptr Snapshot[pointer, pointer]](allocShared0(sizeof(Snapshot[pointer, pointer])))
    raw[] = snapObj
    s.raw = raw
    out_snapshot[] = s
    LF_OK

proc lf_ctrie_snapshot_create*(
    ctrie: ptr lf_ctrie_t,
    out_snapshot: ptr ptr lf_ctrie_snapshot_t
): lf_status_t {.exportc: "lf_ctrie_snapshot_create", cdecl, gcsafe, raises: [].} =
  lf_ctrie_snapshot(ctrie, out_snapshot)

proc lf_ctrie_snapshot_destroy*(snapshot: ptr lf_ctrie_snapshot_t): lf_status_t {.exportc: "lf_ctrie_snapshot_destroy", cdecl, gcsafe, raises: [].} =
  if unlikely(snapshot == nil or snapshot.raw == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    `=destroy`(snapshot.raw[])
    deallocShared(snapshot.raw)
    deallocShared(snapshot)
    LF_OK

proc lf_ctrie_snapshot_lookup*(
    snapshot: ptr lf_ctrie_snapshot_t,
    key: pointer,
    out_val: ptr pointer
): lf_status_t {.exportc: "lf_ctrie_snapshot_lookup", cdecl, gcsafe, raises: [].} =
  if unlikely(snapshot == nil or snapshot.raw == nil or out_val == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    let opt = snapshot.raw[].get(key)
    if opt.isSome:
      out_val[] = opt.get
      LF_OK
    else:
      LF_ERR_EMPTY

proc lf_ctrie_snapshot_get*(
    snapshot: ptr lf_ctrie_snapshot_t,
    key: pointer,
    out_val: ptr pointer
): lf_status_t {.exportc: "lf_ctrie_snapshot_get", cdecl, gcsafe, raises: [].} =
  lf_ctrie_snapshot_lookup(snapshot, key, out_val)

proc lf_ctrie_snapshot_contains*(snapshot: ptr lf_ctrie_snapshot_t, key: pointer): bool {.exportc: "lf_ctrie_snapshot_contains", cdecl, gcsafe, raises: [].} =
  if unlikely(snapshot == nil or snapshot.raw == nil):
    return false
  try:
    snapshot.raw[].contains(key)
  except:
    false

proc lf_ctrie_snapshot_len*(snapshot: ptr lf_ctrie_snapshot_t): csize_t {.exportc: "lf_ctrie_snapshot_len", cdecl, gcsafe, raises: [].} =
  if unlikely(snapshot == nil or snapshot.raw == nil):
    return 0
  try:
    let count = snapshot.raw[].len
    if count < 0: 0.csize_t else: csize_t(count)
  except:
    0

proc lf_ctrie_snapshot_is_empty*(snapshot: ptr lf_ctrie_snapshot_t): bool {.exportc: "lf_ctrie_snapshot_is_empty", cdecl, gcsafe, raises: [].} =
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
  lf_overflow_mode_t* {.size: sizeof(cint).} = enum
    LF_OVERFLOW_DROP_OLDEST = 0
    LF_OVERFLOW_BACKOFF     = 1
  lfq_overflow_mode_t* = lf_overflow_mode_t

  lf_sub_origin_t* {.size: sizeof(cint).} = enum
    LF_SUB_FROM_LATEST   = 0
    LF_SUB_FROM_EARLIEST = 1
  lfq_sub_origin_t* = lf_sub_origin_t

  lf_poll_result_t* {.size: sizeof(cint).} = enum
    LF_POLL_SUCCESS = 0
    LF_POLL_EMPTY   = 1
    LF_POLL_LAGGED  = 2
  lfq_poll_result_t* = lf_poll_result_t

const
  LFQ_OVERFLOW_DROP_OLDEST* = LF_OVERFLOW_DROP_OLDEST
  LFQ_OVERFLOW_BACKOFF*     = LF_OVERFLOW_BACKOFF
  LFQ_SUB_FROM_LATEST*      = LF_SUB_FROM_LATEST
  LFQ_SUB_FROM_EARLIEST*    = LF_SUB_FROM_EARLIEST
  LFQ_POLL_SUCCESS*         = LF_POLL_SUCCESS
  LFQ_POLL_EMPTY*           = LF_POLL_EMPTY
  LFQ_POLL_LAGGED*          = LF_POLL_LAGGED

type
  lf_broadcast_handle* {.exportc: "lf_broadcast_t".} = object
    raw*: ptr BroadcastRing[pointer]

  lf_broadcast_t* = lf_broadcast_handle
  lfq_broadcast_handle* = lf_broadcast_handle
  lfq_broadcast_t* = lf_broadcast_handle

  lf_broadcast_cursor_handle* {.exportc: "lf_broadcast_cursor_t".} = object
    raw*: ptr BroadcastCursor[pointer]

  lf_broadcast_cursor_t* = lf_broadcast_cursor_handle
  lfq_broadcast_cursor_handle* = lf_broadcast_cursor_handle
  lfq_broadcast_cursor_t* = lf_broadcast_cursor_handle

proc lf_broadcast_create*(
    capacity: csize_t,
    overflow_mode: lf_overflow_mode_t,
    max_readers: csize_t,
    out_broadcast: ptr ptr lf_broadcast_t
): lf_status_t {.exportc: "lf_broadcast_create", cdecl, gcsafe, raises: [].} =
  if unlikely(out_broadcast == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    let om = if overflow_mode == LF_OVERFLOW_BACKOFF: omBackoff else: omDropOldest
    let cap = if capacity == 0: DefaultRingCapacity else: int(capacity)
    let maxR = if max_readers == 0: DefaultMaxReaders else: int(max_readers)
    let b = cast[ptr lf_broadcast_t](allocShared0(sizeof(lf_broadcast_t)))
    let raw = cast[ptr BroadcastRing[pointer]](allocShared0(sizeof(BroadcastRing[pointer])))
    raw[] = initBroadcastRing[pointer](cap, om, maxR)
    b.raw = raw
    out_broadcast[] = b
    LF_OK

proc lf_broadcast_destroy*(
    broadcast: ptr lf_broadcast_t
): lf_status_t {.exportc: "lf_broadcast_destroy", cdecl, gcsafe, raises: [].} =
  if unlikely(broadcast == nil or broadcast.raw == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    {.cast(gcsafe).}:
      `=destroy`(broadcast.raw[])
    deallocShared(broadcast.raw)
    deallocShared(broadcast)
    LF_OK

proc lf_broadcast_publish*(
    broadcast: ptr lf_broadcast_t,
    item: pointer
): lf_status_t {.exportc: "lf_broadcast_publish", cdecl, gcsafe, raises: [].} =
  if unlikely(broadcast == nil or broadcast.raw == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    broadcast.raw[].publish(item)
    LF_OK

proc lf_broadcast_subscribe*(
    broadcast: ptr lf_broadcast_t,
    origin: lf_sub_origin_t,
    out_cursor: ptr ptr lf_broadcast_cursor_t
): lf_status_t {.exportc: "lf_broadcast_subscribe", cdecl, gcsafe, raises: [].} =
  if unlikely(broadcast == nil or broadcast.raw == nil or out_cursor == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    let so = if origin == LF_SUB_FROM_EARLIEST: soFromEarliest else: soFromLatest
    let curObj = broadcast.raw[].subscribe(so)
    let c = cast[ptr lf_broadcast_cursor_t](allocShared0(sizeof(lf_broadcast_cursor_t)))
    let raw = cast[ptr BroadcastCursor[pointer]](allocShared0(sizeof(BroadcastCursor[pointer])))
    raw[] = curObj
    c.raw = raw
    out_cursor[] = c
    LF_OK

proc lf_broadcast_unsubscribe*(
    cursor: ptr lf_broadcast_cursor_t
): lf_status_t {.exportc: "lf_broadcast_unsubscribe", cdecl, gcsafe, raises: [].} =
  if unlikely(cursor == nil or cursor.raw == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    cursor.raw[].unsubscribe()
    {.cast(gcsafe).}:
      `=destroy`(cursor.raw[])
    deallocShared(cursor.raw)
    deallocShared(cursor)
    LF_OK

proc lf_broadcast_poll*(
    cursor: ptr lf_broadcast_cursor_t,
    out_item: ptr pointer,
    out_skipped_count: ptr csize_t,
    out_result: ptr lf_poll_result_t
): lf_status_t {.exportc: "lf_broadcast_poll", cdecl, gcsafe, raises: [].} =
  if unlikely(cursor == nil or cursor.raw == nil or out_item == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    let res = cursor.raw[].poll()
    case res.kind
    of prSuccess:
      out_item[] = res.val
      if out_skipped_count != nil:
        out_skipped_count[] = 0
      if out_result != nil:
        out_result[] = LF_POLL_SUCCESS
      LF_OK
    of prEmpty:
      out_item[] = nil
      if out_skipped_count != nil:
        out_skipped_count[] = 0
      if out_result != nil:
        out_result[] = LF_POLL_EMPTY
      LF_ERR_EMPTY
    of prLagged:
      out_item[] = nil
      if out_skipped_count != nil:
        out_skipped_count[] = csize_t(res.skippedCount)
      if out_result != nil:
        out_result[] = LF_POLL_LAGGED
      LF_OK

proc lf_broadcast_try_read*(
    cursor: ptr lf_broadcast_cursor_t,
    out_item: ptr pointer
): lf_status_t {.exportc: "lf_broadcast_try_read", cdecl, gcsafe, raises: [].} =
  if unlikely(cursor == nil or cursor.raw == nil or out_item == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    var val: pointer = nil
    if cursor.raw[].tryRead(val):
      out_item[] = val
      LF_OK
    else:
      LF_ERR_EMPTY

proc lf_broadcast_len*(
    broadcast: ptr lf_broadcast_t
): csize_t {.exportc: "lf_broadcast_len", cdecl, gcsafe, raises: [].} =
  if unlikely(broadcast == nil or broadcast.raw == nil):
    return 0
  try:
    csize_t(broadcast.raw[].len)
  except:
    0

proc lf_broadcast_capacity*(
    broadcast: ptr lf_broadcast_t
): csize_t {.exportc: "lf_broadcast_capacity", cdecl, gcsafe, raises: [].} =
  if unlikely(broadcast == nil or broadcast.raw == nil):
    return 0
  try:
    csize_t(broadcast.raw[].capacity)
  except:
    0

proc lf_broadcast_subscriber_count*(
    broadcast: ptr lf_broadcast_t
): csize_t {.exportc: "lf_broadcast_subscriber_count", cdecl, gcsafe, raises: [].} =
  if unlikely(broadcast == nil or broadcast.raw == nil):
    return 0
  try:
    csize_t(broadcast.raw[].subscriberCount)
  except:
    0

proc lf_broadcast_is_empty*(
    broadcast: ptr lf_broadcast_t
): bool {.exportc: "lf_broadcast_is_empty", cdecl, gcsafe, raises: [].} =
  if unlikely(broadcast == nil or broadcast.raw == nil):
    return true
  try:
    broadcast.raw[].len == 0
  except:
    true

proc lf_broadcast_cursor_lag*(
    cursor: ptr lf_broadcast_cursor_t
): csize_t {.exportc: "lf_broadcast_cursor_lag", cdecl, gcsafe, raises: [].} =
  if unlikely(cursor == nil or cursor.raw == nil):
    return 0
  try:
    csize_t(cursor.raw[].lag)
  except:
    0

# ------------------------------------------------------------------------------
# 8b. TopicBus (Concurrent Multi-Topic Broadcast Bus backed by Ctrie)
# ------------------------------------------------------------------------------

type
  lf_topic_bus_handle* {.exportc: "lf_topic_bus_t".} = object
    raw*: ptr TopicBus[pointer]

  lf_topic_bus_t* = lf_topic_bus_handle
  lfq_topic_bus_handle* = lf_topic_bus_handle
  lfq_topic_bus_t* = lf_topic_bus_handle

proc lf_topic_bus_create*(
    default_capacity: csize_t,
    default_overflow_mode: lf_overflow_mode_t,
    default_max_readers: csize_t,
    out_bus: ptr ptr lf_topic_bus_t
): lf_status_t {.exportc: "lf_topic_bus_create", cdecl, gcsafe, raises: [].} =
  if unlikely(out_bus == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    let om = if default_overflow_mode == LF_OVERFLOW_BACKOFF: omBackoff else: omDropOldest
    let cap = if default_capacity == 0: DefaultRingCapacity else: int(default_capacity)
    let maxR = if default_max_readers == 0: DefaultMaxReaders else: int(default_max_readers)
    let cfg = TopicBusConfig(
      defaultRingCapacity: cap,
      defaultOverflowMode: om,
      defaultMaxReaders: maxR
    )
    let handle = cast[ptr lf_topic_bus_t](allocShared0(sizeof(lf_topic_bus_t)))
    let raw = cast[ptr TopicBus[pointer]](allocShared0(sizeof(TopicBus[pointer])))
    raw[] = initTopicBus[pointer](cfg)
    handle.raw = raw
    out_bus[] = handle
    LF_OK

proc lf_topic_bus_destroy*(
    bus: ptr lf_topic_bus_t
): lf_status_t {.exportc: "lf_topic_bus_destroy", cdecl, gcsafe, raises: [].} =
  if unlikely(bus == nil or bus.raw == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    {.cast(gcsafe).}:
      `=destroy`(bus.raw[])
    deallocShared(bus.raw)
    deallocShared(bus)
    LF_OK

proc lf_topic_bus_publish*(
    bus: ptr lf_topic_bus_t,
    topic: cstring,
    item: pointer
): lf_status_t {.exportc: "lf_topic_bus_publish", cdecl, gcsafe, raises: [].} =
  if unlikely(bus == nil or bus.raw == nil or topic == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    bus.raw[].publish($topic, item)
    LF_OK

proc lf_topic_bus_subscribe*(
    bus: ptr lf_topic_bus_t,
    topic: cstring,
    origin: lf_sub_origin_t,
    out_cursor: ptr ptr lf_broadcast_cursor_t
): lf_status_t {.exportc: "lf_topic_bus_subscribe", cdecl, gcsafe, raises: [].} =
  if unlikely(bus == nil or bus.raw == nil or topic == nil or out_cursor == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    let so = if origin == LF_SUB_FROM_EARLIEST: soFromEarliest else: soFromLatest
    let curObj = bus.raw[].subscribe($topic, so)
    let c = cast[ptr lf_broadcast_cursor_t](allocShared0(sizeof(lf_broadcast_cursor_t)))
    let raw = cast[ptr BroadcastCursor[pointer]](allocShared0(sizeof(BroadcastCursor[pointer])))
    raw[] = curObj
    c.raw = raw
    out_cursor[] = c
    LF_OK

proc lf_topic_bus_topic_count*(
    bus: ptr lf_topic_bus_t
): csize_t {.exportc: "lf_topic_bus_topic_count", cdecl, gcsafe, raises: [].} =
  if unlikely(bus == nil or bus.raw == nil):
    return 0
  try:
    csize_t(bus.raw[].topicCount)
  except:
    0

proc lf_topic_bus_has_topic*(
    bus: ptr lf_topic_bus_t,
    topic: cstring
): bool {.exportc: "lf_topic_bus_has_topic", cdecl, gcsafe, raises: [].} =
  if unlikely(bus == nil or bus.raw == nil or topic == nil):
    return false
  try:
    bus.raw[].hasTopic($topic)
  except:
    false

# ------------------------------------------------------------------------------
# 9. RendezvousChannel (Zero-Buffer Synchronous Dual Channel)
# ------------------------------------------------------------------------------

type
  lf_rendezvous_handle {.exportc: "lf_rendezvous_t".} = object
    raw*: ptr RendezvousChannel[pointer]

  lf_rendezvous_t* = lf_rendezvous_handle
  lfq_rendezvous_handle* = lf_rendezvous_handle
  lfq_rendezvous_t* = lf_rendezvous_handle

proc lf_rendezvous_create*(
    out_chan: ptr ptr lf_rendezvous_t
): lf_status_t {.exportc: "lf_rendezvous_create", cdecl, gcsafe, raises: [].} =
  if unlikely(out_chan == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    let handle = cast[ptr lf_rendezvous_t](allocShared0(sizeof(lf_rendezvous_t)))
    let raw = cast[ptr RendezvousChannel[pointer]](allocShared0(sizeof(RendezvousChannel[pointer])))
    raw[] = initRendezvousChannel[pointer]()
    handle.raw = raw
    out_chan[] = handle
    LF_OK

proc lf_rendezvous_destroy*(
    chan: ptr lf_rendezvous_t
): lf_status_t {.exportc: "lf_rendezvous_destroy", cdecl, gcsafe, raises: [].} =
  if unlikely(chan == nil or chan.raw == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    {.cast(gcsafe).}:
      `=destroy`(chan.raw[])
    deallocShared(chan.raw)
    deallocShared(chan)
    LF_OK

proc lf_rendezvous_close*(
    chan: ptr lf_rendezvous_t
): lf_status_t {.exportc: "lf_rendezvous_close", cdecl, gcsafe, raises: [].} =
  if unlikely(chan == nil or chan.raw == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    chan.raw[].close()
    LF_OK

proc lf_rendezvous_is_closed*(
    chan: ptr lf_rendezvous_t
): bool {.exportc: "lf_rendezvous_is_closed", cdecl, gcsafe, raises: [].} =
  if unlikely(chan == nil or chan.raw == nil):
    return true
  try:
    chan.raw[].isClosed()
  except:
    true

proc lf_rendezvous_send*(
    chan: ptr lf_rendezvous_t,
    payload: pointer,
    out_corr_id: ptr uint64
): lf_status_t {.exportc: "lf_rendezvous_send", cdecl, gcsafe, raises: [].} =
  if unlikely(chan == nil or chan.raw == nil):
    return LF_ERR_INVALID_ARG
  if unlikely(chan.raw[].isClosed()):
    return LF_ERR_CLOSED
  cAbiBoundary:
    let cid = chan.raw[].send(payload)
    if out_corr_id != nil:
      out_corr_id[] = cid
    LF_OK

proc lf_rendezvous_recv*(
    chan: ptr lf_rendezvous_t,
    out_payload: ptr pointer,
    out_corr_id: ptr uint64
): lf_status_t {.exportc: "lf_rendezvous_recv", cdecl, gcsafe, raises: [].} =
  if unlikely(chan == nil or chan.raw == nil or out_payload == nil):
    return LF_ERR_INVALID_ARG
  if unlikely(chan.raw[].isClosed()):
    return LF_ERR_CLOSED
  cAbiBoundary:
    var val: pointer = nil
    let cid = chan.raw[].recv(val)
    out_payload[] = val
    if out_corr_id != nil:
      out_corr_id[] = cid
    LF_OK

proc lf_rendezvous_try_send*(
    chan: ptr lf_rendezvous_t,
    payload: pointer,
    out_corr_id: ptr uint64
): lf_status_t {.exportc: "lf_rendezvous_try_send", cdecl, gcsafe, raises: [].} =
  if unlikely(chan == nil or chan.raw == nil):
    return LF_ERR_INVALID_ARG
  if unlikely(chan.raw[].isClosed()):
    return LF_ERR_CLOSED
  cAbiBoundary:
    var cid: uint64 = 0
    if chan.raw[].trySend(payload, cid):
      if out_corr_id != nil:
        out_corr_id[] = cid
      LF_OK
    else:
      if chan.raw[].isClosed():
        LF_ERR_CLOSED
      else:
        LF_ERR_EMPTY

proc lf_rendezvous_try_recv*(
    chan: ptr lf_rendezvous_t,
    out_payload: ptr pointer,
    out_corr_id: ptr uint64
): lf_status_t {.exportc: "lf_rendezvous_try_recv", cdecl, gcsafe, raises: [].} =
  if unlikely(chan == nil or chan.raw == nil or out_payload == nil):
    return LF_ERR_INVALID_ARG
  if unlikely(chan.raw[].isClosed()):
    return LF_ERR_CLOSED
  cAbiBoundary:
    var val: pointer = nil
    var cid: uint64 = 0
    if chan.raw[].tryRecv(val, cid):
      out_payload[] = val
      if out_corr_id != nil:
        out_corr_id[] = cid
      LF_OK
    else:
      if chan.raw[].isClosed():
        LF_ERR_CLOSED
      else:
        LF_ERR_EMPTY

proc lf_rendezvous_send_timeout*(
    chan: ptr lf_rendezvous_t,
    payload: pointer,
    timeout_ms: int32,
    out_corr_id: ptr uint64
): lf_status_t {.exportc: "lf_rendezvous_send_timeout", cdecl, gcsafe, raises: [].} =
  if unlikely(chan == nil or chan.raw == nil):
    return LF_ERR_INVALID_ARG
  if unlikely(chan.raw[].isClosed()):
    return LF_ERR_CLOSED
  cAbiBoundary:
    var cid: uint64 = 0
    if chan.raw[].sendWithTimeout(payload, int(timeout_ms), cid):
      if out_corr_id != nil:
        out_corr_id[] = cid
      LF_OK
    else:
      if chan.raw[].isClosed():
        LF_ERR_CLOSED
      else:
        LF_ERR_EMPTY

proc lf_rendezvous_recv_timeout*(
    chan: ptr lf_rendezvous_t,
    out_payload: ptr pointer,
    timeout_ms: int32,
    out_corr_id: ptr uint64
): lf_status_t {.exportc: "lf_rendezvous_recv_timeout", cdecl, gcsafe, raises: [].} =
  if unlikely(chan == nil or chan.raw == nil or out_payload == nil):
    return LF_ERR_INVALID_ARG
  if unlikely(chan.raw[].isClosed()):
    return LF_ERR_CLOSED
  cAbiBoundary:
    var val: pointer = nil
    var cid: uint64 = 0
    if chan.raw[].recvWithTimeout(val, int(timeout_ms), cid):
      out_payload[] = val
      if out_corr_id != nil:
        out_corr_id[] = cid
      LF_OK
    else:
      if chan.raw[].isClosed():
        LF_ERR_CLOSED
      else:
        LF_ERR_EMPTY

# ------------------------------------------------------------------------------
# 10. Rate Limiters (Hardware 128-Bit DWCAS TokenBucket & LeakyBucket)
# ------------------------------------------------------------------------------

proc lf_token_bucket_create*(
    capacity: uint64,
    refill_rate: uint64
): ptr lf_token_bucket_t {.exportc: "lf_token_bucket_create", cdecl, gcsafe, raises: [].} =
  try:
    let p = cast[ptr lf_token_bucket_t](allocShared0(sizeof(lf_token_bucket_t)))
    if lfq_token_bucket_init(p, capacity, refill_rate) != 0:
      deallocShared(p)
      return nil
    p
  except:
    nil

proc lf_token_bucket_destroy*(
    bucket: ptr lf_token_bucket_t
) {.exportc: "lf_token_bucket_destroy", cdecl, gcsafe, raises: [].} =
  if bucket != nil:
    deallocShared(bucket)

proc lf_token_bucket_reset*(
    bucket: ptr lf_token_bucket_t,
    tokens: uint64
) {.exportc: "lf_token_bucket_reset", cdecl, gcsafe, raises: [].} =
  if bucket != nil:
    try:
      let tb = cast[ptr TokenBucket](bucket)
      tb[].reset(tokens)
    except:
      discard

proc lf_leaky_bucket_create*(
    burst_tolerance_ns: uint64,
    leak_rate: uint64
): ptr lf_leaky_bucket_t {.exportc: "lf_leaky_bucket_create", cdecl, gcsafe, raises: [].} =
  try:
    let p = cast[ptr lf_leaky_bucket_t](allocShared0(sizeof(lf_leaky_bucket_t)))
    if lfq_leaky_bucket_init(p, burst_tolerance_ns, leak_rate) != 0:
      deallocShared(p)
      return nil
    p
  except:
    nil

proc lf_leaky_bucket_destroy*(
    bucket: ptr lf_leaky_bucket_t
) {.exportc: "lf_leaky_bucket_destroy", cdecl, gcsafe, raises: [].} =
  if bucket != nil:
    deallocShared(bucket)

proc lf_leaky_bucket_reset*(
    bucket: ptr lf_leaky_bucket_t
) {.exportc: "lf_leaky_bucket_reset", cdecl, gcsafe, raises: [].} =
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
  lf_iovec_slice_t* {.exportc: "lf_iovec_slice_t", bycopy.} = object
    iov_base*: pointer
    iov_len*: csize_t
  lfq_iovec_slice_t* = lf_iovec_slice_t

  lf_iovec_pair_t* {.exportc: "lf_iovec_pair_t", bycopy.} = object
    first*: lf_iovec_slice_t
    second*: lf_iovec_slice_t
  lfq_iovec_pair_t* = lf_iovec_pair_t

  lf_stream_ring_handle* {.exportc: "lf_stream_ring_t".} = object
    raw*: ptr StreamRing

  lf_stream_ring_t* = lf_stream_ring_handle
  lfq_stream_ring_handle* = lf_stream_ring_handle
  lfq_stream_ring_t* = lf_stream_ring_handle
  lf_streambuffer_t* = lf_stream_ring_handle
  lfq_streambuffer_t* = lf_stream_ring_handle

proc lf_stream_ring_create*(
    capacity: csize_t,
    use_virtual_mirror: bool
): ptr lf_stream_ring_t {.exportc: "lf_stream_ring_create", cdecl, gcsafe, raises: [].} =
  try:
    let handle = cast[ptr lf_stream_ring_t](allocShared0(sizeof(lf_stream_ring_t)))
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

proc lf_stream_ring_destroy*(
    ring: ptr lf_stream_ring_t
) {.exportc: "lf_stream_ring_destroy", cdecl, gcsafe, raises: [].} =
  if ring != nil:
    if ring.raw != nil:
      try:
        ring.raw[].destroy()
      except:
        discard
      deallocShared(ring.raw)
      ring.raw = nil
    deallocShared(ring)

proc lf_streambuffer_create*(
    capacity: csize_t,
    use_virtual_mirror: bool
): ptr lf_streambuffer_t {.exportc: "lf_streambuffer_create", cdecl, gcsafe, raises: [].} =
  lf_stream_ring_create(capacity, use_virtual_mirror)

proc lf_streambuffer_destroy*(
    ring: ptr lf_streambuffer_t
) {.exportc: "lf_streambuffer_destroy", cdecl, gcsafe, raises: [].} =
  lf_stream_ring_destroy(ring)

proc lf_stream_ring_capacity*(
    ring: ptr lf_stream_ring_t
): csize_t {.exportc: "lf_stream_ring_capacity", cdecl, gcsafe, raises: [].} =
  if ring == nil or ring.raw == nil: return 0
  try:
    csize_t(ring.raw[].capacity())
  except:
    0

proc lf_stream_ring_available_read*(
    ring: ptr lf_stream_ring_t
): csize_t {.exportc: "lf_stream_ring_available_read", cdecl, gcsafe, raises: [].} =
  if ring == nil or ring.raw == nil: return 0
  try:
    csize_t(ring.raw[].availableRead())
  except:
    0

proc lf_stream_ring_available_write*(
    ring: ptr lf_stream_ring_t
): csize_t {.exportc: "lf_stream_ring_available_write", cdecl, gcsafe, raises: [].} =
  if ring == nil or ring.raw == nil: return 0
  try:
    csize_t(ring.raw[].availableWrite())
  except:
    0

proc lf_stream_ring_is_empty*(
    ring: ptr lf_stream_ring_t
): bool {.exportc: "lf_stream_ring_is_empty", cdecl, gcsafe, raises: [].} =
  if ring == nil or ring.raw == nil: return true
  try:
    ring.raw[].isEmpty()
  except:
    true

proc lf_stream_ring_is_full*(
    ring: ptr lf_stream_ring_t
): bool {.exportc: "lf_stream_ring_is_full", cdecl, gcsafe, raises: [].} =
  if ring == nil or ring.raw == nil: return false
  try:
    ring.raw[].isFull()
  except:
    false

proc lf_streambuffer_capacity*(
    ring: ptr lf_streambuffer_t
): csize_t {.exportc: "lf_streambuffer_capacity", cdecl, gcsafe, raises: [].} =
  lf_stream_ring_capacity(ring)

proc lf_streambuffer_available_read*(
    ring: ptr lf_streambuffer_t
): csize_t {.exportc: "lf_streambuffer_available_read", cdecl, gcsafe, raises: [].} =
  lf_stream_ring_available_read(ring)

proc lf_streambuffer_available_write*(
    ring: ptr lf_streambuffer_t
): csize_t {.exportc: "lf_streambuffer_available_write", cdecl, gcsafe, raises: [].} =
  lf_stream_ring_available_write(ring)

proc lf_streambuffer_is_empty*(
    ring: ptr lf_streambuffer_t
): bool {.exportc: "lf_streambuffer_is_empty", cdecl, gcsafe, raises: [].} =
  lf_stream_ring_is_empty(ring)

proc lf_streambuffer_is_full*(
    ring: ptr lf_streambuffer_t
): bool {.exportc: "lf_streambuffer_is_full", cdecl, gcsafe, raises: [].} =
  lf_stream_ring_is_full(ring)

proc lf_stream_ring_try_write*(
    ring: ptr lf_stream_ring_t,
    src: pointer,
    len: csize_t
): csize_t {.exportc: "lf_stream_ring_try_write", cdecl, gcsafe, raises: [].} =
  if ring == nil or ring.raw == nil or src == nil or len == 0: return 0
  try:
    let s = cast[ptr UncheckedArray[byte]](src)
    let written = ring.raw[].tryWrite(toOpenArray(s, 0, int(len) - 1))
    csize_t(written)
  except:
    0

proc lf_stream_ring_try_read*(
    ring: ptr lf_stream_ring_t,
    dst: pointer,
    max_len: csize_t
): csize_t {.exportc: "lf_stream_ring_try_read", cdecl, gcsafe, raises: [].} =
  if ring == nil or ring.raw == nil or dst == nil or max_len == 0: return 0
  try:
    let d = cast[ptr UncheckedArray[byte]](dst)
    let readBytes = ring.raw[].tryRead(toOpenArray(d, 0, int(max_len) - 1))
    csize_t(readBytes)
  except:
    0

proc lf_stream_ring_write_blocking*(
    ring: ptr lf_stream_ring_t,
    src: pointer,
    len: csize_t,
    timeout_ns: int64
): csize_t {.exportc: "lf_stream_ring_write_blocking", cdecl, gcsafe, raises: [].} =
  if ring == nil or ring.raw == nil or src == nil or len == 0: return 0
  try:
    let s = cast[ptr UncheckedArray[byte]](src)
    let written = ring.raw[].writeBlocking(toOpenArray(s, 0, int(len) - 1), timeout_ns)
    csize_t(written)
  except:
    0

proc lf_stream_ring_read_blocking*(
    ring: ptr lf_stream_ring_t,
    dst: pointer,
    max_len: csize_t,
    timeout_ns: int64
): csize_t {.exportc: "lf_stream_ring_read_blocking", cdecl, gcsafe, raises: [].} =
  if ring == nil or ring.raw == nil or dst == nil or max_len == 0: return 0
  try:
    let d = cast[ptr UncheckedArray[byte]](dst)
    let readBytes = ring.raw[].readBlocking(toOpenArray(d, 0, int(max_len) - 1), timeout_ns)
    csize_t(readBytes)
  except:
    0

proc lf_streambuffer_try_write*(
    ring: ptr lf_streambuffer_t,
    src: pointer,
    len: csize_t
): csize_t {.exportc: "lf_streambuffer_try_write", cdecl, gcsafe, raises: [].} =
  lf_stream_ring_try_write(ring, src, len)

proc lf_streambuffer_try_read*(
    ring: ptr lf_streambuffer_t,
    dst: pointer,
    max_len: csize_t
): csize_t {.exportc: "lf_streambuffer_try_read", cdecl, gcsafe, raises: [].} =
  lf_stream_ring_try_read(ring, dst, max_len)

proc lf_streambuffer_write_blocking*(
    ring: ptr lf_streambuffer_t,
    src: pointer,
    len: csize_t,
    timeout_ns: int64
): csize_t {.exportc: "lf_streambuffer_write_blocking", cdecl, gcsafe, raises: [].} =
  lf_stream_ring_write_blocking(ring, src, len, timeout_ns)

proc lf_streambuffer_read_blocking*(
    ring: ptr lf_streambuffer_t,
    dst: pointer,
    max_len: csize_t,
    timeout_ns: int64
): csize_t {.exportc: "lf_streambuffer_read_blocking", cdecl, gcsafe, raises: [].} =
  lf_stream_ring_read_blocking(ring, dst, max_len, timeout_ns)

proc lf_stream_ring_acquire_write_iov*(
    ring: ptr lf_stream_ring_t,
    requested_len: csize_t
): lf_iovec_pair_t {.exportc: "lf_stream_ring_acquire_write_iov", cdecl, gcsafe, raises: [].} =
  if ring == nil or ring.raw == nil or requested_len == 0:
    return lf_iovec_pair_t()
  try:
    let iov = ring.raw[].acquireWriteIov(int(requested_len))
    result.first.iov_base = cast[pointer](iov.first.data)
    result.first.iov_len = csize_t(iov.first.len)
    result.second.iov_base = cast[pointer](iov.second.data)
    result.second.iov_len = csize_t(iov.second.len)
  except:
    result = lf_iovec_pair_t()

proc lf_stream_ring_commit_write*(
    ring: ptr lf_stream_ring_t,
    bytes_written: csize_t
) {.exportc: "lf_stream_ring_commit_write", cdecl, gcsafe, raises: [].} =
  if ring != nil and ring.raw != nil and bytes_written > 0:
    try:
      ring.raw[].commitWrite(int(bytes_written))
    except:
      discard

proc lf_stream_ring_acquire_read_iov*(
    ring: ptr lf_stream_ring_t,
    requested_len: csize_t
): lf_iovec_pair_t {.exportc: "lf_stream_ring_acquire_read_iov", cdecl, gcsafe, raises: [].} =
  if ring == nil or ring.raw == nil or requested_len == 0:
    return lf_iovec_pair_t()
  try:
    let iov = ring.raw[].acquireReadIov(int(requested_len))
    result.first.iov_base = cast[pointer](iov.first.data)
    result.first.iov_len = csize_t(iov.first.len)
    result.second.iov_base = cast[pointer](iov.second.data)
    result.second.iov_len = csize_t(iov.second.len)
  except:
    result = lf_iovec_pair_t()

proc lf_stream_ring_commit_read*(
    ring: ptr lf_stream_ring_t,
    bytes_read: csize_t
) {.exportc: "lf_stream_ring_commit_read", cdecl, gcsafe, raises: [].} =
  if ring != nil and ring.raw != nil and bytes_read > 0:
    try:
      ring.raw[].commitRead(int(bytes_read))
    except:
      discard

proc lf_streambuffer_acquire_write_iov*(
    ring: ptr lf_streambuffer_t,
    requested_len: csize_t
): lf_iovec_pair_t {.exportc: "lf_streambuffer_acquire_write_iov", cdecl, gcsafe, raises: [].} =
  lf_stream_ring_acquire_write_iov(ring, requested_len)

proc lf_streambuffer_commit_write*(
    ring: ptr lf_streambuffer_t,
    bytes_written: csize_t
) {.exportc: "lf_streambuffer_commit_write", cdecl, gcsafe, raises: [].} =
  lf_stream_ring_commit_write(ring, bytes_written)

proc lf_streambuffer_acquire_read_iov*(
    ring: ptr lf_streambuffer_t,
    requested_len: csize_t
): lf_iovec_pair_t {.exportc: "lf_streambuffer_acquire_read_iov", cdecl, gcsafe, raises: [].} =
  lf_stream_ring_acquire_read_iov(ring, requested_len)

proc lf_streambuffer_commit_read*(
    ring: ptr lf_streambuffer_t,
    bytes_read: csize_t
) {.exportc: "lf_streambuffer_commit_read", cdecl, gcsafe, raises: [].} =
  lf_stream_ring_commit_read(ring, bytes_read)

# ------------------------------------------------------------------------------
# 11b. MPMCStreamRing (Multi-Producer Multi-Consumer Byte Stream Ring)
# ------------------------------------------------------------------------------

type
  lf_mpmc_stream_ring_handle* {.exportc: "lf_mpmc_stream_ring_t".} = object
    raw*: ptr MPMCStreamRing

  lf_mpmc_stream_ring_t* = lf_mpmc_stream_ring_handle
  lfq_mpmc_stream_ring_handle* = lf_mpmc_stream_ring_handle
  lfq_mpmc_stream_ring_t* = lf_mpmc_stream_ring_handle

proc lf_mpmc_stream_ring_create*(
    capacity: csize_t
): ptr lf_mpmc_stream_ring_t {.exportc: "lf_mpmc_stream_ring_create", cdecl, gcsafe, raises: [].} =
  try:
    let handle = cast[ptr lf_mpmc_stream_ring_t](allocShared0(sizeof(lf_mpmc_stream_ring_t)))
    if handle == nil: return nil
    let raw = cast[ptr MPMCStreamRing](allocShared0(sizeof(MPMCStreamRing)))
    if raw == nil:
      deallocShared(handle)
      return nil
    let cap = if capacity == 0: DefaultStreamCapacity else: int(capacity)
    raw[] = initMPMCStreamRing(cap)
    handle.raw = raw
    handle
  except:
    nil

proc lf_mpmc_stream_ring_destroy*(
    ring: ptr lf_mpmc_stream_ring_t
) {.exportc: "lf_mpmc_stream_ring_destroy", cdecl, gcsafe, raises: [].} =
  if ring != nil:
    if ring.raw != nil:
      try:
        ring.raw[].destroy()
      except:
        discard
      deallocShared(ring.raw)
      ring.raw = nil
    deallocShared(ring)

proc lf_mpmc_stream_ring_capacity*(
    ring: ptr lf_mpmc_stream_ring_t
): csize_t {.exportc: "lf_mpmc_stream_ring_capacity", cdecl, gcsafe, raises: [].} =
  if ring == nil or ring.raw == nil: return 0
  try:
    csize_t(ring.raw[].capacity())
  except:
    0

proc lf_mpmc_stream_ring_available_read*(
    ring: ptr lf_mpmc_stream_ring_t
): csize_t {.exportc: "lf_mpmc_stream_ring_available_read", cdecl, gcsafe, raises: [].} =
  if ring == nil or ring.raw == nil: return 0
  try:
    csize_t(ring.raw[].availableRead())
  except:
    0

proc lf_mpmc_stream_ring_available_write*(
    ring: ptr lf_mpmc_stream_ring_t
): csize_t {.exportc: "lf_mpmc_stream_ring_available_write", cdecl, gcsafe, raises: [].} =
  if ring == nil or ring.raw == nil: return 0
  try:
    csize_t(ring.raw[].availableWrite())
  except:
    0

proc lf_mpmc_stream_ring_is_empty*(
    ring: ptr lf_mpmc_stream_ring_t
): bool {.exportc: "lf_mpmc_stream_ring_is_empty", cdecl, gcsafe, raises: [].} =
  if ring == nil or ring.raw == nil: return true
  try:
    ring.raw[].availableRead() == 0
  except:
    true

proc lf_mpmc_stream_ring_is_full*(
    ring: ptr lf_mpmc_stream_ring_t
): bool {.exportc: "lf_mpmc_stream_ring_is_full", cdecl, gcsafe, raises: [].} =
  if ring == nil or ring.raw == nil: return false
  try:
    ring.raw[].availableWrite() == 0
  except:
    false

proc lf_mpmc_stream_ring_try_write*(
    ring: ptr lf_mpmc_stream_ring_t,
    src: pointer,
    len: csize_t
): csize_t {.exportc: "lf_mpmc_stream_ring_try_write", cdecl, gcsafe, raises: [].} =
  if ring == nil or ring.raw == nil or src == nil or len == 0: return 0
  try:
    let s = cast[ptr UncheckedArray[byte]](src)
    let written = ring.raw[].tryWrite(toOpenArray(s, 0, int(len) - 1))
    csize_t(written)
  except:
    0

proc lf_mpmc_stream_ring_try_read*(
    ring: ptr lf_mpmc_stream_ring_t,
    dst: pointer,
    max_len: csize_t
): csize_t {.exportc: "lf_mpmc_stream_ring_try_read", cdecl, gcsafe, raises: [].} =
  if ring == nil or ring.raw == nil or dst == nil or max_len == 0: return 0
  try:
    let d = cast[ptr UncheckedArray[byte]](dst)
    let readBytes = ring.raw[].tryRead(toOpenArray(d, 0, int(max_len) - 1))
    csize_t(readBytes)
  except:
    0

# ------------------------------------------------------------------------------
# 12. Atomic Associative Map Operations (Ctrie & SkipListMap)
# ------------------------------------------------------------------------------

type
  lf_skiplist_t* = lf_table_t
  lfq_skiplist_t* = lf_table_t

  lf_mapping_fn* = proc(key: pointer, key_len: csize_t, user_data: pointer): pointer {.cdecl, gcsafe.}
  lfq_mapping_fn* = lf_mapping_fn
  lf_update_fn* = proc(old_val: pointer, old_val_len: csize_t, user_data: pointer): pointer {.cdecl, gcsafe.}
  lfq_update_fn* = lf_update_fn

proc lf_ctrie_compute_if_absent*(
    trie: ptr lf_ctrie_t,
    key: pointer,
    key_len: csize_t,
    mapping_fn: lf_mapping_fn,
    user_data: pointer,
    out_val: ptr pointer,
    out_val_len: ptr csize_t
): bool {.exportc: "lf_ctrie_compute_if_absent", cdecl, gcsafe, raises: [].} =
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

proc lf_ctrie_atomic_update*(
    trie: ptr lf_ctrie_t,
    key: pointer,
    key_len: csize_t,
    update_fn: lf_update_fn,
    user_data: pointer,
    out_val: ptr pointer,
    out_val_len: ptr csize_t
): bool {.exportc: "lf_ctrie_atomic_update", cdecl, gcsafe, raises: [].} =
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

proc lf_skiplist_compute_if_absent*(
    map: ptr lf_table_t,
    key: pointer,
    key_len: csize_t,
    mapping_fn: lf_mapping_fn,
    user_data: pointer,
    out_val: ptr pointer,
    out_val_len: ptr csize_t
): bool {.exportc: "lf_skiplist_compute_if_absent", cdecl, gcsafe, raises: [].} =
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

proc lf_skiplist_atomic_update*(
    map: ptr lf_table_t,
    key: pointer,
    key_len: csize_t,
    update_fn: lf_update_fn,
    user_data: pointer,
    out_val: ptr pointer,
    out_val_len: ptr csize_t
): bool {.exportc: "lf_skiplist_atomic_update", cdecl, gcsafe, raises: [].} =
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

proc lf_table_compute_if_absent*(
    map: ptr lf_table_t,
    key: pointer,
    key_len: csize_t,
    mapping_fn: lf_mapping_fn,
    user_data: pointer,
    out_val: ptr pointer,
    out_val_len: ptr csize_t
): bool {.exportc: "lf_table_compute_if_absent", cdecl, gcsafe, raises: [].} =
  lf_skiplist_compute_if_absent(map, key, key_len, mapping_fn, user_data, out_val, out_val_len)

proc lf_table_atomic_update*(
    map: ptr lf_table_t,
    key: pointer,
    key_len: csize_t,
    update_fn: lf_update_fn,
    user_data: pointer,
    out_val: ptr pointer,
    out_val_len: ptr csize_t
): bool {.exportc: "lf_table_atomic_update", cdecl, gcsafe, raises: [].} =
  lf_skiplist_atomic_update(map, key, key_len, update_fn, user_data, out_val, out_val_len)

# ------------------------------------------------------------------------------
# 13. Lock-Free 128-Bit DWCAS Atomic Shared Pointer (AtomicArc & ArcGuard)
# ------------------------------------------------------------------------------

type
  lf_arc_destructor_fn* = proc(item: pointer, userData: pointer) {.cdecl, gcsafe, raises: [].}
  lfq_arc_destructor_fn* = lf_arc_destructor_fn

  lf_arc_guard_handle* {.exportc: "lf_arc_guard_t".} = object
    raw*: ArcGuard[pointer]

  lf_arc_guard_t* = lf_arc_guard_handle
  lfq_arc_guard_handle* = lf_arc_guard_handle
  lfq_arc_guard_t* = lf_arc_guard_handle

  lf_atomic_arc_handle* {.exportc: "lf_atomic_arc_t".} = object
    raw*: AtomicArc[pointer]

  lf_atomic_arc_t* = lf_atomic_arc_handle
  lfq_atomic_arc_handle* = lf_atomic_arc_handle
  lfq_atomic_arc_t* = lf_atomic_arc_handle

proc wrapArcGuard(g: sink ArcGuard[pointer]): ptr lf_arc_guard_t {.inline.} =
  if g.isNil:
    return nil
  result = cast[ptr lf_arc_guard_t](allocShared0(sizeof(lf_arc_guard_t)))
  if result != nil:
    result.raw = g

proc lf_arc_guard_create*(
    item: pointer,
    destructor: lf_arc_destructor_fn,
    userData: pointer,
    outGuard: ptr ptr lf_arc_guard_t
): lf_status_t {.exportc: "lf_arc_guard_create", cdecl, gcsafe, raises: [].} =
  cAbiBoundary:
    if unlikely(outGuard == nil):
      return LF_ERR_INVALID_ARG
    if item == nil and destructor == nil:
      outGuard[] = nil
      return LF_OK
    var g = initArcGuard[pointer](item, cast[ArcItemDestroyCallback](destructor), userData)
    let h = wrapArcGuard(move(g))
    if unlikely(h == nil):
      return LF_ERR_FAILURE
    outGuard[] = h
    return LF_OK

proc lf_arc_guard_get*(
    guard: ptr lf_arc_guard_t
): pointer {.exportc: "lf_arc_guard_get", cdecl, gcsafe, raises: [].} =
  if guard == nil or guard.raw.isNil:
    return nil
  try:
    guard.raw.get()
  except:
    nil

proc lf_arc_guard_clone*(
    guard: ptr lf_arc_guard_t,
    outClone: ptr ptr lf_arc_guard_t
): lf_status_t {.exportc: "lf_arc_guard_clone", cdecl, gcsafe, raises: [].} =
  cAbiBoundary:
    if unlikely(outClone == nil):
      return LF_ERR_INVALID_ARG
    if guard == nil or guard.raw.isNil:
      outClone[] = nil
      return LF_OK
    var cloned = guard.raw.clone()
    let h = wrapArcGuard(move(cloned))
    if unlikely(h == nil):
      return LF_ERR_FAILURE
    outClone[] = h
    return LF_OK

proc lf_arc_guard_release*(
    guard: ptr lf_arc_guard_t
): lf_status_t {.exportc: "lf_arc_guard_release", cdecl, gcsafe, raises: [].} =
  cAbiBoundary:
    if guard != nil:
      `=destroy`(guard.raw)
      deallocShared(guard)
    return LF_OK

proc lf_atomic_arc_create*(
    initialItem: pointer,
    destructor: lf_arc_destructor_fn,
    userData: pointer,
    outArc: ptr ptr lf_atomic_arc_t
): lf_status_t {.exportc: "lf_atomic_arc_create", cdecl, gcsafe, raises: [].} =
  cAbiBoundary:
    if unlikely(outArc == nil):
      return LF_ERR_INVALID_ARG
    let h = allocAligned[lf_atomic_arc_t]()
    if unlikely(h == nil):
      return LF_ERR_FAILURE
    if initialItem == nil and destructor == nil:
      h.raw = initAtomicArc[pointer]()
    else:
      h.raw = initAtomicArc[pointer](
        initialItem, cast[ArcItemDestroyCallback](destructor), userData
      )
    outArc[] = h
    return LF_OK

proc lf_atomic_arc_destroy*(
    arc: ptr lf_atomic_arc_t
): lf_status_t {.exportc: "lf_atomic_arc_destroy", cdecl, gcsafe, raises: [].} =
  cAbiBoundary:
    if unlikely(arc == nil):
      return LF_ERR_INVALID_ARG
    `=destroy`(arc.raw)
    freeAligned(arc)
    return LF_OK

proc lf_atomic_arc_is_null*(
    arc: ptr lf_atomic_arc_t
): bool {.exportc: "lf_atomic_arc_is_null", cdecl, gcsafe, raises: [].} =
  if arc == nil:
    return true
  try:
    arc.raw.isNil()
  except:
    true

proc lf_atomic_arc_load*(
    arc: ptr lf_atomic_arc_t,
    outGuard: ptr ptr lf_arc_guard_t
): lf_status_t {.exportc: "lf_atomic_arc_load", cdecl, gcsafe, raises: [].} =
  cAbiBoundary:
    if unlikely(arc == nil or outGuard == nil):
      return LF_ERR_INVALID_ARG
    var g = arc.raw.load()
    if g.isNil:
      outGuard[] = nil
      return LF_OK
    let h = wrapArcGuard(move(g))
    if unlikely(h == nil):
      return LF_ERR_FAILURE
    outGuard[] = h
    return LF_OK

proc lf_atomic_arc_store*(
    arc: ptr lf_atomic_arc_t,
    newItem: pointer,
    destructor: lf_arc_destructor_fn,
    userData: pointer
): lf_status_t {.exportc: "lf_atomic_arc_store", cdecl, gcsafe, raises: [].} =
  cAbiBoundary:
    if unlikely(arc == nil):
      return LF_ERR_INVALID_ARG
    if newItem == nil and destructor == nil:
      arc.raw.storeNil()
    else:
      arc.raw.store(newItem, cast[ArcItemDestroyCallback](destructor), userData)
    return LF_OK

proc lf_atomic_arc_store_guard*(
    arc: ptr lf_atomic_arc_t,
    guard: ptr lf_arc_guard_t
): lf_status_t {.exportc: "lf_atomic_arc_store_guard", cdecl, gcsafe, raises: [].} =
  cAbiBoundary:
    if unlikely(arc == nil):
      return LF_ERR_INVALID_ARG
    if guard == nil or guard.raw.isNil:
      arc.raw.storeNil()
    else:
      arc.raw.store(guard.raw)
    return LF_OK

proc lf_atomic_arc_swap*(
    arc: ptr lf_atomic_arc_t,
    newItem: pointer,
    destructor: lf_arc_destructor_fn,
    userData: pointer,
    outOldGuard: ptr ptr lf_arc_guard_t
): lf_status_t {.exportc: "lf_atomic_arc_swap", cdecl, gcsafe, raises: [].} =
  cAbiBoundary:
    if unlikely(arc == nil or outOldGuard == nil):
      return LF_ERR_INVALID_ARG
    var oldG: ArcGuard[pointer]
    if newItem == nil and destructor == nil:
      let empty = ArcGuard[pointer](cb: nil)
      oldG = arc.raw.swap(empty)
    else:
      oldG = arc.raw.swap(newItem, cast[ArcItemDestroyCallback](destructor), userData)
    if oldG.isNil:
      outOldGuard[] = nil
      return LF_OK
    let h = wrapArcGuard(move(oldG))
    if unlikely(h == nil):
      return LF_ERR_FAILURE
    outOldGuard[] = h
    return LF_OK

proc lf_atomic_arc_swap_guard*(
    arc: ptr lf_atomic_arc_t,
    guard: ptr lf_arc_guard_t,
    outOldGuard: ptr ptr lf_arc_guard_t
): lf_status_t {.exportc: "lf_atomic_arc_swap_guard", cdecl, gcsafe, raises: [].} =
  cAbiBoundary:
    if unlikely(arc == nil or outOldGuard == nil):
      return LF_ERR_INVALID_ARG
    var oldG: ArcGuard[pointer]
    if guard == nil or guard.raw.isNil:
      let empty = ArcGuard[pointer](cb: nil)
      oldG = arc.raw.swap(empty)
    else:
      oldG = arc.raw.swap(guard.raw)
    if oldG.isNil:
      outOldGuard[] = nil
      return LF_OK
    let h = wrapArcGuard(move(oldG))
    if unlikely(h == nil):
      return LF_ERR_FAILURE
    outOldGuard[] = h
    return LF_OK

proc lf_atomic_arc_compare_exchange_guard*(
    arc: ptr lf_atomic_arc_t,
    inoutExpected: ptr ptr lf_arc_guard_t,
    desired: ptr lf_arc_guard_t,
    outSwapped: ptr bool
): lf_status_t {.exportc: "lf_atomic_arc_compare_exchange_guard", cdecl, gcsafe, raises: [].} =
  cAbiBoundary:
    if unlikely(arc == nil or inoutExpected == nil or outSwapped == nil):
      return LF_ERR_INVALID_ARG
    var expGuard =
      if inoutExpected[] != nil and not inoutExpected[].raw.isNil:
        inoutExpected[].raw.clone()
      else:
        ArcGuard[pointer](cb: nil)
    let desGuard =
      if desired != nil and not desired.raw.isNil:
        desired.raw
      else:
        ArcGuard[pointer](cb: nil)
    let swapped = arc.raw.compareExchange(expGuard, desGuard)
    outSwapped[] = swapped
    if not swapped:
      if expGuard.isNil:
        if inoutExpected[] != nil:
          `=destroy`(inoutExpected[].raw)
          deallocShared(inoutExpected[])
          inoutExpected[] = nil
      else:
        if inoutExpected[] != nil:
          inoutExpected[].raw = move(expGuard)
        else:
          let h = wrapArcGuard(move(expGuard))
          if unlikely(h == nil):
            return LF_ERR_FAILURE
          inoutExpected[] = h
    return LF_OK

proc lf_atomic_arc_compare_exchange*(
    arc: ptr lf_atomic_arc_t,
    inoutExpected: ptr ptr lf_arc_guard_t,
    desiredItem: pointer,
    destructor: lf_arc_destructor_fn,
    userData: pointer,
    outSwapped: ptr bool
): lf_status_t {.exportc: "lf_atomic_arc_compare_exchange", cdecl, gcsafe, raises: [].} =
  cAbiBoundary:
    if unlikely(arc == nil or inoutExpected == nil or outSwapped == nil):
      return LF_ERR_INVALID_ARG
    if desiredItem == nil and destructor == nil:
      return lf_atomic_arc_compare_exchange_guard(arc, inoutExpected, nil, outSwapped)
    var desHandle: lf_arc_guard_t
    desHandle.raw = initArcGuard[pointer](
      desiredItem, cast[ArcItemDestroyCallback](destructor), userData
    )
    let st = lf_atomic_arc_compare_exchange_guard(
      arc, inoutExpected, addr desHandle, outSwapped
    )
    `=destroy`(desHandle.raw)
    return st

# ------------------------------------------------------------------------------
# 14. Lock-Free Priority Queue (Lindén-Jonsson SkipListPriorityQueue)
# ------------------------------------------------------------------------------

type
  lf_pqueue_destructor_fn* = proc(item: pointer, user_data: pointer) {.cdecl, gcsafe.}
  lfq_pqueue_destructor_fn* = lf_pqueue_destructor_fn

  lf_pqueue_t* = object
    raw: ptr SkipListPriorityQueue[Prioritized[int64, pointer], DefaultPQueueMaxThreads, DefaultPQueueMaxLevel]
    destructor: lf_pqueue_destructor_fn
    userData: pointer

  lfq_pqueue_t* = lf_pqueue_t

proc lf_pqueue_create*(
    destructor: lf_pqueue_destructor_fn,
    user_data: pointer,
    out_pqueue: ptr ptr lf_pqueue_t
): lf_status_t {.exportc: "lf_pqueue_create", cdecl, gcsafe, raises: [].} =
  if unlikely(out_pqueue == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    let pq = cast[ptr lf_pqueue_t](allocShared0(sizeof(lf_pqueue_t)))
    let raw = cast[ptr SkipListPriorityQueue[Prioritized[int64, pointer], DefaultPQueueMaxThreads, DefaultPQueueMaxLevel]](
      allocShared0(sizeof(SkipListPriorityQueue[Prioritized[int64, pointer], DefaultPQueueMaxThreads, DefaultPQueueMaxLevel]))
    )
    raw[] = newSkipListPriorityQueue[Prioritized[int64, pointer], DefaultPQueueMaxThreads, DefaultPQueueMaxLevel]()
    pq.raw = raw
    pq.destructor = destructor
    pq.userData = user_data
    out_pqueue[] = pq
    LF_OK

proc lf_pqueue_clear*(
    pqueue: ptr lf_pqueue_t
): lf_status_t {.exportc: "lf_pqueue_clear", cdecl, gcsafe, raises: [].} =
  if unlikely(pqueue == nil or pqueue.raw == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    {.cast(gcsafe).}:
      var entry: Prioritized[int64, pointer]
      while pqueue.raw[].tryPopMin(entry):
        if pqueue.destructor != nil and entry.value != nil:
          pqueue.destructor(entry.value, pqueue.userData)
      pqueue.raw[].clear()
    LF_OK

proc lf_pqueue_destroy*(
    pqueue: ptr lf_pqueue_t
): lf_status_t {.exportc: "lf_pqueue_destroy", cdecl, gcsafe, raises: [].} =
  if unlikely(pqueue == nil or pqueue.raw == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    {.cast(gcsafe).}:
      if pqueue.destructor != nil:
        var entry: Prioritized[int64, pointer]
        while pqueue.raw[].tryPopMin(entry):
          if entry.value != nil:
            pqueue.destructor(entry.value, pqueue.userData)
      `=destroy`(pqueue.raw[])
      deallocShared(pqueue.raw)
      pqueue.raw = nil
      deallocShared(pqueue)
    LF_OK

proc lf_pqueue_push*(
    pqueue: ptr lf_pqueue_t,
    priority: int64,
    item: pointer
): lf_status_t {.exportc: "lf_pqueue_push", cdecl, gcsafe, raises: [].} =
  if unlikely(pqueue == nil or pqueue.raw == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    {.cast(gcsafe).}:
      pqueue.raw[].push(priority, item)
    LF_OK

proc lf_pqueue_pop_min*(
    pqueue: ptr lf_pqueue_t,
    out_priority: ptr int64,
    out_item: ptr pointer
): lf_status_t {.exportc: "lf_pqueue_pop_min", cdecl, gcsafe, raises: [].} =
  if unlikely(pqueue == nil or pqueue.raw == nil or out_item == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    {.cast(gcsafe).}:
      var entry: Prioritized[int64, pointer]
      if pqueue.raw[].tryPopMin(entry):
        if out_priority != nil:
          out_priority[] = entry.priority
        out_item[] = entry.value
        LF_OK
      else:
        LF_ERR_EMPTY

proc lf_pqueue_peek_min*(
    pqueue: ptr lf_pqueue_t,
    out_priority: ptr int64,
    out_item: ptr pointer
): lf_status_t {.exportc: "lf_pqueue_peek_min", cdecl, gcsafe, raises: [].} =
  if unlikely(pqueue == nil or pqueue.raw == nil or out_item == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    {.cast(gcsafe).}:
      let opt = pqueue.raw[].peekMin()
      if opt.isSome:
        let entry = opt.get()
        if out_priority != nil:
          out_priority[] = entry.priority
        out_item[] = entry.value
        LF_OK
      else:
        LF_ERR_EMPTY

proc lf_pqueue_len*(
    pqueue: ptr lf_pqueue_t
): csize_t {.exportc: "lf_pqueue_len", cdecl, gcsafe, raises: [].} =
  if unlikely(pqueue == nil or pqueue.raw == nil):
    return 0
  try:
    {.cast(gcsafe).}:
      csize_t(pqueue.raw[].len())
  except:
    0

proc lf_pqueue_is_empty*(
    pqueue: ptr lf_pqueue_t
): bool {.exportc: "lf_pqueue_is_empty", cdecl, gcsafe, raises: [].} =
  if unlikely(pqueue == nil or pqueue.raw == nil):
    return true
  try:
    {.cast(gcsafe).}:
      pqueue.raw[].isEmpty()
  except:
    true

# ------------------------------------------------------------------------------
# 15. FlatCombiner (Hendler-Incze-Shavit-Tzafrir Synchronization Adapter)
# ------------------------------------------------------------------------------

type
  lf_flat_combiner_op_fn* = proc(state: pointer, op_arg: pointer, user_data: pointer): pointer {.cdecl, gcsafe.}
  lfq_flat_combiner_op_fn* = lf_flat_combiner_op_fn
  lf_flat_combiner_state_destructor_fn* = proc(state: pointer, user_data: pointer) {.cdecl, gcsafe.}
  lfq_flat_combiner_state_destructor_fn* = lf_flat_combiner_state_destructor_fn

  lf_flat_combiner* {.exportc: "lf_flat_combiner_t".} = object
    defaultOpFn*: lf_flat_combiner_op_fn
    stateDestructor*: lf_flat_combiner_state_destructor_fn
    userData*: pointer
    raw*: FlatCombiner[pointer, pointer, pointer]

  lf_flat_combiner_t* = lf_flat_combiner
  lfq_flat_combiner* = lf_flat_combiner
  lfq_flat_combiner_t* = lf_flat_combiner

  CAbiFlatCombineCtx = object
    opFn: lf_flat_combiner_op_fn
    opArg: pointer
    userData: pointer
    result: pointer

proc cAbiFlatCombineExec(state: var pointer, rawCtx: pointer) {.nimcall, gcsafe.} =
  let ctx = cast[ptr CAbiFlatCombineCtx](rawCtx)
  if ctx.opFn != nil:
    ctx.result = ctx.opFn(state, ctx.opArg, ctx.userData)

proc lf_flat_combiner_create*(
    state: pointer,
    default_op_fn: lf_flat_combiner_op_fn,
    state_destructor: lf_flat_combiner_state_destructor_fn,
    user_data: pointer,
    max_combining_rounds: csize_t,
    cleanup_interval: csize_t,
    out_combiner: ptr ptr lf_flat_combiner_t
): lf_status_t {.exportc: "lf_flat_combiner_create", cdecl, gcsafe, raises: [].} =
  if unlikely(out_combiner == nil):
    return LF_ERR_INVALID_ARG
  let rounds = if max_combining_rounds == 0: DefaultCombiningRounds else: int(max_combining_rounds)
  let cleanup = if cleanup_interval == 0: DefaultCleanupInterval else: int(cleanup_interval)
  cAbiBoundary:
    let fc = cast[ptr lf_flat_combiner_t](allocShared0(sizeof(lf_flat_combiner_t)))
    fc.defaultOpFn = default_op_fn
    fc.stateDestructor = state_destructor
    fc.userData = user_data
    fc.raw = initFlatCombiner[pointer](state, maxCombiningRounds = rounds, cleanupInterval = cleanup)
    out_combiner[] = fc
    LF_OK

proc lf_flat_combiner_destroy*(
    combiner: ptr lf_flat_combiner_t
): lf_status_t {.exportc: "lf_flat_combiner_destroy", cdecl, gcsafe, raises: [].} =
  if unlikely(combiner == nil or not combiner.raw.isInitialized()):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    if combiner.stateDestructor != nil and combiner.raw.core != nil:
      try:
        combiner.stateDestructor(combiner.raw.core.state, combiner.userData)
      except:
        discard
    `=destroy`(combiner.raw)
    zeroMem(addr combiner.raw, sizeof(combiner.raw))
    deallocShared(combiner)
    LF_OK

proc lf_flat_combiner_combine*(
    combiner: ptr lf_flat_combiner_t,
    op_arg: pointer,
    out_result: ptr pointer
): lf_status_t {.exportc: "lf_flat_combiner_combine", cdecl, gcsafe, raises: [].} =
  if unlikely(combiner == nil or not combiner.raw.isInitialized() or combiner.defaultOpFn == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    var ctx = CAbiFlatCombineCtx(
      opFn: combiner.defaultOpFn,
      opArg: op_arg,
      userData: combiner.userData,
      result: nil
    )
    combiner.raw.combineRaw(cAbiFlatCombineExec, addr ctx)
    if out_result != nil:
      out_result[] = ctx.result
    LF_OK

proc lf_flat_combiner_combine_fn*(
    combiner: ptr lf_flat_combiner_t,
    op_fn: lf_flat_combiner_op_fn,
    op_arg: pointer,
    op_user_data: pointer,
    out_result: ptr pointer
): lf_status_t {.exportc: "lf_flat_combiner_combine_fn", cdecl, gcsafe, raises: [].} =
  if unlikely(combiner == nil or not combiner.raw.isInitialized() or op_fn == nil):
    return LF_ERR_INVALID_ARG
  cAbiBoundary:
    var ctx = CAbiFlatCombineCtx(
      opFn: op_fn,
      opArg: op_arg,
      userData: op_user_data,
      result: nil
    )
    combiner.raw.combineRaw(cAbiFlatCombineExec, addr ctx)
    if out_result != nil:
      out_result[] = ctx.result
    LF_OK

proc lf_flat_combiner_pass_count*(
    combiner: ptr lf_flat_combiner_t
): uint64 {.exportc: "lf_flat_combiner_pass_count", cdecl, gcsafe, raises: [].} =
  if unlikely(combiner == nil or not combiner.raw.isInitialized()):
    return 0'u64
  combiner.raw.passCount()

proc lf_flat_combiner_total_combined_ops*(
    combiner: ptr lf_flat_combiner_t
): uint64 {.exportc: "lf_flat_combiner_total_combined_ops", cdecl, gcsafe, raises: [].} =
  if unlikely(combiner == nil or not combiner.raw.isInitialized()):
    return 0'u64
  combiner.raw.totalCombinedOps()

proc lf_flat_combiner_active_records*(
    combiner: ptr lf_flat_combiner_t
): csize_t {.exportc: "lf_flat_combiner_active_records", cdecl, gcsafe, raises: [].} =
  if unlikely(combiner == nil or not combiner.raw.isInitialized()):
    return 0.csize_t
  csize_t(combiner.raw.activePublicationRecords())

# ------------------------------------------------------------------------------
# 16. Bounded Zero-SMR Lock-Free Stack (BStack)
# ------------------------------------------------------------------------------

type
  lf_bstack* {.exportc: "lf_bstack_t".} = object
    destructor*: lf_item_destructor_fn
    userData*: pointer
    destroyFn*: proc(s: ptr lf_bstack_t): lf_status_t {.nimcall, gcsafe, raises: [].}
    pushFn*: proc(s: ptr lf_bstack_t, item: pointer): lf_status_t {.nimcall, gcsafe, raises: [].}
    popFn*: proc(s: ptr lf_bstack_t, outItem: ptr pointer): lf_status_t {.nimcall, gcsafe, raises: [].}
    peekFn*: proc(s: ptr lf_bstack_t, outItem: ptr pointer): lf_status_t {.nimcall, gcsafe, raises: [].}
    clearFn*: proc(s: ptr lf_bstack_t): lf_status_t {.nimcall, gcsafe, raises: [].}
    lenFn*: proc(s: ptr lf_bstack_t): csize_t {.nimcall, gcsafe, raises: [].}
    capFn*: proc(s: ptr lf_bstack_t): csize_t {.nimcall, gcsafe, raises: [].}
    isEmptyFn*: proc(s: ptr lf_bstack_t): bool {.nimcall, gcsafe, raises: [].}
    isFullFn*: proc(s: ptr lf_bstack_t): bool {.nimcall, gcsafe, raises: [].}

  lf_bstack_t* = lf_bstack
  lfq_bstack* = lf_bstack
  lfq_bstack_t* = lf_bstack

  BStackImpl[N: static int] = object
    base: lf_bstack_t
    raw: ptr BStack[pointer, N, ccMulti, ccMulti]

proc bstackPushImpl[N: static int](s: ptr lf_bstack_t, item: pointer): lf_status_t {.nimcall, gcsafe, raises: [].} =
  let impl = cast[ptr BStackImpl[N]](s)
  cAbiBoundary:
    if impl.raw[].tryPush(item):
      LF_OK
    else:
      LF_ERR_FULL

proc bstackPopImpl[N: static int](s: ptr lf_bstack_t, outItem: ptr pointer): lf_status_t {.nimcall, gcsafe, raises: [].} =
  let impl = cast[ptr BStackImpl[N]](s)
  cAbiBoundary:
    var item: pointer = nil
    if impl.raw[].tryPop(item):
      outItem[] = item
      LF_OK
    else:
      LF_ERR_EMPTY

proc bstackPeekImpl[N: static int](s: ptr lf_bstack_t, outItem: ptr pointer): lf_status_t {.nimcall, gcsafe, raises: [].} =
  let impl = cast[ptr BStackImpl[N]](s)
  cAbiBoundary:
    var item: pointer = nil
    if impl.raw[].tryPeek(item):
      outItem[] = item
      LF_OK
    else:
      LF_ERR_EMPTY

proc bstackClearImpl[N: static int](s: ptr lf_bstack_t): lf_status_t {.nimcall, gcsafe, raises: [].} =
  let impl = cast[ptr BStackImpl[N]](s)
  cAbiBoundary:
    if s.destructor != nil:
      var item: pointer = nil
      while impl.raw[].tryPop(item):
        try:
          s.destructor(item, s.userData)
        except:
          discard
    impl.raw[].clear()
    LF_OK

proc bstackDestroyImpl[N: static int](s: ptr lf_bstack_t): lf_status_t {.nimcall, gcsafe, raises: [].} =
  let impl = cast[ptr BStackImpl[N]](s)
  cAbiBoundary:
    if impl.raw != nil:
      if s.destructor != nil:
        var item: pointer = nil
        while impl.raw[].tryPop(item):
          try:
            s.destructor(item, s.userData)
          except:
            discard
      `=destroy`(impl.raw[])
      freeAligned(impl.raw)
      impl.raw = nil
    deallocShared(impl)
    LF_OK

proc bstackLenImpl[N: static int](s: ptr lf_bstack_t): csize_t {.nimcall, gcsafe, raises: [].} =
  let impl = cast[ptr BStackImpl[N]](s)
  csize_t(impl.raw[].len())

proc bstackCapImpl[N: static int](s: ptr lf_bstack_t): csize_t {.nimcall, gcsafe, raises: [].} =
  let impl = cast[ptr BStackImpl[N]](s)
  csize_t(impl.raw[].capacity())

proc bstackIsEmptyImpl[N: static int](s: ptr lf_bstack_t): bool {.nimcall, gcsafe, raises: [].} =
  let impl = cast[ptr BStackImpl[N]](s)
  impl.raw[].isEmpty()

proc bstackIsFullImpl[N: static int](s: ptr lf_bstack_t): bool {.nimcall, gcsafe, raises: [].} =
  let impl = cast[ptr BStackImpl[N]](s)
  impl.raw[].isFull()

proc createBStackTier[N: static int](
    effCap: int,
    destructor: lf_item_destructor_fn,
    userData: pointer,
    outStack: ptr ptr lf_bstack_t
): lf_status_t {.nimcall, gcsafe, raises: [].} =
  cAbiBoundary:
    let impl = cast[ptr BStackImpl[N]](allocShared0(sizeof(BStackImpl[N])))
    let raw = allocAligned[BStack[pointer, N, ccMulti, ccMulti]]()
    raw[] = initBStack[pointer, N]()
    raw[].setEffectiveCapacity(effCap)
    impl.raw = raw
    impl.base.destructor = destructor
    impl.base.userData = userData
    impl.base.destroyFn = bstackDestroyImpl[N]
    impl.base.pushFn = bstackPushImpl[N]
    impl.base.popFn = bstackPopImpl[N]
    impl.base.peekFn = bstackPeekImpl[N]
    impl.base.clearFn = bstackClearImpl[N]
    impl.base.lenFn = bstackLenImpl[N]
    impl.base.capFn = bstackCapImpl[N]
    impl.base.isEmptyFn = bstackIsEmptyImpl[N]
    impl.base.isFullFn = bstackIsFullImpl[N]
    outStack[] = cast[ptr lf_bstack_t](impl)
    LF_OK

proc lf_bstack_create*(
    capacity: csize_t,
    destructor: lf_item_destructor_fn,
    user_data: pointer,
    out_stack: ptr ptr lf_bstack_t
): lf_status_t {.exportc: "lf_bstack_create", cdecl, gcsafe, raises: [].} =
  if unlikely(capacity == 0 or out_stack == nil):
    return LF_ERR_INVALID_ARG
  if unlikely(capacity > 65536):
    return LF_ERR_UNSUPPORTED
  let cap = int(capacity)
  if cap <= 16:
    createBStackTier[16](cap, destructor, user_data, out_stack)
  elif cap <= 64:
    createBStackTier[64](cap, destructor, user_data, out_stack)
  elif cap <= 256:
    createBStackTier[256](cap, destructor, user_data, out_stack)
  elif cap <= 1024:
    createBStackTier[1024](cap, destructor, user_data, out_stack)
  elif cap <= 4096:
    createBStackTier[4096](cap, destructor, user_data, out_stack)
  elif cap <= 16384:
    createBStackTier[16384](cap, destructor, user_data, out_stack)
  else:
    createBStackTier[65536](cap, destructor, user_data, out_stack)

proc lf_bstack_destroy*(
    stack: ptr lf_bstack_t
): lf_status_t {.exportc: "lf_bstack_destroy", cdecl, gcsafe, raises: [].} =
  if unlikely(stack == nil or stack.destroyFn == nil):
    return LF_ERR_INVALID_ARG
  stack.destroyFn(stack)

proc lf_bstack_push*(
    stack: ptr lf_bstack_t,
    item: pointer
): lf_status_t {.exportc: "lf_bstack_push", cdecl, gcsafe, raises: [].} =
  if unlikely(stack == nil or stack.pushFn == nil):
    return LF_ERR_INVALID_ARG
  stack.pushFn(stack, item)

proc lf_bstack_pop*(
    stack: ptr lf_bstack_t,
    out_item: ptr pointer
): lf_status_t {.exportc: "lf_bstack_pop", cdecl, gcsafe, raises: [].} =
  if unlikely(stack == nil or stack.popFn == nil or out_item == nil):
    return LF_ERR_INVALID_ARG
  stack.popFn(stack, out_item)

proc lf_bstack_peek*(
    stack: ptr lf_bstack_t,
    out_item: ptr pointer
): lf_status_t {.exportc: "lf_bstack_peek", cdecl, gcsafe, raises: [].} =
  if unlikely(stack == nil or stack.peekFn == nil or out_item == nil):
    return LF_ERR_INVALID_ARG
  stack.peekFn(stack, out_item)

proc lf_bstack_drain*(
    stack: ptr lf_bstack_t,
    out_items: ptr pointer,
    max_count: csize_t
): csize_t {.exportc: "lf_bstack_drain", cdecl, gcsafe, raises: [].} =
  if unlikely(stack == nil or stack.popFn == nil or out_items == nil or max_count == 0):
    return 0.csize_t
  let arr = cast[ptr UncheckedArray[pointer]](out_items)
  var count: csize_t = 0
  while count < max_count:
    var item: pointer = nil
    if stack.popFn(stack, addr item) == LF_OK:
      arr[count] = item
      inc count
    else:
      break
  count

proc lf_bstack_clear*(
    stack: ptr lf_bstack_t
): lf_status_t {.exportc: "lf_bstack_clear", cdecl, gcsafe, raises: [].} =
  if unlikely(stack == nil or stack.clearFn == nil):
    return LF_ERR_INVALID_ARG
  stack.clearFn(stack)

proc lf_bstack_len*(
    stack: ptr lf_bstack_t
): csize_t {.exportc: "lf_bstack_len", cdecl, gcsafe, raises: [].} =
  if unlikely(stack == nil or stack.lenFn == nil):
    return 0.csize_t
  stack.lenFn(stack)

proc lf_bstack_capacity*(
    stack: ptr lf_bstack_t
): csize_t {.exportc: "lf_bstack_capacity", cdecl, gcsafe, raises: [].} =
  if unlikely(stack == nil or stack.capFn == nil):
    return 0.csize_t
  stack.capFn(stack)

proc lf_bstack_is_empty*(
    stack: ptr lf_bstack_t
): bool {.exportc: "lf_bstack_is_empty", cdecl, gcsafe, raises: [].} =
  if unlikely(stack == nil or stack.isEmptyFn == nil):
    return true
  stack.isEmptyFn(stack)

proc lf_bstack_is_full*(
    stack: ptr lf_bstack_t
): bool {.exportc: "lf_bstack_is_full", cdecl, gcsafe, raises: [].} =
  if unlikely(stack == nil or stack.isFullFn == nil):
    return false
  stack.isFullFn(stack)

# ------------------------------------------------------------------------------
# 17. Bounded Zero-SMR Binary Min-Heap Priority Queue (BPriorityQueue)
# ------------------------------------------------------------------------------

type
  lf_bpqueue* {.exportc: "lf_bpqueue_t".} = object
    destructor*: lf_item_destructor_fn
    userData*: pointer
    destroyFn*: proc(pq: ptr lf_bpqueue_t): lf_status_t {.nimcall, gcsafe, raises: [].}
    pushFn*: proc(pq: ptr lf_bpqueue_t, priority: int64, item: pointer): lf_status_t {.nimcall, gcsafe, raises: [].}
    popMinFn*: proc(pq: ptr lf_bpqueue_t, outPriority: ptr int64, outItem: ptr pointer): lf_status_t {.nimcall, gcsafe, raises: [].}
    peekMinFn*: proc(pq: ptr lf_bpqueue_t, outPriority: ptr int64, outItem: ptr pointer): lf_status_t {.nimcall, gcsafe, raises: [].}
    clearFn*: proc(pq: ptr lf_bpqueue_t): lf_status_t {.nimcall, gcsafe, raises: [].}
    lenFn*: proc(pq: ptr lf_bpqueue_t): csize_t {.nimcall, gcsafe, raises: [].}
    capFn*: proc(pq: ptr lf_bpqueue_t): csize_t {.nimcall, gcsafe, raises: [].}
    isEmptyFn*: proc(pq: ptr lf_bpqueue_t): bool {.nimcall, gcsafe, raises: [].}
    isFullFn*: proc(pq: ptr lf_bpqueue_t): bool {.nimcall, gcsafe, raises: [].}

  lf_bpqueue_t* = lf_bpqueue
  lfq_bpqueue* = lf_bpqueue
  lfq_bpqueue_t* = lf_bpqueue

  BPQueueImpl[N: static int] = object
    base: lf_bpqueue_t
    raw: ptr BPriorityQueue[Prioritized[int64, pointer], N, ccMulti, ccMulti]

proc bpqueuePushImpl[N: static int](pq: ptr lf_bpqueue_t, priority: int64, item: pointer): lf_status_t {.nimcall, gcsafe, raises: [].} =
  let impl = cast[ptr BPQueueImpl[N]](pq)
  cAbiBoundary:
    if impl.raw[].tryPush(Prioritized[int64, pointer](priority: priority, value: item)):
      LF_OK
    else:
      LF_ERR_FULL

proc bpqueuePopMinImpl[N: static int](pq: ptr lf_bpqueue_t, outPriority: ptr int64, outItem: ptr pointer): lf_status_t {.nimcall, gcsafe, raises: [].} =
  let impl = cast[ptr BPQueueImpl[N]](pq)
  cAbiBoundary:
    var entry: Prioritized[int64, pointer]
    if impl.raw[].tryPopMin(entry):
      if outPriority != nil:
        outPriority[] = entry.priority
      outItem[] = entry.value
      LF_OK
    else:
      LF_ERR_EMPTY

proc bpqueuePeekMinImpl[N: static int](pq: ptr lf_bpqueue_t, outPriority: ptr int64, outItem: ptr pointer): lf_status_t {.nimcall, gcsafe, raises: [].} =
  let impl = cast[ptr BPQueueImpl[N]](pq)
  cAbiBoundary:
    let opt = impl.raw[].peekMin()
    if opt.isSome:
      let entry = opt.get()
      if outPriority != nil:
        outPriority[] = entry.priority
      outItem[] = entry.value
      LF_OK
    else:
      LF_ERR_EMPTY

proc bpqueueClearImpl[N: static int](pq: ptr lf_bpqueue_t): lf_status_t {.nimcall, gcsafe, raises: [].} =
  let impl = cast[ptr BPQueueImpl[N]](pq)
  cAbiBoundary:
    if pq.destructor != nil:
      var entry: Prioritized[int64, pointer]
      while impl.raw[].tryPopMin(entry):
        try:
          pq.destructor(entry.value, pq.userData)
        except:
          discard
    impl.raw[].clear()
    LF_OK

proc bpqueueDestroyImpl[N: static int](pq: ptr lf_bpqueue_t): lf_status_t {.nimcall, gcsafe, raises: [].} =
  let impl = cast[ptr BPQueueImpl[N]](pq)
  cAbiBoundary:
    if impl.raw != nil:
      if pq.destructor != nil:
        var entry: Prioritized[int64, pointer]
        while impl.raw[].tryPopMin(entry):
          try:
            pq.destructor(entry.value, pq.userData)
          except:
            discard
      `=destroy`(impl.raw[])
      freeAligned(impl.raw)
      impl.raw = nil
    deallocShared(impl)
    LF_OK

proc bpqueueLenImpl[N: static int](pq: ptr lf_bpqueue_t): csize_t {.nimcall, gcsafe, raises: [].} =
  let impl = cast[ptr BPQueueImpl[N]](pq)
  csize_t(impl.raw[].len())

proc bpqueueCapImpl[N: static int](pq: ptr lf_bpqueue_t): csize_t {.nimcall, gcsafe, raises: [].} =
  let impl = cast[ptr BPQueueImpl[N]](pq)
  csize_t(impl.raw[].capacity())

proc bpqueueIsEmptyImpl[N: static int](pq: ptr lf_bpqueue_t): bool {.nimcall, gcsafe, raises: [].} =
  let impl = cast[ptr BPQueueImpl[N]](pq)
  impl.raw[].isEmpty()

proc bpqueueIsFullImpl[N: static int](pq: ptr lf_bpqueue_t): bool {.nimcall, gcsafe, raises: [].} =
  let impl = cast[ptr BPQueueImpl[N]](pq)
  impl.raw[].isFull()

proc createBPQueueTier[N: static int](
    effCap: int,
    destructor: lf_item_destructor_fn,
    userData: pointer,
    outPQueue: ptr ptr lf_bpqueue_t
): lf_status_t {.nimcall, gcsafe, raises: [].} =
  cAbiBoundary:
    let impl = cast[ptr BPQueueImpl[N]](allocShared0(sizeof(BPQueueImpl[N])))
    let raw = allocAligned[BPriorityQueue[Prioritized[int64, pointer], N, ccMulti, ccMulti]]()
    raw[] = initBPriorityQueue[Prioritized[int64, pointer], N]()
    raw[].setEffectiveCapacity(effCap)
    impl.raw = raw
    impl.base.destructor = destructor
    impl.base.userData = userData
    impl.base.destroyFn = bpqueueDestroyImpl[N]
    impl.base.pushFn = bpqueuePushImpl[N]
    impl.base.popMinFn = bpqueuePopMinImpl[N]
    impl.base.peekMinFn = bpqueuePeekMinImpl[N]
    impl.base.clearFn = bpqueueClearImpl[N]
    impl.base.lenFn = bpqueueLenImpl[N]
    impl.base.capFn = bpqueueCapImpl[N]
    impl.base.isEmptyFn = bpqueueIsEmptyImpl[N]
    impl.base.isFullFn = bpqueueIsFullImpl[N]
    outPQueue[] = cast[ptr lf_bpqueue_t](impl)
    LF_OK

proc lf_bpqueue_create*(
    capacity: csize_t,
    destructor: lf_item_destructor_fn,
    user_data: pointer,
    out_pqueue: ptr ptr lf_bpqueue_t
): lf_status_t {.exportc: "lf_bpqueue_create", cdecl, gcsafe, raises: [].} =
  if unlikely(capacity == 0 or out_pqueue == nil):
    return LF_ERR_INVALID_ARG
  if unlikely(capacity > 65536):
    return LF_ERR_UNSUPPORTED
  let cap = int(capacity)
  if cap <= 16:
    createBPQueueTier[16](cap, destructor, user_data, out_pqueue)
  elif cap <= 64:
    createBPQueueTier[64](cap, destructor, user_data, out_pqueue)
  elif cap <= 256:
    createBPQueueTier[256](cap, destructor, user_data, out_pqueue)
  elif cap <= 1024:
    createBPQueueTier[1024](cap, destructor, user_data, out_pqueue)
  elif cap <= 4096:
    createBPQueueTier[4096](cap, destructor, user_data, out_pqueue)
  elif cap <= 16384:
    createBPQueueTier[16384](cap, destructor, user_data, out_pqueue)
  else:
    createBPQueueTier[65536](cap, destructor, user_data, out_pqueue)

proc lf_bpqueue_destroy*(
    pqueue: ptr lf_bpqueue_t
): lf_status_t {.exportc: "lf_bpqueue_destroy", cdecl, gcsafe, raises: [].} =
  if unlikely(pqueue == nil or pqueue.destroyFn == nil):
    return LF_ERR_INVALID_ARG
  pqueue.destroyFn(pqueue)

proc lf_bpqueue_push*(
    pqueue: ptr lf_bpqueue_t,
    priority: int64,
    item: pointer
): lf_status_t {.exportc: "lf_bpqueue_push", cdecl, gcsafe, raises: [].} =
  if unlikely(pqueue == nil or pqueue.pushFn == nil):
    return LF_ERR_INVALID_ARG
  pqueue.pushFn(pqueue, priority, item)

proc lf_bpqueue_pop_min*(
    pqueue: ptr lf_bpqueue_t,
    out_priority: ptr int64,
    out_item: ptr pointer
): lf_status_t {.exportc: "lf_bpqueue_pop_min", cdecl, gcsafe, raises: [].} =
  if unlikely(pqueue == nil or pqueue.popMinFn == nil or out_item == nil):
    return LF_ERR_INVALID_ARG
  pqueue.popMinFn(pqueue, out_priority, out_item)

proc lf_bpqueue_peek_min*(
    pqueue: ptr lf_bpqueue_t,
    out_priority: ptr int64,
    out_item: ptr pointer
): lf_status_t {.exportc: "lf_bpqueue_peek_min", cdecl, gcsafe, raises: [].} =
  if unlikely(pqueue == nil or pqueue.peekMinFn == nil or out_item == nil):
    return LF_ERR_INVALID_ARG
  pqueue.peekMinFn(pqueue, out_priority, out_item)

proc lf_bpqueue_clear*(
    pqueue: ptr lf_bpqueue_t
): lf_status_t {.exportc: "lf_bpqueue_clear", cdecl, gcsafe, raises: [].} =
  if unlikely(pqueue == nil or pqueue.clearFn == nil):
    return LF_ERR_INVALID_ARG
  pqueue.clearFn(pqueue)

proc lf_bpqueue_len*(
    pqueue: ptr lf_bpqueue_t
): csize_t {.exportc: "lf_bpqueue_len", cdecl, gcsafe, raises: [].} =
  if unlikely(pqueue == nil or pqueue.lenFn == nil):
    return 0.csize_t
  pqueue.lenFn(pqueue)

proc lf_bpqueue_capacity*(
    pqueue: ptr lf_bpqueue_t
): csize_t {.exportc: "lf_bpqueue_capacity", cdecl, gcsafe, raises: [].} =
  if unlikely(pqueue == nil or pqueue.capFn == nil):
    return 0.csize_t
  pqueue.capFn(pqueue)

proc lf_bpqueue_is_empty*(
    pqueue: ptr lf_bpqueue_t
): bool {.exportc: "lf_bpqueue_is_empty", cdecl, gcsafe, raises: [].} =
  if unlikely(pqueue == nil or pqueue.isEmptyFn == nil):
    return true
  pqueue.isEmptyFn(pqueue)

proc lf_bpqueue_is_full*(
    pqueue: ptr lf_bpqueue_t
): bool {.exportc: "lf_bpqueue_is_full", cdecl, gcsafe, raises: [].} =
  if unlikely(pqueue == nil or pqueue.isFullFn == nil):
    return false
  pqueue.isFullFn(pqueue)

# ------------------------------------------------------------------------------
# 18. Bounded Zero-SMR Robin Hood Open-Addressing Hash Table (BTable)
# ------------------------------------------------------------------------------

type
  lf_btable_destructor_fn* = proc(key: pointer, val: pointer, userData: pointer) {.cdecl, gcsafe.}
  lfq_btable_destructor_fn* = lf_btable_destructor_fn
  lf_btable_mapping_fn* = proc(key: pointer, userData: pointer): pointer {.cdecl, gcsafe.}
  lfq_btable_mapping_fn* = lf_btable_mapping_fn
  lf_map_compute_fn* = lf_btable_mapping_fn
  lfq_map_compute_fn* = lf_btable_mapping_fn
  lf_btable_update_fn* = proc(key: pointer, oldVal: pointer, userData: pointer): pointer {.cdecl, gcsafe.}
  lfq_btable_update_fn* = lf_btable_update_fn
  lf_map_merge_fn* = lf_btable_update_fn
  lfq_map_merge_fn* = lf_btable_update_fn

  lf_btable* {.exportc: "lf_btable_t".} = object
    destructor*: lf_btable_destructor_fn
    userData*: pointer
    destroyFn*: proc(t: ptr lf_btable_t): lf_status_t {.nimcall, gcsafe, raises: [].}
    putFn*: proc(t: ptr lf_btable_t, key: pointer, val: pointer, outInserted: ptr bool): lf_status_t {.nimcall, gcsafe, raises: [].}
    insertFn*: proc(t: ptr lf_btable_t, key: pointer, val: pointer, outInserted: ptr bool): lf_status_t {.nimcall, gcsafe, raises: [].}
    getFn*: proc(t: ptr lf_btable_t, key: pointer, outVal: ptr pointer): lf_status_t {.nimcall, gcsafe, raises: [].}
    deleteFn*: proc(t: ptr lf_btable_t, key: pointer, outDeleted: ptr bool): lf_status_t {.nimcall, gcsafe, raises: [].}
    takeFn*: proc(t: ptr lf_btable_t, key: pointer, outVal: ptr pointer): lf_status_t {.nimcall, gcsafe, raises: [].}
    containsFn*: proc(t: ptr lf_btable_t, key: pointer): bool {.nimcall, gcsafe, raises: [].}
    computeIfAbsentFn*: proc(t: ptr lf_btable_t, key: pointer, mappingFn: lf_btable_mapping_fn, userData: pointer, outVal: ptr pointer): lf_status_t {.nimcall, gcsafe, raises: [].}
    atomicUpdateFn*: proc(t: ptr lf_btable_t, key: pointer, updateFn: lf_btable_update_fn, userData: pointer, outVal: ptr pointer): lf_status_t {.nimcall, gcsafe, raises: [].}
    upsertFn*: proc(t: ptr lf_btable_t, key: pointer, initialVal: pointer, updateFn: lf_btable_update_fn, userData: pointer, outVal: ptr pointer): lf_status_t {.nimcall, gcsafe, raises: [].}
    clearFn*: proc(t: ptr lf_btable_t): lf_status_t {.nimcall, gcsafe, raises: [].}
    lenFn*: proc(t: ptr lf_btable_t): csize_t {.nimcall, gcsafe, raises: [].}
    capFn*: proc(t: ptr lf_btable_t): csize_t {.nimcall, gcsafe, raises: [].}
    isEmptyFn*: proc(t: ptr lf_btable_t): bool {.nimcall, gcsafe, raises: [].}
    isFullFn*: proc(t: ptr lf_btable_t): bool {.nimcall, gcsafe, raises: [].}

  lf_btable_t* = lf_btable
  lfq_btable* = lf_btable
  lfq_btable_t* = lf_btable

  BTableImpl[N: static int] = object
    base: lf_btable_t
    raw: ptr BTable[pointer, pointer, N, ccMulti, ccMulti]

proc btablePutImpl[N: static int](t: ptr lf_btable_t, key: pointer, val: pointer, outInserted: ptr bool): lf_status_t {.nimcall, gcsafe, raises: [].} =
  let impl = cast[ptr BTableImpl[N]](t)
  cAbiBoundary:
    var ins = false
    var full = false
    let ok = impl.raw[].tryPutEx(key, val, addr ins, addr full)
    if outInserted != nil:
      outInserted[] = ins
    if ok:
      LF_OK
    elif full:
      LF_ERR_FULL
    else:
      LF_ERR_FAILURE

proc btableInsertImpl[N: static int](t: ptr lf_btable_t, key: pointer, val: pointer, outInserted: ptr bool): lf_status_t {.nimcall, gcsafe, raises: [].} =
  let impl = cast[ptr BTableImpl[N]](t)
  cAbiBoundary:
    var ins = false
    var full = false
    discard impl.raw[].tryInsertEx(key, val, addr ins, addr full)
    if outInserted != nil:
      outInserted[] = ins
    if full:
      LF_ERR_FULL
    else:
      LF_OK

proc btableGetImpl[N: static int](t: ptr lf_btable_t, key: pointer, outVal: ptr pointer): lf_status_t {.nimcall, gcsafe, raises: [].} =
  let impl = cast[ptr BTableImpl[N]](t)
  cAbiBoundary:
    var val: pointer = nil
    if impl.raw[].tryGet(key, val):
      outVal[] = val
      LF_OK
    else:
      LF_ERR_EMPTY

proc btableDeleteImpl[N: static int](t: ptr lf_btable_t, key: pointer, outDeleted: ptr bool): lf_status_t {.nimcall, gcsafe, raises: [].} =
  let impl = cast[ptr BTableImpl[N]](t)
  cAbiBoundary:
    let deleted = impl.raw[].remove(key)
    if outDeleted != nil:
      outDeleted[] = deleted
    if deleted:
      LF_OK
    else:
      LF_ERR_EMPTY

proc btableTakeImpl[N: static int](t: ptr lf_btable_t, key: pointer, outVal: ptr pointer): lf_status_t {.nimcall, gcsafe, raises: [].} =
  let impl = cast[ptr BTableImpl[N]](t)
  cAbiBoundary:
    var val: pointer = nil
    if impl.raw[].tryTake(key, val):
      outVal[] = val
      LF_OK
    else:
      LF_ERR_EMPTY

proc btableContainsImpl[N: static int](t: ptr lf_btable_t, key: pointer): bool {.nimcall, gcsafe, raises: [].} =
  let impl = cast[ptr BTableImpl[N]](t)
  try:
    impl.raw[].contains(key)
  except:
    false

proc btableComputeIfAbsentImpl[N: static int](
    t: ptr lf_btable_t,
    key: pointer,
    mappingFn: lf_btable_mapping_fn,
    userData: pointer,
    outVal: ptr pointer
): lf_status_t {.nimcall, gcsafe, raises: [].} =
  let impl = cast[ptr BTableImpl[N]](t)
  cAbiBoundary:
    var val: pointer = nil
    let ok = impl.raw[].tryComputeIfAbsent(key, proc(k: pointer): pointer {.gcsafe.} =
      mappingFn(k, userData)
    , val)
    if ok:
      if outVal != nil:
        outVal[] = val
      LF_OK
    else:
      LF_ERR_FULL

proc btableAtomicUpdateImpl[N: static int](
    t: ptr lf_btable_t,
    key: pointer,
    updateFn: lf_btable_update_fn,
    userData: pointer,
    outVal: ptr pointer
): lf_status_t {.nimcall, gcsafe, raises: [].} =
  let impl = cast[ptr BTableImpl[N]](t)
  cAbiBoundary:
    var val: pointer = nil
    let ok = impl.raw[].tryAtomicUpdate(key, proc(k: pointer, oldVal: pointer): pointer {.gcsafe.} =
      updateFn(k, oldVal, userData)
    , val)
    if ok:
      if outVal != nil:
        outVal[] = val
      LF_OK
    else:
      LF_ERR_EMPTY

proc btableUpsertImpl[N: static int](
    t: ptr lf_btable_t,
    key: pointer,
    initialVal: pointer,
    updateFn: lf_btable_update_fn,
    userData: pointer,
    outVal: ptr pointer
): lf_status_t {.nimcall, gcsafe, raises: [].} =
  let impl = cast[ptr BTableImpl[N]](t)
  cAbiBoundary:
    var val: pointer = nil
    let ok = impl.raw[].tryUpsert(key, initialVal, proc(k: pointer, oldVal: pointer): pointer {.gcsafe.} =
      updateFn(k, oldVal, userData)
    , val)
    if ok:
      if outVal != nil:
        outVal[] = val
      LF_OK
    else:
      LF_ERR_FULL

proc btableClearImpl[N: static int](t: ptr lf_btable_t): lf_status_t {.nimcall, gcsafe, raises: [].} =
  let impl = cast[ptr BTableImpl[N]](t)
  cAbiBoundary:
    impl.raw[].clearWith(t.destructor, t.userData)
    LF_OK

proc btableDestroyImpl[N: static int](t: ptr lf_btable_t): lf_status_t {.nimcall, gcsafe, raises: [].} =
  let impl = cast[ptr BTableImpl[N]](t)
  cAbiBoundary:
    if impl.raw != nil:
      impl.raw[].clearWith(t.destructor, t.userData)
      `=destroy`(impl.raw[])
      freeAligned(impl.raw)
      impl.raw = nil
    deallocShared(impl)
    LF_OK

proc btableLenImpl[N: static int](t: ptr lf_btable_t): csize_t {.nimcall, gcsafe, raises: [].} =
  let impl = cast[ptr BTableImpl[N]](t)
  csize_t(impl.raw[].len())

proc btableCapImpl[N: static int](t: ptr lf_btable_t): csize_t {.nimcall, gcsafe, raises: [].} =
  let impl = cast[ptr BTableImpl[N]](t)
  csize_t(impl.raw[].capacity())

proc btableIsEmptyImpl[N: static int](t: ptr lf_btable_t): bool {.nimcall, gcsafe, raises: [].} =
  let impl = cast[ptr BTableImpl[N]](t)
  impl.raw[].isEmpty()

proc btableIsFullImpl[N: static int](t: ptr lf_btable_t): bool {.nimcall, gcsafe, raises: [].} =
  let impl = cast[ptr BTableImpl[N]](t)
  impl.raw[].isFull()

proc createBTableTier[N: static int](
    effCap: int,
    destructor: lf_btable_destructor_fn,
    userData: pointer,
    outTable: ptr ptr lf_btable_t
): lf_status_t {.nimcall, gcsafe, raises: [].} =
  cAbiBoundary:
    let impl = cast[ptr BTableImpl[N]](allocShared0(sizeof(BTableImpl[N])))
    let raw = allocAligned[BTable[pointer, pointer, N, ccMulti, ccMulti]]()
    raw[] = initBTable[pointer, pointer, N]()
    raw[].setEffectiveCapacity(effCap)
    impl.raw = raw
    impl.base.destructor = destructor
    impl.base.userData = userData
    impl.base.destroyFn = btableDestroyImpl[N]
    impl.base.putFn = btablePutImpl[N]
    impl.base.insertFn = btableInsertImpl[N]
    impl.base.getFn = btableGetImpl[N]
    impl.base.deleteFn = btableDeleteImpl[N]
    impl.base.takeFn = btableTakeImpl[N]
    impl.base.containsFn = btableContainsImpl[N]
    impl.base.computeIfAbsentFn = btableComputeIfAbsentImpl[N]
    impl.base.atomicUpdateFn = btableAtomicUpdateImpl[N]
    impl.base.upsertFn = btableUpsertImpl[N]
    impl.base.clearFn = btableClearImpl[N]
    impl.base.lenFn = btableLenImpl[N]
    impl.base.capFn = btableCapImpl[N]
    impl.base.isEmptyFn = btableIsEmptyImpl[N]
    impl.base.isFullFn = btableIsFullImpl[N]
    outTable[] = cast[ptr lf_btable_t](impl)
    LF_OK

proc lf_btable_create*(
    capacity: csize_t,
    destructor: lf_btable_destructor_fn,
    user_data: pointer,
    out_table: ptr ptr lf_btable_t
): lf_status_t {.exportc: "lf_btable_create", cdecl, gcsafe, raises: [].} =
  if unlikely(capacity == 0 or out_table == nil):
    return LF_ERR_INVALID_ARG
  if unlikely(capacity > 65536):
    return LF_ERR_UNSUPPORTED
  let cap = int(capacity)
  if cap <= 16:
    createBTableTier[16](cap, destructor, user_data, out_table)
  elif cap <= 64:
    createBTableTier[64](cap, destructor, user_data, out_table)
  elif cap <= 256:
    createBTableTier[256](cap, destructor, user_data, out_table)
  elif cap <= 1024:
    createBTableTier[1024](cap, destructor, user_data, out_table)
  elif cap <= 4096:
    createBTableTier[4096](cap, destructor, user_data, out_table)
  elif cap <= 16384:
    createBTableTier[16384](cap, destructor, user_data, out_table)
  else:
    createBTableTier[65536](cap, destructor, user_data, out_table)

proc lf_btable_destroy*(
    table: ptr lf_btable_t
): lf_status_t {.exportc: "lf_btable_destroy", cdecl, gcsafe, raises: [].} =
  if unlikely(table == nil or table.destroyFn == nil):
    return LF_ERR_INVALID_ARG
  table.destroyFn(table)

proc lf_btable_put*(
    table: ptr lf_btable_t,
    key: pointer,
    val: pointer,
    out_inserted: ptr bool
): lf_status_t {.exportc: "lf_btable_put", cdecl, gcsafe, raises: [].} =
  if unlikely(table == nil or table.putFn == nil):
    return LF_ERR_INVALID_ARG
  table.putFn(table, key, val, out_inserted)

proc lf_btable_insert*(
    table: ptr lf_btable_t,
    key: pointer,
    val: pointer,
    out_inserted: ptr bool
): lf_status_t {.exportc: "lf_btable_insert", cdecl, gcsafe, raises: [].} =
  if unlikely(table == nil or table.insertFn == nil):
    return LF_ERR_INVALID_ARG
  table.insertFn(table, key, val, out_inserted)

proc lf_btable_get*(
    table: ptr lf_btable_t,
    key: pointer,
    out_val: ptr pointer
): lf_status_t {.exportc: "lf_btable_get", cdecl, gcsafe, raises: [].} =
  if unlikely(table == nil or table.getFn == nil or out_val == nil):
    return LF_ERR_INVALID_ARG
  table.getFn(table, key, out_val)

proc lf_btable_delete*(
    table: ptr lf_btable_t,
    key: pointer,
    out_deleted: ptr bool
): lf_status_t {.exportc: "lf_btable_delete", cdecl, gcsafe, raises: [].} =
  if unlikely(table == nil or table.deleteFn == nil):
    return LF_ERR_INVALID_ARG
  table.deleteFn(table, key, out_deleted)

proc lf_btable_remove*(
    table: ptr lf_btable_t,
    key: pointer,
    out_removed: ptr bool
): lf_status_t {.exportc: "lf_btable_remove", cdecl, gcsafe, raises: [].} =
  lf_btable_delete(table, key, out_removed)

proc lf_btable_take*(
    table: ptr lf_btable_t,
    key: pointer,
    out_val: ptr pointer
): lf_status_t {.exportc: "lf_btable_take", cdecl, gcsafe, raises: [].} =
  if unlikely(table == nil or table.takeFn == nil or out_val == nil):
    return LF_ERR_INVALID_ARG
  table.takeFn(table, key, out_val)

proc lf_btable_contains*(
    table: ptr lf_btable_t,
    key: pointer
): bool {.exportc: "lf_btable_contains", cdecl, gcsafe, raises: [].} =
  if unlikely(table == nil or table.containsFn == nil):
    return false
  table.containsFn(table, key)

proc lf_btable_compute_if_absent*(
    table: ptr lf_btable_t,
    key: pointer,
    mapping_fn: lf_btable_mapping_fn,
    user_data: pointer,
    out_val: ptr pointer
): lf_status_t {.exportc: "lf_btable_compute_if_absent", cdecl, gcsafe, raises: [].} =
  if unlikely(table == nil or table.computeIfAbsentFn == nil or mapping_fn == nil):
    return LF_ERR_INVALID_ARG
  table.computeIfAbsentFn(table, key, mapping_fn, user_data, out_val)

proc lf_btable_atomic_update*(
    table: ptr lf_btable_t,
    key: pointer,
    update_fn: lf_btable_update_fn,
    user_data: pointer,
    out_val: ptr pointer
): lf_status_t {.exportc: "lf_btable_atomic_update", cdecl, gcsafe, raises: [].} =
  if unlikely(table == nil or table.atomicUpdateFn == nil or update_fn == nil):
    return LF_ERR_INVALID_ARG
  table.atomicUpdateFn(table, key, update_fn, user_data, out_val)

proc lf_btable_upsert*(
    table: ptr lf_btable_t,
    key: pointer,
    initial_val: pointer,
    update_fn: lf_btable_update_fn,
    user_data: pointer,
    out_val: ptr pointer
): lf_status_t {.exportc: "lf_btable_upsert", cdecl, gcsafe, raises: [].} =
  if unlikely(table == nil or table.upsertFn == nil or update_fn == nil):
    return LF_ERR_INVALID_ARG
  table.upsertFn(table, key, initial_val, update_fn, user_data, out_val)

proc lf_btable_clear*(
    table: ptr lf_btable_t
): lf_status_t {.exportc: "lf_btable_clear", cdecl, gcsafe, raises: [].} =
  if unlikely(table == nil or table.clearFn == nil):
    return LF_ERR_INVALID_ARG
  table.clearFn(table)

proc lf_btable_len*(
    table: ptr lf_btable_t
): csize_t {.exportc: "lf_btable_len", cdecl, gcsafe, raises: [].} =
  if unlikely(table == nil or table.lenFn == nil):
    return 0.csize_t
  table.lenFn(table)

proc lf_btable_capacity*(
    table: ptr lf_btable_t
): csize_t {.exportc: "lf_btable_capacity", cdecl, gcsafe, raises: [].} =
  if unlikely(table == nil or table.capFn == nil):
    return 0.csize_t
  table.capFn(table)

proc lf_btable_is_empty*(
    table: ptr lf_btable_t
): bool {.exportc: "lf_btable_is_empty", cdecl, gcsafe, raises: [].} =
  if unlikely(table == nil or table.isEmptyFn == nil):
    return true
  table.isEmptyFn(table)

proc lf_btable_is_full*(
    table: ptr lf_btable_t
): bool {.exportc: "lf_btable_is_full", cdecl, gcsafe, raises: [].} =
  if unlikely(table == nil or table.isFullFn == nil):
    return false
  table.isFullFn(table)

# ==============================================================================
# 19. BQueue128 (128-Bit DWCAS Bounded MPMC Queue)
# ==============================================================================

type
  lf_bqueue128_destructor_fn* = proc(item: pointer, userData: pointer) {.cdecl, gcsafe, raises: [].}
  lfq_bqueue128_destructor_fn* = lf_bqueue128_destructor_fn

  lf_bqueue128_t* = object
    destructor*: lf_bqueue128_destructor_fn
    userData*: pointer
    destroyFn*: proc(q: ptr lf_bqueue128_t): lf_status_t {.nimcall, gcsafe, raises: [].}
    pushFn*: proc(q: ptr lf_bqueue128_t, item: pointer): lf_status_t {.nimcall, gcsafe, raises: [].}
    popFn*: proc(q: ptr lf_bqueue128_t, outItem: ptr pointer): lf_status_t {.nimcall, gcsafe, raises: [].}
    peekFn*: proc(q: ptr lf_bqueue128_t, outItem: ptr pointer): lf_status_t {.nimcall, gcsafe, raises: [].}
    clearFn*: proc(q: ptr lf_bqueue128_t): lf_status_t {.nimcall, gcsafe, raises: [].}
    lenFn*: proc(q: ptr lf_bqueue128_t): csize_t {.nimcall, gcsafe, raises: [].}
    capFn*: proc(q: ptr lf_bqueue128_t): csize_t {.nimcall, gcsafe, raises: [].}
    isEmptyFn*: proc(q: ptr lf_bqueue128_t): bool {.nimcall, gcsafe, raises: [].}
    isFullFn*: proc(q: ptr lf_bqueue128_t): bool {.nimcall, gcsafe, raises: [].}

  lfq_bqueue128_t* = lf_bqueue128_t

  BQueue128Impl[N: static int] = object
    base*: lf_bqueue128_t
    raw*: ptr BQueue128[pointer, N]

proc bqueue128PushImpl[N: static int](q: ptr lf_bqueue128_t, item: pointer): lf_status_t {.nimcall, gcsafe, raises: [].} =
  let impl = cast[ptr BQueue128Impl[N]](q)
  cAbiBoundary:
    if impl.raw[].tryPush(item):
      LF_OK
    else:
      LF_ERR_FULL

proc bqueue128PopImpl[N: static int](q: ptr lf_bqueue128_t, outItem: ptr pointer): lf_status_t {.nimcall, gcsafe, raises: [].} =
  let impl = cast[ptr BQueue128Impl[N]](q)
  cAbiBoundary:
    var item: pointer = nil
    if impl.raw[].tryPop(item):
      if outItem != nil:
        outItem[] = item
      LF_OK
    else:
      LF_ERR_EMPTY

proc bqueue128PeekImpl[N: static int](q: ptr lf_bqueue128_t, outItem: ptr pointer): lf_status_t {.nimcall, gcsafe, raises: [].} =
  let impl = cast[ptr BQueue128Impl[N]](q)
  cAbiBoundary:
    var item: pointer = nil
    if impl.raw[].tryPeek(item):
      if outItem != nil:
        outItem[] = item
      LF_OK
    else:
      LF_ERR_EMPTY

proc bqueue128ClearImpl[N: static int](q: ptr lf_bqueue128_t): lf_status_t {.nimcall, gcsafe, raises: [].} =
  let impl = cast[ptr BQueue128Impl[N]](q)
  cAbiBoundary:
    if q.destructor != nil:
      var item: pointer = nil
      while impl.raw[].tryPop(item):
        try:
          q.destructor(item, q.userData)
        except:
          discard
    impl.raw[].clear()
    LF_OK

proc bqueue128DestroyImpl[N: static int](q: ptr lf_bqueue128_t): lf_status_t {.nimcall, gcsafe, raises: [].} =
  let impl = cast[ptr BQueue128Impl[N]](q)
  cAbiBoundary:
    if impl.raw != nil:
      if q.destructor != nil:
        var item: pointer = nil
        while impl.raw[].tryPop(item):
          try:
            q.destructor(item, q.userData)
          except:
            discard
      `=destroy`(impl.raw[])
      freeAlignedBQueue128(impl.raw)
      impl.raw = nil
    deallocShared(impl)
    LF_OK

proc bqueue128LenImpl[N: static int](q: ptr lf_bqueue128_t): csize_t {.nimcall, gcsafe, raises: [].} =
  let impl = cast[ptr BQueue128Impl[N]](q)
  csize_t(impl.raw[].len())

proc bqueue128CapImpl[N: static int](q: ptr lf_bqueue128_t): csize_t {.nimcall, gcsafe, raises: [].} =
  let impl = cast[ptr BQueue128Impl[N]](q)
  csize_t(impl.raw[].capacity())

proc bqueue128IsEmptyImpl[N: static int](q: ptr lf_bqueue128_t): bool {.nimcall, gcsafe, raises: [].} =
  let impl = cast[ptr BQueue128Impl[N]](q)
  impl.raw[].isEmpty()

proc bqueue128IsFullImpl[N: static int](q: ptr lf_bqueue128_t): bool {.nimcall, gcsafe, raises: [].} =
  let impl = cast[ptr BQueue128Impl[N]](q)
  impl.raw[].isFull()

proc createBQueue128Tier[N: static int](
    destructor: lf_bqueue128_destructor_fn,
    userData: pointer,
    outQueue: ptr ptr lf_bqueue128_t
): lf_status_t {.nimcall, gcsafe, raises: [].} =
  cAbiBoundary:
    let impl = cast[ptr BQueue128Impl[N]](allocShared0(sizeof(BQueue128Impl[N])))
    let raw = allocAlignedBQueue128[pointer, N]()
    impl.raw = raw
    impl.base.destructor = destructor
    impl.base.userData = userData
    impl.base.destroyFn = bqueue128DestroyImpl[N]
    impl.base.pushFn = bqueue128PushImpl[N]
    impl.base.popFn = bqueue128PopImpl[N]
    impl.base.peekFn = bqueue128PeekImpl[N]
    impl.base.clearFn = bqueue128ClearImpl[N]
    impl.base.lenFn = bqueue128LenImpl[N]
    impl.base.capFn = bqueue128CapImpl[N]
    impl.base.isEmptyFn = bqueue128IsEmptyImpl[N]
    impl.base.isFullFn = bqueue128IsFullImpl[N]
    outQueue[] = cast[ptr lf_bqueue128_t](impl)
    LF_OK

proc lf_bqueue128_create*(
    capacity: csize_t,
    destructor: lf_bqueue128_destructor_fn,
    user_data: pointer,
    out_queue: ptr ptr lf_bqueue128_t
): lf_status_t {.exportc: "lf_bqueue128_create", cdecl, gcsafe, raises: [].} =
  if unlikely(capacity == 0 or out_queue == nil):
    return LF_ERR_INVALID_ARG
  if unlikely(capacity > 65536):
    return LF_ERR_UNSUPPORTED
  let cap = int(capacity)
  if cap <= 4:
    createBQueue128Tier[4](destructor, user_data, out_queue)
  elif cap <= 8:
    createBQueue128Tier[8](destructor, user_data, out_queue)
  elif cap <= 16:
    createBQueue128Tier[16](destructor, user_data, out_queue)
  elif cap <= 32:
    createBQueue128Tier[32](destructor, user_data, out_queue)
  elif cap <= 64:
    createBQueue128Tier[64](destructor, user_data, out_queue)
  elif cap <= 128:
    createBQueue128Tier[128](destructor, user_data, out_queue)
  elif cap <= 256:
    createBQueue128Tier[256](destructor, user_data, out_queue)
  elif cap <= 512:
    createBQueue128Tier[512](destructor, user_data, out_queue)
  elif cap <= 1024:
    createBQueue128Tier[1024](destructor, user_data, out_queue)
  elif cap <= 2048:
    createBQueue128Tier[2048](destructor, user_data, out_queue)
  elif cap <= 4096:
    createBQueue128Tier[4096](destructor, user_data, out_queue)
  elif cap <= 8192:
    createBQueue128Tier[8192](destructor, user_data, out_queue)
  elif cap <= 16384:
    createBQueue128Tier[16384](destructor, user_data, out_queue)
  elif cap <= 32768:
    createBQueue128Tier[32768](destructor, user_data, out_queue)
  else:
    createBQueue128Tier[65536](destructor, user_data, out_queue)

proc lf_bqueue128_destroy*(
    queue: ptr lf_bqueue128_t
): lf_status_t {.exportc: "lf_bqueue128_destroy", cdecl, gcsafe, raises: [].} =
  if unlikely(queue == nil or queue.destroyFn == nil):
    return LF_ERR_INVALID_ARG
  queue.destroyFn(queue)

proc lf_bqueue128_push*(
    queue: ptr lf_bqueue128_t,
    item: pointer
): lf_status_t {.exportc: "lf_bqueue128_push", cdecl, gcsafe, raises: [].} =
  if unlikely(queue == nil or queue.pushFn == nil):
    return LF_ERR_INVALID_ARG
  queue.pushFn(queue, item)

proc lf_bqueue128_pop*(
    queue: ptr lf_bqueue128_t,
    out_item: ptr pointer
): lf_status_t {.exportc: "lf_bqueue128_pop", cdecl, gcsafe, raises: [].} =
  if unlikely(queue == nil or queue.popFn == nil or out_item == nil):
    return LF_ERR_INVALID_ARG
  queue.popFn(queue, out_item)

proc lf_bqueue128_peek*(
    queue: ptr lf_bqueue128_t,
    out_item: ptr pointer
): lf_status_t {.exportc: "lf_bqueue128_peek", cdecl, gcsafe, raises: [].} =
  if unlikely(queue == nil or queue.peekFn == nil or out_item == nil):
    return LF_ERR_INVALID_ARG
  queue.peekFn(queue, out_item)

proc lf_bqueue128_clear*(
    queue: ptr lf_bqueue128_t
): lf_status_t {.exportc: "lf_bqueue128_clear", cdecl, gcsafe, raises: [].} =
  if unlikely(queue == nil or queue.clearFn == nil):
    return LF_ERR_INVALID_ARG
  queue.clearFn(queue)

proc lf_bqueue128_len*(
    queue: ptr lf_bqueue128_t
): csize_t {.exportc: "lf_bqueue128_len", cdecl, gcsafe, raises: [].} =
  if unlikely(queue == nil or queue.lenFn == nil):
    return 0
  queue.lenFn(queue)

proc lf_bqueue128_capacity*(
    queue: ptr lf_bqueue128_t
): csize_t {.exportc: "lf_bqueue128_capacity", cdecl, gcsafe, raises: [].} =
  if unlikely(queue == nil or queue.capFn == nil):
    return 0
  queue.capFn(queue)

proc lf_bqueue128_is_empty*(
    queue: ptr lf_bqueue128_t
): bool {.exportc: "lf_bqueue128_is_empty", cdecl, gcsafe, raises: [].} =
  if unlikely(queue == nil or queue.isEmptyFn == nil):
    return true
  queue.isEmptyFn(queue)

proc lf_bqueue128_is_full*(
    queue: ptr lf_bqueue128_t
): bool {.exportc: "lf_bqueue128_is_full", cdecl, gcsafe, raises: [].} =
  if unlikely(queue == nil or queue.isFullFn == nil):
    return false
  queue.isFullFn(queue)


# ==============================================================================
# Backward Compatibility Forwarders (lfq_* -> lf_*)
# ==============================================================================

proc lfq_unbounded_mpmc_create*(
    segment_size: csize_t,
    max_threads: csize_t,
    destructor: lfq_item_destructor_fn,
    user_data: pointer,
    out_queue: ptr ptr lfq_queue_t
): lfq_status_t {.exportc: "lfq_unbounded_mpmc_create", cdecl, gcsafe, raises: [].} =
  lf_unbounded_mpmc_create(segment_size, max_threads, destructor, user_data, out_queue)

proc lfq_bounded_mpmc_create*(
    capacity: csize_t,
    max_producers: csize_t,
    max_consumers: csize_t,
    destructor: lfq_item_destructor_fn,
    user_data: pointer,
    out_queue: ptr ptr lfq_queue_t
): lfq_status_t {.exportc: "lfq_bounded_mpmc_create", cdecl, gcsafe, raises: [].} =
  lf_bounded_mpmc_create(capacity, max_producers, max_consumers, destructor, user_data, out_queue)

proc lfq_queue_close*(queue: ptr lfq_queue_t): lfq_status_t {.exportc: "lfq_queue_close", cdecl, gcsafe, raises: [].} =
  lf_queue_close(queue)

proc lfq_queue_destroy*(queue: ptr lfq_queue_t): lfq_status_t {.exportc: "lfq_queue_destroy", cdecl, gcsafe, raises: [].} =
  lf_queue_destroy(queue)

proc lfq_producer_acquire*(
    queue: ptr lfq_queue_t,
    out_prod: ptr ptr lfq_producer_t
): lfq_status_t {.exportc: "lfq_producer_acquire", cdecl, gcsafe, raises: [].} =
  lf_producer_acquire(queue, out_prod)

proc lfq_producer_release*(prod: ptr lfq_producer_t): lfq_status_t {.exportc: "lfq_producer_release", cdecl, gcsafe, raises: [].} =
  lf_producer_release(prod)

proc lfq_consumer_acquire*(
    queue: ptr lfq_queue_t,
    out_cons: ptr ptr lfq_consumer_t
): lfq_status_t {.exportc: "lfq_consumer_acquire", cdecl, gcsafe, raises: [].} =
  lf_consumer_acquire(queue, out_cons)

proc lfq_consumer_release*(cons: ptr lfq_consumer_t): lfq_status_t {.exportc: "lfq_consumer_release", cdecl, gcsafe, raises: [].} =
  lf_consumer_release(cons)

proc lfq_push*(prod: ptr lfq_producer_t, item: pointer): lfq_status_t {.exportc: "lfq_push", cdecl, gcsafe, raises: [].} =
  lf_push(prod, item)

proc lfq_pop*(cons: ptr lfq_consumer_t, out_item: ptr pointer): lfq_status_t {.exportc: "lfq_pop", cdecl, gcsafe, raises: [].} =
  lf_pop(cons, out_item)

proc lfq_pop_batch*(
    cons: ptr lfq_consumer_t,
    out_items: ptr pointer,
    max_count: csize_t
): csize_t {.exportc: "lfq_pop_batch", cdecl, gcsafe, raises: [].} =
  lf_pop_batch(cons, out_items, max_count)

proc lfq_queue_len*(queue: ptr lfq_queue_t): csize_t {.exportc: "lfq_queue_len", cdecl, gcsafe, raises: [].} =
  lf_queue_len(queue)

proc lfq_queue_is_empty*(queue: ptr lfq_queue_t): bool {.exportc: "lfq_queue_is_empty", cdecl, gcsafe, raises: [].} =
  lf_queue_is_empty(queue)

proc lfq_queue_is_closed*(queue: ptr lfq_queue_t): bool {.exportc: "lfq_queue_is_closed", cdecl, gcsafe, raises: [].} =
  lf_queue_is_closed(queue)

proc lfq_queue_push*(prod: ptr lfq_producer_t, item: pointer): lfq_status_t {.exportc: "lfq_queue_push", cdecl, gcsafe, raises: [].} =
  lf_queue_push(prod, item)

proc lfq_queue_pop*(cons: ptr lfq_consumer_t, out_item: ptr pointer): lfq_status_t {.exportc: "lfq_queue_pop", cdecl, gcsafe, raises: [].} =
  lf_queue_pop(cons, out_item)

proc lfq_stack_create*(
    destructor: lfq_item_destructor_fn,
    user_data: pointer,
    out_stack: ptr ptr lfq_stack_t
): lfq_status_t {.exportc: "lfq_stack_create", cdecl, gcsafe, raises: [].} =
  lf_stack_create(destructor, user_data, out_stack)

proc lfq_stack_destroy*(stack: ptr lfq_stack_t): lfq_status_t {.exportc: "lfq_stack_destroy", cdecl, gcsafe, raises: [].} =
  lf_stack_destroy(stack)

proc lfq_stack_push*(stack: ptr lfq_stack_t, item: pointer): lfq_status_t {.exportc: "lfq_stack_push", cdecl, gcsafe, raises: [].} =
  lf_stack_push(stack, item)

proc lfq_stack_pop*(stack: ptr lfq_stack_t, out_item: ptr pointer): lfq_status_t {.exportc: "lfq_stack_pop", cdecl, gcsafe, raises: [].} =
  lf_stack_pop(stack, out_item)

proc lfq_stack_peek*(stack: ptr lfq_stack_t, out_item: ptr pointer): lfq_status_t {.exportc: "lfq_stack_peek", cdecl, gcsafe, raises: [].} =
  lf_stack_peek(stack, out_item)

proc lfq_stack_drain*(
    stack: ptr lfq_stack_t,
    out_items: ptr pointer,
    max_count: csize_t
): csize_t {.exportc: "lfq_stack_drain", cdecl, gcsafe, raises: [].} =
  lf_stack_drain(stack, out_items, max_count)

proc lfq_stack_len*(stack: ptr lfq_stack_t): csize_t {.exportc: "lfq_stack_len", cdecl, gcsafe, raises: [].} =
  lf_stack_len(stack)

proc lfq_stack_is_empty*(stack: ptr lfq_stack_t): bool {.exportc: "lfq_stack_is_empty", cdecl, gcsafe, raises: [].} =
  lf_stack_is_empty(stack)

proc lfq_deque_create*(
    initial_capacity: csize_t,
    destructor: lfq_item_destructor_fn,
    user_data: pointer,
    out_deque: ptr ptr lfq_deque_t
): lfq_status_t {.exportc: "lfq_deque_create", cdecl, gcsafe, raises: [].} =
  lf_deque_create(initial_capacity, destructor, user_data, out_deque)

proc lfq_deque_destroy*(deque: ptr lfq_deque_t): lfq_status_t {.exportc: "lfq_deque_destroy", cdecl, gcsafe, raises: [].} =
  lf_deque_destroy(deque)

proc lfq_deque_push*(deque: ptr lfq_deque_t, item: pointer): lfq_status_t {.exportc: "lfq_deque_push", cdecl, gcsafe, raises: [].} =
  lf_deque_push(deque, item)

proc lfq_deque_pop*(deque: ptr lfq_deque_t, out_item: ptr pointer): lfq_status_t {.exportc: "lfq_deque_pop", cdecl, gcsafe, raises: [].} =
  lf_deque_pop(deque, out_item)

proc lfq_deque_steal*(deque: ptr lfq_deque_t, out_item: ptr pointer): lfq_status_t {.exportc: "lfq_deque_steal", cdecl, gcsafe, raises: [].} =
  lf_deque_steal(deque, out_item)

proc lfq_deque_steal_batch*(
    deque: ptr lfq_deque_t,
    out_items: ptr pointer,
    max_count: csize_t
): csize_t {.exportc: "lfq_deque_steal_batch", cdecl, gcsafe, raises: [].} =
  lf_deque_steal_batch(deque, out_items, max_count)

proc lfq_deque_len*(deque: ptr lfq_deque_t): csize_t {.exportc: "lfq_deque_len", cdecl, gcsafe, raises: [].} =
  lf_deque_len(deque)

proc lfq_deque_capacity*(deque: ptr lfq_deque_t): csize_t {.exportc: "lfq_deque_capacity", cdecl, gcsafe, raises: [].} =
  lf_deque_capacity(deque)

proc lfq_deque_is_empty*(deque: ptr lfq_deque_t): bool {.exportc: "lfq_deque_is_empty", cdecl, gcsafe, raises: [].} =
  lf_deque_is_empty(deque)

proc lfq_table_create*(
    destructor: lfq_entry_destructor_fn,
    user_data: pointer,
    out_table: ptr ptr lfq_table_t
): lfq_status_t {.exportc: "lfq_table_create", cdecl, gcsafe, raises: [].} =
  lf_table_create(destructor, user_data, out_table)

proc lfq_table_destroy*(table: ptr lfq_table_t): lfq_status_t {.exportc: "lfq_table_destroy", cdecl, gcsafe, raises: [].} =
  lf_table_destroy(table)

proc lfq_table_put*(
    table: ptr lfq_table_t,
    key: pointer,
    val: pointer,
    out_inserted: ptr bool
): lfq_status_t {.exportc: "lfq_table_put", cdecl, gcsafe, raises: [].} =
  lf_table_put(table, key, val, out_inserted)

proc lfq_table_get*(
    table: ptr lfq_table_t,
    key: pointer,
    out_val: ptr pointer
): lfq_status_t {.exportc: "lfq_table_get", cdecl, gcsafe, raises: [].} =
  lf_table_get(table, key, out_val)

proc lfq_table_delete*(
    table: ptr lfq_table_t,
    key: pointer,
    out_deleted: ptr bool
): lfq_status_t {.exportc: "lfq_table_delete", cdecl, gcsafe, raises: [].} =
  lf_table_delete(table, key, out_deleted)

proc lfq_table_remove*(
    table: ptr lfq_table_t,
    key: pointer,
    out_removed: ptr bool
): lfq_status_t {.exportc: "lfq_table_remove", cdecl, gcsafe, raises: [].} =
  lf_table_remove(table, key, out_removed)

proc lfq_table_contains*(table: ptr lfq_table_t, key: pointer): bool {.exportc: "lfq_table_contains", cdecl, gcsafe, raises: [].} =
  lf_table_contains(table, key)

proc lfq_table_len*(table: ptr lfq_table_t): csize_t {.exportc: "lfq_table_len", cdecl, gcsafe, raises: [].} =
  lf_table_len(table)

proc lfq_table_is_empty*(table: ptr lfq_table_t): bool {.exportc: "lfq_table_is_empty", cdecl, gcsafe, raises: [].} =
  lf_table_is_empty(table)

proc lfq_set_create*(
    destructor: lfq_item_destructor_fn,
    user_data: pointer,
    out_set: ptr ptr lfq_set_t
): lfq_status_t {.exportc: "lfq_set_create", cdecl, gcsafe, raises: [].} =
  lf_set_create(destructor, user_data, out_set)

proc lfq_set_destroy*(set: ptr lfq_set_t): lfq_status_t {.exportc: "lfq_set_destroy", cdecl, gcsafe, raises: [].} =
  lf_set_destroy(set)

proc lfq_set_insert*(
    set: ptr lfq_set_t,
    item: pointer,
    out_inserted: ptr bool
): lfq_status_t {.exportc: "lfq_set_insert", cdecl, gcsafe, raises: [].} =
  lf_set_insert(set, item, out_inserted)

proc lfq_set_remove*(
    set: ptr lfq_set_t,
    item: pointer,
    out_removed: ptr bool
): lfq_status_t {.exportc: "lfq_set_remove", cdecl, gcsafe, raises: [].} =
  lf_set_remove(set, item, out_removed)

proc lfq_set_contains*(set: ptr lfq_set_t, item: pointer): bool {.exportc: "lfq_set_contains", cdecl, gcsafe, raises: [].} =
  lf_set_contains(set, item)

proc lfq_set_len*(set: ptr lfq_set_t): csize_t {.exportc: "lfq_set_len", cdecl, gcsafe, raises: [].} =
  lf_set_len(set)

proc lfq_set_is_empty*(set: ptr lfq_set_t): bool {.exportc: "lfq_set_is_empty", cdecl, gcsafe, raises: [].} =
  lf_set_is_empty(set)

proc lfq_taskpool_create*(
    num_threads: csize_t,
    out_pool: ptr ptr lfq_taskpool_t
): lfq_status_t {.exportc: "lfq_taskpool_create", cdecl, gcsafe, raises: [].} =
  lf_taskpool_create(num_threads, out_pool)

proc lfq_taskpool_destroy*(pool: ptr lfq_taskpool_t): lfq_status_t {.exportc: "lfq_taskpool_destroy", cdecl, gcsafe, raises: [].} =
  lf_taskpool_destroy(pool)

proc lfq_taskpool_spawn*(
    pool: ptr lfq_taskpool_t,
    task: lfq_task_fn,
    arg: pointer
): lfq_status_t {.exportc: "lfq_taskpool_spawn", cdecl, gcsafe, raises: [].} =
  lf_taskpool_spawn(pool, task, arg)

proc lfq_taskpool_parallel_for*(
    pool: ptr lfq_taskpool_t,
    start: csize_t,
    stop: csize_t,
    task: lfq_for_task_fn,
    arg: pointer,
    chunk_size: csize_t
): lfq_status_t {.exportc: "lfq_taskpool_parallel_for", cdecl, gcsafe, raises: [].} =
  lf_taskpool_parallel_for(pool, start, stop, task, arg, chunk_size)

proc lfq_taskpool_sync*(pool: ptr lfq_taskpool_t): lfq_status_t {.exportc: "lfq_taskpool_sync", cdecl, gcsafe, raises: [].} =
  lf_taskpool_sync(pool)

proc lfq_taskpool_num_workers*(pool: ptr lfq_taskpool_t): csize_t {.exportc: "lfq_taskpool_num_workers", cdecl, gcsafe, raises: [].} =
  lf_taskpool_num_workers(pool)

proc lfq_ctrie_create*(
    destructor: lfq_entry_destructor_fn,
    user_data: pointer,
    out_ctrie: ptr ptr lfq_ctrie_t
): lfq_status_t {.exportc: "lfq_ctrie_create", cdecl, gcsafe, raises: [].} =
  lf_ctrie_create(destructor, user_data, out_ctrie)

proc lfq_ctrie_destroy*(ctrie: ptr lfq_ctrie_t): lfq_status_t {.exportc: "lfq_ctrie_destroy", cdecl, gcsafe, raises: [].} =
  lf_ctrie_destroy(ctrie)

proc lfq_ctrie_insert*(
    ctrie: ptr lfq_ctrie_t,
    key: pointer,
    val: pointer,
    out_inserted: ptr bool
): lfq_status_t {.exportc: "lfq_ctrie_insert", cdecl, gcsafe, raises: [].} =
  lf_ctrie_insert(ctrie, key, val, out_inserted)

proc lfq_ctrie_put*(
    ctrie: ptr lfq_ctrie_t,
    key: pointer,
    val: pointer,
    out_inserted: ptr bool
): lfq_status_t {.exportc: "lfq_ctrie_put", cdecl, gcsafe, raises: [].} =
  lf_ctrie_put(ctrie, key, val, out_inserted)

proc lfq_ctrie_lookup*(
    ctrie: ptr lfq_ctrie_t,
    key: pointer,
    out_val: ptr pointer
): lfq_status_t {.exportc: "lfq_ctrie_lookup", cdecl, gcsafe, raises: [].} =
  lf_ctrie_lookup(ctrie, key, out_val)

proc lfq_ctrie_get*(
    ctrie: ptr lfq_ctrie_t,
    key: pointer,
    out_val: ptr pointer
): lfq_status_t {.exportc: "lfq_ctrie_get", cdecl, gcsafe, raises: [].} =
  lf_ctrie_get(ctrie, key, out_val)

proc lfq_ctrie_remove*(
    ctrie: ptr lfq_ctrie_t,
    key: pointer,
    out_removed: ptr bool
): lfq_status_t {.exportc: "lfq_ctrie_remove", cdecl, gcsafe, raises: [].} =
  lf_ctrie_remove(ctrie, key, out_removed)

proc lfq_ctrie_delete*(
    ctrie: ptr lfq_ctrie_t,
    key: pointer,
    out_deleted: ptr bool
): lfq_status_t {.exportc: "lfq_ctrie_delete", cdecl, gcsafe, raises: [].} =
  lf_ctrie_delete(ctrie, key, out_deleted)

proc lfq_ctrie_contains*(ctrie: ptr lfq_ctrie_t, key: pointer): bool {.exportc: "lfq_ctrie_contains", cdecl, gcsafe, raises: [].} =
  lf_ctrie_contains(ctrie, key)

proc lfq_ctrie_len*(ctrie: ptr lfq_ctrie_t): csize_t {.exportc: "lfq_ctrie_len", cdecl, gcsafe, raises: [].} =
  lf_ctrie_len(ctrie)

proc lfq_ctrie_is_empty*(ctrie: ptr lfq_ctrie_t): bool {.exportc: "lfq_ctrie_is_empty", cdecl, gcsafe, raises: [].} =
  lf_ctrie_is_empty(ctrie)

proc lfq_ctrie_snapshot*(
    ctrie: ptr lfq_ctrie_t,
    out_snapshot: ptr ptr lfq_ctrie_snapshot_t
): lfq_status_t {.exportc: "lfq_ctrie_snapshot", cdecl, gcsafe, raises: [].} =
  lf_ctrie_snapshot(ctrie, out_snapshot)

proc lfq_ctrie_snapshot_create*(
    ctrie: ptr lfq_ctrie_t,
    out_snapshot: ptr ptr lfq_ctrie_snapshot_t
): lfq_status_t {.exportc: "lfq_ctrie_snapshot_create", cdecl, gcsafe, raises: [].} =
  lf_ctrie_snapshot_create(ctrie, out_snapshot)

proc lfq_ctrie_snapshot_destroy*(snapshot: ptr lfq_ctrie_snapshot_t): lfq_status_t {.exportc: "lfq_ctrie_snapshot_destroy", cdecl, gcsafe, raises: [].} =
  lf_ctrie_snapshot_destroy(snapshot)

proc lfq_ctrie_snapshot_lookup*(
    snapshot: ptr lfq_ctrie_snapshot_t,
    key: pointer,
    out_val: ptr pointer
): lfq_status_t {.exportc: "lfq_ctrie_snapshot_lookup", cdecl, gcsafe, raises: [].} =
  lf_ctrie_snapshot_lookup(snapshot, key, out_val)

proc lfq_ctrie_snapshot_get*(
    snapshot: ptr lfq_ctrie_snapshot_t,
    key: pointer,
    out_val: ptr pointer
): lfq_status_t {.exportc: "lfq_ctrie_snapshot_get", cdecl, gcsafe, raises: [].} =
  lf_ctrie_snapshot_get(snapshot, key, out_val)

proc lfq_ctrie_snapshot_contains*(snapshot: ptr lfq_ctrie_snapshot_t, key: pointer): bool {.exportc: "lfq_ctrie_snapshot_contains", cdecl, gcsafe, raises: [].} =
  lf_ctrie_snapshot_contains(snapshot, key)

proc lfq_ctrie_snapshot_len*(snapshot: ptr lfq_ctrie_snapshot_t): csize_t {.exportc: "lfq_ctrie_snapshot_len", cdecl, gcsafe, raises: [].} =
  lf_ctrie_snapshot_len(snapshot)

proc lfq_ctrie_snapshot_is_empty*(snapshot: ptr lfq_ctrie_snapshot_t): bool {.exportc: "lfq_ctrie_snapshot_is_empty", cdecl, gcsafe, raises: [].} =
  lf_ctrie_snapshot_is_empty(snapshot)

proc lfq_broadcast_create*(
    capacity: csize_t,
    overflow_mode: lfq_overflow_mode_t,
    max_readers: csize_t,
    out_broadcast: ptr ptr lfq_broadcast_t
): lfq_status_t {.exportc: "lfq_broadcast_create", cdecl, gcsafe, raises: [].} =
  lf_broadcast_create(capacity, overflow_mode, max_readers, out_broadcast)

proc lfq_broadcast_destroy*(
    broadcast: ptr lfq_broadcast_t
): lfq_status_t {.exportc: "lfq_broadcast_destroy", cdecl, gcsafe, raises: [].} =
  lf_broadcast_destroy(broadcast)

proc lfq_broadcast_publish*(
    broadcast: ptr lfq_broadcast_t,
    item: pointer
): lfq_status_t {.exportc: "lfq_broadcast_publish", cdecl, gcsafe, raises: [].} =
  lf_broadcast_publish(broadcast, item)

proc lfq_broadcast_subscribe*(
    broadcast: ptr lfq_broadcast_t,
    origin: lfq_sub_origin_t,
    out_cursor: ptr ptr lfq_broadcast_cursor_t
): lfq_status_t {.exportc: "lfq_broadcast_subscribe", cdecl, gcsafe, raises: [].} =
  lf_broadcast_subscribe(broadcast, origin, out_cursor)

proc lfq_broadcast_unsubscribe*(
    cursor: ptr lfq_broadcast_cursor_t
): lfq_status_t {.exportc: "lfq_broadcast_unsubscribe", cdecl, gcsafe, raises: [].} =
  lf_broadcast_unsubscribe(cursor)

proc lfq_broadcast_poll*(
    cursor: ptr lfq_broadcast_cursor_t,
    out_item: ptr pointer,
    out_skipped_count: ptr csize_t,
    out_result: ptr lfq_poll_result_t
): lfq_status_t {.exportc: "lfq_broadcast_poll", cdecl, gcsafe, raises: [].} =
  lf_broadcast_poll(cursor, out_item, out_skipped_count, out_result)

proc lfq_broadcast_try_read*(
    cursor: ptr lfq_broadcast_cursor_t,
    out_item: ptr pointer
): lfq_status_t {.exportc: "lfq_broadcast_try_read", cdecl, gcsafe, raises: [].} =
  lf_broadcast_try_read(cursor, out_item)

proc lfq_broadcast_len*(
    broadcast: ptr lfq_broadcast_t
): csize_t {.exportc: "lfq_broadcast_len", cdecl, gcsafe, raises: [].} =
  lf_broadcast_len(broadcast)

proc lfq_broadcast_capacity*(
    broadcast: ptr lfq_broadcast_t
): csize_t {.exportc: "lfq_broadcast_capacity", cdecl, gcsafe, raises: [].} =
  lf_broadcast_capacity(broadcast)

proc lfq_broadcast_subscriber_count*(
    broadcast: ptr lfq_broadcast_t
): csize_t {.exportc: "lfq_broadcast_subscriber_count", cdecl, gcsafe, raises: [].} =
  lf_broadcast_subscriber_count(broadcast)

proc lfq_broadcast_is_empty*(
    broadcast: ptr lfq_broadcast_t
): bool {.exportc: "lfq_broadcast_is_empty", cdecl, gcsafe, raises: [].} =
  lf_broadcast_is_empty(broadcast)

proc lfq_broadcast_cursor_lag*(
    cursor: ptr lfq_broadcast_cursor_t
): csize_t {.exportc: "lfq_broadcast_cursor_lag", cdecl, gcsafe, raises: [].} =
  lf_broadcast_cursor_lag(cursor)

proc lfq_topic_bus_create*(
    default_capacity: csize_t,
    default_overflow_mode: lfq_overflow_mode_t,
    default_max_readers: csize_t,
    out_bus: ptr ptr lfq_topic_bus_t
): lfq_status_t {.exportc: "lfq_topic_bus_create", cdecl, gcsafe, raises: [].} =
  lf_topic_bus_create(default_capacity, default_overflow_mode, default_max_readers, out_bus)

proc lfq_topic_bus_destroy*(
    bus: ptr lfq_topic_bus_t
): lfq_status_t {.exportc: "lfq_topic_bus_destroy", cdecl, gcsafe, raises: [].} =
  lf_topic_bus_destroy(bus)

proc lfq_topic_bus_publish*(
    bus: ptr lfq_topic_bus_t,
    topic: cstring,
    item: pointer
): lfq_status_t {.exportc: "lfq_topic_bus_publish", cdecl, gcsafe, raises: [].} =
  lf_topic_bus_publish(bus, topic, item)

proc lfq_topic_bus_subscribe*(
    bus: ptr lfq_topic_bus_t,
    topic: cstring,
    origin: lfq_sub_origin_t,
    out_cursor: ptr ptr lfq_broadcast_cursor_t
): lfq_status_t {.exportc: "lfq_topic_bus_subscribe", cdecl, gcsafe, raises: [].} =
  lf_topic_bus_subscribe(bus, topic, origin, out_cursor)

proc lfq_topic_bus_topic_count*(
    bus: ptr lfq_topic_bus_t
): csize_t {.exportc: "lfq_topic_bus_topic_count", cdecl, gcsafe, raises: [].} =
  lf_topic_bus_topic_count(bus)

proc lfq_topic_bus_has_topic*(
    bus: ptr lfq_topic_bus_t,
    topic: cstring
): bool {.exportc: "lfq_topic_bus_has_topic", cdecl, gcsafe, raises: [].} =
  lf_topic_bus_has_topic(bus, topic)

proc lfq_rendezvous_create*(
    out_chan: ptr ptr lfq_rendezvous_t
): lfq_status_t {.exportc: "lfq_rendezvous_create", cdecl, gcsafe, raises: [].} =
  lf_rendezvous_create(out_chan)

proc lfq_rendezvous_destroy*(
    chan: ptr lfq_rendezvous_t
): lfq_status_t {.exportc: "lfq_rendezvous_destroy", cdecl, gcsafe, raises: [].} =
  lf_rendezvous_destroy(chan)

proc lfq_rendezvous_close*(
    chan: ptr lfq_rendezvous_t
): lfq_status_t {.exportc: "lfq_rendezvous_close", cdecl, gcsafe, raises: [].} =
  lf_rendezvous_close(chan)

proc lfq_rendezvous_is_closed*(
    chan: ptr lfq_rendezvous_t
): bool {.exportc: "lfq_rendezvous_is_closed", cdecl, gcsafe, raises: [].} =
  lf_rendezvous_is_closed(chan)

proc lfq_rendezvous_send*(
    chan: ptr lfq_rendezvous_t,
    payload: pointer,
    out_corr_id: ptr uint64
): lfq_status_t {.exportc: "lfq_rendezvous_send", cdecl, gcsafe, raises: [].} =
  lf_rendezvous_send(chan, payload, out_corr_id)

proc lfq_rendezvous_recv*(
    chan: ptr lfq_rendezvous_t,
    out_payload: ptr pointer,
    out_corr_id: ptr uint64
): lfq_status_t {.exportc: "lfq_rendezvous_recv", cdecl, gcsafe, raises: [].} =
  lf_rendezvous_recv(chan, out_payload, out_corr_id)

proc lfq_rendezvous_try_send*(
    chan: ptr lfq_rendezvous_t,
    payload: pointer,
    out_corr_id: ptr uint64
): lfq_status_t {.exportc: "lfq_rendezvous_try_send", cdecl, gcsafe, raises: [].} =
  lf_rendezvous_try_send(chan, payload, out_corr_id)

proc lfq_rendezvous_try_recv*(
    chan: ptr lfq_rendezvous_t,
    out_payload: ptr pointer,
    out_corr_id: ptr uint64
): lfq_status_t {.exportc: "lfq_rendezvous_try_recv", cdecl, gcsafe, raises: [].} =
  lf_rendezvous_try_recv(chan, out_payload, out_corr_id)

proc lfq_rendezvous_send_timeout*(
    chan: ptr lfq_rendezvous_t,
    payload: pointer,
    timeout_ms: int32,
    out_corr_id: ptr uint64
): lfq_status_t {.exportc: "lfq_rendezvous_send_timeout", cdecl, gcsafe, raises: [].} =
  lf_rendezvous_send_timeout(chan, payload, timeout_ms, out_corr_id)

proc lfq_rendezvous_recv_timeout*(
    chan: ptr lfq_rendezvous_t,
    out_payload: ptr pointer,
    timeout_ms: int32,
    out_corr_id: ptr uint64
): lfq_status_t {.exportc: "lfq_rendezvous_recv_timeout", cdecl, gcsafe, raises: [].} =
  lf_rendezvous_recv_timeout(chan, out_payload, timeout_ms, out_corr_id)

proc lfq_token_bucket_create*(
    capacity: uint64,
    refill_rate: uint64
): ptr lfq_token_bucket_t {.exportc: "lfq_token_bucket_create", cdecl, gcsafe, raises: [].} =
  lf_token_bucket_create(capacity, refill_rate)

proc lfq_token_bucket_destroy*(
    bucket: ptr lfq_token_bucket_t
) {.exportc: "lfq_token_bucket_destroy", cdecl, gcsafe, raises: [].} =
  lf_token_bucket_destroy(bucket)

proc lfq_token_bucket_reset*(
    bucket: ptr lfq_token_bucket_t,
    tokens: uint64
) {.exportc: "lfq_token_bucket_reset", cdecl, gcsafe, raises: [].} =
  lf_token_bucket_reset(bucket, tokens)

proc lfq_leaky_bucket_create*(
    burst_tolerance_ns: uint64,
    leak_rate: uint64
): ptr lfq_leaky_bucket_t {.exportc: "lfq_leaky_bucket_create", cdecl, gcsafe, raises: [].} =
  lf_leaky_bucket_create(burst_tolerance_ns, leak_rate)

proc lfq_leaky_bucket_destroy*(
    bucket: ptr lfq_leaky_bucket_t
) {.exportc: "lfq_leaky_bucket_destroy", cdecl, gcsafe, raises: [].} =
  lf_leaky_bucket_destroy(bucket)

proc lfq_leaky_bucket_reset*(
    bucket: ptr lfq_leaky_bucket_t
) {.exportc: "lfq_leaky_bucket_reset", cdecl, gcsafe, raises: [].} =
  lf_leaky_bucket_reset(bucket)

proc lfq_stream_ring_create*(
    capacity: csize_t,
    use_virtual_mirror: bool
): ptr lfq_stream_ring_t {.exportc: "lfq_stream_ring_create", cdecl, gcsafe, raises: [].} =
  lf_stream_ring_create(capacity, use_virtual_mirror)

proc lfq_stream_ring_destroy*(
    ring: ptr lfq_stream_ring_t
) {.exportc: "lfq_stream_ring_destroy", cdecl, gcsafe, raises: [].} =
  lf_stream_ring_destroy(ring)

proc lfq_streambuffer_create*(
    capacity: csize_t,
    use_virtual_mirror: bool
): ptr lfq_streambuffer_t {.exportc: "lfq_streambuffer_create", cdecl, gcsafe, raises: [].} =
  lf_streambuffer_create(capacity, use_virtual_mirror)

proc lfq_streambuffer_destroy*(
    ring: ptr lfq_streambuffer_t
) {.exportc: "lfq_streambuffer_destroy", cdecl, gcsafe, raises: [].} =
  lf_streambuffer_destroy(ring)

proc lfq_stream_ring_capacity*(
    ring: ptr lfq_stream_ring_t
): csize_t {.exportc: "lfq_stream_ring_capacity", cdecl, gcsafe, raises: [].} =
  lf_stream_ring_capacity(ring)

proc lfq_stream_ring_available_read*(
    ring: ptr lfq_stream_ring_t
): csize_t {.exportc: "lfq_stream_ring_available_read", cdecl, gcsafe, raises: [].} =
  lf_stream_ring_available_read(ring)

proc lfq_stream_ring_available_write*(
    ring: ptr lfq_stream_ring_t
): csize_t {.exportc: "lfq_stream_ring_available_write", cdecl, gcsafe, raises: [].} =
  lf_stream_ring_available_write(ring)

proc lfq_stream_ring_is_empty*(
    ring: ptr lfq_stream_ring_t
): bool {.exportc: "lfq_stream_ring_is_empty", cdecl, gcsafe, raises: [].} =
  lf_stream_ring_is_empty(ring)

proc lfq_stream_ring_is_full*(
    ring: ptr lfq_stream_ring_t
): bool {.exportc: "lfq_stream_ring_is_full", cdecl, gcsafe, raises: [].} =
  lf_stream_ring_is_full(ring)

proc lfq_streambuffer_capacity*(
    ring: ptr lfq_streambuffer_t
): csize_t {.exportc: "lfq_streambuffer_capacity", cdecl, gcsafe, raises: [].} =
  lf_streambuffer_capacity(ring)

proc lfq_streambuffer_available_read*(
    ring: ptr lfq_streambuffer_t
): csize_t {.exportc: "lfq_streambuffer_available_read", cdecl, gcsafe, raises: [].} =
  lf_streambuffer_available_read(ring)

proc lfq_streambuffer_available_write*(
    ring: ptr lfq_streambuffer_t
): csize_t {.exportc: "lfq_streambuffer_available_write", cdecl, gcsafe, raises: [].} =
  lf_streambuffer_available_write(ring)

proc lfq_streambuffer_is_empty*(
    ring: ptr lfq_streambuffer_t
): bool {.exportc: "lfq_streambuffer_is_empty", cdecl, gcsafe, raises: [].} =
  lf_streambuffer_is_empty(ring)

proc lfq_streambuffer_is_full*(
    ring: ptr lfq_streambuffer_t
): bool {.exportc: "lfq_streambuffer_is_full", cdecl, gcsafe, raises: [].} =
  lf_streambuffer_is_full(ring)

proc lfq_stream_ring_try_write*(
    ring: ptr lfq_stream_ring_t,
    src: pointer,
    len: csize_t
): csize_t {.exportc: "lfq_stream_ring_try_write", cdecl, gcsafe, raises: [].} =
  lf_stream_ring_try_write(ring, src, len)

proc lfq_stream_ring_try_read*(
    ring: ptr lfq_stream_ring_t,
    dst: pointer,
    max_len: csize_t
): csize_t {.exportc: "lfq_stream_ring_try_read", cdecl, gcsafe, raises: [].} =
  lf_stream_ring_try_read(ring, dst, max_len)

proc lfq_stream_ring_write_blocking*(
    ring: ptr lfq_stream_ring_t,
    src: pointer,
    len: csize_t,
    timeout_ns: int64
): csize_t {.exportc: "lfq_stream_ring_write_blocking", cdecl, gcsafe, raises: [].} =
  lf_stream_ring_write_blocking(ring, src, len, timeout_ns)

proc lfq_stream_ring_read_blocking*(
    ring: ptr lfq_stream_ring_t,
    dst: pointer,
    max_len: csize_t,
    timeout_ns: int64
): csize_t {.exportc: "lfq_stream_ring_read_blocking", cdecl, gcsafe, raises: [].} =
  lf_stream_ring_read_blocking(ring, dst, max_len, timeout_ns)

proc lfq_streambuffer_try_write*(
    ring: ptr lfq_streambuffer_t,
    src: pointer,
    len: csize_t
): csize_t {.exportc: "lfq_streambuffer_try_write", cdecl, gcsafe, raises: [].} =
  lf_streambuffer_try_write(ring, src, len)

proc lfq_streambuffer_try_read*(
    ring: ptr lfq_streambuffer_t,
    dst: pointer,
    max_len: csize_t
): csize_t {.exportc: "lfq_streambuffer_try_read", cdecl, gcsafe, raises: [].} =
  lf_streambuffer_try_read(ring, dst, max_len)

proc lfq_streambuffer_write_blocking*(
    ring: ptr lfq_streambuffer_t,
    src: pointer,
    len: csize_t,
    timeout_ns: int64
): csize_t {.exportc: "lfq_streambuffer_write_blocking", cdecl, gcsafe, raises: [].} =
  lf_streambuffer_write_blocking(ring, src, len, timeout_ns)

proc lfq_streambuffer_read_blocking*(
    ring: ptr lfq_streambuffer_t,
    dst: pointer,
    max_len: csize_t,
    timeout_ns: int64
): csize_t {.exportc: "lfq_streambuffer_read_blocking", cdecl, gcsafe, raises: [].} =
  lf_streambuffer_read_blocking(ring, dst, max_len, timeout_ns)

proc lfq_stream_ring_acquire_write_iov*(
    ring: ptr lfq_stream_ring_t,
    requested_len: csize_t
): lfq_iovec_pair_t {.exportc: "lfq_stream_ring_acquire_write_iov", cdecl, gcsafe, raises: [].} =
  lf_stream_ring_acquire_write_iov(ring, requested_len)

proc lfq_stream_ring_commit_write*(
    ring: ptr lfq_stream_ring_t,
    bytes_written: csize_t
) {.exportc: "lfq_stream_ring_commit_write", cdecl, gcsafe, raises: [].} =
  lf_stream_ring_commit_write(ring, bytes_written)

proc lfq_stream_ring_acquire_read_iov*(
    ring: ptr lfq_stream_ring_t,
    requested_len: csize_t
): lfq_iovec_pair_t {.exportc: "lfq_stream_ring_acquire_read_iov", cdecl, gcsafe, raises: [].} =
  lf_stream_ring_acquire_read_iov(ring, requested_len)

proc lfq_stream_ring_commit_read*(
    ring: ptr lfq_stream_ring_t,
    bytes_read: csize_t
) {.exportc: "lfq_stream_ring_commit_read", cdecl, gcsafe, raises: [].} =
  lf_stream_ring_commit_read(ring, bytes_read)

proc lfq_streambuffer_acquire_write_iov*(
    ring: ptr lfq_streambuffer_t,
    requested_len: csize_t
): lfq_iovec_pair_t {.exportc: "lfq_streambuffer_acquire_write_iov", cdecl, gcsafe, raises: [].} =
  lf_streambuffer_acquire_write_iov(ring, requested_len)

proc lfq_streambuffer_commit_write*(
    ring: ptr lfq_streambuffer_t,
    bytes_written: csize_t
) {.exportc: "lfq_streambuffer_commit_write", cdecl, gcsafe, raises: [].} =
  lf_streambuffer_commit_write(ring, bytes_written)

proc lfq_streambuffer_acquire_read_iov*(
    ring: ptr lfq_streambuffer_t,
    requested_len: csize_t
): lfq_iovec_pair_t {.exportc: "lfq_streambuffer_acquire_read_iov", cdecl, gcsafe, raises: [].} =
  lf_streambuffer_acquire_read_iov(ring, requested_len)

proc lfq_streambuffer_commit_read*(
    ring: ptr lfq_streambuffer_t,
    bytes_read: csize_t
) {.exportc: "lfq_streambuffer_commit_read", cdecl, gcsafe, raises: [].} =
  lf_streambuffer_commit_read(ring, bytes_read)

proc lfq_mpmc_stream_ring_create*(
    capacity: csize_t
): ptr lfq_mpmc_stream_ring_t {.exportc: "lfq_mpmc_stream_ring_create", cdecl, gcsafe, raises: [].} =
  lf_mpmc_stream_ring_create(capacity)

proc lfq_mpmc_stream_ring_destroy*(
    ring: ptr lfq_mpmc_stream_ring_t
) {.exportc: "lfq_mpmc_stream_ring_destroy", cdecl, gcsafe, raises: [].} =
  lf_mpmc_stream_ring_destroy(ring)

proc lfq_mpmc_stream_ring_capacity*(
    ring: ptr lfq_mpmc_stream_ring_t
): csize_t {.exportc: "lfq_mpmc_stream_ring_capacity", cdecl, gcsafe, raises: [].} =
  lf_mpmc_stream_ring_capacity(ring)

proc lfq_mpmc_stream_ring_available_read*(
    ring: ptr lfq_mpmc_stream_ring_t
): csize_t {.exportc: "lfq_mpmc_stream_ring_available_read", cdecl, gcsafe, raises: [].} =
  lf_mpmc_stream_ring_available_read(ring)

proc lfq_mpmc_stream_ring_available_write*(
    ring: ptr lfq_mpmc_stream_ring_t
): csize_t {.exportc: "lfq_mpmc_stream_ring_available_write", cdecl, gcsafe, raises: [].} =
  lf_mpmc_stream_ring_available_write(ring)

proc lfq_mpmc_stream_ring_is_empty*(
    ring: ptr lfq_mpmc_stream_ring_t
): bool {.exportc: "lfq_mpmc_stream_ring_is_empty", cdecl, gcsafe, raises: [].} =
  lf_mpmc_stream_ring_is_empty(ring)

proc lfq_mpmc_stream_ring_is_full*(
    ring: ptr lfq_mpmc_stream_ring_t
): bool {.exportc: "lfq_mpmc_stream_ring_is_full", cdecl, gcsafe, raises: [].} =
  lf_mpmc_stream_ring_is_full(ring)

proc lfq_mpmc_stream_ring_try_write*(
    ring: ptr lfq_mpmc_stream_ring_t,
    src: pointer,
    len: csize_t
): csize_t {.exportc: "lfq_mpmc_stream_ring_try_write", cdecl, gcsafe, raises: [].} =
  lf_mpmc_stream_ring_try_write(ring, src, len)

proc lfq_mpmc_stream_ring_try_read*(
    ring: ptr lfq_mpmc_stream_ring_t,
    dst: pointer,
    max_len: csize_t
): csize_t {.exportc: "lfq_mpmc_stream_ring_try_read", cdecl, gcsafe, raises: [].} =
  lf_mpmc_stream_ring_try_read(ring, dst, max_len)

proc lfq_ctrie_compute_if_absent*(
    trie: ptr lfq_ctrie_t,
    key: pointer,
    key_len: csize_t,
    mapping_fn: lfq_mapping_fn,
    user_data: pointer,
    out_val: ptr pointer,
    out_val_len: ptr csize_t
): bool {.exportc: "lfq_ctrie_compute_if_absent", cdecl, gcsafe, raises: [].} =
  lf_ctrie_compute_if_absent(trie, key, key_len, mapping_fn, user_data, out_val, out_val_len)

proc lfq_ctrie_atomic_update*(
    trie: ptr lfq_ctrie_t,
    key: pointer,
    key_len: csize_t,
    update_fn: lfq_update_fn,
    user_data: pointer,
    out_val: ptr pointer,
    out_val_len: ptr csize_t
): bool {.exportc: "lfq_ctrie_atomic_update", cdecl, gcsafe, raises: [].} =
  lf_ctrie_atomic_update(trie, key, key_len, update_fn, user_data, out_val, out_val_len)

proc lfq_skiplist_compute_if_absent*(
    map: ptr lfq_table_t,
    key: pointer,
    key_len: csize_t,
    mapping_fn: lfq_mapping_fn,
    user_data: pointer,
    out_val: ptr pointer,
    out_val_len: ptr csize_t
): bool {.exportc: "lfq_skiplist_compute_if_absent", cdecl, gcsafe, raises: [].} =
  lf_skiplist_compute_if_absent(map, key, key_len, mapping_fn, user_data, out_val, out_val_len)

proc lfq_skiplist_atomic_update*(
    map: ptr lfq_table_t,
    key: pointer,
    key_len: csize_t,
    update_fn: lfq_update_fn,
    user_data: pointer,
    out_val: ptr pointer,
    out_val_len: ptr csize_t
): bool {.exportc: "lfq_skiplist_atomic_update", cdecl, gcsafe, raises: [].} =
  lf_skiplist_atomic_update(map, key, key_len, update_fn, user_data, out_val, out_val_len)

proc lfq_table_compute_if_absent*(
    map: ptr lfq_table_t,
    key: pointer,
    key_len: csize_t,
    mapping_fn: lfq_mapping_fn,
    user_data: pointer,
    out_val: ptr pointer,
    out_val_len: ptr csize_t
): bool {.exportc: "lfq_table_compute_if_absent", cdecl, gcsafe, raises: [].} =
  lf_table_compute_if_absent(map, key, key_len, mapping_fn, user_data, out_val, out_val_len)

proc lfq_table_atomic_update*(
    map: ptr lfq_table_t,
    key: pointer,
    key_len: csize_t,
    update_fn: lfq_update_fn,
    user_data: pointer,
    out_val: ptr pointer,
    out_val_len: ptr csize_t
): bool {.exportc: "lfq_table_atomic_update", cdecl, gcsafe, raises: [].} =
  lf_table_atomic_update(map, key, key_len, update_fn, user_data, out_val, out_val_len)

proc lfq_arc_guard_create*(
    item: pointer,
    destructor: lfq_arc_destructor_fn,
    userData: pointer,
    outGuard: ptr ptr lfq_arc_guard_t
): lfq_status_t {.exportc: "lfq_arc_guard_create", cdecl, gcsafe, raises: [].} =
  lf_arc_guard_create(item, destructor, userData, outGuard)

proc lfq_arc_guard_get*(
    guard: ptr lfq_arc_guard_t
): pointer {.exportc: "lfq_arc_guard_get", cdecl, gcsafe, raises: [].} =
  lf_arc_guard_get(guard)

proc lfq_arc_guard_clone*(
    guard: ptr lfq_arc_guard_t,
    outClone: ptr ptr lfq_arc_guard_t
): lfq_status_t {.exportc: "lfq_arc_guard_clone", cdecl, gcsafe, raises: [].} =
  lf_arc_guard_clone(guard, outClone)

proc lfq_arc_guard_release*(
    guard: ptr lfq_arc_guard_t
): lfq_status_t {.exportc: "lfq_arc_guard_release", cdecl, gcsafe, raises: [].} =
  lf_arc_guard_release(guard)

proc lfq_atomic_arc_create*(
    initialItem: pointer,
    destructor: lfq_arc_destructor_fn,
    userData: pointer,
    outArc: ptr ptr lfq_atomic_arc_t
): lfq_status_t {.exportc: "lfq_atomic_arc_create", cdecl, gcsafe, raises: [].} =
  lf_atomic_arc_create(initialItem, destructor, userData, outArc)

proc lfq_atomic_arc_destroy*(
    arc: ptr lfq_atomic_arc_t
): lfq_status_t {.exportc: "lfq_atomic_arc_destroy", cdecl, gcsafe, raises: [].} =
  lf_atomic_arc_destroy(arc)

proc lfq_atomic_arc_is_null*(
    arc: ptr lfq_atomic_arc_t
): bool {.exportc: "lfq_atomic_arc_is_null", cdecl, gcsafe, raises: [].} =
  lf_atomic_arc_is_null(arc)

proc lfq_atomic_arc_load*(
    arc: ptr lfq_atomic_arc_t,
    outGuard: ptr ptr lfq_arc_guard_t
): lfq_status_t {.exportc: "lfq_atomic_arc_load", cdecl, gcsafe, raises: [].} =
  lf_atomic_arc_load(arc, outGuard)

proc lfq_atomic_arc_store*(
    arc: ptr lfq_atomic_arc_t,
    newItem: pointer,
    destructor: lfq_arc_destructor_fn,
    userData: pointer
): lfq_status_t {.exportc: "lfq_atomic_arc_store", cdecl, gcsafe, raises: [].} =
  lf_atomic_arc_store(arc, newItem, destructor, userData)

proc lfq_atomic_arc_store_guard*(
    arc: ptr lfq_atomic_arc_t,
    guard: ptr lfq_arc_guard_t
): lfq_status_t {.exportc: "lfq_atomic_arc_store_guard", cdecl, gcsafe, raises: [].} =
  lf_atomic_arc_store_guard(arc, guard)

proc lfq_atomic_arc_swap*(
    arc: ptr lfq_atomic_arc_t,
    newItem: pointer,
    destructor: lfq_arc_destructor_fn,
    userData: pointer,
    outOldGuard: ptr ptr lfq_arc_guard_t
): lfq_status_t {.exportc: "lfq_atomic_arc_swap", cdecl, gcsafe, raises: [].} =
  lf_atomic_arc_swap(arc, newItem, destructor, userData, outOldGuard)

proc lfq_atomic_arc_swap_guard*(
    arc: ptr lfq_atomic_arc_t,
    guard: ptr lfq_arc_guard_t,
    outOldGuard: ptr ptr lfq_arc_guard_t
): lfq_status_t {.exportc: "lfq_atomic_arc_swap_guard", cdecl, gcsafe, raises: [].} =
  lf_atomic_arc_swap_guard(arc, guard, outOldGuard)

proc lfq_atomic_arc_compare_exchange_guard*(
    arc: ptr lfq_atomic_arc_t,
    inoutExpected: ptr ptr lfq_arc_guard_t,
    desired: ptr lfq_arc_guard_t,
    outSwapped: ptr bool
): lfq_status_t {.exportc: "lfq_atomic_arc_compare_exchange_guard", cdecl, gcsafe, raises: [].} =
  lf_atomic_arc_compare_exchange_guard(arc, inoutExpected, desired, outSwapped)

proc lfq_atomic_arc_compare_exchange*(
    arc: ptr lfq_atomic_arc_t,
    inoutExpected: ptr ptr lfq_arc_guard_t,
    desiredItem: pointer,
    destructor: lfq_arc_destructor_fn,
    userData: pointer,
    outSwapped: ptr bool
): lfq_status_t {.exportc: "lfq_atomic_arc_compare_exchange", cdecl, gcsafe, raises: [].} =
  lf_atomic_arc_compare_exchange(arc, inoutExpected, desiredItem, destructor, userData, outSwapped)

proc lfq_pqueue_create*(
    destructor: lfq_pqueue_destructor_fn,
    user_data: pointer,
    out_pqueue: ptr ptr lfq_pqueue_t
): lfq_status_t {.exportc: "lfq_pqueue_create", cdecl, gcsafe, raises: [].} =
  lf_pqueue_create(destructor, user_data, out_pqueue)

proc lfq_pqueue_clear*(
    pqueue: ptr lfq_pqueue_t
): lfq_status_t {.exportc: "lfq_pqueue_clear", cdecl, gcsafe, raises: [].} =
  lf_pqueue_clear(pqueue)

proc lfq_pqueue_destroy*(
    pqueue: ptr lfq_pqueue_t
): lfq_status_t {.exportc: "lfq_pqueue_destroy", cdecl, gcsafe, raises: [].} =
  lf_pqueue_destroy(pqueue)

proc lfq_pqueue_push*(
    pqueue: ptr lfq_pqueue_t,
    priority: int64,
    item: pointer
): lfq_status_t {.exportc: "lfq_pqueue_push", cdecl, gcsafe, raises: [].} =
  lf_pqueue_push(pqueue, priority, item)

proc lfq_pqueue_pop_min*(
    pqueue: ptr lfq_pqueue_t,
    out_priority: ptr int64,
    out_item: ptr pointer
): lfq_status_t {.exportc: "lfq_pqueue_pop_min", cdecl, gcsafe, raises: [].} =
  lf_pqueue_pop_min(pqueue, out_priority, out_item)

proc lfq_pqueue_peek_min*(
    pqueue: ptr lfq_pqueue_t,
    out_priority: ptr int64,
    out_item: ptr pointer
): lfq_status_t {.exportc: "lfq_pqueue_peek_min", cdecl, gcsafe, raises: [].} =
  lf_pqueue_peek_min(pqueue, out_priority, out_item)

proc lfq_pqueue_len*(
    pqueue: ptr lfq_pqueue_t
): csize_t {.exportc: "lfq_pqueue_len", cdecl, gcsafe, raises: [].} =
  lf_pqueue_len(pqueue)

proc lfq_pqueue_is_empty*(
    pqueue: ptr lfq_pqueue_t
): bool {.exportc: "lfq_pqueue_is_empty", cdecl, gcsafe, raises: [].} =
  lf_pqueue_is_empty(pqueue)

proc lfq_flat_combiner_create*(
    state: pointer,
    default_op_fn: lfq_flat_combiner_op_fn,
    state_destructor: lfq_flat_combiner_state_destructor_fn,
    user_data: pointer,
    max_combining_rounds: csize_t,
    cleanup_interval: csize_t,
    out_combiner: ptr ptr lfq_flat_combiner_t
): lfq_status_t {.exportc: "lfq_flat_combiner_create", cdecl, gcsafe, raises: [].} =
  lf_flat_combiner_create(state, default_op_fn, state_destructor, user_data, max_combining_rounds, cleanup_interval, out_combiner)

proc lfq_flat_combiner_destroy*(
    combiner: ptr lfq_flat_combiner_t
): lfq_status_t {.exportc: "lfq_flat_combiner_destroy", cdecl, gcsafe, raises: [].} =
  lf_flat_combiner_destroy(combiner)

proc lfq_flat_combiner_combine*(
    combiner: ptr lfq_flat_combiner_t,
    op_arg: pointer,
    out_result: ptr pointer
): lfq_status_t {.exportc: "lfq_flat_combiner_combine", cdecl, gcsafe, raises: [].} =
  lf_flat_combiner_combine(combiner, op_arg, out_result)

proc lfq_flat_combiner_combine_fn*(
    combiner: ptr lfq_flat_combiner_t,
    op_fn: lfq_flat_combiner_op_fn,
    op_arg: pointer,
    op_user_data: pointer,
    out_result: ptr pointer
): lfq_status_t {.exportc: "lfq_flat_combiner_combine_fn", cdecl, gcsafe, raises: [].} =
  lf_flat_combiner_combine_fn(combiner, op_fn, op_arg, op_user_data, out_result)

proc lfq_flat_combiner_pass_count*(
    combiner: ptr lfq_flat_combiner_t
): uint64 {.exportc: "lfq_flat_combiner_pass_count", cdecl, gcsafe, raises: [].} =
  lf_flat_combiner_pass_count(combiner)

proc lfq_flat_combiner_total_combined_ops*(
    combiner: ptr lfq_flat_combiner_t
): uint64 {.exportc: "lfq_flat_combiner_total_combined_ops", cdecl, gcsafe, raises: [].} =
  lf_flat_combiner_total_combined_ops(combiner)

proc lfq_flat_combiner_active_records*(
    combiner: ptr lfq_flat_combiner_t
): csize_t {.exportc: "lfq_flat_combiner_active_records", cdecl, gcsafe, raises: [].} =
  lf_flat_combiner_active_records(combiner)

proc lfq_bstack_create*(
    capacity: csize_t,
    destructor: lfq_item_destructor_fn,
    user_data: pointer,
    out_stack: ptr ptr lfq_bstack_t
): lfq_status_t {.exportc: "lfq_bstack_create", cdecl, gcsafe, raises: [].} =
  lf_bstack_create(capacity, destructor, user_data, out_stack)

proc lfq_bstack_destroy*(
    stack: ptr lfq_bstack_t
): lfq_status_t {.exportc: "lfq_bstack_destroy", cdecl, gcsafe, raises: [].} =
  lf_bstack_destroy(stack)

proc lfq_bstack_push*(
    stack: ptr lfq_bstack_t,
    item: pointer
): lfq_status_t {.exportc: "lfq_bstack_push", cdecl, gcsafe, raises: [].} =
  lf_bstack_push(stack, item)

proc lfq_bstack_pop*(
    stack: ptr lfq_bstack_t,
    out_item: ptr pointer
): lfq_status_t {.exportc: "lfq_bstack_pop", cdecl, gcsafe, raises: [].} =
  lf_bstack_pop(stack, out_item)

proc lfq_bstack_peek*(
    stack: ptr lfq_bstack_t,
    out_item: ptr pointer
): lfq_status_t {.exportc: "lfq_bstack_peek", cdecl, gcsafe, raises: [].} =
  lf_bstack_peek(stack, out_item)

proc lfq_bstack_drain*(
    stack: ptr lfq_bstack_t,
    out_items: ptr pointer,
    max_count: csize_t
): csize_t {.exportc: "lfq_bstack_drain", cdecl, gcsafe, raises: [].} =
  lf_bstack_drain(stack, out_items, max_count)

proc lfq_bstack_clear*(
    stack: ptr lfq_bstack_t
): lfq_status_t {.exportc: "lfq_bstack_clear", cdecl, gcsafe, raises: [].} =
  lf_bstack_clear(stack)

proc lfq_bstack_len*(
    stack: ptr lfq_bstack_t
): csize_t {.exportc: "lfq_bstack_len", cdecl, gcsafe, raises: [].} =
  lf_bstack_len(stack)

proc lfq_bstack_capacity*(
    stack: ptr lfq_bstack_t
): csize_t {.exportc: "lfq_bstack_capacity", cdecl, gcsafe, raises: [].} =
  lf_bstack_capacity(stack)

proc lfq_bstack_is_empty*(
    stack: ptr lfq_bstack_t
): bool {.exportc: "lfq_bstack_is_empty", cdecl, gcsafe, raises: [].} =
  lf_bstack_is_empty(stack)

proc lfq_bstack_is_full*(
    stack: ptr lfq_bstack_t
): bool {.exportc: "lfq_bstack_is_full", cdecl, gcsafe, raises: [].} =
  lf_bstack_is_full(stack)

proc lfq_bpqueue_create*(
    capacity: csize_t,
    destructor: lfq_item_destructor_fn,
    user_data: pointer,
    out_pqueue: ptr ptr lfq_bpqueue_t
): lfq_status_t {.exportc: "lfq_bpqueue_create", cdecl, gcsafe, raises: [].} =
  lf_bpqueue_create(capacity, destructor, user_data, out_pqueue)

proc lfq_bpqueue_destroy*(
    pqueue: ptr lfq_bpqueue_t
): lfq_status_t {.exportc: "lfq_bpqueue_destroy", cdecl, gcsafe, raises: [].} =
  lf_bpqueue_destroy(pqueue)

proc lfq_bpqueue_push*(
    pqueue: ptr lfq_bpqueue_t,
    priority: int64,
    item: pointer
): lfq_status_t {.exportc: "lfq_bpqueue_push", cdecl, gcsafe, raises: [].} =
  lf_bpqueue_push(pqueue, priority, item)

proc lfq_bpqueue_pop_min*(
    pqueue: ptr lfq_bpqueue_t,
    out_priority: ptr int64,
    out_item: ptr pointer
): lfq_status_t {.exportc: "lfq_bpqueue_pop_min", cdecl, gcsafe, raises: [].} =
  lf_bpqueue_pop_min(pqueue, out_priority, out_item)

proc lfq_bpqueue_peek_min*(
    pqueue: ptr lfq_bpqueue_t,
    out_priority: ptr int64,
    out_item: ptr pointer
): lfq_status_t {.exportc: "lfq_bpqueue_peek_min", cdecl, gcsafe, raises: [].} =
  lf_bpqueue_peek_min(pqueue, out_priority, out_item)

proc lfq_bpqueue_clear*(
    pqueue: ptr lfq_bpqueue_t
): lfq_status_t {.exportc: "lfq_bpqueue_clear", cdecl, gcsafe, raises: [].} =
  lf_bpqueue_clear(pqueue)

proc lfq_bpqueue_len*(
    pqueue: ptr lfq_bpqueue_t
): csize_t {.exportc: "lfq_bpqueue_len", cdecl, gcsafe, raises: [].} =
  lf_bpqueue_len(pqueue)

proc lfq_bpqueue_capacity*(
    pqueue: ptr lfq_bpqueue_t
): csize_t {.exportc: "lfq_bpqueue_capacity", cdecl, gcsafe, raises: [].} =
  lf_bpqueue_capacity(pqueue)

proc lfq_bpqueue_is_empty*(
    pqueue: ptr lfq_bpqueue_t
): bool {.exportc: "lfq_bpqueue_is_empty", cdecl, gcsafe, raises: [].} =
  lf_bpqueue_is_empty(pqueue)

proc lfq_bpqueue_is_full*(
    pqueue: ptr lfq_bpqueue_t
): bool {.exportc: "lfq_bpqueue_is_full", cdecl, gcsafe, raises: [].} =
  lf_bpqueue_is_full(pqueue)

proc lfq_btable_create*(
    capacity: csize_t,
    destructor: lfq_btable_destructor_fn,
    user_data: pointer,
    out_table: ptr ptr lfq_btable_t
): lfq_status_t {.exportc: "lfq_btable_create", cdecl, gcsafe, raises: [].} =
  lf_btable_create(capacity, destructor, user_data, out_table)

proc lfq_btable_destroy*(
    table: ptr lfq_btable_t
): lfq_status_t {.exportc: "lfq_btable_destroy", cdecl, gcsafe, raises: [].} =
  lf_btable_destroy(table)

proc lfq_btable_put*(
    table: ptr lfq_btable_t,
    key: pointer,
    val: pointer,
    out_inserted: ptr bool
): lfq_status_t {.exportc: "lfq_btable_put", cdecl, gcsafe, raises: [].} =
  lf_btable_put(table, key, val, out_inserted)

proc lfq_btable_insert*(
    table: ptr lfq_btable_t,
    key: pointer,
    val: pointer,
    out_inserted: ptr bool
): lfq_status_t {.exportc: "lfq_btable_insert", cdecl, gcsafe, raises: [].} =
  lf_btable_insert(table, key, val, out_inserted)

proc lfq_btable_get*(
    table: ptr lfq_btable_t,
    key: pointer,
    out_val: ptr pointer
): lfq_status_t {.exportc: "lfq_btable_get", cdecl, gcsafe, raises: [].} =
  lf_btable_get(table, key, out_val)

proc lfq_btable_delete*(
    table: ptr lfq_btable_t,
    key: pointer,
    out_deleted: ptr bool
): lfq_status_t {.exportc: "lfq_btable_delete", cdecl, gcsafe, raises: [].} =
  lf_btable_delete(table, key, out_deleted)

proc lfq_btable_remove*(
    table: ptr lfq_btable_t,
    key: pointer,
    out_removed: ptr bool
): lfq_status_t {.exportc: "lfq_btable_remove", cdecl, gcsafe, raises: [].} =
  lf_btable_remove(table, key, out_removed)

proc lfq_btable_take*(
    table: ptr lfq_btable_t,
    key: pointer,
    out_val: ptr pointer
): lfq_status_t {.exportc: "lfq_btable_take", cdecl, gcsafe, raises: [].} =
  lf_btable_take(table, key, out_val)

proc lfq_btable_contains*(
    table: ptr lfq_btable_t,
    key: pointer
): bool {.exportc: "lfq_btable_contains", cdecl, gcsafe, raises: [].} =
  lf_btable_contains(table, key)

proc lfq_btable_compute_if_absent*(
    table: ptr lfq_btable_t,
    key: pointer,
    mapping_fn: lfq_btable_mapping_fn,
    user_data: pointer,
    out_val: ptr pointer
): lfq_status_t {.exportc: "lfq_btable_compute_if_absent", cdecl, gcsafe, raises: [].} =
  lf_btable_compute_if_absent(table, key, mapping_fn, user_data, out_val)

proc lfq_btable_atomic_update*(
    table: ptr lfq_btable_t,
    key: pointer,
    update_fn: lfq_btable_update_fn,
    user_data: pointer,
    out_val: ptr pointer
): lfq_status_t {.exportc: "lfq_btable_atomic_update", cdecl, gcsafe, raises: [].} =
  lf_btable_atomic_update(table, key, update_fn, user_data, out_val)

proc lfq_btable_upsert*(
    table: ptr lfq_btable_t,
    key: pointer,
    initial_val: pointer,
    update_fn: lfq_btable_update_fn,
    user_data: pointer,
    out_val: ptr pointer
): lfq_status_t {.exportc: "lfq_btable_upsert", cdecl, gcsafe, raises: [].} =
  lf_btable_upsert(table, key, initial_val, update_fn, user_data, out_val)

proc lfq_btable_clear*(
    table: ptr lfq_btable_t
): lfq_status_t {.exportc: "lfq_btable_clear", cdecl, gcsafe, raises: [].} =
  lf_btable_clear(table)

proc lfq_btable_len*(
    table: ptr lfq_btable_t
): csize_t {.exportc: "lfq_btable_len", cdecl, gcsafe, raises: [].} =
  lf_btable_len(table)

proc lfq_btable_capacity*(
    table: ptr lfq_btable_t
): csize_t {.exportc: "lfq_btable_capacity", cdecl, gcsafe, raises: [].} =
  lf_btable_capacity(table)

proc lfq_btable_is_empty*(
    table: ptr lfq_btable_t
): bool {.exportc: "lfq_btable_is_empty", cdecl, gcsafe, raises: [].} =
  lf_btable_is_empty(table)

proc lfq_btable_is_full*(
    table: ptr lfq_btable_t
): bool {.exportc: "lfq_btable_is_full", cdecl, gcsafe, raises: [].} =
  lf_btable_is_full(table)

proc lfq_bqueue128_create*(
    capacity: csize_t,
    destructor: lfq_bqueue128_destructor_fn,
    user_data: pointer,
    out_queue: ptr ptr lfq_bqueue128_t
): lfq_status_t {.exportc: "lfq_bqueue128_create", cdecl, gcsafe, raises: [].} =
  lf_bqueue128_create(capacity, destructor, user_data, out_queue)

proc lfq_bqueue128_destroy*(
    queue: ptr lfq_bqueue128_t
): lfq_status_t {.exportc: "lfq_bqueue128_destroy", cdecl, gcsafe, raises: [].} =
  lf_bqueue128_destroy(queue)

proc lfq_bqueue128_push*(
    queue: ptr lfq_bqueue128_t,
    item: pointer
): lfq_status_t {.exportc: "lfq_bqueue128_push", cdecl, gcsafe, raises: [].} =
  lf_bqueue128_push(queue, item)

proc lfq_bqueue128_pop*(
    queue: ptr lfq_bqueue128_t,
    out_item: ptr pointer
): lfq_status_t {.exportc: "lfq_bqueue128_pop", cdecl, gcsafe, raises: [].} =
  lf_bqueue128_pop(queue, out_item)

proc lfq_bqueue128_peek*(
    queue: ptr lfq_bqueue128_t,
    out_item: ptr pointer
): lfq_status_t {.exportc: "lfq_bqueue128_peek", cdecl, gcsafe, raises: [].} =
  lf_bqueue128_peek(queue, out_item)

proc lfq_bqueue128_clear*(
    queue: ptr lfq_bqueue128_t
): lfq_status_t {.exportc: "lfq_bqueue128_clear", cdecl, gcsafe, raises: [].} =
  lf_bqueue128_clear(queue)

proc lfq_bqueue128_len*(
    queue: ptr lfq_bqueue128_t
): csize_t {.exportc: "lfq_bqueue128_len", cdecl, gcsafe, raises: [].} =
  lf_bqueue128_len(queue)

proc lfq_bqueue128_capacity*(
    queue: ptr lfq_bqueue128_t
): csize_t {.exportc: "lfq_bqueue128_capacity", cdecl, gcsafe, raises: [].} =
  lf_bqueue128_capacity(queue)

proc lfq_bqueue128_is_empty*(
    queue: ptr lfq_bqueue128_t
): bool {.exportc: "lfq_bqueue128_is_empty", cdecl, gcsafe, raises: [].} =
  lf_bqueue128_is_empty(queue)

proc lfq_bqueue128_is_full*(
    queue: ptr lfq_bqueue128_t
): bool {.exportc: "lfq_bqueue128_is_full", cdecl, gcsafe, raises: [].} =
  lf_bqueue128_is_full(queue)


