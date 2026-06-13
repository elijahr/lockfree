## lockfree/smr/nebr: NEBR Safe Memory Reclamation
##
## NEBR = Neutralization-Enhanced Bounded Reclamation. This module is the
## in-tree fork of nim-debra. Semantically identical to upstream nim-debra
## except for import paths.
##
## Public facade re-exporting the manager + neutralize substrate plus the
## thread-registration, epoch, and client-binding helpers that downstream
## consumers (Queue[T] with ref payloads, the destructor walk) need.
##
## Design refs: nim-debra design §3.1, §3.7.

when not compileOption("threads"):
  {.error: "lockfree/smr/nebr requires --threads:on".}

import ../atomics
import ./nebr/types
import ./nebr/signal
import ./nebr/limbo
import ./nebr/thread_id
import ./nebr/typestates/cardinality
import ./nebr/typestates/signal_handler
import ./nebr/typestates/manager
import ./nebr/typestates/registration
import ./nebr/typestates/guard
import ./nebr/typestates/retire
import ./nebr/typestates/pinned_scope
import ./nebr/typestates/reclaim
import ./nebr/typestates/neutralize
import ./nebr/typestates/advance
import ./nebr/typestates/slot
import ./nebr/refptr
import ./nebr/convenience

export types
export signal.setGlobalManager, signal.installSignalHandler
export limbo
export thread_id
export cardinality
export signal_handler
export manager
export registration
export guard
export retire
export pinned_scope
export reclaim
export neutralize
export advance
export slot
export refptr
export convenience

proc registerThread*[MaxThreads: static int, CC: static PinScopeCardinality](
    manager: var DebraManager[MaxThreads, CC]
): ThreadHandle[MaxThreads, CC] {.raises: [DebraRegistrationError].} =
  ## Register current thread with the NEBR manager.
  ##
  ## Must be called once per thread before any epoch operations.
  ## Raises DebraRegistrationError if max threads already registered.
  installSignalHandler()

  let u = unregistered(addr manager)
  var regResult = u.register()
  match regResult:
    Registered(reg):
      return reg.getHandle()
    RegistrationFull(_):
      raise newException(
        DebraRegistrationError,
        "Maximum threads (" & $MaxThreads & ") already registered",
      )

