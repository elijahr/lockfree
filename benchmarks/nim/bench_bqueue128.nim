## BQueue128 (128-Bit DWCAS) vs BQueue (Classical Vyukov) Benchmark
##
## Benchmarks 128-bit hardware DWCAS bounded queue against Dmitry Vyukov's
## classical per-slot sequence counter bounded queue across:
##   1p1c, 2p2c, 4p4c, 8p8c

import std/[monotimes, options, os, parseopt, sets, strformat, syncio, times]
import ./bench_common
import lockfree/bqueue128
import lockfree/bqueue as q_mod
import lockfree/strategy
import lockfree/endpoint

const
  BenchCapacity = 4096
  DefaultRuns = 5
  DefaultWarmup = 2
  DefaultMessageCount = 200_000

type
  BQueue128ProducerCtx[N: static int, T] = object
    q: ptr BQueue128[T, N]
    startIdx: int
    count: int

  BQueue128ConsumerCtx[N: static int, T] = object
    q: ptr BQueue128[T, N]
    count: int

proc bqueue128ProducerThread[N: static int, T](
    ctx: ptr BQueue128ProducerCtx[N, T]
) {.thread.} =
  for i in ctx.startIdx ..< ctx.startIdx + ctx.count:
    while not ctx.q[].tryPush(T(i)):
      benchBackoffOnPeerWait()

proc bqueue128ConsumerThread[N: static int, T](
    ctx: ptr BQueue128ConsumerCtx[N, T]
) {.thread.} =
  var local = 0
  var item: T
  while local < ctx.count:
    if ctx.q[].tryPop(item):
      inc local
    else:
      benchBackoffOnPeerWait()

proc runOneBQueue128Run[N: static int, P, C: static int, T](
    queue: ptr BQueue128[T, N], messageCount: int
): float =
  let baseP = messageCount div P
  let remP = messageCount mod P
  let baseC = messageCount div C
  let remC = messageCount mod C
  var producerThreads: array[P, Thread[ptr BQueue128ProducerCtx[N, T]]]
  var consumerThreads: array[C, Thread[ptr BQueue128ConsumerCtx[N, T]]]
  var producerCtxs: array[P, BQueue128ProducerCtx[N, T]]
  var consumerCtxs: array[C, BQueue128ConsumerCtx[N, T]]
  var nextStart = 0
  for i in 0 ..< P:
    let count = baseP + (if i < remP: 1 else: 0)
    producerCtxs[i] = BQueue128ProducerCtx[N, T](
      q: queue, startIdx: nextStart, count: count
    )
    nextStart += count
  for i in 0 ..< C:
    let count = baseC + (if i < remC: 1 else: 0)
    consumerCtxs[i] = BQueue128ConsumerCtx[N, T](
      q: queue, count: count
    )
  let startTime = getMonoTime()
  for i in 0 ..< P:
    createThread(
      producerThreads[i], bqueue128ProducerThread[N, T], addr producerCtxs[i]
    )
  for i in 0 ..< C:
    createThread(
      consumerThreads[i], bqueue128ConsumerThread[N, T], addr consumerCtxs[i]
    )
  for i in 0 ..< P:
    joinThread(producerThreads[i])
  for i in 0 ..< C:
    joinThread(consumerThreads[i])
  let elapsedNs = float(inNanoseconds(getMonoTime() - startTime))
  if elapsedNs <= 0.0:
    return 0.0
  result = float(messageCount) * 1_000_000.0 / elapsedNs

proc runBQueue128Shape[N: static int, P, C: static int, T](
    em: var BMFEmitter, runs, warmup, messageCount: int
): float =
  let slug = "lockfree_bqueue128/mpmc/" & $P & "p" & $C & "c"
  echo fmt"BQueue128 {P}p{C}c ({slug}):"
  for _ in 0 ..< warmup:
    let q = allocAlignedBQueue128[T, N]()
    discard runOneBQueue128Run[N, P, C, T](q, messageCount)
    freeAlignedBQueue128(q)
  var samples: seq[float] = @[]
  for _ in 0 ..< runs:
    let q = allocAlignedBQueue128[T, N]()
    samples.add(runOneBQueue128Run[N, P, C, T](q, messageCount))
    freeAlignedBQueue128(q)
  let m = mean(samples)
  let s = stddev(samples)
  echo fmt"  mean: {m:.1f} ops/ms"
  echo fmt"  stddev: {s:.1f}"
  echo fmt"  runs: {samples.len}"
  em.addMeasure(slug, "throughput_ops_ms", m, m - s, m + s)
  return m

# ---------- Classical BQueue harness ----------

type
  BQueueProducerCtx[N, P, C: static int, T] = object
    producer: Bound[T, AnyThreadTag, q_mod.BQueue[T, ccMulti, ccMulti, N, P, C]]
    startIdx: int
    count: int

  BQueueConsumerCtx[N, P, C: static int, T] = object
    consumer: Bound[T, AnyThreadTag, q_mod.BQueue[T, ccMulti, ccMulti, N, P, C]]
    count: int

proc bqueueProducerThread[N, P, C: static int, T](
    ctx: ptr BQueueProducerCtx[N, P, C, T]
) {.thread.} =
  for i in ctx.startIdx ..< ctx.startIdx + ctx.count:
    while not ctx.producer.push(T(i)):
      benchBackoffOnPeerWait()

proc bqueueConsumerThread[N, P, C: static int, T](
    ctx: ptr BQueueConsumerCtx[N, P, C, T]
) {.thread.} =
  var local = 0
  while local < ctx.count:
    let item = ctx.consumer.pop()
    if item.isSome:
      inc local
    else:
      benchBackoffOnPeerWait()

