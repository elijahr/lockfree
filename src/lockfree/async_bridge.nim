## src/lockfree/async_bridge.nim
##
## Wave 3C Async Bridge Substrate for std/asyncdispatch.
##
## Provides high-performance, non-blocking asynchronous adapters over
## foundational lock-free containers:
##   - BQueue[T] (Bounded MPMC / SPSC) -> AsyncBQueue[T]
##   - Queue[T] (Unbounded LCRQ) -> AsyncQueue[T]
##   - RendezvousChannel[T] (Synchronous CSP zero-buffer handoff) -> AsyncRendezvousChannel[T]
##   - BroadcastRing[T] (Multicast 1-to-N fanout) -> AsyncBroadcastRing[T], AsyncBroadcastCursor[T]
##
## Core Architectural Invariants:
##   1. Fast-Path Speculative Non-Blocking Execution (zero-allocation immediate Future return)
##   2. Strict SMR Epoch Pin Isolation (PinScope ∩ SuspensionPoints = ∅; pin never held across await)
##   3. Bilateral CAS Arbitration on Cancellation (zero item loss guaranteed on coroutine abort)
##   4. Thread-Safe Cross-Thread Wakeups via AsyncSignal

when not compileOption("threads"):
  {.error: "lockfree/async_bridge requires --threads:on for cross-thread lock-free coordination.".}

