---
title: "lockfree/async_bridge"
description: "API reference for lockfree/async_bridge"
---

<p>src/lockfree/async_bridge.nim</p>
<p>Async Bridge Substrate for std/asyncdispatch and Chronos (-d:lockfreeChronos).</p>
<p>Provides high-performance, non-blocking asynchronous adapters over foundational lock-free containers:</p>
<ul class="simple"><li>BQueue<a class="reference internal" href="#T">T</a> (Bounded MPMC / SPSC) -&gt; AsyncBQueue<a class="reference internal" href="#T">T</a></li>
<li>Queue<a class="reference internal" href="#T">T</a> (Unbounded LCRQ) -&gt; AsyncQueue<a class="reference internal" href="#T">T</a></li>
<li>RendezvousChannel<a class="reference internal" href="#T">T</a> (Synchronous CSP zero-buffer handoff) -&gt; AsyncRendezvousChannel<a class="reference internal" href="#T">T</a></li>
<li>BroadcastRing<a class="reference internal" href="#T">T</a> (Multicast 1-to-N fanout) -&gt; AsyncBroadcastRing<a class="reference internal" href="#T">T</a>, AsyncBroadcastCursor<a class="reference internal" href="#T">T</a></li>
<li>TopicBus<a class="reference internal" href="#T">T</a> (Multiplexed Pub-Sub topic router) -&gt; AsyncTopicBus<a class="reference internal" href="#T">T</a></li>
<li>ChaseLevDeque<a class="reference internal" href="#T">T</a> (Work-stealing deque) -&gt; AsyncChaseLevDeque<a class="reference internal" href="#T">T</a></li>
</ul>
<p>Core Architectural Invariants:</p>
<ol class="simple"><li>Fast-Path Speculative Non-Blocking Execution (zero-allocation immediate Future return)</li>
<li>Strict SMR Epoch Pin Isolation (PinScope ∩ SuspensionPoints = ∅; pin never held across await)</li>
<li>Bilateral CAS Arbitration &amp; Dekker Store-Load (moSequentiallyConsistent) Barrier Pairing (zero lost wakeups and zero item loss on cancellation)</li>
<li>Thread-Safe Cross-Thread Wakeups via AsyncSignal (dual-backend: std/asyncdispatch AsyncEvent and Chronos ThreadSignalPtr)</li>
</ol>


## Types

### `AsyncSignal`

```nim
AsyncSignal = ref object
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
```

### `AsyncBQueue`

```nim
AsyncBQueue[T; ccProd; ccCons; N; P; C] = ref object
  queue*: BQueue[T, ccProd, ccCons, N, P, C]
  consumerSignal*: AsyncSignal
  producerSignal*: AsyncSignal
  hasWaitingConsumers* {.align: 128.}: Atomic[bool]
  hasWaitingProducers* {.align: 128.}: Atomic[bool]
```

### `AsyncQueue`

```nim
AsyncQueue[T; ccProd; ccCons; ST; S; MaxThreads] = ref object
  queue*: Queue[T, ccProd, ccCons, ST, S, MaxThreads]
  consumerSignal*: AsyncSignal
  hasWaitingConsumers* {.align: 128.}: Atomic[bool]
```

### `AsyncQueueSpsc`

```nim
AsyncQueueSpsc[T; S; MaxThreads] = AsyncQueue[T, ccSingle, ccSingle, stEager, S,
    MaxThreads]
```

### `AsyncRendezvousChannel`

```nim
AsyncRendezvousChannel[T] = ref object
  chan*: RendezvousChannel[T]
  senderSignal*: AsyncSignal
  receiverSignal*: AsyncSignal
```

### `AsyncBroadcastRing`

```nim
AsyncBroadcastRing[T] = ref object
  ring*: BroadcastRing[T]
  waitingProducerCount* {.align: 128.}: Atomic[int32]
  waitingCursorCount* {.align: 128.}: Atomic[int32]
  maxReaders*: int
  cursorSignals*: seq[AsyncSignal]
  cursorWaiting*: seq[Atomic[bool]]
  producerSignal*: AsyncSignal
```

