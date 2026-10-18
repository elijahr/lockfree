## Compile-fail control: calling `pushBottom` on a `DequeThiefTag` bound endpoint is rejected.
import lockfree

var d = initChaseLevDeque[int](16)
withBoundThief(d, thief):
  thief.pushBottom(42)
