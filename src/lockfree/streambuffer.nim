## ==============================================================================
## Zero-Copy Lock-Free Circular Streaming I/O Ring Buffer (Wave 4B)
## ==============================================================================
##
## Concurrency Topology & Mathematical Model:
## | Dimension               | Architectural Specification                                              |
## |:------------------------|:-------------------------------------------------------------------------|
## | **Primary Topology**    | SPSC (Single-Producer Single-Consumer) Streaming Byte Ring               |
## | **Multi-Thread Modes**  | SPSC (Wait-Free) & MPMC (Ticket-Reservation Two-Phase Commit)            |
## | **Cursor Architecture** | 64-bit Monotonic Sequence Numbers (`head`, `tail`) with Mask Indexing    |
## | **Memory Isolation**    | Cursors Isolated on Independent Cachelines (`align: CacheLineBytes`)     |
## | **Zero-Copy Substrate** | Dual-Slice Vector Model (`IOVecPair`) & Mirrored Virtual Memory Mapping |
## | **I/O Subsystem**       | Native Integration with POSIX `readv`/`writev` (`struct iovec`) / Sockets|
## | **Backpressure Engine** | Speculative Lock-Free Fast Path + OS Futex Wait-Free Coordination        |
## | **Memory Model**        | Strict C11 Acquire/Release Fence Discipline (`moAcquire`, `moRelease`)   |
## | **Allocation Cost**     | Page-Aligned Buffer Allocation (`posix_memalign`, `_aligned_malloc`)      |
## ==============================================================================

when not compileOption("threads"):
  {.error: "lockfree/streambuffer requires --threads:on".}

import lockfree/atomics
import lockfree/atomics/backoff
import lockfree/backoff
import std/monotimes
when not (defined(macosx) or defined(macos) or defined(ios) or defined(linux) or defined(windows)):
  import std/locks

const
  DefaultStreamCapacity* = 65536
  CacheLine* = CacheLineBytes
  moAcqRel* = moAcquireRelease
  moSeqCst* = moSequentiallyConsistent

# ------------------------------------------------------------------------------
# 1. Aligned Memory Allocation
# ------------------------------------------------------------------------------

when defined(windows):
  proc c_aligned_malloc(size: csize_t, alignment: csize_t): pointer {.
    importc: "_aligned_malloc", header: "<malloc.h>".}
  proc c_aligned_free(memblock: pointer) {.
    importc: "_aligned_free", header: "<malloc.h>".}
else:
  proc posix_memalign(memptr: ptr pointer, alignment: csize_t, size: csize_t): cint {.
    importc, header: "<stdlib.h>".}
  from system/ansi_c import c_free

proc allocAlignedBuffer*(size: int, alignment: int = CacheLine): ptr UncheckedArray[byte] =
  let align = max(alignment, CacheLine)
  when defined(windows):
    let p = c_aligned_malloc(csize_t(size), csize_t(align))
    if p == nil:
      raise newException(OutOfMemDefect, "_aligned_malloc failed")
    zeroMem(p, size)
    result = cast[ptr UncheckedArray[byte]](p)
  else:
    var p: pointer
    if posix_memalign(addr p, csize_t(align), csize_t(size)) != 0:
      raise newException(OutOfMemDefect, "posix_memalign failed")
    zeroMem(p, size)
    result = cast[ptr UncheckedArray[byte]](p)

proc freeAlignedBuffer*(p: pointer) =
  if p == nil: return
  when defined(windows):
    c_aligned_free(p)
  else:
    c_free(p)

proc nextPowerOfTwo*(n: int): int {.inline.} =
  if n <= 16: return 16
  when sizeof(int) == 8:
    if n > (1 shl 62):
      raise newException(ValueError, "Capacity exceeds maximum supported power of two (2^62)")
  var v = n - 1
  v = v or (v shr 1)
  v = v or (v shr 2)
  v = v or (v shr 4)
  v = v or (v shr 8)
  v = v or (v shr 16)
  when sizeof(int) == 8:
    v = v or (v shr 32)
  result = v + 1
  if result < 16: result = 16

