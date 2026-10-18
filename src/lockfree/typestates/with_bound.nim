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
import ../stack
import ../bstack
import ../deque
import ../btable
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

template withBoundProducer*[T](
    stack: var TreiberStack[T],
    endpoint: untyped,
    body: untyped,
): untyped =
  ## TreiberStack producer RAII wrapper. Registers the calling thread with the
  ## stack's NEBR manager on entry and unregisters on scope exit.
  block:
    var u = stack.getProducer()
    var endpoint = u.bindToThread()
    defer:
      discard endpoint.close()
    body

template withBoundConsumer*[T](
    stack: var TreiberStack[T],
    endpoint: untyped,
    body: untyped,
): untyped =
  ## TreiberStack consumer RAII wrapper. Registers the calling thread with the
  ## stack's NEBR manager on entry and unregisters on scope exit.
  block:
    var u = stack.getConsumer()
    var endpoint = u.bindToThread()
    defer:
      discard endpoint.close()
    body

template withBoundProducer*[
    T;
    Cap: static int;
    ccProd, ccCons: static PinScopeCardinality
](
    stack: var BStack[T, Cap, ccProd, ccCons],
    endpoint: untyped,
    body: untyped,
): untyped =
  ## BStack producer RAII wrapper.
  block:
    var u = stack.getProducer()
    var endpoint = u.bindToThread()
    defer:
      discard endpoint.close()
    body

template withBoundConsumer*[
    T;
    Cap: static int;
    ccProd, ccCons: static PinScopeCardinality
](
    stack: var BStack[T, Cap, ccProd, ccCons],
    endpoint: untyped,
    body: untyped,
): untyped =
  ## BStack consumer RAII wrapper.
  block:
    var u = stack.getConsumer()
    var endpoint = u.bindToThread()
    defer:
      discard endpoint.close()
    body

template withBoundOwner*[T](
    deque: var ChaseLevDeque[T],
    endpoint: untyped,
    body: untyped,
): untyped =
  ## ChaseLevDeque owner-worker RAII wrapper (`pushBottom` / `popBottom` / `tryPopBottom`).
  block:
    var u = deque.getOwner()
    var endpoint = u.bindToThread()
    defer:
      discard endpoint.close()
    body

template withBoundThief*[T](
    deque: var ChaseLevDeque[T],
    endpoint: untyped,
    body: untyped,
): untyped =
  ## ChaseLevDeque thief RAII wrapper (`steal` / `trySteal` / `stealBatch`).
  block:
    var u = deque.getThief()
    var endpoint = u.bindToThread()
    defer:
      discard endpoint.close()
    body

template withBoundProducer*[T](
    deque: var ChaseLevDeque[T],
    endpoint: untyped,
    body: untyped,
): untyped =
  withBoundOwner(deque, endpoint, body)

template withBoundConsumer*[T](
    deque: var ChaseLevDeque[T],
    endpoint: untyped,
    body: untyped,
): untyped =
  withBoundThief(deque, endpoint, body)

template withBoundWriter*[
    K, V;
    Cap: static int;
    ccProd, ccCons: static PinScopeCardinality
](
    table: var BTable[K, V, Cap, ccProd, ccCons],
    endpoint: untyped,
    body: untyped,
): untyped =
  ## BTable writer RAII wrapper (permits both mutations and lookups).
  block:
    var u = table.getWriter()
    var endpoint = u.bindToThread()
    defer:
      discard endpoint.close()
    body

template withBoundReader*[
    K, V;
    Cap: static int;
    ccProd, ccCons: static PinScopeCardinality
](
    table: var BTable[K, V, Cap, ccProd, ccCons],
    endpoint: untyped,
    body: untyped,
): untyped =
  ## BTable reader RAII wrapper (permits read-only lookups; rejects mutations at compile time).
  block:
    var u = table.getReader()
    var endpoint = u.bindToThread()
    defer:
      discard endpoint.close()
    body

template withBoundProducer*[
    K, V;
    Cap: static int;
    ccProd, ccCons: static PinScopeCardinality
](
    table: var BTable[K, V, Cap, ccProd, ccCons],
    endpoint: untyped,
    body: untyped,
): untyped =
  withBoundWriter(table, endpoint, body)

