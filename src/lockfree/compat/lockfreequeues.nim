## Backwards-compatibility shim for `lockfreequeues` v4.2.0.
##
## This module provides a zero-breakage drop-in replacement for legacy code
## written against `lockfreequeues`. It maps legacy types and constructors
## onto the unified `BQueue` and `Queue` engines while preserving historical
## generic parameter ordering, constructor arities, and implicit thread
## registration semantics.

import options
import lockfree/atomics
import lockfree/atomics/dsl
import lockfree/strategy
import lockfree/exceptions
import lockfree/bqueue
import lockfree/queue
import lockfree/endpoint except getProducer, getConsumer
import lockfree/endpoint_types
import lockfree/internal/pinscope_stub
import lockfree/smr/nebr as nebr

export atomics, dsl
export strategy
export exceptions
export bqueue
export queue
export endpoint_types
export endpoint.bindToThread, endpoint.close, endpoint.getProducerHere, endpoint.getConsumerHere, endpoint.bindConsumer
export pinscope_stub

const NoSlice* = none(HSlice[int, int])

# ---------------------------------------------------------------------------
# SMR legacy aliases
# ---------------------------------------------------------------------------

type
  DebraManager*[MaxThreads: static int, CC: static nebr.PinScopeCardinality] = nebr.DebraManager[MaxThreads, CC]
  ThreadHandle*[MaxThreads: static int, CC: static nebr.PinScopeCardinality = nebr.ccMulti] = nebr.ThreadHandle[MaxThreads, CC]

# ---------------------------------------------------------------------------
# Bounded legacy type aliases (historical parameter ordering: capacity/threads first, T last)
# ---------------------------------------------------------------------------

type
  Sipsic*[N: static int; T] = BQueue[T, pinscope_stub.ccSingle, pinscope_stub.ccSingle, N, 0, 0]
    ## Single-producer, single-consumer (SPSC) bounded queue.

  Mupsic*[N, P: static int; T] = BQueue[T, pinscope_stub.ccMulti, pinscope_stub.ccSingle, N, P, 0]
    ## Multi-producer, single-consumer (MPSC) bounded queue.

  Sipmuc*[N, C: static int; T] = BQueue[T, pinscope_stub.ccSingle, pinscope_stub.ccMulti, N, 0, C]
    ## Single-producer, multi-consumer (SPMC) bounded queue.

  Mupmuc*[N, P, C: static int; T] = BQueue[T, pinscope_stub.ccMulti, pinscope_stub.ccMulti, N, P, C]
    ## Multi-producer, multi-consumer (MPMC) bounded queue.

  # Per-thread endpoint aliases
  MupmucProducer*[N, P, C: static int; T] = Bound[T, AnyThreadTag, BQueue[T, pinscope_stub.ccMulti, pinscope_stub.ccMulti, N, P, C]]
  MupmucConsumer*[N, P, C: static int; T] = Bound[T, AnyThreadTag, BQueue[T, pinscope_stub.ccMulti, pinscope_stub.ccMulti, N, P, C]]
  MupsicProducer*[N, P: static int; T] = Bound[T, AnyThreadTag, BQueue[T, pinscope_stub.ccMulti, pinscope_stub.ccSingle, N, P, 0]]
  SipmucConsumer*[N, C: static int; T] = Bound[T, AnyThreadTag, BQueue[T, pinscope_stub.ccSingle, pinscope_stub.ccMulti, N, 0, C]]

# ---------------------------------------------------------------------------
# Unbounded legacy type aliases
# ---------------------------------------------------------------------------

