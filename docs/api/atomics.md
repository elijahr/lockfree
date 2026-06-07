# atomics

`lockfree/atomics` is the umbrella's atomics facade. It provides the
typed atomic primitives used internally by the queue bodies and the
SMR layer: relaxed/acquire/release/seq-cst loads and stores, CAS,
fetch-add, and the bounded back-off loop used on contention.

Downstream code generally does not need to import this directly —
the queue and SMR APIs encapsulate the atomic operations. It is
documented here for callers writing additional lock-free primitives
against the same memory-ordering discipline used by the umbrella.

## See also

- `lockfree/atomics/dsl` — the macros used to declare atomic fields
  and load/store sites with explicit memory ordering.
- `lockfree/atomics/backoff` — the spin/yield/back-off loop used by
  contention paths.

::: lockfree/atomics
