## debra/atomics/dsl
##
## Symmetric `.relaxed/.acquire/.release/.sequential` shorthand for load and
## store. Mirrors `commit 8fb4717 src/lockfree/atomic_dsl.nim` so the lockfree
## port is a one-line `import` swap.
##
## Symmetry rule (design doc section 2):
##   * `.relaxed()` load, moRelaxed
##   * `.relaxed(v)` store, moRelaxed
##   * `.acquire()` load, moAcquire (load-only)
##   * `.release(v)` store, moRelease (store-only)
##   * `.sequential()` load, moSequentiallyConsistent
##   * `.sequential(v)` store, moSequentiallyConsistent
##
## `compareExchange` and friends stay out of the DSL. This module is opt-in;
## `import debra/atomics` does NOT bring it in.
##
## ### Name coexistence with `std/locks`
##
## The exported `acquire`/`release` take `var Atomic[T]` and intentionally
## coexist with `system`/`std/locks` `acquire`/`release` (which take a `Lock`).
## At a call site that imports both, the two overload sets are disambiguated
## purely by the first argument's type, so `acquire(x)` resolves to the lock
## primitive when `x: Lock` and to the atomic acquire-load when `x: Atomic[T]`.
## This compiles unambiguously, but a reader must check the argument's type to
## know which `acquire` is meant. This overlap is deliberate (it keeps the DSL
## terse and symmetric); if you mix `std/locks` and this DSL in one module and
## want the distinction visible at the call site, qualify the lock calls
## (`locks.acquire(l)`).

import ../atomics

proc relaxed*[T](loc: var Atomic[T]): T {.inline.} =
  ## Load `loc` with moRelaxed.
  loc.load(moRelaxed)

proc relaxed*[T](loc: var Atomic[T], value: T) {.inline.} =
  ## Store `value` into `loc` with moRelaxed.
  loc.store(value, moRelaxed)

proc acquire*[T](loc: var Atomic[T]): T {.inline.} =
  ## Load `loc` with moAcquire. Load-only by design: moAcquire is not a valid
  ## store order.
  loc.load(moAcquire)

proc release*[T](loc: var Atomic[T], value: T) {.inline.} =
  ## Store `value` into `loc` with moRelease. Store-only by design: moRelease is
  ## not a valid load order.
  loc.store(value, moRelease)

proc sequential*[T](loc: var Atomic[T]): T {.inline.} =
  ## Load `loc` with moSequentiallyConsistent.
  loc.load(moSequentiallyConsistent)

proc sequential*[T](loc: var Atomic[T], value: T) {.inline.} =
  ## Store `value` into `loc` with moSequentiallyConsistent.
  loc.store(value, moSequentiallyConsistent)
