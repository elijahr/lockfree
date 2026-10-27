## ==============================================================================
## Test Suite: C ABI Interoperability (`tests/t_cabi.nim`)
## ==============================================================================
##
## Verifies the canonical C99 interface declared in `include/lockfree.h` and
## implemented in `src/lockfree/cabi.nim`:
## - Bounded & unbounded MPMC queue lifecycle
## - Opaque handle acquisition, thread registration, and releasing
## - Zero-copy pointer transport and FIFO ordering
## - Full capacity and empty queue error handling
## - Batch pop operations
## - Item cleanup callbacks on queue destroy
## - Registry limits and slot reuse
## - Multithreaded cross-thread push/pop concurrency
## - Direct C99 emission `#include "lockfree.h"` verifying header correctness
## ==============================================================================

import unittest2
import std/os
import lockfree/atomics
import lockfree/atomics/backoff
import lockfree/cabi

# Pass include path to the C compiler so #include "lockfree.h" resolves
const includeDir {.used.} = currentSourcePath().parentDir() / "../include"

type
  ThreadProducerArg = object
    queue: ptr lf_queue_t
    items: int

  ThreadConsumerArg = object
    queue: ptr lf_queue_t
    targetTotal: int
    totalPopped: ptr Atomic[int]

proc threadProducerWorker(arg: ptr ThreadProducerArg) {.thread.} =
  var prod: ptr lf_producer_t = nil
  if lf_producer_acquire(arg.queue, addr prod) == LF_OK:
    for i in 1 .. arg.items:
      while lf_push(prod, cast[pointer](i)) == LF_ERR_FULL:
        cpuPause()
    discard lf_producer_release(prod)

proc threadConsumerWorker(arg: ptr ThreadConsumerArg) {.thread.} =
  var cons: ptr lf_consumer_t = nil
  if lf_consumer_acquire(arg.queue, addr cons) == LF_OK:
    var item: pointer = nil
    while arg.totalPopped[].load(moRelaxed) < arg.targetTotal:
      if lf_pop(cons, addr item) == LF_OK:
        discard arg.totalPopped[].fetchAdd(1, moRelaxed)
      else:
        cpuPause()
    discard lf_consumer_release(cons)

type
  UniqueProducerArg = object
    queue: ptr lf_queue_t
    startVal: int
    count: int

  UniqueConsumerArg = object
    queue: ptr lf_queue_t
    targetTotal: int
    totalPopped: ptr Atomic[int]
    checksum: ptr Atomic[uint64]
    seenArray: ptr UncheckedArray[Atomic[uint8]]

proc uniqueProducerWorker(arg: ptr UniqueProducerArg) {.thread.} =
  var prod: ptr lf_producer_t = nil
  if lf_producer_acquire(arg.queue, addr prod) == LF_OK:
    for i in 0 ..< arg.count:
      let itemVal = arg.startVal + i
      while lf_push(prod, cast[pointer](itemVal)) == LF_ERR_FULL:
        cpuPause()
    discard lf_producer_release(prod)

