## Adapter for ``crossbeam_queue::ArrayQueue<u64>`` (bounded MPMC).
##
## Crossbeam is a Rust lock-free ecosystem (https://github.com/crossbeam-rs,
## dual-licensed Apache-2.0 / MIT). ``ArrayQueue<T>`` is a fixed-capacity
## ring-buffer MPMC queue.
##
## We do not link directly against the Rust library; instead we go through
## a thin C-ABI cdylib at ``benchmarks/rust/bench-ffi-crossbeam/``.
## The cdylib exports four ``extern "C"`` fns:
## ``cb_array_init``, ``cb_array_push``, ``cb_array_pop``, ``cb_array_destroy``.
##
## Topology: ``mpmc`` bounded. ``topologiesSupported = {tMpmc}``.
##
## Compile-time gating: only included when
## ``-d:adapter_crossbeam_array_queue_available`` is passed.
##
## Linking: callers must build the cdylib first
## (``cargo build --release --manifest-path benchmarks/rust/bench-ffi-crossbeam/Cargo.toml``)
## and then compile the bench binary with the link flags emitted below.
## Override the search path with ``-d:crossbeamLibDir=<path>`` if the crate
## was built somewhere other than the in-tree ``target/release``.

when defined(adapter_crossbeam_array_queue_available):
  import std/typetraits
  import ../bench_common
  import ../adapter
  # Link-flag emission lives in a shared module so it fires exactly once
  # per bench binary that imports ANY crossbeam adapter, decoupled from
  # which gates happen to be globally set. See crossbeam_link.nim header
  # for the failure mode this avoids.
  import ./crossbeam_link

  # The Rust cdylib exports `cb_array_*` with C linkage. We model the
  # opaque queue handle as `pointer` (Nim) <-> `*mut c_void` (Rust). All
  # multi-threaded access is the caller's responsibility; the queue
  # itself is MPMC-safe.

  proc cb_array_init(capacity: csize_t): pointer {.importc, cdecl.}
  proc cb_array_push(q: pointer, item: uint64): bool {.importc, cdecl.}
  proc cb_array_pop(q: pointer, outVal: ptr uint64): bool {.importc, cdecl.}
  proc cb_array_destroy(q: pointer) {.importc, cdecl.}

  const topologiesSupported* = {tMpmc}

  type CrossbeamArrayQueueAdapter*[T] = object
    # T must be POD and fit in a u64 cell: the Rust side stores items as
    # `u64`, and the FFI marshals via plain byte-equivalent value passing.
    # Non-POD T (anything with =copy/=destroy hooks) would skip the hook
    # on the Rust side and leak/double-free; T larger than 8 bytes would
    # silently truncate. The static asserts inside the generic procs
    # below fire at the first instantiation site with a concrete T.
    # Per gemini PR feat/v0.1.0 review, 2026-06-07.
    queue*: pointer
    capacity*: int

  proc makeCrossbeamArrayQueueAdapter*[T](
      capacity: int = 1024
  ): CrossbeamArrayQueueAdapter[T] =
    when not supportsCopyMem(T):
      {.error: "CrossbeamArrayQueueAdapter[T] requires POD T (no =copy/=destroy hooks); the FFI passes by raw u64 value and would bypass user hooks.".}
    when sizeof(T) > sizeof(uint64):
      {.error: "CrossbeamArrayQueueAdapter[T] requires sizeof(T) <= 8; the Rust cell is u64 and larger T would truncate silently.".}
    doAssert capacity > 0,
      "CrossbeamArrayQueue requires capacity > 0 (zero would null-init)"
    result.capacity = capacity
    result.queue = cb_array_init(csize_t(capacity))
    doAssert result.queue != nil, "cb_array_init returned null"

  proc cleanup*[T](a: var CrossbeamArrayQueueAdapter[T]) =
    if a.queue != nil:
      cb_array_destroy(a.queue)
      a.queue = nil

  proc push*[T](a: var CrossbeamArrayQueueAdapter[T], item: T): PushResult =
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
    if cb_array_push(a.queue, val): prSuccess else: prFull

  proc pop*[T](a: var CrossbeamArrayQueueAdapter[T]): PopResult[T] =
    if a.queue == nil:
      return PopResult[T](success: false)
    var raw: uint64
    if cb_array_pop(a.queue, addr raw):
      # Reconstruct T from the low `sizeof(T)` bytes of the u64 wire value,
      # mirroring the push side. `copyMem` into a properly-typed `val`
      # avoids `cast[T](raw)`, which reinterprets a full 8-byte source for
      # T narrower than 8 bytes. Per gemini PR feat/v0.1.0 review.
      var val: T
      copyMem(addr val, addr raw, sizeof(T))
      PopResult[T](success: true, value: val)
    else:
      PopResult[T](success: false)

  proc name*[T](a: CrossbeamArrayQueueAdapter[T]): string =
    "crossbeam_queue/ArrayQueue[u64]"