proc unregisterThread*[
    MaxThreads: static int, CC: static PinScopeCardinality = ccSingle
](
    manager: var DebraManager[MaxThreads, CC], handle: ThreadHandle[MaxThreads, CC]
) {.raises: [].} =
  ## Unregister the current thread from the NEBR manager, releasing the
  ## slot it claimed via `registerThread` so a future `registerThread` may
  ## re-claim that slot index for a different thread.
  ##
  ## **Caller contract (preconditions).** Both must hold or this proc fails a
  ## `doAssert` (see "Failure behavior" below):
  ##
  ## 1. **Unpinned.** The calling thread MUST have exited *all* pin scopes
  ##    before calling. The slot's `pinned` flag must be clear. Calling from
  ##    inside a critical section is a programming error.
  ## 2. **Drained limbo.** The calling thread MUST have drained its own
  ##    retired/limbo objects before calling, i.e. run reclamation until it
  ##    reclaims nothing — `reclaimNow(handle)` (the convenience entry point;
  ##    underlying mechanism `tryReclaim`) until it returns `0`. The slot's
  ##    `currentBag` and `limboBagTail` must be `nil`. Unregistering with
  ##    pending limbo is a programming error.
  ##
  ## **Why the contract exists.** Releasing the slot lets `registerThread`
  ## re-claim THIS slot index for a DIFFERENT thread; `register` reuses the
  ## slot in place and does not re-initialise its epoch/pinned/limbo state.
  ## So any state left here is inherited verbatim by the next owner:
  ##
  ## * A departing thread's still-pending retired objects are NOT necessarily
  ##   epoch-safe to free yet, and NEBR keeps NO manager-level orphan-reclaim
  ##   list — it cannot adopt them. Eagerly freeing them here would be a
  ##   premature-free UAF; leaving them on a reused slot would let the new
  ##   owner's `tryReclaim` walk them under a different epoch (a stale-slot
  ##   use-after-free / double-free). Requiring the caller to drain first is
  ##   the conservative resolution of both hazards.
  ## * A stale `pinned = true` would make reclamation observe this slot as
  ##   pinned forever, stalling ALL reclamation manager-wide.
  ##
  ## **Failure behavior.** Contract violations are reported via `doAssert`
  ## (this proc is `{.raises: [].}`, a compile-time-pinned contract, so it
  ## cannot raise). In debug builds a violation aborts loudly. Under
  ## `-d:danger` assertions are compiled out, so violating the contract is
  ## undefined behavior (the very slot-reuse UAF / double-free this contract
  ## prevents) rather than a loud abort. Treat the contract as mandatory in
  ## all builds, not merely as a debug aid.
  ##
  ## A handle with an out-of-range index, a slot whose `activeThreadMask` bit
  ## is already clear (double-unregister), or a thread-affinity mismatch is
  ## handled before the precondition checks: the first two return silently;
  ## the affinity mismatch is its own `doAssert`.

  if handle.idx < 0 or handle.idx >= MaxThreads:
    return

  let bit = 1'u64 shl handle.idx

  if (manager.activeThreadMask.load(moAcquire) and bit) == 0'u64:
    return

  doAssert threadLocalRegistered and threadLocalIdx == handle.idx and
    threadLocalManager == cast[pointer](addr manager),
    "unregisterThread: thread-affinity violation or stale handle on a live slot"

  let slot = addr manager.threads[handle.idx]

  # Memory-safety contract (NEBR slot reuse).
  #
  # The slot's `activeThreadMask` bit is about to be cleared, after which
  # `register` may re-claim THIS slot index for a DIFFERENT thread. `register`
  # only stores `threadId` + the threadvars; it never re-initialises the slot's
  # epoch/pinned/neutralized/bag pointers/advanceCounter. So whatever state we
  # leave here is inherited verbatim by the next owner. Two hazards follow if we
  # leave it dirty:
  #
  #  * Leftover limbo bags (currentBag / limboBagTail) belong to the departing
  #    thread's retire lifecycle. A reused slot's `tryReclaim` would walk them
  #    under the new owner's epoch arithmetic — a use-after-free / double-free of
  #    objects retired against a now-departed reader set.
  #  * A stale `pinned = true` makes `loadEpochs` (reclaim.nim) observe this slot
  #    as pinned forever, pinning `safeEpoch` at the stale epoch and stalling ALL
  #    reclamation manager-wide until manager destroy.
  #
  # We do NOT eagerly drain the bags here: the departing thread's retired objects
  # may not be epoch-safe to free yet, and freeing them now would be a different
  # (premature-reclamation) UAF. NEBR has no manager-level orphan-reclaim list,
  # so the conservative correct contract is: callers must drain their own limbo
  # (via `tryReclaim` until empty) BEFORE unregistering. We assert that here so a
  # violation surfaces loudly instead of leaking or double-freeing on reuse.
  #
  # `unregisterThread` is `{.raises: [].}` (a pinned compile-time contract in the
  # test suite), so these are `doAssert`s (consistent with the affinity assert
  # above and the `boundClients` assert in `=destroy`), not raised exceptions.
  doAssert not slot.pinned.load(moAcquire),
    "unregisterThread: slot is still pinned (thread is inside a critical " &
      "section); unpin before unregistering"
  doAssert slot.limboBagTail == nil and slot.currentBag == nil,
    "unregisterThread: slot still holds retired objects in limbo; drain via " &
      "tryReclaim (until it reclaims nothing) before unregistering — otherwise " &
      "a reused slot would walk this thread's pending retires (UAF/double-free)"

  manager.threads[handle.idx].threadId.store(InvalidThreadId, moRelease)

  # Reset the slot to its `initDebraManager` clean state so a subsequent
  # `register` re-claiming this index starts from init values rather than
  # inheriting this thread's epoch/flags/counters. The bag pointers are already
  # nil (asserted above); reset them anyway for defensiveness and symmetry with
  # initDebraManager.
  slot.epoch.store(0'u64, moRelease)
  slot.pinned.store(false, moRelease)
  slot.neutralized.store(false, moRelease)
  slot.currentBag = nil
  slot.limboBagTail = nil
  slot.advanceCounter = 0'u64

  var expected = manager.activeThreadMask.load(moAcquire)
  while (expected and bit) != 0'u64:
    let desired = expected and not bit
    if manager.activeThreadMask.compareExchangeWeak(
      expected, desired, moAcquireRelease, moAcquire
    ):
      break

  threadLocalIdx = 0
  threadLocalRegistered = false
  threadLocalManager = nil

proc neutralizeStalled*[
    MaxThreads: static int, CC: static PinScopeCardinality = ccSingle
](
    manager: var DebraManager[MaxThreads, CC], epochsBeforeNeutralize: uint64 = 2
): int =
  ## Signal all stalled threads. Returns number of signals sent.
  let op = scanStart(addr manager)
  let scanning = op.loadEpoch(epochsBeforeNeutralize)
  let complete = scanning.scanAndSignal()
  complete.extractSignalCount()

proc advance*[MaxThreads: static int, CC: static PinScopeCardinality = ccSingle](
    manager: var DebraManager[MaxThreads, CC]
) {.inline.} =
  ## Advance the global epoch.
  discard manager.globalEpoch.fetchAdd(1'u64, moRelease)

proc currentEpoch*[MaxThreads: static int, CC: static PinScopeCardinality = ccSingle](
    manager: var DebraManager[MaxThreads, CC]
): uint64 {.inline.} =
  ## Get current global epoch.
  manager.globalEpoch.load(moAcquire)

proc bindClient*[MaxThreads: static int, CC: static PinScopeCardinality = ccSingle](
    manager: var DebraManager[MaxThreads, CC]
) {.inline.} =
  ## Register a client as bound to this manager. Increments `boundClients`.
  discard manager.boundClients.fetchAdd(1, moAcquireRelease)

proc unbindClient*[MaxThreads: static int, CC: static PinScopeCardinality = ccSingle](
    manager: var DebraManager[MaxThreads, CC]
) {.inline.} =
  ## Unregister a client previously bound via `bindClient`.
  let prev = manager.boundClients.fetchSub(1, moAcquireRelease)
  doAssert prev > 0,
    "unbindClient: boundClients underflow (was " & $prev &
      ", expected > 0); unbalanced bindClient/unbindClient"

proc clientCount*[MaxThreads: static int, CC: static PinScopeCardinality = ccSingle](
    manager: var DebraManager[MaxThreads, CC]
): int {.inline.} =
  ## Number of clients currently bound to this manager.
  manager.boundClients.load(moRelaxed)
