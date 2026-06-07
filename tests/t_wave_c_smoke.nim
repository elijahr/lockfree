## Wave C smoke: instantiate BQueue and Queue for the 4 admit-arms
## (ref T, string, seq[U], POD) across all 4 cardinality combinations
## of BQueue. Compile-only — exercises the generic elaboration of the
## Path-C through-typestate wiring.
##
## See AGENTS.md (v5.0.0 wave) for the SlotEncoding mapping:
##   ref X  -> ManagedRef[X]
##   string -> ManagedSlice[char]
##   seq[U] -> ManagedSlice[U]
##   POD    -> T (identity)
##
## Functional sanity:
##   * MPMC bounded with string T (the v5.0.0 wave blocker before
##     Path-C wiring).
##   * MPMC bounded with ref T.

import options
import unittest2

import lockfree/bqueue
import lockfree/endpoint
import lockfree/role_tags
import lockfree/internal/pinscope_stub
import lockfree/reclamation
import lockfree/strategy

type Foo = object
  v: int

suite "wave-c 12-combo bqueue compile smoke":
  test "spsc bounded — ref T":
    var q = newBQueue[ref Foo, ccSingle, ccSingle, 16, 0, 0]()
    check q.pop().isNone
  test "spsc bounded — string":
    var q = newBQueue[string, ccSingle, ccSingle, 16, 0, 0]()
    check q.pop().isNone
  test "spsc bounded — seq[int]":
    var q = newBQueue[seq[int], ccSingle, ccSingle, 16, 0, 0]()
    check q.pop().isNone

  test "mpsc bounded — ref T":
    var q = newBQueue[ref Foo, ccMulti, ccSingle, 16, 4, 0]()
    check q.pop().isNone
  test "mpsc bounded — string":
    var q = newBQueue[string, ccMulti, ccSingle, 16, 4, 0]()
    check q.pop().isNone
  test "mpsc bounded — seq[int]":
    var q = newBQueue[seq[int], ccMulti, ccSingle, 16, 4, 0]()
    check q.pop().isNone

  test "spmc bounded — ref T":
    var q = newBQueue[ref Foo, ccSingle, ccMulti, 16, 0, 4]()
    var c = q.getConsumerHere(0)
    check c.pop().isNone
  test "spmc bounded — string":
    var q = newBQueue[string, ccSingle, ccMulti, 16, 0, 4]()
    var c = q.getConsumerHere(0)
    check c.pop().isNone
  test "spmc bounded — seq[int]":
    var q = newBQueue[seq[int], ccSingle, ccMulti, 16, 0, 4]()
    var c = q.getConsumerHere(0)
    check c.pop().isNone

  test "mpmc bounded — ref T":
    var q = newBQueue[ref Foo, ccMulti, ccMulti, 16, 4, 4]()
    var c = q.getConsumerHere(0)
    check c.pop().isNone
  test "mpmc bounded — string":
    var q = newBQueue[string, ccMulti, ccMulti, 16, 4, 4]()
    var c = q.getConsumerHere(0)
    check c.pop().isNone
  test "mpmc bounded — seq[int]":
    var q = newBQueue[seq[int], ccMulti, ccMulti, 16, 4, 4]()
    var c = q.getConsumerHere(0)
    check c.pop().isNone

suite "wave-c bqueue functional roundtrip":
  test "mpmc bounded — push then pop string":
    var q = newBQueue[string, ccMulti, ccMulti, 16, 4, 4]()
    var p = q.getProducerHere(0)
    var c = q.getConsumerHere(0)
    check p.push("hello")
    let r = c.pop()
    check r.isSome
    check r.get == "hello"

  test "mpmc bounded — push then pop ref":
    var q = newBQueue[ref Foo, ccMulti, ccMulti, 16, 4, 4]()
    var p = q.getProducerHere(0)
    var c = q.getConsumerHere(0)
    var f: ref Foo
    new(f)
    f.v = 42
    check p.push(f)
    let r = c.pop()
    check r.isSome
    check r.get.v == 42

  test "spsc bounded — push then pop string":
    var q = newBQueue[string, ccSingle, ccSingle, 16, 0, 0]()
    check q.push("alpha")
    let r = q.pop()
    check r.isSome
    check r.get == "alpha"

  test "mpsc bounded — push then pop seq[int]":
    var q = newBQueue[seq[int], ccMulti, ccSingle, 16, 4, 0]()
    var p = q.getProducerHere(0)
    check p.push(@[1, 2, 3])
    let r = q.pop()
    check r.isSome
    check r.get == @[1, 2, 3]