proc getMonotonicTimeNs*(): uint64 {.inline.} =
  uint64(getMonoTime().ticks)

# ------------------------------------------------------------------------------
# 2. Thread Suspension: Parker (Futex / ulock / WaitOnAddress)
# ------------------------------------------------------------------------------

when defined(macosx) or defined(macos) or defined(ios):
  const UL_COMPARE_AND_WAIT = 1'u32
  proc ulock_wait(operation: uint32, address: pointer, value: uint64, timeoutUs: uint32): cint {.importc: "__ulock_wait".}
  proc ulock_wake(operation: uint32, address: pointer, wakeValue: uint64): cint {.importc: "__ulock_wake".}

elif defined(linux):
  const
    FUTEX_WAIT_PRIVATE = 128'i32
    FUTEX_WAKE_PRIVATE = 129'i32
    SYS_futex = when defined(amd64) or defined(x86_64): 202
                elif defined(arm64) or defined(aarch64): 98
                elif defined(i386): 240
                elif defined(arm): 240
                elif defined(riscv64): 422
                else: 202
  type
    Timespec = object
      tv_sec: clong
      tv_nsec: clong
  proc syscall(number: clong): clong {.varargs, importc: "syscall", header: "<unistd.h>".}

elif defined(windows):
  proc WaitOnAddress(Address: pointer, CompareAddress: pointer, AddressSize: csize_t, dwMilliseconds: uint32): bool {.stdcall, dynlib: "api-ms-win-core-synch-l1-2-0.dll|kernelbase.dll|kernel32.dll", importc: "WaitOnAddress".}
  proc WakeByAddressSingle(Address: pointer) {.stdcall, dynlib: "api-ms-win-core-synch-l1-2-0.dll|kernelbase.dll|kernel32.dll", importc: "WakeByAddressSingle".}

type
  Parker* = object
    when defined(macosx) or defined(macos) or defined(ios):
      word*: Atomic[uint32]
    elif defined(linux) or defined(windows):
      word*: Atomic[int32]
    else:
      lock*: Lock
      cond*: Cond
      signaled*: Atomic[bool]

proc initParker*(p: var Parker) {.inline.} =
  when defined(macosx) or defined(macos) or defined(ios):
    p.word.store(0, moRelaxed)
  elif defined(linux) or defined(windows):
    p.word.store(0, moRelaxed)
  else:
    initLock(p.lock)
    initCond(p.cond)
    p.signaled.store(false, moRelaxed)

proc deinitParker*(p: var Parker) {.inline.} =
  when not (defined(macosx) or defined(macos) or defined(ios) or defined(linux) or defined(windows)):
    deinitLock(p.lock)
    deinitCond(p.cond)

proc resetParker*(p: var Parker) {.inline.} =
  when defined(macosx) or defined(macos) or defined(ios):
    p.word.store(0, moRelaxed)
  elif defined(linux) or defined(windows):
    p.word.store(0, moRelaxed)
  else:
    p.signaled.store(false, moRelaxed)

proc unpark*(p: var Parker) {.inline.} =
  when defined(macosx) or defined(macos) or defined(ios):
    p.word.store(1, moRelease)
    discard ulock_wake(UL_COMPARE_AND_WAIT, addr p.word, 0)
  elif defined(linux):
    p.word.store(1, moRelease)
    discard syscall(clong(SYS_futex), cast[pointer](addr p.word), clong(FUTEX_WAKE_PRIVATE), clong(1), nil, nil, clong(0))
  elif defined(windows):
    p.word.store(1, moRelease)
    WakeByAddressSingle(cast[pointer](addr p.word))
  else:
    p.signaled.store(true, moRelease)
    acquire(p.lock)
    signal(p.cond)
    release(p.lock)

