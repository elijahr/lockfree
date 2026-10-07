## lockfree/channel — High-level Go/Rust-style Channel facade for `lockfree`.
##
## Collapses the 6-parameter generic surface of `BQueue` and `Queue` into
## ergonomic `Sender[T]`, `Receiver[T]`, and `Channel[T]` types.
##
## Features:
##   - Bounded and unbounded channel flavours (`ChannelKind.ckBounded`, `ckUnbounded`).
##   - Auto-registration for threads using thread-local storage (`{.threadvar.}`).
##     Threads can simply call `tx.send(item)` and `rx.recv()` without manual
##     `getProducer().bindToThread()` ceremonies.
##   - Smart `withEndpoint*(queue, ep, body)` AST-inspecting macro that auto-infers
##     whether to bind a producer or consumer based on whether `.push()` or `.pop()`
##     is called.

import std/[options, macros]
import ./atomics
import ./bqueue
import ./queue
import ./endpoint
import ./strategy
import ./reclamation
import ./role_tags
import ./typestates/with_bound
import ./exceptions

export with_bound

type
  ChannelKind* = enum
    ckBounded
    ckUnbounded

  ChannelConfig* = object
    kind*: ChannelKind
    capacity*: int
    segmentSize*: int
    maxThreads*: int
    eagerReclaim*: bool

proc defaultChannelConfig*(kind: ChannelKind = ckBounded): ChannelConfig =
  ## Returns sensible default configuration for bounded or unbounded channels.
  ChannelConfig(
    kind: kind,
    capacity: 1024,
    segmentSize: 64,
    maxThreads: 128,
    eagerReclaim: true
  )

var gNextChannelId {.global.}: Atomic[uint64]

proc allocChannelId(): uint64 =
  gNextChannelId.fetchAdd(1, moRelaxed) + 1

type
  ChannelCore[T] = object
    kind*: ChannelKind
    id*: uint64
    rc*: Atomic[int]
    isClosed*: Atomic[bool]
    destroyProc*: proc(self: pointer) {.nimcall, gcsafe, raises: [].}
    sendProc*: proc(self: pointer, item: sink T): bool {.nimcall, gcsafe, raises: [].}
    recvProc*: proc(self: pointer): Option[T] {.nimcall, gcsafe, raises: [].}
    lenProc*: proc(self: pointer): int {.nimcall, gcsafe, raises: [].}
    isFullProc*: proc(self: pointer): bool {.nimcall, gcsafe, raises: [].}
    isEmptyProc*: proc(self: pointer): bool {.nimcall, gcsafe, raises: [].}

  Sender*[T] = object
    core*: ptr ChannelCore[T]

  Receiver*[T] = object
    core*: ptr ChannelCore[T]

  Channel*[T] = object
    tx*: Sender[T]
    rx*: Receiver[T]

proc `=destroy`*[T](s: var Sender[T]) =
  if s.core != nil:
    if s.core.rc.fetchSub(1, moRelease) == 1:
      threadFence(moAcquire)
      if s.core.destroyProc != nil:
        s.core.destroyProc(s.core)
      deallocShared(s.core)
    s.core = nil

proc `=copy`*[T](dest: var Sender[T], src: Sender[T]) =
  if dest.core != src.core:
    `=destroy`(dest)
    dest.core = src.core
    if dest.core != nil:
      discard dest.core.rc.fetchAdd(1, moRelaxed)

proc `=dup`*[T](src: Sender[T]): Sender[T] =
  result.core = src.core
  if result.core != nil:
    discard result.core.rc.fetchAdd(1, moRelaxed)

proc `=destroy`*[T](r: var Receiver[T]) =
  if r.core != nil:
    if r.core.rc.fetchSub(1, moRelease) == 1:
      threadFence(moAcquire)
      if r.core.destroyProc != nil:
        r.core.destroyProc(r.core)
      deallocShared(r.core)
    r.core = nil

