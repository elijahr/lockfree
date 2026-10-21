## Adapter for lockfree C-ABI bounded MPMC queue.
##
## Exercises `src/lockfree/cabi.nim`:
##   `lfq_bounded_mpmc_create`
##   `lfq_producer_acquire` / `lfq_consumer_acquire`
##   `lfq_push` / `lfq_pop`
##   `lfq_producer_release` / `lfq_consumer_release`
##   `lfq_queue_destroy`

import std/atomics
import lockfree/cabi
import ../bench_common

const topologiesSupported*: set[Topology] = {tSpsc, tMpsc, tMpmc}

type
  LockfreeCabiAdapter*[T] = object
    queue*: ptr lfq_queue_t
    capacity*: int

var tlProducer {.threadvar.}: ptr lfq_producer_t
var tlConsumer {.threadvar.}: ptr lfq_consumer_t

proc makeLockfreeCabiAdapter*[T](capacity: int = 1024): LockfreeCabiAdapter[T] =
  result.capacity = capacity
  let st = lfq_bounded_mpmc_create(
    csize_t(capacity),
    csize_t(64),
    csize_t(64),
    nil,
    nil,
    addr result.queue
  )
  if st != LFQ_OK or result.queue == nil:
    raise newException(ValueError, "Failed to create cabi queue: " & $st)

proc cleanup*[T](a: var LockfreeCabiAdapter[T]) =
  if a.queue != nil:
    if tlProducer != nil and tlProducer.queue == a.queue:
      discard lfq_producer_release(tlProducer)
      tlProducer = nil
    if tlConsumer != nil and tlConsumer.queue == a.queue:
      discard lfq_consumer_release(tlConsumer)
      tlConsumer = nil
    a.queue.activeProducers.store(0, moRelaxed)
    a.queue.activeConsumers.store(0, moRelaxed)
    discard lfq_queue_destroy(a.queue)
    a.queue = nil

proc push*[T](a: var LockfreeCabiAdapter[T], item: T): PushResult =
  if unlikely(tlProducer == nil or tlProducer.queue != a.queue):
    let st = lfq_producer_acquire(a.queue, addr tlProducer)
    if st != LFQ_OK: return prFull
  # Non-null pointer payload (+ 1 offset so item=0 doesn't encode as NULL)
  let ptrVal = cast[pointer](uint64(item) + 1'u64)
  let st = lfq_push(tlProducer, ptrVal)
  if st == LFQ_OK:
    prSuccess
  else:
    prFull

proc pop*[T](a: var LockfreeCabiAdapter[T]): PopResult[T] =
  if unlikely(tlConsumer == nil or tlConsumer.queue != a.queue):
    let st = lfq_consumer_acquire(a.queue, addr tlConsumer)
    if st != LFQ_OK: return PopResult[T](success: false)
  var raw: pointer = nil
  let st = lfq_pop(tlConsumer, addr raw)
  if st == LFQ_OK and raw != nil:
    let item = cast[T](cast[uint64](raw) - 1'u64)
    PopResult[T](success: true, value: item)
  else:
    PopResult[T](success: false)

proc name*[T](a: LockfreeCabiAdapter[T]): string =
  "lockfree/cabi/BQueue"
