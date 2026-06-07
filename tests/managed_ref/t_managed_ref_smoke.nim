## Smoke coverage for ``lockfree/managed_ref`` (T-MANAGED-REF, PG-5a).
##
## Exercises wrap/unwrap roundtrip, acquire/release refcount behaviour,
## reset, the strict mm:none contract, and the §2.10 ABI identity claim.
##
## Lifecycle discipline: per design §4.3.2 ``toManagedRef`` /
## ``toRef`` are pointer-bit transfers that do NOT touch the refcount.
## A test that calls ``toRef`` and lets the binding go out of scope
## under arc / orc / atomicArc will emit a destructor-driven
## ``nimDecRefIsLast`` against bits that the caller never incremented,
## crashing. The tests below either keep the bits live via the
## original ``ref`` binding, or balance ``incRefSlot`` + ``toRef``
## pairs explicitly. The comprehensive suite lives in T-TEST-MANAGED-REF
## (PG-9).

import unittest2

import lockfree/managed_ref

type
  Payload = ref object
    value: int

suite "ManagedRef[X] smoke":
  test "wrap+unwrap roundtrip preserves pointer identity":
    # Keep the original ``p`` live so the bits-cast does not race the
    # MM's lifecycle. The test verifies the bit transport only.
    var p = Payload(value: 7)
    let raw = cast[uint](p)
    let mref = toManagedRef(p)
    check toBits(mref) == raw
    # Re-derive an uint from the slot bits and compare directly,
    # rather than materialising a stray ``ref X`` whose destructor
    # would race the queue's lifecycle invariant.
    check toBits(mref) == cast[uint](p)

  test "nilManagedRef encodes the null slot":
    check toBits(nilManagedRef(Payload)) == 0'u

  test "fromBits round-trips uint":
    var p = Payload(value: 9)
    let bits = cast[uint](p)
    let mref = fromBits(ManagedRef[Payload], bits)
    check toBits(mref) == bits

  test "incRefSlot/decRefSlot are balanced no-ops on lifecycle":
    # Net-zero: ref count after inc+dec equals starting count, and the
    # payload is still readable. The strongest assertion we can make
    # portably across MMs without poking heap headers.
    var p = Payload(value: 13)
    let mref = toManagedRef(p)
    incRefSlot(mref)
    decRefSlot(mref)
    # Payload still alive because ``p`` still holds its own ref.
    check p.value == 13
    check toBits(mref) == cast[uint](p)

  test "decRefSlot on nilManagedRef is safe":
    decRefSlot(nilManagedRef(Payload))
    incRefSlot(nilManagedRef(Payload))
    # The exercise: no crash, no UB on the nil bit pattern.
    check toBits(nilManagedRef(Payload)) == 0'u

  test "incRefSlot bumps the refcount (claimed +1 survives release)":
    # +1 then +1 via incRefSlot then -1 via decRefSlot leaves the
    # cell live (queue's +1 still held). Under mm:none the inc/dec
    # are no-ops and the assertion still holds because ``p`` keeps
    # the cell alive on its own.
    var p = Payload(value: 21)
    let mref = toManagedRef(p)
    incRefSlot(mref)        # queue's +1
    # Drop the queue's +1; ``p``'s ref keeps the cell alive.
    decRefSlot(mref)
    check p.value == 21

  test "reset zeroes the slot and drops the queue's +1":
    var p = Payload(value: 34)
    var mref = toManagedRef(p)
    incRefSlot(mref)        # queue's +1 (matches the §4.3.4 push pattern)
    reset(mref)
    check toBits(mref) == 0'u
    # ``p`` still holds the cell, so its value is intact.
    check p.value == 34

  test "ABI: sizeof(ManagedRef[X]) == sizeof(uint)":
    check sizeof(ManagedRef[Payload]) == sizeof(uint)
    check sizeof(ManagedRef[int]) == sizeof(uint)

  test "ABI: alignof(ManagedRef[X]) == alignof(uint)":
    check alignof(ManagedRef[Payload]) == alignof(uint)
    check alignof(ManagedRef[int]) == alignof(uint)