proc `=copy`*[T](dest: var Receiver[T], src: Receiver[T]) =
  if dest.core != src.core:
    `=destroy`(dest)
    dest.core = src.core
    if dest.core != nil:
      discard dest.core.rc.fetchAdd(1, moRelaxed)

proc `=dup`*[T](src: Receiver[T]): Receiver[T] =
  result.core = src.core
  if result.core != nil:
    discard result.core.rc.fetchAdd(1, moRelaxed)

# ---------------------------------------------------------------------------
# Bounded Channel Backend
# ---------------------------------------------------------------------------

type
  BoundedCore[T; N, P, C: static int] = object
    core*: ChannelCore[T]
    queue*: BQueue[T, ccMulti, ccMulti, N, P, C]

proc boundedDestroy[T; N, P, C: static int](p: pointer) {.nimcall, gcsafe, raises: [].} =
  {.cast(gcsafe).}:
    var bc = cast[ptr BoundedCore[T, N, P, C]](p)
    `=destroy`(bc.queue)

proc boundedSend[T; N, P, C: static int](p: pointer, item: sink T): bool {.nimcall, gcsafe, raises: [].} =
  var bc = cast[ptr BoundedCore[T, N, P, C]](p)
  if bc.core.isClosed.load(moAcquire):
    return false

  type BoundProd = Bound[T, AnyThreadTag, BQueue[T, ccMulti, ccMulti, N, P, C]]
  type CachedEntry = object
    chanId: uint64
    bound: BoundProd

  var tlsProducers {.threadvar.}: seq[CachedEntry]
  let chanId = bc.core.id
  for i in 0 ..< tlsProducers.len:
    if tlsProducers[i].chanId == chanId:
      return tlsProducers[i].bound.push(item)

  try:
    var u = bc.queue.getProducer()
    var b = u.bindToThread()
    tlsProducers.add(CachedEntry(chanId: chanId, bound: b))
    return tlsProducers[^1].bound.push(item)
  except NoProducersAvailableError:
    return false

proc boundedRecv[T; N, P, C: static int](p: pointer): Option[T] {.nimcall, gcsafe, raises: [].} =
  var bc = cast[ptr BoundedCore[T, N, P, C]](p)
  type BoundCons = Bound[T, AnyThreadTag, BQueue[T, ccMulti, ccMulti, N, P, C]]
  type CachedEntry = object
    chanId: uint64
    bound: BoundCons

  var tlsConsumers {.threadvar.}: seq[CachedEntry]
  let chanId = bc.core.id
  for i in 0 ..< tlsConsumers.len:
    if tlsConsumers[i].chanId == chanId:
      return tlsConsumers[i].bound.pop()

  try:
    var u = bc.queue.getConsumer()
    var b = u.bindToThread()
    tlsConsumers.add(CachedEntry(chanId: chanId, bound: b))
    return tlsConsumers[^1].bound.pop()
  except NoConsumersAvailableError:
    return none(T)

proc boundedLen[T; N, P, C: static int](p: pointer): int {.nimcall, gcsafe, raises: [].} =
  var bc = cast[ptr BoundedCore[T, N, P, C]](p)
  var q = addr(bc.queue)
  let t = q.tail.load(moRelaxed)
  let h = q.head.load(moRelaxed)
  if t >= h: int(t - h) else: 0

proc boundedIsFull[T; N, P, C: static int](p: pointer): bool {.nimcall, gcsafe, raises: [].} =
  boundedLen[T, N, P, C](p) >= N

proc boundedIsEmpty[T; N, P, C: static int](p: pointer): bool {.nimcall, gcsafe, raises: [].} =
  boundedLen[T, N, P, C](p) == 0

