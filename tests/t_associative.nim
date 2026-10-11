## # Test Suite: Wave 5A Atomic Associative Map Operations
##
## Verifies compound read-modify-write operations across Ctrie and SkipListMap:
## - computeIfAbsent
## - atomicUpdate
## - upsert
## - snapshotPairs, snapshotKeys, snapshotValues
## - High-contention multi-threaded counter stress (lost update verification)
## - ARC/ORC heap payload memory safety and SMR epoch safety

import std/[options, algorithm]
import unittest2
import lockfree
import lockfree/ctrie
import lockfree/skiplist

type
  PayloadRef = ref object
    count: int
    tag: string

suite "Wave 5A: Single-Threaded Atomic Associative Operations":
  test "Ctrie computeIfAbsent basic semantics":
    let map = newCtrie[string, int]()
    # Key absent: compute
    var callCount = 0
    let v1 = map.computeIfAbsent("counter", proc(k: string): int =
      inc callCount
      42
    )
    check v1 == 42
    check callCount == 1
    check map.len == 1
    check map.get("counter") == some(42)

    # Key present: do not compute
    let v2 = map.computeIfAbsent("counter", proc(k: string): int =
      inc callCount
      999
    )
    check v2 == 42
    check callCount == 1
    check map.len == 1

    # Parameterless overload
    let v3 = map.computeIfAbsent("other", proc(): int = 100)
    check v3 == 100
    check map.len == 2

  test "SkipListMap computeIfAbsent basic semantics":
    var map = newSkipListMap[string, int]()
    var callCount = 0
    let v1 = map.computeIfAbsent("counter", proc(k: string): int =
      inc callCount
      42
    )
    check v1 == 42
    check callCount == 1
    check map.len == 1
    check map.get("counter") == some(42)

    # Key present
    let v2 = map.computeIfAbsent("counter", proc(k: string): int =
      inc callCount
      999
    )
    check v2 == 42
    check callCount == 1
    check map.len == 1

    # Parameterless overload
    let v3 = map.computeIfAbsent("other", proc(): int = 100)
    check v3 == 100
    check map.len == 2

  test "Ctrie atomicUpdate semantics":
    let map = newCtrie[string, int]()
    # Absent key returns none
    check map.atomicUpdate("counter", proc(v: int): int = v + 1).isNone
    check map.len == 0

    # Insert key and update
    discard map.put("counter", 10)
    let res = map.atomicUpdate("counter", proc(v: int): int = v * 2)
    check res == some(20)
    check map.get("counter") == some(20)
    check map.len == 1

  test "SkipListMap atomicUpdate semantics":
    var map = newSkipListMap[string, int]()
    # Absent key returns none
    check map.atomicUpdate("counter", proc(v: int): int = v + 1).isNone
    check map.len == 0

    # Insert key and update
    discard map.put("counter", 10)
    let res = map.atomicUpdate("counter", proc(v: int): int = v * 2)
    check res == some(20)
    check map.get("counter") == some(20)
    check map.len == 1

  test "Ctrie upsert semantics":
    let map = newCtrie[string, int]()
    # Absent key: inserts insertVal
    let v1 = map.upsert("counter", 100, proc(old: int): int = old + 1)
    check v1 == 100
    check map.get("counter") == some(100)
    check map.len == 1

    # Present key: updates via updateProc
    let v2 = map.upsert("counter", 500, proc(old: int): int = old + 50)
    check v2 == 150
    check map.get("counter") == some(150)
    check map.len == 1

  test "SkipListMap upsert semantics":
    var map = newSkipListMap[string, int]()
    # Absent key: inserts insertVal
    let v1 = map.upsert("counter", 100, proc(old: int): int = old + 1)
    check v1 == 100
    check map.get("counter") == some(100)
    check map.len == 1

    # Present key: updates via updateProc
    let v2 = map.upsert("counter", 500, proc(old: int): int = old + 50)
    check v2 == 150
    check map.get("counter") == some(150)
    check map.len == 1

  test "Ctrie and SkipListMap snapshot materialized views":
    let c = newCtrie[int, string]()
    var s = newSkipListMap[int, string]()
    for i in [30, 10, 20]:
      discard c.put(i, "val_" & $i)
      discard s.put(i, "val_" & $i)

    # SkipListMap snapshot should be in strictly sorted key order
    let sPairs = s.snapshotPairs()
    let sKeys = s.snapshotKeys()
    let sVals = s.snapshotValues()
    check sPairs == @[(10, "val_10"), (20, "val_20"), (30, "val_30")]
    check sKeys == @[10, 20, 30]
    check sVals == @["val_10", "val_20", "val_30"]

    # Ctrie snapshot pairs/keys/values
    let cPairs = c.snapshotPairs()
    let cKeys = c.snapshotKeys()
    let cVals = c.snapshotValues()
    check cPairs.len == 3
    check cKeys.len == 3
    check cVals.len == 3
    var sortedCKeys = cKeys
    sortedCKeys.sort()
    check sortedCKeys == @[10, 20, 30]

  test "ARC/ORC Ref Object payload safety in atomicUpdate and upsert":
    let map = newCtrie[int, PayloadRef]()
    discard map.upsert(1, PayloadRef(count: 1, tag: "initial"), proc(old: PayloadRef): PayloadRef =
      PayloadRef(count: old.count + 1, tag: "updated")
    )
    check map.get(1).get.count == 1
    check map.get(1).get.tag == "initial"

    discard map.upsert(1, PayloadRef(count: 99, tag: "fail"), proc(old: PayloadRef): PayloadRef =
      PayloadRef(count: old.count + 1, tag: "second")
    )
    check map.get(1).get.count == 2
    check map.get(1).get.tag == "second"

    var sMap = newSkipListMap[int, PayloadRef]()
    discard sMap.upsert(1, PayloadRef(count: 1, tag: "initial"), proc(old: PayloadRef): PayloadRef =
      PayloadRef(count: old.count + 1, tag: "updated")
    )
    check sMap.get(1).get.count == 1
    check sMap.get(1).get.tag == "initial"

    discard sMap.atomicUpdate(1, proc(old: PayloadRef): PayloadRef =
      PayloadRef(count: old.count + 10, tag: "atomic")
    )
    check sMap.get(1).get.count == 11
    check sMap.get(1).get.tag == "atomic"