### `AsyncBroadcastCursor`

```nim
AsyncBroadcastCursor[T] = ref object
  cursor*: BroadcastCursor[T]
  ring*: AsyncBroadcastRing[T]
  slotId*: int
  signal*: AsyncSignal
  isWaiting* {.align: 128.}: Atomic[bool]
  closed*: Atomic[bool]
```

### `AsyncTopicBus`

```nim
AsyncTopicBus[T] = ref object
  bus*: TopicBus[T]
  config*: TopicBusConfig
  topics*: Ctrie[string, AsyncBroadcastRing[T]]
```

### `AsyncChaseLevDeque`

```nim
AsyncChaseLevDeque[T] = ref object
  deque*: ChaseLevDeque[T]
  waitingThieves* {.align: 128.}: Atomic[int32]
  thiefSignal*: AsyncSignal
  closed*: Atomic[bool]
```

### `AsyncDeque`

```nim
AsyncDeque[T] = AsyncChaseLevDeque[T]
```

### `AsyncConcurrentDeque`

```nim
AsyncConcurrentDeque[T] = AsyncChaseLevDeque[T]
```


## Procedures & Functions

### ``=destroy``

```nim
proc `=destroy`(sig: var typeof(AsyncSignal()[])) {.raises: [], tags: [],
    forbids: [].}
```

### `newAsyncSignal`

```nim
proc newAsyncSignal(): AsyncSignal {.raises: [OSError], tags: [], forbids: [].}
```

### `pruneFinishedWaiters`

```nim
proc pruneFinishedWaiters(sig: AsyncSignal) {.inline, raises: [], tags: [],
    forbids: [].}
```

### `hasWaiters`

```nim
proc hasWaiters(sig: AsyncSignal): bool {.inline, raises: [], tags: [],
    forbids: [].}
```

### `waiters`

```nim
proc waiters(sig: AsyncSignal): seq[Future[void]] {.inline, raises: [],
    tags: [], forbids: [].}
```

Snapshot of currently parked waiter futures in FIFO registration order.

### `fire`

```nim
proc fire(sig: AsyncSignal) {.inline, gcsafe, raises: [], tags: [], forbids: [].}
```

Thread-safe, non-blocking signal trigger. Can be invoked from any OS thread. Triggers the underlying kernel event at most once per active registration (<tt class="docutils literal"><span class="pre"><span class="Identifier">ksRegistered</span> <span class="Operator">-&gt;</span> <span class="Identifier">ksTriggered</span></span></tt>).

### `clear`

```nim
proc clear(sig: AsyncSignal) {.inline, gcsafe, raises: [], tags: [], forbids: [].}
```

### `wait`

```nim
proc wait(sig: AsyncSignal): Future[void] {.raises: [Exception, OSError],
    tags: [RootEffect], forbids: [].}
```

Suspends until the signal is fired. Sticky flag prevents lost wakeups.

### `close`

```nim
proc close(sig: AsyncSignal) {.raises: [Exception, OSError], tags: [RootEffect],
                               forbids: [].}
```

### `newAsyncBQueue`

```nim
proc newAsyncBQueue[T; ccProd, ccCons: static PinScopeCardinality;
                    N, P, C: static int](): AsyncBQueue[T, ccProd, ccCons, N, P,
    C]
```

### `toAsync`

```nim
proc toAsync[T; ccProd, ccCons: static PinScopeCardinality; N, P, C: static int](
    q: sink BQueue[T, ccProd, ccCons, N, P, C]): AsyncBQueue[T, ccProd, ccCons,
    N, P, C]
```

### `sendAsync`

```nim
proc sendAsync[T; N: static int](self: AsyncBQueue[T, ccSingle, ccSingle, N, 0,
    0]; item: sink T): Future[bool] {.stackTrace: false.}
```

