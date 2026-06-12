## Adapter for ``boost::lockfree::spsc_queue<uint64_t>`` (SPSC bounded).
##
## ``boost::lockfree::spsc_queue`` is a single-producer single-consumer
## wait-free ring buffer. It provides stronger progress guarantees than
## ``boost::lockfree::queue`` (the MPMC version) at the cost of being
## restricted to one writer + one reader thread.
##
## Topology: ``spsc`` bounded. ``topologiesSupported = {tSpsc}``.
##
## Build constraint: requires ``nim cpp`` (Boost.LockFree is C++).
##
## Compile-time gating: only included when
## ``-d:adapter_boost_lockfree_spsc_available`` is passed.
##
## See ``boost_lockfree_queue_adapter.nim`` for the rationale on header
## search paths and the heap-allocated indirection (Boost queues are
## non-copyable, non-movable C++ types).

const boostIncludeDir {.strdefine.}: string = ""

when defined(adapter_boost_lockfree_spsc_available):
  when not defined(cpp):
    {.
      error: "boost_lockfree_spsc_adapter requires `nim cpp` (Boost.LockFree is C++)."
    .}

  import std/typetraits
  import ../bench_common
  import ../adapter
  import lockfree/internal/aligned_alloc

  when boostIncludeDir.len > 0:
    {.passC: "-I" & boostIncludeDir.}
  else:
    when defined(macosx) or defined(macos):
      {.passC: "-I/opt/homebrew/opt/boost/include".}
      {.passC: "-I/usr/local/include".}
    else:
      {.passC: "-I/usr/include".}
      {.passC: "-I/usr/local/include".}

  type BoostSpscRaw {.
    importcpp: "boost::lockfree::spsc_queue<unsigned long long>",
    header: "boost/lockfree/spsc_queue.hpp",
    byref
  .} = object

  proc bsPush(q: var BoostSpscRaw, v: culonglong): bool {.importcpp: "#.push(@)".}

  proc bsPop(
    q: var BoostSpscRaw, v: var culonglong
  ): csize_t {.importcpp: "#.pop(&#, 1ULL)".}

  const topologiesSupported* = {tSpsc}

  type BoostLockfreeSpscAdapter*[T] = object
    queue*: ptr BoostSpscRaw
    capacity*: int

  proc makeBoostLockfreeSpscAdapter*[T](
      capacity: int = 1024
  ): BoostLockfreeSpscAdapter[T] =
    when not supportsCopyMem(T):
      {.error: "BoostLockfreeSpscAdapter[T] requires POD T (no =copy/=destroy hooks); the C++ queue stores raw uint64 and would bypass user hooks.".}
    when sizeof(T) != sizeof(uint64):
      {.error: "BoostLockfreeSpscAdapter[T] requires sizeof(T) == 8; the C++ cell is uint64 and a mismatched T would truncate or sign-extend silently.".}
    result.capacity = capacity
    # `allocAligned` (cache-line aligned, zeroed) instead of `alloc0` so the
    # placement-constructed Boost spsc_queue gets the alignment its internal
    # padding pragmas expect; matches the bounded `lockfree::queue` adapter.
    result.queue = allocAligned[BoostSpscRaw]()
    {.
      emit: [
        "new (",
        result.queue,
        ") boost::lockfree::spsc_queue<unsigned long long>(",
        csize_t(capacity),
        ");",
      ]
    .}

  proc cleanup*[T](a: var BoostLockfreeSpscAdapter[T]) =
    if a.queue != nil:
      {.emit: [a.queue, "->~spsc_queue();"].}
      freeAligned(a.queue)
      a.queue = nil

  proc push*[T](a: var BoostLockfreeSpscAdapter[T], item: T): PushResult =
    if a.queue == nil:
      return prFull
    # `cast[uint64](item)` (not `uint64(item)`) so non-numeric 8-byte
    # payloads (pointers, distinct-int aliases) round-trip through the
    # C++ uint64 wire format by their bit pattern. Per gemini PR
    # feat/v0.1.0 review, 2026-06-07.
    if bsPush(a.queue[], culonglong(cast[uint64](item))): prSuccess else: prFull

  proc pop*[T](a: var BoostLockfreeSpscAdapter[T]): PopResult[T] =
    if a.queue == nil:
      return PopResult[T](success: false)
    var raw: culonglong
    let n = bsPop(a.queue[], raw)
    if n == csize_t(1):
      # `cast[T]` mirrors the push side so pointer payloads recover
      # their original bit pattern. Per gemini PR feat/v0.1.0 review,
      # 2026-06-07.
      PopResult[T](success: true, value: cast[T](uint64(raw)))
    else:
      PopResult[T](success: false)

  proc name*[T](a: BoostLockfreeSpscAdapter[T]): string =
    "boost_lockfree_queue/spsc_queue[uint64]"
