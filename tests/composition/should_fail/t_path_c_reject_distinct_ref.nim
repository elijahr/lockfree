## §2.5 Row 7 REJECT — `distinct ref X` must trigger the documented
## `{.error.}` from `src/lockfree/internal/path_c_admit.nim` L82-86.
##
## Pinned substring: "distinct ref alias" (verbatim from path_c_admit.nim).
##
## The admit gate fires inside `push` (see bqueue.nim). A bare
## type instantiation is not enough — we must call `push` to materialise
## the static-dispatch chain.

import lockfree
import lockfree/bqueue as q_mod

type
  Foo = ref object
    v: int
  MyHandle = distinct Foo

var q = q_mod.newBQueue[MyHandle, ccSingle, ccSingle, 16, 0, 0]()
let inner: Foo = new(Foo)
inner.v = 1
discard q.push(MyHandle(inner))
