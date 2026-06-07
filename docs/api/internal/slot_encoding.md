# internal/slot_encoding

!!! warning "Internal module"

    `lockfree/internal/slot_encoding` is an **internal** module. Its
    API is not part of the umbrella's semver contract and may change
    at any time. Downstream code MUST NOT import it directly.
    Documented here for contributors and reviewers.

`slot_encoding` defines the bit-level layout for the unbounded MPMC
shape's `(seq, payload)` packed cell — the DWCAS word used by the
LCRQ paper §4 close-CAS-on-empty progress rule. It centralizes the
encode / decode pair so that the producer and consumer paths agree
on the layout, and so that the `supportsCopyMem(T) AND sizeof(T) <= 8`
constraint on unbounded-MPMC payload `T` can be statically enforced
in one place.

## See also

- [Queue](../queue.md) — the unbounded queue that consumes this
  encoding for its MPMC shape.

::: lockfree/internal/slot_encoding
