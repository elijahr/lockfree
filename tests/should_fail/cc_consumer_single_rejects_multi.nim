## §6.3 condition (2) / brief §3.3: a Queue with `ccCons == ccSingle`
## rejects a `ccMulti` DebraManager/handle pair.
##
## `newUnboundedMpscQueue` (`ccMulti × ccSingle`) borrow-overload
## requires `DebraManager[MT, nebr.ccSingle]` and
## `ThreadHandle[MT, nebr.ccSingle]` / §3.1. Passing
## a ccMulti-cardinality manager/handle pair must fail type-checking.

import lockfree/queue
import lockfree/strategy
import lockfree/reclamation
import lockfree/internal/pinscope_stub

import lockfree/smr/nebr as debra_mod
from lockfree/smr/nebr import initDebraManager, registerThread

proc main() =
  var manager = initDebraManager[4, debra_mod.ccMulti]()
  let handle = registerThread(manager) # ThreadHandle[4, nebr.ccMulti]
  # newUnboundedMpscQueue's borrow overload requires
  # `DebraManager[4, nebr.ccSingle]`; passing the ccMulti pair must
  # fail type-checking with a type-mismatch error.
  var q = newUnboundedMpscQueue[int, stEager, 16, 4](addr manager, handle)
  discard q.segmentCount()

main()