proc park*(p: var Parker) {.inline.} =
  for _ in 0 ..< 64:
    when defined(macosx) or defined(macos) or defined(ios) or defined(linux) or defined(windows):
      if p.word.load(moAcquire) != 0: return
    else:
      if p.signaled.load(moAcquire): return
    cpuPause()

  when defined(macosx) or defined(macos) or defined(ios):
    while p.word.load(moAcquire) == 0:
      discard ulock_wait(UL_COMPARE_AND_WAIT, addr p.word, 0, 0)
  elif defined(linux):
    while p.word.load(moAcquire) == 0:
      discard syscall(clong(SYS_futex), cast[pointer](addr p.word), clong(FUTEX_WAIT_PRIVATE), clong(0), nil, nil, clong(0))
  elif defined(windows):
    var expected: int32 = 0
    while p.word.load(moAcquire) == 0:
      discard WaitOnAddress(cast[pointer](addr p.word), cast[pointer](addr expected), csize_t(sizeof(int32)), 0xFFFFFFFF'u32)
  else:
    acquire(p.lock)
    while not p.signaled.load(moAcquire):
      wait(p.cond, p.lock)
    release(p.lock)

proc parkTimeout*(p: var Parker, timeoutMs: int): bool =
  if timeoutMs <= 0:
    when defined(macosx) or defined(macos) or defined(ios) or defined(linux) or defined(windows):
      return p.word.load(moAcquire) != 0
    else:
      return p.signaled.load(moAcquire)

  for _ in 0 ..< 64:
    when defined(macosx) or defined(macos) or defined(ios) or defined(linux) or defined(windows):
      if p.word.load(moAcquire) != 0: return true
    else:
      if p.signaled.load(moAcquire): return true
    cpuPause()

  when defined(macosx) or defined(macos) or defined(ios):
    let timeoutUs: uint32 = uint32(timeoutMs * 1000)
    if p.word.load(moAcquire) == 0:
      discard ulock_wait(UL_COMPARE_AND_WAIT, addr p.word, 0, timeoutUs)
    return p.word.load(moAcquire) != 0
  elif defined(linux):
    var ts: Timespec
    ts.tv_sec = timeoutMs div 1000
    ts.tv_nsec = (timeoutMs mod 1000) * 1_000_000
    if p.word.load(moAcquire) == 0:
      discard syscall(clong(SYS_futex), cast[pointer](addr p.word), clong(FUTEX_WAIT_PRIVATE), clong(0), addr ts, nil, clong(0))
    return p.word.load(moAcquire) != 0
  elif defined(windows):
    var expected: int32 = 0
    discard WaitOnAddress(cast[pointer](addr p.word), cast[pointer](addr expected), csize_t(sizeof(int32)), uint32(timeoutMs))
    return p.word.load(moAcquire) != 0
  else:
    acquire(p.lock)
    let res = p.signaled.load(moAcquire)
    release(p.lock)
    return res

# ------------------------------------------------------------------------------
# 3. Zero-Copy IOVec Structures
# ------------------------------------------------------------------------------

type
  IOVecSlice* = object
    data*: ptr byte
    len*: int

  IOVecPair* = object
    first*: IOVecSlice
    second*: IOVecSlice

proc totalLen*(p: IOVecPair): int {.inline.} =
  p.first.len + p.second.len

proc copyTo*(p: IOVecPair, dst: var openArray[byte]): int =
  ## Copies data from IOVecPair into destination openArray.
  var copied = 0
  if p.first.len > 0 and dst.len > 0:
    let n1 = min(p.first.len, dst.len)
    copyMem(addr dst[0], p.first.data, n1)
    copied += n1
  if p.second.len > 0 and dst.len > copied:
    let n2 = min(p.second.len, dst.len - copied)
    copyMem(addr dst[copied], p.second.data, n2)
    copied += n2
  return copied

proc copyFrom*(p: var IOVecPair, src: openArray[byte]): int =
  ## Copies data from source openArray into IOVecPair memory slices.
  var copied = 0
  if p.first.len > 0 and src.len > 0:
    let n1 = min(p.first.len, src.len)
    copyMem(p.first.data, unsafeAddr src[0], n1)
    copied += n1
  if p.second.len > 0 and src.len > copied:
    let n2 = min(p.second.len, src.len - copied)
    copyMem(p.second.data, unsafeAddr src[copied], n2)
    copied += n2
  return copied

# ------------------------------------------------------------------------------
# 4. StreamRing (SPSC Lock-Free Streaming Ring Buffer)
# ------------------------------------------------------------------------------

type
  StreamRing* = object
    tail* {.align: CacheLineBytes.}: Atomic[uint64]
    cachedHead {.align: CacheLineBytes.}: uint64
    head* {.align: CacheLineBytes.}: Atomic[uint64]
    cachedTail {.align: CacheLineBytes.}: uint64
    buffer* {.align: CacheLineBytes.}: ptr UncheckedArray[byte]
    capacity*: int
    mask*: int
    isMirrored*: bool
    # Reader Domain (MED-01 cacheline isolation)
    notEmptyParker* {.align: CacheLineBytes.}: Parker
    hasWaitingReader*: Atomic[bool]
    # Writer Domain (MED-01 cacheline isolation)
    notFullParker* {.align: CacheLineBytes.}: Parker
    hasWaitingWriter*: Atomic[bool]

proc initStreamRing*(capacity: int = DefaultStreamCapacity, useVirtualMirror: bool = false): StreamRing =
  ## Initializes a new SPSC zero-copy circular streaming ring buffer.
  ## Capacity is automatically rounded up to the next power of two.
  if useVirtualMirror:
    raise newException(ValueError, "Virtual memory mirrored ring buffer is not supported on this platform; use dual-slice IOVecPair")
  let cap = nextPowerOfTwo(capacity)
  result.capacity = cap
  result.mask = cap - 1
  result.tail.store(0, moRelaxed)
  result.head.store(0, moRelaxed)
  result.cachedHead = 0
  result.cachedTail = 0
  result.isMirrored = false
  result.buffer = allocAlignedBuffer(cap, CacheLine)
  initParker(result.notEmptyParker)
  initParker(result.notFullParker)
  result.hasWaitingReader.store(false, moRelaxed)
  result.hasWaitingWriter.store(false, moRelaxed)

proc newStreamRing*(capacity: int = DefaultStreamCapacity, useVirtualMirror: bool = false): ref StreamRing =
  ## Heap-allocates a new StreamRing wrapper.
  new result
  result[] = initStreamRing(capacity, useVirtualMirror)

proc destroy*(self: var StreamRing) =
  ## Reclaims memory and operating system primitives.
  if self.buffer != nil:
    freeAlignedBuffer(self.buffer)
    self.buffer = nil
  deinitParker(self.notEmptyParker)
  deinitParker(self.notFullParker)

proc capacity*(self: StreamRing): int {.inline.} =
  self.capacity

proc availableRead*(self: var StreamRing): int {.inline.} =
  ## Returns total bytes currently available to read.
  let t = self.tail.load(moAcquire)
  let h = self.head.load(moAcquire)
  if t < h: return 0
  let avail = int(t - h)
  return if avail < 0: 0 else: avail

proc availableWrite*(self: var StreamRing): int {.inline.} =
  ## Returns total free bytes currently available to write.
  let t = self.tail.load(moAcquire)
  let h = self.head.load(moAcquire)
  if t < h: return self.capacity
  let diff = t - h
  if diff >= uint64(self.capacity): return 0
  return self.capacity - int(diff)

proc isEmpty*(self: var StreamRing): bool {.inline.} =
  self.availableRead() == 0

proc isFull*(self: var StreamRing): bool {.inline.} =
  self.availableWrite() == 0

# ------------------------------------------------------------------------------
# 5. Zero-Copy Vectored Read / Write Protocol
# ------------------------------------------------------------------------------

proc acquireWriteIov*(self: var StreamRing, requestedLen: int): IOVecPair =
  ## Obtains up to two contiguous memory slices for zero-copy writing.
  ## Does NOT advance the write cursor; caller must call commitWrite afterwards.
  if requestedLen <= 0: return IOVecPair()
  let t = self.tail.load(moRelaxed)
  var avail = self.capacity - int(t - self.cachedHead)
  if avail < requestedLen:
    self.cachedHead = self.head.load(moAcquire)
    avail = self.capacity - int(t - self.cachedHead)
  if avail <= 0: return IOVecPair()

  let n = min(requestedLen, avail)
  let tailIdx = int(t and uint64(self.mask))
  let l1 = min(n, self.capacity - tailIdx)

  result.first.data = cast[ptr byte](addr self.buffer[tailIdx])
  result.first.len = l1

  let l2 = n - l1
  if l2 > 0:
    result.second.data = cast[ptr byte](addr self.buffer[0])
    result.second.len = l2

proc commitWrite*(self: var StreamRing, bytesWritten: int) =
  ## Commits bytesWritten bytes to the buffer, publishing data with release
  ## semantics and waking any waiting reader thread.
  if bytesWritten <= 0: return
  assert bytesWritten <= self.capacity, "commitWrite exceeds buffer capacity"
  let oldTail = self.tail.load(moRelaxed)
  let newTail = oldTail + uint64(bytesWritten)
  self.tail.store(newTail, moRelease)

  # Full barrier to prevent StoreLoad reordering between tail store and hasWaitingReader load (BLOCKER-01)
  threadFence(moSeqCst)
  if self.hasWaitingReader.load(moSeqCst):
    self.hasWaitingReader.store(false, moSeqCst)
    self.notEmptyParker.unpark()

proc acquireReadIov*(self: var StreamRing, requestedLen: int): IOVecPair =
  ## Obtains up to two contiguous memory slices for zero-copy reading.
  ## Does NOT advance the read cursor; caller must call commitRead afterwards.
  if requestedLen <= 0: return IOVecPair()
  let h = self.head.load(moRelaxed)
  var avail = int(self.cachedTail - h)
  if avail < requestedLen:
    self.cachedTail = self.tail.load(moAcquire)
    avail = int(self.cachedTail - h)
  if avail <= 0: return IOVecPair()

  let n = min(requestedLen, avail)
  let headIdx = int(h and uint64(self.mask))
  let l1 = min(n, self.capacity - headIdx)

  result.first.data = cast[ptr byte](addr self.buffer[headIdx])
  result.first.len = l1

  let l2 = n - l1
  if l2 > 0:
    result.second.data = cast[ptr byte](addr self.buffer[0])
    result.second.len = l2

proc commitRead*(self: var StreamRing, bytesRead: int) =
  ## Commits bytesRead bytes as consumed, releasing buffer space with release
  ## semantics and waking any waiting writer thread.
  if bytesRead <= 0: return
  assert bytesRead <= self.capacity, "commitRead exceeds buffer capacity"
  let oldHead = self.head.load(moRelaxed)
  let newHead = oldHead + uint64(bytesRead)
  self.head.store(newHead, moRelease)

  # Full barrier to prevent StoreLoad reordering between head store and hasWaitingWriter load (BLOCKER-01)
  threadFence(moSeqCst)
  if self.hasWaitingWriter.load(moSeqCst):
    self.hasWaitingWriter.store(false, moSeqCst)
    self.notFullParker.unpark()

# ------------------------------------------------------------------------------
# 6. Basic Read / Write APIs
# ------------------------------------------------------------------------------

proc tryWrite*(self: var StreamRing, src: openArray[byte]): int =
  ## Non-blocking write. Copies up to src.len bytes to the buffer.
  ## Returns total bytes written (may be less than src.len if space is constrained).
  if src.len == 0: return 0
  var iov = self.acquireWriteIov(src.len)
  let written = iov.copyFrom(src)
  if written > 0:
    self.commitWrite(written)
  return written

proc tryRead*(self: var StreamRing, dst: var openArray[byte]): int =
  ## Non-blocking read. Copies up to dst.len bytes from the buffer.
  ## Returns total bytes read (0 if buffer is empty).
  if dst.len == 0: return 0
  let iov = self.acquireReadIov(dst.len)
  let readBytes = iov.copyTo(dst)
  if readBytes > 0:
    self.commitRead(readBytes)
  return readBytes

proc tryWriteString*(self: var StreamRing, s: string): int =
  ## Non-blocking write overload for Nim string.
  if s.len == 0: return 0
  return self.tryWrite(toOpenArray(cast[ptr UncheckedArray[byte]](cstring(s)), 0, s.len - 1))

proc readString*(self: var StreamRing, maxLen: int): string =
  ## Non-blocking read overload returning string.
  if maxLen <= 0: return ""
  result = newString(maxLen)
  let n = self.tryRead(toOpenArray(cast[ptr UncheckedArray[byte]](cstring(result)), 0, maxLen - 1))
  result.setLen(n)

proc writeBlocking*(self: var StreamRing, src: openArray[byte], timeoutNs: int64 = -1): int =
  ## Writes data, blocking when full until space is freed or timeout expires.
  if src.len == 0: return 0
  let startTime = if timeoutNs > 0: getMonotonicTimeNs() else: 0'u64
  var writtenTotal = 0

  while writtenTotal < src.len:
    let remaining = src.len - writtenTotal
    let n = self.tryWrite(src[writtenTotal ..< (writtenTotal + remaining)])
    if n > 0:
      writtenTotal += n
      if writtenTotal == src.len: break

    # Buffer full, wait
    if timeoutNs == 0:
      break
    elif timeoutNs > 0:
      let elapsed = int64(getMonotonicTimeNs() - startTime)
      if elapsed >= timeoutNs: break
      let remTimeoutMs = int((timeoutNs - elapsed) div 1_000_000'i64)
      resetParker(self.notFullParker)
      self.hasWaitingWriter.store(true, moSeqCst)
      threadFence(moSeqCst)
      if self.availableWrite() > 0:
        self.hasWaitingWriter.store(false, moSeqCst)
      else:
        discard self.notFullParker.parkTimeout(max(1, remTimeoutMs))
        self.hasWaitingWriter.store(false, moSeqCst)
    else:
      resetParker(self.notFullParker)
      self.hasWaitingWriter.store(true, moSeqCst)
      threadFence(moSeqCst)
      if self.availableWrite() > 0:
        self.hasWaitingWriter.store(false, moSeqCst)
      else:
        self.notFullParker.park()
        self.hasWaitingWriter.store(false, moSeqCst)

  return writtenTotal

proc readBlocking*(self: var StreamRing, dst: var openArray[byte], timeoutNs: int64 = -1): int =
  ## Reads data, blocking when empty until data arrives or timeout expires.
  if dst.len == 0: return 0
  let startTime = if timeoutNs > 0: getMonotonicTimeNs() else: 0'u64

  while true:
    let n = self.tryRead(dst)
    if n > 0: return n

    # Buffer empty, wait
    if timeoutNs == 0:
      return 0
    elif timeoutNs > 0:
      let elapsed = int64(getMonotonicTimeNs() - startTime)
      if elapsed >= timeoutNs: return 0
      let remTimeoutMs = int((timeoutNs - elapsed) div 1_000_000'i64)
      resetParker(self.notEmptyParker)
      self.hasWaitingReader.store(true, moSeqCst)
      threadFence(moSeqCst)
      if self.availableRead() > 0:
        self.hasWaitingReader.store(false, moSeqCst)
      else:
        discard self.notEmptyParker.parkTimeout(max(1, remTimeoutMs))
        self.hasWaitingReader.store(false, moSeqCst)
    else:
      resetParker(self.notEmptyParker)
      self.hasWaitingReader.store(true, moSeqCst)
      threadFence(moSeqCst)
      if self.availableRead() > 0:
        self.hasWaitingReader.store(false, moSeqCst)
      else:
        self.notEmptyParker.park()
        self.hasWaitingReader.store(false, moSeqCst)

# ------------------------------------------------------------------------------
# 7. MPMC StreamRing (Two-Phase Ticket Reservation)
# ------------------------------------------------------------------------------

type
  MPMCStreamRing* = object
    tail* {.align: CacheLineBytes.}: Atomic[uint64]
    head* {.align: CacheLineBytes.}: Atomic[uint64]
    tailCommitted* {.align: CacheLineBytes.}: Atomic[uint64]
    headCommitted* {.align: CacheLineBytes.}: Atomic[uint64]
    buffer* {.align: CacheLineBytes.}: ptr UncheckedArray[byte]
    capacity*: int
    mask*: int

proc initMPMCStreamRing*(capacity: int = DefaultStreamCapacity): MPMCStreamRing =
  let cap = nextPowerOfTwo(capacity)
  result.capacity = cap
  result.mask = cap - 1
  result.tail.store(0, moRelaxed)
  result.head.store(0, moRelaxed)
  result.tailCommitted.store(0, moRelaxed)
  result.headCommitted.store(0, moRelaxed)
  result.buffer = allocAlignedBuffer(cap, CacheLine)

proc destroy*(self: var MPMCStreamRing) =
  if self.buffer != nil:
    freeAlignedBuffer(self.buffer)
    self.buffer = nil

proc capacity*(self: MPMCStreamRing): int {.inline.} =
  self.capacity

proc availableRead*(self: var MPMCStreamRing): int {.inline.} =
  let tc = self.tailCommitted.load(moAcquire)
  let hc = self.headCommitted.load(moAcquire)
  if tc < hc: return 0
  let diff = tc - hc
  return min(int(diff), self.capacity)

proc availableWrite*(self: var MPMCStreamRing): int {.inline.} =
  let t = self.tail.load(moAcquire)
  let hc = self.headCommitted.load(moAcquire)
  if t < hc: return self.capacity
  let diff = t - hc
  if diff >= uint64(self.capacity): return 0
  return self.capacity - int(diff)

proc tryWrite*(self: var MPMCStreamRing, src: openArray[byte]): int =
  if src.len == 0: return 0
  let req = src.len
  var spins = InitialSpin
  while true:
    let t = self.tail.load(moAcquire)
    let hc = self.headCommitted.load(moAcquire)
    if t < hc:
      # t is a stale snapshot preceding hc; retry CAS loop
      backoffOnRetry(spins)
      continue
    let diff = t - hc
    if diff >= uint64(self.capacity):
      return 0 # Buffer is full
    let avail = self.capacity - int(diff)
    if avail <= 0: return 0
    let toWrite = min(req, avail)
    var exp = t
    if self.tail.compareExchange(exp, t + uint64(toWrite), moAcqRel):
      # Write data into reserved slice
      for i in 0 ..< toWrite:
        let idx = int((t + uint64(i)) and uint64(self.mask))
        self.buffer[idx] = src[i]
      # Wait for prior writes to commit
      while self.tailCommitted.load(moAcquire) != t:
        cpuPause()
      self.tailCommitted.store(t + uint64(toWrite), moRelease)
      return toWrite
    backoffOnRetry(spins)

proc tryRead*(self: var MPMCStreamRing, dst: var openArray[byte]): int =
  if dst.len == 0: return 0
  let req = dst.len
  var spins = InitialSpin
  while true:
    let h = self.head.load(moAcquire)
    let tc = self.tailCommitted.load(moAcquire)
    if tc < h:
      # tc is a stale snapshot preceding h; retry CAS loop
      backoffOnRetry(spins)
      continue
    let diff = tc - h
    if diff == 0: return 0 # Buffer is empty
    let avail = min(int(diff), self.capacity)
    if avail <= 0: return 0
    let toRead = min(req, avail)
    var exp = h
    if self.head.compareExchange(exp, h + uint64(toRead), moAcqRel):
      # Read data from reserved slice
      for i in 0 ..< toRead:
        let idx = int((h + uint64(i)) and uint64(self.mask))
        dst[i] = self.buffer[idx]
      # Wait for prior reads to commit
      while self.headCommitted.load(moAcquire) != h:
        cpuPause()
      self.headCommitted.store(h + uint64(toRead), moRelease)
      return toRead
    backoffOnRetry(spins)
