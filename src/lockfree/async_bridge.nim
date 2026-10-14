## src/lockfree/async_bridge.nim
##
## Async Bridge Substrate for std/asyncdispatch and Chronos (-d:lockfreeChronos).
##
## Provides high-performance, non-blocking asynchronous adapters over
## foundational lock-free containers:
##   - BQueue[T] (Bounded MPMC / SPSC) -> AsyncBQueue[T]
##   - Queue[T] (Unbounded LCRQ) -> AsyncQueue[T]
##   - RendezvousChannel[T] (Synchronous CSP zero-buffer handoff) ->
##     AsyncRendezvousChannel[T]
##   - BroadcastRing[T] (Multicast 1-to-N fanout) -> AsyncBroadcastRing[T],
##     AsyncBroadcastCursor[T]
##   - TopicBus[T] (Multiplexed Pub-Sub topic router) -> AsyncTopicBus[T]
##   - ChaseLevDeque[T] (Work-stealing deque) -> AsyncChaseLevDeque[T]
##
## Core Architectural Invariants:
##   1. Fast-Path Speculative Non-Blocking Execution (zero-allocation immediate
##      Future return)
##   2. Strict SMR Epoch Pin Isolation (PinScope ∩ SuspensionPoints = ∅; pin
##      never held across await)
##   3. Bilateral CAS Arbitration & Dekker Store-Load (moSequentiallyConsistent)
##      Barrier Pairing (zero lost wakeups and zero item loss on cancellation)
##   4. Thread-Safe Cross-Thread Wakeups via AsyncSignal (dual-backend:
##      std/asyncdispatch AsyncEvent and Chronos ThreadSignalPtr)

when not compileOption("threads"):
  {.error: "lockfree/async_bridge requires --threads:on for cross-thread lock-free coordination.".}

when defined(lockfreeChronos):
  when (compiles do:
    import chronos/asyncsync
  ):
    discard

  const chronosBridgeReachable = compiles do:
    import chronos/[asyncsync, threadsync]

  when not chronosBridgeReachable:
    {.error: "lockfree/async_bridge: -d:lockfreeChronos was set but chronos is not installed.".}

