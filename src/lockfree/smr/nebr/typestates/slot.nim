## ThreadSlot typestate: a compile-time-only ordering marker for the slot
## lifecycle.
##
## IMPORTANT: this typestate is a *compile-time marker only*. The state
## transitions (`claim`/`activate`/`drain`/`release`) perform NO atomic
## operations and carry NO backing runtime state: each is a pure cast between
## distinct wrappers of the same `SlotContext`. They do not touch
## `manager.activeThreadMask`, `threadId`, or any per-slot flag, so an `Active`
## value here has no relationship to whether the slot's bit is actually set.
##
## The authoritative slot state machine lives in `registration.nim`: a slot is
## genuinely claimed by the `activeThreadMask` compare-exchange
## (registration.nim, `register`) and released by the corresponding mask clear.
## This typestate only documents/enforces the *legal ordering* of those phases
## at compile time for callers that choose to model them; it does not gate the
## underlying bitmask.
##
## The intended phase ordering it encodes:
## - Free: Slot is available for claiming
## - Claiming: Thread is attempting to claim the slot
## - Active: Slot is actively in use by a thread
## - Draining: Thread is unregistering, draining limbo bags
## - Free: Slot released back to pool

import typestates

import ../types

type
  SlotContext*[MaxThreads: static int, CC: static PinScopeCardinality = ccSingle] = object of RootObj
    idx*: int
    manager*: ptr DebraManager[MaxThreads, CC]

  Free*[MaxThreads: static int, CC: static PinScopeCardinality = ccSingle] =
    distinct SlotContext[MaxThreads, CC]
  Claiming*[MaxThreads: static int, CC: static PinScopeCardinality = ccSingle] =
    distinct SlotContext[MaxThreads, CC]
  Active*[MaxThreads: static int, CC: static PinScopeCardinality = ccSingle] =
    distinct SlotContext[MaxThreads, CC]
  Draining*[MaxThreads: static int, CC: static PinScopeCardinality = ccSingle] =
    distinct SlotContext[MaxThreads, CC]

typestate SlotContext[MaxThreads: static int, CC: static PinScopeCardinality]:
  inheritsFromRootObj = true
  defaults:
    CC:
      ccSingle
  states Free[MaxThreads, CC],
    Claiming[MaxThreads, CC], Active[MaxThreads, CC], Draining[MaxThreads, CC]
  transitions:
    Free[MaxThreads, CC] -> Claiming[MaxThreads, CC]
    Claiming[MaxThreads, CC] -> Active[MaxThreads, CC]
    Active[MaxThreads, CC] -> Draining[MaxThreads, CC]
    Draining[MaxThreads, CC] -> Free[MaxThreads, CC]

proc freeSlot*[MaxThreads: static int, CC: static PinScopeCardinality = ccSingle](
    idx: int, mgr: ptr DebraManager[MaxThreads, CC]
): Free[MaxThreads, CC] =
  ## Create a free slot context.
  Free[MaxThreads, CC](SlotContext[MaxThreads, CC](idx: idx, manager: mgr))

proc claim*[MaxThreads: static int, CC: static PinScopeCardinality](
    f: sink Free[MaxThreads, CC]
): Claiming[MaxThreads, CC] {.transition.} =
  ## Begin claiming this slot. Transition to Claiming state.
  Claiming[MaxThreads, CC](SlotContext[MaxThreads, CC](f))

proc activate*[MaxThreads: static int, CC: static PinScopeCardinality](
    c: sink Claiming[MaxThreads, CC]
): Active[MaxThreads, CC] {.transition.} =
  ## Complete slot claim. Transition to Active state. This is where the slot
  ## becomes fully owned by a thread.
  Active[MaxThreads, CC](SlotContext[MaxThreads, CC](c))

proc drain*[MaxThreads: static int, CC: static PinScopeCardinality](
    a: sink Active[MaxThreads, CC]
): Draining[MaxThreads, CC] {.transition.} =
  ## Begin unregistration. Transition to Draining state. Thread will drain its
  ## limbo bags before releasing the slot.
  Draining[MaxThreads, CC](SlotContext[MaxThreads, CC](a))

proc release*[MaxThreads: static int, CC: static PinScopeCardinality](
    d: sink Draining[MaxThreads, CC]
): Free[MaxThreads, CC] {.transition.} =
  ## Release slot back to free pool. Transition back to Free state. This
  ## completes the lifecycle, making the slot available for reuse.
  Free[MaxThreads, CC](SlotContext[MaxThreads, CC](d))

func idx*[MaxThreads: static int, CC: static PinScopeCardinality](
    s: Active[MaxThreads, CC]
): int {.notATransition.} =
  ## Get the slot index from Active state.
  SlotContext[MaxThreads, CC](s).idx

func idx*[MaxThreads: static int, CC: static PinScopeCardinality](
    s: Draining[MaxThreads, CC]
): int {.notATransition.} =
  ## Get the slot index from Draining state.
  SlotContext[MaxThreads, CC](s).idx

func manager*[MaxThreads: static int, CC: static PinScopeCardinality](
    s: Active[MaxThreads, CC]
): ptr DebraManager[MaxThreads, CC] {.notATransition.} =
  ## Get the manager pointer from Active state.
  SlotContext[MaxThreads, CC](s).manager

func manager*[MaxThreads: static int, CC: static PinScopeCardinality](
    s: Draining[MaxThreads, CC]
): ptr DebraManager[MaxThreads, CC] {.notATransition.} =
  ## Get the manager pointer from Draining state.
  SlotContext[MaxThreads, CC](s).manager