proc runOneBQueueRun[N, P, C: static int, T](
    queue: var q_mod.BQueue[T, ccMulti, ccMulti, N, P, C], messageCount: int
): float =
  let baseP = messageCount div P
  let remP = messageCount mod P
  let baseC = messageCount div C
  let remC = messageCount mod C
  var producerThreads: array[P, Thread[ptr BQueueProducerCtx[N, P, C, T]]]
  var consumerThreads: array[C, Thread[ptr BQueueConsumerCtx[N, P, C, T]]]
  var producerCtxs: array[P, BQueueProducerCtx[N, P, C, T]]
  var consumerCtxs: array[C, BQueueConsumerCtx[N, P, C, T]]
  var nextStart = 0
  for i in 0 ..< P:
    let count = baseP + (if i < remP: 1 else: 0)
    producerCtxs[i] = BQueueProducerCtx[N, P, C, T](
      producer: queue.getProducerHere(idx = i), startIdx: nextStart, count: count
    )
    nextStart += count
  for i in 0 ..< C:
    let count = baseC + (if i < remC: 1 else: 0)
    consumerCtxs[i] = BQueueConsumerCtx[N, P, C, T](
      consumer: queue.getConsumerHere(idx = i), count: count
    )
  let startTime = getMonoTime()
  for i in 0 ..< P:
    createThread(
      producerThreads[i], bqueueProducerThread[N, P, C, T], addr producerCtxs[i]
    )
  for i in 0 ..< C:
    createThread(
      consumerThreads[i], bqueueConsumerThread[N, P, C, T], addr consumerCtxs[i]
    )
  for i in 0 ..< P:
    joinThread(producerThreads[i])
  for i in 0 ..< C:
    joinThread(consumerThreads[i])
  let elapsedNs = float(inNanoseconds(getMonoTime() - startTime))
  if elapsedNs <= 0.0:
    return 0.0
  result = float(messageCount) * 1_000_000.0 / elapsedNs

proc runBQueueShape[N, P, C: static int, T](
    em: var BMFEmitter, runs, warmup, messageCount: int
): float =
  let slug = "lockfree_bqueue/mpmc/" & $P & "p" & $C & "c"
  echo fmt"BQueue (Vyukov) {P}p{C}c ({slug}):"
  for _ in 0 ..< warmup:
    var q = q_mod.newBQueue[T, ccMulti, ccMulti, N, P, C]()
    discard runOneBQueueRun(q, messageCount)
  var samples: seq[float] = @[]
  for _ in 0 ..< runs:
    var q = q_mod.newBQueue[T, ccMulti, ccMulti, N, P, C]()
    samples.add(runOneBQueueRun(q, messageCount))
  let m = mean(samples)
  let s = stddev(samples)
  echo fmt"  mean: {m:.1f} ops/ms"
  echo fmt"  stddev: {s:.1f}"
  echo fmt"  runs: {samples.len}"
  em.addMeasure(slug, "throughput_ops_ms", m, m - s, m + s)
  return m

proc main() =
  var em = initBMFEmitter()
  echo "================================================================="
  echo " Benchmarking BQueue128 (128-Bit DWCAS) vs BQueue (Classical)    "
  echo " Capacity: " & $BenchCapacity & ", Messages: " & $DefaultMessageCount
  echo "=================================================================\n"

  echo "--- 1 Producer x 1 Consumer ---"
  let bq128_1 = runBQueue128Shape[BenchCapacity, 1, 1, uint64](em, DefaultRuns, DefaultWarmup, DefaultMessageCount)
  let bq_1 = runBQueueShape[BenchCapacity, 1, 1, uint64](em, DefaultRuns, DefaultWarmup, DefaultMessageCount)
  echo fmt"  => Ratio (BQueue128 / BQueue): {bq128_1 / bq_1:.2f}x\n"

  echo "--- 2 Producers x 2 Consumers ---"
  let bq128_2 = runBQueue128Shape[BenchCapacity, 2, 2, uint64](em, DefaultRuns, DefaultWarmup, DefaultMessageCount)
  let bq_2 = runBQueueShape[BenchCapacity, 2, 2, uint64](em, DefaultRuns, DefaultWarmup, DefaultMessageCount)
  echo fmt"  => Ratio (BQueue128 / BQueue): {bq128_2 / bq_2:.2f}x\n"

  echo "--- 4 Producers x 4 Consumers ---"
  let bq128_4 = runBQueue128Shape[BenchCapacity, 4, 4, uint64](em, DefaultRuns, DefaultWarmup, DefaultMessageCount)
  let bq_4 = runBQueueShape[BenchCapacity, 4, 4, uint64](em, DefaultRuns, DefaultWarmup, DefaultMessageCount)
  echo fmt"  => Ratio (BQueue128 / BQueue): {bq128_4 / bq_4:.2f}x\n"

  echo "--- 8 Producers x 8 Consumers ---"
  let bq128_8 = runBQueue128Shape[BenchCapacity, 8, 8, uint64](em, DefaultRuns, DefaultWarmup, DefaultMessageCount)
  let bq_8 = runBQueueShape[BenchCapacity, 8, 8, uint64](em, DefaultRuns, DefaultWarmup, DefaultMessageCount)
  echo fmt"  => Ratio (BQueue128 / BQueue): {bq128_8 / bq_8:.2f}x\n"

  echo "================================================================="
  echo " Benchmark Complete.                                             "
  echo "================================================================="

when isMainModule:
  main()
