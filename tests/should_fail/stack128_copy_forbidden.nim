## Compile-fail negative control: TaggedStack/Stack128 cannot be copied.
import lockfree/stack128

proc testCopy() =
  var s1 = initTaggedStack[int]()
  var s2 = s1 # Triggers =copy
  discard s1
  discard s2

testCopy()