Asynchronously sends an item into the bounded queue. Suspends if full until space is available.

### `recvAsync`

```nim
proc recvAsync[T; N: static int](self: AsyncBQueue[T, ccSingle, ccSingle, N, 0,
    0]): Future[Option[T]] {.stackTrace: false.}
```

Asynchronously awaits and receives an item from the bounded queue. SMR invariant: No pin held across await.

### `tryPopAsync`

```nim
proc tryPopAsync[T; N: static int](self: AsyncBQueue[T, ccSingle, ccSingle, N,
    0, 0]): Future[Option[T]]
```

Speculative non-blocking try-pop. Returns immediately resolved Future.

### `push`

```nim
proc push[T; N: static int](self: AsyncBQueue[T, ccSingle, ccSingle, N, 0, 0];
                            item: sink T): bool
```

Synchronous push with consumer wakeup.

### `pop`

```nim
proc pop[T; N: static int](self: AsyncBQueue[T, ccSingle, ccSingle, N, 0, 0]): Future[
    Option[T]] {.inline.}
```

### `close`

```nim
proc close[T; ccProd, ccCons: static PinScopeCardinality; N, P, C: static int](
    self: AsyncBQueue[T, ccProd, ccCons, N, P, C])
```

### `tryPopAsync`

```nim
proc tryPopAsync[T; N: static int](self: var BQueue[T, ccSingle, ccSingle, N, 0,
    0]): Future[Option[T]]
```

### `newAsyncQueue`

```nim
proc newAsyncQueue[T; ccProd, ccCons: static PinScopeCardinality;
                   ST: static DeallocationStrategy; S, MaxThreads: static int](
    _: typedesc[AsyncQueue[T, ccProd, ccCons, ST, S, MaxThreads]]): AsyncQueue[
    T, ccProd, ccCons, ST, S, MaxThreads]
```

### `toAsync`

```nim
proc toAsync[T; ccProd, ccCons: static PinScopeCardinality;
             ST: static DeallocationStrategy; S, MaxThreads: static int](
    q: sink Queue[T, ccProd, ccCons, ST, S, MaxThreads]): AsyncQueue[T, ccProd,
    ccCons, ST, S, MaxThreads]
```

### `push`

```nim
proc push[T; ST: static DeallocationStrategy; S, MaxThreads: static int](
    self: AsyncQueue[T, ccSingle, ccSingle, ST, S, MaxThreads]; item: sink T): bool
```

Synchronous thread-safe push with consumer wakeup. Safe to invoke from raw OS worker threads without allocating Future objects.

### `trySend`

```nim
proc trySend[T; ST: static DeallocationStrategy; S, MaxThreads: static int](
    self: AsyncQueue[T, ccSingle, ccSingle, ST, S, MaxThreads]; item: sink T): bool {.
    inline.}
```

Alias for synchronous thread-safe <tt class="docutils literal"><span class="pre"><span class="Identifier">push</span></span></tt>.

### `sendAsync`

```nim
proc sendAsync[T; ST: static DeallocationStrategy; S, MaxThreads: static int](
    self: AsyncQueue[T, ccSingle, ccSingle, ST, S, MaxThreads]; item: sink T): Future[
    bool]
```

Unbounded enqueue never blocks; pushes immediately and notifies waiting consumers. Note: Must be invoked from the event-loop thread; raw OS threads should call <tt class="docutils literal"><span class="pre"><span class="Identifier">push</span></span></tt> or <tt class="docutils literal"><span class="pre"><span class="Identifier">trySend</span></span></tt>.

### `recvAsync`

```nim
proc recvAsync[T; ST: static DeallocationStrategy; S, MaxThreads: static int](
    self: AsyncQueue[T, ccSingle, ccSingle, ST, S, MaxThreads]): Future[
    Option[T]] {.stackTrace: false.}
```

Asynchronously awaits and receives an item from the unbounded queue.

### `tryPopAsync`

