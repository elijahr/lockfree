---
title: "lockfree/rendezvous"
description: "API reference for lockfree/rendezvous"
---

<h1><a class="toc-backref" id="concurrency-topologycolon-mpmc-synchronous-zerominusbuffer-dual-channel-nimrendezvouschannel-t" href="#concurrency-topologycolon-mpmc-synchronous-zerominusbuffer-dual-channel-nimrendezvouschannel-t">Concurrency Topology: MPMC Synchronous Zero-Buffer Dual Channel (<tt class="docutils literal"><span class="pre"><span class="Identifier">RendezvousChannel</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>)</a></h1><table border="1" class="docutils"><tr><th>Dimension</th><th>Architectural Specification</th></tr>
<tr><td><strong>Topologies</strong></td><td>MPMC Synchronous Dual Channel (CSP / Go unbuffered <tt class="docutils literal"><span class="pre"><span class="Identifier">make</span><span class="Punctuation">(</span><span class="Identifier">chan</span> <span class="Identifier">T</span><span class="Punctuation">)</span></span></tt>)</td></tr>
<tr><td><strong>Buffer Capacity</strong></td><td>Strictly Zero (No intermediate ring buffer or linked queue segment)</td></tr>
<tr><td><strong>Delivery Model</strong></td><td>Bilateral 1-to-1 Rendezvous (Sender &amp; receiver must meet in real time)</td></tr>
<tr><td><strong>Matching Engine</strong></td><td>Dual lock-free queue with bilateral CAS arbitration (Scherer &amp; Scott)</td></tr>
<tr><td><strong>Thread Suspension</strong></td><td>OS-native futex (<tt class="docutils literal"><span class="pre"><span class="Identifier">ulock_wait</span></span></tt> on Darwin, <tt class="docutils literal"><span class="pre"><span class="Identifier">WaitOnAddress</span></span></tt>, Linux futex)</td></tr>
<tr><td><strong>Correlation Tracking</strong></td><td>Monotonic 64-bit correlation IDs for req/rep RPC pair tracing</td></tr>
<tr><td><strong>Timeouts</strong></td><td>Bounded timeouts (<tt class="docutils literal"><span class="pre"><span class="Identifier">trySend</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">sendWithTimeout</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">tryRecv</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">recvTimeout</span></span></tt>)</td></tr>
<tr><td><strong>Payload Storage</strong></td><td>Single-owner atomic pointer transfer (<tt class="docutils literal"><span class="pre"><span class="Identifier">VBox</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>) under ARC/ORC</td></tr>
<tr><td><strong>Cache Alignment</strong></td><td>Waiter nodes and channel anchors aligned to <tt class="docutils literal"><span class="pre"><span class="Identifier">CacheLineBytes</span></span></tt> (64/128B)</td></tr>
<tr><td><strong>Progress Guarantees</strong></td><td>Immediate Match: Lock-Free; Parking Path: Wait-Free Coordination</td></tr>
<tr><td><strong>C ABI Interop</strong></td><td>Full C99 foreign thread support with <tt class="docutils literal"><span class="pre"><span class="Identifier">lockfree_rendezvous</span><span class="Operator">.</span><span class="Identifier">h</span></span></tt> bindings</td></tr>
</table>
<h2><a class="toc-backref" id="concurrency-topologycolon-mpmc-synchronous-zerominusbuffer-dual-channel-nimrendezvouschannel-t-overview" href="#concurrency-topologycolon-mpmc-synchronous-zerominusbuffer-dual-channel-nimrendezvouschannel-t-overview">Overview</a></h2><p><tt class="docutils literal"><span class="pre"><span class="Identifier">RendezvousChannel</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> implements a high-performance synchronous zero-buffer dual channel based on William N. Scherer III and Michael L. Scott's dual data structures (PPoPP '06).</p>
<p>Senders block until a receiver arrives; receivers block until a sender arrives. Data transfer occurs bilaterally between physical threads with zero intermediate queue buffering. Monotonic correlation IDs enable deterministic request/response tracing.</p>


## Types

### `VBox`

```nim
VBox[T] = object
  rc*: Atomic[int32]
  val*: T
```

### `ParkerWakeProc`

```nim
ParkerWakeProc = proc (arg: pointer) {.nimcall, gcsafe, raises: [].}
```

### `Parker`

```nim
Parker = object
  when defined(macosx) or defined(macos) or defined(ios):
    word*: Atomic[uint32]
  elif defined(linux) or defined(windows):
    word*: Atomic[int32]
  else:
    lock*: Lock
    cond*: Cond
    signaled*: Atomic[bool]
  wakeCb*: Atomic[pointer]
  wakeArg*: Atomic[pointer]
```

### `WaiterMode`

```nim
WaiterMode = enum
  wmSender,                 ## Offering a value
  wmReceiver                 ## Requesting a value
```

### `RendezvousState`