when defined(lockfreeChronos) or defined(lockfreeAsyncdispatch) or compileOption("threads"):
  import std/options
  when defined(lockfreeChronos):
    import chronos/[asyncsync, threadsync]
  else:
    import std/asyncdispatch

  import ./constants
  import ./atomics
  import ./atomics/backoff
  import ./bqueue
  import ./queue
  import ./rendezvous
  import ./broadcast
  import ./deque
  import ./strategy
  import ./endpoint
  import ./endpoint_types
  import ./role_tags
  import ./exceptions

  export exceptions

  const
    moSeqCst = moSequentiallyConsistent

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

  proc incRef[T](box: ptr AsyncPayloadBox[T]) {.inline, used.} =
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

  const
    ksIdle = 0'i32
    ksRegistered = 1'i32
    ksTriggered = 2'i32

  type
    AsyncSignal* = ref object
      signaled*: Atomic[bool]
      closed*: Atomic[bool]
      kernelState*: Atomic[int32]
      eventClosed*: bool
      when defined(lockfreeChronos):
        tsig*: ThreadSignalPtr
        waiters*: seq[Future[void]]
        tsigWaitFut*: Future[void]
      else:
        event*: AsyncEvent
        waiters*: seq[Future[void]]

  proc newAsyncSignal*(): AsyncSignal =
    new result
    result.signaled.store(false, moRelaxed)
    result.closed.store(false, moRelaxed)
    result.kernelState.store(ksIdle, moRelaxed)
    result.eventClosed = false
    when defined(lockfreeChronos):
      let res = ThreadSignalPtr.new()
      if res.isOk:
        result.tsig = res.get()
      result.waiters = @[]
    else:
      result.event = newAsyncEvent()
      result.waiters = @[]

  proc fire*(sig: AsyncSignal) {.inline, gcsafe.} =
    ## Thread-safe, non-blocking signal trigger. Can be invoked from any OS
    ## thread. Triggers the underlying kernel event at most once per active
    ## registration (`ksRegistered -> ksTriggered`).
    if sig == nil or sig.closed.load(moAcquire):
      return
    sig.signaled.store(true, moSeqCst)
    threadFence(moSeqCst)
    var exp = ksRegistered
    if sig.kernelState.compareExchange(exp, ksTriggered, moSeqCst):
      when defined(lockfreeChronos):
        if sig.tsig != nil:
          discard sig.tsig.fireSync()
      else:
        sig.event.trigger()

  proc clear*(sig: AsyncSignal) {.inline, gcsafe.} =
    if sig == nil:
      return
    sig.signaled.store(false, moSeqCst)

  proc pruneFinishedWaiters*(sig: AsyncSignal) {.inline.} =
    if sig == nil:
      return
    var i = 0
    while i < sig.waiters.len:
      when defined(lockfreeChronos):
        let done = sig.waiters[i].finished()
      else:
        let done = sig.waiters[i].finished
      if done:
        sig.waiters.delete(i)
      else:
        inc i

  when defined(lockfreeChronos):
    proc wait*(sig: AsyncSignal): Future[void] {.
        async: (raw: true, raises: [CatchableError]).} =
      ## Suspends until the signal is fired. Sticky flag prevents lost wakeups.
      let fut = newFuture[void]("AsyncSignal.wait")
      if sig != nil:
        sig.pruneFinishedWaiters()
      if sig == nil or sig.closed.load(moAcquire) or
          (sig.waiters.len == 0 and sig.signaled.exchange(false, moSeqCst)):
        fut.complete()
        return fut

      proc onCancel(udata: pointer) {.gcsafe, raises: [].} =
        for i in 0 ..< sig.waiters.len:
          if sig.waiters[i] == fut:
            sig.waiters.delete(i)
            break

      fut.cancelCallback = onCancel
      sig.waiters.add(fut)

      if sig.kernelState.load(moSeqCst) == ksIdle and sig.tsig != nil:
        let tw = sig.tsig.wait()
        sig.tsigWaitFut = tw
        tw.addCallback(proc(udata: pointer) {.gcsafe, raises: [].} =
          sig.signaled.store(false, moSeqCst)
          sig.tsigWaitFut = nil
          var pending = move sig.waiters
          sig.waiters = @[]
          sig.kernelState.store(ksIdle, moSeqCst)
          threadFence(moSeqCst)
          if sig.closed.load(moAcquire):
            if not sig.eventClosed:
              sig.eventClosed = true
              if sig.tsig != nil:
                discard sig.tsig.close()
                sig.tsig = nil
          for w in pending:
            if not w.finished():
              w.complete()
        )
        sig.kernelState.store(ksRegistered, moSeqCst)

      threadFence(moSeqCst)
      if sig.signaled.load(moSeqCst) or sig.closed.load(moSeqCst):
        var exp = ksRegistered
        if sig.kernelState.compareExchange(exp, ksTriggered, moSeqCst):
          if sig.tsig != nil:
            discard sig.tsig.fireSync()
      return fut
  else:
    proc wait*(sig: AsyncSignal): Future[void] =
      ## Suspends until the signal is fired. Sticky flag prevents lost wakeups.
      if sig != nil:
        sig.pruneFinishedWaiters()
      if sig == nil or sig.closed.load(moAcquire) or
          (sig.waiters.len == 0 and sig.signaled.exchange(false, moSeqCst)):
        var fut = newFuture[void]("AsyncSignal.wait.fast")
        fut.complete()
        return fut

      var fut = newFuture[void]("AsyncSignal.wait.slow")
      sig.waiters.add(fut)

      if sig.kernelState.load(moSeqCst) == ksIdle:
        # Register addEvent on the dispatcher BEFORE publishing
        # ksRegistered so no foreign thread can call trigger() before addEvent.
        sig.event.addEvent(proc(fd: AsyncFD): bool {.gcsafe.} =
          # Defer state reset, optional close, and waiter completion
          # to callSoon (executed at the end of runOnce strictly AFTER
          # eventcb / processBasicCallbacks completes unregister(ev)).
          callSoon(proc() {.gcsafe.} =
            sig.signaled.store(false, moSeqCst)
            var pending = move sig.waiters
            sig.waiters = @[]
            sig.kernelState.store(ksIdle, moSeqCst)
            threadFence(moSeqCst)
            if sig.closed.load(moAcquire):
              if not sig.eventClosed:
                sig.eventClosed = true
                try:
                  sig.event.close()
                except CatchableError:
                  discard
            for w in pending:
              if not w.finished:
                w.complete()
          )
          return true # unregister from selector / IOCP wait handle
        )
        sig.kernelState.store(ksRegistered, moSeqCst)

      threadFence(moSeqCst)
      if sig.signaled.load(moSeqCst) or sig.closed.load(moSeqCst):
        var exp = ksRegistered
        if sig.kernelState.compareExchange(exp, ksTriggered, moSeqCst):
          sig.event.trigger()
      return fut

  proc close*(sig: AsyncSignal) =
    if sig == nil:
      return
    if not sig.closed.exchange(true, moSeqCst):
      threadFence(moSeqCst)
      when defined(lockfreeChronos):
        let ks = sig.kernelState.load(moSeqCst)
        if ks == ksIdle:
          var pending = move sig.waiters
          sig.waiters = @[]
          if not sig.eventClosed:
            sig.eventClosed = true
            if sig.tsig != nil:
              discard sig.tsig.close()
              sig.tsig = nil
          for w in pending:
            if not w.finished():
              w.complete()
        else:
          var exp = ksRegistered
          if sig.kernelState.compareExchange(exp, ksTriggered, moSeqCst):
            if sig.tsig != nil:
              discard sig.tsig.fireSync()
      else:
        let ks = sig.kernelState.load(moSeqCst)
        if ks == ksIdle:
          var pending = move sig.waiters
          sig.waiters = @[]
          if not sig.eventClosed:
            sig.eventClosed = true
            try:
              sig.event.close()
            except CatchableError:
              discard
          for w in pending:
            if not w.finished:
              w.complete()
        else:
          var exp = ksRegistered
          if sig.kernelState.compareExchange(exp, ksTriggered, moSeqCst):
            sig.event.trigger()

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
      hasWaitingConsumers* {.align: CacheLineBytes.}: Atomic[bool]
      hasWaitingProducers* {.align: CacheLineBytes.}: Atomic[bool]

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
    ## Asynchronously sends an item into the bounded queue. Suspends if full
    ## until space is available.
    var cur = move item
    while true:
      self.producerSignal.clear()
      self.hasWaitingProducers.store(true, moSeqCst)
      threadFence(moSeqCst)
      try:
        if self.queue.push(cur):
          self.hasWaitingProducers.store(false, moSeqCst)
          threadFence(moSeqCst)
          if self.hasWaitingConsumers.load(moSeqCst):
            self.consumerSignal.fire()
          return true
        await self.producerSignal.wait()
      finally:
        self.hasWaitingProducers.store(false, moSeqCst)

  proc recvAsync*[T; N: static int](
      self: AsyncBQueue[T, ccSingle, ccSingle, N, 0, 0]
  ): Future[Option[T]] {.async.} =
    ## Asynchronously awaits and receives an item from the bounded queue. SMR
    ## invariant: No pin held across await.
    while true:
      self.consumerSignal.clear()
      self.hasWaitingConsumers.store(true, moSeqCst)
      threadFence(moSeqCst)
      try:
        let v = self.queue.pop()
        if v.isSome:
          self.hasWaitingConsumers.store(false, moSeqCst)
          threadFence(moSeqCst)
          if self.hasWaitingProducers.load(moSeqCst):
            self.producerSignal.fire()
          return v
        await self.consumerSignal.wait()
      finally:
        self.hasWaitingConsumers.store(false, moSeqCst)

  proc tryPopAsync*[T; N: static int](
      self: AsyncBQueue[T, ccSingle, ccSingle, N, 0, 0]
  ): Future[Option[T]] =
    ## Speculative non-blocking try-pop. Returns immediately resolved Future.
    let v = self.queue.pop()
    if v.isSome:
      threadFence(moSeqCst)
      if self.hasWaitingProducers.load(moSeqCst):
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
      threadFence(moSeqCst)
      if self.hasWaitingConsumers.load(moSeqCst):
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
      hasWaitingConsumers* {.align: CacheLineBytes.}: Atomic[bool]

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

  proc push*[T; ST: static DeallocationStrategy, S, MaxThreads: static int](
      self: AsyncQueue[T, ccSingle, ccSingle, ST, S, MaxThreads],
      item: sink T
  ): bool =
    ## Synchronous thread-safe push with consumer wakeup. Safe to invoke from
    ## raw OS worker threads without allocating Future objects.
    var prod = self.queue.getProducerHere()
    prod.push(item)
    threadFence(moSeqCst)
    if self.hasWaitingConsumers.load(moSeqCst):
      self.consumerSignal.fire()
    return true

  proc trySend*[T; ST: static DeallocationStrategy, S, MaxThreads: static int](
      self: AsyncQueue[T, ccSingle, ccSingle, ST, S, MaxThreads],
      item: sink T
  ): bool {.inline.} =
    ## Alias for synchronous thread-safe `push`.
    self.push(item)

  proc sendAsync*[T; ST: static DeallocationStrategy, S, MaxThreads: static int](
      self: AsyncQueue[T, ccSingle, ccSingle, ST, S, MaxThreads],
      item: sink T
  ): Future[bool] =
    ## Unbounded enqueue never blocks; pushes immediately and notifies waiting
    ## consumers. Note: Must be invoked from the event-loop thread; raw OS
    ## threads should call `push` or `trySend`.
    let ok = self.push(item)
    var fut = newFuture[bool]("sendAsync")
    fut.complete(ok)
    return fut

  proc recvAsync*[T; ST: static DeallocationStrategy, S, MaxThreads: static int](
      self: AsyncQueue[T, ccSingle, ccSingle, ST, S, MaxThreads]
  ): Future[Option[T]] {.async.} =
    ## Asynchronously awaits and receives an item from the unbounded queue.
    while true:
      self.consumerSignal.clear()
      self.hasWaitingConsumers.store(true, moSeqCst)
      threadFence(moSeqCst)
      try:
        let v = self.queue.pop()
        if v.isSome:
          self.hasWaitingConsumers.store(false, moSeqCst)
          return v
        await self.consumerSignal.wait()
      finally:
        self.hasWaitingConsumers.store(false, moSeqCst)

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

    AsyncRendezvousWaiterNodeObj[T] = object
      state*: Atomic[AsyncRendezvousState]
      box*: Atomic[ptr AsyncPayloadBox[T]]
      signal*: AsyncSignal
      next*: ptr AsyncRendezvousWaiterNodeObj[T]

    AsyncRendezvousWaiterNode[T] = ptr AsyncRendezvousWaiterNodeObj[T]

    AsyncRendezvousChannel*[T] = ref object
      chan*: RendezvousChannel[T]
      waitingSenders*: AsyncRendezvousWaiterNode[T]
      waitingReceivers*: AsyncRendezvousWaiterNode[T]
      waiterLock*: Atomic[bool]

  proc allocWaiterNode[T](): AsyncRendezvousWaiterNode[T] {.inline.} =
    result = cast[AsyncRendezvousWaiterNode[T]](
      allocShared0(sizeof(AsyncRendezvousWaiterNodeObj[T]))
    )
    result.signal = newAsyncSignal()
    result.state.store(arsWaiting, moRelaxed)
    result.box.store(nil, moRelaxed)
    result.next = nil

  proc unlinkAndDestroySenderWaiter[T](
      self: AsyncRendezvousChannel[T], waiter: AsyncRendezvousWaiterNode[T]
  ) {.inline.} =
    self.waiterLock.acquireLock()
    var p: AsyncRendezvousWaiterNode[T] = nil
    var c = self.waitingSenders
    while c != nil:
      if c == waiter:
        if p == nil:
          self.waitingSenders = c.next
        else:
          p.next = c.next
        break
      p = c
      c = c.next
    self.waiterLock.releaseLock()
    waiter.signal.close()
    waiter.signal = nil
    deallocShared(waiter)

  proc unlinkAndDestroyReceiverWaiter[T](
      self: AsyncRendezvousChannel[T], waiter: AsyncRendezvousWaiterNode[T]
  ) {.inline.} =
    self.waiterLock.acquireLock()
    var p: AsyncRendezvousWaiterNode[T] = nil
    var c = self.waitingReceivers
    while c != nil:
      if c == waiter:
        if p == nil:
          self.waitingReceivers = c.next
        else:
          p.next = c.next
        break
      p = c
      c = c.next
    self.waiterLock.releaseLock()
    waiter.signal.close()
    waiter.signal = nil
    deallocShared(waiter)

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
    ## Asynchronously sends an item through the rendezvous channel. Matches an
    ## active receiver (OS thread or coroutine) or suspends until matched.
    ## Bilateral CAS arbitration guarantees zero item loss on cancellation.
    if self.chan.isClosed:
      raise newException(ChannelClosedDefect, "RendezvousChannel is closed")

    var curItem = move item
    # Fast path 1: Check if synchronous thread is parked in chan.recv()
    var corrId: uint64
    if self.chan.trySend(curItem, corrId):
      return true

    # Fast path 2: Check if async receiver is waiting
    var matched = false
    self.waiterLock.acquireLock()
    var prev: AsyncRendezvousWaiterNode[T] = nil
    var curr = self.waitingReceivers
    while curr != nil:
      var exp = arsWaiting
      if curr.state.compareExchange(exp, arsMatched, moAcquireRelease):
        if prev == nil:
          self.waitingReceivers = curr.next
        else:
          prev.next = curr.next
        let pbox = allocPayloadBox(curItem)
        curr.box.store(pbox, moRelease)
        curr.signal.fire()
        matched = true
        break
      else:
        # Cancelled or dead waiter
        if prev == nil:
          self.waitingReceivers = curr.next
        else:
          prev.next = curr.next
        curr = curr.next
    self.waiterLock.releaseLock()

    if matched:
      return true

    # Slow path: Register as waiting sender
    let waiter = allocWaiterNode[T]()
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
      let cancelled = waiter.state.compareExchange(exp, arsCancelled, moAcquireRelease)
      self.unlinkAndDestroySenderWaiter(waiter)
      if cancelled:
        decRef(pbox)
        raise e
      # Peer won CAS before or concurrently with cancel; item transferred!
      return true

    var exp = arsWaiting
    discard waiter.state.compareExchange(exp, arsCancelled, moAcquireRelease)
    let wasMatched = (exp == arsMatched)
    self.unlinkAndDestroySenderWaiter(waiter)
    if wasMatched:
      return true
    else:
      decRef(pbox)
      raise newException(ChannelClosedDefect, "Channel closed while waiting")

  proc recvAsync*[T](self: AsyncRendezvousChannel[T]): Future[Option[T]] {.async.} =
    ## Asynchronously receives an item from the rendezvous channel. Matches an
    ## active sender (OS thread or coroutine) or suspends until matched.
    if self.chan.isClosed:
      return none(T)

    # Fast path 1: Check if synchronous thread is parked in chan.send()
    var val: T
    var corrId: uint64
    if self.chan.tryRecv(val, corrId):
      return some(val)

    # Fast path 2: Check if async sender is waiting
    var matchedBox: ptr AsyncPayloadBox[T] = nil
    self.waiterLock.acquireLock()
    var prev: AsyncRendezvousWaiterNode[T] = nil
    var curr = self.waitingSenders
    while curr != nil:
      var exp = arsWaiting
      if curr.state.compareExchange(exp, arsMatched, moAcquireRelease):
        if prev == nil:
          self.waitingSenders = curr.next
        else:
          prev.next = curr.next
        matchedBox = curr.box.load(moAcquire)
        curr.signal.fire()
        break
      else:
        if prev == nil:
          self.waitingSenders = curr.next
        else:
          prev.next = curr.next
        curr = curr.next
    self.waiterLock.releaseLock()

    if matchedBox != nil:
      var res = matchedBox.val
      decRef(matchedBox)
      return some(res)

    # Slow path: Register as waiting receiver
    let waiter = allocWaiterNode[T]()

    self.waiterLock.acquireLock()
    waiter.next = self.waitingReceivers
    self.waitingReceivers = waiter
    self.waiterLock.releaseLock()

    try:
      await waiter.signal.wait()
    except CatchableError as e:
      var exp = arsWaiting
      let cancelled = waiter.state.compareExchange(exp, arsCancelled, moAcquireRelease)
      var pbox: ptr AsyncPayloadBox[T] = nil
      if not cancelled:
        self.waiterLock.acquireLock()
        pbox = waiter.box.load(moAcquire)
        self.waiterLock.releaseLock()
      self.unlinkAndDestroyReceiverWaiter(waiter)
      if cancelled:
        raise e
      var res = pbox.val
      decRef(pbox)
      return some(res)

    var exp = arsWaiting
    discard waiter.state.compareExchange(exp, arsCancelled, moAcquireRelease)
    let wasMatched = (exp == arsMatched)
    var pbox: ptr AsyncPayloadBox[T] = nil
    if wasMatched:
      self.waiterLock.acquireLock()
      pbox = waiter.box.load(moAcquire)
      self.waiterLock.releaseLock()
    self.unlinkAndDestroyReceiverWaiter(waiter)
    if wasMatched:
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

    var matchedBox: ptr AsyncPayloadBox[T] = nil
    self.waiterLock.acquireLock()
    var prev: AsyncRendezvousWaiterNode[T] = nil
    var curr = self.waitingSenders
    while curr != nil:
      var exp = arsWaiting
      if curr.state.compareExchange(exp, arsMatched, moAcquireRelease):
        if prev == nil:
          self.waitingSenders = curr.next
        else:
          prev.next = curr.next
        matchedBox = curr.box.load(moAcquire)
        curr.signal.fire()
        break
      else:
        if prev == nil:
          self.waitingSenders = curr.next
        else:
          prev.next = curr.next
        curr = curr.next
    self.waiterLock.releaseLock()

    var fut = newFuture[Option[T]]("tryPopAsync")
    if matchedBox != nil:
      var res = matchedBox.val
      decRef(matchedBox)
      fut.complete(some(res))
    else:
      fut.complete(none(T))
    return fut

  proc send*[T](self: AsyncRendezvousChannel[T], item: sink T): uint64 =
    ## Synchronous send on AsyncRendezvousChannel (e.g. from an OS worker
    ## thread). Wakes a waiting async receiver or falls back to sync
    ## RendezvousChannel.
    if self.chan.isClosed:
      raise newException(ChannelClosedDefect, "RendezvousChannel is closed")

    var curItem = move item
    var matched = false
    self.waiterLock.acquireLock()
    var prev: AsyncRendezvousWaiterNode[T] = nil
    var curr = self.waitingReceivers
    while curr != nil:
      var exp = arsWaiting
      if curr.state.compareExchange(exp, arsMatched, moAcquireRelease):
        if prev == nil:
          self.waitingReceivers = curr.next
        else:
          prev.next = curr.next
        let pbox = allocPayloadBox(curItem)
        curr.box.store(pbox, moRelease)
        curr.signal.fire()
        matched = true
        break
      else:
        if prev == nil:
          self.waitingReceivers = curr.next
        else:
          prev.next = curr.next
        curr = curr.next
    self.waiterLock.releaseLock()

    if matched:
      return 1

    result = self.chan.send(curItem)

  proc recv*[T](self: AsyncRendezvousChannel[T], outVal: var T): uint64 =
    ## Synchronous recv on AsyncRendezvousChannel (e.g. from an OS worker
    ## thread). Wakes a waiting async sender or falls back to sync
    ## RendezvousChannel.
    if self.chan.isClosed:
      raise newException(ChannelClosedDefect, "RendezvousChannel is closed")

    var matchedBox: ptr AsyncPayloadBox[T] = nil
    self.waiterLock.acquireLock()
    var prev: AsyncRendezvousWaiterNode[T] = nil
    var curr = self.waitingSenders
    while curr != nil:
      var exp = arsWaiting
      if curr.state.compareExchange(exp, arsMatched, moAcquireRelease):
        if prev == nil:
          self.waitingSenders = curr.next
        else:
          prev.next = curr.next
        matchedBox = curr.box.load(moAcquire)
        curr.signal.fire()
        break
      else:
        if prev == nil:
          self.waitingSenders = curr.next
        else:
          prev.next = curr.next
        curr = curr.next
    self.waiterLock.releaseLock()

    if matchedBox != nil:
      outVal = matchedBox.val
      decRef(matchedBox)
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
      waitingProducerCount* {.align: CacheLineBytes.}: Atomic[int32]
      waitingCursorCount* {.align: CacheLineBytes.}: Atomic[int32]
      cursorsLock* {.align: CacheLineBytes.}: Atomic[bool]
      cursors*: seq[AsyncBroadcastCursor[T]]
      producerSignal*: AsyncSignal

    AsyncBroadcastCursor*[T] = ref object
      cursor*: BroadcastCursor[T]
      ring*: AsyncBroadcastRing[T]
      signal*: AsyncSignal
      isWaiting* {.align: CacheLineBytes.}: Atomic[bool]
      closed*: Atomic[bool]

  proc newAsyncBroadcastRing*[T](
      capacity: int = DefaultRingCapacity,
      overflowMode: OverflowMode = omDropOldest,
      maxReaders: int = DefaultMaxReaders
  ): AsyncBroadcastRing[T] =
    new result
    result.ring = initBroadcastRing[T](capacity, overflowMode, maxReaders)
    result.waitingProducerCount.store(0, moRelaxed)
    result.waitingCursorCount.store(0, moRelaxed)
    result.cursorsLock.store(false, moRelaxed)
    result.cursors = @[]
    result.producerSignal = newAsyncSignal()

  proc toAsync*[T](ring: sink BroadcastRing[T]): AsyncBroadcastRing[T] =
    new result
    result.ring = ring
    result.waitingProducerCount.store(0, moRelaxed)
    result.waitingCursorCount.store(0, moRelaxed)
    result.cursorsLock.store(false, moRelaxed)
    result.cursors = @[]
    result.producerSignal = newAsyncSignal()

  proc notifyCursors*[T](self: AsyncBroadcastRing[T]) {.inline, gcsafe.} =
    if self == nil:
      return
    self.cursorsLock.acquireLock()
    for i in 0 ..< self.cursors.len:
      if self.cursors[i] != nil and self.cursors[i].isWaiting.load(moSeqCst):
        self.cursors[i].signal.fire()
    self.cursorsLock.releaseLock()

  proc notifyProducers*[T](self: AsyncBroadcastRing[T]) {.inline, gcsafe.} =
    if self == nil or self.producerSignal == nil:
      return
    self.producerSignal.fire()

  proc close*[T](self: AsyncBroadcastRing[T]) =
    if self == nil:
      return
    if self.producerSignal != nil:
      self.producerSignal.close()

  proc subscribe*[T](
      self: AsyncBroadcastRing[T],
      origin: SubscriptionOrigin = soFromLatest
  ): AsyncBroadcastCursor[T] =
    new result
    result.ring = self
    result.cursor = self.ring.subscribe(origin)
    result.signal = newAsyncSignal()
    result.isWaiting.store(false, moRelaxed)
    result.closed.store(false, moRelaxed)
    self.cursorsLock.acquireLock()
    self.cursors.add(result)
    self.cursorsLock.releaseLock()

  proc unsubscribe*[T](self: AsyncBroadcastCursor[T]) =
    ## Deregisters the async cursor, removes it from the ring's active cursor
    ## list, releases its slot in the underlying BroadcastRing cursor table,
    ## closes its dedicated AsyncSignal, and wakes any stalled omBackoff
    ## producers.
    if self == nil:
      return
    if not self.closed.exchange(true, moAcquireRelease):
      if self.ring != nil:
        if self.isWaiting.exchange(false, moSeqCst):
          discard self.ring.waitingCursorCount.fetchSub(1, moSeqCst)
        self.ring.cursorsLock.acquireLock()
        for i in 0 ..< self.ring.cursors.len:
          if self.ring.cursors[i] == self:
            self.ring.cursors.delete(i)
            break
        self.ring.cursorsLock.releaseLock()

      self.cursor.unsubscribe()
      self.signal.close()

      if self.ring != nil:
        threadFence(moSeqCst)
        if self.ring.waitingProducerCount.load(moSeqCst) > 0:
          self.ring.notifyProducers()

  proc close*[T](self: AsyncBroadcastCursor[T]) {.inline.} =
    self.unsubscribe()

  proc isClosed*[T](self: AsyncBroadcastCursor[T]): bool {.inline.} =
    self == nil or self.closed.load(moAcquire) or self.cursor.isNil

  proc lag*[T](self: AsyncBroadcastCursor[T]): uint64 {.inline.} =
    if self == nil: 0'u64 else: self.cursor.lag

  proc subscriberCount*[T](self: AsyncBroadcastRing[T]): int {.inline.} =
    if self == nil: 0 else: self.ring.subscriberCount

  proc capacity*[T](self: AsyncBroadcastRing[T]): int {.inline.} =
    if self == nil: 0 else: self.ring.capacity

  proc len*[T](self: AsyncBroadcastRing[T]): int {.inline.} =
    if self == nil: 0 else: self.ring.len

  proc publish*[T](self: AsyncBroadcastRing[T], item: sink T) =
    self.ring.publish(item)
    threadFence(moSeqCst)
    if self.waitingCursorCount.load(moSeqCst) > 0:
      self.notifyCursors()

  proc tryPublish*[T](self: AsyncBroadcastRing[T], item: sink T): bool =
    result = self.ring.tryPublish(item)
    if result:
      threadFence(moSeqCst)
      if self.waitingCursorCount.load(moSeqCst) > 0:
        self.notifyCursors()

  proc sendAsync*[T](self: AsyncBroadcastRing[T], item: sink T): Future[bool] {.async.} =
    ## Asynchronously publishes an item to the broadcast ring. Under
    ## `omDropOldest`, publishes immediately without suspending. Under
    ## `omBackoff`, suspends when the ring is full until the slowest active
    ## cursor advances or unsubscribes.
    var cur = move item
    if self.ring.core.overflowMode == omDropOldest:
      self.publish(cur)
      return true

    while true:
      if self.tryPublish(cur):
        return true

      self.producerSignal.pruneFinishedWaiters()
      if self.producerSignal.waiters.len == 0:
        self.producerSignal.clear()
      discard self.waitingProducerCount.fetchAdd(1, moSeqCst)
      threadFence(moSeqCst)

      try:
        if self.tryPublish(cur):
          if self.waitingProducerCount.load(moSeqCst) > 1:
            self.notifyProducers()
          return true
        await self.producerSignal.wait()
      finally:
        discard self.waitingProducerCount.fetchSub(1, moSeqCst)
        self.producerSignal.pruneFinishedWaiters()

  proc sendAsync*[T](ring: BroadcastRing[T], item: sink T): Future[bool] =
    ring.publish(item)
    var fut = newFuture[bool]("sendAsync")
    fut.complete(true)
    return fut

  proc isReadable*[T](self: AsyncBroadcastCursor[T]): bool {.inline.} =
    ## Returns true if the cursor currently has a published slot ready to be
    ## polled (either `prSuccess` or `prLagged`) without advancing `readSeq`.
    if self == nil or self.closed.load(moAcquire) or self.cursor.isNil:
      return false
    let core = self.ring.ring.core
    let targetSeq = self.cursor.readSeq
    let idx = targetSeq and core.mask
    core.slots[idx].seq.load(moSeqCst) >= targetSeq + 1

  proc waitReadable*[T](self: AsyncBroadcastCursor[T]): Future[bool] {.async.} =
    ## Suspends until at least one message is readable at this cursor without
    ## consuming the message. Returns `false` if the cursor is unsubscribed or
    ## closed.
    while true:
      if self == nil or self.closed.load(moAcquire) or self.cursor.isNil:
        return false
      if self.isReadable():
        return true

      self.signal.clear()
      if not self.isWaiting.exchange(true, moSeqCst):
        discard self.ring.waitingCursorCount.fetchAdd(1, moSeqCst)
      threadFence(moSeqCst)

      try:
        if self.closed.load(moAcquire) or self.cursor.isNil:
          return false
        if self.isReadable():
          return true
        await self.signal.wait()
      finally:
        if self.isWaiting.exchange(false, moSeqCst):
          discard self.ring.waitingCursorCount.fetchSub(1, moSeqCst)

  proc pollAsync*[T](self: AsyncBroadcastCursor[T]): Future[PollResult[T]] {.async.} =
    ## Asynchronously polls the next event on this cursor, returning `prSuccess`
    ## with the item or `prLagged(skippedCount)` if the subscriber fell behind
    ## the ring overwrite horizon under `omDropOldest`. Returns `prEmpty` only
    ## if the cursor is closed/unsubscribed.
    while true:
      if self == nil or self.closed.load(moAcquire) or self.cursor.isNil:
        return PollResult[T](kind: prEmpty)

      let r1 = self.cursor.poll()
      if r1.kind != prEmpty:
        threadFence(moSeqCst)
        if self.ring != nil and self.ring.waitingProducerCount.load(moSeqCst) > 0:
          self.ring.notifyProducers()
        return r1

      self.signal.clear()
      if not self.isWaiting.exchange(true, moSeqCst):
        discard self.ring.waitingCursorCount.fetchAdd(1, moSeqCst)
      threadFence(moSeqCst)

      try:
        let r2 = self.cursor.poll()
        if r2.kind != prEmpty:
          if self.isWaiting.exchange(false, moSeqCst):
            discard self.ring.waitingCursorCount.fetchSub(1, moSeqCst)
          threadFence(moSeqCst)
          if self.ring != nil and self.ring.waitingProducerCount.load(moSeqCst) > 0:
            self.ring.notifyProducers()
          return r2

        if self.closed.load(moAcquire) or self.cursor.isNil:
          return PollResult[T](kind: prEmpty)

        await self.signal.wait()
      finally:
        if self.isWaiting.exchange(false, moSeqCst):
          discard self.ring.waitingCursorCount.fetchSub(1, moSeqCst)

  proc recvAsync*[T](self: AsyncBroadcastCursor[T]): Future[Option[T]] {.async.} =
    ## Asynchronously awaits the next available broadcast message on this
    ## cursor. If the cursor lags under `omDropOldest`, it automatically snaps
    ## forward to the newest available ring horizon and reads without spurious
    ## suspension. Returns `none(T)` if the cursor is unsubscribed/closed.
    while true:
      if self == nil or self.closed.load(moAcquire) or self.cursor.isNil:
        return none(T)
      let res = await self.pollAsync()
      case res.kind
      of prSuccess:
        return some(res.val)
      of prLagged:
        continue
      of prEmpty:
        if self.closed.load(moAcquire) or self.cursor.isNil:
          return none(T)

  proc tryPopAsync*[T](self: AsyncBroadcastCursor[T]): Future[Option[T]] =
    var fut = newFuture[Option[T]]("tryPopAsync")
    if self == nil or self.closed.load(moAcquire) or self.cursor.isNil:
      fut.complete(none(T))
      return fut
    while true:
      let res = self.cursor.poll()
      case res.kind
      of prSuccess:
        threadFence(moSeqCst)
        if self.ring != nil and self.ring.waitingProducerCount.load(moSeqCst) > 0:
          self.ring.notifyProducers()
        fut.complete(some(res.val))
        return fut
      of prLagged:
        threadFence(moSeqCst)
        if self.ring != nil and self.ring.waitingProducerCount.load(moSeqCst) > 0:
          self.ring.notifyProducers()
        continue
      of prEmpty:
        fut.complete(none(T))
        return fut

  proc tryPopAsync*[T](self: var BroadcastCursor[T]): Future[Option[T]] =
    var fut = newFuture[Option[T]]("tryPopAsync")
    while true:
      let res = self.poll()
      case res.kind
      of prSuccess:
        fut.complete(some(res.val))
        return fut
      of prLagged:
        continue
      of prEmpty:
        fut.complete(none(T))
        return fut

  # ---------------------------------------------------------------------------
  # 5. Multiplexed Topic Bus Adapter: AsyncTopicBus[T]
  # ---------------------------------------------------------------------------

  type
    AsyncTopicEntry[T] = object
      topic*: string
      ring*: AsyncBroadcastRing[T]

    AsyncTopicBus*[T] = ref object
      bus*: TopicBus[T]
      config*: TopicBusConfig
      lock* {.align: CacheLineBytes.}: Atomic[bool]
      entries*: seq[AsyncTopicEntry[T]]

  proc newAsyncTopicBus*[T](
      config: TopicBusConfig = TopicBusConfig(
        defaultRingCapacity: DefaultRingCapacity,
        defaultOverflowMode: omDropOldest,
        defaultMaxReaders: DefaultMaxReaders
      )
  ): AsyncTopicBus[T] =
    new result
    result.bus = initTopicBus[T](config)
    result.config = config
    result.lock.store(false, moRelaxed)
    result.entries = @[]

  proc toAsync*[T](bus: sink TopicBus[T]): AsyncTopicBus[T] =
    new result
    result.bus = bus
    result.config =
      if result.bus.core != nil:
        result.bus.core.config
      else:
        TopicBusConfig(
          defaultRingCapacity: DefaultRingCapacity,
          defaultOverflowMode: omDropOldest,
          defaultMaxReaders: DefaultMaxReaders
        )
    result.lock.store(false, moRelaxed)
    result.entries = @[]

  proc getOrCreateTopicRing*[T](self: AsyncTopicBus[T], topic: string): AsyncBroadcastRing[T] =
    self.lock.acquireLock()
    try:
      for i in 0 ..< self.entries.len:
        if self.entries[i].topic == topic:
          return self.entries[i].ring

      # Bind to the underlying TopicBus[T]'s BroadcastRing[T] for this topic
      var tempCursor = self.bus.subscribe(topic, soFromLatest)
      let syncRing = tempCursor.ring
      tempCursor.unsubscribe()

      let asyncRing = toAsync(syncRing)
      self.entries.add(AsyncTopicEntry[T](topic: topic, ring: asyncRing))
      return asyncRing
    finally:
      self.lock.releaseLock()

  proc subscribe*[T](
      self: AsyncTopicBus[T],
      topic: string,
      origin: SubscriptionOrigin = soFromLatest
  ): AsyncBroadcastCursor[T] =
    let r = self.getOrCreateTopicRing(topic)
    r.subscribe(origin)

  proc publish*[T](self: AsyncTopicBus[T], topic: string, item: sink T) =
    let r = self.getOrCreateTopicRing(topic)
    r.publish(item)

  proc tryPublish*[T](self: AsyncTopicBus[T], topic: string, item: sink T): bool =
    let r = self.getOrCreateTopicRing(topic)
    r.tryPublish(item)

  proc sendAsync*[T](self: AsyncTopicBus[T], topic: string, item: sink T): Future[bool] =
    let r = self.getOrCreateTopicRing(topic)
    r.sendAsync(item)

  proc topicCount*[T](self: AsyncTopicBus[T]): int {.inline.} =
    if self == nil: 0 else: self.bus.topicCount

  proc hasTopic*[T](self: AsyncTopicBus[T], topic: string): bool {.inline.} =
    if self == nil: false else: self.bus.hasTopic(topic)

  # ---------------------------------------------------------------------------
  # 6. Work-Stealing Deque Adapter: AsyncChaseLevDeque[T]
  # ---------------------------------------------------------------------------

  type
    AsyncChaseLevDeque*[T] = ref object
      deque*: ChaseLevDeque[T]
      waitingThieves* {.align: CacheLineBytes.}: Atomic[int32]
      thiefSignal*: AsyncSignal
      closed*: Atomic[bool]

    AsyncDeque*[T] = AsyncChaseLevDeque[T]
    AsyncConcurrentDeque*[T] = AsyncChaseLevDeque[T]

  proc newAsyncChaseLevDeque*[T](initialCapacity: int = 64): AsyncChaseLevDeque[T] =
    new result
    result.deque = initChaseLevDeque[T](initialCapacity)
    result.waitingThieves.store(0, moRelaxed)
    result.thiefSignal = newAsyncSignal()
    result.closed.store(false, moRelaxed)

  proc newAsyncDeque*[T](initialCapacity: int = 64): AsyncDeque[T] {.inline.} =
    newAsyncChaseLevDeque[T](initialCapacity)

  proc toAsync*[T](d: sink ChaseLevDeque[T]): AsyncChaseLevDeque[T] =
    new result
    result.deque = d
    result.waitingThieves.store(0, moRelaxed)
    result.thiefSignal = newAsyncSignal()
    result.closed.store(false, moRelaxed)

  proc notifyThieves*[T](self: AsyncChaseLevDeque[T]) {.inline, gcsafe.} =
    if self == nil or self.thiefSignal == nil:
      return
    self.thiefSignal.fire()

  proc close*[T](self: AsyncChaseLevDeque[T]) =
    if self == nil:
      return
    if not self.closed.exchange(true, moAcquireRelease):
      threadFence(moSeqCst)
      if self.thiefSignal != nil:
        self.thiefSignal.close()

  proc isClosed*[T](self: AsyncChaseLevDeque[T]): bool {.inline.} =
    self == nil or self.closed.load(moAcquire)

  proc len*[T](self: AsyncChaseLevDeque[T]): int {.inline.} =
    if self == nil: 0 else: self.deque.len

  proc isEmpty*[T](self: AsyncChaseLevDeque[T]): bool {.inline.} =
    if self == nil: true else: self.deque.isEmpty

  proc capacity*[T](self: AsyncChaseLevDeque[T]): int {.inline.} =
    if self == nil: 0 else: self.deque.capacity

  proc pushBottom*[T](self: AsyncChaseLevDeque[T], item: sink T) =
    ## Pushes an item to the bottom of the work-stealing deque (single
    ## owner-worker thread only) and wakes any parked async thieves under a
    ## Dekker `moSequentiallyConsistent` Store-Load barrier.
    self.deque.pushBottom(item)
    threadFence(moSeqCst)
    if self.waitingThieves.load(moSeqCst) > 0:
      self.notifyThieves()

  proc sendAsync*[T](self: AsyncChaseLevDeque[T], item: sink T): Future[bool] =
    ## Owner-worker non-blocking bottom push returning an immediately completed
    ## Future.
    self.pushBottom(item)
    var fut = newFuture[bool]("sendAsync")
    fut.complete(true)
    return fut

  proc popBottom*[T](self: AsyncChaseLevDeque[T]): Option[T] {.inline.} =
    ## Pops an item from the bottom of the deque (LIFO order, single
    ## owner-worker thread only).
    self.deque.popBottom()

  proc tryPopBottom*[T](self: AsyncChaseLevDeque[T], item: var T): bool {.inline.} =
    self.deque.tryPopBottom(item)

  proc steal*[T](self: AsyncChaseLevDeque[T]): Option[T] {.inline.} =
    ## Synchronous non-blocking FIFO steal from the top of the deque.
    self.deque.steal()

  proc stealBatch*[T](
      self: AsyncChaseLevDeque[T], dest: var openArray[T], maxItems: int = -1
  ): int {.inline.} =
    self.deque.stealBatch(dest, maxItems)

  proc stealBatch*[T](self: AsyncChaseLevDeque[T], maxItems: int = -1): seq[T] {.inline.} =
    self.deque.stealBatch(maxItems)

  proc tryStealAsync*[T](self: AsyncChaseLevDeque[T]): Future[Option[T]] =
    ## Speculative non-blocking FIFO steal from the top of the deque.
    let v = self.deque.steal()
    var fut = newFuture[Option[T]]("tryStealAsync")
    fut.complete(v)
    return fut

  proc tryPopAsync*[T](self: AsyncChaseLevDeque[T]): Future[Option[T]] {.inline.} =
    self.tryStealAsync()

  proc tryStealAsync*[T](self: var ChaseLevDeque[T]): Future[Option[T]] =
    let v = self.steal()
    var fut = newFuture[Option[T]]("tryStealAsync")
    fut.complete(v)
    return fut

  proc stealAsync*[T](self: AsyncChaseLevDeque[T]): Future[Option[T]] {.async.} =
    ## Asynchronously steals an item from the top of the deque (FIFO order).
    ## Suspends without busy-spinning when the deque is empty, using a Dekker
    ## `moSequentiallyConsistent` barrier with `pushBottom` so zero wakeups can
    ## be lost. Returns `none(T)` only if the deque is closed and empty.
    while true:
      while not self.deque.isEmpty:
        let v1 = self.deque.steal()
        if v1.isSome:
          if not self.deque.isEmpty and self.waitingThieves.load(moSeqCst) > 0:
            self.notifyThieves()
          return v1
        cpuPause()

      if self.closed.load(moAcquire):
        return self.deque.steal()

      self.thiefSignal.pruneFinishedWaiters()
      if self.thiefSignal.waiters.len == 0:
        self.thiefSignal.clear()
      discard self.waitingThieves.fetchAdd(1, moSeqCst)
      threadFence(moSeqCst)

      try:
        while not self.deque.isEmpty:
          let v2 = self.deque.steal()
          if v2.isSome:
            if not self.deque.isEmpty and self.waitingThieves.load(moSeqCst) > 1:
              self.notifyThieves()
            return v2
          cpuPause()

        if self.closed.load(moAcquire):
          return self.deque.steal()

        await self.thiefSignal.wait()
      finally:
        discard self.waitingThieves.fetchSub(1, moSeqCst)
        self.thiefSignal.pruneFinishedWaiters()

  proc recvAsync*[T](self: AsyncChaseLevDeque[T]): Future[Option[T]] {.inline.} =
    self.stealAsync()

  proc stealBatchAsync*[T](
      self: AsyncChaseLevDeque[T], maxItems: int = -1
  ): Future[seq[T]] {.async.} =
    ## Asynchronously steals a batch of items from the top of the deque (FIFO
    ## order). Suspends when empty and wakes on `pushBottom`. If items remain
    ## after the batch steal, cascades wakeup to any remaining parked thieves.
    while true:
      while not self.deque.isEmpty:
        let b1 = self.deque.stealBatch(maxItems)
        if b1.len > 0:
          if not self.deque.isEmpty and self.waitingThieves.load(moSeqCst) > 0:
            self.notifyThieves()
          return b1
        cpuPause()

      if self.closed.load(moAcquire):
        return self.deque.stealBatch(maxItems)

      self.thiefSignal.pruneFinishedWaiters()
      if self.thiefSignal.waiters.len == 0:
        self.thiefSignal.clear()
      discard self.waitingThieves.fetchAdd(1, moSeqCst)
      threadFence(moSeqCst)

      try:
        while not self.deque.isEmpty:
          let b2 = self.deque.stealBatch(maxItems)
          if b2.len > 0:
            if not self.deque.isEmpty and self.waitingThieves.load(moSeqCst) > 1:
              self.notifyThieves()
            return b2
          cpuPause()

        if self.closed.load(moAcquire):
          return self.deque.stealBatch(maxItems)

        await self.thiefSignal.wait()
      finally:
        discard self.waitingThieves.fetchSub(1, moSeqCst)
        self.thiefSignal.pruneFinishedWaiters()