```nim
proc tryPopAsync[T; ST: static DeallocationStrategy; S, MaxThreads: static int](
    self: AsyncQueue[T, ccSingle, ccSingle, ST, S, MaxThreads]): Future[
    Option[T]]
```

### `pop`

```nim
proc pop[T; ST: static DeallocationStrategy; S, MaxThreads: static int](
    self: AsyncQueue[T, ccSingle, ccSingle, ST, S, MaxThreads]): Future[
    Option[T]] {.inline.}
```

### `close`

```nim
proc close[T; ccProd, ccCons: static PinScopeCardinality;
           ST: static DeallocationStrategy; S, MaxThreads: static int](
    self: AsyncQueue[T, ccProd, ccCons, ST, S, MaxThreads])
```

### `tryPopAsync`

```nim
proc tryPopAsync[T; ST: static DeallocationStrategy; S, MaxThreads: static int](
    self: var Queue[T, ccSingle, ccSingle, ST, S, MaxThreads]): Future[Option[T]]
```

### `newAsyncRendezvousChannel`

```nim
proc newAsyncRendezvousChannel[T](): AsyncRendezvousChannel[T]
```

### `toAsync`

```nim
proc toAsync[T](chan: RendezvousChannel[T]): AsyncRendezvousChannel[T]
```

### `isClosed`

```nim
proc isClosed[T](self: AsyncRendezvousChannel[T]): bool {.inline.}
```

### `close`

```nim
proc close[T](self: AsyncRendezvousChannel[T])
```

### `sendAsync`

```nim
proc sendAsync[T](self: AsyncRendezvousChannel[T]; item: sink T): Future[bool] {.
    stackTrace: false.}
```

Asynchronously sends an item through the rendezvous channel. Delegates directly to <tt class="docutils literal"><span class="pre"><span class="Identifier">RendezvousChannel</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>'s lock-free Scherer-Scott dual queue. Bilateral CAS arbitration guarantees zero item loss on cancellation.

### `recvAsync`

```nim
proc recvAsync[T](self: AsyncRendezvousChannel[T]): Future[Option[T]] {.
    stackTrace: false.}
```

Asynchronously receives an item from the rendezvous channel. Delegates directly to <tt class="docutils literal"><span class="pre"><span class="Identifier">RendezvousChannel</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>'s lock-free Scherer-Scott dual queue.

### `tryPopAsync`

```nim
proc tryPopAsync[T](self: AsyncRendezvousChannel[T]): Future[Option[T]]
```

Speculative non-blocking try-recv delegated to <tt class="docutils literal"><span class="pre"><span class="Identifier">RendezvousChannel</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>.

### `send`

```nim
proc send[T](self: AsyncRendezvousChannel[T]; item: sink T): uint64 {.inline.}
```

Synchronous send on AsyncRendezvousChannel delegated to <tt class="docutils literal"><span class="pre"><span class="Identifier">RendezvousChannel</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>.

### `recv`

```nim
proc recv[T](self: AsyncRendezvousChannel[T]; outVal: var T): uint64 {.inline.}
```

Synchronous recv on AsyncRendezvousChannel delegated to <tt class="docutils literal"><span class="pre"><span class="Identifier">RendezvousChannel</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>.

### `tryPopAsync`

```nim
proc tryPopAsync[T](self: RendezvousChannel[T]): Future[Option[T]]
```

### `newAsyncBroadcastRing`

```nim
proc newAsyncBroadcastRing[T](capacity: int = DefaultRingCapacity;
                              overflowMode: OverflowMode = omDropOldest;
                              maxReaders: int = DefaultMaxReaders): AsyncBroadcastRing[
    T]
```

### `toAsync`

```nim
proc toAsync[T](ring: sink BroadcastRing[T]): AsyncBroadcastRing[T]
```

### `notifyCursors`

```nim
proc notifyCursors[T](self: AsyncBroadcastRing[T]) {.inline, gcsafe.}
```

### `notifyProducers`

