## ==============================================================================
## Lock-Free 128-Bit DWCAS Split-Reference-Counted Pointer (`AtomicArc[T]`)
## ==============================================================================
##
## Concurrency Topology & Mathematical Model:
## | Dimension               | Architectural Specification                                              |
## |:------------------------|:-------------------------------------------------------------------------|
## | **Primitives**          | `AtomicArc[T]` (`AtomicSharedPtr[T]`) & `ArcGuard[T]` (`SharedPtr[T]`)   |
## | **State Encoding**      | 128-bit `Pair[uint64, pointer]`: `(gen:32 | extCount:32, cbPtr:64)`      |
## | **Atomic Substrate**    | Hardware 128-bit DWCAS (`cmpxchg16b` on x86_64, `caspal` on ARM64 LSE)   |
## | **Reclamation Model**   | Biased Split-Reference Counting (`ArcSlotBias = 1'i64 shl 32`)           |
## | **Progress Guarantees** | `load`: Lock-Free DWCAS (zero cache-line writes to control block)        |
## |                         | `store` / `swap`: Lock-Free DWCAS + 1 atomic `fetchAdd` on evicted block |
## |                         | `compareExchange`: Lock-Free DWCAS immune to concurrent `load` churn     |
## | **C ABI Interop**       | C99 bindings declared in `include/lockfree_atomic_arc.h`                 |
## ==============================================================================

when not compileOption("threads"):
  {.error: "lockfree/atomic_arc requires --threads:on".}

import std/options
import lockfree/atomics
import lockfree/internal/aligned_alloc

const
  ArcSlotBias* = 1'i64 shl 32
    ## Reference weight contributed to `cb.internalCount` by each active
    ## `AtomicArc[T]` slot holding `cb`. Prevents `cb.internalCount` from ever
    ## reaching `0` while `cb` remains installed in any `AtomicArc[T]` slot.
  ArcExtMask* = 0xFFFF_FFFF'u64
    ## Low 32 bits of `slot.first` track external `load()` acquisitions for the
    ## current slot generation. High 32 bits track the monotonic slot generation.
  ArcGenStep* = 1'u64 shl 32
    ## Added to the high 32-bit generation counter on every slot replacement.
  ArcExtFlushThreshold* = 1'u64 shl 30
    ## If a single slot accumulates >= 2^30 `load()` operations without being
    ## replaced, the reader flushes `ArcExtFlushThreshold` back into
    ## `cb.internalCount` so the 32-bit external counter never overflows.

type
  ArcDestroyCallback* = proc(p: pointer) {.cdecl, gcsafe, raises: [].}
    ## Optional single-argument custom destructor callback when `T is pointer`.

  ArcItemDestroyCallback* = proc(item: pointer, userData: pointer) {.cdecl, gcsafe, raises: [].}
    ## Optional C ABI destructor callback matching `lfq_item_destructor_fn`.

  ArcControlBlock*[T] = object
    internalCount* {.align: CacheLineBytes.}: Atomic[int64]
    destroyCb*: ArcDestroyCallback
    itemDestroyCb*: ArcItemDestroyCallback
    userData*: pointer
    val*: T

  ArcGuard*[T] = object
    ## Thread-safe reference-counted guard returned by `AtomicArc[T].load()`,
    ## `swap()`, or constructed via `initArcGuard[T]()`.
    ## Keeps the underlying payload alive until all guards and `AtomicArc[T]`
    ## slots referencing the control block have been released.
    cb*: ptr ArcControlBlock[T]

  SharedPtr*[T] = ArcGuard[T]
    ## Ergonomic C++-style alias for `ArcGuard[T]`.

  AtomicArcSlot* = Pair[uint64, pointer]
    ## 16-byte DWCAS payload:
    ## - `first`:  `(gen shl 32) or extCount`
    ## - `second`: `ptr ArcControlBlock[T]` (cast to `pointer`)

  AtomicArcCore*[T] = object
    slot* {.align: CacheLineBytes.}: Atomic[AtomicArcSlot]
    rc* {.align: CacheLineBytes.}: Atomic[int]

  AtomicArc*[T] = object
    ## Lock-free atomic shared pointer backed by 128-bit DWCAS split-reference
    ## counting. Supports concurrent `load`, `store`, `swap`, and
    ## `compareExchange` without locks or background SMR threads.
    core*: ptr AtomicArcCore[T]

  AtomicSharedPtr*[T] = AtomicArc[T]
    ## Ergonomic C++-style alias for `AtomicArc[T]`.