template withBoundConsumer*[
    K, V;
    Cap: static int;
    ccProd, ccCons: static PinScopeCardinality
](
    table: var BTable[K, V, Cap, ccProd, ccCons],
    endpoint: untyped,
    body: untyped,
): untyped =
  withBoundReader(table, endpoint, body)

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
# Queueable[T], Stackable[T], Stealable[T], TableReadable[K, V], TableWritable[K, V]
# ---------------------------------------------------------------------------

type Queueable*[T] = concept x
  ## Type-class for "anything queue-like accepting / yielding `T`".
  var qref: typeof(x)
  push(qref, default(T)) is bool
  pop(qref) is Option[T]

type Stackable*[T] = concept x
  ## Type-class for LIFO stacks (`TreiberStack`, `BStack`) supporting `push`, `pop`, and `peek`.
  var sref: typeof(x)
  compiles(sref.push(default(T)))
  pop(sref) is Option[T]
  peek(sref) is Option[T]

type Stealable*[T] = concept x
  ## Type-class for work-stealing deques (`ChaseLevDeque`, `Bound[..., DequeThiefTag, ChaseLevDeque[T]]`)
  ## supporting `steal`.
  var dref: typeof(x)
  steal(dref) is Option[T]

type TableReadable*[K, V] = concept x
  ## Type-class for concurrent hash tables and bound reader/writer endpoints
  ## supporting `get` and `contains`.
  var tref: typeof(x)
  get(tref, default(K)) is Option[V]
  contains(tref, default(K)) is bool

type TableWritable*[K, V] = concept x
  ## Type-class for concurrent hash tables and bound writer endpoints
  ## supporting `put`, `get`, and `remove`.
  var tref: typeof(x)
  put(tref, default(K), default(V)) is bool
  get(tref, default(K)) is Option[V]
  remove(tref, default(K)) is bool

# ---------------------------------------------------------------------------
# Concept-hookup verification.
# ---------------------------------------------------------------------------

type QueueableHookupDummy = object ## nominal ref target for the Path-C ref-arm Queueable conformance pin (static
## doAssert below); has no fields by design

static:
  doAssert (BQueue[int, ccSingle, ccSingle, 16, 0, 0]) is Queueable[int],
    "BQueue SPSC[int] must satisfy Queueable[int] (POD arm)"
  doAssert (BQueue[string, ccSingle, ccSingle, 16, 0, 0]) is Queueable[string],
    "BQueue SPSC[string] must satisfy Queueable[string] (Path-C string arm)"
  doAssert (BQueue[seq[int], ccSingle, ccSingle, 16, 0, 0]) is Queueable[seq[int]],
    "BQueue SPSC[seq[int] must satisfy Queueable[seq[int]] (Path-C seq arm)"
  doAssert (BQueue[ref QueueableHookupDummy, ccSingle, ccSingle, 16, 0, 0]) is Queueable[ref QueueableHookupDummy],
    "BQueue SPSC[ref T] must satisfy Queueable[ref T] (Path-C ref arm)"
  doAssert (TreiberStack[int]) is Stackable[int],
    "TreiberStack[int] must satisfy Stackable[int]"
  doAssert (BStack[int, 16, ccMulti, ccMulti]) is Stackable[int],
    "BStack[int, 16] must satisfy Stackable[int]"
  doAssert (ChaseLevDeque[int]) is Stealable[int],
    "ChaseLevDeque[int] must satisfy Stealable[int]"
  doAssert (Bound[int, DequeThiefTag, ChaseLevDeque[int]]) is Stealable[int],
    "Bound[..., DequeThiefTag, ChaseLevDeque[int]] must satisfy Stealable[int]"
  doAssert (BTable[int, string, 16, ccMulti, ccMulti]) is TableReadable[int, string],
    "BTable[int, string, 16] must satisfy TableReadable[int, string]"
  doAssert (BTable[int, string, 16, ccMulti, ccMulti]) is TableWritable[int, string],
    "BTable[int, string, 16] must satisfy TableWritable[int, string]"
  doAssert (Bound[(int, string), TableReaderTag, BTable[int, string, 16, ccMulti, ccMulti]]) is TableReadable[int, string],
    "Bound[..., TableReaderTag, BTable] must satisfy TableReadable[int, string]"
  doAssert (Bound[(int, string), TableWriterTag, BTable[int, string, 16, ccMulti, ccMulti]]) is TableWritable[int, string],
    "Bound[..., TableWriterTag, BTable] must satisfy TableWritable[int, string]"

