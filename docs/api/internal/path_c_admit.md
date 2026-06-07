# internal/path_c_admit

!!! warning "Internal module"

    `lockfree/internal/path_c_admit` is an **internal** module. Its
    API is not part of the umbrella's semver contract and may change
    at any time. Downstream code MUST NOT import it directly.
    Documented here for contributors and reviewers.

`path_c_admit` implements the unbounded MPMC "path C — admit" branch
of the consumer-side close protocol: the case where the consumer
observes an empty cell and must close the cell so that the producer
sees the closure and retries on the next segment. See the LCRQ
paper §4 for the broader protocol context.

## See also

- [`path_c_wrap`](path_c_wrap.md) — sibling close-CAS branch.
- [Queue](../queue.md) — the body that dispatches into these paths.

::: lockfree/internal/path_c_admit
