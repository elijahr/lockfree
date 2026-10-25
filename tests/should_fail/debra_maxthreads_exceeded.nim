## Regression test for FIND-D1-04:
## DebraManager requires MaxThreads <= 64 because activeThreadMask is a uint64 bitmask.
## Instantiating DebraManager with MaxThreads > 64 must trigger a static assertion failure.

import lockfree/smr/nebr

proc main() =
  var manager = initDebraManager[128]()
  discard manager

main()
