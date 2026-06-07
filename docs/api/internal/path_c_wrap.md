# internal/path_c_wrap

!!! warning "Internal module"

    `lockfree/internal/path_c_wrap` is an **internal** module. Its
    API is not part of the umbrella's semver contract and may change
    at any time. Downstream code MUST NOT import it directly.
    Documented here for contributors and reviewers.

`path_c_wrap` implements the unbounded MPMC "path C — wrap" branch
of the consumer-side close protocol: the case where a closed cell is
observed on segment wrap-around and the consumer must advance to the
next segment without consuming a payload. See the LCRQ paper §4 for
the broader protocol context.

## See also

- [`path_c_admit`](path_c_admit.md) — sibling close-CAS branch.
- [Queue](../queue.md) — the body that dispatches into these paths.

::: lockfree/internal/path_c_wrap
