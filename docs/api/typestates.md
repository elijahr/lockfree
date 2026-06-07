# typestates (facade)

`lockfree/typestates` is the facade module that re-exports the
typestate machines used across the umbrella: slot ownership, segment
lifecycle, endpoint claim state (`Unbound → Bound → Closed`), and the
`with_bound` scope macro that binds an endpoint to the current
thread for the body of a block.

The facade is the recommended import surface for downstream code that
needs to spell typestate parameters explicitly (for example, when
storing a `Bound[T, Tag, ...]` endpoint as a field). The granular
submodules below are documented for deeper inspection.

## Submodules

- [`with_bound`](typestates/with_bound.md) — scoped binding macro
  for endpoint views.
- [`slot_state`](typestates/slot_state.md) — slot-level ownership
  typestate.
- [`segment_state`](typestates/segment_state.md) — segment-level
  lifecycle typestate (unbounded `Queue`).

## See also

- [Typestates user guide](../guide/typestates.md) — high-level usage.
- [Slot ownership typestates (legacy guide)](../guide/slot-ownership-typestates.md)
  — pre-umbrella conceptual overview.

::: lockfree/typestates