proc newBoundedChannelImpl*[T; N, P, C: static int](): tuple[tx: Sender[T], rx: Receiver[T]] =
  let bc = cast[ptr BoundedCore[T, N, P, C]](allocShared0(sizeof(BoundedCore[T, N, P, C])))
  bc.core.kind = ckBounded
  bc.core.id = allocChannelId()
  bc.core.rc.store(2, moRelaxed)
  bc.core.isClosed.store(false, moRelaxed)
  bc.core.destroyProc = boundedDestroy[T, N, P, C]
  bc.core.sendProc = boundedSend[T, N, P, C]
  bc.core.recvProc = boundedRecv[T, N, P, C]
  bc.core.lenProc = boundedLen[T, N, P, C]
  bc.core.isFullProc = boundedIsFull[T, N, P, C]
  bc.core.isEmptyProc = boundedIsEmpty[T, N, P, C]
  bc.queue = newBQueue[T, ccMulti, ccMulti, N, P, C]()
  let corePtr = cast[ptr ChannelCore[T]](bc)
  (Sender[T](core: corePtr), Receiver[T](core: corePtr))

# ---------------------------------------------------------------------------
# Unbounded Channel Backend
# ---------------------------------------------------------------------------

type
  UnboundedCore[T; ST: static DeallocationStrategy; S, MaxThreads: static int] = object
    core*: ChannelCore[T]
    queue*: Queue[T, ccMulti, ccMulti, ST, S, MaxThreads]

proc unboundedDestroy[T; ST: static DeallocationStrategy; S, MaxThreads: static int](p: pointer) {.nimcall, gcsafe, raises: [].} =
  {.cast(gcsafe).}:
    var uc = cast[ptr UnboundedCore[T, ST, S, MaxThreads]](p)
    `=destroy`(uc.queue)

proc unboundedSend[T; ST: static DeallocationStrategy; S, MaxThreads: static int](p: pointer, item: sink T): bool {.nimcall, gcsafe, raises: [].} =
  {.cast(gcsafe).}:
    var uc = cast[ptr UnboundedCore[T, ST, S, MaxThreads]](p)
    if uc.core.isClosed.load(moAcquire):
      return false

    type BoundProd = Bound[T, AnyThreadTag, Queue[T, ccMulti, ccMulti, ST, S, MaxThreads]]
    type CachedEntry = object
      chanId: uint64
      bound: BoundProd

    var tlsProducers {.threadvar.}: seq[CachedEntry]
    let chanId = uc.core.id
    for i in 0 ..< tlsProducers.len:
      if tlsProducers[i].chanId == chanId:
        tlsProducers[i].bound.push(item)
        return true

    var u = uc.queue.getProducer()
    var b = u.bindToThread()
    tlsProducers.add(CachedEntry(chanId: chanId, bound: b))
    tlsProducers[^1].bound.push(item)
    return true

proc unboundedRecv[T; ST: static DeallocationStrategy; S, MaxThreads: static int](p: pointer): Option[T] {.nimcall, gcsafe, raises: [].} =
  {.cast(gcsafe).}:
    var uc = cast[ptr UnboundedCore[T, ST, S, MaxThreads]](p)
    type BoundCons = Bound[T, AnyThreadTag, Queue[T, ccMulti, ccMulti, ST, S, MaxThreads]]
    type CachedEntry = object
      chanId: uint64
      bound: BoundCons

    var tlsConsumers {.threadvar.}: seq[CachedEntry]
    let chanId = uc.core.id
    for i in 0 ..< tlsConsumers.len:
      if tlsConsumers[i].chanId == chanId:
        return tlsConsumers[i].bound.pop()

    var u = uc.queue.getConsumer()
    var b = u.bindToThread()
    tlsConsumers.add(CachedEntry(chanId: chanId, bound: b))
    return tlsConsumers[^1].bound.pop()

proc unboundedLen[T; ST: static DeallocationStrategy; S, MaxThreads: static int](p: pointer): int {.nimcall, gcsafe, raises: [].} =
  {.cast(gcsafe).}:
    var uc = cast[ptr UnboundedCore[T, ST, S, MaxThreads]](p)
    uc.queue.len()

proc unboundedIsFull[T; ST: static DeallocationStrategy; S, MaxThreads: static int](p: pointer): bool {.nimcall, gcsafe, raises: [].} =
  false

