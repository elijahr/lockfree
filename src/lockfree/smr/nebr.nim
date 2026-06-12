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
  ## slot it claimed via `registerThread`.

  if handle.idx < 0 or handle.idx >= MaxThreads:
    return

  let bit = 1'u64 shl handle.idx

  if (manager.activeThreadMask.load(moAcquire) and bit) == 0'u64:
    return

  doAssert threadLocalRegistered and threadLocalIdx == handle.idx and
    threadLocalManager == cast[pointer](addr manager),
    "unregisterThread: thread-affinity violation or stale handle on a live slot"

  manager.threads[handle.idx].threadId.store(InvalidThreadId, moRelease)

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

proc neutralizeStalled*[MaxThreads: static int](
    manager: var DebraManager[MaxThreads], epochsBeforeNeutralize: uint64 = 2
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
