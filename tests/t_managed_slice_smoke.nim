## Smoke coverage for ``lockfree/managed_slice``.
##
## Exercises wrap/unwrap roundtrip for string + seq[U], ABI identity
## with ``uint``, POD-seq positive, and ``disposeSlot`` on both
## the nil slot and a populated slot.
##
## Does NOT exercise queue/bqueue. This is module isolation only.
##
## Lifecycle discipline: ``wrap`` consumes its argument (``sink``)
## and returns ownership of the heap-boxed payload. ``unwrap`` moves
## the payload back out and frees the box. ``disposeSlot`` is the
## destroy-walk counterpart for un-popped slots; the comprehensive
## leak suite lives in the valgrind CI cell.

import lockfree/managed_slice

# wrap/unwrap roundtrip — string
block:
  let original = "hello, world"
  let ms = wrap("hello, world")
  let back = unwrap(ms)
  doAssert back == original

# wrap/unwrap roundtrip — seq[int]
block:
  let original = @[1, 2, 3, 4, 5]
  let ms = wrap(@[1, 2, 3, 4, 5])
  let back = unwrap(ms)
  doAssert back == original

# Empty string
block:
  let ms = wrap("")
  let back = unwrap(ms)
  doAssert back == ""

# Empty seq
block:
  let ms = wrap(newSeq[int]())
  let back = unwrap(ms)
  doAssert back == @[]

# ABI — sizeof identity with uint
static:
  doAssert sizeof(ManagedSlice[char]) == sizeof(uint)
  doAssert sizeof(ManagedSlice[int]) == sizeof(uint)
  doAssert sizeof(ManagedSlice[float]) == sizeof(uint)

# disposeSlot — empty (nil) slot is safe
block:
  var ms = ManagedSlice[char](0)
  disposeSlot(ms)  # should not crash

block:
  var ms = ManagedSlice[int](0)
  disposeSlot(ms)

# disposeSlot — non-empty slot frees the box without crash. Leak /
# double-free detection lives in the valgrind CI cell.
block:
  let ms = wrap("payload to dispose")
  disposeSlot(ms)

block:
  let ms = wrap(@[7, 8, 9])
  disposeSlot(ms)

echo "managed_slice smoke OK"
