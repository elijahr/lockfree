---
title: "lockfree/channel"
description: "API reference for lockfree/channel"
---

<p>lockfree/channel — High-level Go/Rust-style Channel facade for <tt class="docutils literal"><span class="pre"><span class="Identifier">lockfree</span></span></tt>.</p>
<p>Collapses the 6-parameter generic surface of <tt class="docutils literal"><span class="pre"><span class="Identifier">BQueue</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">Queue</span></span></tt> into ergonomic <tt class="docutils literal"><span class="pre"><span class="Identifier">Sender</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">Receiver</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>, and <tt class="docutils literal"><span class="pre"><span class="Identifier">Channel</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> types.</p>
<p>Features:</p>
<ul class="simple"><li>Bounded and unbounded channel flavours (<tt class="docutils literal"><span class="pre"><span class="Identifier">ChannelKind</span><span class="Operator">.</span><span class="Identifier">ckBounded</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">ckUnbounded</span></span></tt>).</li>
<li>Auto-registration for threads using thread-local storage (<tt class="docutils literal"><span class="pre"><span class="Punctuation">{</span><span class="Operator">.</span><span class="Identifier">threadvar</span><span class="Operator">.</span><span class="Punctuation">}</span></span></tt>). Threads can simply call <tt class="docutils literal"><span class="pre"><span class="Identifier">tx</span><span class="Operator">.</span><span class="Identifier">send</span><span class="Punctuation">(</span><span class="Identifier">item</span><span class="Punctuation">)</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">rx</span><span class="Operator">.</span><span class="Identifier">recv</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt> without manual <tt class="docutils literal"><span class="pre"><span class="Identifier">getProducer</span><span class="Punctuation">(</span><span class="Punctuation">)</span><span class="Operator">.</span><span class="Identifier">bindToThread</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt> ceremonies.</li>
<li>Smart <tt class="docutils literal"><span class="pre"><span class="Identifier">withEndpoint</span><span class="Operator">*</span><span class="Punctuation">(</span><span class="Identifier">queue</span><span class="Punctuation">,</span> <span class="Identifier">ep</span><span class="Punctuation">,</span> <span class="Identifier">body</span><span class="Punctuation">)</span></span></tt> AST-inspecting macro that auto-infers whether to bind a producer or consumer based on whether <tt class="docutils literal"><span class="pre"><span class="Operator">.</span><span class="Identifier">push</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt> or <tt class="docutils literal"><span class="pre"><span class="Operator">.</span><span class="Identifier">pop</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt> is called.</li>
</ul>


## Types

### `ChannelKind`

```nim
ChannelKind = enum
  ckBounded, ckUnbounded
```

### `ChannelConfig`

```nim
ChannelConfig = object
  kind*: ChannelKind
  capacity*: int
  segmentSize*: int
  maxThreads*: int
  eagerReclaim*: bool
```

### `Sender`

```nim
Sender[T] = object
  core*: ptr ChannelCore[T]
```

### `Receiver`

```nim
Receiver[T] = object
  core*: ptr ChannelCore[T]
```

### `Channel`

```nim
Channel[T] = object
  tx*: Sender[T]
  rx*: Receiver[T]
```


## Constants

### `ChannelTlsMruCapacity`

```nim
ChannelTlsMruCapacity = 32
```

Maximum number of cached channel endpoints per thread to prevent unbounded TLS leakage.


## Procedures & Functions

### `defaultChannelConfig`

```nim
proc defaultChannelConfig(kind: ChannelKind = ckBounded): ChannelConfig {.
    raises: [], tags: [], forbids: [].}
```

Returns sensible default configuration for bounded or unbounded channels.

### ``=destroy``

```nim
proc `=destroy`[T](s: var Sender[T]) {.raises: [].}
```

### ``=copy``

```nim
proc `=copy`[T](dest: var Sender[T]; src: Sender[T])
```

### ``=dup``

```nim
proc `=dup`[T](src: Sender[T]): Sender[T]
```

### ``=destroy``

```nim
proc `=destroy`[T](r: var Receiver[T]) {.raises: [].}
```

### ``=copy``

```nim
proc `=copy`[T](dest: var Receiver[T]; src: Receiver[T])
```

### ``=dup``

```nim
proc `=dup`[T](src: Receiver[T]): Receiver[T]
```

### `newBoundedChannelImpl`

```nim
proc newBoundedChannelImpl[T; N, P, C: static int](): tuple[tx: Sender[T],
    rx: Receiver[T]]
```

### `newUnboundedChannelImpl`

```nim
proc newUnboundedChannelImpl[T; ST: static DeallocationStrategy;
                             S, MaxThreads: static int](): tuple[tx: Sender[T],
    rx: Receiver[T]]
```

### `newBoundedChannel`

```nim
proc newBoundedChannel[T, N: static int](): tuple[tx: Sender[T], rx: Receiver[T]] {.
    inline.}
```

Creates a bounded channel with exact static capacity N.

### `newBoundedChannel`

```nim
proc newBoundedChannel[T](capacity: static int = 1024): tuple[tx: Sender[T],
    rx: Receiver[T]] {.inline.}
```

Creates a bounded channel with static capacity (defaults to 1024).

### `newBoundedChannel`

```nim
proc newBoundedChannel[T](capacity: int): tuple[tx: Sender[T], rx: Receiver[T]]
```

Creates a bounded channel with dynamic capacity coarse tiers (&lt;= 64, &lt;= 1024, else 65536).

### `newChannel`

```nim
proc newChannel[T, N: static int](): tuple[tx: Sender[T], rx: Receiver[T]] {.
    inline.}
```

Alias for newBoundedChannel with exact static capacity N.

### `newChannel`

```nim
proc newChannel[T](capacity: static int = 1024): tuple[tx: Sender[T],
    rx: Receiver[T]] {.inline.}
```

Creates a bounded channel with static capacity (defaults to 1024).

### `newChannel`

```nim
proc newChannel[T](capacity: int): tuple[tx: Sender[T], rx: Receiver[T]] {.
    inline.}
```

Creates a bounded channel with dynamic capacity coarse tiers (&lt;= 64, &lt;= 1024, else 65536).

### `newUnboundedChannel`

```nim
proc newUnboundedChannel[T, S: static int](): tuple[tx: Sender[T],
    rx: Receiver[T]] {.inline.}
```

Creates an unbounded lock-free channel with exact static segment size S.

### `newUnboundedChannel`

```nim
proc newUnboundedChannel[T](segmentSize: static int = 64): tuple[tx: Sender[T],
    rx: Receiver[T]] {.inline.}
```

Creates an unbounded lock-free channel with static segment size (defaults to 64).

### `newUnboundedChannel`

```nim
proc newUnboundedChannel[T](segmentSize: int): tuple[tx: Sender[T],
    rx: Receiver[T]]
```

Creates an unbounded lock-free channel with 1 standard tier (64).

### `newChannel`

```nim
proc newChannel[T](config: ChannelConfig): tuple[tx: Sender[T], rx: Receiver[T]]
```

Creates a channel configured via <tt class="docutils literal"><span class="pre"><span class="Identifier">ChannelConfig</span></span></tt>.

### `channel`

```nim
proc channel[T, N: static int](): Channel[T]
```

### `channel`

```nim
proc channel[T](capacity: static int = 1024): Channel[T]
```

### `channel`

```nim
proc channel[T](capacity: int): Channel[T]
```

### `channel`

```nim
proc channel[T](config: ChannelConfig): Channel[T]
```

### `unboundedChannel`

```nim
proc unboundedChannel[T, S: static int](): Channel[T]
```

### `unboundedChannel`

```nim
proc unboundedChannel[T](segmentSize: static int = 64): Channel[T]
```

### `unboundedChannel`

```nim
proc unboundedChannel[T](segmentSize: int): Channel[T]
```

### `split`

```nim
proc split[T](c: Channel[T]): tuple[tx: Sender[T], rx: Receiver[T]] {.inline.}
```

### `send`

```nim
proc send[T](s: Sender[T]; item: sink T): bool {.inline.}
```

Sends an item into the channel. Automatically registers the calling thread on first call without manual binding ceremonies. Returns true on success, false if channel is closed, all receivers dropped, or bounded channel is full.

### `senders`

```nim
proc senders[T](s: Sender[T]): int {.inline.}
```

### `senders`

```nim
proc senders[T](r: Receiver[T]): int {.inline.}
```

### `receivers`

```nim
proc receivers[T](s: Sender[T]): int {.inline.}
```

### `receivers`

```nim
proc receivers[T](r: Receiver[T]): int {.inline.}
```

### `trySend`

```nim
proc trySend[T](s: Sender[T]; item: sink T): bool {.inline.}
```

Non-blocking send alias.

### `recv`

```nim
proc recv[T](r: Receiver[T]): Option[T] {.inline.}
```

Receives an item from the channel. Automatically registers the calling thread on first call without manual binding ceremonies. Returns some(item) on success, or none(T) if channel is empty.

### `tryRecv`

```nim
proc tryRecv[T](r: Receiver[T]): Option[T] {.inline.}
```

Non-blocking receive alias.

### `close`

```nim
proc close[T](s: Sender[T]) {.inline.}
```

Closes the channel. Subsequent sends return false.

### `close`

```nim
proc close[T](r: Receiver[T]) {.inline.}
```

Closes the channel.

### `isClosed`

```nim
proc isClosed[T](s: Sender[T]): bool {.inline.}
```

### `isClosed`

```nim
proc isClosed[T](r: Receiver[T]): bool {.inline.}
```

### `kind`

```nim
proc kind[T](s: Sender[T]): ChannelKind {.inline.}
```

### `kind`

```nim
proc kind[T](r: Receiver[T]): ChannelKind {.inline.}
```

### `len`

```nim
proc len[T](s: Sender[T]): int {.inline.}
```

### `len`

```nim
proc len[T](r: Receiver[T]): int {.inline.}
```

### `isFull`

```nim
proc isFull[T](s: Sender[T]): bool {.inline.}
```

### `isEmpty`

```nim
proc isEmpty[T](r: Receiver[T]): bool {.inline.}
```

### `send`

```nim
proc send[T](c: Channel[T]; item: sink T): bool {.inline.}
```

### `trySend`

```nim
proc trySend[T](c: Channel[T]; item: sink T): bool {.inline.}
```

### `recv`

```nim
proc recv[T](c: Channel[T]): Option[T] {.inline.}
```

### `tryRecv`

```nim
proc tryRecv[T](c: Channel[T]): Option[T] {.inline.}
```

### `close`

```nim
proc close[T](c: Channel[T]) {.inline.}
```

### `isClosed`

```nim
proc isClosed[T](c: Channel[T]): bool {.inline.}
```

### `len`

```nim
proc len[T](c: Channel[T]): int {.inline.}
```

### `kind`

```nim
proc kind[T](c: Channel[T]): ChannelKind {.inline.}
```

### `isFull`

```nim
proc isFull[T](c: Channel[T]): bool {.inline.}
```

### `isEmpty`

```nim
proc isEmpty[T](c: Channel[T]): bool {.inline.}
```

### `senders`

```nim
proc senders[T](c: Channel[T]): int {.inline.}
```

### `receivers`

```nim
proc receivers[T](c: Channel[T]): int {.inline.}
```


## Macros

### `withEndpoint`

```nim
macro withEndpoint(queue, ep, body: untyped): untyped
```

<p>Smart role-inferring RAII macro.</p>
<p>Inspects <tt class="docutils literal"><span class="pre"><span class="Identifier">body</span></span></tt> AST for <tt class="docutils literal"><span class="pre"><span class="Operator">.</span><span class="Identifier">push</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Operator">.</span><span class="Identifier">pop</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt> calls on <tt class="docutils literal"><span class="pre"><span class="Identifier">ep</span></span></tt> to auto-infer whether to bind a producer or consumer endpoint. Expands to <tt class="docutils literal"><span class="pre"><span class="Identifier">withBoundProducer</span><span class="Punctuation">(</span><span class="Identifier">queue</span><span class="Punctuation">,</span> <span class="Identifier">ep</span><span class="Punctuation">,</span> <span class="Identifier">body</span><span class="Punctuation">)</span></span></tt> or <tt class="docutils literal"><span class="pre"><span class="Identifier">withBoundConsumer</span><span class="Punctuation">(</span><span class="Identifier">queue</span><span class="Punctuation">,</span> <span class="Identifier">ep</span><span class="Punctuation">,</span> <span class="Identifier">body</span><span class="Punctuation">)</span></span></tt>.</p>

