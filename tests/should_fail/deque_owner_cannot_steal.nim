## Compile-fail control: calling `steal` on a `DequeOwnerTag` bound endpoint is rejected.
import lockfree

var d = initChaseLevDeque[int](16)
withBoundOwner(d, owner):
  owner.pushBottom(42)
  discard owner.steal()
