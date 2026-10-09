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
const includeDir = currentSourcePath().parentDir() / "../include"
{.passC: "-I" & includeDir.}

type
  ThreadProducerArg = object
    queue: ptr lfq_queue_t
    items: int

  ThreadConsumerArg = object
    queue: ptr lfq_queue_t
    targetTotal: int
    totalPopped: ptr Atomic[int]

proc threadProducerWorker(arg: ptr ThreadProducerArg) {.thread.} =
  var prod: ptr lfq_producer_t = nil
  if lfq_producer_acquire(arg.queue, addr prod) == LFQ_OK:
    for i in 1 .. arg.items:
      while lfq_push(prod, cast[pointer](i)) == LFQ_ERR_FULL:
        cpuPause()
    discard lfq_producer_release(prod)

proc threadConsumerWorker(arg: ptr ThreadConsumerArg) {.thread.} =
  var cons: ptr lfq_consumer_t = nil
  if lfq_consumer_acquire(arg.queue, addr cons) == LFQ_OK:
    var item: pointer = nil
    while arg.totalPopped[].load(moRelaxed) < arg.targetTotal:
      if lfq_pop(cons, addr item) == LFQ_OK:
        discard arg.totalPopped[].fetchAdd(1, moRelaxed)
      else:
        cpuPause()
    discard lfq_consumer_release(cons)

type
  UniqueProducerArg = object
    queue: ptr lfq_queue_t
    startVal: int
    count: int

  UniqueConsumerArg = object
    queue: ptr lfq_queue_t
    targetTotal: int
    totalPopped: ptr Atomic[int]
    checksum: ptr Atomic[uint64]
    seenArray: ptr UncheckedArray[Atomic[uint8]]

proc uniqueProducerWorker(arg: ptr UniqueProducerArg) {.thread.} =
  var prod: ptr lfq_producer_t = nil
  if lfq_producer_acquire(arg.queue, addr prod) == LFQ_OK:
    for i in 0 ..< arg.count:
      let itemVal = arg.startVal + i
      while lfq_push(prod, cast[pointer](itemVal)) == LFQ_ERR_FULL:
        cpuPause()
    discard lfq_producer_release(prod)

