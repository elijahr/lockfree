## Compile-fail control: calling `push` on a `MpmcConsumerTag` TreiberStack endpoint is rejected.
import lockfree

var s = initTreiberStack[int]()
withBoundConsumer(s, cons):
  cons.push(99)
