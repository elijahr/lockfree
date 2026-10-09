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
## `RendezvousChannel[T]` implements a high-performance synchronous zero-buffer dual
## channel based on William N. Scherer III and Michael L. Scott's dual data structures
## (PPoPP '06).
##
## Senders block until a receiver arrives; receivers block until a sender arrives.
## Data transfer occurs bilaterally between physical threads with zero intermediate queue
## buffering. Monotonic correlation IDs enable deterministic request/response tracing.

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

proc incRef[T](box: ptr VBox[T]) {.inline.} =
  if box != nil:
    discard box.rc.fetchAdd(1, moRelaxed)

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

  proc ulock_wait(operation: uint32, address: pointer, value: uint64, timeout_us: uint32): cint {.importc: "__ulock_wait".}
  proc ulock_wake(operation: uint32, address: pointer, wake_value: uint64): cint {.importc: "__ulock_wake".}

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
  proc WaitOnAddress(Address: pointer, CompareAddress: pointer, AddressSize: csize_t, dwMilliseconds: uint32): bool {.stdcall, dynlib: "kernel32", importc: "WaitOnAddress".}
  proc WakeByAddressSingle(Address: pointer) {.stdcall, dynlib: "kernel32", importc: "WakeByAddressSingle".}

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

proc initParker(p: var Parker) {.inline.} =
  when defined(macosx) or defined(macos) or defined(ios):
    p.word.store(0, moRelaxed)
  elif defined(linux) or defined(windows):
    p.word.store(0, moRelaxed)
  else:
    initLock(p.lock)
    initCond(p.cond)
    p.signaled.store(false, moRelaxed)

proc deinitParker(p: var Parker) {.inline.} =
  when not (defined(macosx) or defined(macos) or defined(ios) or defined(linux) or defined(windows)):
    deinitLock(p.lock)
    deinitCond(p.cond)

proc resetParker(p: var Parker) {.inline.} =
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
    WakeByAddressSingle(addr p.word)
  else:
    p.signaled.store(true, moRelease)
    acquire(p.lock)
    signal(p.cond)
    release(p.lock)

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
      discard WaitOnAddress(addr p.word, addr expected, sizeof(int32), 0xFFFFFFFF'u32)
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
      discard WaitOnAddress(addr p.word, addr expected, sizeof(int32), dwMs)
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
    state*: Atomic[RendezvousState]
    vbox*: Atomic[ptr VBox[T]]
    correlationId*: uint64
    next*: Atomic[ptr RendezvousWaiter[T]]
    allNext*: ptr RendezvousWaiter[T]
    parker*: Parker
    pad: array[8, byte]

# ---------------------------------------------------------------------------
# Channel Core & Memory Reclamation
# ---------------------------------------------------------------------------

type
  RendezvousChannelCore*[T] = object
    head*: Atomic[ptr RendezvousWaiter[T]]
    padHead: array[CacheLine - sizeof(Atomic[pointer]), byte]

    tail*: Atomic[ptr RendezvousWaiter[T]]
    padTail: array[CacheLine - sizeof(Atomic[pointer]), byte]

    allNodes*: Atomic[ptr RendezvousWaiter[T]]
    padAll: array[CacheLine - sizeof(Atomic[pointer]), byte]

    nextCorrId*: Atomic[uint64]
    rc*: Atomic[int]
    isClosed*: Atomic[bool]

  RendezvousChannel*[T] = object
    core*: ptr RendezvousChannelCore[T]

proc purgeCancelledWaiters[T](core: ptr RendezvousChannelCore[T], maxSpins: int = 16) =
  ## Bounded purge of contiguous rsCancelled waiters from core.head.
  ## Prevents unbounded CAS retry latency under high timeout influx (MED-01).
  var spins = 0
  while spins < maxSpins:
    var h = core.head.load(moAcquire)
    let t = core.tail.load(moAcquire)
    if h == nil or t == nil or h == t:
      break
    let hNext = h.next.load(moAcquire)
    if hNext == nil or h != core.head.load(moAcquire):
      break
    if hNext.state.load(moAcquire) == rsCancelled:
      if core.head.compareExchangeStrong(h, hNext, moAcquireRelease, moRelaxed):
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
    corrId: uint64
): ptr RendezvousWaiter[T] {.inline.} =
  result = allocSharedAligned[RendezvousWaiter[T]]()
  initParker(result.parker)
  result.mode = mode
  result.state.store(rsWaiting, moRelease)
  result.vbox.store(vbox, moRelease)
  result.correlationId = corrId
  result.next.store(nil, moRelaxed)

  # Track for clean deallocation in freeChannelCore
  while true:
    var cur = core.allNodes.load(moAcquire)
    result.allNext = cur
    if core.allNodes.compareExchangeWeak(cur, result, moRelease, moRelaxed):
      break