proc uniqueConsumerWorker(arg: ptr UniqueConsumerArg) {.thread.} =
  var cons: ptr lfq_consumer_t = nil
  if lfq_consumer_acquire(arg.queue, addr cons) == LFQ_OK:
    var item: pointer = nil
    while arg.totalPopped[].load(moRelaxed) < arg.targetTotal:
      if lfq_pop(cons, addr item) == LFQ_OK:
        let val = cast[int](item)
        discard arg.totalPopped[].fetchAdd(1, moRelaxed)
        discard arg.checksum[].fetchAdd(uint64(val), moRelaxed)
        if arg.seenArray != nil:
          let prev = arg.seenArray[val].exchange(1'u8, moRelaxed)
          doAssert prev == 0'u8, "Duplicate item detected in C ABI consumer pop: " & $val
      else:
        cpuPause()
    discard lfq_consumer_release(cons)

suite "lockfree C ABI Specification & Cross-Language Interop":

  test "Bounded MPMC lifecycle & FIFO ordering":
    var queue: ptr lfq_queue_t = nil
    check lfq_bounded_mpmc_create(8, 2, 2, nil, nil, addr queue) == LFQ_OK
    check queue != nil
    check lfq_queue_is_empty(queue) == true
    check lfq_queue_len(queue) == 0

    var prod: ptr lfq_producer_t = nil
    var cons: ptr lfq_consumer_t = nil
    check lfq_producer_acquire(queue, addr prod) == LFQ_OK
    check lfq_consumer_acquire(queue, addr cons) == LFQ_OK
    check prod != nil
    check cons != nil

    # Push 3 items
    check lfq_push(prod, cast[pointer](101)) == LFQ_OK
    check lfq_push(prod, cast[pointer](102)) == LFQ_OK
    check lfq_push(prod, cast[pointer](103)) == LFQ_OK

    check lfq_queue_is_empty(queue) == false
    check lfq_queue_len(queue) == 3

    # Pop items and verify FIFO
    var item: pointer = nil
    check lfq_pop(cons, addr item) == LFQ_OK
    check cast[int](item) == 101

    check lfq_pop(cons, addr item) == LFQ_OK
    check cast[int](item) == 102

    check lfq_pop(cons, addr item) == LFQ_OK
    check cast[int](item) == 103

    # Empty pop
    check lfq_pop(cons, addr item) == LFQ_ERR_EMPTY
    check lfq_queue_is_empty(queue) == true

    check lfq_producer_release(prod) == LFQ_OK
    check lfq_consumer_release(cons) == LFQ_OK
    check lfq_queue_destroy(queue) == LFQ_OK

  test "Bounded MPMC full capacity handling":
    var queue: ptr lfq_queue_t = nil
    check lfq_bounded_mpmc_create(4, 2, 2, nil, nil, addr queue) == LFQ_OK

    var prod: ptr lfq_producer_t = nil
    var cons: ptr lfq_consumer_t = nil
    check lfq_producer_acquire(queue, addr prod) == LFQ_OK
    check lfq_consumer_acquire(queue, addr cons) == LFQ_OK

    for i in 1 .. 4:
      check lfq_push(prod, cast[pointer](i)) == LFQ_OK

    # 5th push must return LFQ_ERR_FULL
    check lfq_push(prod, cast[pointer](5)) == LFQ_ERR_FULL

    # Pop 1 item
    var item: pointer = nil
    check lfq_pop(cons, addr item) == LFQ_OK
    check cast[int](item) == 1

    # Now push should succeed
    check lfq_push(prod, cast[pointer](5)) == LFQ_OK

    # Drain remaining
    var count = 0
    while lfq_pop(cons, addr item) == LFQ_OK:
      inc count
    check count == 4

    check lfq_producer_release(prod) == LFQ_OK
    check lfq_consumer_release(cons) == LFQ_OK
    check lfq_queue_destroy(queue) == LFQ_OK

  test "Unbounded MPMC lifecycle and segment growth":
    var queue: ptr lfq_queue_t = nil
    check lfq_unbounded_mpmc_create(16, 4, nil, nil, addr queue) == LFQ_OK
    check queue != nil
    check lfq_queue_is_empty(queue) == true

    var prod: ptr lfq_producer_t = nil
    var cons: ptr lfq_consumer_t = nil
    check lfq_producer_acquire(queue, addr prod) == LFQ_OK
    check lfq_consumer_acquire(queue, addr cons) == LFQ_OK

    # Push 100 items (spanning across multiple segments of size 16)
    for i in 1 .. 100:
      check lfq_push(prod, cast[pointer](i)) == LFQ_OK

    check lfq_queue_len(queue) == 100
    check lfq_queue_is_empty(queue) == false

    # Pop 100 items and verify FIFO order
    var item: pointer = nil
    for i in 1 .. 100:
      check lfq_pop(cons, addr item) == LFQ_OK
      check cast[int](item) == i

    # Next pop should be empty
    check lfq_pop(cons, addr item) == LFQ_ERR_EMPTY

    check lfq_producer_release(prod) == LFQ_OK
    check lfq_consumer_release(cons) == LFQ_OK
    check lfq_queue_destroy(queue) == LFQ_OK

  test "Batch pop operations (lfq_pop_batch)":
    var queue: ptr lfq_queue_t = nil
    check lfq_bounded_mpmc_create(16, 2, 2, nil, nil, addr queue) == LFQ_OK

    var prod: ptr lfq_producer_t = nil
    var cons: ptr lfq_consumer_t = nil
    check lfq_producer_acquire(queue, addr prod) == LFQ_OK
    check lfq_consumer_acquire(queue, addr cons) == LFQ_OK

    for i in 1 .. 10:
      check lfq_push(prod, cast[pointer](i)) == LFQ_OK

    var buffer: array[10, pointer]
    let popped1 = lfq_pop_batch(cons, addr buffer[0], 4)
    check popped1 == 4
    for i in 0 ..< 4:
      check cast[int](buffer[i]) == i + 1

    let popped2 = lfq_pop_batch(cons, addr buffer[0], 10)
    check popped2 == 6 # only 6 remaining
    for i in 0 ..< 6:
      check cast[int](buffer[i]) == i + 5

    let poppedEmpty = lfq_pop_batch(cons, addr buffer[0], 5)
    check poppedEmpty == 0

    check lfq_producer_release(prod) == LFQ_OK
    check lfq_consumer_release(cons) == LFQ_OK
    check lfq_queue_destroy(queue) == LFQ_OK

  var destroyedCount = 0
  proc testItemDestructor(item: pointer, userData: pointer) {.cdecl, gcsafe.} =
    let pCount = cast[ptr int](userData)
    pCount[] += 1
    discard item

  test "Item destructor callback on queue teardown":
    destroyedCount = 0
    var queue: ptr lfq_queue_t = nil
    check lfq_bounded_mpmc_create(8, 2, 2, testItemDestructor, addr destroyedCount, addr queue) == LFQ_OK

    var prod: ptr lfq_producer_t = nil
    var cons: ptr lfq_consumer_t = nil
    check lfq_producer_acquire(queue, addr prod) == LFQ_OK
    check lfq_consumer_acquire(queue, addr cons) == LFQ_OK

    # Push 5 items
    for i in 1 .. 5:
      check lfq_push(prod, cast[pointer](i)) == LFQ_OK

    # Pop 2 items
    var item: pointer = nil
    check lfq_pop(cons, addr item) == LFQ_OK
    check lfq_pop(cons, addr item) == LFQ_OK

    # 3 items remain in queue
    check lfq_producer_release(prod) == LFQ_OK
    check lfq_consumer_release(cons) == LFQ_OK

    # Destroy queue - unpopped items must be cleaned up via destructor callback
    check lfq_queue_destroy(queue) == LFQ_OK
    check destroyedCount == 3

  test "Registry limits and recycling after release":
    var queue: ptr lfq_queue_t = nil
    check lfq_bounded_mpmc_create(8, 2, 1, nil, nil, addr queue) == LFQ_OK

    var p1, p2, p3: ptr lfq_producer_t = nil
    var c1, c2: ptr lfq_consumer_t = nil

    check lfq_producer_acquire(queue, addr p1) == LFQ_OK
    check lfq_producer_acquire(queue, addr p2) == LFQ_OK
    # 3rd producer should fail with REGISTRY_FULL
    check lfq_producer_acquire(queue, addr p3) == LFQ_ERR_REGISTRY_FULL
    check p3 == nil

    # Consumer limit is 1
    check lfq_consumer_acquire(queue, addr c1) == LFQ_OK
    check lfq_consumer_acquire(queue, addr c2) == LFQ_ERR_REGISTRY_FULL
    check c2 == nil

    # Release p1 -> p3 should now succeed
    check lfq_producer_release(p1) == LFQ_OK
    check lfq_producer_acquire(queue, addr p3) == LFQ_OK
    check p3 != nil

    check lfq_producer_release(p2) == LFQ_OK
    check lfq_producer_release(p3) == LFQ_OK
    check lfq_consumer_release(c1) == LFQ_OK
    check lfq_queue_destroy(queue) == LFQ_OK

  test "Invalid argument validation":
    var queue: ptr lfq_queue_t = nil
    check lfq_bounded_mpmc_create(0, 1, 1, nil, nil, addr queue) == LFQ_ERR_INVALID_ARG
    check lfq_bounded_mpmc_create(8, 1, 1, nil, nil, nil) == LFQ_ERR_INVALID_ARG
    check lfq_unbounded_mpmc_create(16, 4, nil, nil, nil) == LFQ_ERR_INVALID_ARG
    check lfq_queue_destroy(nil) == LFQ_ERR_INVALID_ARG

    var prod: ptr lfq_producer_t = nil
    check lfq_producer_acquire(nil, addr prod) == LFQ_ERR_INVALID_ARG
    check lfq_producer_release(nil) == LFQ_ERR_INVALID_ARG
    check lfq_push(nil, cast[pointer](1)) == LFQ_ERR_INVALID_ARG

    var item: pointer = nil
    check lfq_pop(nil, addr item) == LFQ_ERR_INVALID_ARG
    var cons: ptr lfq_consumer_t = nil
    check lfq_consumer_release(cons) == LFQ_ERR_INVALID_ARG
    check lfq_pop_batch(nil, addr item, 5) == 0
    check lfq_queue_len(nil) == 0
    check lfq_queue_is_empty(nil) == true

  test "Multithreaded concurrent producer/consumer":
    var queue: ptr lfq_queue_t = nil
    check lfq_unbounded_mpmc_create(32, 8, nil, nil, addr queue) == LFQ_OK

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
    check lfq_queue_destroy(queue) == LFQ_OK

  test "C ABI Bounded MPMC 4P/4C 100k items stress":
    var queue: ptr lfq_queue_t = nil
    check lfq_bounded_mpmc_create(1024, 4, 4, nil, nil, addr queue) == LFQ_OK

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
    check lfq_queue_destroy(queue) == LFQ_OK

  test "C ABI Unbounded MPMC 4P/4C 100k items stress":
    var queue: ptr lfq_queue_t = nil
    check lfq_unbounded_mpmc_create(64, 16, nil, nil, addr queue) == LFQ_OK

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
    check lfq_queue_destroy(queue) == LFQ_OK

  test "AUDIT-CABI-01: Multiple queue handles on single thread without NEBR panic":
    var q1, q2: ptr lfq_queue_t = nil
    check lfq_unbounded_mpmc_create(16, 4, nil, nil, addr q1) == LFQ_OK
    check lfq_unbounded_mpmc_create(16, 4, nil, nil, addr q2) == LFQ_OK

    var p1, p2: ptr lfq_producer_t = nil
    var c1, c2: ptr lfq_consumer_t = nil

    check lfq_producer_acquire(q1, addr p1) == LFQ_OK
    check lfq_producer_acquire(q2, addr p2) == LFQ_OK
    check lfq_consumer_acquire(q1, addr c1) == LFQ_OK
    check lfq_consumer_acquire(q2, addr c2) == LFQ_OK

    check lfq_push(p1, cast[pointer](111)) == LFQ_OK
    check lfq_push(p2, cast[pointer](222)) == LFQ_OK

    var item: pointer = nil
    check lfq_pop(c1, addr item) == LFQ_OK
    check cast[int](item) == 111
    check lfq_pop(c2, addr item) == LFQ_OK
    check cast[int](item) == 222

    # Release across different queues without NEBR threadvar assertion panic
    check lfq_producer_release(p1) == LFQ_OK
    check lfq_consumer_release(c1) == LFQ_OK
    check lfq_producer_release(p2) == LFQ_OK
    check lfq_consumer_release(c2) == LFQ_OK

    check lfq_queue_destroy(q1) == LFQ_OK
    check lfq_queue_destroy(q2) == LFQ_OK

  test "HIGH-CABI-02: Queue destruction rejected when endpoints active":
    var queue: ptr lfq_queue_t = nil
    check lfq_bounded_mpmc_create(8, 2, 2, nil, nil, addr queue) == LFQ_OK

    var prod: ptr lfq_producer_t = nil
    check lfq_producer_acquire(queue, addr prod) == LFQ_OK

    # Cannot destroy while producer is active
    check lfq_queue_destroy(queue) == LFQ_ERR_FAILURE

    check lfq_producer_release(prod) == LFQ_OK

    var cons: ptr lfq_consumer_t = nil
    check lfq_consumer_acquire(queue, addr cons) == LFQ_OK

    # Cannot destroy while consumer is active
    check lfq_queue_destroy(queue) == LFQ_ERR_FAILURE

    check lfq_consumer_release(cons) == LFQ_OK

    # Now destruction succeeds
    check lfq_queue_destroy(queue) == LFQ_OK

  test "AUDIT-CABI-03: Queue close semantics and drain":
    var queue: ptr lfq_queue_t = nil
    check lfq_bounded_mpmc_create(8, 2, 2, nil, nil, addr queue) == LFQ_OK
    check lfq_queue_is_closed(queue) == false

    var prod: ptr lfq_producer_t = nil
    var cons: ptr lfq_consumer_t = nil
    check lfq_producer_acquire(queue, addr prod) == LFQ_OK
    check lfq_consumer_acquire(queue, addr cons) == LFQ_OK

    check lfq_push(prod, cast[pointer](10)) == LFQ_OK
    check lfq_push(prod, cast[pointer](20)) == LFQ_OK
    check lfq_push(prod, cast[pointer](30)) == LFQ_OK

    # Close queue
    check lfq_queue_close(queue) == LFQ_OK
    check lfq_queue_is_closed(queue) == true

    # Subsequent push must fail with LFQ_ERR_CLOSED
    check lfq_push(prod, cast[pointer](40)) == LFQ_ERR_CLOSED

    # Acquiring new producer must fail with LFQ_ERR_CLOSED
    var p2: ptr lfq_producer_t = nil
    check lfq_producer_acquire(queue, addr p2) == LFQ_ERR_CLOSED
    check p2 == nil

    # Consumer drains remaining items
    var item: pointer = nil
    check lfq_pop(cons, addr item) == LFQ_OK
    check cast[int](item) == 10
    check lfq_pop(cons, addr item) == LFQ_OK
    check cast[int](item) == 20
    check lfq_pop(cons, addr item) == LFQ_OK
    check cast[int](item) == 30

    # Once drained, pop returns LFQ_ERR_EMPTY
    check lfq_pop(cons, addr item) == LFQ_ERR_EMPTY

    check lfq_producer_release(prod) == LFQ_OK
    check lfq_consumer_release(cons) == LFQ_OK
    check lfq_queue_destroy(queue) == LFQ_OK

  test "AUDIT-CABI-03: Multithreaded concurrent with payload uniqueness & checksum":
    var queue: ptr lfq_queue_t = nil
    check lfq_unbounded_mpmc_create(64, 16, nil, nil, addr queue) == LFQ_OK

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

    check lfq_queue_destroy(queue) == LFQ_OK

  test "Treiber Stack lifecycle & LIFO ordering":
    var stack: ptr lfq_stack_t = nil
    check lfq_stack_create(nil, nil, addr stack) == LFQ_OK
    check stack != nil
    check lfq_stack_is_empty(stack) == true
    check lfq_stack_len(stack) == 0

    var item: pointer = nil
    check lfq_stack_pop(stack, addr item) == LFQ_ERR_EMPTY
    check lfq_stack_peek(stack, addr item) == LFQ_ERR_EMPTY

    # Push 3 items: 10, 20, 30
    check lfq_stack_push(stack, cast[pointer](10)) == LFQ_OK
    check lfq_stack_push(stack, cast[pointer](20)) == LFQ_OK
    check lfq_stack_push(stack, cast[pointer](30)) == LFQ_OK

    check lfq_stack_is_empty(stack) == false
    check lfq_stack_len(stack) == 3

    # Peek top item -> 30
    check lfq_stack_peek(stack, addr item) == LFQ_OK
    check cast[int](item) == 30
    check lfq_stack_len(stack) == 3

    # Pop LIFO order: 30, 20, 10
    check lfq_stack_pop(stack, addr item) == LFQ_OK
    check cast[int](item) == 30

    check lfq_stack_pop(stack, addr item) == LFQ_OK
    check cast[int](item) == 20

    check lfq_stack_pop(stack, addr item) == LFQ_OK
    check cast[int](item) == 10

    check lfq_stack_is_empty(stack) == true
    check lfq_stack_pop(stack, addr item) == LFQ_ERR_EMPTY
    check lfq_stack_destroy(stack) == LFQ_OK

  test "Treiber Stack drain operations":
    var stack: ptr lfq_stack_t = nil
    check lfq_stack_create(nil, nil, addr stack) == LFQ_OK

    for i in 1 .. 5:
      check lfq_stack_push(stack, cast[pointer](i * 10)) == LFQ_OK

    check lfq_stack_len(stack) == 5

    var drained: array[8, pointer]
    let count1 = lfq_stack_drain(stack, cast[ptr pointer](addr drained[0]), 3)
    check count1 == 3
    check cast[int](drained[0]) == 50
    check cast[int](drained[1]) == 40
    check cast[int](drained[2]) == 30

    let count2 = lfq_stack_drain(stack, cast[ptr pointer](addr drained[0]), 5)
    check count2 == 2
    check cast[int](drained[0]) == 20
    check cast[int](drained[1]) == 10

    check lfq_stack_is_empty(stack) == true
    check lfq_stack_destroy(stack) == LFQ_OK

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
    var stack: ptr lfq_stack_t = nil
    check lfq_stack_create(stackDestructor, addr tracker, addr stack) == LFQ_OK

    check lfq_stack_push(stack, cast[pointer](11)) == LFQ_OK
    check lfq_stack_push(stack, cast[pointer](22)) == LFQ_OK
    check lfq_stack_push(stack, cast[pointer](33)) == LFQ_OK

    var item: pointer = nil
    check lfq_stack_pop(stack, addr item) == LFQ_OK
    check cast[int](item) == 33

    check lfq_stack_destroy(stack) == LFQ_OK
    check tracker.count == 2
    check tracker.sum == (11 + 22)

  test "Chase-Lev Deque worker push/pop (LIFO) & thief steal (FIFO)":
    var deque: ptr lfq_deque_t = nil
    check lfq_deque_create(32, nil, nil, addr deque) == LFQ_OK
    check deque != nil
    check lfq_deque_is_empty(deque) == true
    check lfq_deque_len(deque) == 0
    check lfq_deque_capacity(deque) >= 32

    var item: pointer = nil
    check lfq_deque_pop(deque, addr item) == LFQ_ERR_EMPTY
    check lfq_deque_steal(deque, addr item) == LFQ_ERR_EMPTY

    # Worker pushes 4 items: 100, 200, 300, 400
    check lfq_deque_push(deque, cast[pointer](100)) == LFQ_OK
    check lfq_deque_push(deque, cast[pointer](200)) == LFQ_OK
    check lfq_deque_push(deque, cast[pointer](300)) == LFQ_OK
    check lfq_deque_push(deque, cast[pointer](400)) == LFQ_OK

    check lfq_deque_is_empty(deque) == false
    check lfq_deque_len(deque) == 4

    # Thief steals 1 item -> FIFO top item: 100
    check lfq_deque_steal(deque, addr item) == LFQ_OK
    check cast[int](item) == 100
    check lfq_deque_len(deque) == 3

    # Worker pops 1 item -> LIFO bottom item: 400
    check lfq_deque_pop(deque, addr item) == LFQ_OK
    check cast[int](item) == 400
    check lfq_deque_len(deque) == 2

    # Thief steals batch of remaining 2 items (200, 300)
    var batch: array[4, pointer]
    let stolen = lfq_deque_steal_batch(deque, cast[ptr pointer](addr batch[0]), 4)
    check stolen == 2
    check cast[int](batch[0]) == 200
    check cast[int](batch[1]) == 300

    check lfq_deque_is_empty(deque) == true
    check lfq_deque_destroy(deque) == LFQ_OK

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
    var deque: ptr lfq_deque_t = nil
    check lfq_deque_create(32, dequeDestructor, addr tracker, addr deque) == LFQ_OK

    check lfq_deque_push(deque, cast[pointer](7)) == LFQ_OK
    check lfq_deque_push(deque, cast[pointer](14)) == LFQ_OK
    check lfq_deque_push(deque, cast[pointer](21)) == LFQ_OK

    check lfq_deque_destroy(deque) == LFQ_OK
    check tracker.count == 3
    check tracker.sum == (7 + 14 + 21)

  test "SkipListMap Table lifecycle, put, get, update, delete & contains":
    var table: ptr lfq_table_t = nil
    check lfq_table_create(nil, nil, addr table) == LFQ_OK
    check table != nil
    check lfq_table_is_empty(table) == true
    check lfq_table_len(table) == 0

    var val: pointer = nil
    check lfq_table_get(table, cast[pointer](1), addr val) == LFQ_ERR_EMPTY
    check lfq_table_contains(table, cast[pointer](1)) == false

    # Put 3 entries
    var inserted: bool = false
    check lfq_table_put(table, cast[pointer](1), cast[pointer](10), addr inserted) == LFQ_OK
    check inserted == true
    check lfq_table_put(table, cast[pointer](2), cast[pointer](20), addr inserted) == LFQ_OK
    check inserted == true
    check lfq_table_put(table, cast[pointer](3), cast[pointer](30), addr inserted) == LFQ_OK
    check inserted == true

    check lfq_table_is_empty(table) == false
    check lfq_table_len(table) == 3
    check lfq_table_contains(table, cast[pointer](1)) == true
    check lfq_table_contains(table, cast[pointer](2)) == true
    check lfq_table_contains(table, cast[pointer](3)) == true

    # Get items
    check lfq_table_get(table, cast[pointer](1), addr val) == LFQ_OK
    check cast[int](val) == 10
    check lfq_table_get(table, cast[pointer](2), addr val) == LFQ_OK
    check cast[int](val) == 20
    check lfq_table_get(table, cast[pointer](3), addr val) == LFQ_OK
    check cast[int](val) == 30

    # Update key 2 -> 222
    check lfq_table_put(table, cast[pointer](2), cast[pointer](222), addr inserted) == LFQ_OK
    check inserted == false
    check lfq_table_len(table) == 3
    check lfq_table_get(table, cast[pointer](2), addr val) == LFQ_OK
    check cast[int](val) == 222

    # Delete key 2
    var deleted: bool = false
    check lfq_table_delete(table, cast[pointer](2), addr deleted) == LFQ_OK
    check deleted == true
    check lfq_table_len(table) == 2
    check lfq_table_contains(table, cast[pointer](2)) == false
    check lfq_table_get(table, cast[pointer](2), addr val) == LFQ_ERR_EMPTY

    # Delete non-existent key returns LFQ_ERR_EMPTY
    check lfq_table_delete(table, cast[pointer](999), addr deleted) == LFQ_ERR_EMPTY
    check deleted == false

    # Remove key 1 via alias lfq_table_remove
    var removed: bool = false
    check lfq_table_remove(table, cast[pointer](1), addr removed) == LFQ_OK
    check removed == true
    check lfq_table_len(table) == 1

    check lfq_table_destroy(table) == LFQ_OK

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
    var table: ptr lfq_table_t = nil
    check lfq_table_create(tableDestructor, addr tracker, addr table) == LFQ_OK

    var inserted: bool = false
    check lfq_table_put(table, cast[pointer](10), cast[pointer](100), addr inserted) == LFQ_OK
    check lfq_table_put(table, cast[pointer](20), cast[pointer](200), addr inserted) == LFQ_OK

    var deleted: bool = false
    check lfq_table_delete(table, cast[pointer](10), addr deleted) == LFQ_OK

    check lfq_table_destroy(table) == LFQ_OK
    check tracker.count == 1
    check tracker.sumKeys == 20
    check tracker.sumVals == 200

  test "SkipListSet lifecycle, insert, remove, contains & duplicates":
    var set: ptr lfq_set_t = nil
    check lfq_set_create(nil, nil, addr set) == LFQ_OK
    check set != nil
    check lfq_set_is_empty(set) == true
    check lfq_set_len(set) == 0
    check lfq_set_contains(set, cast[pointer](42)) == false

    # Insert 3 items
    var inserted: bool = false
    check lfq_set_insert(set, cast[pointer](100), addr inserted) == LFQ_OK
    check inserted == true
    check lfq_set_insert(set, cast[pointer](200), addr inserted) == LFQ_OK
    check inserted == true
    check lfq_set_insert(set, cast[pointer](300), addr inserted) == LFQ_OK
    check inserted == true

    check lfq_set_is_empty(set) == false
    check lfq_set_len(set) == 3
    check lfq_set_contains(set, cast[pointer](100)) == true
    check lfq_set_contains(set, cast[pointer](200)) == true
    check lfq_set_contains(set, cast[pointer](300)) == true

    # Insert duplicate 200
    check lfq_set_insert(set, cast[pointer](200), addr inserted) == LFQ_OK
    check inserted == false
    check lfq_set_len(set) == 3

    # Remove 200
    var removed: bool = false
    check lfq_set_remove(set, cast[pointer](200), addr removed) == LFQ_OK
    check removed == true
    check lfq_set_len(set) == 2
    check lfq_set_contains(set, cast[pointer](200)) == false

    # Remove non-existent returns LFQ_ERR_EMPTY
    check lfq_set_remove(set, cast[pointer](999), addr removed) == LFQ_ERR_EMPTY
    check removed == false

    check lfq_set_destroy(set) == LFQ_OK

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
    var set: ptr lfq_set_t = nil
    check lfq_set_create(setDestructor, addr tracker, addr set) == LFQ_OK

    var inserted: bool = false
    check lfq_set_insert(set, cast[pointer](11), addr inserted) == LFQ_OK
    check lfq_set_insert(set, cast[pointer](22), addr inserted) == LFQ_OK
    check lfq_set_insert(set, cast[pointer](33), addr inserted) == LFQ_OK

    check lfq_set_destroy(set) == LFQ_OK
    check tracker.count == 3
    check tracker.sum == (11 + 22 + 33)

  test "Ctrie lifecycle, insert, lookup, remove, and wait-free snapshot":
    var ctrie: ptr lfq_ctrie_t = nil
    check lfq_ctrie_create(nil, nil, addr ctrie) == LFQ_OK
    check ctrie != nil
    check lfq_ctrie_is_empty(ctrie) == true
    check lfq_ctrie_len(ctrie) == 0

    var inserted: bool = false
    check lfq_ctrie_insert(ctrie, cast[pointer](1), cast[pointer](10), addr inserted) == LFQ_OK
    check inserted == true
    check lfq_ctrie_insert(ctrie, cast[pointer](2), cast[pointer](20), addr inserted) == LFQ_OK
    check inserted == true
    check lfq_ctrie_insert(ctrie, cast[pointer](3), cast[pointer](30), addr inserted) == LFQ_OK
    check inserted == true

    check lfq_ctrie_is_empty(ctrie) == false
    check lfq_ctrie_len(ctrie) == 3
    check lfq_ctrie_contains(ctrie, cast[pointer](1)) == true
    check lfq_ctrie_contains(ctrie, cast[pointer](2)) == true
    check lfq_ctrie_contains(ctrie, cast[pointer](3)) == true
    check lfq_ctrie_contains(ctrie, cast[pointer](4)) == false

    var val: pointer = nil
    check lfq_ctrie_lookup(ctrie, cast[pointer](2), addr val) == LFQ_OK
    check cast[int](val) == 20

    # Wait-free snapshot
    var snap: ptr lfq_ctrie_snapshot_t = nil
    check lfq_ctrie_snapshot(ctrie, addr snap) == LFQ_OK
    check snap != nil
    check lfq_ctrie_snapshot_is_empty(snap) == false
    check lfq_ctrie_snapshot_len(snap) == 3
    check lfq_ctrie_snapshot_contains(snap, cast[pointer](2)) == true

    # Mutate ctrie after snapshot
    var removed: bool = false
    check lfq_ctrie_remove(ctrie, cast[pointer](2), addr removed) == LFQ_OK
    check removed == true
    check lfq_ctrie_len(ctrie) == 2
    check lfq_ctrie_contains(ctrie, cast[pointer](2)) == false

    # Snapshot should still hold 2
    check lfq_ctrie_snapshot_len(snap) == 3
    check lfq_ctrie_snapshot_contains(snap, cast[pointer](2)) == true
    var snapVal: pointer = nil
    check lfq_ctrie_snapshot_lookup(snap, cast[pointer](2), addr snapVal) == LFQ_OK
    check cast[int](snapVal) == 20

    check lfq_ctrie_snapshot_destroy(snap) == LFQ_OK
    check lfq_ctrie_destroy(ctrie) == LFQ_OK

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
    var ctrie: ptr lfq_ctrie_t = nil
    check lfq_ctrie_create(ctrieDestructor, addr tracker, addr ctrie) == LFQ_OK

    var inserted: bool = false
    check lfq_ctrie_insert(ctrie, cast[pointer](5), cast[pointer](50), addr inserted) == LFQ_OK
    check lfq_ctrie_insert(ctrie, cast[pointer](6), cast[pointer](60), addr inserted) == LFQ_OK

    check lfq_ctrie_destroy(ctrie) == LFQ_OK
    check tracker.count == 2
    check tracker.sumKeys == (5 + 6)
    check tracker.sumVals == (50 + 60)

  test "Direct C99 Header Interoperability":
    let code = execShellCmd("clang -fsyntax-only -std=c99 -Wall -Wextra -Werror -I" & includeDir & " " & (includeDir / "lockfree.h"))
    check code == 0

  test "Compiled C99 test harness execution (clang + liblockfree.a)":
    let rootDir = currentSourcePath().parentDir() / ".."
    let staticLib = rootDir / ".tmp/liblockfree.a"
    if not fileExists(staticLib):
      let buildCode = execShellCmd("nim c --app:staticlib -d:danger --threads:on -o:" & staticLib & " " & (rootDir / "src/lockfree/cabi.nim"))
      check buildCode == 0
    let cTestSrc = rootDir / "tests/cabi/test_cabi.c"
    let cTestBin = rootDir / ".tmp/test_cabi"
    let compileCmd = "clang -std=c99 -Wall -Wextra -Werror -I" & includeDir & " " & cTestSrc & " -L" & (rootDir / ".tmp") & " -llockfree -o " & cTestBin
    let compCode = execShellCmd(compileCmd)
    check compCode == 0
    let runCode = execShellCmd(cTestBin)
    check runCode == 0