```nim
proc notifyProducers[T](self: AsyncBroadcastRing[T]) {.inline, gcsafe.}
```

### `close`

```nim
proc close[T](self: AsyncBroadcastRing[T])
```

### `subscribe`

```nim
proc subscribe[T](self: AsyncBroadcastRing[T];
                  origin: SubscriptionOrigin = soFromLatest): AsyncBroadcastCursor[
    T]
```

### `unsubscribe`

```nim
proc unsubscribe[T](self: AsyncBroadcastCursor[T])
```

Deregisters the async cursor, clears its lock-free slot in the ring's cursor table, releases its slot in the underlying BroadcastRing cursor table, wakes any coroutine awaiting this cursor, and wakes any stalled omBackoff producers.

### `close`

```nim
proc close[T](self: AsyncBroadcastCursor[T]) {.inline.}
```

### `isClosed`

```nim
proc isClosed[T](self: AsyncBroadcastCursor[T]): bool {.inline.}
```

### `lag`

```nim
proc lag[T](self: AsyncBroadcastCursor[T]): uint64 {.inline.}
```

### `subscriberCount`

```nim
proc subscriberCount[T](self: AsyncBroadcastRing[T]): int {.inline.}
```

### `capacity`

```nim
proc capacity[T](self: AsyncBroadcastRing[T]): int {.inline.}
```

### `len`

```nim
proc len[T](self: AsyncBroadcastRing[T]): int {.inline.}
```

### `publish`

```nim
proc publish[T](self: AsyncBroadcastRing[T]; item: sink T)
```

### `tryPublish`

```nim
proc tryPublish[T](self: AsyncBroadcastRing[T]; item: sink T): bool
```

### `sendAsync`

```nim
proc sendAsync[T](self: AsyncBroadcastRing[T]; item: sink T): Future[bool] {.
    stackTrace: false.}
```

Asynchronously publishes an item to the broadcast ring. Under <tt class="docutils literal"><span class="pre"><span class="Identifier">omDropOldest</span></span></tt>, publishes immediately without suspending. Under <tt class="docutils literal"><span class="pre"><span class="Identifier">omBackoff</span></span></tt>, suspends when the ring is full until the slowest active cursor advances or unsubscribes.

### `sendAsync`

```nim
proc sendAsync[T](ring: BroadcastRing[T]; item: sink T): Future[bool]
```

### `isReadable`

```nim
proc isReadable[T](self: AsyncBroadcastCursor[T]): bool {.inline.}
```

Returns true if the cursor currently has a published slot ready to be polled (either <tt class="docutils literal"><span class="pre"><span class="Identifier">prSuccess</span></span></tt> or <tt class="docutils literal"><span class="pre"><span class="Identifier">prLagged</span></span></tt>) without advancing <tt class="docutils literal"><span class="pre"><span class="Identifier">readSeq</span></span></tt>.

### `waitReadable`

```nim
proc waitReadable[T](self: AsyncBroadcastCursor[T]): Future[bool] {.
    stackTrace: false.}
```

Suspends until at least one message is readable at this cursor without consuming the message. Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">false</span></span></tt> if the cursor is unsubscribed or closed.

### `pollAsync`

```nim
proc pollAsync[T](self: AsyncBroadcastCursor[T]): Future[PollResult[T]] {.
    stackTrace: false.}
```

Asynchronously polls the next event on this cursor, returning <tt class="docutils literal"><span class="pre"><span class="Identifier">prSuccess</span></span></tt> with the item or <tt class="docutils literal"><span class="pre"><span class="Identifier">prLagged</span><span class="Punctuation">(</span><span class="Identifier">skippedCount</span><span class="Punctuation">)</span></span></tt> if the subscriber fell behind the ring overwrite horizon under <tt class="docutils literal"><span class="pre"><span class="Identifier">omDropOldest</span></span></tt>. Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">prEmpty</span></span></tt> only if the cursor is closed/unsubscribed.

### `recvAsync`

