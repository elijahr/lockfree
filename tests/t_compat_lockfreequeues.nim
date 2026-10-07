import unittest2
import options

# Test both top-level and path imports
import lockfree/compat/lockfreequeues
import lockfreequeues

suite "lockfreequeues compatibility shim — type aliases & bounded constructors":
  test "DEFECT-CRIT-01: bounded constructor arity overloads":
    # 2-param and 4-param overloads for newSipsicQueue
    var s1 = newSipsicQueue[int, 8]()
    var s2 = newSipsicQueue[int, 8, 0, 0]()
    check s1.capacity == 8
    check s2.capacity == 8
    check s1.pop().isNone
    check s1.push(42)
    let val = s1.pop()
    check val.isSome and val.get == 42
    check s1.pop().isNone

    # 3-param and 4-param overloads for newMupsicQueue
    var m1 = newMupsicQueue[int, 8, 2]()
    var m2 = newMupsicQueue[int, 8, 2, 0]()
    check m1.capacity == 8
    check m2.capacity == 8

    # newSipmucQueue
    var sm = newSipmucQueue[int, 8, 2]()
    check sm.capacity == 8

    # 4-param overload for newMupmucQueue
    var mm = newMupmucQueue[int, 8, 2, 2]()
    check mm.capacity == 8

  test "legacy init* constructors (capacity first, T last)":
    var s = initSipsic[8, int]()
    check s.capacity == 8
    check s.push(10)
    check s.pop().get == 10

    var m = initMupsic[8, 2, int]()
    check m.capacity == 8

    var sm = initSipmuc[8, 2, int]()
    check sm.capacity == 8

    var mm = initMupmuc[8, 2, 2, int]()
    check mm.capacity == 8

  test "bounded type aliases instantiation":
    var s: Sipsic[8, int] = initSipsic[8, int]()
    var m: Mupsic[8, 2, int] = initMupsic[8, 2, int]()
    var sm: Sipmuc[8, 2, int] = initSipmuc[8, 2, int]()
    var mm: Mupmuc[8, 2, 2, int] = initMupmuc[8, 2, 2, int]()
    check s.capacity == 8
    check m.capacity == 8
    check sm.capacity == 8
    check mm.capacity == 8

suite "lockfreequeues compatibility shim — unbounded queues & DEFECT-WARN-01":
  test "unbounded constructors and type aliases":
    var us: UnboundedSipsic[8, int] = newUnboundedSipsic[8, int]()
    check us.len == 0
    check us.empty
    check not us.full
    check us.segmentCount == 1

    var umps: UnboundedMupsic[8, int, 4] = newUnboundedMupsic[8, int, 4]()
    check umps.len == 0

    var uspm: UnboundedSipmuc[8, int, 4] = newUnboundedSipmuc[8, int, 4]()
    check uspm.len == 0

    var umpm: UnboundedMupmuc[8, int, 4] = newUnboundedMupmuc[8, int, 4]()
    check umpm.len == 0

    # Test modern-style aliases (T first)
    var q1 = newUnboundedSipsicQueue[int, 8]()
    var q2 = newUnboundedMupsicQueue[int, 8, 4]()
    var q3 = newUnboundedSipmucQueue[int, 8, 4]()
    var q4 = newUnboundedMupmucQueue[int, 8, 4]()
    check q1.len == 0
    check q2.len == 0
    check q3.len == 0
    check q4.len == 0

  test "DEFECT-WARN-01: auto-attach on unbounded getProducer and getConsumer":
    var q = newUnboundedMupmuc[8, int, 4]()

    # In v4.2.0, getProducer() and getConsumer() return immediately usable endpoints
    var prod = q.getProducer()
    check prod.isAttached
    # Idempotent attach
    var prodAttached = prod.attach()
    check prodAttached.isAttached

    # Push immediately without manual .bindToThread()
    prod.push(100)
    prod.push(200)
    check q.len == 2

    # Consumer auto-attach
    var cons = q.getConsumer()
    check cons.isAttached
    let item1 = cons.pop()
    check item1.isSome and item1.get == 100
    let item2 = cons.pop()
    check item2.isSome and item2.get == 200
    check cons.pop().isNone
    check q.len == 0

  test "batch push and batch pop on endpoints":
    var q = newUnboundedMupmuc[8, int, 4]()
    var prod = q.getProducer()
    var cons = q.getConsumer()

    prod.push([1, 2, 3, 4, 5])
    check q.len == 5

    let batch = cons.pop(3)
    check batch.isSome and batch.get == @[1, 2, 3]
    check q.len == 2

    let rest = cons.pop(3)
    check rest.isSome and rest.get == @[4, 5]
    check q.len == 0
    check cons.pop(1).isNone

  test "bounded MPMC getProducer / getConsumer auto-attach":
    var q = initMupmuc[8, 2, 2, int]()
    var prod = q.getProducer()
    var cons = q.getConsumer()
    check prod.idx >= 0
    check cons.idx >= 0

    check prod.push(77)
    check cons.pop().get == 77
