## ==============================================================================
## Unit & Behavioral Tests for Lock-Free 128-Bit DWCAS AtomicArc[T] & ArcGuard[T]
## ==============================================================================

import std/[options, strutils]
import unittest2
import lockfree
import lockfree/atomic_arc
import lockfree/atomics

type
  TrackedConfig = object
    id: int
    label: string
    destroyedCounter: ptr Atomic[int]

proc `=destroy`(x: var TrackedConfig) =
  if x.destroyedCounter != nil:
    discard x.destroyedCounter[].fetchAdd(1, moSequentiallyConsistent)
    x.destroyedCounter = nil
  `=destroy`(x.label)

proc `=copy`(dest: var TrackedConfig, src: TrackedConfig) =
  if dest.destroyedCounter != src.destroyedCounter or dest.id != src.id:
    `=destroy`(dest)
  dest.id = src.id
  dest.label = src.label
  dest.destroyedCounter = nil # only the original sink instance tracks destruction

proc `=sink`(dest: var TrackedConfig, src: TrackedConfig) =
  `=destroy`(dest)
  dest.id = src.id
  dest.label = src.label
  dest.destroyedCounter = src.destroyedCounter

proc makeTracked(id: int, label: string, counter: ptr Atomic[int]): TrackedConfig =
  result.id = id
  result.label = label
  result.destroyedCounter = counter

suite "AtomicArc[T] & ArcGuard[T] (128-Bit DWCAS Split-Refcount)":

  test "Empty AtomicArc initialization, load, storeNil, and isNil":
    var arc = initAtomicArc[int]()
    check arc.isNil == true
    let g0 = arc.load()
    check g0.isNil == true
    check g0.rawPtr == nil
    check g0.tryGet().isNone
    check arc.loadOpt().isNone

    arc.store(42)
    check arc.isNil == false
    let g1 = arc.load()
    check g1.isNil == false
    check g1.get() == 42
    check g1[] == 42
    check g1.rawPtr != nil
    check g1.rawPtr[] == 42
    check g1.tryGet() == some(42)
    check arc.loadOpt() == some(42)

    arc.storeNil()
    check arc.isNil == true
    # Existing guard g1 keeps the payload alive even after arc is cleared!
    check g1.get() == 42

  test "SharedPtr[T] & AtomicSharedPtr[T] aliases, clone, reset, and equality":
    var g1 = initSharedPtr[string]("alpha-config")
    var g2 = g1.clone()
    check g1 == g2
    check g1.get() == "alpha-config"
    check g2.get() == "alpha-config"

    var sp = initAtomicSharedPtr[string](g1)
    check not sp.isNil
    let g3 = sp.load()
    check g3 == g1
    check g3.get() == "alpha-config"

    g2.reset()
    check g2.isNil
    check g1.get() == "alpha-config"

  test "Deterministic ARC/ORC destructor reclamation and deferred guard survival":
    var destroyed: Atomic[int]
    destroyed.store(0, moRelaxed)

    block:
      var arc = initAtomicArc[TrackedConfig](makeTracked(10, "v1-payload", addr destroyed))
      check destroyed.load(moSequentiallyConsistent) == 0

      # Acquire two guards to v1
      var gA = arc.load()
      var gB = arc.load()
      check gA.get().id == 10
      check gB.get().label == "v1-payload"

      # Replace v1 with v2 in the AtomicArc slot
      arc.store(makeTracked(20, "v2-payload", addr destroyed))
      # v1 MUST NOT be destroyed yet because gA and gB still hold references!
      check destroyed.load(moSequentiallyConsistent) == 0
      check gA.get().id == 10
      check gB.get().id == 10

      # Release gA -> v1 still kept alive by gB
      gA.reset()
      check destroyed.load(moSequentiallyConsistent) == 0
      check gB.get().id == 10

      # Release gB -> v1's last reference drops; v1 is deterministically destroyed!
      gB.reset()
      check destroyed.load(moSequentiallyConsistent) == 1

      # Now arc goes out of scope -> v2 is destroyed!
    check destroyed.load(moSequentiallyConsistent) == 2

  test "Self-assignment safety: arc.store(arc.load()) & arc.swap(arc.load())":
    var destroyed: Atomic[int]
    destroyed.store(0, moRelaxed)

    var arc = initAtomicArc[TrackedConfig](makeTracked(77, "self-assign", addr destroyed))
    for i in 0 ..< 10:
      arc.store(arc.load())
      check destroyed.load(moSequentiallyConsistent) == 0
      let prev = arc.swap(arc.load())
      check not prev.isNil
      check prev.get().id == 77
      check destroyed.load(moSequentiallyConsistent) == 0

    arc.storeNil()
    check destroyed.load(moSequentiallyConsistent) == 1

  test "swap / exchange returns displaced guard and preserves lifetime":
    var destroyed: Atomic[int]
    destroyed.store(0, moRelaxed)

    var arc = initAtomicArc[TrackedConfig](makeTracked(1, "first", addr destroyed))
    var old1 = arc.swap(makeTracked(2, "second", addr destroyed))
    check destroyed.load(moSequentiallyConsistent) == 0
    check old1.get().id == 1
    check arc.load().get().id == 2

    old1.reset()
    check destroyed.load(moSequentiallyConsistent) == 1

    var old2 = arc.exchange(ArcGuard[TrackedConfig](cb: nil))
    check arc.isNil
    check destroyed.load(moSequentiallyConsistent) == 1
    check old2.get().id == 2
    old2.reset()
    check destroyed.load(moSequentiallyConsistent) == 2

  test "compareExchange succeeds despite concurrent load() external count changes":
    var destroyed: Atomic[int]
    destroyed.store(0, moRelaxed)

    var arc = initAtomicArc[TrackedConfig](makeTracked(100, "initial", addr destroyed))
    var expected = arc.load()
    # Perform extra loads so slot.first extCount advances from 1 to 5
    let extra1 = arc.load()
    let extra2 = arc.load()
    let extra3 = arc.load()
    let extra4 = arc.load()

    let desired = initArcGuard[TrackedConfig](makeTracked(200, "updated", addr destroyed))
    # compareExchange MUST succeed even though extCount changed!
    check arc.compareExchange(expected, desired) == true
    check arc.load().get().id == 200
    check destroyed.load(moSequentiallyConsistent) == 0

    # Release all guards to 100
    expected.reset()
    discard extra1.get().id
    discard extra2.get().id
    discard extra3.get().id
    discard extra4.get().id

  test "compareExchange updates expected on pointer mismatch without leaking":
    var destroyed: Atomic[int]
    destroyed.store(0, moRelaxed)

    var arc = initAtomicArc[TrackedConfig](makeTracked(1, "actual-1", addr destroyed))
    var staleExpected = initArcGuard[TrackedConfig](makeTracked(999, "stale", addr destroyed))
    var desired = initArcGuard[TrackedConfig](makeTracked(2, "desired-2", addr destroyed))

    # Mismatch: staleExpected (999) != actual (1)
    check arc.compareExchange(staleExpected, desired) == false
    # staleExpected's old 999 guard was released (destroying 999) and replaced with guard to 1!
    check destroyed.load(moSequentiallyConsistent) == 1
    check staleExpected.get().id == 1

    # Now retry with the updated staleExpected -> succeeds!
    check arc.compareExchange(staleExpected, desired) == true
    check arc.load().get().id == 2

    staleExpected.reset()
    # 1 is now destroyed!
    check destroyed.load(moSequentiallyConsistent) == 2

    desired.reset()
    arc.storeNil()
    # 2 is now destroyed!
    check destroyed.load(moSequentiallyConsistent) == 3
