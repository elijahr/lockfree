## # Concurrency Topology: MPMC Synchronous Zero-Buffer Dual Channel (`RendezvousChannel[T]`)
##
## | Dimension              | Architectural Specification                                             |
## |:-----------------------|:------------------------------------------------------------------------|
## | **Topologies**         | MPMC Synchronous Dual Channel (CSP / Go unbuffered `make(chan T)`)       |
## | **Buffer Capacity**    | Strictly Zero (No intermediate ring buffer or linked queue segment)     |
## | **Delivery Model**     | Bilateral 1-to-1 Rendezvous (Sender & receiver must meet in real time)   |
## | **Matching Engine**    | Dual lock-free queue with bilateral CAS arbitration (Scherer & Scott)   |
## | **Thread Suspension**  | OS-native futex (`ulock_wait` on Darwin, `WaitOnAddress`, Linux futex) |
## | **Correlation Tracking**| Monotonic 64-bit correlation IDs for req/rep RPC pair tracing            |
## | **Timeouts**           | Bounded timeouts (`trySend`, `sendWithTimeout`, `tryRecv`, `recvTimeout`)|
## | **Payload Storage**    | Single-owner atomic pointer transfer (`VBox[T]`) under ARC/ORC          |
## | **Cache Alignment**    | Waiter nodes and channel anchors aligned to `CacheLineBytes` (64/128B)   |
## | **Progress Guarantees**| Immediate Match: Lock-Free; Parking Path: Wait-Free Coordination        |
## | **C ABI Interop**      | Full C99 foreign thread support with `lockfree_rendezvous.h` bindings    |
##
## ## Overview
##
## `RendezvousChannel[T]` implements a high-performance synchronous zero-buffer
## dual channel based on William N. Scherer III and Michael L. Scott's dual data
## structures (PPoPP '06).
##
## Senders block until a receiver arrives; receivers block until a sender
## arrives. Data transfer occurs bilaterally between physical threads with zero
## intermediate queue buffering. Monotonic correlation IDs enable deterministic
## request/response tracing.

when not compileOption("threads"):
  {.error: "lockfree/rendezvous requires --threads:on".}

import std/[options, os, times]
when not (defined(macosx) or defined(macos) or defined(ios) or defined(linux) or defined(windows)):
  import std/locks
import ./atomics
import ./atomics/backoff
import ./constants
import ./exceptions

export exceptions.ChannelClosedDefect
export exceptions.RendezvousDefect

const
  CacheLine = constants.CacheLineBytes

when defined(windows):
  proc c_aligned_malloc(size: csize_t, alignment: csize_t): pointer {.importc: "_aligned_malloc", header: "<malloc.h>".}
  proc c_aligned_free(memblock: pointer) {.importc: "_aligned_free", header: "<malloc.h>".}
else:
  proc posix_memalign(memptr: ptr pointer, alignment: csize_t, size: csize_t): cint {.importc, header: "<stdlib.h>".}
  from system/ansi_c import c_free

proc allocSharedAligned*[T](): ptr T =
  when defined(windows):
    let p = c_aligned_malloc(csize_t(sizeof(T)), csize_t(CacheLine))
    if p == nil:
      raise newException(OutOfMemDefect, "_aligned_malloc failed")
  else:
    var p: pointer
    if posix_memalign(addr p, csize_t(CacheLine), csize_t(sizeof(T))) != 0:
      raise newException(OutOfMemDefect, "posix_memalign failed")
  zeroMem(p, sizeof(T))
  result = cast[ptr T](p)

proc freeSharedAligned*(p: pointer) {.inline.} =
  if p == nil: return
  when defined(windows):
    c_aligned_free(p)
  else:
    c_free(p)

proc freeSharedAligned*[T](p: ptr T) {.inline.} =
  freeSharedAligned(cast[pointer](p))

# ---------------------------------------------------------------------------
# Payload Box: VBox[T] (ARC/ORC Refcount Safety)
# ---------------------------------------------------------------------------

type
  VBox*[T] = object
    rc*: Atomic[int32]
    val*: T

proc allocVBox[T](item: sink T): ptr VBox[T] {.inline.} =
  result = allocSharedAligned[VBox[T]]()
  result.rc.store(1, moRelaxed)
  result.val = item

proc decRef[T](box: ptr VBox[T]) {.inline, gcsafe.} =
  if box != nil:
    if box.rc.fetchSub(1, moRelease) == 1:
      threadFence(moAcquire)
      when not (T is SomeNumber or T is bool or T is char or T is pointer or T is ptr):
        {.cast(gcsafe).}:
          `=destroy`(box.val)
      freeSharedAligned(box)

# ---------------------------------------------------------------------------
# Thread Suspension: Parker (OS-native Futex / ulock / WaitOnAddress)
# ---------------------------------------------------------------------------

when defined(macosx) or defined(macos) or defined(ios):
  const
    UL_COMPARE_AND_WAIT = 1'u32

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
  ParkerWakeProc* = proc(arg: pointer) {.nimcall, gcsafe, raises: [].}

  Parker* = object
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

proc initParker*(p: var Parker) {.inline.} =
  when defined(macosx) or defined(macos) or defined(ios):
    p.word.store(0, moRelaxed)
  elif defined(linux) or defined(windows):
    p.word.store(0, moRelaxed)
  else:
    initLock(p.lock)
    initCond(p.cond)
    p.signaled.store(false, moRelaxed)
  p.wakeCb.store(nil, moRelaxed)
  p.wakeArg.store(nil, moRelaxed)

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
  p.wakeCb.store(nil, moRelaxed)
  p.wakeArg.store(nil, moRelaxed)

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
  let arg = p.wakeArg.exchange(nil, moAcquireRelease)
  if arg != nil:
    let cb = cast[ParkerWakeProc](p.wakeCb.load(moAcquire))
    if cb != nil:
      cb(arg)

proc park*(p: var Parker) {.inline.} =
  # Spin-before-park optimization (Section 7.1)
  for _ in 0 ..< 64:
    when defined(macosx) or defined(macos) or defined(ios) or defined(linux) or defined(windows):
      if p.word.load(moAcquire) != 0:
        return
    else:
      if p.signaled.load(moAcquire):
        return
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
      if p.word.load(moAcquire) != 0:
        return true
    else:
      if p.signaled.load(moAcquire):
        return true
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
    let dwMs: uint32 = uint32(timeoutMs)
    if p.word.load(moAcquire) == 0:
      discard WaitOnAddress(cast[pointer](addr p.word), cast[pointer](addr expected), csize_t(sizeof(int32)), dwMs)
    return p.word.load(moAcquire) != 0
  else:
    let deadline = epochTime() + (timeoutMs.float64 / 1000.0)
    while not p.signaled.load(moAcquire):
      let rem = deadline - epochTime()
      if rem <= 0.0:
        return p.signaled.load(moAcquire)
      sleep(1)
    return true