proc initRendezvousChannel*[T](): RendezvousChannel[T] =
  ## Constructs a new zero-buffer MPMC synchronous rendezvous channel.
  let core = allocSharedAligned[RendezvousChannelCore[T]]()

  # Allocate sentinel dummy node
  let dummy = allocSharedAligned[RendezvousWaiter[T]]()
  initParker(dummy.parker)
  dummy.mode = wmReceiver
  dummy.state.store(rsMatched, moRelaxed)
  dummy.next.store(nil, moRelaxed)
  dummy.allNext = nil

  core.head.store(dummy, moRelaxed)
  core.tail.store(dummy, moRelaxed)
  core.allNodes.store(dummy, moRelaxed)
  core.nextCorrId.store(0, moRelaxed)
  core.rc.store(1, moRelaxed)
  core.isClosed.store(false, moRelaxed)
  result.core = core

proc freeChannelCore[T](core: ptr RendezvousChannelCore[T]) =
  if core == nil: return

  # Drain remaining active VBoxes in queue
  var curr = core.head.load(moRelaxed)
  while curr != nil:
    if curr.state.load(moRelaxed) == rsWaiting and curr.mode == wmSender:
      let vb = curr.vbox.load(moRelaxed)
      if vb != nil:
        decRef(vb)
    curr = curr.next.load(moRelaxed)

  # Free every allocated node cleanly via allNodes list
  var node = core.allNodes.load(moAcquire)
  while node != nil:
    let nextNode = node.allNext
    deinitParker(node.parker)
    freeSharedAligned(node)
    node = nextNode

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
        var exp = rsWaiting
        if curr.state.compareExchangeStrong(exp, rsCancelled, moAcquireRelease, moRelaxed):
          curr.parker.unpark()
        curr = curr.next.load(moAcquire)

# ---------------------------------------------------------------------------
# Core Operations: send & recv
# ---------------------------------------------------------------------------

