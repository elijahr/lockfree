import std/unittest
import lockfree/endpoint
import lockfree/role_tags

type DummyQueue = object

suite "endpoint types compile":
  test "Unbound[T, Tag, queueT] is a value type":
    var u: Unbound[int, AnyThreadTag, DummyQueue]
    check u.idx == 0

  test "Bound and Closed also instantiate":
    var b: Bound[int, AnyThreadTag, DummyQueue]
    var c: Closed[int, AnyThreadTag, DummyQueue]
    check b.idx == 0
    discard c