```nim
RendezvousState = enum
  rsWaiting,                ## Actively enqueued, waiting for partner
  rsMatched,                ## Partner arrived and won CAS; data transferred
  rsCancelled                ## Thread timed out or aborted before match
```

### `RendezvousWaiter`

```nim
RendezvousWaiter[T] = object
  mode*: WaiterMode
  taggedState*: Atomic[uint64]
  lifecycleRc*: Atomic[int32]
  vbox*: Atomic[ptr VBox[T]]
  correlationId*: uint64
  next*: Atomic[ptr RendezvousWaiter[T]]
  poolNext*: Atomic[ptr RendezvousWaiter[T]]
  parker*: Parker
```

### `RendezvousChannelCore`

```nim
RendezvousChannelCore[T] = object
  head*: Atomic[ptr RendezvousWaiter[T]]
  tail*: Atomic[ptr RendezvousWaiter[T]]
  freeWriteIdx*: Atomic[uint64]
  freeReadIdx*: Atomic[uint64]
  freeSlots*: array[WaiterPoolCap, Atomic[ptr RendezvousWaiter[T]]]
  overflowHead*: Atomic[ptr RendezvousWaiter[T]]
  nextCorrId*: Atomic[uint64]
  nextWaiterEpoch*: Atomic[uint64]
  rc*: Atomic[int]
  isClosed*: Atomic[bool]
```

### `RendezvousChannel`

```nim
RendezvousChannel[T] = object
  core*: ptr RendezvousChannelCore[T]
```


## Procedures & Functions

### `allocSharedAligned`

```nim
proc allocSharedAligned[T](): ptr T
```

### `freeSharedAligned`

```nim
proc freeSharedAligned(p: pointer) {.inline, raises: [], tags: [], forbids: [].}
```

### `freeSharedAligned`

```nim
proc freeSharedAligned[T](p: ptr T) {.inline.}
```

### `initParker`

```nim
proc initParker(p: var Parker) {.inline, raises: [], tags: [], forbids: [].}
```

### `deinitParker`

```nim
proc deinitParker(p: var Parker) {.inline, raises: [], tags: [], forbids: [].}
```

### `resetParker`

```nim
proc resetParker(p: var Parker) {.inline, raises: [], tags: [], forbids: [].}
```

### `unpark`

```nim
proc unpark(p: var Parker) {.inline, raises: [], tags: [RootEffect], forbids: [].}
```

### `park`

```nim
proc park(p: var Parker) {.inline, raises: [], tags: [], forbids: [].}
```

### `parkTimeout`

```nim
proc parkTimeout(p: var Parker; timeoutMs: int): bool {.raises: [], tags: [],
    forbids: [].}
```

### `currentState`

```nim
proc currentState[T](w: ptr RendezvousWaiter[T];
                     order: static MemoryOrder = moAcquire): RendezvousState {.
    inline, raises: [].}
```

Loads the current <tt class="docutils literal"><span class="pre"><span class="Identifier">RendezvousState</span></span></tt> from the waiter's 64-bit <tt class="docutils literal"><span class="pre"><span class="Identifier">taggedState</span></span></tt>.

### `initRendezvousChannel`

```nim
proc initRendezvousChannel[T](): RendezvousChannel[T]
```

Constructs a new zero-buffer MPMC synchronous rendezvous channel.

### ``=destroy``

```nim
proc `=destroy`[T](self: var RendezvousChannel[T]) {.raises: [].}
```

### ``=copy``

```nim
proc `=copy`[T](dest: var RendezvousChannel[T]; src: RendezvousChannel[T])
```

### ``=sink``

```nim
proc `=sink`[T](dest: var RendezvousChannel[T]; src: RendezvousChannel[T])
```

### `isNil`

```nim
proc isNil[T](self: RendezvousChannel[T]): bool {.inline.}
```

### `isClosed`

```nim
proc isClosed[T](self: RendezvousChannel[T]): bool {.inline.}
```

### `close`

```nim
proc close[T](self: RendezvousChannel[T])
```

Closes the rendezvous channel and unparks any waiting threads.

### `send`

```nim
proc send[T](self: RendezvousChannel[T]; item: sink T): uint64
```

Synchronously sends <tt class="docutils literal"><span class="pre"><span class="Identifier">item</span></span></tt>, blocking until a receiver consumes it. Returns the unique monotonic correlation ID for this rendezvous.

### `recv`

```nim
proc recv[T](self: RendezvousChannel[T]; outVal: var T): uint64
```

Synchronously receives an item, blocking until a sender provides it. Stores payload in <tt class="docutils literal"><span class="pre"><span class="Identifier">outVal</span></span></tt> and returns the matching correlation ID.

### `recv`

```nim
proc recv[T](self: RendezvousChannel[T]): tuple[val: T, correlationId: uint64] {.
    inline.}
```

### `trySend`

```nim
proc trySend[T](self: RendezvousChannel[T]; item: sink T; outCorrId: var uint64): bool
```

Attempts an immediate non-blocking send. Returns true if a receiver was immediately available to accept the payload, false otherwise.