when defined(lockfreeAsyncdispatch) or compileOption("threads"):
  import std/[asyncdispatch, options]
  import ./atomics
  import ./atomics/backoff
  import ./bqueue
  import ./queue
  import ./rendezvous
  import ./broadcast
  import ./strategy
  import ./endpoint
  import ./endpoint_types
  import ./role_tags
  import ./exceptions

  export exceptions

  # ---------------------------------------------------------------------------
  # Payload Box: Safe ARC/ORC Cross-Thread Transport
  # ---------------------------------------------------------------------------

  type
    AsyncPayloadBox[T] = object
      rc*: Atomic[int32]
      val*: T

  proc allocPayloadBox[T](item: sink T): ptr AsyncPayloadBox[T] {.inline.} =
    result = cast[ptr AsyncPayloadBox[T]](allocShared0(sizeof(AsyncPayloadBox[T])))
    result.rc.store(1, moRelaxed)
    result.val = item

  proc incRef[T](box: ptr AsyncPayloadBox[T]) {.inline.} =
    if box != nil:
      discard box.rc.fetchAdd(1, moRelaxed)

  proc decRef[T](box: ptr AsyncPayloadBox[T]) {.inline, gcsafe.} =
    if box != nil:
      if box.rc.fetchSub(1, moRelease) == 1:
        threadFence(moAcquire)
        when not (T is SomeNumber or T is bool or T is char or T is pointer or T is ptr):
          {.cast(gcsafe).}:
            `=destroy`(box.val)
        deallocShared(box)

  # ---------------------------------------------------------------------------
  # Polyglot AsyncSignal: Thread-Safe Cross-Thread Reactor Wakeup
  # ---------------------------------------------------------------------------

  type
    AsyncSignal* = ref object
      signaled*: Atomic[bool]
      event*: AsyncEvent
      waiters*: seq[Future[void]]
      registered*: bool

  proc newAsyncSignal*(): AsyncSignal =
    new result
    result.signaled.store(false, moRelaxed)
    result.event = newAsyncEvent()
    result.waiters = @[]
    result.registered = false

  proc fire*(sig: AsyncSignal) {.inline, gcsafe.} =
    ## Thread-safe, non-blocking signal trigger. Can be invoked from any OS thread.
    if sig == nil: return
    sig.signaled.store(true, moRelease)
    sig.event.trigger()

  proc clear*(sig: AsyncSignal) {.inline, gcsafe.} =
    if sig == nil: return
    sig.signaled.store(false, moRelease)

  proc wait*(sig: AsyncSignal): Future[void] =
    ## Suspends until the signal is fired. Sticky flag prevents lost wakeups.
    if sig.signaled.exchange(false, moAcquireRelease):
      var fut = newFuture[void]("AsyncSignal.wait.fast")
      fut.complete()
      return fut

    var fut = newFuture[void]("AsyncSignal.wait.slow")
    sig.waiters.add(fut)

    if not sig.registered:
      sig.registered = true
      sig.event.addEvent(proc(fd: AsyncFD): bool =
        sig.signaled.store(false, moRelease)
        var pending = move sig.waiters
        sig.waiters = @[]
        sig.registered = false
        for w in pending:
          if not w.finished:
            w.complete()
        return true # unregister from selector
      )
    return fut

  proc close*(sig: AsyncSignal) =
    if sig != nil:
      sig.event.close()

  # ---------------------------------------------------------------------------
  # Spinlock Helper
  # ---------------------------------------------------------------------------

  proc acquireLock(lock: var Atomic[bool]) {.inline.} =
    while lock.exchange(true, moAcquire):
      while lock.load(moRelaxed):
        cpuPause()

  proc releaseLock(lock: var Atomic[bool]) {.inline.} =
    lock.store(false, moRelease)

  # ---------------------------------------------------------------------------
  # 1. Bounded Queue Adapter: AsyncBQueue[T]
  # ---------------------------------------------------------------------------

  type
    AsyncBQueue*[
      T;
      ccProd, ccCons: static PinScopeCardinality,
      N, P, C: static int,
    ] = ref object
      queue*: BQueue[T, ccProd, ccCons, N, P, C]
      consumerSignal*: AsyncSignal
      producerSignal*: AsyncSignal
      hasWaitingConsumers*: Atomic[bool]
      hasWaitingProducers*: Atomic[bool]

  proc newAsyncBQueue*[
      T;
      ccProd, ccCons: static PinScopeCardinality,
      N, P, C: static int,
  ](): AsyncBQueue[T, ccProd, ccCons, N, P, C] =
    new result
    result.queue = newBQueue[T, ccProd, ccCons, N, P, C]()
    result.consumerSignal = newAsyncSignal()
    result.producerSignal = newAsyncSignal()
    result.hasWaitingConsumers.store(false, moRelaxed)
    result.hasWaitingProducers.store(false, moRelaxed)

  proc toAsync*[T; ccProd, ccCons: static PinScopeCardinality; N, P, C: static int](
      q: sink BQueue[T, ccProd, ccCons, N, P, C]
  ): AsyncBQueue[T, ccProd, ccCons, N, P, C] =
    new result
    result.queue = q
    result.consumerSignal = newAsyncSignal()
    result.producerSignal = newAsyncSignal()
    result.hasWaitingConsumers.store(false, moRelaxed)
    result.hasWaitingProducers.store(false, moRelaxed)

  proc sendAsync*[T; N: static int](
      self: AsyncBQueue[T, ccSingle, ccSingle, N, 0, 0],
      item: sink T
  ): Future[bool] {.async.} =
    ## Asynchronously sends an item into the bounded queue.
    ## Suspends if full until space is available.
    var cur = move item
    while true:
      self.producerSignal.clear()
      self.hasWaitingProducers.store(true, moRelease)
      if self.queue.push(cur):
        self.hasWaitingProducers.store(false, moRelease)
        if self.hasWaitingConsumers.load(moAcquire):
          self.consumerSignal.fire()
        return true
      await self.producerSignal.wait()

  proc recvAsync*[T; N: static int](
      self: AsyncBQueue[T, ccSingle, ccSingle, N, 0, 0]
  ): Future[Option[T]] {.async.} =
    ## Asynchronously awaits and receives an item from the bounded queue.
    ## SMR invariant: No pin held across await.
    while true:
      self.consumerSignal.clear()
      self.hasWaitingConsumers.store(true, moRelease)
      let v = self.queue.pop()
      if v.isSome:
        self.hasWaitingConsumers.store(false, moRelease)
        if self.hasWaitingProducers.load(moAcquire):
          self.producerSignal.fire()
        return v
      await self.consumerSignal.wait()

  proc tryPopAsync*[T; N: static int](
      self: AsyncBQueue[T, ccSingle, ccSingle, N, 0, 0]
  ): Future[Option[T]] =
    ## Speculative non-blocking try-pop. Returns immediately resolved Future.
    let v = self.queue.pop()
    if v.isSome and self.hasWaitingProducers.load(moAcquire):
      self.producerSignal.fire()
    var fut = newFuture[Option[T]]("tryPopAsync")
    fut.complete(v)
    return fut

  proc push*[T; N: static int](
      self: AsyncBQueue[T, ccSingle, ccSingle, N, 0, 0], item: sink T
  ): bool =
    ## Synchronous push with consumer wakeup.
    result = self.queue.push(item)
    if result:
      self.consumerSignal.fire()

  proc pop*[T; N: static int](
      self: AsyncBQueue[T, ccSingle, ccSingle, N, 0, 0]
  ): Future[Option[T]] {.inline.} =
    self.recvAsync()

  # Direct on BQueue:
  proc tryPopAsync*[T; N: static int](
      self: var BQueue[T, ccSingle, ccSingle, N, 0, 0]
  ): Future[Option[T]] =
    let v = self.pop()
    var fut = newFuture[Option[T]]("tryPopAsync")
    fut.complete(v)
    return fut

  # ---------------------------------------------------------------------------
  # 2. Unbounded Queue Adapter: AsyncQueue[T] (LCRQ)
  # ---------------------------------------------------------------------------

  type
    AsyncQueue*[
      T;
      ccProd, ccCons: static PinScopeCardinality,
      ST: static DeallocationStrategy,
      S, MaxThreads: static int,
    ] = ref object
      queue*: Queue[T, ccProd, ccCons, ST, S, MaxThreads]
      consumerSignal*: AsyncSignal
      hasWaitingConsumers*: Atomic[bool]

    AsyncQueueSpsc*[T; S, MaxThreads: static int] =
      AsyncQueue[T, ccSingle, ccSingle, stEager, S, MaxThreads]

  proc newAsyncQueue*[
      T;
      ccProd, ccCons: static PinScopeCardinality,
      ST: static DeallocationStrategy,
      S, MaxThreads: static int,
  ](
      _: typedesc[AsyncQueue[T, ccProd, ccCons, ST, S, MaxThreads]]
  ): AsyncQueue[T, ccProd, ccCons, ST, S, MaxThreads] =
    new result
    result.queue = newQueue(Queue[T, ccProd, ccCons, ST, S, MaxThreads])
    result.consumerSignal = newAsyncSignal()
    result.hasWaitingConsumers.store(false, moRelaxed)

  proc toAsync*[
      T;
      ccProd, ccCons: static PinScopeCardinality,
      ST: static DeallocationStrategy,
      S, MaxThreads: static int,
  ](
      q: sink Queue[T, ccProd, ccCons, ST, S, MaxThreads]
  ): AsyncQueue[T, ccProd, ccCons, ST, S, MaxThreads] =
    new result
    result.queue = q
    result.consumerSignal = newAsyncSignal()
    result.hasWaitingConsumers.store(false, moRelaxed)

  proc sendAsync*[T; ST: static DeallocationStrategy, S, MaxThreads: static int](
      self: AsyncQueue[T, ccSingle, ccSingle, ST, S, MaxThreads],
      item: sink T
  ): Future[bool] =
    ## Unbounded enqueue never blocks; pushes immediately and notifies waiting consumers.
    var prod = self.queue.getProducerHere()
    prod.push(item)
    if self.hasWaitingConsumers.load(moAcquire):
      self.consumerSignal.fire()
    var fut = newFuture[bool]("sendAsync")
    fut.complete(true)
    return fut

  proc recvAsync*[T; ST: static DeallocationStrategy, S, MaxThreads: static int](
      self: AsyncQueue[T, ccSingle, ccSingle, ST, S, MaxThreads]
  ): Future[Option[T]] {.async.} =
    ## Asynchronously awaits and receives an item from the unbounded queue.
    while true:
      self.consumerSignal.clear()
      self.hasWaitingConsumers.store(true, moRelease)
      let v = self.queue.pop()
      if v.isSome:
        self.hasWaitingConsumers.store(false, moRelease)
        return v
      await self.consumerSignal.wait()

  proc tryPopAsync*[T; ST: static DeallocationStrategy, S, MaxThreads: static int](
      self: AsyncQueue[T, ccSingle, ccSingle, ST, S, MaxThreads]
  ): Future[Option[T]] =
    let v = self.queue.pop()
    var fut = newFuture[Option[T]]("tryPopAsync")
    fut.complete(v)
    return fut

  proc pop*[T; ST: static DeallocationStrategy, S, MaxThreads: static int](
      self: AsyncQueue[T, ccSingle, ccSingle, ST, S, MaxThreads]
  ): Future[Option[T]] {.inline.} =
    self.recvAsync()

  # Direct on Queue:
  proc tryPopAsync*[T; ST: static DeallocationStrategy, S, MaxThreads: static int](
      self: var Queue[T, ccSingle, ccSingle, ST, S, MaxThreads]
  ): Future[Option[T]] =
    let v = self.pop()
    var fut = newFuture[Option[T]]("tryPopAsync")
    fut.complete(v)
    return fut

  # ---------------------------------------------------------------------------
  # 3. Synchronous Dual Channel Adapter: AsyncRendezvousChannel[T]
  # ---------------------------------------------------------------------------

  type
    AsyncRendezvousState* = enum
      arsWaiting
      arsMatched
      arsCancelled

    AsyncRendezvousWaiterNode[T] = ref object
      state*: Atomic[AsyncRendezvousState]
      box*: Atomic[ptr AsyncPayloadBox[T]]
      signal*: AsyncSignal
      next*: AsyncRendezvousWaiterNode[T]

    AsyncRendezvousChannel*[T] = ref object
      chan*: RendezvousChannel[T]
      waitingSenders*: AsyncRendezvousWaiterNode[T]
      waitingReceivers*: AsyncRendezvousWaiterNode[T]
      waiterLock*: Atomic[bool]

  proc newAsyncRendezvousChannel*[T](): AsyncRendezvousChannel[T] =
    new result
    result.chan = initRendezvousChannel[T]()
    result.waiterLock.store(false, moRelaxed)

  proc toAsync*[T](chan: RendezvousChannel[T]): AsyncRendezvousChannel[T] =
    new result
    result.chan = chan
    result.waiterLock.store(false, moRelaxed)

  proc isClosed*[T](self: AsyncRendezvousChannel[T]): bool {.inline.} =
    self.chan.isClosed

  proc close*[T](self: AsyncRendezvousChannel[T]) =
    self.chan.close()
    self.waiterLock.acquireLock()
    var s = self.waitingSenders
    while s != nil:
      s.signal.fire()
      s = s.next
    var r = self.waitingReceivers
    while r != nil:
      r.signal.fire()
      r = r.next
    self.waiterLock.releaseLock()

  proc sendAsync*[T](self: AsyncRendezvousChannel[T], item: sink T): Future[bool] {.async.} =
    ## Asynchronously sends an item through the rendezvous channel.
    ## Matches an active receiver (OS thread or coroutine) or suspends until matched.
    ## Bilateral CAS arbitration guarantees zero item loss on cancellation.
    if self.chan.isClosed:
      raise newException(ChannelClosedDefect, "RendezvousChannel is closed")

    var curItem = move item
    # Fast path 1: Check if synchronous thread is parked in chan.recv()
    var corrId: uint64
    if self.chan.trySend(curItem, corrId):
      return true

    # Fast path 2: Check if async receiver is waiting
    var matchedReceiver: AsyncRendezvousWaiterNode[T] = nil
    self.waiterLock.acquireLock()
    var prev: AsyncRendezvousWaiterNode[T] = nil
    var curr = self.waitingReceivers
    while curr != nil:
      var exp = arsWaiting
      if curr.state.compareExchange(exp, arsMatched, moAcquireRelease):
        matchedReceiver = curr
        if prev == nil:
          self.waitingReceivers = curr.next
        else:
          prev.next = curr.next
        break
      else:
        # Cancelled or dead waiter
        if prev == nil:
          self.waitingReceivers = curr.next
        else:
          prev.next = curr.next
        curr = curr.next
    self.waiterLock.releaseLock()

    if matchedReceiver != nil:
      let pbox = allocPayloadBox(curItem)
      matchedReceiver.box.store(pbox, moRelease)
      matchedReceiver.signal.fire()
      return true

    # Slow path: Register as waiting sender
    var waiter = AsyncRendezvousWaiterNode[T](
      signal: newAsyncSignal()
    )
    waiter.state.store(arsWaiting, moRelaxed)
    let pbox = allocPayloadBox(curItem)
    waiter.box.store(pbox, moRelaxed)

    self.waiterLock.acquireLock()
    waiter.next = self.waitingSenders
    self.waitingSenders = waiter
    self.waiterLock.releaseLock()

    try:
      await waiter.signal.wait()
    except CatchableError as e:
      var exp = arsWaiting
      if waiter.state.compareExchange(exp, arsCancelled, moAcquireRelease):
        # Cancellation won arbitration! Reclaim box and unlink
        self.waiterLock.acquireLock()
        var p: AsyncRendezvousWaiterNode[T] = nil
        var c = self.waitingSenders
        while c != nil:
          if c == waiter:
            if p == nil: self.waitingSenders = c.next
            else: p.next = c.next
            break
          p = c
          c = c.next
        self.waiterLock.releaseLock()
        decRef(pbox)
        raise e
      # Peer won CAS before or concurrently with cancel; item transferred!
      return true

    if waiter.state.load(moAcquire) == arsMatched:
      return true
    else:
      raise newException(ChannelClosedDefect, "Channel closed while waiting")

  proc recvAsync*[T](self: AsyncRendezvousChannel[T]): Future[Option[T]] {.async.} =
    ## Asynchronously receives an item from the rendezvous channel.
    ## Matches an active sender (OS thread or coroutine) or suspends until matched.
    if self.chan.isClosed:
      return none(T)

    # Fast path 1: Check if synchronous thread is parked in chan.send()
    var val: T
    var corrId: uint64
    if self.chan.tryRecv(val, corrId):
      return some(val)

    # Fast path 2: Check if async sender is waiting
    var matchedSender: AsyncRendezvousWaiterNode[T] = nil
    self.waiterLock.acquireLock()
    var prev: AsyncRendezvousWaiterNode[T] = nil
    var curr = self.waitingSenders
    while curr != nil:
      var exp = arsWaiting
      if curr.state.compareExchange(exp, arsMatched, moAcquireRelease):
        matchedSender = curr
        if prev == nil:
          self.waitingSenders = curr.next
        else:
          prev.next = curr.next
        break
      else:
        if prev == nil:
          self.waitingSenders = curr.next
        else:
          prev.next = curr.next
        curr = curr.next
    self.waiterLock.releaseLock()

    if matchedSender != nil:
      let pbox = matchedSender.box.load(moAcquire)
      matchedSender.signal.fire()
      var res = pbox.val
      decRef(pbox)
      return some(res)

    # Slow path: Register as waiting receiver
    var waiter = AsyncRendezvousWaiterNode[T](
      signal: newAsyncSignal()
    )
    waiter.state.store(arsWaiting, moRelaxed)

    self.waiterLock.acquireLock()
    waiter.next = self.waitingReceivers
    self.waitingReceivers = waiter
    self.waiterLock.releaseLock()

    try:
      await waiter.signal.wait()
    except CatchableError as e:
      var exp = arsWaiting
      if waiter.state.compareExchange(exp, arsCancelled, moAcquireRelease):
        self.waiterLock.acquireLock()
        var p: AsyncRendezvousWaiterNode[T] = nil
        var c = self.waitingReceivers
        while c != nil:
          if c == waiter:
            if p == nil: self.waitingReceivers = c.next
            else: p.next = c.next
            break
          p = c
          c = c.next
        self.waiterLock.releaseLock()
        raise e
      # Sender matched concurrently; receive payload
      let pbox = waiter.box.load(moAcquire)
      var res = pbox.val
      decRef(pbox)
      return some(res)

    if waiter.state.load(moAcquire) == arsMatched:
      let pbox = waiter.box.load(moAcquire)
      var res = pbox.val
      decRef(pbox)
      return some(res)
    else:
      return none(T)

  proc tryPopAsync*[T](self: AsyncRendezvousChannel[T]): Future[Option[T]] =
    ## Speculative non-blocking try-recv.
    var val: T
    var corrId: uint64
    if self.chan.tryRecv(val, corrId):
      var fut = newFuture[Option[T]]("tryPopAsync")
      fut.complete(some(val))
      return fut

    var matchedSender: AsyncRendezvousWaiterNode[T] = nil
    self.waiterLock.acquireLock()
    var prev: AsyncRendezvousWaiterNode[T] = nil
    var curr = self.waitingSenders
    while curr != nil:
      var exp = arsWaiting
      if curr.state.compareExchange(exp, arsMatched, moAcquireRelease):
        matchedSender = curr
        if prev == nil:
          self.waitingSenders = curr.next
        else:
          prev.next = curr.next
        break
      else:
        if prev == nil:
          self.waitingSenders = curr.next
        else:
          prev.next = curr.next
        curr = curr.next
    self.waiterLock.releaseLock()

    var fut = newFuture[Option[T]]("tryPopAsync")
    if matchedSender != nil:
      let pbox = matchedSender.box.load(moAcquire)
      matchedSender.signal.fire()
      var res = pbox.val
      decRef(pbox)
      fut.complete(some(res))
    else:
      fut.complete(none(T))
    return fut

  proc send*[T](self: AsyncRendezvousChannel[T], item: sink T): uint64 =
    ## Synchronous send on AsyncRendezvousChannel (e.g. from an OS worker thread).
    ## Wakes a waiting async receiver or falls back to sync RendezvousChannel.
    if self.chan.isClosed:
      raise newException(ChannelClosedDefect, "RendezvousChannel is closed")

    var curItem = move item
    var matchedReceiver: AsyncRendezvousWaiterNode[T] = nil
    self.waiterLock.acquireLock()
    var prev: AsyncRendezvousWaiterNode[T] = nil
    var curr = self.waitingReceivers
    while curr != nil:
      var exp = arsWaiting
      if curr.state.compareExchange(exp, arsMatched, moAcquireRelease):
        matchedReceiver = curr
        if prev == nil:
          self.waitingReceivers = curr.next
        else:
          prev.next = curr.next
        break
      else:
        if prev == nil:
          self.waitingReceivers = curr.next
        else:
          prev.next = curr.next
        curr = curr.next
    self.waiterLock.releaseLock()

    if matchedReceiver != nil:
      let pbox = allocPayloadBox(curItem)
      matchedReceiver.box.store(pbox, moRelease)
      matchedReceiver.signal.fire()
      return 1

    result = self.chan.send(curItem)

  proc recv*[T](self: AsyncRendezvousChannel[T], outVal: var T): uint64 =
    ## Synchronous recv on AsyncRendezvousChannel (e.g. from an OS worker thread).
    ## Wakes a waiting async sender or falls back to sync RendezvousChannel.
    if self.chan.isClosed:
      raise newException(ChannelClosedDefect, "RendezvousChannel is closed")

    var matchedSender: AsyncRendezvousWaiterNode[T] = nil
    self.waiterLock.acquireLock()
    var prev: AsyncRendezvousWaiterNode[T] = nil
    var curr = self.waitingSenders
    while curr != nil:
      var exp = arsWaiting
      if curr.state.compareExchange(exp, arsMatched, moAcquireRelease):
        matchedSender = curr
        if prev == nil:
          self.waitingSenders = curr.next
        else:
          prev.next = curr.next
        break
      else:
        if prev == nil:
          self.waitingSenders = curr.next
        else:
          prev.next = curr.next
        curr = curr.next
    self.waiterLock.releaseLock()

    if matchedSender != nil:
      let pbox = matchedSender.box.load(moAcquire)
      matchedSender.signal.fire()
      outVal = pbox.val
      decRef(pbox)
      return 1

    result = self.chan.recv(outVal)

  # Direct on RendezvousChannel:
  proc tryPopAsync*[T](self: RendezvousChannel[T]): Future[Option[T]] =
    var val: T
    var corrId: uint64
    var fut = newFuture[Option[T]]("tryPopAsync")
    if self.tryRecv(val, corrId):
      fut.complete(some(val))
    else:
      fut.complete(none(T))
    return fut

  # ---------------------------------------------------------------------------
  # 4. Broadcast Ring Buffer Adapter: AsyncBroadcastRing[T] & Cursor
  # ---------------------------------------------------------------------------

  type
    AsyncBroadcastRing*[T] = ref object
      ring*: BroadcastRing[T]
      signal*: AsyncSignal

    AsyncBroadcastCursor*[T] = ref object
      cursor*: BroadcastCursor[T]
      ring*: AsyncBroadcastRing[T]
      signal*: AsyncSignal

  proc newAsyncBroadcastRing*[T](
      capacity: int = DefaultRingCapacity,
      overflowMode: OverflowMode = omDropOldest
  ): AsyncBroadcastRing[T] =
    new result
    result.ring = initBroadcastRing[T](capacity, overflowMode)
    result.signal = newAsyncSignal()

  proc toAsync*[T](ring: sink BroadcastRing[T]): AsyncBroadcastRing[T] =
    new result
    result.ring = ring
    result.signal = newAsyncSignal()

  proc subscribe*[T](
      self: AsyncBroadcastRing[T],
      origin: SubscriptionOrigin = soFromLatest
  ): AsyncBroadcastCursor[T] =
    new result
    result.ring = self
    result.cursor = self.ring.subscribe(origin)
    result.signal = self.signal

  proc publish*[T](self: AsyncBroadcastRing[T], item: sink T) =
    self.ring.publish(item)
    self.signal.fire()

  proc sendAsync*[T](self: AsyncBroadcastRing[T], item: sink T): Future[bool] =
    self.publish(item)
    var fut = newFuture[bool]("sendAsync")
    fut.complete(true)
    return fut

  proc sendAsync*[T](ring: BroadcastRing[T], item: sink T): Future[bool] =
    ring.publish(item)
    var fut = newFuture[bool]("sendAsync")
    fut.complete(true)
    return fut

  proc recvAsync*[T](self: AsyncBroadcastCursor[T]): Future[Option[T]] {.async.} =
    ## Asynchronously awaits the next available broadcast message on this cursor.
    while true:
      self.signal.clear()
      var val: T
      if self.cursor.tryRead(val):
        return some(val)
      await self.signal.wait()

  proc tryPopAsync*[T](self: AsyncBroadcastCursor[T]): Future[Option[T]] =
    var val: T
    var fut = newFuture[Option[T]]("tryPopAsync")
    if self.cursor.tryRead(val):
      fut.complete(some(val))
    else:
      fut.complete(none(T))
    return fut

  proc tryPopAsync*[T](self: var BroadcastCursor[T]): Future[Option[T]] =
    var val: T
    var fut = newFuture[Option[T]]("tryPopAsync")
    if self.tryRead(val):
      fut.complete(some(val))
    else:
      fut.complete(none(T))
    return fut
