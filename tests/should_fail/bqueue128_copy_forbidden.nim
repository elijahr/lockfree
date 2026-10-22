## Compile-fail negative control: BQueue128 cannot be copied.
import lockfree/bqueue128

proc testCopy() =
  var q1 = initBQueue128[int, 16]()
  var q2 = q1 # Triggers =copy
  discard q1
  discard q2

testCopy()