```nim
proc recvAsync[T](self: AsyncBroadcastCursor[T]): Future[Option[T]] {.
    stackTrace: false.}
```

Asynchronously awaits the next available broadcast message on this cursor. If the cursor lags under <tt class="docutils literal"><span class="pre"><span class="Identifier">omDropOldest</span></span></tt>, it automatically snaps forward to the newest available ring horizon and reads without spurious suspension. Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">none</span><span class="Punctuation">(</span><span class="Identifier">T</span><span class="Punctuation">)</span></span></tt> if the cursor is unsubscribed/closed.

### `tryPopAsync`

```nim
proc tryPopAsync[T](self: AsyncBroadcastCursor[T]): Future[Option[T]]
```

### `tryPopAsync`

```nim
proc tryPopAsync[T](self: var BroadcastCursor[T]): Future[Option[T]]
```

### `newAsyncTopicBus`

```nim
proc newAsyncTopicBus[T](config: TopicBusConfig = TopicBusConfig(
    defaultRingCapacity: 1024, defaultOverflowMode: omDropOldest,
    defaultMaxReaders: 64)): AsyncTopicBus[T]
```

### `toAsync`

```nim
proc toAsync[T](bus: sink TopicBus[T]): AsyncTopicBus[T]
```

### `getOrCreateTopicRing`

```nim
proc getOrCreateTopicRing[T](self: AsyncTopicBus[T]; topic: string): AsyncBroadcastRing[
    T]
```

### `subscribe`

```nim
proc subscribe[T](self: AsyncTopicBus[T]; topic: string;
                  origin: SubscriptionOrigin = soFromLatest): AsyncBroadcastCursor[
    T]
```

### `publish`

```nim
proc publish[T](self: AsyncTopicBus[T]; topic: string; item: sink T)
```

### `tryPublish`

```nim
proc tryPublish[T](self: AsyncTopicBus[T]; topic: string; item: sink T): bool
```

### `sendAsync`

```nim
proc sendAsync[T](self: AsyncTopicBus[T]; topic: string; item: sink T): Future[
    bool]
```

### `topicCount`

```nim
proc topicCount[T](self: AsyncTopicBus[T]): int {.inline.}
```

### `hasTopic`

```nim
proc hasTopic[T](self: AsyncTopicBus[T]; topic: string): bool {.inline.}
```

### `newAsyncChaseLevDeque`

```nim
proc newAsyncChaseLevDeque[T](initialCapacity: int = 64): AsyncChaseLevDeque[T]
```

### `newAsyncDeque`

```nim
proc newAsyncDeque[T](initialCapacity: int = 64): AsyncDeque[T] {.inline.}
```

### `toAsync`

```nim
proc toAsync[T](d: sink ChaseLevDeque[T]): AsyncChaseLevDeque[T] {.
    notATransition.}
```

### `notifyThieves`

```nim
proc notifyThieves[T](self: AsyncChaseLevDeque[T]) {.inline, gcsafe.}
```

### `close`

```nim
proc close[T](self: AsyncChaseLevDeque[T])
```

### `isClosed`

```nim
proc isClosed[T](self: AsyncChaseLevDeque[T]): bool {.inline.}
```

### `len`

```nim
proc len[T](self: AsyncChaseLevDeque[T]): int {.inline.}
```

### `isEmpty`

```nim
proc isEmpty[T](self: AsyncChaseLevDeque[T]): bool {.inline.}
```

### `capacity`

```nim
proc capacity[T](self: AsyncChaseLevDeque[T]): int {.inline.}
```

### `pushBottom`

```nim
proc pushBottom[T](self: AsyncChaseLevDeque[T]; item: sink T)
```

Pushes an item to the bottom of the work-stealing deque (single owner-worker thread only) and wakes any parked async thieves under a Dekker <tt class="docutils literal"><span class="pre"><span class="Identifier">moSequentiallyConsistent</span></span></tt> Store-Load barrier.

### `sendAsync`

```nim
proc sendAsync[T](self: AsyncChaseLevDeque[T]; item: sink T): Future[bool]
```