proc unboundedIsEmpty[T; ST: static DeallocationStrategy; S, MaxThreads: static int](p: pointer): bool {.nimcall, gcsafe, raises: [].} =
  unboundedLen[T, ST, S, MaxThreads](p) == 0

proc newUnboundedChannelImpl*[T; ST: static DeallocationStrategy; S, MaxThreads: static int](): tuple[tx: Sender[T], rx: Receiver[T]] =
  let uc = cast[ptr UnboundedCore[T, ST, S, MaxThreads]](allocShared0(sizeof(UnboundedCore[T, ST, S, MaxThreads])))
  uc.core.kind = ckUnbounded
  uc.core.id = allocChannelId()
  uc.core.rc.store(2, moRelaxed)
  uc.core.isClosed.store(false, moRelaxed)
  uc.core.destroyProc = unboundedDestroy[T, ST, S, MaxThreads]
  uc.core.sendProc = unboundedSend[T, ST, S, MaxThreads]
  uc.core.recvProc = unboundedRecv[T, ST, S, MaxThreads]
  uc.core.lenProc = unboundedLen[T, ST, S, MaxThreads]
  uc.core.isFullProc = unboundedIsFull[T, ST, S, MaxThreads]
  uc.core.isEmptyProc = unboundedIsEmpty[T, ST, S, MaxThreads]
  uc.queue = newUnboundedMpmcQueue[T, ST, S, MaxThreads]()
  let corePtr = cast[ptr ChannelCore[T]](uc)
  (Sender[T](core: corePtr), Receiver[T](core: corePtr))

# ---------------------------------------------------------------------------
# High-Level Channel Constructors
# ---------------------------------------------------------------------------

proc newChannel*[T](capacity: static int = 1024): tuple[tx: Sender[T], rx: Receiver[T]] =
  ## Creates a bounded channel with static capacity (defaults to 1024).
  newBoundedChannelImpl[T, capacity, 128, 128]()

proc newChannel*[T](capacity: int): tuple[tx: Sender[T], rx: Receiver[T]] =
  ## Creates a bounded channel with dynamic capacity (rounded to next power of 2).
  if capacity <= 16:
    newBoundedChannelImpl[T, 16, 128, 128]()
  elif capacity <= 32:
    newBoundedChannelImpl[T, 32, 128, 128]()
  elif capacity <= 64:
    newBoundedChannelImpl[T, 64, 128, 128]()
  elif capacity <= 128:
    newBoundedChannelImpl[T, 128, 128, 128]()
  elif capacity <= 256:
    newBoundedChannelImpl[T, 256, 128, 128]()
  elif capacity <= 512:
    newBoundedChannelImpl[T, 512, 128, 128]()
  elif capacity <= 1024:
    newBoundedChannelImpl[T, 1024, 128, 128]()
  elif capacity <= 2048:
    newBoundedChannelImpl[T, 2048, 128, 128]()
  elif capacity <= 4096:
    newBoundedChannelImpl[T, 4096, 128, 128]()
  elif capacity <= 8192:
    newBoundedChannelImpl[T, 8192, 128, 128]()
  elif capacity <= 16384:
    newBoundedChannelImpl[T, 16384, 128, 128]()
  elif capacity <= 32768:
    newBoundedChannelImpl[T, 32768, 128, 128]()
  else:
    newBoundedChannelImpl[T, 65536, 128, 128]()

proc newUnboundedChannel*[T](segmentSize: static int = 64): tuple[tx: Sender[T], rx: Receiver[T]] =
  ## Creates an unbounded lock-free channel with static segment size.
  newUnboundedChannelImpl[T, stEager, segmentSize, 128]()

proc newUnboundedChannel*[T](segmentSize: int): tuple[tx: Sender[T], rx: Receiver[T]] =
  ## Creates an unbounded lock-free channel with dynamic segment size.
  if segmentSize <= 16:
    newUnboundedChannelImpl[T, stEager, 16, 128]()
  elif segmentSize <= 32:
    newUnboundedChannelImpl[T, stEager, 32, 128]()
  elif segmentSize <= 64:
    newUnboundedChannelImpl[T, stEager, 64, 128]()
  elif segmentSize <= 128:
    newUnboundedChannelImpl[T, stEager, 128, 128]()
  elif segmentSize <= 256:
    newUnboundedChannelImpl[T, stEager, 256, 128]()
  else:
    newUnboundedChannelImpl[T, stEager, 512, 128]()

