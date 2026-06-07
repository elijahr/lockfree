## §2.5 Row 8 REJECT — `ref ref X` must trigger the documented
## `{.error.}` from `src/lockfree/internal/path_c_admit.nim` L76-79.
##
## Pinned substring: "nested ref" (verbatim from path_c_admit.nim).
##
## The admit gate fires inside `push` (see bqueue.nim L416, etc.). A bare
## type instantiation is not enough — we must call `push` to materialise
## the static-dispatch chain.

import lockfree
import lockfree/bqueue as q_mod

type
  Foo = ref object
    v: int
  RefRefFoo = ref Foo  # `ref Foo` where Foo itself is a ref => `ref ref X`

var q = q_mod.newBQueue[RefRefFoo, ccSingle, ccSingle, 16, 0, 0]()
let inner: Foo = new(Foo)
inner.v = 2
let outer: RefRefFoo = new(RefRefFoo)
outer[] = inner
discard q.push(outer)
