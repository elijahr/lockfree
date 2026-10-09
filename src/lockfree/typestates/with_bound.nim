## RAII wrapper template (`withBoundEndpoint` / `withBoundProducer` /
## `withBoundConsumer`) + `Queueable[T]` concept per design §5.5.
##
## ## Purpose
##
## v0.1.0 surfaces two API styles for endpoint binding:
##
## 1. **Typestate-guarded surface (existing)** — users call `q.getProducer()`,
##    then `bindToThread()`, then `push(item)`, then `close()`. The `Unbound →
##    Bound → Closed` typestate FSM is visible and provides compile-time
##    guards (no `push` on `Unbound`, no double bind, no use-after-close).
##
## 2. **RAII surface (this module)** — `withBoundProducer(q, p): body` expands
##    to a block that runs `getProducer + bindToThread`, executes `body` with
##    `p` bound to the `Bound[...]` endpoint, and runs `close` on scope exit via
##    `defer`. The typestate FSM still drives the compile-time guards inside
##    `body`; the user just doesn't type the transitions.
##
## Both surfaces dispatch to the same per-cardinality push/pop bodies — there
## is no duplicate implementation. Bug fixes apply uniformly.
##
## The `Queueable[T]` concept (§5.5.5) is a non-typestate-aware ergonomic
## surface for library code that wants a single generic `Queueable[T]`-shaped
## parameter rather than `Queue[T, ccProd, ...] | BQueue[T, ccProd, ...] |
## Bound[T, Tag, Queue[T, ...]]` enumerated arms. Concept resolution is verified
## across the full Path-C-encoded payload set (ref X / string / seq[U] / POD T).
##
## ## Path-C transparency (operator directive 2026-06-06)
##
## Both surfaces work uniformly across `ref X` (via ManagedRef), `string` /
## `seq[U]` (via ManagedSlice), and POD T. The Path-C encoding routing happens
## INSIDE the existing per-cardinality push/pop bodies; this module never
## touches encoded slots. Users see `Queue[ref Foo]` / `Queue[string]` /
## `Queue[seq[int]]` / `Queue[int]` with the same surface regardless of which
## API style they choose.

import std/options

import ../bqueue
import ../queue
import ../endpoint
import ../strategy

# ---------------------------------------------------------------------------
# RAII templates.
#
# Two flavour pairs are needed because BQueue and Queue have different generic
# parameter counts (BQueue: N, P, C ints; Queue: ST strategy + S, MaxThreads
# ints). Each flavour calls `getProducer` / `getConsumer` + `bindToThread` and
# defers `close`. The defer runs on normal exit and on unhandled exceptions, so
# the `Bound → Closed` transition always fires.
#
# The user-visible `endpoint` name binds to the `Bound[...]` value inside `body`
# and is closed on scope exit.
# ---------------------------------------------------------------------------

template withBoundProducer*[T; ccCons: static PinScopeCardinality; N, P, C: static int](
    queue: var BQueue[T, ccMulti, ccCons, N, P, C],
    endpoint: untyped,
    body: untyped,
): untyped =
  ## BQueue multi-producer RAII wrapper. Acquires a per-thread producer slot,
  ## transitions to `Bound`, runs `body`, then transitions to `EndpointClosed`
  ## on scope exit.
  block:
    var u = queue.getProducer()
    var endpoint = u.bindToThread()
    defer:
      discard endpoint.close()
    body

template withBoundConsumer*[T; ccProd: static PinScopeCardinality; N, P, C: static int](
    queue: var BQueue[T, ccProd, ccMulti, N, P, C],
    endpoint: untyped,
    body: untyped,
): untyped =
  ## BQueue multi-consumer RAII wrapper. Symmetric to `withBoundProducer`.
  block:
    var u = queue.getConsumer()
    var endpoint = u.bindToThread()
    defer:
      discard endpoint.close()
    body

template withBoundProducer*[
    T;
    ccProd, ccCons: static PinScopeCardinality;
    ST: static DeallocationStrategy;
    S, MaxThreads: static int,
](
    queue: var Queue[T, ccProd, ccCons, ST, S, MaxThreads],
    endpoint: untyped,
    body: untyped,
): untyped =
  ## Queue producer RAII wrapper. Covers all four cardinality arms (SPSC / MPSC
  ## / SPMC / MPMC) — `getProducer` on `Queue` is defined uniformly in
  ## `endpoint.nim`. SPSC absorbed arm (ccProd == ccSingle and ccCons ==
  ## ccSingle) is debra-free, so `bindToThread` is a no-op there; the template's
  ## shape is unchanged.
  block:
    var u = queue.getProducer()
    var endpoint = u.bindToThread()
    defer:
      discard endpoint.close()
    body

template withBoundConsumer*[
    T;
    ccProd, ccCons: static PinScopeCardinality;
    ST: static DeallocationStrategy;
    S, MaxThreads: static int,
](
    queue: var Queue[T, ccProd, ccCons, ST, S, MaxThreads],
    endpoint: untyped,
    body: untyped,
): untyped =
  ## Queue consumer RAII wrapper. Symmetric to `withBoundProducer`.
  block:
    var u = queue.getConsumer()
    var endpoint = u.bindToThread()
    defer:
      discard endpoint.close()
    body