type
  UnboundedSipsic*[S: static int, T] = Queue[T, pinscope_stub.ccSingle, pinscope_stub.ccSingle, stEager, S, 1]
    ## Single-producer, single-consumer (SPSC) unbounded queue.

  UnboundedMupsic*[S: static int, T; MaxThreads: static int = 64] = Queue[T, pinscope_stub.ccMulti, pinscope_stub.ccSingle, stEager, S, MaxThreads]
    ## Multi-producer, single-consumer (MPSC) unbounded queue.

  UnboundedSipmuc*[S: static int, T; MaxThreads: static int = 64] = Queue[T, pinscope_stub.ccSingle, pinscope_stub.ccMulti, stEager, S, MaxThreads]
    ## Single-producer, multi-consumer (SPMC) unbounded queue.

  UnboundedMupmuc*[S: static int, T; MaxThreads: static int = 64] = Queue[T, pinscope_stub.ccMulti, pinscope_stub.ccMulti, stEager, S, MaxThreads]
    ## Multi-producer, multi-consumer (MPMC) unbounded queue.

  # Modern-style Queue alias wrappers with T first
  UnboundedSipsicQueue*[T; S: static int] = Queue[T, pinscope_stub.ccSingle, pinscope_stub.ccSingle, stEager, S, 1]
  UnboundedMupsicQueue*[T; S, MaxThreads: static int] = Queue[T, pinscope_stub.ccMulti, pinscope_stub.ccSingle, stEager, S, MaxThreads]
  UnboundedSipmucQueue*[T; S, MaxThreads: static int] = Queue[T, pinscope_stub.ccSingle, pinscope_stub.ccMulti, stEager, S, MaxThreads]
  UnboundedMupmucQueue*[T; S, MaxThreads: static int] = Queue[T, pinscope_stub.ccMulti, pinscope_stub.ccMulti, stEager, S, MaxThreads]

# ---------------------------------------------------------------------------
# Bounded constructors (supporting both minimal and 4-param arities per DEFECT-CRIT-01)
# ---------------------------------------------------------------------------

template newSipsicQueue*[T; N: static int; P: static int = 0; C: static int = 0](): untyped =
  newBQueue[T, pinscope_stub.ccSingle, pinscope_stub.ccSingle, N, 0, 0]()

template newMupsicQueue*[T; N, P: static int; C: static int = 0](): untyped =
  newBQueue[T, pinscope_stub.ccMulti, pinscope_stub.ccSingle, N, P, 0]()

template newSipmucQueue*[T; N, C: static int](): untyped =
  newBQueue[T, pinscope_stub.ccSingle, pinscope_stub.ccMulti, N, 0, C]()

template newMupmucQueue*[T; N, P, C: static int](): untyped =
  newBQueue[T, pinscope_stub.ccMulti, pinscope_stub.ccMulti, N, P, C]()

# Legacy init* constructors (capacity first, T last)
proc initSipsic*[N: static int, T](): Sipsic[N, T] {.inline.} =
  newBQueue[T, pinscope_stub.ccSingle, pinscope_stub.ccSingle, N, 0, 0]()

proc initMupsic*[N, P: static int, T](): Mupsic[N, P, T] {.inline.} =
  newBQueue[T, pinscope_stub.ccMulti, pinscope_stub.ccSingle, N, P, 0]()

proc initSipmuc*[N, C: static int, T](): Sipmuc[N, C, T] {.inline.} =
  newBQueue[T, pinscope_stub.ccSingle, pinscope_stub.ccMulti, N, 0, C]()

proc initMupmuc*[N, P, C: static int, T](): Mupmuc[N, P, C, T] {.inline.} =
  newBQueue[T, pinscope_stub.ccMulti, pinscope_stub.ccMulti, N, P, C]()

# ---------------------------------------------------------------------------
# Unbounded constructors
# ---------------------------------------------------------------------------

# newUnbounded*Queue constructors (T first)
template newUnboundedSipsicQueue*[T; S: static int](): untyped =
  newUnboundedSpscQueue[T, stEager, S, 1]()

template newUnboundedMupsicQueue*[T; S, MaxThreads: static int](): untyped =
  newUnboundedMpscQueue[T, stEager, S, MaxThreads]()

template newUnboundedSipmucQueue*[T; S, MaxThreads: static int](): untyped =
  newUnboundedSpmcQueue[T, stEager, S, MaxThreads]()

template newUnboundedMupmucQueue*[T; S, MaxThreads: static int](): untyped =
  newUnboundedMpmcQueue[T, stEager, S, MaxThreads]()

# Legacy newUnbounded* constructors (S first, T second)
template newUnboundedSipsic*[S: static int, T](): untyped =
  newUnboundedSpscQueue[T, stEager, S, 1]()

template newUnboundedMupsic*[S: static int, T; MaxThreads: static int = 64](): untyped =
  newUnboundedMpscQueue[T, stEager, S, MaxThreads]()

template newUnboundedMupsic*[S: static int, T; MaxThreads: static int](manager: auto): untyped =
  newUnboundedMpscQueue[T, stEager, S, MaxThreads](cast[ptr nebr.DebraManager[MaxThreads, nebr.ccSingle]](manager))