proc uniqueConsumerWorker(arg: ptr UniqueConsumerArg) {.thread.} =
  var cons: ptr lf_consumer_t = nil
  if lf_consumer_acquire(arg.queue, addr cons) == LF_OK:
    var item: pointer = nil
    while arg.totalPopped[].load(moRelaxed) < arg.targetTotal:
      if lf_pop(cons, addr item) == LF_OK:
        let val = cast[int](item)
        discard arg.totalPopped[].fetchAdd(1, moRelaxed)
        discard arg.checksum[].fetchAdd(uint64(val), moRelaxed)
        if arg.seenArray != nil:
          let prev = arg.seenArray[val].exchange(1'u8, moRelaxed)
          doAssert prev == 0'u8, "Duplicate item detected in C ABI consumer pop: " & $val
      else:
        cpuPause()
    discard lf_consumer_release(cons)

type
  RzSyncArg = object
    chan: ptr lf_rendezvous_t
    recvVal: ptr Atomic[int]
    recvCid: ptr Atomic[uint64]

proc rzSyncWorker(arg: ptr RzSyncArg) {.thread.} =
  var item: pointer = nil
  var cid: uint64 = 0
  if lf_rendezvous_recv(arg.chan, addr item, addr cid) == LF_OK:
    arg.recvVal[].store(cast[int](item), moRelaxed)
    arg.recvCid[].store(cid, moRelaxed)

suite "lockfree C ABI Specification & Cross-Language Interop":

  test "Bounded MPMC lifecycle & FIFO ordering":
    var queue: ptr lf_queue_t = nil
    check lf_bounded_mpmc_create(8, 2, 2, nil, nil, addr queue) == LF_OK
    check queue != nil
    check lf_queue_is_empty(queue) == true
    check lf_queue_len(queue) == 0

    var prod: ptr lf_producer_t = nil
    var cons: ptr lf_consumer_t = nil
    check lf_producer_acquire(queue, addr prod) == LF_OK
    check lf_consumer_acquire(queue, addr cons) == LF_OK
    check prod != nil
    check cons != nil

    # Push 3 items
    check lf_push(prod, cast[pointer](101)) == LF_OK
    check lf_push(prod, cast[pointer](102)) == LF_OK
    check lf_push(prod, cast[pointer](103)) == LF_OK

    check lf_queue_is_empty(queue) == false
    check lf_queue_len(queue) == 3

    # Pop items and verify FIFO
    var item: pointer = nil
    check lf_pop(cons, addr item) == LF_OK
    check cast[int](item) == 101

    check lf_pop(cons, addr item) == LF_OK
    check cast[int](item) == 102

    check lf_pop(cons, addr item) == LF_OK
    check cast[int](item) == 103

    # Empty pop
    check lf_pop(cons, addr item) == LF_ERR_EMPTY
    check lf_queue_is_empty(queue) == true

    check lf_producer_release(prod) == LF_OK
    check lf_consumer_release(cons) == LF_OK
    check lf_queue_destroy(queue) == LF_OK

  test "Bounded MPMC full capacity handling":
    var queue: ptr lf_queue_t = nil
    check lf_bounded_mpmc_create(4, 2, 2, nil, nil, addr queue) == LF_OK

    var prod: ptr lf_producer_t = nil
    var cons: ptr lf_consumer_t = nil
    check lf_producer_acquire(queue, addr prod) == LF_OK
    check lf_consumer_acquire(queue, addr cons) == LF_OK

    for i in 1 .. 4:
      check lf_push(prod, cast[pointer](i)) == LF_OK

    # 5th push must return LF_ERR_FULL
    check lf_push(prod, cast[pointer](5)) == LF_ERR_FULL

    # Pop 1 item
    var item: pointer = nil
    check lf_pop(cons, addr item) == LF_OK
    check cast[int](item) == 1

    # Now push should succeed
    check lf_push(prod, cast[pointer](5)) == LF_OK

    # Drain remaining
    var count = 0
    while lf_pop(cons, addr item) == LF_OK:
      inc count
    check count == 4

    check lf_producer_release(prod) == LF_OK
    check lf_consumer_release(cons) == LF_OK
    check lf_queue_destroy(queue) == LF_OK

  test "Unbounded MPMC lifecycle and segment growth":
    var queue: ptr lf_queue_t = nil
    check lf_unbounded_mpmc_create(16, 4, nil, nil, addr queue) == LF_OK
    check queue != nil
    check lf_queue_is_empty(queue) == true

    var prod: ptr lf_producer_t = nil
    var cons: ptr lf_consumer_t = nil
    check lf_producer_acquire(queue, addr prod) == LF_OK
    check lf_consumer_acquire(queue, addr cons) == LF_OK

    # Push 100 items (spanning across multiple segments of size 16)
    for i in 1 .. 100:
      check lf_push(prod, cast[pointer](i)) == LF_OK

    check lf_queue_len(queue) == 100
    check lf_queue_is_empty(queue) == false

    # Pop 100 items and verify FIFO order
    var item: pointer = nil
    for i in 1 .. 100:
      check lf_pop(cons, addr item) == LF_OK
      check cast[int](item) == i

    # Next pop should be empty
    check lf_pop(cons, addr item) == LF_ERR_EMPTY

    check lf_producer_release(prod) == LF_OK
    check lf_consumer_release(cons) == LF_OK
    check lf_queue_destroy(queue) == LF_OK

  test "Batch pop operations (lf_pop_batch)":
    var queue: ptr lf_queue_t = nil
    check lf_bounded_mpmc_create(16, 2, 2, nil, nil, addr queue) == LF_OK

    var prod: ptr lf_producer_t = nil
    var cons: ptr lf_consumer_t = nil
    check lf_producer_acquire(queue, addr prod) == LF_OK
    check lf_consumer_acquire(queue, addr cons) == LF_OK

    for i in 1 .. 10:
      check lf_push(prod, cast[pointer](i)) == LF_OK

    var buffer: array[10, pointer]
    let popped1 = lf_pop_batch(cons, addr buffer[0], 4)
    check popped1 == 4
    for i in 0 ..< 4:
      check cast[int](buffer[i]) == i + 1

    let popped2 = lf_pop_batch(cons, addr buffer[0], 10)
    check popped2 == 6 # only 6 remaining
    for i in 0 ..< 6:
      check cast[int](buffer[i]) == i + 5

    let poppedEmpty = lf_pop_batch(cons, addr buffer[0], 5)
    check poppedEmpty == 0

    check lf_producer_release(prod) == LF_OK
    check lf_consumer_release(cons) == LF_OK
    check lf_queue_destroy(queue) == LF_OK

  var destroyedCount = 0
  proc testItemDestructor(item: pointer, userData: pointer) {.cdecl, gcsafe.} =
    let pCount = cast[ptr int](userData)
    pCount[] += 1
    discard item

  test "Item destructor callback on queue teardown":
    destroyedCount = 0
    var queue: ptr lf_queue_t = nil
    check lf_bounded_mpmc_create(8, 2, 2, testItemDestructor, addr destroyedCount, addr queue) == LF_OK

    var prod: ptr lf_producer_t = nil
    var cons: ptr lf_consumer_t = nil
    check lf_producer_acquire(queue, addr prod) == LF_OK
    check lf_consumer_acquire(queue, addr cons) == LF_OK

    # Push 5 items
    for i in 1 .. 5:
      check lf_push(prod, cast[pointer](i)) == LF_OK

    # Pop 2 items
    var item: pointer = nil
    check lf_pop(cons, addr item) == LF_OK
    check lf_pop(cons, addr item) == LF_OK

    # 3 items remain in queue
    check lf_producer_release(prod) == LF_OK
    check lf_consumer_release(cons) == LF_OK

    # Destroy queue - unpopped items must be cleaned up via destructor callback
    check lf_queue_destroy(queue) == LF_OK
    check destroyedCount == 3

  test "Registry limits and recycling after release":
    var queue: ptr lf_queue_t = nil
    check lf_bounded_mpmc_create(8, 2, 1, nil, nil, addr queue) == LF_OK

    var p1, p2, p3: ptr lf_producer_t = nil
    var c1, c2: ptr lf_consumer_t = nil

    check lf_producer_acquire(queue, addr p1) == LF_OK
    check lf_producer_acquire(queue, addr p2) == LF_OK
    # 3rd producer should fail with REGISTRY_FULL
    check lf_producer_acquire(queue, addr p3) == LF_ERR_REGISTRY_FULL
    check p3 == nil

    # Consumer limit is 1
    check lf_consumer_acquire(queue, addr c1) == LF_OK
    check lf_consumer_acquire(queue, addr c2) == LF_ERR_REGISTRY_FULL
    check c2 == nil

    # Release p1 -> p3 should now succeed
    check lf_producer_release(p1) == LF_OK
    check lf_producer_acquire(queue, addr p3) == LF_OK
    check p3 != nil

    check lf_producer_release(p2) == LF_OK
    check lf_producer_release(p3) == LF_OK
    check lf_consumer_release(c1) == LF_OK
    check lf_queue_destroy(queue) == LF_OK

  test "Invalid argument validation":
    var queue: ptr lf_queue_t = nil
    check lf_bounded_mpmc_create(0, 1, 1, nil, nil, addr queue) == LF_ERR_INVALID_ARG
    check lf_bounded_mpmc_create(8, 1, 1, nil, nil, nil) == LF_ERR_INVALID_ARG
    check lf_unbounded_mpmc_create(16, 4, nil, nil, nil) == LF_ERR_INVALID_ARG
    check lf_queue_destroy(nil) == LF_ERR_INVALID_ARG

    var prod: ptr lf_producer_t = nil
    check lf_producer_acquire(nil, addr prod) == LF_ERR_INVALID_ARG
    check lf_producer_release(nil) == LF_ERR_INVALID_ARG
    check lf_push(nil, cast[pointer](1)) == LF_ERR_INVALID_ARG

    var item: pointer = nil
    check lf_pop(nil, addr item) == LF_ERR_INVALID_ARG
    var cons: ptr lf_consumer_t = nil
    check lf_consumer_release(cons) == LF_ERR_INVALID_ARG
    check lf_pop_batch(nil, addr item, 5) == 0
    check lf_queue_len(nil) == 0
    check lf_queue_is_empty(nil) == true

  test "Multithreaded concurrent producer/consumer":
    var queue: ptr lf_queue_t = nil
    check lf_unbounded_mpmc_create(32, 8, nil, nil, addr queue) == LF_OK

    const NumProducers = 4
    const NumConsumers = 4
    const ItemsPerProducer = 1000

    var producerThreads: array[NumProducers, Thread[ptr ThreadProducerArg]]
    var consumerThreads: array[NumConsumers, Thread[ptr ThreadConsumerArg]]
    var pArgs: array[NumProducers, ThreadProducerArg]
    var cArgs: array[NumConsumers, ThreadConsumerArg]
    var totalPopped: Atomic[int]
    totalPopped.store(0, moRelaxed)

    for i in 0 ..< NumConsumers:
      cArgs[i] = ThreadConsumerArg(queue: queue, targetTotal: NumProducers * ItemsPerProducer, totalPopped: addr totalPopped)
      createThread(consumerThreads[i], threadConsumerWorker, addr cArgs[i])
    for i in 0 ..< NumProducers:
      pArgs[i] = ThreadProducerArg(queue: queue, items: ItemsPerProducer)
      createThread(producerThreads[i], threadProducerWorker, addr pArgs[i])

    joinThreads(producerThreads)
    joinThreads(consumerThreads)

    check totalPopped.load(moRelaxed) == (NumProducers * ItemsPerProducer)
    check lf_queue_destroy(queue) == LF_OK

  test "C ABI Bounded MPMC 4P/4C 100k items stress":
    var queue: ptr lf_queue_t = nil
    check lf_bounded_mpmc_create(1024, 4, 4, nil, nil, addr queue) == LF_OK

    const NumProducers = 4
    const NumConsumers = 4
    const ItemsPerProducer = 25_000

    var producerThreads: array[NumProducers, Thread[ptr ThreadProducerArg]]
    var consumerThreads: array[NumConsumers, Thread[ptr ThreadConsumerArg]]
    var pArgs: array[NumProducers, ThreadProducerArg]
    var cArgs: array[NumConsumers, ThreadConsumerArg]
    var totalPopped: Atomic[int]
    totalPopped.store(0, moRelaxed)

    for i in 0 ..< NumConsumers:
      cArgs[i] = ThreadConsumerArg(queue: queue, targetTotal: NumProducers * ItemsPerProducer, totalPopped: addr totalPopped)
      createThread(consumerThreads[i], threadConsumerWorker, addr cArgs[i])
    for i in 0 ..< NumProducers:
      pArgs[i] = ThreadProducerArg(queue: queue, items: ItemsPerProducer)
      createThread(producerThreads[i], threadProducerWorker, addr pArgs[i])

    joinThreads(producerThreads)
    joinThreads(consumerThreads)

    check totalPopped.load(moRelaxed) == (NumProducers * ItemsPerProducer)
    check lf_queue_destroy(queue) == LF_OK

  test "C ABI Unbounded MPMC 4P/4C 100k items stress":
    var queue: ptr lf_queue_t = nil
    check lf_unbounded_mpmc_create(64, 16, nil, nil, addr queue) == LF_OK

    const NumProducers = 4
    const NumConsumers = 4
    const ItemsPerProducer = 25_000

    var producerThreads: array[NumProducers, Thread[ptr ThreadProducerArg]]
    var consumerThreads: array[NumConsumers, Thread[ptr ThreadConsumerArg]]
    var pArgs: array[NumProducers, ThreadProducerArg]
    var cArgs: array[NumConsumers, ThreadConsumerArg]
    var totalPopped: Atomic[int]
    totalPopped.store(0, moRelaxed)

    for i in 0 ..< NumConsumers:
      cArgs[i] = ThreadConsumerArg(queue: queue, targetTotal: NumProducers * ItemsPerProducer, totalPopped: addr totalPopped)
      createThread(consumerThreads[i], threadConsumerWorker, addr cArgs[i])
    for i in 0 ..< NumProducers:
      pArgs[i] = ThreadProducerArg(queue: queue, items: ItemsPerProducer)
      createThread(producerThreads[i], threadProducerWorker, addr pArgs[i])

    joinThreads(producerThreads)
    joinThreads(consumerThreads)

    check totalPopped.load(moRelaxed) == (NumProducers * ItemsPerProducer)
    check lf_queue_destroy(queue) == LF_OK

  test "AUDIT-CABI-01: Multiple queue handles on single thread without NEBR panic":
    var q1, q2: ptr lf_queue_t = nil
    check lf_unbounded_mpmc_create(16, 4, nil, nil, addr q1) == LF_OK
    check lf_unbounded_mpmc_create(16, 4, nil, nil, addr q2) == LF_OK

    var p1, p2: ptr lf_producer_t = nil
    var c1, c2: ptr lf_consumer_t = nil

    check lf_producer_acquire(q1, addr p1) == LF_OK
    check lf_producer_acquire(q2, addr p2) == LF_OK
    check lf_consumer_acquire(q1, addr c1) == LF_OK
    check lf_consumer_acquire(q2, addr c2) == LF_OK

    check lf_push(p1, cast[pointer](111)) == LF_OK
    check lf_push(p2, cast[pointer](222)) == LF_OK

    var item: pointer = nil
    check lf_pop(c1, addr item) == LF_OK
    check cast[int](item) == 111
    check lf_pop(c2, addr item) == LF_OK
    check cast[int](item) == 222

    # Release across different queues without NEBR threadvar assertion panic
    check lf_producer_release(p1) == LF_OK
    check lf_consumer_release(c1) == LF_OK
    check lf_producer_release(p2) == LF_OK
    check lf_consumer_release(c2) == LF_OK

    check lf_queue_destroy(q1) == LF_OK
    check lf_queue_destroy(q2) == LF_OK

  test "HIGH-CABI-02: Queue destruction rejected when endpoints active":
    var queue: ptr lf_queue_t = nil
    check lf_bounded_mpmc_create(8, 2, 2, nil, nil, addr queue) == LF_OK

    var prod: ptr lf_producer_t = nil
    check lf_producer_acquire(queue, addr prod) == LF_OK

    # Cannot destroy while producer is active
    check lf_queue_destroy(queue) == LF_ERR_FAILURE

    check lf_producer_release(prod) == LF_OK

    var cons: ptr lf_consumer_t = nil
    check lf_consumer_acquire(queue, addr cons) == LF_OK

    # Cannot destroy while consumer is active
    check lf_queue_destroy(queue) == LF_ERR_FAILURE

    check lf_consumer_release(cons) == LF_OK

    # Now destruction succeeds
    check lf_queue_destroy(queue) == LF_OK

  test "AUDIT-CABI-03: Queue close semantics and drain":
    var queue: ptr lf_queue_t = nil
    check lf_bounded_mpmc_create(8, 2, 2, nil, nil, addr queue) == LF_OK
    check lf_queue_is_closed(queue) == false

    var prod: ptr lf_producer_t = nil
    var cons: ptr lf_consumer_t = nil
    check lf_producer_acquire(queue, addr prod) == LF_OK
    check lf_consumer_acquire(queue, addr cons) == LF_OK

    check lf_push(prod, cast[pointer](10)) == LF_OK
    check lf_push(prod, cast[pointer](20)) == LF_OK
    check lf_push(prod, cast[pointer](30)) == LF_OK

    # Close queue
    check lf_queue_close(queue) == LF_OK
    check lf_queue_is_closed(queue) == true

    # Subsequent push must fail with LF_ERR_CLOSED
    check lf_push(prod, cast[pointer](40)) == LF_ERR_CLOSED

    # Acquiring new producer must fail with LF_ERR_CLOSED
    var p2: ptr lf_producer_t = nil
    check lf_producer_acquire(queue, addr p2) == LF_ERR_CLOSED
    check p2 == nil

    # Consumer drains remaining items
    var item: pointer = nil
    check lf_pop(cons, addr item) == LF_OK
    check cast[int](item) == 10
    check lf_pop(cons, addr item) == LF_OK
    check cast[int](item) == 20
    check lf_pop(cons, addr item) == LF_OK
    check cast[int](item) == 30

    # Once drained, pop returns LF_ERR_EMPTY
    check lf_pop(cons, addr item) == LF_ERR_EMPTY

    check lf_producer_release(prod) == LF_OK
    check lf_consumer_release(cons) == LF_OK
    check lf_queue_destroy(queue) == LF_OK

  test "AUDIT-CABI-03: Multithreaded concurrent with payload uniqueness & checksum":
    var queue: ptr lf_queue_t = nil
    check lf_unbounded_mpmc_create(64, 16, nil, nil, addr queue) == LF_OK

    const NumProds = 4
    const NumCons = 4
    const ItemsPerProd = 5000
    const TotalItems = NumProds * ItemsPerProd
    const ExpectedSum = uint64(TotalItems) * uint64(TotalItems + 1) div 2'u64

    var seen = newSeq[Atomic[uint8]](TotalItems + 1)
    var prodThreads: array[NumProds, Thread[ptr UniqueProducerArg]]
    var consThreads: array[NumCons, Thread[ptr UniqueConsumerArg]]
    var pArgs: array[NumProds, UniqueProducerArg]
    var cArgs: array[NumCons, UniqueConsumerArg]
    var totalPopped: Atomic[int]
    var sumChecksum: Atomic[uint64]
    totalPopped.store(0, moRelaxed)
    sumChecksum.store(0, moRelaxed)

    for i in 0 ..< NumCons:
      cArgs[i] = UniqueConsumerArg(
        queue: queue,
        targetTotal: TotalItems,
        totalPopped: addr totalPopped,
        checksum: addr sumChecksum,
        seenArray: cast[ptr UncheckedArray[Atomic[uint8]]](addr seen[0])
      )
      createThread(consThreads[i], uniqueConsumerWorker, addr cArgs[i])

    for i in 0 ..< NumProds:
      pArgs[i] = UniqueProducerArg(
        queue: queue,
        startVal: i * ItemsPerProd + 1,
        count: ItemsPerProd
      )
      createThread(prodThreads[i], uniqueProducerWorker, addr pArgs[i])

    joinThreads(prodThreads)
    joinThreads(consThreads)

    check totalPopped.load(moRelaxed) == TotalItems
    check sumChecksum.load(moRelaxed) == ExpectedSum
    for i in 1 .. TotalItems:
      check seen[i].load(moRelaxed) == 1'u8

    check lf_queue_destroy(queue) == LF_OK

  test "Treiber Stack lifecycle & LIFO ordering":
    var stack: ptr lf_stack_t = nil
    check lf_stack_create(nil, nil, addr stack) == LF_OK
    check stack != nil
    check lf_stack_is_empty(stack) == true
    check lf_stack_len(stack) == 0

    var item: pointer = nil
    check lf_stack_pop(stack, addr item) == LF_ERR_EMPTY
    check lf_stack_peek(stack, addr item) == LF_ERR_EMPTY

    # Push 3 items: 10, 20, 30
    check lf_stack_push(stack, cast[pointer](10)) == LF_OK
    check lf_stack_push(stack, cast[pointer](20)) == LF_OK
    check lf_stack_push(stack, cast[pointer](30)) == LF_OK

    check lf_stack_is_empty(stack) == false
    check lf_stack_len(stack) == 3

    # Peek top item -> 30
    check lf_stack_peek(stack, addr item) == LF_OK
    check cast[int](item) == 30
    check lf_stack_len(stack) == 3

    # Pop LIFO order: 30, 20, 10
    check lf_stack_pop(stack, addr item) == LF_OK
    check cast[int](item) == 30

    check lf_stack_pop(stack, addr item) == LF_OK
    check cast[int](item) == 20

    check lf_stack_pop(stack, addr item) == LF_OK
    check cast[int](item) == 10

    check lf_stack_is_empty(stack) == true
    check lf_stack_pop(stack, addr item) == LF_ERR_EMPTY
    check lf_stack_destroy(stack) == LF_OK

  test "Treiber Stack drain operations":
    var stack: ptr lf_stack_t = nil
    check lf_stack_create(nil, nil, addr stack) == LF_OK

    for i in 1 .. 5:
      check lf_stack_push(stack, cast[pointer](i * 10)) == LF_OK

    check lf_stack_len(stack) == 5

    var drained: array[8, pointer]
    let count1 = lf_stack_drain(stack, cast[ptr pointer](addr drained[0]), 3)
    check count1 == 3
    check cast[int](drained[0]) == 50
    check cast[int](drained[1]) == 40
    check cast[int](drained[2]) == 30

    let count2 = lf_stack_drain(stack, cast[ptr pointer](addr drained[0]), 5)
    check count2 == 2
    check cast[int](drained[0]) == 20
    check cast[int](drained[1]) == 10

    check lf_stack_is_empty(stack) == true
    check lf_stack_destroy(stack) == LF_OK

  test "Treiber Stack destructor callback on destroy":
    type DestructorTracker = object
      count: int
      sum: int

    proc stackDestructor(item: pointer, userData: pointer) {.cdecl.} =
      let tracker = cast[ptr DestructorTracker](userData)
      if tracker != nil:
        inc tracker.count
        tracker.sum += cast[int](item)

    var tracker = DestructorTracker(count: 0, sum: 0)
    var stack: ptr lf_stack_t = nil
    check lf_stack_create(stackDestructor, addr tracker, addr stack) == LF_OK

    check lf_stack_push(stack, cast[pointer](11)) == LF_OK
    check lf_stack_push(stack, cast[pointer](22)) == LF_OK
    check lf_stack_push(stack, cast[pointer](33)) == LF_OK

    var item: pointer = nil
    check lf_stack_pop(stack, addr item) == LF_OK
    check cast[int](item) == 33

    check lf_stack_destroy(stack) == LF_OK
    check tracker.count == 2
    check tracker.sum == (11 + 22)

  test "Chase-Lev Deque worker push/pop (LIFO) & thief steal (FIFO)":
    var deque: ptr lf_deque_t = nil
    check lf_deque_create(32, nil, nil, addr deque) == LF_OK
    check deque != nil
    check lf_deque_is_empty(deque) == true
    check lf_deque_len(deque) == 0
    check lf_deque_capacity(deque) >= 32

    var item: pointer = nil
    check lf_deque_pop(deque, addr item) == LF_ERR_EMPTY
    check lf_deque_steal(deque, addr item) == LF_ERR_EMPTY

    # Worker pushes 4 items: 100, 200, 300, 400
    check lf_deque_push(deque, cast[pointer](100)) == LF_OK
    check lf_deque_push(deque, cast[pointer](200)) == LF_OK
    check lf_deque_push(deque, cast[pointer](300)) == LF_OK
    check lf_deque_push(deque, cast[pointer](400)) == LF_OK

    check lf_deque_is_empty(deque) == false
    check lf_deque_len(deque) == 4

    # Thief steals 1 item -> FIFO top item: 100
    check lf_deque_steal(deque, addr item) == LF_OK
    check cast[int](item) == 100
    check lf_deque_len(deque) == 3

    # Worker pops 1 item -> LIFO bottom item: 400
    check lf_deque_pop(deque, addr item) == LF_OK
    check cast[int](item) == 400
    check lf_deque_len(deque) == 2

    # Thief steals batch of remaining 2 items (200, 300)
    var batch: array[4, pointer]
    let stolen = lf_deque_steal_batch(deque, cast[ptr pointer](addr batch[0]), 4)
    check stolen == 2
    check cast[int](batch[0]) == 200
    check cast[int](batch[1]) == 300

    check lf_deque_is_empty(deque) == true
    check lf_deque_destroy(deque) == LF_OK

  test "Chase-Lev Deque destructor callback on destroy":
    type DestructorTracker = object
      count: int
      sum: int

    proc dequeDestructor(item: pointer, userData: pointer) {.cdecl.} =
      let tracker = cast[ptr DestructorTracker](userData)
      if tracker != nil:
        inc tracker.count
        tracker.sum += cast[int](item)

    var tracker = DestructorTracker(count: 0, sum: 0)
    var deque: ptr lf_deque_t = nil
    check lf_deque_create(32, dequeDestructor, addr tracker, addr deque) == LF_OK

    check lf_deque_push(deque, cast[pointer](7)) == LF_OK
    check lf_deque_push(deque, cast[pointer](14)) == LF_OK
    check lf_deque_push(deque, cast[pointer](21)) == LF_OK

    check lf_deque_destroy(deque) == LF_OK
    check tracker.count == 3
    check tracker.sum == (7 + 14 + 21)

  test "SkipListMap Table lifecycle, put, get, update, delete & contains":
    var table: ptr lf_table_t = nil
    check lf_table_create(nil, nil, addr table) == LF_OK
    check table != nil
    check lf_table_is_empty(table) == true
    check lf_table_len(table) == 0

    var val: pointer = nil
    check lf_table_get(table, cast[pointer](1), addr val) == LF_ERR_EMPTY
    check lf_table_contains(table, cast[pointer](1)) == false

    # Put 3 entries
    var inserted: bool = false
    check lf_table_put(table, cast[pointer](1), cast[pointer](10), addr inserted) == LF_OK
    check inserted == true
    check lf_table_put(table, cast[pointer](2), cast[pointer](20), addr inserted) == LF_OK
    check inserted == true
    check lf_table_put(table, cast[pointer](3), cast[pointer](30), addr inserted) == LF_OK
    check inserted == true

    check lf_table_is_empty(table) == false
    check lf_table_len(table) == 3
    check lf_table_contains(table, cast[pointer](1)) == true
    check lf_table_contains(table, cast[pointer](2)) == true
    check lf_table_contains(table, cast[pointer](3)) == true

    # Get items
    check lf_table_get(table, cast[pointer](1), addr val) == LF_OK
    check cast[int](val) == 10
    check lf_table_get(table, cast[pointer](2), addr val) == LF_OK
    check cast[int](val) == 20
    check lf_table_get(table, cast[pointer](3), addr val) == LF_OK
    check cast[int](val) == 30

    # Update key 2 -> 222
    check lf_table_put(table, cast[pointer](2), cast[pointer](222), addr inserted) == LF_OK
    check inserted == false
    check lf_table_len(table) == 3
    check lf_table_get(table, cast[pointer](2), addr val) == LF_OK
    check cast[int](val) == 222

    # Delete key 2
    var deleted: bool = false
    check lf_table_delete(table, cast[pointer](2), addr deleted) == LF_OK
    check deleted == true
    check lf_table_len(table) == 2
    check lf_table_contains(table, cast[pointer](2)) == false
    check lf_table_get(table, cast[pointer](2), addr val) == LF_ERR_EMPTY

    # Delete non-existent key returns LF_ERR_EMPTY
    check lf_table_delete(table, cast[pointer](999), addr deleted) == LF_ERR_EMPTY
    check deleted == false

    # Remove key 1 via alias lf_table_remove
    var removed: bool = false
    check lf_table_remove(table, cast[pointer](1), addr removed) == LF_OK
    check removed == true
    check lf_table_len(table) == 1

    check lf_table_destroy(table) == LF_OK

  test "SkipListMap Table destructor callback on destroy":
    type EntryTracker = object
      count: int
      sumKeys: int
      sumVals: int

    proc tableDestructor(key: pointer, val: pointer, userData: pointer) {.cdecl.} =
      let tracker = cast[ptr EntryTracker](userData)
      if tracker != nil:
        inc tracker.count
        tracker.sumKeys += cast[int](key)
        tracker.sumVals += cast[int](val)

    var tracker = EntryTracker(count: 0, sumKeys: 0, sumVals: 0)
    var table: ptr lf_table_t = nil
    check lf_table_create(tableDestructor, addr tracker, addr table) == LF_OK

    var inserted: bool = false
    check lf_table_put(table, cast[pointer](10), cast[pointer](100), addr inserted) == LF_OK
    check lf_table_put(table, cast[pointer](20), cast[pointer](200), addr inserted) == LF_OK

    var deleted: bool = false
    check lf_table_delete(table, cast[pointer](10), addr deleted) == LF_OK

    check lf_table_destroy(table) == LF_OK
    check tracker.count == 1
    check tracker.sumKeys == 20
    check tracker.sumVals == 200

  test "SkipListSet lifecycle, insert, remove, contains & duplicates":
    var set: ptr lf_set_t = nil
    check lf_set_create(nil, nil, addr set) == LF_OK
    check set != nil
    check lf_set_is_empty(set) == true
    check lf_set_len(set) == 0
    check lf_set_contains(set, cast[pointer](42)) == false

    # Insert 3 items
    var inserted: bool = false
    check lf_set_insert(set, cast[pointer](100), addr inserted) == LF_OK
    check inserted == true
    check lf_set_insert(set, cast[pointer](200), addr inserted) == LF_OK
    check inserted == true
    check lf_set_insert(set, cast[pointer](300), addr inserted) == LF_OK
    check inserted == true

    check lf_set_is_empty(set) == false
    check lf_set_len(set) == 3
    check lf_set_contains(set, cast[pointer](100)) == true
    check lf_set_contains(set, cast[pointer](200)) == true
    check lf_set_contains(set, cast[pointer](300)) == true

    # Insert duplicate 200
    check lf_set_insert(set, cast[pointer](200), addr inserted) == LF_OK
    check inserted == false
    check lf_set_len(set) == 3

    # Remove 200
    var removed: bool = false
    check lf_set_remove(set, cast[pointer](200), addr removed) == LF_OK
    check removed == true
    check lf_set_len(set) == 2
    check lf_set_contains(set, cast[pointer](200)) == false

    # Remove non-existent returns LF_ERR_EMPTY
    check lf_set_remove(set, cast[pointer](999), addr removed) == LF_ERR_EMPTY
    check removed == false

    check lf_set_destroy(set) == LF_OK

  test "SkipListSet destructor callback on destroy":
    type ItemTracker = object
      count: int
      sum: int

    proc setDestructor(item: pointer, userData: pointer) {.cdecl.} =
      let tracker = cast[ptr ItemTracker](userData)
      if tracker != nil:
        inc tracker.count
        tracker.sum += cast[int](item)

    var tracker = ItemTracker(count: 0, sum: 0)
    var set: ptr lf_set_t = nil
    check lf_set_create(setDestructor, addr tracker, addr set) == LF_OK

    var inserted: bool = false
    check lf_set_insert(set, cast[pointer](11), addr inserted) == LF_OK
    check lf_set_insert(set, cast[pointer](22), addr inserted) == LF_OK
    check lf_set_insert(set, cast[pointer](33), addr inserted) == LF_OK

    check lf_set_destroy(set) == LF_OK
    check tracker.count == 3
    check tracker.sum == (11 + 22 + 33)

  test "Ctrie lifecycle, insert, lookup, remove, and wait-free snapshot":
    var ctrie: ptr lf_ctrie_t = nil
    check lf_ctrie_create(nil, nil, addr ctrie) == LF_OK
    check ctrie != nil
    check lf_ctrie_is_empty(ctrie) == true
    check lf_ctrie_len(ctrie) == 0

    var inserted: bool = false
    check lf_ctrie_insert(ctrie, cast[pointer](1), cast[pointer](10), addr inserted) == LF_OK
    check inserted == true
    check lf_ctrie_insert(ctrie, cast[pointer](2), cast[pointer](20), addr inserted) == LF_OK
    check inserted == true
    check lf_ctrie_insert(ctrie, cast[pointer](3), cast[pointer](30), addr inserted) == LF_OK
    check inserted == true

    check lf_ctrie_is_empty(ctrie) == false
    check lf_ctrie_len(ctrie) == 3
    check lf_ctrie_contains(ctrie, cast[pointer](1)) == true
    check lf_ctrie_contains(ctrie, cast[pointer](2)) == true
    check lf_ctrie_contains(ctrie, cast[pointer](3)) == true
    check lf_ctrie_contains(ctrie, cast[pointer](4)) == false

    var val: pointer = nil
    check lf_ctrie_lookup(ctrie, cast[pointer](2), addr val) == LF_OK
    check cast[int](val) == 20

    # Wait-free snapshot
    var snap: ptr lf_ctrie_snapshot_t = nil
    check lf_ctrie_snapshot(ctrie, addr snap) == LF_OK
    check snap != nil
    check lf_ctrie_snapshot_is_empty(snap) == false
    check lf_ctrie_snapshot_len(snap) == 3
    check lf_ctrie_snapshot_contains(snap, cast[pointer](2)) == true

    # Mutate ctrie after snapshot
    var removed: bool = false
    check lf_ctrie_remove(ctrie, cast[pointer](2), addr removed) == LF_OK
    check removed == true
    check lf_ctrie_len(ctrie) == 2
    check lf_ctrie_contains(ctrie, cast[pointer](2)) == false

    # Snapshot should still hold 2
    check lf_ctrie_snapshot_len(snap) == 3
    check lf_ctrie_snapshot_contains(snap, cast[pointer](2)) == true
    var snapVal: pointer = nil
    check lf_ctrie_snapshot_lookup(snap, cast[pointer](2), addr snapVal) == LF_OK
    check cast[int](snapVal) == 20

    check lf_ctrie_snapshot_destroy(snap) == LF_OK
    check lf_ctrie_destroy(ctrie) == LF_OK

  test "Ctrie destructor callback on destroy":
    type EntryTracker = object
      count: int
      sumKeys: int
      sumVals: int

    proc ctrieDestructor(key: pointer, val: pointer, userData: pointer) {.cdecl.} =
      let tracker = cast[ptr EntryTracker](userData)
      if tracker != nil:
        inc tracker.count
        tracker.sumKeys += cast[int](key)
        tracker.sumVals += cast[int](val)

    var tracker = EntryTracker(count: 0, sumKeys: 0, sumVals: 0)
    var ctrie: ptr lf_ctrie_t = nil
    check lf_ctrie_create(ctrieDestructor, addr tracker, addr ctrie) == LF_OK

    var inserted: bool = false
    check lf_ctrie_insert(ctrie, cast[pointer](5), cast[pointer](50), addr inserted) == LF_OK
    check lf_ctrie_insert(ctrie, cast[pointer](6), cast[pointer](60), addr inserted) == LF_OK

    check lf_ctrie_destroy(ctrie) == LF_OK
    check tracker.count == 2
    check tracker.sumKeys == (5 + 6)
    check tracker.sumVals == (50 + 60)

  test "BroadcastRing lifecycle, fan-out multicast, and replay":
    var ring: ptr lf_broadcast_t = nil
    check lf_broadcast_create(16, LF_OVERFLOW_DROP_OLDEST, 8, addr ring) == LF_OK
    check ring != nil
    check lf_broadcast_capacity(ring) >= 16
    check lf_broadcast_len(ring) == 0
    check lf_broadcast_is_empty(ring) == true
    check lf_broadcast_subscriber_count(ring) == 0

    var cur1: ptr lf_broadcast_cursor_t = nil
    var cur2: ptr lf_broadcast_cursor_t = nil
    check lf_broadcast_subscribe(ring, LF_SUB_FROM_LATEST, addr cur1) == LF_OK
    check lf_broadcast_subscribe(ring, LF_SUB_FROM_LATEST, addr cur2) == LF_OK
    check lf_broadcast_subscriber_count(ring) == 2

    check lf_broadcast_publish(ring, cast[pointer](111)) == LF_OK
    check lf_broadcast_publish(ring, cast[pointer](222)) == LF_OK
    check lf_broadcast_len(ring) == 2
    check lf_broadcast_is_empty(ring) == false

    # cur1 reads via try_read
    var item1: pointer = nil
    check lf_broadcast_try_read(cur1, addr item1) == LF_OK
    check cast[int](item1) == 111
    check lf_broadcast_try_read(cur1, addr item1) == LF_OK
    check cast[int](item1) == 222
    check lf_broadcast_try_read(cur1, addr item1) == LF_ERR_EMPTY

    # cur2 reads via poll
    var item2: pointer = nil
    var skipped: csize_t = 0
    var res: lf_poll_result_t
    check lf_broadcast_poll(cur2, addr item2, addr skipped, addr res) == LF_OK
    check cast[int](item2) == 111
    check res == LF_POLL_SUCCESS

    check lf_broadcast_poll(cur2, addr item2, addr skipped, addr res) == LF_OK
    check cast[int](item2) == 222
    check res == LF_POLL_SUCCESS

    check lf_broadcast_poll(cur2, addr item2, addr skipped, addr res) == LF_ERR_EMPTY
    check res == LF_POLL_EMPTY

    # cur3 replay via FROM_EARLIEST
    var cur3: ptr lf_broadcast_cursor_t = nil
    check lf_broadcast_subscribe(ring, LF_SUB_FROM_EARLIEST, addr cur3) == LF_OK
    check lf_broadcast_subscriber_count(ring) == 3

    var item3: pointer = nil
    check lf_broadcast_try_read(cur3, addr item3) == LF_OK
    check cast[int](item3) == 111
    check lf_broadcast_try_read(cur3, addr item3) == LF_OK
    check cast[int](item3) == 222

    check lf_broadcast_unsubscribe(cur1) == LF_OK
    check lf_broadcast_unsubscribe(cur2) == LF_OK
    check lf_broadcast_unsubscribe(cur3) == LF_OK
    check lf_broadcast_subscriber_count(ring) == 0

    check lf_broadcast_destroy(ring) == LF_OK

  test "TopicBus C ABI lifecycle, multi-topic pub/sub, and introspection":
    var bus: ptr lf_topic_bus_t = nil
    check lf_topic_bus_create(16, LF_OVERFLOW_DROP_OLDEST, 8, addr bus) == LF_OK
    check bus != nil
    check lf_topic_bus_topic_count(bus) == 0
    check lf_topic_bus_has_topic(bus, "orders") == false

    var curOrders: ptr lf_broadcast_cursor_t = nil
    var curTrades: ptr lf_broadcast_cursor_t = nil
    check lf_topic_bus_subscribe(bus, "orders", LF_SUB_FROM_LATEST, addr curOrders) == LF_OK
    check lf_topic_bus_subscribe(bus, "trades", LF_SUB_FROM_LATEST, addr curTrades) == LF_OK
    check lf_topic_bus_topic_count(bus) == 2
    check lf_topic_bus_has_topic(bus, "orders") == true
    check lf_topic_bus_has_topic(bus, "trades") == true
    check lf_topic_bus_has_topic(bus, "quotes") == false

    check lf_topic_bus_publish(bus, "orders", cast[pointer](1001)) == LF_OK
    check lf_topic_bus_publish(bus, "trades", cast[pointer](2002)) == LF_OK

    var item: pointer = nil
    check lf_broadcast_try_read(curOrders, addr item) == LF_OK
    check cast[int](item) == 1001
    check lf_broadcast_try_read(curOrders, addr item) == LF_ERR_EMPTY

    check lf_broadcast_try_read(curTrades, addr item) == LF_OK
    check cast[int](item) == 2002
    check lf_broadcast_try_read(curTrades, addr item) == LF_ERR_EMPTY

    check lf_broadcast_unsubscribe(curOrders) == LF_OK
    check lf_broadcast_unsubscribe(curTrades) == LF_OK
    check lf_topic_bus_destroy(bus) == LF_OK

  test "RendezvousChannel C ABI Lifecycle & Synchronous Handoff":
    var chan: ptr lf_rendezvous_t = nil
    check lf_rendezvous_create(addr chan) == LF_OK
    check chan != nil
    check lf_rendezvous_is_closed(chan) == false

    var corrId: uint64 = 0
    var item: pointer = nil
    check lf_rendezvous_try_send(chan, cast[pointer](42), addr corrId) == LF_ERR_EMPTY
    check lf_rendezvous_try_recv(chan, addr item, addr corrId) == LF_ERR_EMPTY

    check lf_rendezvous_send_timeout(chan, cast[pointer](42), 5, addr corrId) == LF_ERR_EMPTY
    check lf_rendezvous_recv_timeout(chan, addr item, 5, addr corrId) == LF_ERR_EMPTY

    # Cross-thread bilateral handoff
    var rcvVal: Atomic[int]
    var rcvCid: Atomic[uint64]
    rcvVal.store(0, moRelaxed)
    rcvCid.store(0, moRelaxed)

    var rzArg = RzSyncArg(
      chan: chan,
      recvVal: addr rcvVal,
      recvCid: addr rcvCid
    )

    var th: Thread[ptr RzSyncArg]
    createThread(th, rzSyncWorker, addr rzArg)

    var scid: uint64 = 0
    check lf_rendezvous_send(chan, cast[pointer](888), addr scid) == LF_OK
    joinThread(th)

    check rcvVal.load(moRelaxed) == 888
    check scid > 0'u64
    check rcvCid.load(moRelaxed) == scid

    # Close & destroy
    check lf_rendezvous_close(chan) == LF_OK
    check lf_rendezvous_is_closed(chan) == true
    check lf_rendezvous_send(chan, cast[pointer](1), addr corrId) == LF_ERR_CLOSED
    check lf_rendezvous_recv(chan, addr item, addr corrId) == LF_ERR_CLOSED
    check lf_rendezvous_destroy(chan) == LF_OK

  test "Rate Limiters C ABI (TokenBucket & LeakyBucket)":
    # Stack-allocated TokenBucket
    var tb: lf_token_bucket_t
    check lf_token_bucket_init(addr tb, 100, 50) == 0
    check lf_token_bucket_available(addr tb) == 100
    check lf_token_bucket_try_acquire(addr tb, 40) == true
    check lf_token_bucket_available(addr tb) == 60
    check lf_token_bucket_acquire_timeout(addr tb, 10, 1_000_000) == true

    # Reset
    lf_token_bucket_reset(addr tb, 100)
    check lf_token_bucket_available(addr tb) == 100

    # Heap-allocated TokenBucket
    let heapTb = lf_token_bucket_create(50, 10)
    check heapTb != nil
    check lf_token_bucket_available(heapTb) == 50
    check lf_token_bucket_try_acquire(heapTb, 25) == true
    lf_token_bucket_destroy(heapTb)

    # Stack-allocated LeakyBucket
    var lb: lf_leaky_bucket_t
    check lf_leaky_bucket_init(addr lb, 100_000_000, 20) == 0
    check lf_leaky_bucket_try_consume(addr lb, 1) == true
    check lf_leaky_bucket_water_level(addr lb) > 0
    lf_leaky_bucket_reset(addr lb)
    check lf_leaky_bucket_water_level(addr lb) == 0

    # Heap-allocated LeakyBucket
    let heapLb = lf_leaky_bucket_create(200_000_000, 50)
    check heapLb != nil
    check lf_leaky_bucket_try_consume(heapLb, 1) == true
    lf_leaky_bucket_destroy(heapLb)

  test "StreamRing / StreamBuffer & MPMCStreamRing C ABI":
    let ring = lf_stream_ring_create(1024, false)
    check ring != nil
    check lf_stream_ring_capacity(ring) == 1024
    check lf_stream_ring_available_read(ring) == 0
    check lf_stream_ring_available_write(ring) == 1024
    check lf_stream_ring_is_empty(ring) == true
    check lf_stream_ring_is_full(ring) == false

    var msg = "StreamRing Nim C ABI Test"
    let written = lf_stream_ring_try_write(ring, cast[pointer](addr msg[0]), csize_t(msg.len))
    check written == csize_t(msg.len)
    check lf_stream_ring_available_read(ring) == csize_t(msg.len)

    var readBuf = newString(64)
    let readBytes = lf_stream_ring_try_read(ring, cast[pointer](addr readBuf[0]), csize_t(readBuf.len))
    check readBytes == csize_t(msg.len)
    readBuf.setLen(int(readBytes))
    check readBuf == msg
    check lf_stream_ring_is_empty(ring) == true

    # Zero-copy IOVec test
    let iovW = lf_stream_ring_acquire_write_iov(ring, 100)
    check iovW.first.iov_len + iovW.second.iov_len == 100
    lf_stream_ring_commit_write(ring, 100)
    check lf_stream_ring_available_read(ring) == 100

    let iovR = lf_stream_ring_acquire_read_iov(ring, 100)
    check iovR.first.iov_len + iovR.second.iov_len == 100
    lf_stream_ring_commit_read(ring, 100)
    check lf_stream_ring_is_empty(ring) == true

    lf_stream_ring_destroy(ring)

    # StreamBuffer alias test
    let sbuf = lf_streambuffer_create(512, false)
    check sbuf != nil
    check lf_streambuffer_capacity(sbuf) == 512
    check lf_streambuffer_available_read(sbuf) == 0
    check lf_streambuffer_available_write(sbuf) == 512
    check lf_streambuffer_is_empty(sbuf) == true
    check lf_streambuffer_is_full(sbuf) == false
    lf_streambuffer_destroy(sbuf)

    # MPMCStreamRing test
    let mpmcRing = lf_mpmc_stream_ring_create(1024)
    check mpmcRing != nil
    check lf_mpmc_stream_ring_capacity(mpmcRing) == 1024
    check lf_mpmc_stream_ring_available_read(mpmcRing) == 0
    check lf_mpmc_stream_ring_available_write(mpmcRing) == 1024
    check lf_mpmc_stream_ring_is_empty(mpmcRing) == true
    check lf_mpmc_stream_ring_is_full(mpmcRing) == false

    var mpmcMsg = "MPMCStreamRing Nim C ABI Payload"
    let mpmcWritten = lf_mpmc_stream_ring_try_write(mpmcRing, cast[pointer](addr mpmcMsg[0]), csize_t(mpmcMsg.len))
    check mpmcWritten == csize_t(mpmcMsg.len)
    check lf_mpmc_stream_ring_available_read(mpmcRing) == csize_t(mpmcMsg.len)
    check lf_mpmc_stream_ring_is_empty(mpmcRing) == false

    var mpmcReadBuf = newString(64)
    let mpmcRead = lf_mpmc_stream_ring_try_read(mpmcRing, cast[pointer](addr mpmcReadBuf[0]), csize_t(mpmcReadBuf.len))
    check mpmcRead == csize_t(mpmcMsg.len)
    mpmcReadBuf.setLen(int(mpmcRead))
    check mpmcReadBuf == mpmcMsg
    check lf_mpmc_stream_ring_is_empty(mpmcRing) == true

    lf_mpmc_stream_ring_destroy(mpmcRing)

  test "Atomic Associative Map Operations C ABI":
    var ctrie: ptr lf_ctrie_t = nil
    check lf_ctrie_create(nil, nil, addr ctrie) == LF_OK
    check ctrie != nil

    var outVal: pointer = nil
    var outLen: csize_t = 0

    let mappingCb: lf_mapping_fn = proc(k: pointer, kLen: csize_t, uData: pointer): pointer {.cdecl.} =
      cast[pointer](cast[uint](k) * 10)

    let updateCb: lf_update_fn = proc(oldVal: pointer, oldLen: csize_t, uData: pointer): pointer {.cdecl.} =
      cast[pointer](cast[uint](oldVal) + 1)

    # Ctrie computeIfAbsent
    check lf_ctrie_compute_if_absent(ctrie, cast[pointer](42), 0, mappingCb, nil, addr outVal, addr outLen) == true
    check cast[uint](outVal) == 420
    outVal = nil
    check lf_ctrie_compute_if_absent(ctrie, cast[pointer](42), 0, mappingCb, nil, addr outVal, addr outLen) == true
    check cast[uint](outVal) == 420

    # Ctrie atomicUpdate
    check lf_ctrie_atomic_update(ctrie, cast[pointer](999), 0, updateCb, nil, addr outVal, addr outLen) == false
    check lf_ctrie_atomic_update(ctrie, cast[pointer](42), 0, updateCb, nil, addr outVal, addr outLen) == true
    check cast[uint](outVal) == 421

    check lf_ctrie_destroy(ctrie) == LF_OK

    # SkipListMap / Table
    var table: ptr lf_table_t = nil
    check lf_table_create(nil, nil, addr table) == LF_OK
    check table != nil

    check lf_skiplist_compute_if_absent(table, cast[pointer](55), 0, mappingCb, nil, addr outVal, addr outLen) == true
    check cast[uint](outVal) == 550
    check lf_skiplist_atomic_update(table, cast[pointer](55), 0, updateCb, nil, addr outVal, addr outLen) == true
    check cast[uint](outVal) == 551

    check lf_table_destroy(table) == LF_OK

  test "AtomicArc & ArcGuard C ABI (load, store, swap, compare_exchange & destructor)":
    type ArcAbiTracker = object
      count: int
      sum: int

    proc arcAbiDtor(item: pointer, userData: pointer) {.cdecl, gcsafe, raises: [].} =
      let t = cast[ptr ArcAbiTracker](userData)
      if t != nil:
        inc t.count
        t.sum += cast[int](item)

    var tracker = ArcAbiTracker(count: 0, sum: 0)
    var arc: ptr lf_atomic_arc_t = nil
    check lf_atomic_arc_create(cast[pointer](10), arcAbiDtor, addr tracker, addr arc) == LF_OK
    check arc != nil
    check lf_atomic_arc_is_null(arc) == false

    var g1: ptr lf_arc_guard_t = nil
    check lf_atomic_arc_load(arc, addr g1) == LF_OK
    check g1 != nil
    check cast[int](lf_arc_guard_get(g1)) == 10

    var g1Clone: ptr lf_arc_guard_t = nil
    check lf_arc_guard_clone(g1, addr g1Clone) == LF_OK
    check g1Clone != nil
    check cast[int](lf_arc_guard_get(g1Clone)) == 10

    # Store 20; 10 is kept alive by g1 and g1Clone
    check lf_atomic_arc_store(arc, cast[pointer](20), arcAbiDtor, addr tracker) == LF_OK
    check tracker.count == 0

    check lf_arc_guard_release(g1) == LF_OK
    check tracker.count == 0
    check lf_arc_guard_release(g1Clone) == LF_OK
    check tracker.count == 1
    check tracker.sum == 10

    # Swap 20 -> 30
    var oldG: ptr lf_arc_guard_t = nil
    check lf_atomic_arc_swap(arc, cast[pointer](30), arcAbiDtor, addr tracker, addr oldG) == LF_OK
    check oldG != nil
    check cast[int](lf_arc_guard_get(oldG)) == 20
    check tracker.count == 1
    check lf_arc_guard_release(oldG) == LF_OK
    check tracker.count == 2
    check tracker.sum == 30

    # compare_exchange mismatch updates expected from NULL -> 30
    var expectedG: ptr lf_arc_guard_t = nil
    var swapped: bool = false
    check lf_atomic_arc_compare_exchange(arc, addr expectedG, cast[pointer](40), arcAbiDtor, addr tracker, addr swapped) == LF_OK
    check swapped == false
    check expectedG != nil
    check cast[int](lf_arc_guard_get(expectedG)) == 30
    # Failed desired_item (40) was immediately cleaned up!
    check tracker.count == 3
    check tracker.sum == 70

    # Retry compare_exchange with updated expectedG (30) -> 50 succeeds!
    check lf_atomic_arc_compare_exchange(arc, addr expectedG, cast[pointer](50), arcAbiDtor, addr tracker, addr swapped) == LF_OK
    check swapped == true
    check lf_arc_guard_release(expectedG) == LF_OK
    # 30 is now destroyed!
    check tracker.count == 4
    check tracker.sum == 100

    check lf_atomic_arc_destroy(arc) == LF_OK
    # 50 is now destroyed!
    check tracker.count == 5
    check tracker.sum == 150

  test "Bounded Zero-SMR Primitives C ABI (BStack, BPriorityQueue, BTable)":
    # 1. lf_bstack_*
    var bs: ptr lf_bstack_t = nil
    check lf_bstack_create(0, nil, nil, addr bs) == LF_ERR_INVALID_ARG
    check lf_bstack_create(65537, nil, nil, addr bs) == LF_ERR_UNSUPPORTED
    check lf_bstack_create(4, nil, nil, addr bs) == LF_OK
    check bs != nil
    check lf_bstack_capacity(bs) == 4
    check lf_bstack_is_empty(bs) == true
    check lf_bstack_is_full(bs) == false

    for i in 1 .. 4:
      check lf_bstack_push(bs, cast[pointer](i * 100)) == LF_OK
    check lf_bstack_is_full(bs) == true
    check lf_bstack_push(bs, cast[pointer](500)) == LF_ERR_FULL

    var outItem: pointer = nil
    check lf_bstack_peek(bs, addr outItem) == LF_OK
    check cast[int](outItem) == 400

    # Drain top 2 items (400, 300) via lf_bstack_drain (CRIT-01)
    var drained: array[4, pointer]
    check lf_bstack_drain(nil, addr drained[0], 2) == 0
    check lf_bstack_drain(bs, nil, 2) == 0
    check lf_bstack_drain(bs, addr drained[0], 0) == 0
    check lf_bstack_drain(bs, addr drained[0], 2) == 2
    check cast[int](drained[0]) == 400
    check cast[int](drained[1]) == 300

    for expected in [200, 100]:
      outItem = nil
      check lf_bstack_pop(bs, addr outItem) == LF_OK
      check cast[int](outItem) == expected
    check lf_bstack_pop(bs, addr outItem) == LF_ERR_EMPTY

    # Verify nil / (void*)0 payload push, peek, pop (CRIT-02)
    check lf_bstack_push(bs, nil) == LF_OK
    outItem = cast[pointer](123)
    check lf_bstack_peek(bs, addr outItem) == LF_OK
    check outItem == nil
    outItem = cast[pointer](123)
    check lf_bstack_pop(bs, addr outItem) == LF_OK
    check outItem == nil
    check lf_bstack_destroy(bs) == LF_OK

    # 2. lf_bpqueue_*
    var bpq: ptr lf_bpqueue_t = nil
    check lf_bpqueue_create(0, nil, nil, addr bpq) == LF_ERR_INVALID_ARG
    check lf_bpqueue_create(65537, nil, nil, addr bpq) == LF_ERR_UNSUPPORTED
    check lf_bpqueue_create(4, nil, nil, addr bpq) == LF_OK
    check bpq != nil
    check lf_bpqueue_capacity(bpq) == 4

    check lf_bpqueue_push(bpq, 30, cast[pointer](300)) == LF_OK
    check lf_bpqueue_push(bpq, 10, cast[pointer](100)) == LF_OK
    check lf_bpqueue_push(bpq, 20, cast[pointer](201)) == LF_OK
    check lf_bpqueue_push(bpq, 20, cast[pointer](202)) == LF_OK
    check lf_bpqueue_push(bpq, 5, cast[pointer](50)) == LF_ERR_FULL

    var outPrio: int64 = 0
    check lf_bpqueue_peek_min(bpq, addr outPrio, addr outItem) == LF_OK
    check outPrio == 10
    check cast[int](outItem) == 100

    for (ep, ev) in [(10'i64, 100), (20'i64, 201), (20'i64, 202), (30'i64, 300)]:
      check lf_bpqueue_pop_min(bpq, addr outPrio, addr outItem) == LF_OK
      check outPrio == ep
      check cast[int](outItem) == ev
    check lf_bpqueue_pop_min(bpq, addr outPrio, addr outItem) == LF_ERR_EMPTY
    check lf_bpqueue_destroy(bpq) == LF_OK

    # 3. lf_btable_*
    var bt: ptr lf_btable_t = nil
    check lf_btable_create(0, nil, nil, addr bt) == LF_ERR_INVALID_ARG
    check lf_btable_create(65537, nil, nil, addr bt) == LF_ERR_UNSUPPORTED
    check lf_btable_create(4, nil, nil, addr bt) == LF_OK
    check bt != nil
    check lf_btable_capacity(bt) == 4

    # Verify nil / (void*)0 values in compute_if_absent, atomic_update, upsert, and take (CRIT-02)
    let zeroMapCb: lf_btable_mapping_fn = proc(k: pointer, ud: pointer): pointer {.cdecl, gcsafe.} = nil
    let zeroUpdCb: lf_btable_update_fn = proc(k: pointer, oldVal: pointer, ud: pointer): pointer {.cdecl, gcsafe.} = nil
    outItem = cast[pointer](999)
    check lf_btable_compute_if_absent(bt, nil, zeroMapCb, nil, addr outItem) == LF_OK
    check outItem == nil
    outItem = cast[pointer](999)
    check lf_btable_atomic_update(bt, nil, zeroUpdCb, nil, addr outItem) == LF_OK
    check outItem == nil
    outItem = cast[pointer](999)
    check lf_btable_take(bt, nil, addr outItem) == LF_OK
    check outItem == nil
    outItem = cast[pointer](999)
    check lf_btable_upsert(bt, nil, nil, zeroUpdCb, nil, addr outItem) == LF_OK
    check outItem == nil
    check lf_btable_take(bt, nil, addr outItem) == LF_OK
    check outItem == nil

    var inserted = false
    for k in 1 .. 4:
      check lf_btable_put(bt, cast[pointer](k), cast[pointer](k * 10), addr inserted) == LF_OK
      check inserted == true
    check lf_btable_is_full(bt) == true
    check lf_btable_put(bt, cast[pointer](5), cast[pointer](50), addr inserted) == LF_ERR_FULL
    check inserted == false

    # Update existing key at full capacity
    check lf_btable_put(bt, cast[pointer](2), cast[pointer](222), addr inserted) == LF_OK
    check inserted == false
    check lf_btable_get(bt, cast[pointer](2), addr outItem) == LF_OK
    check cast[int](outItem) == 222

    var removed = false
    check lf_btable_remove(bt, cast[pointer](2), addr removed) == LF_OK
    check removed == true
    check lf_btable_contains(bt, cast[pointer](2)) == false
    check lf_btable_destroy(bt) == LF_OK

    # 4. lf_bqueue128_*
    var bq: ptr lf_bqueue128_t = nil
    check lf_bqueue128_create(0, nil, nil, addr bq) == LF_ERR_INVALID_ARG
    check lf_bqueue128_create(65537, nil, nil, addr bq) == LF_ERR_UNSUPPORTED
    check lf_bqueue128_create(4, nil, nil, addr bq) == LF_OK
    check bq != nil
    check lf_bqueue128_capacity(bq) == 4
    check lf_bqueue128_is_empty(bq) == true
    check lf_bqueue128_is_full(bq) == false
    check lf_bqueue128_len(bq) == 0

    for i in 1 .. 4:
      check lf_bqueue128_push(bq, cast[pointer](i * 111)) == LF_OK
    check lf_bqueue128_is_full(bq) == true
    check lf_bqueue128_push(bq, cast[pointer](999)) == LF_ERR_FULL

    var bqItem: pointer = nil
    check lf_bqueue128_peek(bq, addr bqItem) == LF_OK
    check cast[int](bqItem) == 111

    for i in 1 .. 4:
      check lf_bqueue128_pop(bq, addr bqItem) == LF_OK
      check cast[int](bqItem) == i * 111
    check lf_bqueue128_pop(bq, addr bqItem) == LF_ERR_EMPTY
    check lf_bqueue128_is_empty(bq) == true

    # Push and clear test
    check lf_bqueue128_push(bq, cast[pointer](777)) == LF_OK
    check lf_bqueue128_clear(bq) == LF_OK
    check lf_bqueue128_is_empty(bq) == true
    check lf_bqueue128_destroy(bq) == LF_OK


  test "Backward compatibility aliases (lfq_* and LFQ_*)":
    # 1. Status enum and macros
    var st: lfq_status_t = LFQ_OK
    check st == LF_OK
    check LFQ_ERR_EMPTY == LF_ERR_EMPTY
    check LFQ_ERR_FULL == LF_ERR_FULL
    check LFQ_ERR_CLOSED == LF_ERR_CLOSED
    check LFQ_ERR_INVALID_ARG == LF_ERR_INVALID_ARG
    check LFQ_ERR_REGISTRY_FULL == LF_ERR_REGISTRY_FULL
    check LFQ_ERR_UNSUPPORTED == LF_ERR_UNSUPPORTED
    check LFQ_ERR_FAILURE == LF_ERR_FAILURE
    check LFQ_ERR_PANIC == LF_ERR_PANIC

    # 2. Bounded queue legacy API
    var q: ptr lfq_queue_t = nil
    check lfq_bounded_mpmc_create(8, 2, 2, nil, nil, addr q) == LFQ_OK
    check lfq_queue_is_empty(q) == true
    check lfq_queue_len(q) == 0
    var prod: ptr lfq_producer_t = nil
    var cons: ptr lfq_consumer_t = nil
    check lfq_producer_acquire(q, addr prod) == LFQ_OK
    check lfq_consumer_acquire(q, addr cons) == LFQ_OK
    check lfq_push(prod, cast[pointer](123)) == LFQ_OK
    check lfq_queue_len(q) == 1
    var item: pointer = nil
    check lfq_pop(cons, addr item) == LFQ_OK
    check cast[int](item) == 123
    check lfq_pop(cons, addr item) == LFQ_ERR_EMPTY
    check lfq_producer_release(prod) == LFQ_OK
    check lfq_consumer_release(cons) == LFQ_OK
    check lfq_queue_destroy(q) == LFQ_OK

    # 3. Stack legacy API
    var stk: ptr lfq_stack_t = nil
    check lfq_stack_create(nil, nil, addr stk) == LFQ_OK
    check lfq_stack_push(stk, cast[pointer](456)) == LFQ_OK
    check lfq_stack_len(stk) == 1
    check lfq_stack_peek(stk, addr item) == LFQ_OK
    check cast[int](item) == 456
    check lfq_stack_pop(stk, addr item) == LFQ_OK
    check cast[int](item) == 456
    check lfq_stack_destroy(stk) == LFQ_OK

    # 4. Deque legacy API
    var dq: ptr lfq_deque_t = nil
    check lfq_deque_create(8, nil, nil, addr dq) == LFQ_OK
    check lfq_deque_push(dq, cast[pointer](789)) == LFQ_OK
    check lfq_deque_pop(dq, addr item) == LFQ_OK
    check cast[int](item) == 789
    check lfq_deque_destroy(dq) == LFQ_OK

    # 5. Table and Set legacy API
    var tbl: ptr lfq_table_t = nil
    check lfq_table_create(nil, nil, addr tbl) == LFQ_OK
    var ins = false
    check lfq_table_put(tbl, cast[pointer](1), cast[pointer](10), addr ins) == LFQ_OK
    check lfq_table_get(tbl, cast[pointer](1), addr item) == LFQ_OK
    check cast[int](item) == 10
    check lfq_table_destroy(tbl) == LFQ_OK

    var stSet: ptr lfq_set_t = nil
    check lfq_set_create(nil, nil, addr stSet) == LFQ_OK
    check lfq_set_insert(stSet, cast[pointer](1), addr ins) == LFQ_OK
    check lfq_set_contains(stSet, cast[pointer](1)) == true
    check lfq_set_destroy(stSet) == LFQ_OK

    # 6. CTrie legacy API
    var ct: ptr lfq_ctrie_t = nil
    check lfq_ctrie_create(nil, nil, addr ct) == LFQ_OK
    check lfq_ctrie_insert(ct, cast[pointer](1), cast[pointer](100), addr ins) == LFQ_OK
    check lfq_ctrie_lookup(ct, cast[pointer](1), addr item) == LFQ_OK
    check cast[int](item) == 100
    check lfq_ctrie_destroy(ct) == LFQ_OK

    # 7. Broadcast legacy API
    var bc: ptr lfq_broadcast_t = nil
    check lfq_broadcast_create(16, LFQ_OVERFLOW_DROP_OLDEST, 4, addr bc) == LFQ_OK
    check lfq_broadcast_publish(bc, cast[pointer](11)) == LFQ_OK
    check lfq_broadcast_destroy(bc) == LFQ_OK

    # 8. Rendezvous legacy API
    var rz: ptr lfq_rendezvous_t = nil
    check lfq_rendezvous_create(addr rz) == LFQ_OK
    check lfq_rendezvous_try_recv(rz, addr item, nil) == LFQ_ERR_EMPTY
    check lfq_rendezvous_destroy(rz) == LFQ_OK

    # 9. Token & Leaky Bucket legacy API
    let heapTb = lfq_token_bucket_create(50, 10)
    check heapTb != nil
    check lfq_token_bucket_try_acquire(heapTb, 25) == true
    lfq_token_bucket_destroy(heapTb)

    let heapLb = lfq_leaky_bucket_create(200_000_000, 50)
    check heapLb != nil
    check lfq_leaky_bucket_try_consume(heapLb, 1) == true
    lfq_leaky_bucket_destroy(heapLb)

    # 10. Streambuffer legacy API
    let sb = lfq_streambuffer_create(64, false)
    check sb != nil
    lfq_streambuffer_destroy(sb)

    # 11. Atomic Arc legacy API
    var arc: ptr lfq_atomic_arc_t = nil
    check lfq_atomic_arc_create(cast[pointer](42), nil, nil, addr arc) == LFQ_OK
    var grd: ptr lfq_arc_guard_t = nil
    check lfq_atomic_arc_load(arc, addr grd) == LFQ_OK
    check cast[int](lfq_arc_guard_get(grd)) == 42
    check lfq_arc_guard_release(grd) == LFQ_OK
    check lfq_atomic_arc_destroy(arc) == LFQ_OK

    # 12. BStack, BPQueue, BTable legacy API
    var bstk: ptr lfq_bstack_t = nil
    check lfq_bstack_create(8, nil, nil, addr bstk) == LFQ_OK
    check lfq_bstack_push(bstk, cast[pointer](99)) == LFQ_OK
    check lfq_bstack_pop(bstk, addr item) == LFQ_OK
    check cast[int](item) == 99
    check lfq_bstack_destroy(bstk) == LFQ_OK

    var bpq: ptr lfq_bpqueue_t = nil
    check lfq_bpqueue_create(8, nil, nil, addr bpq) == LFQ_OK
    check lfq_bpqueue_push(bpq, 10, cast[pointer](88)) == LFQ_OK
    var prio: int64 = 0
    check lfq_bpqueue_pop_min(bpq, addr prio, addr item) == LFQ_OK
    check prio == 10 and cast[int](item) == 88
    check lfq_bpqueue_destroy(bpq) == LFQ_OK

    var btbl: ptr lfq_btable_t = nil
    check lfq_btable_create(8, nil, nil, addr btbl) == LFQ_OK
    check lfq_btable_put(btbl, cast[pointer](5), cast[pointer](50), addr ins) == LFQ_OK
    check lfq_btable_get(btbl, cast[pointer](5), addr item) == LFQ_OK
    check cast[int](item) == 50
    check lfq_btable_destroy(btbl) == LFQ_OK

    var lbq: ptr lfq_bqueue128_t = nil
    check lfq_bqueue128_create(8, nil, nil, addr lbq) == LFQ_OK
    check lfq_bqueue128_push(lbq, cast[pointer](55)) == LFQ_OK
    check lfq_bqueue128_pop(lbq, addr item) == LFQ_OK
    check cast[int](item) == 55
    check lfq_bqueue128_destroy(lbq) == LFQ_OK

  when not defined(windows):
    test "Direct C99 Header Interoperability":
      let code1 = execShellCmd("clang -fsyntax-only -std=c99 -Wall -Wextra -Werror -pedantic -Wstrict-prototypes -I" & includeDir & " " & (includeDir / "lockfree.h"))
      check code1 == 0
      let code2 = execShellCmd("clang -fsyntax-only -std=c99 -Wall -Wextra -Werror -pedantic -Wstrict-prototypes -I" & includeDir & " " & (includeDir / "lockfree_rendezvous.h"))
      check code2 == 0
      let code3 = execShellCmd("clang -fsyntax-only -std=c99 -Wall -Wextra -Werror -pedantic -Wstrict-prototypes -I" & includeDir & " " & (includeDir / "lockfree_ratelimit.h"))
      check code3 == 0
      let code4 = execShellCmd("clang -fsyntax-only -std=c99 -Wall -Wextra -Werror -pedantic -Wstrict-prototypes -I" & includeDir & " " & (includeDir / "lockfree_streambuffer.h"))
      check code4 == 0
      let code5 = execShellCmd("clang -fsyntax-only -std=c99 -Wall -Wextra -Werror -pedantic -Wstrict-prototypes -I" & includeDir & " " & (includeDir / "lockfree_associative.h"))
      check code5 == 0
      let code6 = execShellCmd("clang -fsyntax-only -std=c99 -Wall -Wextra -Werror -pedantic -Wstrict-prototypes -I" & includeDir & " " & (includeDir / "lockfree_atomic_arc.h"))
      check code6 == 0
      let code7 = execShellCmd("clang -fsyntax-only -std=c99 -Wall -Wextra -Werror -pedantic -Wstrict-prototypes -I" & includeDir & " " & (includeDir / "lockfree_bstack.h"))
      check code7 == 0
      let code8 = execShellCmd("clang -fsyntax-only -std=c99 -Wall -Wextra -Werror -pedantic -Wstrict-prototypes -I" & includeDir & " " & (includeDir / "lockfree_bpqueue.h"))
      check code8 == 0
      let code9 = execShellCmd("clang -fsyntax-only -std=c99 -Wall -Wextra -Werror -pedantic -Wstrict-prototypes -I" & includeDir & " " & (includeDir / "lockfree_btable.h"))
      check code9 == 0
      let code10 = execShellCmd("clang -fsyntax-only -std=c99 -Wall -Wextra -Werror -pedantic -Wstrict-prototypes -I" & includeDir & " " & (includeDir / "lockfree_bqueue128.h"))
      check code10 == 0

    test "Compiled C99 test harness execution (clang + liblockfree.a)":
      let rootDir = currentSourcePath().parentDir() / ".."
      let staticLib = rootDir / ".tmp/liblockfree.a"
      let buildCode = execShellCmd(
        "nim c --app:staticlib --hints:off --warnings:off -d:release --opt:speed -d:useMalloc --threads:on --path:" &
        (rootDir / "src") & " --nimcache:" & (rootDir / ".tmp/cabi_staticlib_cache") &
        " -o:" & staticLib & " " & (rootDir / "src/lockfree/cabi.nim")
      )
      check buildCode == 0
      let cTestSrc = rootDir / "tests/cabi/test_cabi.c"
      let cTestBin = rootDir / ".tmp/test_cabi"
      let compileCmd = "clang -std=c99 -D_POSIX_C_SOURCE=199309L -Wall -Wextra -Werror -I" & includeDir & " " & cTestSrc & " -L" & (rootDir / ".tmp") & " -llockfree -o " & cTestBin
      let compCode = execShellCmd(compileCmd)
      check compCode == 0
      let runCode = execShellCmd(cTestBin)
      check runCode == 0
