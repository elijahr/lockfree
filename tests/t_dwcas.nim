## Unit tests for 16-byte Double-Width Compare-and-Swap (DWCAS) operations.
##
## Verifies 64-bit DWCAS correctness across compiler backends:
## - MSVC (vcc): _InterlockedCompareExchange128
## - GCC (MinGW / Linux): __sync_val_compare_and_swap on __int128 (cmpxchg16b with -mcx16)
## - Clang: __atomic_compare_exchange_n / __atomic_load_n
##
## Tested primitives on Atomic[Pair[uint64, uint64]]:
## 1. load / store round-trips with seq_cst guarantees.
## 2. exchange returning prior value.
## 3. compareExchangeStrong (success and failure updating expected).
## 4. compareExchangeWeak in a CAS loop.
## 5. Componentwise fetchAdd, fetchSub, fetchAnd, fetchOr, fetchXor.
## 6. Multi-threaded contention verification (8 threads x 5,000 ops) ensuring no torn words.

import unittest2
import lockfree/atomics

template makePair(a: uint64, b: uint64): Pair[uint64, uint64] =
  Pair[uint64, uint64](first: a, second: b)

suite "64-bit DWCAS (128-bit) Atomics Verification":

  test "Pair[uint64, uint64] layout and 16-byte width":
    check sizeof(Pair[uint64, uint64]) == 16
    check sizeof(Atomic[Pair[uint64, uint64]]) == 16

  test "DWCAS load and store round-trip":
    var a: Atomic[Pair[uint64, uint64]]
    store(a, makePair(0x1234_5678_9ABC_DEF0'u64, 0x0FED_CBA9_8765_4321'u64))
    let val = load(a)
    check val.first == 0x1234_5678_9ABC_DEF0'u64
    check val.second == 0x0FED_CBA9_8765_4321'u64

  test "DWCAS exchange":
    var a: Atomic[Pair[uint64, uint64]]
    store(a, makePair(100'u64, 200'u64))
    let prev = exchange(a, makePair(300'u64, 400'u64))
    check prev.first == 100'u64
    check prev.second == 200'u64
    let cur = load(a)
    check cur.first == 300'u64
    check cur.second == 400'u64

  test "DWCAS compareExchangeStrong success":
    var a: Atomic[Pair[uint64, uint64]]
    store(a, makePair(10'u64, 20'u64))
    var expected = makePair(10'u64, 20'u64)
    let desired = makePair(30'u64, 40'u64)
    let ok = compareExchangeStrong(a, expected, desired, moSequentiallyConsistent, moSequentiallyConsistent)
    check ok == true
    check expected.first == 10'u64
    check expected.second == 20'u64
    let cur = load(a)
    check cur.first == 30'u64
    check cur.second == 40'u64

  test "DWCAS compareExchangeStrong failure updates expected":
    var a: Atomic[Pair[uint64, uint64]]
    store(a, makePair(55'u64, 66'u64))
    var expected = makePair(11'u64, 22'u64)
    let desired = makePair(99'u64, 88'u64)
    let ok = compareExchangeStrong(a, expected, desired, moSequentiallyConsistent, moSequentiallyConsistent)
    check ok == false
    check expected.first == 55'u64
    check expected.second == 66'u64
    let cur = load(a)
    check cur.first == 55'u64
    check cur.second == 66'u64

  test "DWCAS compareExchangeWeak CAS-loop":
    var a: Atomic[Pair[uint64, uint64]]
    store(a, makePair(1'u64, 1'u64))
    var expected = load(a)
    var success = false
    while not success:
      let desired = makePair(expected.first + 10'u64, expected.second + 20'u64)
      success = compareExchangeWeak(a, expected, desired, moSequentiallyConsistent, moSequentiallyConsistent)
    check success == true
    let cur = load(a)
    check cur.first == 11'u64
    check cur.second == 21'u64

  test "DWCAS fetchAdd componentwise":
    var a: Atomic[Pair[uint64, uint64]]
    store(a, makePair(100'u64, 200'u64))
    let prev = fetchAdd(a, makePair(50'u64, 75'u64))
    check prev.first == 100'u64
    check prev.second == 200'u64
    let cur = load(a)
    check cur.first == 150'u64
    check cur.second == 275'u64

  test "DWCAS fetchSub componentwise":
    var a: Atomic[Pair[uint64, uint64]]
    store(a, makePair(150'u64, 275'u64))
    let prev = fetchSub(a, makePair(50'u64, 75'u64))
    check prev.first == 150'u64
    check prev.second == 275'u64
    let cur = load(a)
    check cur.first == 100'u64
    check cur.second == 200'u64

  test "DWCAS fetchAnd, fetchOr, fetchXor bitwise":
    var a: Atomic[Pair[uint64, uint64]]
    store(a, makePair(0xFF00_FF00'u64, 0x00FF_00FF'u64))
    discard fetchOr(a, makePair(0x00FF_0000'u64, 0x0000_FF00'u64))
    var cur = load(a)
    check cur.first == 0xFFFF_FF00'u64
    check cur.second == 0x00FF_FFFF'u64

    discard fetchAnd(a, makePair(0x0FFF_0000'u64, 0x0000_FFF0'u64))
    cur = load(a)
    check cur.first == 0x0FFF_0000'u64
    check cur.second == 0x0000_FFF0'u64

    discard fetchXor(a, makePair(0x0FFF_0000'u64, 0x0000_FFF0'u64))
    cur = load(a)
    check cur.first == 0'u64
    check cur.second == 0'u64

var dwcasContentionVar: Atomic[Pair[uint64, uint64]]

proc dwcasContentionWorker() {.thread.} =
  for _ in 0 ..< 5000:
    discard fetchAdd(dwcasContentionVar, makePair(1'u64, 2'u64))

suite "64-bit DWCAS Multi-threaded Contention":
  test "8 threads concurrent fetchAdd — zero torn words":
    const Threads = 8
    const Iters = 5000
    store(dwcasContentionVar, makePair(0'u64, 0'u64))

    var threads: array[Threads, Thread[void]]
    for i in 0 ..< Threads:
      createThread(threads[i], dwcasContentionWorker)
    for i in 0 ..< Threads:
      joinThread(threads[i])

    let finalVal = load(dwcasContentionVar)
    check finalVal.first == uint64(Threads * Iters)
    check finalVal.second == uint64(Threads * Iters * 2)