template newUnboundedMupsic*[S: static int, T; MaxThreads: static int](manager: auto, handle: auto): untyped =
  newUnboundedMpscQueue[T, stEager, S, MaxThreads](cast[ptr nebr.DebraManager[MaxThreads, nebr.ccSingle]](manager))

template newUnboundedMupsic*[S: static int, T; MaxThreads: static int](manager: auto, handle: auto, strategy: DeallocationStrategy): untyped =
  newUnboundedMpscQueue[T, strategy, S, MaxThreads](cast[ptr nebr.DebraManager[MaxThreads, nebr.ccSingle]](manager))

template newUnboundedSipmuc*[S: static int, T; MaxThreads: static int = 64](): untyped =
  newUnboundedSpmcQueue[T, stEager, S, MaxThreads]()

template newUnboundedSipmuc*[S: static int, T; MaxThreads: static int](manager: auto): untyped =
  newUnboundedSpmcQueue[T, stEager, S, MaxThreads](cast[ptr nebr.DebraManager[MaxThreads, nebr.ccMulti]](manager))

template newUnboundedSipmuc*[S: static int, T; MaxThreads: static int](manager: auto, strategy: DeallocationStrategy): untyped =
  newUnboundedSpmcQueue[T, strategy, S, MaxThreads](cast[ptr nebr.DebraManager[MaxThreads, nebr.ccMulti]](manager))

template newUnboundedMupmuc*[S: static int, T; MaxThreads: static int = 64](): untyped =
  newUnboundedMpmcQueue[T, stEager, S, MaxThreads]()

template newUnboundedMupmuc*[S: static int, T; MaxThreads: static int](manager: auto): untyped =
  newUnboundedMpmcQueue[T, stEager, S, MaxThreads](cast[ptr nebr.DebraManager[MaxThreads, nebr.ccMulti]](manager))

template newUnboundedMupmuc*[S: static int, T; MaxThreads: static int](manager: auto, strategy: DeallocationStrategy): untyped =
  newUnboundedMpmcQueue[T, strategy, S, MaxThreads](cast[ptr nebr.DebraManager[MaxThreads, nebr.ccMulti]](manager))

# ---------------------------------------------------------------------------
# Auto-attach logic for endpoints (DEFECT-WARN-01)
# ---------------------------------------------------------------------------

template getProducer*[
    T;
    ccProd, ccCons: static pinscope_stub.PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](self: var Queue[T, ccProd, ccCons, ST, S, MaxThreads]): untyped =
  var u = endpoint.getProducer(self)
  u.bindToThread()

template getProducer*[
    T;
    ccProd, ccCons: static pinscope_stub.PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](self: var Queue[T, ccProd, ccCons, ST, S, MaxThreads], handle: auto): untyped =
  var u = endpoint.getProducer(self)
  u.bindToThread()

template getConsumer*[
    T;
    ccProd, ccCons: static pinscope_stub.PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](self: var Queue[T, ccProd, ccCons, ST, S, MaxThreads]): untyped =
  var u = endpoint.getConsumer(self)
  u.bindToThread()

template getConsumer*[
    T;
    ccProd, ccCons: static pinscope_stub.PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](self: var Queue[T, ccProd, ccCons, ST, S, MaxThreads], handle: auto): untyped =
  var u = endpoint.getConsumer(self)
  u.bindToThread()

template getProducer*[T; ccCons: static pinscope_stub.PinScopeCardinality, N, P, C: static int](
    self: var BQueue[T, pinscope_stub.ccMulti, ccCons, N, P, C], idx: int = -1
): untyped =
  var u = endpoint.getProducer(self, idx)
  u.bindToThread()

template getConsumer*[T; ccProd: static pinscope_stub.PinScopeCardinality, N, P, C: static int](
    self: var BQueue[T, ccProd, pinscope_stub.ccMulti, N, P, C], idx: int = -1
): untyped =
  var u = endpoint.getConsumer(self, idx)
  u.bindToThread()

template attach*(b: Bound): untyped = b
template attach*(u: Unbound): untyped = u.bindToThread()

proc isAttached*[T; Tag; queueT](u: Unbound[T, Tag, queueT]): bool {.inline.} = false
proc isAttached*[T; Tag; queueT](b: Bound[T, Tag, queueT]): bool {.inline.} = true

