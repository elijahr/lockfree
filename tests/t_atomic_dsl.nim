import lockfree/atomics
import lockfree/atomics/dsl
import unittest2

import lockfree
import lockfree/endpoint
import lockfree/role_tags

suite "atomic_dsl":
  var atom: Atomic[int]

  test "integration":
    atom.relaxed(1)
    assert(atom.relaxed == 1)
    atom.relaxed(2)
    assert(atom.acquire == 2)
