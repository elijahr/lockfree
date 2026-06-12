## Adapter for ``crossbeam_queue::SegQueue<u64>`` (unbounded MPMC).
##
## ``SegQueue<T>`` is Crossbeam's unbounded MPMC queue (a Michael-Scott
## variant); it allocates new segments on demand instead of returning
## "full". Pushes therefore never report ``prFull`` -- failure can only
## come from a null queue handle.
##
## Topology: ``mpmc_unbounded``. ``topologiesSupported = {tMpmcUnbounded}``.
##
## Compile-time gating: only included when
## ``-d:adapter_crossbeam_seg_queue_available`` is passed.
##
## Same cdylib as ``crossbeam_array_queue_adapter``; both adapters can
## be enabled simultaneously without duplicate symbols (each adapter
## ``importc`` s a disjoint set of fns: ``cb_array_*`` vs ``cb_seg_*``).

when defined(adapter_crossbeam_seg_queue_available):
  import std/typetraits
  import ../bench_common
  import ../adapter
  # See ./crossbeam_link.nim — shared link-flag emission, fires once per
  # bench binary that imports ANY crossbeam adapter.
  import ./crossbeam_link

  proc cb_seg_init(): pointer {.importc, cdecl.}
  proc cb_seg_push(q: pointer, item: uint64): bool {.importc, cdecl.}
  proc cb_seg_pop(q: pointer, outVal: ptr uint64): bool {.importc, cdecl.}
  proc cb_seg_destroy(q: pointer) {.importc, cdecl.}

  const topologiesSupported* = {tMpmcUnbounded}

  type CrossbeamSegQueueAdapter*[T] = object
    # T must be POD and fit in a u64 cell — the Rust side stores items as
    # `u64`. See parallel notes in crossbeam_array_queue_adapter.nim. The
    # static asserts inside the generic procs below fire at the first
    # instantiation site with a concrete T. Per gemini PR feat/v0.1.0
    # review, 2026-06-07.
    queue*: pointer

  proc makeCrossbeamSegQueueAdapter*[T](
      capacity: int = 0
  ): CrossbeamSegQueueAdapter[T] =
    ## ``capacity`` is ignored — SegQueue is unbounded. Default arg matches
    ## the other adapters' shape so the wire-up sites can pass the same
    ## ``capacity`` uniformly without conditionals.
    when not supportsCopyMem(T):
      {.error: "CrossbeamSegQueueAdapter[T] requires POD T (no =copy/=destroy hooks); the FFI passes by raw u64 value and would bypass user hooks.".}
    when sizeof(T) > sizeof(uint64):
      {.error: "CrossbeamSegQueueAdapter[T] requires sizeof(T) <= 8; the Rust cell is u64 and larger T would truncate silently.".}
    discard capacity
    result.queue = cb_seg_init()
    doAssert result.queue != nil, "cb_seg_init returned null"

  proc cleanup*[T](a: var CrossbeamSegQueueAdapter[T]) =
    if a.queue != nil:
      cb_seg_destroy(a.queue)
      a.queue = nil

  proc push*[T](a: var CrossbeamSegQueueAdapter[T], item: T): PushResult =
    ## Always succeeds when the queue is alive (SegQueue is unbounded;
    ## the underlying ``cb_seg_push`` only returns false on a null handle).
    if a.queue == nil:
      return prFull
    # Marshal the payload's bit pattern into a u64 wire value. We zero-init
    # `val` and `copyMem` exactly `sizeof(T)` bytes (T is constrained to
    # `sizeof(T) <= 8` by the static check in the make* proc), so for T
    # smaller than 8 bytes the high bytes stay clean and there is no
    # out-of-bounds read. `cast[uint64](item)` would over-read the source
    # operand for `sizeof(T) < 8`. Per gemini PR feat/v0.1.0 review.
    var val: uint64 = 0
    copyMem(addr val, unsafeAddr item, sizeof(T))
    discard cb_seg_push(a.queue, val)
    prSuccess

  proc pop*[T](a: var CrossbeamSegQueueAdapter[T]): PopResult[T] =
    if a.queue == nil:
      return PopResult[T](success: false)
    var raw: uint64
    if cb_seg_pop(a.queue, addr raw):
      # Reconstruct T from the low `sizeof(T)` bytes of the u64 wire value,
      # mirroring the push side. `copyMem` into a properly-typed `val`
      # avoids `cast[T](raw)`, which reinterprets a full 8-byte source for
      # T narrower than 8 bytes. Per gemini PR feat/v0.1.0 review.
      var val: T
      copyMem(addr val, addr raw, sizeof(T))
      PopResult[T](success: true, value: val)
    else:
      PopResult[T](success: false)

  proc name*[T](a: CrossbeamSegQueueAdapter[T]): string =
    "crossbeam_queue/SegQueue[u64]"