# ------------------------------------------------------------------------------
# Internal Control Block Management
# ------------------------------------------------------------------------------

proc allocControlBlock*[T](
    item: sink T,
    initialCount: int64,
    destroyCb: ArcDestroyCallback = nil,
    itemDestroyCb: ArcItemDestroyCallback = nil,
    userData: pointer = nil
): ptr ArcControlBlock[T] {.inline.} =
  result = allocAligned[ArcControlBlock[T]]()
  result.internalCount.store(initialCount, moRelaxed)
  result.destroyCb = destroyCb
  result.itemDestroyCb = itemDestroyCb
  result.userData = userData
  result.val = item

proc destroyControlBlock*[T](cb: ptr ArcControlBlock[T]) {.inline, gcsafe.} =
  if cb == nil:
    return
  threadFence(moAcquire)
  when T is pointer:
    if cb.itemDestroyCb != nil and cb.val != nil:
      cb.itemDestroyCb(cb.val, cb.userData)
    elif cb.destroyCb != nil and cb.val != nil:
      cb.destroyCb(cb.val)
  elif not (T is SomeNumber or T is bool or T is char or T is enum or T is ptr):
    {.cast(gcsafe).}:
      `=destroy`(cb.val)
  freeAligned(cb)

proc releaseSlotRef*[T](
    cb: ptr ArcControlBlock[T], extCount: uint64
) {.inline, gcsafe.} =
  ## Reconciles a swapped-out slot's `extCount` against its `ArcSlotBias` in
  ## `cb.internalCount`. If total remaining references reach 0, destroys `cb`.
  if cb == nil:
    return
  let delta = int64(extCount) - ArcSlotBias
  let prev = cb.internalCount.fetchAdd(delta, moAcquireRelease)
  if prev + delta == 0:
    destroyControlBlock(cb)

# ------------------------------------------------------------------------------
# ArcGuard[T] (`SharedPtr[T]`) Lifecycle & Accessors
# ------------------------------------------------------------------------------

proc `=destroy`*[T](self: var ArcGuard[T]) {.gcsafe.} =
  if self.cb != nil:
    if self.cb.internalCount.fetchSub(1, moAcquireRelease) == 1:
      destroyControlBlock(self.cb)
    self.cb = nil

proc `=copy`*[T](dest: var ArcGuard[T], src: ArcGuard[T]) =
  if dest.cb != src.cb:
    `=destroy`(dest)
    dest.cb = src.cb
    if dest.cb != nil:
      discard dest.cb.internalCount.fetchAdd(1, moRelaxed)

proc `=sink`*[T](dest: var ArcGuard[T], src: ArcGuard[T]) =
  if dest.cb != src.cb:
    `=destroy`(dest)
  dest.cb = src.cb

