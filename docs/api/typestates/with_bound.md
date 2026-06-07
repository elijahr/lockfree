# typestates/with_bound

The `with_bound` macro provides a scoped binding for an endpoint
view: within the macro body, the endpoint is in the `Bound` state
and the user code may `push` / `pop` through it; on scope exit, the
endpoint transitions back to `Unbound` (or `Closed`, depending on the
shape's destructor contract).

This is the recommended form for the common case of a worker thread
that acquires an endpoint, drives it for a bounded period of work,
and releases it on exit. The explicit `getProducer()` /
`bindToThread()` / `detach()` triple is retained for cases where the
endpoint must outlive a single scope (for example, when stored on a
long-lived worker object).

## See also

- [Typestates facade](../typestates.md) — overview and submodule
  index.

::: lockfree/typestates/with_bound