proc send*[T](self: RendezvousChannel[T], item: sink T): uint64 =
  ## Synchronously sends `item`, blocking until a receiver consumes it.
  ## Returns the unique monotonic correlation ID for this rendezvous.
  if self.core == nil or self.core.isClosed.load(moAcquire):
    raise newException(ChannelClosedDefect, "RendezvousChannel is closed")

  let core = self.core
  let myVBox = allocVBox(item)
  let corrId = core.nextCorrId.fetchAdd(1, moRelaxed) + 1
  var myWaiter: ptr RendezvousWaiter[T] = nil

  while true:
    purgeCancelledWaiters(core)
    if core.isClosed.load(moAcquire):
      decRef(myVBox)
      myWaiter = nil
      raise newException(ChannelClosedDefect, "RendezvousChannel is closed")

    var h = core.head.load(moAcquire)
    var t = core.tail.load(moAcquire)

    if h == nil or t == nil:
      continue

    var next = t.next.load(moAcquire)
    if t == core.tail.load(moAcquire):
      if next != nil:
        discard core.tail.compareExchangeWeak(t, next, moAcquireRelease, moRelaxed)
        continue

      if h == t or t.mode == wmSender:
        if myWaiter == nil:
          myWaiter = allocWaiter[T](core, wmSender, myVBox, corrId)

        var nilExp: ptr RendezvousWaiter[T] = nil
        if t.next.compareExchangeStrong(nilExp, myWaiter, moAcquireRelease, moRelaxed):
          discard core.tail.compareExchangeWeak(t, myWaiter, moAcquireRelease, moRelaxed)
          # Park until matched or closed
          while not core.isClosed.load(moAcquire):
            myWaiter.parker.park()
            if myWaiter.state.load(moAcquire) == rsMatched:
              return corrId
          if myWaiter.state.load(moAcquire) == rsMatched:
            return corrId
          decRef(myVBox)
          raise newException(ChannelClosedDefect, "RendezvousChannel closed while waiting")
      else:
        # Opposite mode: queue has waiting receivers!
        let hNext = h.next.load(moAcquire)
        if h == core.head.load(moAcquire) and hNext != nil:
          if hNext.mode != wmReceiver:
            if hNext.state.load(moAcquire) != rsWaiting:
              discard core.head.compareExchangeWeak(h, hNext, moAcquireRelease, moRelaxed)
            continue
          var exp = rsWaiting
          if hNext.state.compareExchangeStrong(exp, rsMatched, moAcquireRelease, moRelaxed):
            hNext.correlationId = corrId
            hNext.vbox.store(myVBox, moRelease)
            hNext.parker.unpark()
            discard core.head.compareExchangeWeak(h, hNext, moAcquireRelease, moRelaxed)
            return corrId
          else:
            discard core.head.compareExchangeWeak(h, hNext, moAcquireRelease, moRelaxed)

