# Typestates — endpoint lifecycle

`lockfree`'s multi-cardinality queues hand out *endpoints*. An
endpoint is a per-thread view that lets you push (producer) or pop
(consumer) safely. The endpoint lifecycle is enforced at compile time
by typestates: `Unbound → Bound → Closed`.

This page covers three things:

1. **The bare API** — `getProducer`, `bindToThread`, `close`. The
   building-block surface.
2. **The RAII wrapper** — `withBoundEndpoint`. Same API, scope-bound.
3. **The `Queueable[T]` concept** — for generic code that operates on
   any queue endpoint.

And a teaser for [chronos integration](#chronos-integration) at the end.

## Why typestates

A bound endpoint is *thread-affine*: the thread that called
`bindToThread()` is the only thread that can `push` / `pop` through
it. Violating thread-affinity is a use-after-something error class
(use-after-unregister, use-by-wrong-thread, double-bind, etc.).

The typestate machinery makes those errors compile-time:

- `push` and `pop` are defined ONLY on `Bound[…]`.
- `bindToThread` is defined ONLY on `Unbound[…]`.
- `close` is defined ONLY on `Bound[…]`.

You cannot push through an `Unbound` (no `bind`), and you cannot push
through a `Closed` (already released). The compiler refuses.

## The bare API

```nim
import lockfree
import lockfree/endpoint
import lockfree/role_tags

var q = newMpmcQueue[int, 16, 4, 4]()

# 1. Get an Unbound endpoint (on any thread).
var producer: Unbound[int, ProducerTag, …] = q.getProducer()

# 2. Hand off to the operating thread.
proc workerProc(p: ptr Unbound[…]) {.thread.} =
  var bound = p[].bindToThread()  # Unbound → Bound; registers with nebr
  bound.push(42)
  bound.close()                   # Bound → Closed; unregisters
```

The `Unbound → Bound` transition is the registration point. For the
unbounded multi-consumer arms, this is where the endpoint registers
with the internal nebr manager.

The `Bound → Closed` transition is the unregistration point. After
`close()`, the endpoint is consumed (its state is `Closed`); calling
any operation on it is a compile-time error.

## Sugar: `*Here` for same-thread bind

When the caller is also the operating thread, the explicit
`getProducer` + `bindToThread` is needlessly verbose. Use
`*Here`:

```nim
var producer = q.getProducerHere()  # Unbound + bindToThread in one
producer.push(42)
producer.close()
```

`getProducerHere()` and `getConsumerHere()` are sugar for the
same-thread shortcut.

## RAII wrapper: `withBoundEndpoint`

For scope-bound usage where the endpoint should always close at scope
exit (including on raised exceptions), use `withBoundEndpoint`:

```nim
import lockfree/typestates/with_bound

proc workerProc(q: ptr Queue[int, …]) {.thread.} =
  q[].withBoundEndpoint(producer):
    producer.push(42)
    # close() invoked automatically at scope exit, even on raised exceptions
```

The block introduces `producer` as a `Bound[…]` endpoint, bound to
the current thread, and ensures `close()` runs at scope exit. This is
the recommended pattern for new code unless you have a specific need
for the bare API (e.g. lifetime spanning multiple procs).

## The `Queueable[T]` concept

For generic code that operates on any bound endpoint (regardless of
queue type or cardinality), use the `Queueable[T]` concept:

```nim
proc pumpFrom[Q: Queueable[int]](source: var Q) =
  while true:
    let v = source.pop()
    if v.isNone: break
    process(v.get)
```

`Queueable[T]` matches any `Bound[T, _, _]` endpoint regardless of
cardinality, queue type (`BQueue` vs `Queue`), or backing storage.
This is the concept to write against when the cardinality is a
parameter of your code rather than a fixed design choice.

## Choosing among the three styles

| Style | Use when |
|---|---|
| Bare API | Endpoint lifetime spans multiple procs; you need explicit control of bind / close timing. |
| `withBoundEndpoint` | Endpoint lifetime fits a single block; you want exception-safe close. |
| `Queueable[T]` | Code is generic over queue type or cardinality. |

For most new code, prefer `withBoundEndpoint` for endpoint
construction and `Queueable[T]` for generic consumers.

## chronos integration

When compiled with `-d:lockfreeChronos` (or with `chronos` available
and auto-detected), `lockfree` exposes async-aware endpoint variants
under `lockfree/chronos`:

```nim
# With -d:lockfreeChronos
import lockfree
import lockfree/chronos

proc asyncWorker(q: AsyncQueue[int]) {.async.} =
  let v = await q.pop()
  await process(v)
```

The chronos adapter integrates the endpoint typestate with chronos's
`Future[T]` lifecycle: `await q.pop()` suspends until an item arrives,
and a cancelled future correctly closes the bound endpoint without
leaking a nebr registration. See [the chronos example](https://github.com/elijahr/lockfree/blob/devel/examples/06_chronos_async.nim)
for the full pattern.

The chronos dependency is **soft** — it is not in `lockfree.nimble`'s
`requires`. The adapter is enabled automatically if `chronos` is
present in the resolved import path, or explicitly via
`-d:lockfreeChronos`. Code that does not need async pays nothing.

## Further reading

- [`api/endpoint`](../api/endpoint.md) — auto-generated endpoint reference.
- Internal: [design-sections/05-api-surfaces.md](https://github.com/elijahr/lockfree/blob/devel/docs/internal/design-sections/05-api-surfaces.md) — full API surface specification.
- [nebr](smr/nebr.md) — what the `Unbound → Bound` transition registers with.