proc initArcGuard*[T](
    val: sink T, destroyCb: ArcDestroyCallback = nil
): ArcGuard[T] {.inline.} =
  ## Allocates a new reference-counted control block owning `val` and returns
  ## an `ArcGuard[T]` with initial reference count 1.
  result.cb = allocControlBlock[T](val, 1'i64, destroyCb)

proc initArcGuard*[T](
    val: sink T,
    itemDestroyCb: ArcItemDestroyCallback,
    userData: pointer
): ArcGuard[T] {.inline.} =
  ## Allocates a new reference-counted control block owning `val` with a
  ## `(item, userData)` destructor callback and returns an `ArcGuard[T]`.
  result.cb = allocControlBlock[T](val, 1'i64, nil, itemDestroyCb, userData)

proc newArcGuard*[T](
    val: sink T, destroyCb: ArcDestroyCallback = nil
): ArcGuard[T] {.inline.} =
  initArcGuard[T](val, destroyCb)

proc initSharedPtr*[T](
    val: sink T, destroyCb: ArcDestroyCallback = nil
): SharedPtr[T] {.inline.} =
  initArcGuard[T](val, destroyCb)

proc isNil*[T](self: ArcGuard[T]): bool {.inline.} =
  self.cb == nil

proc get*[T](self: ArcGuard[T]): lent T {.inline.} =
  ## Returns an immutable lent reference to the managed value.
  ## Raises `NilAccessDefect` if `self.isNil`.
  if unlikely(self.cb == nil):
    raise newException(NilAccessDefect, "Attempt to dereference nil ArcGuard")
  self.cb.val

proc `[]`*[T](self: ArcGuard[T]): lent T {.inline.} =
  self.get()

proc rawPtr*[T](self: ArcGuard[T]): ptr T {.inline.} =
  ## Returns a raw pointer to the payload inside the control block, or `nil` if
  ## the guard is empty. Valid for the lifetime of `self`.
  if self.cb == nil:
    nil
  else:
    addr self.cb.val

proc tryGet*[T](self: ArcGuard[T]): Option[T] {.inline.} =
  if self.cb == nil:
    none(T)
  else:
    some(self.cb.val)

proc clone*[T](self: ArcGuard[T]): ArcGuard[T] {.inline.} =
  ## Explicitly clones the guard, incrementing the control block's reference
  ## count.
  if self.cb != nil:
    discard self.cb.internalCount.fetchAdd(1, moRelaxed)
  result.cb = self.cb

proc reset*[T](self: var ArcGuard[T]) {.inline.} =
  ## Releases the guard's reference and resets it to `nil`.
  `=destroy`(self)

proc `==`*[T](a, b: ArcGuard[T]): bool {.inline.} =
  ## Pointer-identity equality between two `ArcGuard[T]` handles.
  a.cb == b.cb

# ------------------------------------------------------------------------------
# AtomicArc[T] (`AtomicSharedPtr[T]`) Lifecycle
# ------------------------------------------------------------------------------

proc freeAtomicArcCore[T](core: ptr AtomicArcCore[T]) {.gcsafe.} =
  if core == nil:
    return
  let old = core.slot.exchange(
    AtomicArcSlot(first: 0'u64, second: nil), moSequentiallyConsistent
  )
  if old.second != nil:
    let oldCb = cast[ptr ArcControlBlock[T]](old.second)
    let oldExt = old.first and ArcExtMask
    releaseSlotRef(oldCb, oldExt)
  freeAligned(core)

proc `=destroy`*[T](self: var AtomicArc[T]) {.gcsafe.} =
  if self.core != nil:
    if self.core.rc.fetchSub(1, moAcquireRelease) == 1:
      threadFence(moAcquire)
      freeAtomicArcCore(self.core)
    self.core = nil

proc `=copy`*[T](dest: var AtomicArc[T], src: AtomicArc[T]) =
  if dest.core != src.core:
    `=destroy`(dest)
    dest.core = src.core
    if dest.core != nil:
      discard dest.core.rc.fetchAdd(1, moRelaxed)

proc `=sink`*[T](dest: var AtomicArc[T], src: AtomicArc[T]) =
  if dest.core != src.core:
    `=destroy`(dest)
  dest.core = src.core

proc initAtomicArc*[T](): AtomicArc[T] =
  ## Initializes an empty (`nil`) `AtomicArc[T]`.
  let core = allocAligned[AtomicArcCore[T]]()
  core.slot.store(
    AtomicArcSlot(first: 0'u64, second: nil), moSequentiallyConsistent
  )
  core.rc.store(1, moRelaxed)
  result.core = core

proc initAtomicArc*[T](
    val: sink T, destroyCb: ArcDestroyCallback = nil
): AtomicArc[T] =
  ## Initializes a new `AtomicArc[T]` owning `val`.
  let core = allocAligned[AtomicArcCore[T]]()
  let cb = allocControlBlock[T](val, ArcSlotBias, destroyCb)
  core.slot.store(
    AtomicArcSlot(first: ArcGenStep, second: cast[pointer](cb)),
    moSequentiallyConsistent
  )
  core.rc.store(1, moRelaxed)
  result.core = core

proc initAtomicArc*[T](
    val: sink T,
    itemDestroyCb: ArcItemDestroyCallback,
    userData: pointer
): AtomicArc[T] =
  ## Initializes a new `AtomicArc[T]` owning `val` with a `(item, userData)`
  ## destructor callback.
  let core = allocAligned[AtomicArcCore[T]]()
  let cb = allocControlBlock[T](val, ArcSlotBias, nil, itemDestroyCb, userData)
  core.slot.store(
    AtomicArcSlot(first: ArcGenStep, second: cast[pointer](cb)),
    moSequentiallyConsistent
  )
  core.rc.store(1, moRelaxed)
  result.core = core

proc initAtomicArc*[T](guard: ArcGuard[T]): AtomicArc[T] =
  ## Initializes a new `AtomicArc[T]` sharing ownership of `guard`.
  let core = allocAligned[AtomicArcCore[T]]()
  if guard.cb != nil:
    discard guard.cb.internalCount.fetchAdd(ArcSlotBias, moRelaxed)
    core.slot.store(
      AtomicArcSlot(first: ArcGenStep, second: cast[pointer](guard.cb)),
      moSequentiallyConsistent
    )
  else:
    core.slot.store(
      AtomicArcSlot(first: 0'u64, second: nil), moSequentiallyConsistent
    )
  core.rc.store(1, moRelaxed)
  result.core = core

proc newAtomicArc*[T](): AtomicArc[T] {.inline.} =
  initAtomicArc[T]()

proc newAtomicArc*[T](
    val: sink T, destroyCb: ArcDestroyCallback = nil
): AtomicArc[T] {.inline.} =
  initAtomicArc[T](val, destroyCb)

proc newAtomicArc*[T](guard: ArcGuard[T]): AtomicArc[T] {.inline.} =
  initAtomicArc[T](guard)

proc initAtomicSharedPtr*[T](): AtomicSharedPtr[T] {.inline.} =
  initAtomicArc[T]()

proc initAtomicSharedPtr*[T](
    val: sink T, destroyCb: ArcDestroyCallback = nil
): AtomicSharedPtr[T] {.inline.} =
  initAtomicArc[T](val, destroyCb)

proc initAtomicSharedPtr*[T](guard: SharedPtr[T]): AtomicSharedPtr[T] {.inline.} =
  initAtomicArc[T](guard)

# ------------------------------------------------------------------------------
# AtomicArc[T] Lock-Free 128-Bit DWCAS Operations
# ------------------------------------------------------------------------------

proc flushExtCountIfNeeded[T](
    core: ptr AtomicArcCore[T],
    cb: ptr ArcControlBlock[T],
    observedPtr: pointer,
    postAcqSlot: AtomicArcSlot
) {.inline, gcsafe.} =
  let newExt = postAcqSlot.first and ArcExtMask
  if unlikely(newExt >= ArcExtFlushThreshold):
    discard cb.internalCount.fetchAdd(int64(ArcExtFlushThreshold), moRelaxed)
    var flushExp = postAcqSlot
    while flushExp.second == observedPtr and
          ((flushExp.first and not ArcExtMask) == (postAcqSlot.first and not ArcExtMask)) and
          (flushExp.first and ArcExtMask) >= ArcExtFlushThreshold:
      let flushDes = AtomicArcSlot(
        first: flushExp.first - ArcExtFlushThreshold,
        second: flushExp.second
      )
      if core.slot.compareExchangeWeak(
        flushExp, flushDes, moSequentiallyConsistent, moSequentiallyConsistent
      ):
        return
    # Slot was replaced before flush CAS; undo speculative internalCount addition
    let prev = cb.internalCount.fetchSub(int64(ArcExtFlushThreshold), moAcquireRelease)
    if prev == int64(ArcExtFlushThreshold):
      destroyControlBlock(cb)

proc isNil*[T](self: AtomicArc[T]): bool {.inline, gcsafe.} =
  ## Returns `true` if the `AtomicArc[T]` is uninitialized or currently holds `nil`.
  if self.core == nil:
    return true
  let cur = self.core.slot.load(moSequentiallyConsistent)
  cur.second == nil

proc load*[T](self: AtomicArc[T]): ArcGuard[T] {.inline, gcsafe.} =
  ## Atomically loads an `ArcGuard[T]` from `self` using 128-bit DWCAS.
  ## Increments the slot's 32-bit external counter atomically with pointer
  ## observation so the control block cannot be reclaimed by a concurrent
  ## `store` / `swap` / `compareExchange`.
  if self.core == nil:
    return ArcGuard[T](cb: nil)
  var cur = self.core.slot.load(moSequentiallyConsistent)
  while true:
    if cur.second == nil:
      return ArcGuard[T](cb: nil)
    let desired = AtomicArcSlot(first: cur.first + 1'u64, second: cur.second)
    if self.core.slot.compareExchangeWeak(
      cur, desired, moSequentiallyConsistent, moSequentiallyConsistent
    ):
      let cb = cast[ptr ArcControlBlock[T]](cur.second)
      flushExtCountIfNeeded(self.core, cb, cur.second, desired)
      return ArcGuard[T](cb: cb)

proc loadOpt*[T](self: AtomicArc[T]): Option[T] {.inline, gcsafe.} =
  ## Atomically loads a copy of the current value wrapped in `Option[T]`, or
  ## `none(T)` if the `AtomicArc[T]` is currently empty.
  let g = self.load()
  if g.isNil:
    none(T)
  else:
    some(g.get())

proc store*[T](self: AtomicArc[T], guard: ArcGuard[T]) {.gcsafe.} =
  ## Atomically replaces the pointer in `self` with `guard` and releases the
  ## previous control block's slot reference.
  doAssert self.core != nil, "AtomicArc must be initialized before store"
  if guard.cb != nil:
    discard guard.cb.internalCount.fetchAdd(ArcSlotBias, moRelaxed)
  var cur = self.core.slot.load(moSequentiallyConsistent)
  while true:
    let nextGen = ((cur.first shr 32) + 1'u64) shl 32
    let desired = AtomicArcSlot(first: nextGen, second: cast[pointer](guard.cb))
    if self.core.slot.compareExchangeWeak(
      cur, desired, moSequentiallyConsistent, moSequentiallyConsistent
    ):
      if cur.second != nil:
        let oldCb = cast[ptr ArcControlBlock[T]](cur.second)
        let oldExt = cur.first and ArcExtMask
        releaseSlotRef(oldCb, oldExt)
      return

proc store*[T](
    self: AtomicArc[T], val: sink T, destroyCb: ArcDestroyCallback = nil
) {.gcsafe.} =
  ## Allocates a new control block for `val` and atomically stores it into `self`.
  doAssert self.core != nil, "AtomicArc must be initialized before store"
  let newCb = allocControlBlock[T](val, ArcSlotBias, destroyCb)
  var cur = self.core.slot.load(moSequentiallyConsistent)
  while true:
    let nextGen = ((cur.first shr 32) + 1'u64) shl 32
    let desired = AtomicArcSlot(first: nextGen, second: cast[pointer](newCb))
    if self.core.slot.compareExchangeWeak(
      cur, desired, moSequentiallyConsistent, moSequentiallyConsistent
    ):
      if cur.second != nil:
        let oldCb = cast[ptr ArcControlBlock[T]](cur.second)
        let oldExt = cur.first and ArcExtMask
        releaseSlotRef(oldCb, oldExt)
      return

proc store*[T](
    self: AtomicArc[T],
    val: sink T,
    itemDestroyCb: ArcItemDestroyCallback,
    userData: pointer
) {.gcsafe.} =
  ## Allocates a new control block for `val` with `(itemDestroyCb, userData)`
  ## and atomically stores it into `self`.
  doAssert self.core != nil, "AtomicArc must be initialized before store"
  let newCb = allocControlBlock[T](val, ArcSlotBias, nil, itemDestroyCb, userData)
  var cur = self.core.slot.load(moSequentiallyConsistent)
  while true:
    let nextGen = ((cur.first shr 32) + 1'u64) shl 32
    let desired = AtomicArcSlot(first: nextGen, second: cast[pointer](newCb))
    if self.core.slot.compareExchangeWeak(
      cur, desired, moSequentiallyConsistent, moSequentiallyConsistent
    ):
      if cur.second != nil:
        let oldCb = cast[ptr ArcControlBlock[T]](cur.second)
        let oldExt = cur.first and ArcExtMask
        releaseSlotRef(oldCb, oldExt)
      return

proc storeNil*[T](self: AtomicArc[T]) {.inline, gcsafe.} =
  ## Atomically clears `self` to `nil`.
  let empty = ArcGuard[T](cb: nil)
  self.store(empty)

proc swap*[T](self: AtomicArc[T], guard: ArcGuard[T]): ArcGuard[T] {.gcsafe.} =
  ## Atomically replaces the pointer in `self` with `guard` and returns the
  ## previous value as an `ArcGuard[T]`.
  doAssert self.core != nil, "AtomicArc must be initialized before swap"
  if guard.cb != nil:
    discard guard.cb.internalCount.fetchAdd(ArcSlotBias, moRelaxed)
  var cur = self.core.slot.load(moSequentiallyConsistent)
  while true:
    let nextGen = ((cur.first shr 32) + 1'u64) shl 32
    let desired = AtomicArcSlot(first: nextGen, second: cast[pointer](guard.cb))
    if self.core.slot.compareExchangeWeak(
      cur, desired, moSequentiallyConsistent, moSequentiallyConsistent
    ):
      if cur.second == nil:
        return ArcGuard[T](cb: nil)
      let oldCb = cast[ptr ArcControlBlock[T]](cur.second)
      let oldExt = cur.first and ArcExtMask
      # Transfer the slot reference into a single (+1) guard reference for the
      # returned ArcGuard[T]: net delta = oldExt + 1 - ArcSlotBias.
      let delta = int64(oldExt) + 1'i64 - ArcSlotBias
      discard oldCb.internalCount.fetchAdd(delta, moAcquireRelease)
      return ArcGuard[T](cb: oldCb)

proc swap*[T](
    self: AtomicArc[T], val: sink T, destroyCb: ArcDestroyCallback = nil
): ArcGuard[T] {.gcsafe.} =
  ## Allocates a new control block for `val`, atomically swaps it into `self`,
  ## and returns the previous value as an `ArcGuard[T]`.
  doAssert self.core != nil, "AtomicArc must be initialized before swap"
  let newCb = allocControlBlock[T](val, ArcSlotBias, destroyCb)
  var cur = self.core.slot.load(moSequentiallyConsistent)
  while true:
    let nextGen = ((cur.first shr 32) + 1'u64) shl 32
    let desired = AtomicArcSlot(first: nextGen, second: cast[pointer](newCb))
    if self.core.slot.compareExchangeWeak(
      cur, desired, moSequentiallyConsistent, moSequentiallyConsistent
    ):
      if cur.second == nil:
        return ArcGuard[T](cb: nil)
      let oldCb = cast[ptr ArcControlBlock[T]](cur.second)
      let oldExt = cur.first and ArcExtMask
      let delta = int64(oldExt) + 1'i64 - ArcSlotBias
      discard oldCb.internalCount.fetchAdd(delta, moAcquireRelease)
      return ArcGuard[T](cb: oldCb)

proc swap*[T](
    self: AtomicArc[T],
    val: sink T,
    itemDestroyCb: ArcItemDestroyCallback,
    userData: pointer
): ArcGuard[T] {.gcsafe.} =
  ## Allocates a new control block for `val` with `(itemDestroyCb, userData)`,
  ## atomically swaps it into `self`, and returns the previous value as an
  ## `ArcGuard[T]`.
  doAssert self.core != nil, "AtomicArc must be initialized before swap"
  let newCb = allocControlBlock[T](val, ArcSlotBias, nil, itemDestroyCb, userData)
  var cur = self.core.slot.load(moSequentiallyConsistent)
  while true:
    let nextGen = ((cur.first shr 32) + 1'u64) shl 32
    let desired = AtomicArcSlot(first: nextGen, second: cast[pointer](newCb))
    if self.core.slot.compareExchangeWeak(
      cur, desired, moSequentiallyConsistent, moSequentiallyConsistent
    ):
      if cur.second == nil:
        return ArcGuard[T](cb: nil)
      let oldCb = cast[ptr ArcControlBlock[T]](cur.second)
      let oldExt = cur.first and ArcExtMask
      let delta = int64(oldExt) + 1'i64 - ArcSlotBias
      discard oldCb.internalCount.fetchAdd(delta, moAcquireRelease)
      return ArcGuard[T](cb: oldCb)

proc exchange*[T](
    self: AtomicArc[T], guard: ArcGuard[T]
): ArcGuard[T] {.inline, gcsafe.} =
  self.swap(guard)

proc exchange*[T](
    self: AtomicArc[T], val: sink T, destroyCb: ArcDestroyCallback = nil
): ArcGuard[T] {.inline, gcsafe.} =
  self.swap(val, destroyCb)

proc compareExchange*[T](
    self: AtomicArc[T],
    expected: var ArcGuard[T],
    desired: ArcGuard[T]
): bool {.gcsafe.} =
  ## Atomically compares the control block pointer in `self` with `expected.cb`.
  ## - If equal, replaces `self` with `desired` and returns `true` (`expected` is
  ##   unchanged). Regardless of concurrent `load()` operations modifying the
  ##   slot's external count, the CAS retries as long as the control block
  ##   pointer continues to match `expected.cb`.
  ## - If not equal, updates `expected` to hold a guard to the current value of
  ##   `self` and returns `false`.
  doAssert self.core != nil, "AtomicArc must be initialized before compareExchange"
  let expectedPtr = cast[pointer](expected.cb)
  let desiredCb = desired.cb
  if desiredCb != nil:
    discard desiredCb.internalCount.fetchAdd(ArcSlotBias, moRelaxed)

  var cur = self.core.slot.load(moSequentiallyConsistent)
  while true:
    if cur.second != expectedPtr:
      if cur.second == nil:
        `=destroy`(expected)
        if desiredCb != nil:
          releaseSlotRef(desiredCb, 0'u64)
        return false
      # Increment external count on cur so expected receives a valid guard
      let acqDesired = AtomicArcSlot(first: cur.first + 1'u64, second: cur.second)
      if self.core.slot.compareExchangeWeak(
        cur, acqDesired, moSequentiallyConsistent, moSequentiallyConsistent
      ):
        let observedCb = cast[ptr ArcControlBlock[T]](cur.second)
        flushExtCountIfNeeded(self.core, observedCb, cur.second, acqDesired)
        `=destroy`(expected)
        expected.cb = observedCb
        if desiredCb != nil:
          releaseSlotRef(desiredCb, 0'u64)
        return false
      continue

    let nextGen = ((cur.first shr 32) + 1'u64) shl 32
    let newSlot = AtomicArcSlot(first: nextGen, second: cast[pointer](desiredCb))
    if self.core.slot.compareExchangeWeak(
      cur, newSlot, moSequentiallyConsistent, moSequentiallyConsistent
    ):
      if cur.second != nil:
        let oldCb = cast[ptr ArcControlBlock[T]](cur.second)
        let oldExt = cur.first and ArcExtMask
        releaseSlotRef(oldCb, oldExt)
      return true

proc compareExchange*[T](
    self: AtomicArc[T],
    expected: var ArcGuard[T],
    desiredVal: sink T,
    destroyCb: ArcDestroyCallback = nil
): bool {.inline, gcsafe.} =
  ## Convenience overload that wraps `desiredVal` in a temporary `ArcGuard[T]`
  ## and performs `compareExchange`. If the CAS fails, `desiredVal`'s control
  ## block is automatically destroyed before returning `false`.
  let desiredGuard = initArcGuard[T](desiredVal, destroyCb)
  self.compareExchange(expected, desiredGuard)

proc compareExchange*[T](
    self: AtomicArc[T],
    expected: var ArcGuard[T],
    desiredVal: sink T,
    itemDestroyCb: ArcItemDestroyCallback,
    userData: pointer
): bool {.inline, gcsafe.} =
  let desiredGuard = initArcGuard[T](desiredVal, itemDestroyCb, userData)
  self.compareExchange(expected, desiredGuard)

proc compareExchangeStrong*[T](
    self: AtomicArc[T],
    expected: var ArcGuard[T],
    desired: ArcGuard[T]
): bool {.inline, gcsafe.} =
  self.compareExchange(expected, desired)

proc compareExchangeWeak*[T](
    self: AtomicArc[T],
    expected: var ArcGuard[T],
    desired: ArcGuard[T]
): bool {.inline, gcsafe.} =
  self.compareExchange(expected, desired)
