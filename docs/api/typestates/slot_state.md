# typestates/slot_state

`slot_state` defines the slot-level ownership typestate machine
shared across all bounded `BQueue` shapes and the unbounded `Queue`'s
segment cells. It encodes the Vyukov per-slot `seq` protocol's
allowed transitions (empty → producer-owned → committed → consumed →
next-empty) as a typestate so that violations are statically
detectable in the queue body code.

Downstream code does not normally interact with `slot_state` directly;
it is documented here to make the umbrella's internal safety
contracts visible.

## See also

- [Typestates facade](../typestates.md)
- [Slot ownership typestates (legacy guide)](../../guide/slot-ownership-typestates.md)

::: lockfree/typestates/slot_state
