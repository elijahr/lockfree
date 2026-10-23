## Example: 128-Bit DWCAS Bounded MPMC Queue (`BQueue128`)
##
## Demonstrates:
## 1. Single-instruction atomic publish via Double-Word CAS (128-bit hardware atomics).
## 2. Inlined, zero-allocation 16-byte slot layout (tag + value in a single DWCAS word).
## 3. Cacheline-aligned heap allocation (`allocAlignedBQueue128` / `freeAlignedBQueue128`).
## 4. Concurrent MPMC multi-threaded work distribution.

import std/atomics as std_atomics
import lockfree
import lockfree/bqueue128

const
  Capacity = 512
  NumProducers = 4
  NumConsumers = 4
  ItemsPerProducer = 10_000
  TotalItems = NumProducers * ItemsPerProducer

type
  WorkerContext = object
    q: ptr BQueue128[int, Capacity]
    totalPopped: std_atomics.Atomic[int]
    sumPopped: std_atomics.Atomic[int64]

proc producerWorker(ctx: ptr WorkerContext) {.thread.} =
  for i in 1 .. ItemsPerProducer:
    # Single-instruction hardware DWCAS pushes sequence tag + payload atomically.
    # Producers never stall or leave partial uncommitted state in a slot.
    while not ctx.q[].tryPush(i):
      discard

proc consumerWorker(ctx: ptr WorkerContext) {.thread.} =
  var localSum: int64 = 0
  var val: int
  while true:
    if ctx.q[].tryPop(val):
      localSum += val
      let count = ctx.totalPopped.fetchAdd(1) + 1
      if count == TotalItems:
        discard ctx.sumPopped.fetchAdd(localSum)
        break
      elif count > TotalItems:
        break
    else:
      if ctx.totalPopped.load() >= TotalItems:
        discard ctx.sumPopped.fetchAdd(localSum)
        break

proc main() =
  echo "=== BQueue128: 128-Bit DWCAS Bounded Queue Demo ==="
  echo "Capacity: ", Capacity, " slots"
  echo "Producers: ", NumProducers, ", Consumers: ", NumConsumers
  echo "Total items: ", TotalItems

  # 1. Stack / Value-type allocation demonstration
  var stackQueue = initBQueue128[int, 16]()
  assert stackQueue.tryPush(42)
  assert stackQueue.tryPush(100)
  var outVal: int
  assert stackQueue.tryPop(outVal) and outVal == 42
  assert stackQueue.tryPop(outVal) and outVal == 100
  echo "Stack-allocated queue verification: OK"

  # 2. Heap-allocated with strict 128-byte Apple Silicon / 64-byte x86 cacheline alignment
  let heapQueue = allocAlignedBQueue128[int, Capacity]()

  var ctx: WorkerContext
  ctx.q = heapQueue
  ctx.totalPopped.store(0)
  ctx.sumPopped.store(0)

  var prodThreads: array[NumProducers, Thread[ptr WorkerContext]]
  var consThreads: array[NumConsumers, Thread[ptr WorkerContext]]

  for c in 0 ..< NumConsumers:
    consThreads[c].createThread(consumerWorker, addr ctx)

  for p in 0 ..< NumProducers:
    prodThreads[p].createThread(producerWorker, addr ctx)

  for p in 0 ..< NumProducers:
    joinThread(prodThreads[p])

  for c in 0 ..< NumConsumers:
    joinThread(consThreads[c])

  let expectedSumPerProd = (int64(ItemsPerProducer) * int64(ItemsPerProducer + 1)) div 2
  let expectedTotalSum = expectedSumPerProd * NumProducers

  echo "Processed: ", ctx.totalPopped.load(), " / ", TotalItems, " items"
  echo "Sum match: ", ctx.sumPopped.load() == expectedTotalSum, " (", ctx.sumPopped.load(), ")"
  assert ctx.totalPopped.load() == TotalItems
  assert ctx.sumPopped.load() == expectedTotalSum
  assert heapQueue[].isEmpty

  # Free aligned heap buffer
  freeAlignedBQueue128(heapQueue)
  echo "BQueue128 demo completed successfully!"

when isMainModule:
  main()
