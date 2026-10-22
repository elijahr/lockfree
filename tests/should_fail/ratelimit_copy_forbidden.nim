## Compile-fail negative control: TokenBucket and LeakyBucket cannot be copied.
import lockfree/ratelimit

proc testTokenBucketCopy() =
  var tb1 = initTokenBucket(capacityTokens = 10, refillRatePerSec = 5)
  var tb2 = tb1 # Triggers =copy
  discard tb1
  discard tb2

testTokenBucketCopy()
