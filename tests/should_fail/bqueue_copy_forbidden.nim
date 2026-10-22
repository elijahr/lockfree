## Compile-fail negative control: BQueue cannot be copied.
import lockfree/bqueue

proc testCopy() =
  var q1 = initBoundedQueue[int, ccSingle, ccSingle, 16, 0, 0]()
  var q2 = q1 # Triggers =copy
  discard q1
  discard q2

testCopy()