Owner-worker non-blocking bottom push returning an immediately completed Future.

### `popBottom`

```nim
proc popBottom[T](self: AsyncChaseLevDeque[T]): Option[T] {.inline.}
```

Pops an item from the bottom of the deque (LIFO order, single owner-worker thread only).

### `tryPopBottom`

```nim
proc tryPopBottom[T](self: AsyncChaseLevDeque[T]; item: var T): bool {.inline.}
```

### `steal`

```nim
proc steal[T](self: AsyncChaseLevDeque[T]): Option[T] {.inline.}
```

Synchronous non-blocking FIFO steal from the top of the deque.

### `stealBatch`

```nim
proc stealBatch[T](self: AsyncChaseLevDeque[T]; dest: var openArray[T];
                   maxItems: int = -1): int {.inline.}
```

### `stealBatch`

```nim
proc stealBatch[T](self: AsyncChaseLevDeque[T]; maxItems: int = -1): seq[T] {.
    inline.}
```

### `tryStealAsync`

```nim
proc tryStealAsync[T](self: AsyncChaseLevDeque[T]): Future[Option[T]]
```

Speculative non-blocking FIFO steal from the top of the deque.

### `tryPopAsync`

```nim
proc tryPopAsync[T](self: AsyncChaseLevDeque[T]): Future[Option[T]] {.inline.}
```

### `tryStealAsync`

```nim
proc tryStealAsync[T](self: var ChaseLevDeque[T]): Future[Option[T]] {.
    notATransition.}
```

### `stealAsync`

```nim
proc stealAsync[T](self: AsyncChaseLevDeque[T]): Future[Option[T]] {.
    stackTrace: false.}
```

Asynchronously steals an item from the top of the deque (FIFO order). Suspends without busy-spinning when the deque is empty, using a Dekker <tt class="docutils literal"><span class="pre"><span class="Identifier">moSequentiallyConsistent</span></span></tt> barrier with <tt class="docutils literal"><span class="pre"><span class="Identifier">pushBottom</span></span></tt> so zero wakeups can be lost. Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">none</span><span class="Punctuation">(</span><span class="Identifier">T</span><span class="Punctuation">)</span></span></tt> only if the deque is closed and empty.

### `recvAsync`

```nim
proc recvAsync[T](self: AsyncChaseLevDeque[T]): Future[Option[T]] {.inline.}
```

### `stealBatchAsync`

```nim
proc stealBatchAsync[T](self: AsyncChaseLevDeque[T]; maxItems: int = -1): Future[
    seq[T]] {.stackTrace: false.}
```

Asynchronously steals a batch of items from the top of the deque (FIFO order). Suspends when empty and wakes on <tt class="docutils literal"><span class="pre"><span class="Identifier">pushBottom</span></span></tt>. If items remain after the batch steal, cascades wakeup to any remaining parked thieves.


## Templates

### `event`

```nim
template event[T; ccProd, ccCons: static PinScopeCardinality;
               N, P, C: static int](self: AsyncBQueue[T, ccProd, ccCons, N, P, C]): AsyncSignal
```

### `asyncEvent`

```nim
template asyncEvent[T; ccProd, ccCons: static PinScopeCardinality;
                    N, P, C: static int](
    self: AsyncBQueue[T, ccProd, ccCons, N, P, C]): AsyncSignal
```

### `event`

```nim
template event[T; ccProd, ccCons: static PinScopeCardinality;
               ST: static DeallocationStrategy; S, MaxThreads: static int](
    self: AsyncQueue[T, ccProd, ccCons, ST, S, MaxThreads]): AsyncSignal
```

### `asyncEvent`

```nim
template asyncEvent[T; ccProd, ccCons: static PinScopeCardinality;
                    ST: static DeallocationStrategy; S, MaxThreads: static int](
    self: AsyncQueue[T, ccProd, ccCons, ST, S, MaxThreads]): AsyncSignal
```

