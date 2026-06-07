# typestates/segment_state

`segment_state` defines the segment-level lifecycle typestate machine
used by the unbounded `Queue`'s linked-segment ring. It encodes the
allowed segment transitions (allocated → linked → drained → retired)
so that the queue body's segment-advance and reclamation paths are
statically checked.

Downstream code does not normally interact with `segment_state`
directly; it is documented here to make the umbrella's segment
lifecycle contract visible.

## See also

- [Typestates facade](../typestates.md)
- [Queue](../queue.md) — the unbounded queue body that drives this
  typestate.

::: lockfree/typestates/segment_state
