---
title: "lockfree/streambuffer"
description: "API reference for lockfree/streambuffer"
---

<p>Concurrency Topology &amp; Mathematical Model:</p>
<table border="1" class="docutils"><tr><th>Dimension</th><th>Architectural Specification</th></tr>
<tr><td><strong>Primary Topology</strong></td><td>SPSC (Single-Producer Single-Consumer) Streaming Byte Ring</td></tr>
<tr><td><strong>Multi-Thread Modes</strong></td><td>SPSC (Wait-Free) &amp; MPMC (Ticket-Reservation Two-Phase Commit)</td></tr>
<tr><td><strong>Cursor Architecture</strong></td><td>64-bit Monotonic Sequence Numbers (<tt class="docutils literal"><span class="pre"><span class="Identifier">head</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">tail</span></span></tt>) with Mask Indexing</td></tr>
<tr><td><strong>Memory Isolation</strong></td><td>Cursors Isolated on Independent Cachelines (<tt class="docutils literal"><span class="pre"><span class="Identifier">align</span><span class="Punctuation">:</span> <span class="Identifier">CacheLineBytes</span></span></tt>)</td></tr>
<tr><td><strong>Zero-Copy Substrate</strong></td><td>Dual-Slice Vector Model (<tt class="docutils literal"><span class="pre"><span class="Identifier">IOVecPair</span></span></tt>) &amp; Mirrored Virtual Memory Mapping</td></tr>
<tr><td><strong>I/O Subsystem</strong></td><td>Native Integration with POSIX <tt class="docutils literal"><span class="pre"><span class="Identifier">readv</span></span></tt>/<tt class="docutils literal"><span class="pre"><span class="Identifier">writev</span></span></tt> (<tt class="docutils literal"><span class="pre"><span class="Identifier">struct</span> <span class="Identifier">iovec</span></span></tt>) / Sockets</td></tr>
<tr><td><strong>Backpressure Engine</strong></td><td>Speculative Lock-Free Fast Path + OS Futex Wait-Free Coordination</td></tr>
<tr><td><strong>Memory Model</strong></td><td>Strict C11 Acquire/Release Fence Discipline (<tt class="docutils literal"><span class="pre"><span class="Identifier">moAcquire</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">moRelease</span></span></tt>)</td></tr>
<tr><td><strong>Allocation Cost</strong></td><td>Page-Aligned Buffer Allocation (<tt class="docutils literal"><span class="pre"><span class="Identifier">posix_memalign</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">_aligned_malloc</span></span></tt>)</td></tr>
</table><p>==============================================================================</p>


## Types

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
```

### `IOVecSlice`

```nim
IOVecSlice = object
  data*: ptr byte
  len*: int
```

### `IOVecPair`

```nim
IOVecPair = object
  first*: IOVecSlice
  second*: IOVecSlice
```

### `StreamRing`

```nim
StreamRing = object
  tail* {.align: 128.}: Atomic[uint64]
  head* {.align: 128.}: Atomic[uint64]
  buffer* {.align: 128.}: ptr UncheckedArray[byte]
  capacity*: int
  mask*: int
  isMirrored*: bool
  notEmptyParker* {.align: 128.}: Parker
  hasWaitingReader*: Atomic[bool]
  notFullParker* {.align: 128.}: Parker
  hasWaitingWriter*: Atomic[bool]
```

### `MPMCStreamRing`

```nim
MPMCStreamRing = object
  tail* {.align: 128.}: Atomic[uint64]
  head* {.align: 128.}: Atomic[uint64]
  tailCommitted* {.align: 128.}: Atomic[uint64]
  headCommitted* {.align: 128.}: Atomic[uint64]
  buffer* {.align: 128.}: ptr UncheckedArray[byte]
  capacity*: int
  mask*: int
```


## Constants

### `DefaultStreamCapacity`

```nim
DefaultStreamCapacity = 65536
```

### `CacheLine`

```nim
CacheLine = 128
```

### `moAcqRel`

```nim
moAcqRel = moAcquireRelease
```

### `moSeqCst`

```nim
moSeqCst = moSequentiallyConsistent
```


## Procedures & Functions

### `allocAlignedBuffer`

```nim
proc allocAlignedBuffer(size: int; alignment: int = CacheLine): ptr UncheckedArray[
    byte] {.raises: [], tags: [], forbids: [].}
```

### `freeAlignedBuffer`

```nim
proc freeAlignedBuffer(p: pointer) {.raises: [], tags: [], forbids: [].}
```

### `nextPowerOfTwo`

```nim
proc nextPowerOfTwo(n: int): int {.inline, raises: [ValueError], tags: [],
                                   forbids: [].}
```

### `getMonotonicTimeNs`

```nim
proc getMonotonicTimeNs(): uint64 {.inline, raises: [], tags: [TimeEffect],
                                    forbids: [].}
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
proc unpark(p: var Parker) {.inline, raises: [], tags: [], forbids: [].}
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

### `totalLen`

```nim
proc totalLen(p: IOVecPair): int {.inline, raises: [], tags: [], forbids: [].}
```

### `copyTo`

```nim
proc copyTo(p: IOVecPair; dst: var openArray[byte]): int {.raises: [], tags: [],
    forbids: [].}
```

Copies data from IOVecPair into destination openArray.

### `copyFrom`

```nim
proc copyFrom(p: var IOVecPair; src: openArray[byte]): int {.raises: [],
    tags: [], forbids: [].}
```

Copies data from source openArray into IOVecPair memory slices.

### `initStreamRing`

```nim
proc initStreamRing(capacity: int = DefaultStreamCapacity;
                    useVirtualMirror: bool = false): StreamRing {.
    raises: [ValueError], tags: [], forbids: [].}
```

Initializes a new SPSC zero-copy circular streaming ring buffer. Capacity is automatically rounded up to the next power of two.

### `newStreamRing`

```nim
proc newStreamRing(capacity: int = DefaultStreamCapacity;
                   useVirtualMirror: bool = false): ref StreamRing {.
    raises: [ValueError], tags: [], forbids: [].}
```

Heap-allocates a new StreamRing wrapper.

### `destroy`

```nim
proc destroy(self: var StreamRing) {.raises: [], tags: [], forbids: [].}
```

Reclaims memory and operating system primitives.

### `capacity`

```nim
proc capacity(self: StreamRing): int {.inline, raises: [], tags: [], forbids: [].}
```

### `availableRead`

```nim
proc availableRead(self: var StreamRing): int {.inline, raises: [], tags: [],
    forbids: [].}
```

Returns total bytes currently available to read.

### `availableWrite`

```nim
proc availableWrite(self: var StreamRing): int {.inline, raises: [], tags: [],
    forbids: [].}
```

Returns total free bytes currently available to write.

### `isEmpty`

```nim
proc isEmpty(self: var StreamRing): bool {.inline, raises: [], tags: [],
    forbids: [].}
```

### `isFull`

```nim
proc isFull(self: var StreamRing): bool {.inline, raises: [], tags: [],
    forbids: [].}
```

### `acquireWriteIov`

```nim
proc acquireWriteIov(self: var StreamRing; requestedLen: int): IOVecPair {.
    raises: [], tags: [], forbids: [].}
```

Obtains up to two contiguous memory slices for zero-copy writing. Does NOT advance the write cursor; caller must call commitWrite afterwards.

### `commitWrite`

```nim
proc commitWrite(self: var StreamRing; bytesWritten: int) {.raises: [],
    tags: [], forbids: [].}
```

Commits bytesWritten bytes to the buffer, publishing data with release semantics and waking any waiting reader thread.

### `acquireReadIov`

```nim
proc acquireReadIov(self: var StreamRing; requestedLen: int): IOVecPair {.
    raises: [], tags: [], forbids: [].}
```

Obtains up to two contiguous memory slices for zero-copy reading. Does NOT advance the read cursor; caller must call commitRead afterwards.

### `commitRead`

```nim
proc commitRead(self: var StreamRing; bytesRead: int) {.raises: [], tags: [],
    forbids: [].}
```

Commits bytesRead bytes as consumed, releasing buffer space with release semantics and waking any waiting writer thread.

### `tryWrite`

```nim
proc tryWrite(self: var StreamRing; src: openArray[byte]): int {.raises: [],
    tags: [], forbids: [].}
```

Non-blocking write. Copies up to src.len bytes to the buffer. Returns total bytes written (may be less than src.len if space is constrained).

### `tryRead`

```nim
proc tryRead(self: var StreamRing; dst: var openArray[byte]): int {.raises: [],
    tags: [], forbids: [].}
```

Non-blocking read. Copies up to dst.len bytes from the buffer. Returns total bytes read (0 if buffer is empty).

### `tryWriteString`

```nim
proc tryWriteString(self: var StreamRing; s: string): int {.raises: [],
    tags: [], forbids: [].}
```

Non-blocking write overload for Nim string.

### `readString`

```nim
proc readString(self: var StreamRing; maxLen: int): string {.raises: [],
    tags: [], forbids: [].}
```

Non-blocking read overload returning string.

### `writeBlocking`

```nim
proc writeBlocking(self: var StreamRing; src: openArray[byte];
                   timeoutNs: int64 = -1): int {.raises: [], tags: [TimeEffect],
    forbids: [].}
```

Writes data, blocking when full until space is freed or timeout expires.

### `readBlocking`

```nim
proc readBlocking(self: var StreamRing; dst: var openArray[byte];
                  timeoutNs: int64 = -1): int {.raises: [], tags: [TimeEffect],
    forbids: [].}
```

Reads data, blocking when empty until data arrives or timeout expires.

### `initMPMCStreamRing`

```nim
proc initMPMCStreamRing(capacity: int = DefaultStreamCapacity): MPMCStreamRing {.
    raises: [ValueError], tags: [], forbids: [].}
```

### `destroy`

```nim
proc destroy(self: var MPMCStreamRing) {.raises: [], tags: [], forbids: [].}
```

### `capacity`

```nim
proc capacity(self: MPMCStreamRing): int {.inline, raises: [], tags: [],
    forbids: [].}
```

### `availableRead`

```nim
proc availableRead(self: var MPMCStreamRing): int {.inline, raises: [],
    tags: [], forbids: [].}
```

### `availableWrite`

```nim
proc availableWrite(self: var MPMCStreamRing): int {.inline, raises: [],
    tags: [], forbids: [].}
```

### `tryWrite`

```nim
proc tryWrite(self: var MPMCStreamRing; src: openArray[byte]): int {.raises: [],
    tags: [], forbids: [].}
```

### `tryRead`

```nim
proc tryRead(self: var MPMCStreamRing; dst: var openArray[byte]): int {.
    raises: [], tags: [], forbids: [].}
```