proc newChannel*[T](config: ChannelConfig): tuple[tx: Sender[T], rx: Receiver[T]] =
  ## Creates a channel configured via `ChannelConfig`.
  case config.kind
  of ckBounded:
    newChannel[T](if config.capacity > 0: config.capacity else: 1024)
  of ckUnbounded:
    newUnboundedChannel[T](if config.segmentSize > 0: config.segmentSize else: 64)

proc channel*[T](capacity: static int = 1024): Channel[T] =
  let tup = newChannel[T](capacity)
  Channel[T](tx: tup.tx, rx: tup.rx)

proc channel*[T](capacity: int): Channel[T] =
  let tup = newChannel[T](capacity)
  Channel[T](tx: tup.tx, rx: tup.rx)

proc channel*[T](config: ChannelConfig): Channel[T] =
  let tup = newChannel[T](config)
  Channel[T](tx: tup.tx, rx: tup.rx)

proc unboundedChannel*[T](segmentSize: static int = 64): Channel[T] =
  let tup = newUnboundedChannel[T](segmentSize)
  Channel[T](tx: tup.tx, rx: tup.rx)

proc unboundedChannel*[T](segmentSize: int): Channel[T] =
  let tup = newUnboundedChannel[T](segmentSize)
  Channel[T](tx: tup.tx, rx: tup.rx)

converter toTuple*[T](c: Channel[T]): tuple[tx: Sender[T], rx: Receiver[T]] =
  (c.tx, c.rx)

proc split*[T](c: Channel[T]): tuple[tx: Sender[T], rx: Receiver[T]] {.inline.} =
  (c.tx, c.rx)

converter toChannel*[T](t: tuple[tx: Sender[T], rx: Receiver[T]]): Channel[T] =
  Channel[T](tx: t.tx, rx: t.rx)

# ---------------------------------------------------------------------------
# Sender & Receiver Methods
# ---------------------------------------------------------------------------

proc send*[T](s: Sender[T], item: sink T): bool {.inline.} =
  ## Sends an item into the channel. Automatically registers the calling
  ## thread on first call without manual binding ceremonies.
  ## Returns true on success, false if bounded channel is full or closed.
  assert s.core != nil, "Sender: nil channel core"
  s.core.sendProc(s.core, item)

proc trySend*[T](s: Sender[T], item: sink T): bool {.inline.} =
  ## Non-blocking send alias.
  s.send(item)

proc recv*[T](r: Receiver[T]): Option[T] {.inline.} =
  ## Receives an item from the channel. Automatically registers the calling
  ## thread on first call without manual binding ceremonies.
  ## Returns some(item) on success, or none(T) if channel is empty.
  assert r.core != nil, "Receiver: nil channel core"
  r.core.recvProc(r.core)

proc tryRecv*[T](r: Receiver[T]): Option[T] {.inline.} =
  ## Non-blocking receive alias.
  r.recv()

proc close*[T](s: Sender[T]) {.inline.} =
  ## Closes the channel. Subsequent sends return false.
  if s.core != nil:
    s.core.isClosed.store(true, moRelease)

proc close*[T](r: Receiver[T]) {.inline.} =
  ## Closes the channel.
  if r.core != nil:
    r.core.isClosed.store(true, moRelease)

proc isClosed*[T](s: Sender[T]): bool {.inline.} =
  if s.core != nil: s.core.isClosed.load(moAcquire) else: true

proc isClosed*[T](r: Receiver[T]): bool {.inline.} =
  if r.core != nil: r.core.isClosed.load(moAcquire) else: true

proc kind*[T](s: Sender[T]): ChannelKind {.inline.} =
  assert s.core != nil
  s.core.kind

