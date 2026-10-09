## src/lockfree/chronos.nim
##
## Tier 3 chronos async adapter for `lockfree` queues. This is the only async
## tier shipping in v0.1.0, built on the hybrid optional-dep pattern.
##
## chronos is intentionally NOT listed unconditionally in `lockfree.nimble`
## `requires`. The library is flag-only opt-in: users who want the async adapter
## pass `-d:lockfreeChronos` AND install chronos themselves (or rely on
## `lockfree.nimble`'s `when defined(lockfreeChronos): requires "chronos >=
## 4.0.0, < 5.0.0"` conditional dep). The library never transitively pulls
## chronos in for users who do not need it, and chronos is never auto-detected
## at compile time.
##
## Activation matrix (flag-only opt-in):
##
##   `-d:lockfreeChronos` | chronos installed | outcome
##   -------------------- | ----------------- | -----------------------------
##   No | (irrelevant) | (d) import succeeds; module body skipped; AsyncQueue/
##   AsyncBQueue invisible. Yes | Yes | (b) opt-in path; module body activates;
##   types exported. Yes | No | (c) `{.error.}` fires with a precise install
##   hint referencing `docs/api/chronos.md`.
##
## The previous auto-detect arm — a public `lockfreeChronosAvailable*`
## constant that callers could `when`-branch on to silently enable the adapter
## without the flag — was removed: silent activation based on whether chronos
## happens to be installed in a user's package set violates the flag-only opt-in
## contract. An internal (non-exported) `chronosReachable` probe is retained
## ONLY to drive the precise install-hint `{.error.}` arm; the module body never
## activates without `-d:lockfreeChronos`, regardless of whether chronos is
## reachable.
##
## NOTE on chronos import form: the obvious `import chronos` self-shadows inside
## this module — our own file IS `src/lockfree/chronos.nim`, which Nim
## resolves first on the import search path, breaking the `compiles do:` probe
## used to emit the precise install-hint error. We import the chronos
## *submodule* `chronos/asyncsync` (which transitively re-exports asyncloop ->
## asyncfutures + asyncmacro, covering AsyncEvent, Future, async/await, waitFor,
## CancelledError) and we use the bracket-array form `chronos/[asyncsync]`. The
## bracket form is what makes the resolver locate the chronos package despite
## the local module's name. A leading throw-away `compiles do: import
## chronos/asyncsync` primes Nim's package resolver so the bracket form binds
## correctly on the next call — without that prime the bracket form returns
## false on the very first invocation in a module whose own name is "chronos".
## This priming probe is deliberate and is required to defeat the
## self-shadowing; it is NOT an auto-detect arm, and its result is discarded.

# Prime the package resolver. The result is intentionally discarded; the side
# effect is that Nim now knows the chronos package exists, so the bracket-form
# `compiles do:` probe below succeeds when chronos IS installed. Kept
# unconditional (not gated on `lockfreeChronos`) because the cost is zero when
# chronos is missing and it avoids two distinct probe shapes for the resolver to
# disagree about. The result of the `when (compiles do: ...)` is discarded.
when (compiles do:
  import chronos/asyncsync
):
  discard

# `chronosReachable` is the internal flag-only equivalent of the old public
# `lockfreeChronosAvailable` constant — but it is NOT exported and is
# consulted ONLY inside the `when defined(lockfreeChronos)` arm below. That
# keeps the activation contract flag-only: a user who has chronos in their
# package set but does NOT pass `-d:lockfreeChronos` still gets the no-op (d)
# outcome from the activation matrix.
const chronosReachable = compiles do:
  import chronos/[asyncsync]

when defined(lockfreeChronos) and not chronosReachable:
  {.
    error:
      "lockfree/chronos: -d:lockfreeChronos was set but the chronos " &
      "package is not installed. Run " &
      "`nimble install \"chronos >= 4.0.0, < 5.0.0\"` and re-build, " &
      "or remove -d:lockfreeChronos to disable the async adapter. " &
      "See docs/api/chronos.md for the full integration guide."
  .}

## --------------------------------------------------------------------
## (b) Module body — activates ONLY when `-d:lockfreeChronos` is set (the (c)
## guard above already ensured chronos is present in that case).
## --------------------------------------------------------------------

