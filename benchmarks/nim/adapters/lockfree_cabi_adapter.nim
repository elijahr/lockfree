## Adapter for lockfree C-ABI bounded MPMC queue.
##
## Exercises `src/lockfree/cabi.nim`:
##   `lf_bounded_mpmc_create`
##   `lf_producer_acquire` / `lf_consumer_acquire`
##   `lf_push` / `lf_pop`
##   `lf_producer_release` / `lf_consumer_release`
##   `lf_queue_destroy`

import std/atomics
import lockfree/cabi
import ../bench_common

const topologiesSupported*: set[Topology] = {tSpsc, tMpsc, tMpmc}

type
  LockfreeCabiAdapter*[T] = object
    queue*: ptr lf_queue_t
    capacity*: int

var tlProducer {.threadvar.}: ptr lf_producer_t
var tlConsumer {.threadvar.}: ptr lf_consumer_t

proc makeLockfreeCabiAdapter*[T](capacity: int = 1024): LockfreeCabiAdapter[T] =
  result.capacity = capacity
  let st = lf_bounded_mpmc_create(
    csize_t(capacity),
    csize_t(64),
    csize_t(64),
    nil,
    nil,
    addr result.queue
  )
  if st != LF_OK or result.queue == nil:
    raise newException(ValueError, "Failed to create cabi queue: " & $st)

proc cleanup*[T](a: var LockfreeCabiAdapter[T]) =
  if a.queue != nil:
    if tlProducer != nil and tlProducer.queue == a.queue:
      discard lf_producer_release(tlProducer)
      tlProducer = nil
    if tlConsumer != nil and tlConsumer.queue == a.queue:
      discard lf_consumer_release(tlConsumer)
      tlConsumer = nil
    a.queue.activeProducers.store(0, moRelaxed)
    a.queue.activeConsumers.store(0, moRelaxed)
    discard lf_queue_destroy(a.queue)
    a.queue = nil

proc push*[T](a: var LockfreeCabiAdapter[T], item: T): PushResult =
  if unlikely(tlProducer == nil or tlProducer.queue != a.queue):
    let st = lf_producer_acquire(a.queue, addr tlProducer)
    if st != LF_OK: return prFull
  # Non-null pointer payload (+ 1 offset so item=0 doesn't encode as NULL)
  let ptrVal = cast[pointer](uint64(item) + 1'u64)
  let st = lf_push(tlProducer, ptrVal)
  if st == LF_OK:
    prSuccess
  else:
    prFull

proc pop*[T](a: var LockfreeCabiAdapter[T]): PopResult[T] =
  if unlikely(tlConsumer == nil or tlConsumer.queue != a.queue):
    let st = lf_consumer_acquire(a.queue, addr tlConsumer)
    if st != LF_OK: return PopResult[T](success: false)
  var raw: pointer = nil
  let st = lf_pop(tlConsumer, addr raw)
  if st == LF_OK and raw != nil:
    let item = cast[T](cast[uint64](raw) - 1'u64)
    PopResult[T](success: true, value: item)
  else:
    PopResult[T](success: false)

proc name*[T](a: LockfreeCabiAdapter[T]): string =
  "lockfree/cabi/BQueue"
