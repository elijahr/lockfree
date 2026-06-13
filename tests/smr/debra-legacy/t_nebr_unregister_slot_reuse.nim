## Gating test for the slot-reuse stale-state UAF/double-free fix
## (review finding T1-G3-001, coverage gap T2-001).
##
## `unregisterThread` clears the `activeThreadMask` bit, after which
## `register` may re-claim the SAME slot index for a different thread.
## `register` never re-initialises the slot, so any state left behind by the
## departing thread is inherited verbatim by the next owner. Before the fix,
## `unregisterThread` reset only `threadId` + the threadvars, leaving the
## slot's `epoch`/`pinned`/`neutralized`/`currentBag`/`limboBagTail`/
## `advanceCounter` dirty — a use-after-free / double-free hazard (leftover
## limbo bags) and a reclamation-stall hazard (stale `pinned = true`).
##
## The fix:
##   * resets all scalar slot state on unregister, AND
##   * requires the slot's limbo to be empty (drain via `tryReclaim` /
##     `reclaimNow` before unregistering) and the slot to be unpinned,
##     asserting loudly otherwise.
##
## These tests dirty the slot's scalar state, drain its limbo, unregister,
## then re-register (re-claiming the slot index) and assert the reused slot
## starts from `initDebraManager` clean values rather than inheriting the
## previous owner's state. The `epoch`/`advanceCounter` assertions FAIL
## against the pre-fix code (which left them non-zero) and PASS after.

import unittest2

import lockfree/smr/nebr
import lockfree/atomics
import lockfree/smr/nebr/signal
import lockfree/smr/nebr/thread_id
import lockfree/smr/nebr/types
import lockfree/smr/nebr/limbo
import lockfree/smr/nebr/typestates/cardinality
import lockfree/smr/nebr/typestates/guard
import lockfree/smr/nebr/typestates/retire
import lockfree/smr/nebr/typestates/reclaim

# Process-global free counter for the instrumented retire/reclaim test.
var freeCount: Atomic[int]

proc countingDtor(p: pointer) {.nimcall, raises: [].} =
  ## Destructor that bumps a global counter and frees the allocation, so a
  ## double-free (a reused slot walking the previous owner's bags) shows up
  ## as an inflated count.
  discard freeCount.fetchAdd(1, moRelaxed)
  dealloc(p)

suite "unregisterThread — slot-reuse resets scalar slot state (T1-G3-001)":
  test "reused slot does NOT inherit the previous owner's epoch":
    var mgr = initDebraManager[4]()
    setGlobalManager(addr mgr)
    let h1 = registerThread(mgr)

    # Dirty the slot's epoch: a pin captures the current global epoch into
    # `slot.epoch`; unpin leaves that non-zero value in place.
    mgr.advance()
    mgr.advance()
    block:
      let pinned = unpinned(h1).pin()
      discard pinned.unpin()
    check mgr.threads[h1.idx].epoch.load(moAcquire) != 0'u64

    unregisterThread(mgr, h1)

    # Re-claim the same slot index from this thread.
    let h2 = registerThread(mgr)
    check h2.idx == h1.idx

    # The reused slot must start from init values, NOT inherit h1's epoch.
    check mgr.threads[h2.idx].epoch.load(moAcquire) == 0'u64
    check mgr.threads[h2.idx].pinned.load(moAcquire) == false
    check mgr.threads[h2.idx].neutralized.load(moAcquire) == false
    check mgr.threads[h2.idx].currentBag == nil
    check mgr.threads[h2.idx].limboBagTail == nil

    unregisterThread(mgr, h2)

  test "reused slot does NOT inherit the previous owner's advanceCounter":
    var mgr = initDebraManager[4]()
    setGlobalManager(addr mgr)
    let h1 = registerThread(mgr)

    # Bump the per-slot advance cadence counter a few times.
    for _ in 0 ..< 5:
      discard h1.advanceEvery(1000)
    check mgr.threads[h1.idx].advanceCounter == 5'u64

    unregisterThread(mgr, h1)

    let h2 = registerThread(mgr)
    check h2.idx == h1.idx
    check mgr.threads[h2.idx].advanceCounter == 0'u64

    unregisterThread(mgr, h2)

  test "drain-before-unregister + reuse does not double-free the prior owner's retires":
    freeCount.store(0, moRelaxed)
    var mgr = initDebraManager[4]()
    setGlobalManager(addr mgr)

    # --- First owner: retire instrumented objects, then DRAIN them. ---
    let h1 = registerThread(mgr)
    block:
      # Sink-form retire chain: pin -> retire (x3) -> unpin. Each
      # `retire` consumes the `RetireReady` and returns `Retired`;
      # `retireReadyFromRetired` rebuilds it for the next retire, and
      # `pinnedFromRetired` projects back to `Pinned` for the final unpin.
      # Qualify with the `retire` module to pick the sink-form transition
      # (returns `Retired`) over the convenience `retire(var RetireReady,...)`
      # overload (returns void), which is also in scope via the `nebr` umbrella.
      let ready = retireReady(unpinned(h1).pin())
      var retired = retire.retire(ready, alloc0(8), countingDtor)
      retired = retire.retire(retireReadyFromRetired(retired), alloc0(8), countingDtor)
      retired = retire.retire(retireReadyFromRetired(retired), alloc0(8), countingDtor)
      discard pinnedFromRetired(retired).unpin()

    # Advance enough that the retired epoch becomes reclaimable, then drain
    # the limbo fully (the new unregister contract requires an empty limbo).
    for _ in 0 ..< 4:
      mgr.advance()
    var reclaimed = 0
    for _ in 0 ..< 8:
      reclaimed += reclaimNow(h1)
    check reclaimed == 3
    check freeCount.load(moRelaxed) == 3
    check mgr.threads[h1.idx].limboBagTail == nil
    check mgr.threads[h1.idx].currentBag == nil

    unregisterThread(mgr, h1)

    # --- Second owner re-claims the slot and retires/reclaims its own. ---
    let h2 = registerThread(mgr)
    check h2.idx == h1.idx
    block:
      let retired =
        retire.retire(retireReady(unpinned(h2).pin()), alloc0(8), countingDtor)
      discard pinnedFromRetired(retired).unpin()

    for _ in 0 ..< 4:
      mgr.advance()
    var reclaimed2 = 0
    for _ in 0 ..< 8:
      reclaimed2 += reclaimNow(h2)
    check reclaimed2 == 1
    # Exactly 3 (owner 1) + 1 (owner 2) frees. A reused slot that inherited
    # owner 1's bags would re-run owner 1's destructors -> count > 4.
    check freeCount.load(moRelaxed) == 4

    unregisterThread(mgr, h2)