# ---------------------------------------------------------------------------
# Dual Queue Nodes & State Machine
# ---------------------------------------------------------------------------

const
  WaiterPoolCap = 1024
  WaiterPoolMask = uint64(WaiterPoolCap - 1)
  WaiterQuarantine = 512'u64

type
  WaiterMode* = enum
    wmSender       ## Offering a value
    wmReceiver     ## Requesting a value

  RendezvousState* = enum
    rsWaiting      ## Actively enqueued, waiting for partner
    rsMatched      ## Partner arrived and won CAS; data transferred
    rsCancelled    ## Thread timed out or aborted before match

  RendezvousWaiter*[T] = object
    mode*: WaiterMode
    taggedState*: Atomic[uint64]
    lifecycleRc*: Atomic[int32]
    vbox*: Atomic[ptr VBox[T]]
    correlationId*: uint64
    next*: Atomic[ptr RendezvousWaiter[T]]
    poolNext*: Atomic[ptr RendezvousWaiter[T]]
    parker*: Parker

proc makeWaiterTag(epoch: uint64, mode: WaiterMode, st: RendezvousState): uint64 {.inline.} =
  (epoch shl 3) or (uint64(ord(mode)) shl 2) or uint64(ord(st))

proc tagEpoch(tag: uint64): uint64 {.inline.} =
  tag shr 3