proc kind*[T](r: Receiver[T]): ChannelKind {.inline.} =
  assert r.core != nil
  r.core.kind

proc len*[T](s: Sender[T]): int {.inline.} =
  if s.core != nil: s.core.lenProc(s.core) else: 0

proc len*[T](r: Receiver[T]): int {.inline.} =
  if r.core != nil: r.core.lenProc(r.core) else: 0

proc isFull*[T](s: Sender[T]): bool {.inline.} =
  if s.core != nil: s.core.isFullProc(s.core) else: false

proc isEmpty*[T](r: Receiver[T]): bool {.inline.} =
  if r.core != nil: r.core.isEmptyProc(r.core) else: true

# ---------------------------------------------------------------------------
# Channel[T] Methods
# ---------------------------------------------------------------------------

proc send*[T](c: Channel[T], item: sink T): bool {.inline.} =
  c.tx.send(item)

proc trySend*[T](c: Channel[T], item: sink T): bool {.inline.} =
  c.tx.trySend(item)

proc recv*[T](c: Channel[T]): Option[T] {.inline.} =
  c.rx.recv()

proc tryRecv*[T](c: Channel[T]): Option[T] {.inline.} =
  c.rx.tryRecv()

proc close*[T](c: Channel[T]) {.inline.} =
  c.tx.close()

proc isClosed*[T](c: Channel[T]): bool {.inline.} =
  c.tx.isClosed()

proc len*[T](c: Channel[T]): int {.inline.} =
  c.tx.len()

proc kind*[T](c: Channel[T]): ChannelKind {.inline.} =
  c.tx.kind()

proc isFull*[T](c: Channel[T]): bool {.inline.} =
  c.tx.isFull()

proc isEmpty*[T](c: Channel[T]): bool {.inline.} =
  c.rx.isEmpty()

# ---------------------------------------------------------------------------
# Smart Role-Inferring withEndpoint Macro
# ---------------------------------------------------------------------------

proc inferEndpointRole(epIdentStr: string, node: NimNode, foundProducer: var bool, foundConsumer: var bool) =
  case node.kind
  of nnkCall, nnkCommand:
    if node.len >= 1:
      if node[0].kind == nnkDotExpr and node[0].len >= 2:
        if node[0][0].kind in {nnkIdent, nnkSym} and node[0][0].strVal == epIdentStr:
          let op = node[0][1].strVal
          if op in ["push", "pushBatch", "send", "trySend"]:
            foundProducer = true
          elif op in ["pop", "popBatch", "recv", "tryRecv"]:
            foundConsumer = true
      elif node[0].kind in {nnkIdent, nnkSym} and node.len >= 2:
        let op = node[0].strVal
        if node[1].kind in {nnkIdent, nnkSym} and node[1].strVal == epIdentStr:
          if op in ["push", "pushBatch", "send", "trySend"]:
            foundProducer = true
          elif op in ["pop", "popBatch", "recv", "tryRecv"]:
            foundConsumer = true
  else:
    discard
  for child in node:
    inferEndpointRole(epIdentStr, child, foundProducer, foundConsumer)

macro withEndpoint*(queue, ep, body: untyped): untyped =
  ## Smart role-inferring RAII macro.
  ##
  ## Inspects `body` AST for `.push()` / `.pop()` calls on `ep` to auto-infer
  ## whether to bind a producer or consumer endpoint.
  ## Expands to `withBoundProducer(queue, ep, body)` or
  ## `withBoundConsumer(queue, ep, body)`.
  var foundProd = false
  var foundCons = false
  let epStr = if ep.kind in {nnkIdent, nnkSym}: ep.strVal else: ep.repr
  inferEndpointRole(epStr, body, foundProd, foundCons)
  if foundProd and foundCons:
    error("withEndpoint: ambiguous role in body; both push and pop called on endpoint '" & epStr & "'", body)
  elif foundCons:
    result = newCall(bindSym"withBoundConsumer", queue, ep, body)
  else:
    result = newCall(bindSym"withBoundProducer", queue, ep, body)