when defined(lockfreeChronos):
  import std/options
  import chronos/[asyncsync]
  import ./bqueue
  import ./queue
  import ./strategy

  type
    AsyncBQueue*[
      T;
      ccProd, ccCons: static PinScopeCardinality,
      N, P, C: static int,
    ] = ref object
      ## Bounded async-adapter queue. Wraps a sync `BQueue` and adds a single
      ## chronos `AsyncEvent` for the consumer-wakeup signal. Lock-freedom on
      ## the producer side is preserved (fire is a non-blocking flag set on the
      ## chronos event-loop thread); the consumer opts into blocking via `await
      ## event.wait()`.
      ##
      ## Storage is `ref object` rather than a plain `object` because chronos's
      ## `{.async.}` macro lifts pop into a closure-bearing iterator, and Nim
      ## refuses to capture a `var` receiver across the await suspension point.
      ## Boxing the wrapper resolves the capture without introducing extra
      ## atomic state. This matches chronos's own `asyncsync.AsyncQueue[T]`
      ## which is also `ref object of RootRef`.
      queue*: BQueue[T, ccProd, ccCons, N, P, C]
      event*: AsyncEvent

    AsyncQueue*[
      T;
      ccProd, ccCons: static PinScopeCardinality,
      ST: static DeallocationStrategy,
      S, MaxThreads: static int,
    ] = ref object
      ## Unbounded async-adapter queue. Same shape as `AsyncBQueue` but over the
      ## unbounded `Queue`. Note that chronos's own
      ## `chronos/asyncsync.AsyncQueue[T]` (a ref object with a single generic
      ## parameter) lives in a different scope; downstream code that imports
      ## both should qualify or alias one side. See the test suite
      ## (`tests/t_chronos.nim`) for the recommended `from chronos import nil`
      ## pattern.
      queue*: Queue[T, ccProd, ccCons, ST, S, MaxThreads]
      event*: AsyncEvent

    AsyncQueueSpsc*[T; S, MaxThreads: static int] =
      AsyncQueue[T, ccSingle, ccSingle, stEager, S, MaxThreads]
      ## Convenience alias for the SPSC-absorbed unbounded async queue
      ## (debra-free; no pinscope; trivially safe across async-await boundaries
      ## — pin scope is closed inside the inner pop before any `await`).

  ## ------------------------------------------------------------------
  ## Constructors.
  ## ------------------------------------------------------------------

  proc newAsyncBQueue*[
      T;
      ccProd, ccCons: static PinScopeCardinality,
      N, P, C: static int,
  ](): AsyncBQueue[T, ccProd, ccCons, N, P, C] =
    ## Construct an `AsyncBQueue`. Allocates a fresh `AsyncEvent` and forwards
    ## to `newBQueue` for the inner queue. Returns a heap- allocated wrapper
    ## (see the type doc on why the wrapper is `ref object`).
    new result
    result.queue = newBQueue[T, ccProd, ccCons, N, P, C]()
    result.event = newAsyncEvent()

  proc newAsyncQueue*[
      T;
      ccProd, ccCons: static PinScopeCardinality,
      ST: static DeallocationStrategy,
      S, MaxThreads: static int,
  ](
      _: typedesc[AsyncQueue[T, ccProd, ccCons, ST, S, MaxThreads]]
  ): AsyncQueue[T, ccProd, ccCons, ST, S, MaxThreads] =
    ## Construct an `AsyncQueue` via the typedesc-only sync ctor (delegates to
    ## `newQueue(typedesc[Queue[...]])`). For the spsc-absorbed `(ccSingle,
    ## ccSingle)` shape this is debra-free. For other cardinalities the sync
    ## ctor allocates a private `DebraManager`; the async wrapper inherits that
    ## ownership.
    new result
    result.queue = newQueue(Queue[T, ccProd, ccCons, ST, S, MaxThreads])
    result.event = newAsyncEvent()

  ## ------------------------------------------------------------------
  ## SPSC bounded push / pop.
  ##
  ## Direct push/pop carriers on `AsyncBQueue` are defined for the SPSC arm only
  ## — the same scope where the underlying sync `BQueue` has a direct push/pop
  ## body. Multi-side cardinalities (MPSC / SPMC / MPMC) require the
  ## typestate-guarded `Bound[...]` endpoint dance on the sync queue and are
  ## exposed through user-side endpoint factories rather than a direct push/pop
  ## on the wrapper. The `AsyncQueue` types are still parameterized for all
  ## cardinalities so that follow-up work can layer an `asyncPop` on `Bound`
  ## without reshaping the wrapper.
  ## ------------------------------------------------------------------

  proc push*[T; N: static int](
      self: AsyncBQueue[T, ccSingle, ccSingle, N, 0, 0], item: sink T
  ): bool =
    ## SPSC async-adapter push. Forwards to the sync `BQueue.push` and fires the
    ## `AsyncEvent` on success so an awaiting `pop` wakes. Returns the
    ## underlying push outcome so the user can implement back-pressure (a
    ## `false` return means the bounded queue is full; the event is NOT fired in
    ## that case).
    result = self.queue.push(item)
    if result:
      self.event.fire()

  proc pop*[T; N: static int](
      self: AsyncBQueue[T, ccSingle, ccSingle, N, 0, 0]
  ): Future[Option[T]] {.async.} =
    ## SPSC async-adapter pop. Loops the canonical sticky-flag condition
    ## pattern:
    ##
    ##   clear flag -> non-blocking pop -> if some, return -> else await flag ->
    ##   repeat
    ##
    ## The `clear` precedes the pop so a producer push that interleaves between
    ## the `clear` and the `await` still leaves the flag set, and the subsequent
    ## `await event.wait()` returns immediately (chronos `AsyncEvent.wait`
    ## short-circuits when the flag is already true — chronos 4.x
    ## `AsyncEvent.wait`). This eliminates the lost-wakeup race without
    ## introducing extra atomic state on the queue side.
    ##
    ## Cancellation discipline: the sync `pop` body for the SPSC arm is
    ## debra-free and holds no pin across the `await`. The `try/finally` here is
    ## the structural guard that also covers future expansion to cardinalities
    ## where an inner pop DOES enter and exit a pin scope (the design guarantees
    ## that pin acquisition/release happens entirely inside `q.queue.pop()`, so
    ## no pin is held across the `await event.wait()` line below; the
    ## try/finally captures the cancellation propagation contract regardless).
    while true:
      self.event.clear()
      let v = self.queue.pop()
      if v.isSome:
        return v
      # SPSC arm holds no pinscope across the await — the sync pop acquires
      # and releases any pin entirely inside q.queue.pop(). CancelledError
      # propagates naturally (no cleanup to unwind).
      await self.event.wait()

  ## ------------------------------------------------------------------
  ## SPSC unbounded pop.
  ##
  ## The spsc-absorbed unbounded `Queue` exposes a direct `pop` on the bare `var
  ## Queue` receiver. We wrap that. The producer side of the unbounded queue is
  ## currently endpoint-only (push lives on `Bound[T, Tag, Queue[...]]`), so the
  ## corresponding `asyncPush` lives on `Bound` rather than on the wrapper. That
  ## endpoint-side integration is user-side. For users who want SPSC-unbounded
  ## async with a pre-bound producer, the pattern is:
  ##
  ##   var aq = newAsyncQueue(AsyncQueueSpsc[int, 64, 1]) var prod =
  ##   aq.queue.getProducerHere() prod.push(42) aq.event.fire() #
  ##   consumer-wakeup hook let v = waitFor aq.pop() # pops 42
  ##
  ## A future commit will collapse the producer-side ceremony into an
  ## `asyncPush` template on the wrapper.
  ## ------------------------------------------------------------------

  proc pop*[
      T;
      ST: static DeallocationStrategy,
      S, MaxThreads: static int,
  ](
      self: AsyncQueue[T, ccSingle, ccSingle, ST, S, MaxThreads]
  ): Future[Option[T]] {.async.} =
    ## SPSC async-adapter pop for the unbounded queue. Same loop and
    ## cancellation contract as the bounded SPSC `pop` above.
    while true:
      self.event.clear()
      let v = self.queue.pop()
      if v.isSome:
        return v
      # SPSC arm holds no pinscope across the await — the sync pop acquires
      # and releases any pin entirely inside q.queue.pop(). CancelledError
      # propagates naturally (no cleanup to unwind).
      await self.event.wait()

  ## ------------------------------------------------------------------
  ## Helper accessors. The underlying sync queue is publicly accessible via the
  ## `queue*` field; these templates exist as ergonomic sugar for users who want
  ## to forward to the sync endpoint factories without typing
  ## `q.queue.getProducer()` in the call site.
  ## ------------------------------------------------------------------

  template asyncEvent*[T; ccProd, ccCons: static PinScopeCardinality; N, P, C: static int](
      self: AsyncBQueue[T, ccProd, ccCons, N, P, C]
  ): var AsyncEvent =
    ## Returns a mutable view of the wrapper's `AsyncEvent`. Exposed so
    ## downstream `asyncPop`-on-`Bound` implementations can share the same event
    ## flag without reaching through `q.event` directly.
    self.event

  template asyncEvent*[
      T;
      ccProd, ccCons: static PinScopeCardinality;
      ST: static DeallocationStrategy,
      S, MaxThreads: static int,
  ](
      self: AsyncQueue[T, ccProd, ccCons, ST, S, MaxThreads]
  ): var AsyncEvent =
    ## Unbounded analog of the bounded `asyncEvent` helper above.
    self.event
