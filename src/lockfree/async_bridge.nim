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
    {.
      error:
        "lockfree/async_bridge requires the `chronos` package when compiled with " &
        "`-d:lockfreeChronos`, but `chronos` could not be resolved on the search path. " &
        "Install it cleanly in your project environment with: " &
        "`nimble install \"chronos >= 4.0.0, < 5.0.0\"` (see docs/api/chronos.md)."
    .}

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
  import ./ctrie
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
  # Polyglot AsyncSignal: Thread-Safe Cross-Thread Reactor Wakeup
  # ---------------------------------------------------------------------------

  const
    ksIdle = 0'i32
    ksRegistered = 1'i32
    ksTriggered = 2'i32

  type
    AsyncSignalWaiterNodeObj = object
      fut*: Future[void]
      next*: ptr AsyncSignalWaiterNodeObj

    AsyncSignalWaiterNode = ptr AsyncSignalWaiterNodeObj

    AsyncSignal* = ref object
      signaled*: Atomic[bool]
      closed*: Atomic[bool]
      kernelState*: Atomic[int32]
      eventClosed*: Atomic[bool]
      waitersHead*: Atomic[AsyncSignalWaiterNode]
      when defined(lockfreeChronos):
        tsig*: ThreadSignalPtr
        tsigWaitFut*: Future[void]
      else:
        event*: AsyncEvent

  proc `=destroy`*(sig: var typeof(AsyncSignal()[])) =
    sig.closed.store(true, moSeqCst)
    when defined(lockfreeChronos):
      if not sig.eventClosed.exchange(true, moSeqCst):
        if sig.tsig != nil:
          discard sig.tsig.close()
          sig.tsig = nil
    else:
      if not sig.eventClosed.exchange(true, moSeqCst):
        if pointer(sig.event) != nil:
          try:
            sig.event.close()
          except CatchableError:
            discard
    var curr = sig.waitersHead.exchange(nil, moSeqCst)
    while curr != nil:
      let nxt = curr.next
      GC_unref(curr.fut)
      deallocShared(curr)
      curr = nxt

  proc newAsyncSignal*(): AsyncSignal =
    new result
    result.signaled.store(false, moRelaxed)
    result.closed.store(false, moRelaxed)
    result.kernelState.store(ksIdle, moRelaxed)
    result.eventClosed.store(false, moRelaxed)
    result.waitersHead.store(nil, moRelaxed)
    when defined(lockfreeChronos):
      let res = ThreadSignalPtr.new()
      if res.isOk:
        result.tsig = res.get()
    else:
      result.event = newAsyncEvent()

  proc pushWaiter(sig: AsyncSignal, fut: Future[void]) {.inline.} =
    GC_ref(fut)
    let node = cast[AsyncSignalWaiterNode](
      allocShared0(sizeof(AsyncSignalWaiterNodeObj))
    )
    node.fut = fut
    while true:
      var cur = sig.waitersHead.load(moAcquire)
      node.next = cur
      if sig.waitersHead.compareExchange(cur, node, moSeqCst):
        break

  proc popAllWaiters(sig: AsyncSignal): seq[Future[void]] =
    if sig == nil:
      return @[]
    var curr = sig.waitersHead.exchange(nil, moSeqCst)
    var rev: AsyncSignalWaiterNode = nil
    while curr != nil:
      let nxt = curr.next
      curr.next = rev
      rev = curr
      curr = nxt
    while rev != nil:
      let nxt = rev.next
      let f = rev.fut
      GC_unref(f)
      deallocShared(rev)
      result.add(f)
      rev = nxt

  proc filterWaiters(sig: AsyncSignal, removeTarget: Future[void] = nil) =
    if sig == nil:
      return
    var curr = sig.waitersHead.exchange(nil, moSeqCst)
    if curr == nil:
      return
    var rev: AsyncSignalWaiterNode = nil
    while curr != nil:
      let nxt = curr.next
      curr.next = rev
      rev = curr
      curr = nxt
    while rev != nil:
      let nxt = rev.next
      let f = rev.fut
      when defined(lockfreeChronos):
        let done = f.finished()
      else:
        let done = f.finished
      if done or (removeTarget != nil and f == removeTarget):
        GC_unref(f)
        deallocShared(rev)
      else:
        while true:
          var h = sig.waitersHead.load(moAcquire)
          rev.next = h
          if sig.waitersHead.compareExchange(h, rev, moSeqCst):
            break
      rev = nxt

  proc pruneFinishedWaiters*(sig: AsyncSignal) {.inline.} =
    filterWaiters(sig, nil)

  proc hasWaiters*(sig: AsyncSignal): bool {.inline.} =
    sig != nil and sig.waitersHead.load(moSeqCst) != nil

  proc waiters*(sig: AsyncSignal): seq[Future[void]] {.inline, raises: [].} =
    ## Snapshot of currently parked waiter futures in FIFO registration order.
    if sig == nil:
      return @[]
    var cur = sig.waitersHead.load(moSeqCst)
    var tmp: seq[Future[void]] = @[]
    while cur != nil:
      tmp.add(cur.fut)
      cur = cur.next
    for i in countdown(tmp.len - 1, 0):
      result.add(tmp[i])

  proc fire*(sig: AsyncSignal) {.inline, gcsafe, raises: [].} =
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
        try:
          sig.event.trigger()
        except CatchableError:
          discard

  proc clear*(sig: AsyncSignal) {.inline, gcsafe.} =
    if sig == nil:
      return
    sig.signaled.store(false, moSeqCst)

  when defined(lockfreeChronos):
    proc wait*(sig: AsyncSignal): Future[void] {.
        async: (raw: true, raises: [CatchableError]).} =
      ## Suspends until the signal is fired. Sticky flag prevents lost wakeups.
      let fut = newFuture[void]("AsyncSignal.wait")
      if sig != nil:
        sig.pruneFinishedWaiters()
      if sig == nil or sig.closed.load(moAcquire) or
          (not sig.hasWaiters() and sig.signaled.exchange(false, moSeqCst)):
        fut.complete()
        return fut

      proc onCancel(udata: pointer) {.gcsafe, raises: [].} =
        filterWaiters(sig, fut)

      fut.cancelCallback = onCancel
      sig.pushWaiter(fut)

      if sig.kernelState.load(moSeqCst) == ksIdle and sig.tsig != nil:
        let tw = sig.tsig.wait()
        sig.tsigWaitFut = tw
        tw.addCallback(proc(udata: pointer) {.gcsafe, raises: [].} =
          sig.signaled.store(false, moSeqCst)
          sig.tsigWaitFut = nil
          var pending = sig.popAllWaiters()
          sig.kernelState.store(ksIdle, moSeqCst)
          threadFence(moSeqCst)
          if sig.closed.load(moAcquire):
            if not sig.eventClosed.exchange(true, moSeqCst):
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
          (not sig.hasWaiters() and sig.signaled.exchange(false, moSeqCst)):
        var fut = newFuture[void]("AsyncSignal.wait.fast")
        fut.complete()
        return fut

      var fut = newFuture[void]("AsyncSignal.wait.slow")
      sig.pushWaiter(fut)

      if sig.kernelState.load(moSeqCst) == ksIdle:
        # Register addEvent on the dispatcher BEFORE publishing
        # ksRegistered so no foreign thread can call trigger() before addEvent.
        sig.event.addEvent(proc(fd: AsyncFD): bool {.gcsafe.} =
          # Defer state reset, optional close, and waiter completion
          # to callSoon (executed at the end of runOnce strictly AFTER
          # eventcb / processBasicCallbacks completes unregister(ev)).
          callSoon(proc() {.gcsafe.} =
            sig.signaled.store(false, moSeqCst)
            var pending = sig.popAllWaiters()
            sig.kernelState.store(ksIdle, moSeqCst)
            threadFence(moSeqCst)
            if sig.closed.load(moAcquire):
              if not sig.eventClosed.exchange(true, moSeqCst):
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
          var pending = sig.popAllWaiters()
          if not sig.eventClosed.exchange(true, moSeqCst):
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
          var pending = sig.popAllWaiters()
          if not sig.eventClosed.exchange(true, moSeqCst):
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

  template event*[T; ccProd, ccCons: static PinScopeCardinality; N, P, C: static int](
      self: AsyncBQueue[T, ccProd, ccCons, N, P, C]
  ): AsyncSignal =
    self.consumerSignal

  template asyncEvent*[T; ccProd, ccCons: static PinScopeCardinality; N, P, C: static int](
      self: AsyncBQueue[T, ccProd, ccCons, N, P, C]
  ): AsyncSignal =
    self.consumerSignal

  proc close*[T; ccProd, ccCons: static PinScopeCardinality; N, P, C: static int](
      self: AsyncBQueue[T, ccProd, ccCons, N, P, C]
  ) =
    if self != nil:
      self.consumerSignal.close()
      self.producerSignal.close()

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

  template event*[
      T;
      ccProd, ccCons: static PinScopeCardinality,
      ST: static DeallocationStrategy,
      S, MaxThreads: static int,
  ](
      self: AsyncQueue[T, ccProd, ccCons, ST, S, MaxThreads]
  ): AsyncSignal =
    self.consumerSignal

  template asyncEvent*[
      T;
      ccProd, ccCons: static PinScopeCardinality,
      ST: static DeallocationStrategy,
      S, MaxThreads: static int,
  ](
      self: AsyncQueue[T, ccProd, ccCons, ST, S, MaxThreads]
  ): AsyncSignal =
    self.consumerSignal

  proc close*[
      T;
      ccProd, ccCons: static PinScopeCardinality,
      ST: static DeallocationStrategy,
      S, MaxThreads: static int,
  ](
      self: AsyncQueue[T, ccProd, ccCons, ST, S, MaxThreads]
  ) =
    if self != nil:
      self.consumerSignal.close()

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
    AsyncRendezvousChannel*[T] = ref object
      chan*: RendezvousChannel[T]
      senderSignal*: AsyncSignal
      receiverSignal*: AsyncSignal

  proc asyncSignalWakeProc(arg: pointer) {.nimcall, gcsafe, raises: [].} =
    if arg != nil:
      let sig = cast[AsyncSignal](arg)
      sig.fire()
      GC_unref(sig)

  proc newAsyncRendezvousChannel*[T](): AsyncRendezvousChannel[T] =
    new result
    result.chan = initRendezvousChannel[T]()
    result.senderSignal = newAsyncSignal()
    result.receiverSignal = newAsyncSignal()

  proc toAsync*[T](chan: RendezvousChannel[T]): AsyncRendezvousChannel[T] =
    new result
    result.chan = chan
    result.senderSignal = newAsyncSignal()
    result.receiverSignal = newAsyncSignal()

  proc isClosed*[T](self: AsyncRendezvousChannel[T]): bool {.inline.} =
    self.chan.isClosed

  proc close*[T](self: AsyncRendezvousChannel[T]) =
    self.chan.close()
    if self.senderSignal != nil:
      self.senderSignal.close()
    if self.receiverSignal != nil:
      self.receiverSignal.close()

  proc sendAsync*[T](self: AsyncRendezvousChannel[T], item: sink T): Future[bool] {.async.} =
    ## Asynchronously sends an item through the rendezvous channel. Delegates
    ## directly to `RendezvousChannel[T]`'s lock-free Scherer-Scott dual queue.
    ## Bilateral CAS arbitration guarantees zero item loss on cancellation.
    if self.chan.isClosed:
      raise newException(ChannelClosedDefect, "RendezvousChannel is closed")

    var curItem = move item
    var corrId: uint64 = 0
    if self.chan.trySend(curItem, corrId):
      return true

    self.senderSignal.pruneFinishedWaiters()
    let sig = self.senderSignal
    GC_ref(sig)
    let waiter = self.chan.enqueueAsyncSender(
      curItem, asyncSignalWakeProc, cast[pointer](sig), corrId
    )
    if waiter == nil:
      GC_unref(sig)
      if corrId > 0:
        return true
      raise newException(ChannelClosedDefect, "RendezvousChannel is closed")

    try:
      while waiter.currentState(moSeqCst) == rsWaiting and not self.chan.isClosed:
        await sig.wait()
    except CatchableError as e:
      var leftover: pointer = nil
      let transferred = self.chan.finishAsyncSender(waiter, leftover)
      if leftover != nil:
        GC_unref(cast[AsyncSignal](leftover))
      sig.pruneFinishedWaiters()
      if transferred:
        return true
      raise e

    var leftover: pointer = nil
    let transferred = self.chan.finishAsyncSender(waiter, leftover)
    if leftover != nil:
      GC_unref(cast[AsyncSignal](leftover))
    sig.pruneFinishedWaiters()
    if transferred:
      return true
    raise newException(ChannelClosedDefect, "Channel closed while waiting")

  proc recvAsync*[T](self: AsyncRendezvousChannel[T]): Future[Option[T]] {.async.} =
    ## Asynchronously receives an item from the rendezvous channel. Delegates
    ## directly to `RendezvousChannel[T]`'s lock-free Scherer-Scott dual queue.
    if self.chan.isClosed:
      return none(T)

    var val: T
    var corrId: uint64 = 0
    if self.chan.tryRecv(val, corrId):
      return some(val)

    self.receiverSignal.pruneFinishedWaiters()
    let sig = self.receiverSignal
    GC_ref(sig)
    let waiter = self.chan.enqueueAsyncReceiver(
      asyncSignalWakeProc, cast[pointer](sig), val, corrId
    )
    if waiter == nil:
      GC_unref(sig)
      if corrId > 0:
        return some(val)
      return none(T)

    try:
      while waiter.currentState(moSeqCst) == rsWaiting and not self.chan.isClosed:
        await sig.wait()
    except CatchableError as e:
      var leftover: pointer = nil
      let matched = self.chan.finishAsyncReceiver(waiter, val, corrId, leftover)
      if leftover != nil:
        GC_unref(cast[AsyncSignal](leftover))
      sig.pruneFinishedWaiters()
      if matched:
        return some(val)
      raise e

    var leftover: pointer = nil
    let matched = self.chan.finishAsyncReceiver(waiter, val, corrId, leftover)
    if leftover != nil:
      GC_unref(cast[AsyncSignal](leftover))
    sig.pruneFinishedWaiters()
    if matched:
      return some(val)
    return none(T)

  proc tryPopAsync*[T](self: AsyncRendezvousChannel[T]): Future[Option[T]] =
    ## Speculative non-blocking try-recv delegated to `RendezvousChannel[T]`.
    var val: T
    var corrId: uint64
    var fut = newFuture[Option[T]]("tryPopAsync")
    if self.chan.tryRecv(val, corrId):
      fut.complete(some(val))
    else:
      fut.complete(none(T))
    return fut

  proc send*[T](self: AsyncRendezvousChannel[T], item: sink T): uint64 {.inline.} =
    ## Synchronous send on AsyncRendezvousChannel delegated to `RendezvousChannel[T]`.
    self.chan.send(item)

  proc recv*[T](self: AsyncRendezvousChannel[T], outVal: var T): uint64 {.inline.} =
    ## Synchronous recv on AsyncRendezvousChannel delegated to `RendezvousChannel[T]`.
    self.chan.recv(outVal)

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
      maxReaders*: int
      cursorSignals*: seq[AsyncSignal]
      cursorWaiting*: seq[Atomic[bool]]
      producerSignal*: AsyncSignal

    AsyncBroadcastCursor*[T] = ref object
      cursor*: BroadcastCursor[T]
      ring*: AsyncBroadcastRing[T]
      slotId*: int
      signal*: AsyncSignal
      isWaiting* {.align: CacheLineBytes.}: Atomic[bool]
      closed*: Atomic[bool]

  proc initCursorSlotTable[T](self: AsyncBroadcastRing[T], maxReaders: int) =
    let maxR = max(1, maxReaders)
    self.maxReaders = maxR
    self.cursorSignals = newSeq[AsyncSignal](maxR)
    self.cursorWaiting = newSeq[Atomic[bool]](maxR)
    for i in 0 ..< maxR:
      self.cursorWaiting[i].store(false, moRelaxed)

  proc newAsyncBroadcastRing*[T](
      capacity: int = DefaultRingCapacity,
      overflowMode: OverflowMode = omDropOldest,
      maxReaders: int = DefaultMaxReaders
  ): AsyncBroadcastRing[T] =
    new result
    result.ring = initBroadcastRing[T](capacity, overflowMode, maxReaders)
    result.waitingProducerCount.store(0, moRelaxed)
    result.waitingCursorCount.store(0, moRelaxed)
    result.initCursorSlotTable(result.ring.core.maxReaders)
    result.producerSignal = newAsyncSignal()

  proc toAsync*[T](ring: sink BroadcastRing[T]): AsyncBroadcastRing[T] =
    new result
    result.ring = ring
    result.waitingProducerCount.store(0, moRelaxed)
    result.waitingCursorCount.store(0, moRelaxed)
    let maxR = if result.ring.core != nil: result.ring.core.maxReaders else: DefaultMaxReaders
    result.initCursorSlotTable(maxR)
    result.producerSignal = newAsyncSignal()

  proc notifyCursors*[T](self: AsyncBroadcastRing[T]) {.inline, gcsafe.} =
    if self == nil:
      return
    for i in 0 ..< self.maxReaders:
      if self.cursorWaiting[i].load(moSeqCst):
        if self.cursorSignals[i] != nil:
          self.cursorSignals[i].fire()

  proc notifyProducers*[T](self: AsyncBroadcastRing[T]) {.inline, gcsafe.} =
    if self == nil or self.producerSignal == nil:
      return
    self.producerSignal.fire()

  proc close*[T](self: AsyncBroadcastRing[T]) =
    if self == nil:
      return
    if self.producerSignal != nil:
      self.producerSignal.close()
    for i in 0 ..< self.maxReaders:
      if self.cursorSignals[i] != nil:
        self.cursorSignals[i].close()

  proc subscribe*[T](
      self: AsyncBroadcastRing[T],
      origin: SubscriptionOrigin = soFromLatest
  ): AsyncBroadcastCursor[T] =
    new result
    result.ring = self
    result.cursor = self.ring.subscribe(origin)
    let id = result.cursor.cursorId
    result.slotId = id
    if self.cursorSignals[id] == nil:
      self.cursorSignals[id] = newAsyncSignal()
    result.signal = self.cursorSignals[id]
    result.signal.clear()
    self.cursorWaiting[id].store(false, moSeqCst)
    result.isWaiting.store(false, moRelaxed)
    result.closed.store(false, moRelaxed)

  proc unsubscribe*[T](self: AsyncBroadcastCursor[T]) =
    ## Deregisters the async cursor, clears its lock-free slot in the ring's
    ## cursor table, releases its slot in the underlying BroadcastRing cursor
    ## table, wakes any coroutine awaiting this cursor, and wakes any stalled
    ## omBackoff producers.
    if self == nil:
      return
    if not self.closed.exchange(true, moAcquireRelease):
      let id = self.slotId
      if self.ring != nil and id >= 0 and id < self.ring.maxReaders:
        self.ring.cursorWaiting[id].store(false, moSeqCst)
        if self.isWaiting.exchange(false, moSeqCst):
          discard self.ring.waitingCursorCount.fetchSub(1, moSeqCst)

      self.cursor.unsubscribe()
      if self.signal != nil:
        self.signal.fire()

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
      if not self.producerSignal.hasWaiters():
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

      let id = self.slotId
      self.signal.clear()
      if not self.isWaiting.exchange(true, moSeqCst):
        self.ring.cursorWaiting[id].store(true, moSeqCst)
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
          self.ring.cursorWaiting[id].store(false, moSeqCst)
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

      let id = self.slotId
      self.signal.clear()
      if not self.isWaiting.exchange(true, moSeqCst):
        self.ring.cursorWaiting[id].store(true, moSeqCst)
        discard self.ring.waitingCursorCount.fetchAdd(1, moSeqCst)
      threadFence(moSeqCst)

      try:
        let r2 = self.cursor.poll()
        if r2.kind != prEmpty:
          if self.isWaiting.exchange(false, moSeqCst):
            self.ring.cursorWaiting[id].store(false, moSeqCst)
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
          self.ring.cursorWaiting[id].store(false, moSeqCst)
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
    AsyncTopicBus*[T] = ref object
      bus*: TopicBus[T]
      config*: TopicBusConfig
      topics*: Ctrie[string, AsyncBroadcastRing[T]]

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
    result.topics = initCtrie[string, AsyncBroadcastRing[T]]()

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
    result.topics = initCtrie[string, AsyncBroadcastRing[T]]()

  proc getOrCreateTopicRing*[T](self: AsyncTopicBus[T], topic: string): AsyncBroadcastRing[T] =
    let existing = self.topics.get(topic)
    if existing.isSome:
      return existing.get
    let syncRing = self.bus.getOrCreateRing(topic)
    let newAsyncRing = toAsync(syncRing)
    let prev = self.topics.putIfAbsent(topic, newAsyncRing)
    if prev.isSome:
      newAsyncRing.close()
      return prev.get
    return newAsyncRing

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
      if not self.thiefSignal.hasWaiters():
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
      if not self.thiefSignal.hasWaiters():
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