proc tagMode(tag: uint64): WaiterMode {.inline.} =
  WaiterMode((tag shr 2) and 1'u64)

proc tagState(tag: uint64): RendezvousState {.inline, raises: [].} =
  RendezvousState(tag and 3'u64)

proc withTagState(tag: uint64, st: RendezvousState): uint64 {.inline, raises: [].} =
  (tag and not 3'u64) or uint64(ord(st))

proc currentState*[T](
    w: ptr RendezvousWaiter[T], order: static MemoryOrder = moAcquire
): RendezvousState {.inline, raises: [].} =
  ## Loads the current `RendezvousState` from the waiter's 64-bit `taggedState`.
  tagState(w.taggedState.load(order))

# ---------------------------------------------------------------------------
# Channel Core & Memory Reclamation
# ---------------------------------------------------------------------------

type
  RendezvousChannelCore*[T] = object
    head*: Atomic[ptr RendezvousWaiter[T]]
    padHead: array[CacheLine - sizeof(Atomic[pointer]), byte]

    tail*: Atomic[ptr RendezvousWaiter[T]]
    padTail: array[CacheLine - sizeof(Atomic[pointer]), byte]

    freeWriteIdx*: Atomic[uint64]
    freeReadIdx*: Atomic[uint64]
    freeSlots*: array[WaiterPoolCap, Atomic[ptr RendezvousWaiter[T]]]
    overflowHead*: Atomic[ptr RendezvousWaiter[T]]

    nextCorrId*: Atomic[uint64]
    nextWaiterEpoch*: Atomic[uint64]
    rc*: Atomic[int]
    isClosed*: Atomic[bool]

  RendezvousChannel*[T] = object
    core*: ptr RendezvousChannelCore[T]

proc pushOverflowWaiter[T](core: ptr RendezvousChannelCore[T], w: ptr RendezvousWaiter[T]) {.inline, raises: [].} =
  var head = core.overflowHead.load(moAcquire)
  while true:
    w.poolNext.store(head, moRelaxed)
    if core.overflowHead.compareExchangeWeak(head, w, moAcquireRelease, moAcquire):
      return

proc pushFreeWaiter[T](core: ptr RendezvousChannelCore[T], w: ptr RendezvousWaiter[T]) {.inline, raises: [].} =
  while true:
    var wIdx = core.freeWriteIdx.load(moAcquire)
    let rIdx = core.freeReadIdx.load(moAcquire)
    if wIdx - rIdx >= uint64(WaiterPoolCap):
      pushOverflowWaiter(core, w)
      return
    let slotIdx = int(wIdx and WaiterPoolMask)
    if core.freeSlots[slotIdx].load(moAcquire) != nil:
      pushOverflowWaiter(core, w)
      return
    if core.freeWriteIdx.compareExchangeWeak(wIdx, wIdx + 1, moAcquireRelease, moRelaxed):
      let prev = core.freeSlots[slotIdx].exchange(w, moAcquireRelease)
      if prev != nil:
        pushOverflowWaiter(core, prev)
      return

proc popFreeWaiter[T](core: ptr RendezvousChannelCore[T]): ptr RendezvousWaiter[T] {.inline, raises: [].} =
  var rIdx = core.freeReadIdx.load(moAcquire)
  let wIdx = core.freeWriteIdx.load(moAcquire)
  if wIdx < rIdx or wIdx - rIdx < WaiterQuarantine:
    return nil
  let slotIdx = int(rIdx and WaiterPoolMask)
  if core.freeSlots[slotIdx].load(moAcquire) == nil:
    return nil
  if core.freeReadIdx.compareExchangeWeak(rIdx, rIdx + 1, moAcquireRelease, moRelaxed):
    return core.freeSlots[slotIdx].exchange(nil, moAcquireRelease)
  return nil

proc releaseWaiter[T](
    core: ptr RendezvousChannelCore[T],
    w: ptr RendezvousWaiter[T],
    count: int32 = 1
) {.inline.} =
  if w == nil:
    return
  if w.lifecycleRc.fetchSub(count, moAcquireRelease) == count:
    pushFreeWaiter(core, w)

proc recycleUnenqueuedWaiter[T](
    core: ptr RendezvousChannelCore[T],
    w: ptr RendezvousWaiter[T]
) {.inline.} =
  if w == nil:
    return
  w.vbox.store(nil, moRelaxed)
  w.lifecycleRc.store(0, moRelaxed)
  pushFreeWaiter(core, w)

proc advanceHead[T](
    core: ptr RendezvousChannelCore[T],
    h: var ptr RendezvousWaiter[T],
    hEpoch: uint64,
    hNext: ptr RendezvousWaiter[T]
): bool {.inline.} =
  if tagEpoch(h.taggedState.load(moAcquire)) != hEpoch:
    return false
  var t = core.tail.load(moAcquire)
  if t == h:
    discard core.tail.compareExchangeStrong(t, hNext, moAcquireRelease, moRelaxed)
  result = core.head.compareExchangeStrong(h, hNext, moAcquireRelease, moRelaxed)
  if result:
    releaseWaiter(core, h, 1)

proc purgeCancelledWaiters[T](core: ptr RendezvousChannelCore[T], maxSpins: int = 16) =
  ## Bounded purge of contiguous rsCancelled waiters from core.head.
  ## Prevents unbounded CAS retry latency under high timeout influx (MED-01).
  var spins = 0
  while spins < maxSpins:
    var h = core.head.load(moAcquire)
    let t = core.tail.load(moAcquire)
    if h == nil or t == nil or h == t:
      break
    let hEpoch = tagEpoch(h.taggedState.load(moAcquire))
    let hNext = h.next.load(moAcquire)
    if hNext == nil or h != core.head.load(moAcquire) or
       tagEpoch(h.taggedState.load(moAcquire)) != hEpoch:
      break
    if tagState(hNext.taggedState.load(moAcquire)) == rsCancelled:
      if advanceHead(core, h, hEpoch, hNext):
        inc spins
      else:
        cpuPause()
        inc spins
    else:
      break

proc allocWaiter[T](
    core: ptr RendezvousChannelCore[T],
    mode: WaiterMode,
    vbox: ptr VBox[T],
    corrId: uint64,
    outEpoch: var uint64
): ptr RendezvousWaiter[T] {.inline.} =
  result = popFreeWaiter(core)
  if result == nil:
    result = allocSharedAligned[RendezvousWaiter[T]]()
    initParker(result.parker)
  else:
    resetParker(result.parker)
  let epoch = core.nextWaiterEpoch.fetchAdd(1, moRelaxed) + 1
  outEpoch = epoch
  result.mode = mode
  result.lifecycleRc.store(3, moRelease)
  result.vbox.store(vbox, moRelease)
  result.correlationId = corrId
  result.next.store(nil, moRelease)
  result.taggedState.store(makeWaiterTag(epoch, mode, rsWaiting), moRelease)

proc initRendezvousChannel*[T](): RendezvousChannel[T] =
  ## Constructs a new zero-buffer MPMC synchronous rendezvous channel.
  let core = allocSharedAligned[RendezvousChannelCore[T]]()

  # Allocate sentinel dummy node (only holds Ref #1: Queue Sentinel Ref)
  let dummy = allocSharedAligned[RendezvousWaiter[T]]()
  initParker(dummy.parker)
  dummy.mode = wmReceiver
  dummy.taggedState.store(makeWaiterTag(1'u64, wmReceiver, rsMatched), moRelaxed)
  dummy.lifecycleRc.store(1, moRelaxed)
  dummy.next.store(nil, moRelaxed)

  core.head.store(dummy, moRelaxed)
  core.tail.store(dummy, moRelaxed)
  core.freeWriteIdx.store(0, moRelaxed)
  core.freeReadIdx.store(0, moRelaxed)
  core.overflowHead.store(nil, moRelaxed)
  core.nextCorrId.store(0, moRelaxed)
  core.nextWaiterEpoch.store(1, moRelaxed)
  core.rc.store(1, moRelaxed)
  core.isClosed.store(false, moRelaxed)
  result.core = core

proc freeChannelCore[T](core: ptr RendezvousChannelCore[T]) =
  if core == nil: return

  # Drain and free active nodes reachable from core.head
  var curr = core.head.load(moRelaxed)
  while curr != nil:
    let nextNode = curr.next.load(moRelaxed)
    let tag = curr.taggedState.load(moRelaxed)
    if tagState(tag) == rsWaiting and tagMode(tag) == wmSender:
      let vb = curr.vbox.exchange(nil, moRelaxed)
      if vb != nil:
        decRef(vb)
    deinitParker(curr.parker)
    freeSharedAligned(curr)
    curr = nextNode

  # Free all pooled waiter nodes in freeSlots
  for i in 0 ..< WaiterPoolCap:
    let pooled = core.freeSlots[i].exchange(nil, moRelaxed)
    if pooled != nil:
      deinitParker(pooled.parker)
      freeSharedAligned(pooled)

  # Free any overflowed waiter nodes in overflowHead
  var ov = core.overflowHead.exchange(nil, moRelaxed)
  while ov != nil:
    let nextOv = ov.poolNext.load(moRelaxed)
    deinitParker(ov.parker)
    freeSharedAligned(ov)
    ov = nextOv

  freeSharedAligned(core)

proc `=destroy`*[T](self: var RendezvousChannel[T]) =
  if self.core != nil:
    if self.core.rc.fetchSub(1, moRelease) == 1:
      threadFence(moAcquire)
      freeChannelCore(self.core)
    self.core = nil

proc `=copy`*[T](dest: var RendezvousChannel[T], src: RendezvousChannel[T]) =
  if dest.core != src.core:
    `=destroy`(dest)
    dest.core = src.core
    if dest.core != nil:
      discard dest.core.rc.fetchAdd(1, moRelaxed)

proc `=sink`*[T](dest: var RendezvousChannel[T], src: RendezvousChannel[T]) =
  if dest.core != src.core:
    `=destroy`(dest)
  dest.core = src.core

proc isNil*[T](self: RendezvousChannel[T]): bool {.inline.} =
  self.core == nil

proc isClosed*[T](self: RendezvousChannel[T]): bool {.inline.} =
  if self.core == nil: true else: self.core.isClosed.load(moAcquire)

proc close*[T](self: RendezvousChannel[T]) =
  ## Closes the rendezvous channel and unparks any waiting threads.
  if self.core != nil:
    if not self.core.isClosed.exchange(true, moAcquireRelease):
      var curr = self.core.head.load(moAcquire)
      while curr != nil:
        let nextNode = curr.next.load(moAcquire)
        var tag = curr.taggedState.load(moAcquire)
        while tagState(tag) == rsWaiting:
          if curr.taggedState.compareExchangeWeak(
            tag, withTagState(tag, rsCancelled), moAcquireRelease, moAcquire
          ):
            curr.parker.unpark()
            releaseWaiter(self.core, curr, 1)
            break
        curr = nextNode

# ---------------------------------------------------------------------------
# Core Operations: send & recv
# ---------------------------------------------------------------------------

proc send*[T](self: RendezvousChannel[T], item: sink T): uint64 =
  ## Synchronously sends `item`, blocking until a receiver consumes it. Returns
  ## the unique monotonic correlation ID for this rendezvous.
  if self.core == nil or self.core.isClosed.load(moAcquire):
    raise newException(ChannelClosedDefect, "RendezvousChannel is closed")

  let core = self.core
  let myVBox = allocVBox(item)
  let corrId = core.nextCorrId.fetchAdd(1, moRelaxed) + 1
  var myWaiter: ptr RendezvousWaiter[T] = nil
  var myEpoch: uint64 = 0

  while true:
    purgeCancelledWaiters(core)
    if core.isClosed.load(moAcquire):
      if myWaiter != nil:
        recycleUnenqueuedWaiter(core, myWaiter)
        myWaiter = nil
      decRef(myVBox)
      raise newException(ChannelClosedDefect, "RendezvousChannel is closed")

    var h = core.head.load(moAcquire)
    var t = core.tail.load(moAcquire)

    if h == nil or t == nil:
      continue

    let hEpoch = tagEpoch(h.taggedState.load(moAcquire))
    let tTag = t.taggedState.load(moAcquire)
    let tEpoch = tagEpoch(tTag)
    var next = t.next.load(moAcquire)
    if t == core.tail.load(moAcquire) and tagEpoch(t.taggedState.load(moAcquire)) == tEpoch:
      if next != nil:
        discard core.tail.compareExchangeWeak(t, next, moAcquireRelease, moRelaxed)
        continue

      if h == t or tagMode(tTag) == wmSender:
        if myWaiter == nil:
          myWaiter = allocWaiter[T](core, wmSender, myVBox, corrId, myEpoch)

        var nilExp: ptr RendezvousWaiter[T] = nil
        if t.next.compareExchangeStrong(nilExp, myWaiter, moAcquireRelease, moRelaxed):
          discard core.tail.compareExchangeWeak(t, myWaiter, moAcquireRelease, moRelaxed)
          let waitTag = makeWaiterTag(myEpoch, wmSender, rsWaiting)
          let cancelTag = makeWaiterTag(myEpoch, wmSender, rsCancelled)
          if core.isClosed.load(moAcquire):
            var expTag = waitTag
            if myWaiter.taggedState.compareExchangeStrong(expTag, cancelTag, moAcquireRelease, moRelaxed):
              myWaiter.parker.unpark()
              releaseWaiter(core, myWaiter, 1)
          # Park until matched or closed
          while not core.isClosed.load(moAcquire):
            myWaiter.parker.park()
            if tagState(myWaiter.taggedState.load(moAcquire)) == rsMatched:
              releaseWaiter(core, myWaiter, 1)
              return corrId
          var expWaiting = waitTag
          if myWaiter.taggedState.compareExchangeStrong(expWaiting, cancelTag, moAcquireRelease, moRelaxed):
            discard myWaiter.vbox.exchange(nil, moAcquireRelease)
            releaseWaiter(core, myWaiter, 2)
            decRef(myVBox)
            purgeCancelledWaiters(core)
            raise newException(ChannelClosedDefect, "RendezvousChannel closed while waiting")
          elif tagState(expWaiting) == rsMatched:
            releaseWaiter(core, myWaiter, 1)
            return corrId
          else:
            discard myWaiter.vbox.exchange(nil, moAcquireRelease)
            releaseWaiter(core, myWaiter, 1)
            decRef(myVBox)
            purgeCancelledWaiters(core)
            raise newException(ChannelClosedDefect, "RendezvousChannel closed while waiting")
      else:
        # Opposite mode: queue has waiting receivers!
        let hNext = h.next.load(moAcquire)
        if h == core.head.load(moAcquire) and hNext != nil and
           tagEpoch(h.taggedState.load(moAcquire)) == hEpoch:
          let hnTag = hNext.taggedState.load(moAcquire)
          if tagMode(hnTag) != wmReceiver:
            if tagState(hnTag) != rsWaiting:
              discard advanceHead(core, h, hEpoch, hNext)
            continue
          if tagState(hnTag) != rsWaiting:
            discard advanceHead(core, h, hEpoch, hNext)
            continue
          var expTag = hnTag
          let matchedTag = withTagState(hnTag, rsMatched)
          if hNext.taggedState.compareExchangeStrong(expTag, matchedTag, moAcquireRelease, moRelaxed):
            if myWaiter != nil:
              recycleUnenqueuedWaiter(core, myWaiter)
              myWaiter = nil
            hNext.correlationId = corrId
            hNext.vbox.store(myVBox, moRelease)
            hNext.parker.unpark()
            discard advanceHead(core, h, hEpoch, hNext)
            releaseWaiter(core, hNext, 1)
            return corrId
          else:
            discard advanceHead(core, h, hEpoch, hNext)

proc recv*[T](self: RendezvousChannel[T], outVal: var T): uint64 =
  ## Synchronously receives an item, blocking until a sender provides it. Stores
  ## payload in `outVal` and returns the matching correlation ID.
  if self.core == nil or self.core.isClosed.load(moAcquire):
    raise newException(ChannelClosedDefect, "RendezvousChannel is closed")

  let core = self.core
  var myWaiter: ptr RendezvousWaiter[T] = nil
  var myEpoch: uint64 = 0

  while true:
    purgeCancelledWaiters(core)
    if core.isClosed.load(moAcquire):
      if myWaiter != nil:
        recycleUnenqueuedWaiter(core, myWaiter)
        myWaiter = nil
      raise newException(ChannelClosedDefect, "RendezvousChannel is closed")

    var h = core.head.load(moAcquire)
    var t = core.tail.load(moAcquire)

    if h == nil or t == nil:
      continue

    let hEpoch = tagEpoch(h.taggedState.load(moAcquire))
    let tTag = t.taggedState.load(moAcquire)
    let tEpoch = tagEpoch(tTag)
    var next = t.next.load(moAcquire)
    if t == core.tail.load(moAcquire) and tagEpoch(t.taggedState.load(moAcquire)) == tEpoch:
      if next != nil:
        discard core.tail.compareExchangeWeak(t, next, moAcquireRelease, moRelaxed)
        continue

      if h == t or tagMode(tTag) == wmReceiver:
        if myWaiter == nil:
          myWaiter = allocWaiter[T](core, wmReceiver, nil, 0, myEpoch)

        var nilExp: ptr RendezvousWaiter[T] = nil
        if t.next.compareExchangeStrong(nilExp, myWaiter, moAcquireRelease, moRelaxed):
          discard core.tail.compareExchangeWeak(t, myWaiter, moAcquireRelease, moRelaxed)
          let waitTag = makeWaiterTag(myEpoch, wmReceiver, rsWaiting)
          let cancelTag = makeWaiterTag(myEpoch, wmReceiver, rsCancelled)
          if core.isClosed.load(moAcquire):
            var expTag = waitTag
            if myWaiter.taggedState.compareExchangeStrong(expTag, cancelTag, moAcquireRelease, moRelaxed):
              myWaiter.parker.unpark()
              releaseWaiter(core, myWaiter, 1)
          while not core.isClosed.load(moAcquire):
            myWaiter.parker.park()
            if tagState(myWaiter.taggedState.load(moAcquire)) == rsMatched:
              while myWaiter.vbox.load(moAcquire) == nil:
                cpuPause()
              let transferred = myWaiter.vbox.exchange(nil, moAcquireRelease)
              outVal = transferred.val
              let cid = myWaiter.correlationId
              decRef(transferred)
              releaseWaiter(core, myWaiter, 1)
              return cid
          var expWaiting = waitTag
          if myWaiter.taggedState.compareExchangeStrong(expWaiting, cancelTag, moAcquireRelease, moRelaxed):
            releaseWaiter(core, myWaiter, 2)
            purgeCancelledWaiters(core)
            raise newException(ChannelClosedDefect, "RendezvousChannel closed while waiting")
          elif tagState(expWaiting) == rsMatched:
            while myWaiter.vbox.load(moAcquire) == nil:
              cpuPause()
            let transferred = myWaiter.vbox.exchange(nil, moAcquireRelease)
            outVal = transferred.val
            let cid = myWaiter.correlationId
            decRef(transferred)
            releaseWaiter(core, myWaiter, 1)
            return cid
          else:
            releaseWaiter(core, myWaiter, 1)
            purgeCancelledWaiters(core)
            raise newException(ChannelClosedDefect, "RendezvousChannel closed while waiting")
      else:
        # Opposite mode: queue has waiting senders!
        let hNext = h.next.load(moAcquire)
        if h == core.head.load(moAcquire) and hNext != nil and
           tagEpoch(h.taggedState.load(moAcquire)) == hEpoch:
          let hnTag = hNext.taggedState.load(moAcquire)
          if tagMode(hnTag) != wmSender:
            if tagState(hnTag) != rsWaiting:
              discard advanceHead(core, h, hEpoch, hNext)
            continue
          if tagState(hnTag) != rsWaiting:
            discard advanceHead(core, h, hEpoch, hNext)
            continue
          var expTag = hnTag
          let matchedTag = withTagState(hnTag, rsMatched)
          if hNext.taggedState.compareExchangeStrong(expTag, matchedTag, moAcquireRelease, moRelaxed):
            if myWaiter != nil:
              recycleUnenqueuedWaiter(core, myWaiter)
              myWaiter = nil
            let transferred = hNext.vbox.exchange(nil, moAcquireRelease)
            outVal = transferred.val
            let cid = hNext.correlationId
            decRef(transferred)
            hNext.parker.unpark()
            discard advanceHead(core, h, hEpoch, hNext)
            releaseWaiter(core, hNext, 1)
            return cid
          else:
            discard advanceHead(core, h, hEpoch, hNext)

proc recv*[T](self: RendezvousChannel[T]): tuple[val: T, correlationId: uint64] {.inline.} =
  var item: T
  let cid = self.recv(item)
  (item, cid)

# ---------------------------------------------------------------------------
# Non-Blocking & Bounded Timeout Primitives
# ---------------------------------------------------------------------------

proc trySend*[T](self: RendezvousChannel[T], item: sink T, outCorrId: var uint64): bool =
  ## Attempts an immediate non-blocking send. Returns true if a receiver was
  ## immediately available to accept the payload, false otherwise.
  if self.core == nil or self.core.isClosed.load(moAcquire):
    return false

  let core = self.core
  purgeCancelledWaiters(core)
  while true:
    var h = core.head.load(moAcquire)
    var t = core.tail.load(moAcquire)

    if h == nil or t == nil or h == t or tagMode(t.taggedState.load(moAcquire)) != wmReceiver:
      return false

    let hEpoch = tagEpoch(h.taggedState.load(moAcquire))
    let hNext = h.next.load(moAcquire)
    if hNext == nil or h != core.head.load(moAcquire) or
       tagEpoch(h.taggedState.load(moAcquire)) != hEpoch:
      return false

    let hnTag = hNext.taggedState.load(moAcquire)
    if tagMode(hnTag) != wmReceiver:
      return false
    if tagState(hnTag) != rsWaiting:
      discard advanceHead(core, h, hEpoch, hNext)
      continue

    var expTag = hnTag
    let matchedTag = withTagState(hnTag, rsMatched)
    if hNext.taggedState.compareExchangeStrong(expTag, matchedTag, moAcquireRelease, moRelaxed):
      let corrId = core.nextCorrId.fetchAdd(1, moRelaxed) + 1
      let myVBox = allocVBox(item)
      hNext.correlationId = corrId
      hNext.vbox.store(myVBox, moRelease)
      hNext.parker.unpark()
      discard advanceHead(core, h, hEpoch, hNext)
      releaseWaiter(core, hNext, 1)
      outCorrId = corrId
      return true
    else:
      discard advanceHead(core, h, hEpoch, hNext)

proc tryRecv*[T](self: RendezvousChannel[T], outVal: var T, outCorrId: var uint64): bool =
  ## Attempts an immediate non-blocking receive. Returns true if a sender was
  ## immediately available with a pending payload, false otherwise.
  if self.core == nil or self.core.isClosed.load(moAcquire):
    return false

  let core = self.core
  purgeCancelledWaiters(core)
  while true:
    var h = core.head.load(moAcquire)
    var t = core.tail.load(moAcquire)

    if h == nil or t == nil or h == t or tagMode(t.taggedState.load(moAcquire)) != wmSender:
      return false

    let hEpoch = tagEpoch(h.taggedState.load(moAcquire))
    let hNext = h.next.load(moAcquire)
    if hNext == nil or h != core.head.load(moAcquire) or
       tagEpoch(h.taggedState.load(moAcquire)) != hEpoch:
      return false

    let hnTag = hNext.taggedState.load(moAcquire)
    if tagMode(hnTag) != wmSender:
      return false
    if tagState(hnTag) != rsWaiting:
      discard advanceHead(core, h, hEpoch, hNext)
      continue

    var expTag = hnTag
    let matchedTag = withTagState(hnTag, rsMatched)
    if hNext.taggedState.compareExchangeStrong(expTag, matchedTag, moAcquireRelease, moRelaxed):
      let transferred = hNext.vbox.exchange(nil, moAcquireRelease)
      outVal = transferred.val
      outCorrId = hNext.correlationId
      decRef(transferred)
      hNext.parker.unpark()
      discard advanceHead(core, h, hEpoch, hNext)
      releaseWaiter(core, hNext, 1)
      return true
    else:
      discard advanceHead(core, h, hEpoch, hNext)

proc sendWithTimeout*[T](
    self: RendezvousChannel[T],
    item: sink T,
    timeoutMs: int,
    outCorrId: var uint64
): bool =
  ## Attempts to send with a bounded timeout.
  if self.trySend(item, outCorrId):
    return true
  if timeoutMs <= 0:
    return false

  let core = self.core
  let myVBox = allocVBox(item)
  let corrId = core.nextCorrId.fetchAdd(1, moRelaxed) + 1
  var myEpoch: uint64 = 0
  let myWaiter = allocWaiter[T](core, wmSender, myVBox, corrId, myEpoch)
  let waitTag = makeWaiterTag(myEpoch, wmSender, rsWaiting)
  let cancelTag = makeWaiterTag(myEpoch, wmSender, rsCancelled)

  # Enqueue waiter
  while true:
    purgeCancelledWaiters(core)
    if core.isClosed.load(moAcquire):
      recycleUnenqueuedWaiter(core, myWaiter)
      decRef(myVBox)
      return false

    var h = core.head.load(moAcquire)
    var t = core.tail.load(moAcquire)
    if h == nil or t == nil: continue

    let hEpoch = tagEpoch(h.taggedState.load(moAcquire))
    let tTag = t.taggedState.load(moAcquire)
    let tEpoch = tagEpoch(tTag)
    var next = t.next.load(moAcquire)
    if t == core.tail.load(moAcquire) and tagEpoch(t.taggedState.load(moAcquire)) == tEpoch:
      if next != nil:
        discard core.tail.compareExchangeWeak(t, next, moAcquireRelease, moRelaxed)
        continue

      if h == t or tagMode(tTag) == wmSender:
        var nilExp: ptr RendezvousWaiter[T] = nil
        if t.next.compareExchangeStrong(nilExp, myWaiter, moAcquireRelease, moRelaxed):
          discard core.tail.compareExchangeWeak(t, myWaiter, moAcquireRelease, moRelaxed)
          if core.isClosed.load(moAcquire):
            var expW = waitTag
            if myWaiter.taggedState.compareExchangeStrong(expW, cancelTag, moAcquireRelease, moRelaxed):
              myWaiter.parker.unpark()
              releaseWaiter(core, myWaiter, 1)
          break
      else:
        # Match head receiver
        let hNext = h.next.load(moAcquire)
        if h == core.head.load(moAcquire) and hNext != nil and
           tagEpoch(h.taggedState.load(moAcquire)) == hEpoch:
          let hnTag = hNext.taggedState.load(moAcquire)
          if tagMode(hnTag) != wmReceiver:
            if tagState(hnTag) != rsWaiting:
              discard advanceHead(core, h, hEpoch, hNext)
            continue
          if tagState(hnTag) != rsWaiting:
            discard advanceHead(core, h, hEpoch, hNext)
            continue
          var expTag = hnTag
          let matchedTag = withTagState(hnTag, rsMatched)
          if hNext.taggedState.compareExchangeStrong(expTag, matchedTag, moAcquireRelease, moRelaxed):
            recycleUnenqueuedWaiter(core, myWaiter)
            hNext.correlationId = corrId
            hNext.vbox.store(myVBox, moRelease)
            hNext.parker.unpark()
            discard advanceHead(core, h, hEpoch, hNext)
            releaseWaiter(core, hNext, 1)
            outCorrId = corrId
            return true
          else:
            discard advanceHead(core, h, hEpoch, hNext)

  # Wait with timeout
  let signaled = myWaiter.parker.parkTimeout(timeoutMs)
  if signaled and tagState(myWaiter.taggedState.load(moAcquire)) == rsMatched:
    releaseWaiter(core, myWaiter, 1)
    outCorrId = corrId
    return true

  # Section 5.1 Timeout Cancellation Race Resolution
  var expWaiting = waitTag
  if myWaiter.taggedState.compareExchangeStrong(expWaiting, cancelTag, moAcquireRelease, moRelaxed):
    discard myWaiter.vbox.exchange(nil, moAcquireRelease)
    decRef(myVBox)
    releaseWaiter(core, myWaiter, 2)
    purgeCancelledWaiters(core)
    return false
  elif tagState(expWaiting) == rsMatched:
    releaseWaiter(core, myWaiter, 1)
    outCorrId = corrId
    return true
  else:
    discard myWaiter.vbox.exchange(nil, moAcquireRelease)
    decRef(myVBox)
    releaseWaiter(core, myWaiter, 1)
    purgeCancelledWaiters(core)
    return false

proc recvWithTimeout*[T](
    self: RendezvousChannel[T],
    outVal: var T,
    timeoutMs: int,
    outCorrId: var uint64
): bool =
  ## Attempts to receive with a bounded timeout.
  if self.tryRecv(outVal, outCorrId):
    return true
  if timeoutMs <= 0:
    return false

  let core = self.core
  var myEpoch: uint64 = 0
  let myWaiter = allocWaiter[T](core, wmReceiver, nil, 0, myEpoch)
  let waitTag = makeWaiterTag(myEpoch, wmReceiver, rsWaiting)
  let cancelTag = makeWaiterTag(myEpoch, wmReceiver, rsCancelled)

  while true:
    purgeCancelledWaiters(core)
    if core.isClosed.load(moAcquire):
      recycleUnenqueuedWaiter(core, myWaiter)
      return false

    var h = core.head.load(moAcquire)
    var t = core.tail.load(moAcquire)
    if h == nil or t == nil: continue

    let hEpoch = tagEpoch(h.taggedState.load(moAcquire))
    let tTag = t.taggedState.load(moAcquire)
    let tEpoch = tagEpoch(tTag)
    var next = t.next.load(moAcquire)
    if t == core.tail.load(moAcquire) and tagEpoch(t.taggedState.load(moAcquire)) == tEpoch:
      if next != nil:
        discard core.tail.compareExchangeWeak(t, next, moAcquireRelease, moRelaxed)
        continue

      if h == t or tagMode(tTag) == wmReceiver:
        var nilExp: ptr RendezvousWaiter[T] = nil
        if t.next.compareExchangeStrong(nilExp, myWaiter, moAcquireRelease, moRelaxed):
          discard core.tail.compareExchangeWeak(t, myWaiter, moAcquireRelease, moRelaxed)
          if core.isClosed.load(moAcquire):
            var expW = waitTag
            if myWaiter.taggedState.compareExchangeStrong(expW, cancelTag, moAcquireRelease, moRelaxed):
              myWaiter.parker.unpark()
              releaseWaiter(core, myWaiter, 1)
          break
      else:
        let hNext = h.next.load(moAcquire)
        if h == core.head.load(moAcquire) and hNext != nil and
           tagEpoch(h.taggedState.load(moAcquire)) == hEpoch:
          let hnTag = hNext.taggedState.load(moAcquire)
          if tagMode(hnTag) != wmSender:
            if tagState(hnTag) != rsWaiting:
              discard advanceHead(core, h, hEpoch, hNext)
            continue
          if tagState(hnTag) != rsWaiting:
            discard advanceHead(core, h, hEpoch, hNext)
            continue
          var expTag = hnTag
          let matchedTag = withTagState(hnTag, rsMatched)
          if hNext.taggedState.compareExchangeStrong(expTag, matchedTag, moAcquireRelease, moRelaxed):
            recycleUnenqueuedWaiter(core, myWaiter)
            let transferred = hNext.vbox.exchange(nil, moAcquireRelease)
            outVal = transferred.val
            outCorrId = hNext.correlationId
            decRef(transferred)
            hNext.parker.unpark()
            discard advanceHead(core, h, hEpoch, hNext)
            releaseWaiter(core, hNext, 1)
            return true
          else:
            discard advanceHead(core, h, hEpoch, hNext)

  let signaled = myWaiter.parker.parkTimeout(timeoutMs)
  if signaled and tagState(myWaiter.taggedState.load(moAcquire)) == rsMatched:
    while myWaiter.vbox.load(moAcquire) == nil:
      cpuPause()
    let transferred = myWaiter.vbox.exchange(nil, moAcquireRelease)
    outVal = transferred.val
    outCorrId = myWaiter.correlationId
    decRef(transferred)
    releaseWaiter(core, myWaiter, 1)
    return true

  var expWaiting = waitTag
  if myWaiter.taggedState.compareExchangeStrong(expWaiting, cancelTag, moAcquireRelease, moRelaxed):
    releaseWaiter(core, myWaiter, 2)
    purgeCancelledWaiters(core)
    return false
  elif tagState(expWaiting) == rsMatched:
    while myWaiter.vbox.load(moAcquire) == nil:
      cpuPause()
    let transferred = myWaiter.vbox.exchange(nil, moAcquireRelease)
    outVal = transferred.val
    outCorrId = myWaiter.correlationId
    decRef(transferred)
    releaseWaiter(core, myWaiter, 1)
    return true
  else:
    releaseWaiter(core, myWaiter, 1)
    purgeCancelledWaiters(core)
    return false

# ---------------------------------------------------------------------------
# Async Bridge Delegation Primitives (Lock-Free Scherer-Scott Dual Queue)
# ---------------------------------------------------------------------------

proc enqueueAsyncSender*[T](
    self: RendezvousChannel[T],
    item: sink T,
    wakeCb: ParkerWakeProc,
    wakeArg: pointer,
    outCorrId: var uint64
): ptr RendezvousWaiter[T] =
  ## Attempts an immediate lock-free match against a waiting receiver in the
  ## dual queue (`result == nil`, `outCorrId > 0`), or enqueues a `wmSender`
  ## waiter node with `wakeCb`/`wakeArg` attached (`result != nil`).
  if self.core == nil or self.core.isClosed.load(moAcquire):
    outCorrId = 0
    return nil

  if self.trySend(item, outCorrId):
    return nil

  let core = self.core
  let myVBox = allocVBox(item)
  let corrId = core.nextCorrId.fetchAdd(1, moRelaxed) + 1
  var myEpoch: uint64 = 0
  let myWaiter = allocWaiter[T](core, wmSender, myVBox, corrId, myEpoch)
  let waitTag = makeWaiterTag(myEpoch, wmSender, rsWaiting)
  let cancelTag = makeWaiterTag(myEpoch, wmSender, rsCancelled)
  myWaiter.parker.wakeCb.store(cast[pointer](wakeCb), moRelease)
  myWaiter.parker.wakeArg.store(wakeArg, moRelease)

  while true:
    purgeCancelledWaiters(core)
    if core.isClosed.load(moAcquire):
      discard myWaiter.parker.wakeArg.exchange(nil, moAcquireRelease)
      myWaiter.taggedState.store(cancelTag, moRelease)
      let vb = myWaiter.vbox.exchange(nil, moAcquireRelease)
      if vb != nil:
        decRef(vb)
      recycleUnenqueuedWaiter(core, myWaiter)
      outCorrId = 0
      return nil

    var h = core.head.load(moAcquire)
    var t = core.tail.load(moAcquire)
    if h == nil or t == nil:
      continue

    let hEpoch = tagEpoch(h.taggedState.load(moAcquire))
    let tTag = t.taggedState.load(moAcquire)
    let tEpoch = tagEpoch(tTag)
    var next = t.next.load(moAcquire)
    if t == core.tail.load(moAcquire) and tagEpoch(t.taggedState.load(moAcquire)) == tEpoch:
      if next != nil:
        discard core.tail.compareExchangeWeak(t, next, moAcquireRelease, moRelaxed)
        continue

      if h == t or tagMode(tTag) == wmSender:
        var nilExp: ptr RendezvousWaiter[T] = nil
        if t.next.compareExchangeStrong(nilExp, myWaiter, moAcquireRelease, moRelaxed):
          discard core.tail.compareExchangeWeak(t, myWaiter, moAcquireRelease, moRelaxed)
          if core.isClosed.load(moAcquire):
            var expW = waitTag
            if myWaiter.taggedState.compareExchangeStrong(expW, cancelTag, moAcquireRelease, moRelaxed):
              myWaiter.parker.unpark()
              releaseWaiter(core, myWaiter, 1)
          outCorrId = corrId
          return myWaiter
      else:
        let hNext = h.next.load(moAcquire)
        if h == core.head.load(moAcquire) and hNext != nil and
           tagEpoch(h.taggedState.load(moAcquire)) == hEpoch:
          let hnTag = hNext.taggedState.load(moAcquire)
          if tagMode(hnTag) != wmReceiver:
            if tagState(hnTag) != rsWaiting:
              discard advanceHead(core, h, hEpoch, hNext)
            continue
          if tagState(hnTag) != rsWaiting:
            discard advanceHead(core, h, hEpoch, hNext)
            continue
          var expTag = hnTag
          let matchedTag = withTagState(hnTag, rsMatched)
          if hNext.taggedState.compareExchangeStrong(expTag, matchedTag, moAcquireRelease, moRelaxed):
            discard myWaiter.parker.wakeArg.exchange(nil, moAcquireRelease)
            myWaiter.taggedState.store(cancelTag, moRelease)
            discard myWaiter.vbox.exchange(nil, moAcquireRelease)
            recycleUnenqueuedWaiter(core, myWaiter)
            hNext.correlationId = corrId
            hNext.vbox.store(myVBox, moRelease)
            hNext.parker.unpark()
            discard advanceHead(core, h, hEpoch, hNext)
            releaseWaiter(core, hNext, 1)
            outCorrId = corrId
            return nil
          else:
            discard advanceHead(core, h, hEpoch, hNext)

proc finishAsyncSender*[T](
    self: RendezvousChannel[T],
    waiter: ptr RendezvousWaiter[T],
    outLeftoverWakeArg: var pointer
): bool =
  ## Resolves bilateral CAS arbitration when an async sender wakes or cancels.
  ## Atomically extracts any unconsumed `wakeArg` into `outLeftoverWakeArg`
  ## before releasing the owner's waiter lifecycle reference.
  var tag = waiter.taggedState.load(moAcquire)
  var wonCancel = false
  while tagState(tag) == rsWaiting:
    if waiter.taggedState.compareExchangeWeak(
      tag, withTagState(tag, rsCancelled), moAcquireRelease, moAcquire
    ):
      wonCancel = true
      break
  outLeftoverWakeArg = waiter.parker.wakeArg.exchange(nil, moAcquireRelease)
  if not wonCancel and tagState(tag) == rsMatched:
    if self.core != nil:
      releaseWaiter(self.core, waiter, 1)
    return true
  let vb = waiter.vbox.exchange(nil, moAcquireRelease)
  if vb != nil:
    decRef(vb)
  if self.core != nil:
    releaseWaiter(self.core, waiter, if wonCancel: 2 else: 1)
    purgeCancelledWaiters(self.core)
  return false

proc finishAsyncSender*[T](
    self: RendezvousChannel[T],
    waiter: ptr RendezvousWaiter[T]
): bool {.inline.} =
  var dummy: pointer = nil
  finishAsyncSender(self, waiter, dummy)

proc enqueueAsyncReceiver*[T](
    self: RendezvousChannel[T],
    wakeCb: ParkerWakeProc,
    wakeArg: pointer,
    outVal: var T,
    outCorrId: var uint64
): ptr RendezvousWaiter[T] =
  ## Attempts an immediate lock-free match against a waiting sender in the dual
  ## queue (`result == nil`, `outCorrId > 0`, `outVal` populated), or enqueues a
  ## `wmReceiver` waiter node with `wakeCb`/`wakeArg` attached (`result != nil`).
  if self.core == nil or self.core.isClosed.load(moAcquire):
    outCorrId = 0
    return nil

  if self.tryRecv(outVal, outCorrId):
    return nil

  let core = self.core
  var myEpoch: uint64 = 0
  let myWaiter = allocWaiter[T](core, wmReceiver, nil, 0, myEpoch)
  let waitTag = makeWaiterTag(myEpoch, wmReceiver, rsWaiting)
  let cancelTag = makeWaiterTag(myEpoch, wmReceiver, rsCancelled)
  myWaiter.parker.wakeCb.store(cast[pointer](wakeCb), moRelease)
  myWaiter.parker.wakeArg.store(wakeArg, moRelease)

  while true:
    purgeCancelledWaiters(core)
    if core.isClosed.load(moAcquire):
      discard myWaiter.parker.wakeArg.exchange(nil, moAcquireRelease)
      myWaiter.taggedState.store(cancelTag, moRelease)
      recycleUnenqueuedWaiter(core, myWaiter)
      outCorrId = 0
      return nil

    var h = core.head.load(moAcquire)
    var t = core.tail.load(moAcquire)
    if h == nil or t == nil:
      continue

    let hEpoch = tagEpoch(h.taggedState.load(moAcquire))
    let tTag = t.taggedState.load(moAcquire)
    let tEpoch = tagEpoch(tTag)
    var next = t.next.load(moAcquire)
    if t == core.tail.load(moAcquire) and tagEpoch(t.taggedState.load(moAcquire)) == tEpoch:
      if next != nil:
        discard core.tail.compareExchangeWeak(t, next, moAcquireRelease, moRelaxed)
        continue

      if h == t or tagMode(tTag) == wmReceiver:
        var nilExp: ptr RendezvousWaiter[T] = nil
        if t.next.compareExchangeStrong(nilExp, myWaiter, moAcquireRelease, moRelaxed):
          discard core.tail.compareExchangeWeak(t, myWaiter, moAcquireRelease, moRelaxed)
          if core.isClosed.load(moAcquire):
            var expW = waitTag
            if myWaiter.taggedState.compareExchangeStrong(expW, cancelTag, moAcquireRelease, moRelaxed):
              myWaiter.parker.unpark()
              releaseWaiter(core, myWaiter, 1)
          outCorrId = 0
          return myWaiter
      else:
        let hNext = h.next.load(moAcquire)
        if h == core.head.load(moAcquire) and hNext != nil and
           tagEpoch(h.taggedState.load(moAcquire)) == hEpoch:
          let hnTag = hNext.taggedState.load(moAcquire)
          if tagMode(hnTag) != wmSender:
            if tagState(hnTag) != rsWaiting:
              discard advanceHead(core, h, hEpoch, hNext)
            continue
          if tagState(hnTag) != rsWaiting:
            discard advanceHead(core, h, hEpoch, hNext)
            continue
          var expTag = hnTag
          let matchedTag = withTagState(hnTag, rsMatched)
          if hNext.taggedState.compareExchangeStrong(expTag, matchedTag, moAcquireRelease, moRelaxed):
            discard myWaiter.parker.wakeArg.exchange(nil, moAcquireRelease)
            myWaiter.taggedState.store(cancelTag, moRelease)
            recycleUnenqueuedWaiter(core, myWaiter)
            let transferred = hNext.vbox.exchange(nil, moAcquireRelease)
            outVal = transferred.val
            outCorrId = hNext.correlationId
            decRef(transferred)
            hNext.parker.unpark()
            discard advanceHead(core, h, hEpoch, hNext)
            releaseWaiter(core, hNext, 1)
            return nil
          else:
            discard advanceHead(core, h, hEpoch, hNext)

proc finishAsyncReceiver*[T](
    self: RendezvousChannel[T],
    waiter: ptr RendezvousWaiter[T],
    outVal: var T,
    outCorrId: var uint64,
    outLeftoverWakeArg: var pointer
): bool =
  ## Resolves bilateral CAS arbitration when an async receiver wakes or cancels.
  ## Atomically extracts any unconsumed `wakeArg` into `outLeftoverWakeArg`
  ## before releasing the owner's waiter lifecycle reference.
  var tag = waiter.taggedState.load(moAcquire)
  var wonCancel = false
  while tagState(tag) == rsWaiting:
    if waiter.taggedState.compareExchangeWeak(
      tag, withTagState(tag, rsCancelled), moAcquireRelease, moAcquire
    ):
      wonCancel = true
      break
  outLeftoverWakeArg = waiter.parker.wakeArg.exchange(nil, moAcquireRelease)
  if not wonCancel and tagState(tag) == rsMatched:
    while waiter.vbox.load(moAcquire) == nil:
      cpuPause()
    let transferred = waiter.vbox.exchange(nil, moAcquireRelease)
    outVal = transferred.val
    outCorrId = waiter.correlationId
    decRef(transferred)
    if self.core != nil:
      releaseWaiter(self.core, waiter, 1)
    return true
  if self.core != nil:
    releaseWaiter(self.core, waiter, if wonCancel: 2 else: 1)
    purgeCancelledWaiters(self.core)
  return false

proc finishAsyncReceiver*[T](
    self: RendezvousChannel[T],
    waiter: ptr RendezvousWaiter[T],
    outVal: var T,
    outCorrId: var uint64
): bool {.inline.} =
  var dummy: pointer = nil
  finishAsyncReceiver(self, waiter, outVal, outCorrId, dummy)

# ---------------------------------------------------------------------------
# Syntactic Sugar Operators
# ---------------------------------------------------------------------------

template `<<-`*[T](chan: RendezvousChannel[T], val: T) =
  discard chan.send(val)

template `->>`*[T](chan: RendezvousChannel[T], target: var T) =
  discard chan.recv(target)
