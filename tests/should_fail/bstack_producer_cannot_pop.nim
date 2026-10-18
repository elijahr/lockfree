## Compile-fail control: calling `pop` on a `MpmcProducerTag` BStack endpoint is rejected.
import lockfree

var s = initBStack[int, 16]()
withBoundProducer(s, prod):
  discard prod.push(10)
  discard prod.pop()
