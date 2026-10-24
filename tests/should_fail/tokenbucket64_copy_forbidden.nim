## Compile-fail negative control: TokenBucket64 cannot be copied.
import lockfree/ratelimit

proc testCopy() =
  var tb1 = initTokenBucket64(10, 1)
  var tb2 = tb1 # Triggers =copy
  discard tb1
  discard tb2

testCopy()
