## tests/t_pinscope_unwind.nim
##
## Pinscope unwind on raise. `PinnedScope[MT, CC]` is
## destructor-driven: raising inside the scope block invokes the
## destructor on unwind, which in turn drives `unpin` /
## (`acknowledge` if signaled) / `close` and clears the slot's
## `pinned` flag.
##
## This file is the regression test the docstring on
## `src/lockfree/smr/nebr/typestates/pinned_scope.nim:pinScope` cites
## under its "Cleanup contract" subsection. It runs across
## `arc / orc / atomicArc` via the per-MM lane sweep.

import std/unittest
import lockfree/atomics
import lockfree/smr/nebr

suite "pinScope unwind":
  test "raise inside pinScope releases the slot pin via =destroy":
    var manager = initDebraManager[4]()
    setGlobalManager(addr manager)
    let handle = registerThread(manager)

    var raised = false
    try:
      block:
        var scope = pinScope(unpinned(handle))
        # Touch `scope` so the move analyser cannot elide the local
        # before the raise. The destructor MUST run on the unwind path.
        doAssert not scope.consumed
        raise newException(CatchableError, "synthetic — pinscope unwind")
    except CatchableError:
      raised = true

    check raised
    # After the unwind the slot's `pinned` flag must be clear: the
    # destructor drove `unpin -> close` (or
    # `unpin -> acknowledge -> close` if the slot had been signaled
    # under a stall scan, which this test does not exercise).
    check not handle.manager.threads[handle.idx].pinned.load(moRelaxed)

    unregisterThread(manager, handle)