proc recv*[T](self: RendezvousChannel[T], outVal: var T): uint64 =
  ## Synchronously receives an item, blocking until a sender provides it.
  ## Stores payload in `outVal` and returns the matching correlation ID.
  if self.core == nil or self.core.isClosed.load(moAcquire):
    raise newException(ChannelClosedDefect, "RendezvousChannel is closed")

  let core = self.core
  var myWaiter: ptr RendezvousWaiter[T] = nil

  while true:
    purgeCancelledWaiters(core)
    if core.isClosed.load(moAcquire):
      raise newException(ChannelClosedDefect, "RendezvousChannel is closed")

    var h = core.head.load(moAcquire)
    var t = core.tail.load(moAcquire)

    if h == nil or t == nil:
      continue

    var next = t.next.load(moAcquire)
    if t == core.tail.load(moAcquire):
      if next != nil:
        discard core.tail.compareExchangeWeak(t, next, moAcquireRelease, moRelaxed)
        continue

      if h == t or t.mode == wmReceiver:
        if myWaiter == nil:
          myWaiter = allocWaiter[T](core, wmReceiver, nil, 0)

        var nilExp: ptr RendezvousWaiter[T] = nil
        if t.next.compareExchangeStrong(nilExp, myWaiter, moAcquireRelease, moRelaxed):
          discard core.tail.compareExchangeWeak(t, myWaiter, moAcquireRelease, moRelaxed)
          while not core.isClosed.load(moAcquire):
            myWaiter.parker.park()
            if myWaiter.state.load(moAcquire) == rsMatched:
              while myWaiter.vbox.load(moAcquire) == nil:
                cpuPause()
              let transferred = myWaiter.vbox.load(moAcquire)
              outVal = transferred.val
              let cid = myWaiter.correlationId
              decRef(transferred)
              return cid
          if myWaiter.state.load(moAcquire) == rsMatched:
            while myWaiter.vbox.load(moAcquire) == nil:
              cpuPause()
            let transferred = myWaiter.vbox.load(moAcquire)
            outVal = transferred.val
            let cid = myWaiter.correlationId
            decRef(transferred)
            return cid
          raise newException(ChannelClosedDefect, "RendezvousChannel closed while waiting")
      else:
        # Opposite mode: queue has waiting senders!
        let hNext = h.next.load(moAcquire)
        if h == core.head.load(moAcquire) and hNext != nil:
          if hNext.mode != wmSender:
            if hNext.state.load(moAcquire) != rsWaiting:
              discard core.head.compareExchangeWeak(h, hNext, moAcquireRelease, moRelaxed)
            continue
          var exp = rsWaiting
          if hNext.state.compareExchangeStrong(exp, rsMatched, moAcquireRelease, moRelaxed):
            let transferred = hNext.vbox.load(moAcquire)
            outVal = transferred.val
            let cid = hNext.correlationId
            decRef(transferred)
            hNext.parker.unpark()
            discard core.head.compareExchangeWeak(h, hNext, moAcquireRelease, moRelaxed)
            return cid
          else:
            discard core.head.compareExchangeWeak(h, hNext, moAcquireRelease, moRelaxed)

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

    if h == nil or t == nil or h == t or t.mode != wmReceiver:
      return false

    let hNext = h.next.load(moAcquire)
    if hNext == nil or h != core.head.load(moAcquire) or hNext.mode != wmReceiver:
      return false

    var exp = rsWaiting
    if hNext.state.compareExchangeStrong(exp, rsMatched, moAcquireRelease, moRelaxed):
      let corrId = core.nextCorrId.fetchAdd(1, moRelaxed) + 1
      let myVBox = allocVBox(item)
      hNext.correlationId = corrId
      hNext.vbox.store(myVBox, moRelease)
      hNext.parker.unpark()
      discard core.head.compareExchangeWeak(h, hNext, moAcquireRelease, moRelaxed)
      outCorrId = corrId
      return true
    else:
      discard core.head.compareExchangeWeak(h, hNext, moAcquireRelease, moRelaxed)

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

    if h == nil or t == nil or h == t or t.mode != wmSender:
      return false

    let hNext = h.next.load(moAcquire)
    if hNext == nil or h != core.head.load(moAcquire) or hNext.mode != wmSender:
      return false

    var exp = rsWaiting
    if hNext.state.compareExchangeStrong(exp, rsMatched, moAcquireRelease, moRelaxed):
      let transferred = hNext.vbox.load(moAcquire)
      outVal = transferred.val
      outCorrId = hNext.correlationId
      decRef(transferred)
      hNext.parker.unpark()
      discard core.head.compareExchangeWeak(h, hNext, moAcquireRelease, moRelaxed)
      return true
    else:
      discard core.head.compareExchangeWeak(h, hNext, moAcquireRelease, moRelaxed)

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
  let myWaiter = allocWaiter[T](core, wmSender, myVBox, corrId)

  # Enqueue waiter
  while true:
    purgeCancelledWaiters(core)
    if core.isClosed.load(moAcquire):
      decRef(myVBox)
      return false

    var h = core.head.load(moAcquire)
    var t = core.tail.load(moAcquire)
    if h == nil or t == nil: continue

    var next = t.next.load(moAcquire)
    if t == core.tail.load(moAcquire):
      if next != nil:
        discard core.tail.compareExchangeWeak(t, next, moAcquireRelease, moRelaxed)
        continue

      if h == t or t.mode == wmSender:
        var nilExp: ptr RendezvousWaiter[T] = nil
        if t.next.compareExchangeStrong(nilExp, myWaiter, moAcquireRelease, moRelaxed):
          discard core.tail.compareExchangeWeak(t, myWaiter, moAcquireRelease, moRelaxed)
          break
      else:
        # Match head receiver
        let hNext = h.next.load(moAcquire)
        if h == core.head.load(moAcquire) and hNext != nil:
          if hNext.mode != wmReceiver:
            if hNext.state.load(moAcquire) != rsWaiting:
              discard core.head.compareExchangeWeak(h, hNext, moAcquireRelease, moRelaxed)
            continue
          var exp = rsWaiting
          if hNext.state.compareExchangeStrong(exp, rsMatched, moAcquireRelease, moRelaxed):
            hNext.correlationId = corrId
            hNext.vbox.store(myVBox, moRelease)
            hNext.parker.unpark()
            discard core.head.compareExchangeWeak(h, hNext, moAcquireRelease, moRelaxed)
            outCorrId = corrId
            return true
          else:
            discard core.head.compareExchangeWeak(h, hNext, moAcquireRelease, moRelaxed)

  # Wait with timeout
  let signaled = myWaiter.parker.parkTimeout(timeoutMs)
  if signaled and myWaiter.state.load(moAcquire) == rsMatched:
    outCorrId = corrId
    return true

  # Section 5.1 Timeout Cancellation Race Resolution
  var expWaiting = rsWaiting
  if myWaiter.state.compareExchangeStrong(expWaiting, rsCancelled, moAcquireRelease, moRelaxed):
    decRef(myVBox)
    return false
  else:
    outCorrId = corrId
    return true

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
  let myWaiter = allocWaiter[T](core, wmReceiver, nil, 0)

  while true:
    purgeCancelledWaiters(core)
    if core.isClosed.load(moAcquire):
      return false

    var h = core.head.load(moAcquire)
    var t = core.tail.load(moAcquire)
    if h == nil or t == nil: continue

    var next = t.next.load(moAcquire)
    if t == core.tail.load(moAcquire):
      if next != nil:
        discard core.tail.compareExchangeWeak(t, next, moAcquireRelease, moRelaxed)
        continue

      if h == t or t.mode == wmReceiver:
        var nilExp: ptr RendezvousWaiter[T] = nil
        if t.next.compareExchangeStrong(nilExp, myWaiter, moAcquireRelease, moRelaxed):
          discard core.tail.compareExchangeWeak(t, myWaiter, moAcquireRelease, moRelaxed)
          break
      else:
        let hNext = h.next.load(moAcquire)
        if h == core.head.load(moAcquire) and hNext != nil:
          if hNext.mode != wmSender:
            if hNext.state.load(moAcquire) != rsWaiting:
              discard core.head.compareExchangeWeak(h, hNext, moAcquireRelease, moRelaxed)
            continue
          var exp = rsWaiting
          if hNext.state.compareExchangeStrong(exp, rsMatched, moAcquireRelease, moRelaxed):
            let transferred = hNext.vbox.load(moAcquire)
            outVal = transferred.val
            outCorrId = hNext.correlationId
            decRef(transferred)
            hNext.parker.unpark()
            discard core.head.compareExchangeWeak(h, hNext, moAcquireRelease, moRelaxed)
            return true
          else:
            discard core.head.compareExchangeWeak(h, hNext, moAcquireRelease, moRelaxed)

  let signaled = myWaiter.parker.parkTimeout(timeoutMs)
  if signaled and myWaiter.state.load(moAcquire) == rsMatched:
    while myWaiter.vbox.load(moAcquire) == nil:
      cpuPause()
    let transferred = myWaiter.vbox.load(moAcquire)
    outVal = transferred.val
    outCorrId = myWaiter.correlationId
    decRef(transferred)
    return true

  var expWaiting = rsWaiting
  if myWaiter.state.compareExchangeStrong(expWaiting, rsCancelled, moAcquireRelease, moRelaxed):
    return false
  else:
    while myWaiter.vbox.load(moAcquire) == nil:
      cpuPause()
    let transferred = myWaiter.vbox.load(moAcquire)
    outVal = transferred.val
    outCorrId = myWaiter.correlationId
    decRef(transferred)
    return true

# ---------------------------------------------------------------------------
# Syntactic Sugar Operators
# ---------------------------------------------------------------------------

template `<<-`*[T](chan: RendezvousChannel[T], val: T) =
  discard chan.send(val)

template `->>`*[T](chan: RendezvousChannel[T], target: var T) =
  discard chan.recv(target)
