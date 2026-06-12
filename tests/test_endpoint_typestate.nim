import std/unittest
import lockfree/endpoint
import lockfree/role_tags

type DummyQueue = object

suite "endpoint typestate":
  test "single Endpoint typestate verifies":
    # verifyTypestates() in endpoint.nim runs at module-import time.
    # If the FSM declaration (Unbound -> Bound -> Closed) is rejected by
    # typestates 0.12.0's AST verifier, this importing test fails to
    # compile. Reaching the runtime body proves the FSM was accepted.
    # Lifecycle transitions themselves are exercised once C5 (bindToThread)
    # and C6 (close) ship transition procs; role distinctness lives at
    # C9 under the Tag generic + effect-tag pragmas.
    var u: Unbound[int, AnyThreadTag, DummyQueue]
    check u.queue == nil
