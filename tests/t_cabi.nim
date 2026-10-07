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

  test "Direct C99 Header Interoperability":
    let code = execShellCmd("clang -fsyntax-only -std=c99 -Wall -Wextra -Werror -I" & includeDir & " " & (includeDir / "lockfree.h"))
    check code == 0