# ---------------------------------------------------------------------------
# `withBoundEndpoint` umbrella alias.
#
# The design §5.5.3 sketches `withBoundEndpoint(queue, endpoint, body)` as the
# canonical name. In practice the producer/consumer distinction is unavoidable
# at the call site (getProducer vs getConsumer dispatch), so the umbrella name
# is exposed as an alias for `withBoundProducer` (the most common case). Users
# who need a consumer endpoint reach for `withBoundConsumer` directly.
# ---------------------------------------------------------------------------

template withBoundEndpoint*(queue, endpoint, body: untyped): untyped =
  ## WARNING: this umbrella alias ALWAYS binds a PRODUCER endpoint (it forwards
  ## to withBoundProducer). A consumer-intent call here will SILENTLY acquire a
  ## producer slot — there is no role auto-detection. For a consumer endpoint
  ## you MUST call withBoundConsumer explicitly. The producer/consumer dispatch
  ## (getProducer vs getConsumer) cannot be inferred from the queue type alone,
  ## so this alias hard-codes the producer role.
  withBoundProducer(queue, endpoint, body)

# ---------------------------------------------------------------------------
# Queueable[T] concept (§5.5.5).
#
# A type-class matching anything with `push(x, T): bool` and `pop(x):
# Option[T]`. Resolves uniformly across:
#   * bare BQueue[T, ccSingle, ccSingle, ...] (SPSC direct push/pop)
#   * bare BQueue[T, ccMulti, ccSingle, ...] (MPSC direct pop side; push goes
#     through Bound)
#   * bare Queue[T, ccSingle, ccSingle, ...] (unbounded SPSC direct)
#   * Bound[T, Tag, Queue[...]] / Bound[T, Tag, BQueue[...]]
#
# The concept must resolve under generic instantiation. Nim 2.x concepts use the
# `concept x` form with `var x` for procs that take `var T` arguments. The body
# uses real concept expressions evaluated against `x` (no compiles() needed for
# the straightforward push/pop case).
#
# Path-C encoding is TRANSPARENT to the concept: `Queueable[ref Foo]` matches
# `BQueue[ref Foo, ...]` because push/pop on the bare queue accept `ref Foo` and
# return `Option[ref Foo]` at the public surface (the ManagedRef[X] encoding is
# internal). Same for `string` / `seq[U]`.
# ---------------------------------------------------------------------------

type Queueable*[T] = concept x
  ## Type-class for "anything queue-like accepting / yielding `T`".
  ##
  ## Resolution: Nim's concept machinery instantiates the body with `x` bound to
  ## a candidate type and checks each expression compiles and has the stated
  ## type. The `var x` form admits both `var Queue` and `var BQueue` direct-push
  ## variants and `Bound` endpoint variants alike — push/pop on `Bound` take
  ## `self: Bound[...]` (not var), but Nim's overload resolution falls through
  ## to those from the `var x` candidate.
  var qref: typeof(x)
  push(qref, default(T)) is bool
  pop(qref) is Option[T]

# ---------------------------------------------------------------------------
# Concept-hookup verification.
#
# `Queueable[T]` must resolve under generic instantiation across the full
# Path-C-encoded payload set (ref / string / seq / POD). The static doAsserts
# below pin the conformance contract: bare `BQueue[T, ccSingle, ccSingle, ...]`
# satisfies `Queueable[T]` for each Path-C payload arm.
#
# This pin lives in `with_bound.nim` rather than `queue.nim` / `bqueue.nim`
# because adding `import ./typestates/with_bound` from either of those would
# close the dependency cycle (with_bound imports both). The conformance check
# sits at the layer that owns the concept, importing the queue modules from the
# outside.
#
# Per design §5.5.5: the unbounded Queue does NOT satisfy Queueable (push/pop
# are only defined on `Bound[T, Tag, Queue[...]]`, not on bare `Queue`). Users
# wanting an unbounded queue with the Queueable surface must wrap an endpoint
# via the typestate API or the RAII template above.
# ---------------------------------------------------------------------------

type QueueableHookupDummy = object ## nominal ref target for the Path-C ref-arm Queueable conformance pin (static
## doAssert below); has no fields by design

static:
  doAssert (BQueue[int, ccSingle, ccSingle, 16, 0, 0]) is Queueable[int],
    "BQueue SPSC[int] must satisfy Queueable[int] (POD arm)"
  doAssert (BQueue[string, ccSingle, ccSingle, 16, 0, 0]) is Queueable[string],
    "BQueue SPSC[string] must satisfy Queueable[string] (Path-C string arm)"
  doAssert (BQueue[seq[int], ccSingle, ccSingle, 16, 0, 0]) is Queueable[seq[int]],
    "BQueue SPSC[seq[int]] must satisfy Queueable[seq[int]] (Path-C seq arm)"
  doAssert (BQueue[ref QueueableHookupDummy, ccSingle, ccSingle, 16, 0, 0]) is Queueable[ref QueueableHookupDummy],
    "BQueue SPSC[ref T] must satisfy Queueable[ref T] (Path-C ref arm)"