### `tryRecv`

```nim
proc tryRecv[T](self: RendezvousChannel[T]; outVal: var T; outCorrId: var uint64): bool
```

Attempts an immediate non-blocking receive. Returns true if a sender was immediately available with a pending payload, false otherwise.

### `sendWithTimeout`

```nim
proc sendWithTimeout[T](self: RendezvousChannel[T]; item: sink T;
                        timeoutMs: int; outCorrId: var uint64): bool
```

Attempts to send with a bounded timeout.

### `recvWithTimeout`

```nim
proc recvWithTimeout[T](self: RendezvousChannel[T]; outVal: var T;
                        timeoutMs: int; outCorrId: var uint64): bool
```

Attempts to receive with a bounded timeout.

### `enqueueAsyncSender`

```nim
proc enqueueAsyncSender[T](self: RendezvousChannel[T]; item: sink T;
                           wakeCb: ParkerWakeProc; wakeArg: pointer;
                           outCorrId: var uint64): ptr RendezvousWaiter[T]
```

Attempts an immediate lock-free match against a waiting receiver in the dual queue (<tt class="docutils literal"><span class="pre"><span class="Identifier">result</span> <span class="Operator">==</span> <span class="Keyword">nil</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">outCorrId</span> <span class="Operator">&gt;</span> <span class="DecNumber">0</span></span></tt>), or enqueues a <tt class="docutils literal"><span class="pre"><span class="Identifier">wmSender</span></span></tt> waiter node with <tt class="docutils literal"><span class="pre"><span class="Identifier">wakeCb</span></span></tt>/<tt class="docutils literal"><span class="pre"><span class="Identifier">wakeArg</span></span></tt> attached (<tt class="docutils literal"><span class="pre"><span class="Identifier">result</span> <span class="Operator">!=</span> <span class="Keyword">nil</span></span></tt>).

### `finishAsyncSender`

```nim
proc finishAsyncSender[T](self: RendezvousChannel[T];
                          waiter: ptr RendezvousWaiter[T];
                          outLeftoverWakeArg: var pointer): bool
```

Resolves bilateral CAS arbitration when an async sender wakes or cancels. Atomically extracts any unconsumed <tt class="docutils literal"><span class="pre"><span class="Identifier">wakeArg</span></span></tt> into <tt class="docutils literal"><span class="pre"><span class="Identifier">outLeftoverWakeArg</span></span></tt> before releasing the owner's waiter lifecycle reference.

### `finishAsyncSender`

```nim
proc finishAsyncSender[T](self: RendezvousChannel[T];
                          waiter: ptr RendezvousWaiter[T]): bool {.inline.}
```

### `enqueueAsyncReceiver`

```nim
proc enqueueAsyncReceiver[T](self: RendezvousChannel[T]; wakeCb: ParkerWakeProc;
                             wakeArg: pointer; outVal: var T;
                             outCorrId: var uint64): ptr RendezvousWaiter[T]
```

Attempts an immediate lock-free match against a waiting sender in the dual queue (<tt class="docutils literal"><span class="pre"><span class="Identifier">result</span> <span class="Operator">==</span> <span class="Keyword">nil</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">outCorrId</span> <span class="Operator">&gt;</span> <span class="DecNumber">0</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">outVal</span></span></tt> populated), or enqueues a <tt class="docutils literal"><span class="pre"><span class="Identifier">wmReceiver</span></span></tt> waiter node with <tt class="docutils literal"><span class="pre"><span class="Identifier">wakeCb</span></span></tt>/<tt class="docutils literal"><span class="pre"><span class="Identifier">wakeArg</span></span></tt> attached (<tt class="docutils literal"><span class="pre"><span class="Identifier">result</span> <span class="Operator">!=</span> <span class="Keyword">nil</span></span></tt>).

### `finishAsyncReceiver`

```nim
proc finishAsyncReceiver[T](self: RendezvousChannel[T];
                            waiter: ptr RendezvousWaiter[T]; outVal: var T;
                            outCorrId: var uint64;
                            outLeftoverWakeArg: var pointer): bool
```

Resolves bilateral CAS arbitration when an async receiver wakes or cancels. Atomically extracts any unconsumed <tt class="docutils literal"><span class="pre"><span class="Identifier">wakeArg</span></span></tt> into <tt class="docutils literal"><span class="pre"><span class="Identifier">outLeftoverWakeArg</span></span></tt> before releasing the owner's waiter lifecycle reference.

### `finishAsyncReceiver`

```nim
proc finishAsyncReceiver[T](self: RendezvousChannel[T];
                            waiter: ptr RendezvousWaiter[T]; outVal: var T;
                            outCorrId: var uint64): bool {.inline.}
```


## Templates

### ``&lt;&lt;-``

```nim
template `<<-`[T](chan: RendezvousChannel[T]; val: T)
```

### ``-&gt;&gt;``

```nim
template `->>`[T](chan: RendezvousChannel[T]; target: var T)
```

