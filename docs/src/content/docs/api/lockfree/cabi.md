---
title: "lockfree/cabi"
description: "API reference for lockfree/cabi"
---

<p>Canonical C99 interface implementation declared in <tt class="docutils literal"><span class="pre"><span class="Keyword">include</span><span class="Operator">/</span><span class="Identifier">lockfree</span><span class="Operator">.</span><span class="Identifier">h</span></span></tt>. Wraps bounded (BQueue) and unbounded (Queue) lock-free MPMC queues with:</p>
<ul class="simple"><li>Opaque handles (<tt class="docutils literal"><span class="pre"><span class="Identifier">lf_queue_t</span><span class="Operator">*</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">lf_producer_t</span><span class="Operator">*</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">lf_consumer_t</span><span class="Operator">*</span></span></tt>)</li>
<li>Zero-copy 64-bit raw pointer payload transport (<tt class="docutils literal"><span class="pre"><span class="Identifier">void</span><span class="Operator">*</span></span></tt> &lt;-&gt; <tt class="docutils literal"><span class="pre"><span class="Identifier">pointer</span></span></tt>)</li>
<li>Dynamic thread registration and thread-local slot recycling</li>
<li>Optional item cleanup callbacks on queue destroy</li>
<li>Strict <tt class="docutils literal"><span class="pre"><span class="Identifier">cAbiBoundary</span></span></tt> exception firewall preventing any Nim exception/panic from escaping across the FFI boundary</li>
<li>C99 POSIX consumers using <tt class="docutils literal"><span class="pre"><span class="Operator">&lt;</span><span class="Identifier">pthread</span><span class="Operator">.</span><span class="Identifier">h</span><span class="Operator">&gt;</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Operator">&lt;</span><span class="Identifier">time</span><span class="Operator">.</span><span class="Identifier">h</span><span class="Operator">&gt;</span></span></tt> (<tt class="docutils literal"><span class="pre"><span class="Identifier">nanosleep</span></span></tt>) under <tt class="docutils literal"><span class="pre"><span class="Operator">-</span><span class="Identifier">std</span><span class="Operator">=</span><span class="Identifier">c99</span></span></tt> on glibc should compile with <tt class="docutils literal"><span class="pre"><span class="Operator">-</span><span class="Identifier">D_POSIX_C_SOURCE</span><span class="Operator">=</span><span class="DecNumber">199309</span><span class="Identifier">L</span></span></tt></li>
</ul>
<p>==============================================================================</p>


## Types

### `lf_status_t`

```nim
lf_status_t {.size: 4.} = enum
  LF_ERR_PANIC = -2, LF_ERR_FAILURE = -1, LF_OK = 0, LF_ERR_EMPTY = 1,
  LF_ERR_FULL = 2, LF_ERR_CLOSED = 3, LF_ERR_INVALID_ARG = 4,
  LF_ERR_REGISTRY_FULL = 5, LF_ERR_UNSUPPORTED = 6
```

### `lfq_status_t`

```nim
lfq_status_t = lf_status_t
```

### `lf_item_destructor_fn`

```nim
lf_item_destructor_fn = proc (item: pointer; userData: pointer) {.cdecl, gcsafe.}
```

### `lfq_item_destructor_fn`

```nim
lfq_item_destructor_fn = lf_item_destructor_fn
```

### `lf_entry_destructor_fn`

```nim
lf_entry_destructor_fn = proc (key: pointer; val: pointer; userData: pointer) {.
    cdecl, gcsafe.}
```

### `lfq_entry_destructor_fn`

```nim
lfq_entry_destructor_fn = lf_entry_destructor_fn
```

### `lf_queue`

```nim
lf_queue {.exportc: "lf_queue_t".} = object
  destructor*: lf_item_destructor_fn
  userData*: pointer
  maxProducers*: int
  maxConsumers*: int
  activeProducers*: Atomic[int]
  activeConsumers*: Atomic[int]
  isClosed*: Atomic[bool]
  destroyFn*: proc (q: ptr lf_queue_t): lf_status_t {.nimcall, gcsafe,
      raises: [].}
  producerAcquireFn*: proc (q: ptr lf_queue_t; outProd: ptr ptr lf_producer_t): lf_status_t {.
      nimcall, gcsafe, raises: [].}
  consumerAcquireFn*: proc (q: ptr lf_queue_t; outCons: ptr ptr lf_consumer_t): lf_status_t {.
      nimcall, gcsafe, raises: [].}
  lenFn*: proc (q: ptr lf_queue_t): csize_t {.nimcall, gcsafe, raises: [].}
  isEmptyFn*: proc (q: ptr lf_queue_t): bool {.nimcall, gcsafe, raises: [].}
```

### `lf_queue_t`

```nim
lf_queue_t = lf_queue
```

### `lfq_queue`

```nim
lfq_queue = lf_queue
```

### `lfq_queue_t`

```nim
lfq_queue_t = lf_queue
```

### `lf_producer`

```nim
lf_producer {.exportc: "lf_producer_t".} = object
  queue*: ptr lf_queue_t
  pushFn*: proc (prod: ptr lf_producer_t; item: pointer): lf_status_t {.nimcall,
      gcsafe, raises: [].}
  releaseFn*: proc (prod: ptr lf_producer_t): lf_status_t {.nimcall, gcsafe,
      raises: [].}
  handleManager*: pointer
  handleIdx*: int
```

### `lf_producer_t`

```nim
lf_producer_t = lf_producer
```

### `lfq_producer`

```nim
lfq_producer = lf_producer
```

### `lfq_producer_t`

```nim
lfq_producer_t = lf_producer
```

### `lf_consumer`

```nim
lf_consumer {.exportc: "lf_consumer_t".} = object
  queue*: ptr lf_queue_t
  popFn*: proc (cons: ptr lf_consumer_t; outItem: ptr pointer): lf_status_t {.
      nimcall, gcsafe, raises: [].}
  popBatchFn*: proc (cons: ptr lf_consumer_t; outItems: ptr pointer;
                     maxCount: csize_t): csize_t {.nimcall, gcsafe, raises: [].}
  releaseFn*: proc (cons: ptr lf_consumer_t): lf_status_t {.nimcall, gcsafe,
      raises: [].}
  handleManager*: pointer
  handleIdx*: int
```

### `lf_consumer_t`

```nim
lf_consumer_t = lf_consumer
```

### `lfq_consumer`

```nim
lfq_consumer = lf_consumer
```

### `lfq_consumer_t`

```nim
lfq_consumer_t = lf_consumer
```

### `lf_stack`

```nim
lf_stack {.exportc: "lf_stack_t".} = object
  destructor*: lf_item_destructor_fn
  userData*: pointer
  raw*: ptr TreiberStack[pointer]
```

### `lf_stack_t`

```nim
lf_stack_t = lf_stack
```

### `lfq_stack`

```nim
lfq_stack = lf_stack
```

### `lfq_stack_t`

```nim
lfq_stack_t = lf_stack
```

### `lf_deque`

```nim
lf_deque {.exportc: "lf_deque_t".} = object
  destructor*: lf_item_destructor_fn
  userData*: pointer
  raw*: ptr ChaseLevDeque[pointer]
```

### `lf_deque_t`

```nim
lf_deque_t = lf_deque
```

### `lfq_deque`

```nim
lfq_deque = lf_deque
```

### `lfq_deque_t`

```nim
lfq_deque_t = lf_deque
```

### `lf_table`

```nim
lf_table {.exportc: "lf_table_t".} = object
  destructor*: lf_entry_destructor_fn
  userData*: pointer
  raw*: ptr SkipListMap[pointer, pointer]
```

### `lf_table_t`

```nim
lf_table_t = lf_table
```

### `lfq_table`

```nim
lfq_table = lf_table
```

### `lfq_table_t`

```nim
lfq_table_t = lf_table
```

### `lf_set`

```nim
lf_set {.exportc: "lf_set_t".} = object
  destructor*: lf_item_destructor_fn
  userData*: pointer
  raw*: ptr SkipListSet[pointer]
```

### `lf_set_t`

```nim
lf_set_t = lf_set
```

### `lfq_set`

```nim
lfq_set = lf_set
```

### `lfq_set_t`

```nim
lfq_set_t = lf_set
```

### `lf_taskpool`

```nim
lf_taskpool {.exportc: "lf_taskpool_t".} = object
  raw*: ptr TaskPool
```

### `lf_taskpool_t`

```nim
lf_taskpool_t = lf_taskpool
```

### `lfq_taskpool`

```nim
lfq_taskpool = lf_taskpool
```

### `lfq_taskpool_t`

```nim
lfq_taskpool_t = lf_taskpool
```

### `lf_task_fn`

```nim
lf_task_fn = proc (arg: pointer) {.cdecl, gcsafe.}
```

### `lfq_task_fn`

```nim
lfq_task_fn = lf_task_fn
```

### `lf_for_task_fn`

```nim
lf_for_task_fn = proc (index: csize_t; arg: pointer) {.cdecl, gcsafe.}
```

### `lfq_for_task_fn`

```nim
lfq_for_task_fn = lf_for_task_fn
```

### `lf_ctrie`

```nim
lf_ctrie {.exportc: "lf_ctrie_t".} = object
  destructor*: lf_entry_destructor_fn
  userData*: pointer
  raw*: ptr Ctrie[pointer, pointer]
```

### `lf_ctrie_t`

```nim
lf_ctrie_t = lf_ctrie
```

### `lfq_ctrie`

```nim
lfq_ctrie = lf_ctrie
```

### `lfq_ctrie_t`

```nim
lfq_ctrie_t = lf_ctrie
```

### `lf_ctrie_snapshot_handle`

```nim
lf_ctrie_snapshot_handle {.exportc: "lf_ctrie_snapshot_t".} = object
  raw*: ptr Snapshot[pointer, pointer]
```

### `lf_ctrie_snapshot_t`

```nim
lf_ctrie_snapshot_t = lf_ctrie_snapshot_handle
```

### `lfq_ctrie_snapshot_handle`

```nim
lfq_ctrie_snapshot_handle = lf_ctrie_snapshot_handle
```

### `lfq_ctrie_snapshot_t`

```nim
lfq_ctrie_snapshot_t = lf_ctrie_snapshot_handle
```

### `lf_overflow_mode_t`

```nim
lf_overflow_mode_t {.size: 4.} = enum
  LF_OVERFLOW_DROP_OLDEST = 0, LF_OVERFLOW_BACKOFF = 1
```

### `lfq_overflow_mode_t`

```nim
lfq_overflow_mode_t = lf_overflow_mode_t
```

### `lf_sub_origin_t`

```nim
lf_sub_origin_t {.size: 4.} = enum
  LF_SUB_FROM_LATEST = 0, LF_SUB_FROM_EARLIEST = 1
```

### `lfq_sub_origin_t`

```nim
lfq_sub_origin_t = lf_sub_origin_t
```

### `lf_poll_result_t`

```nim
lf_poll_result_t {.size: 4.} = enum
  LF_POLL_SUCCESS = 0, LF_POLL_EMPTY = 1, LF_POLL_LAGGED = 2
```

### `lfq_poll_result_t`

```nim
lfq_poll_result_t = lf_poll_result_t
```

### `lf_broadcast_handle`

```nim
lf_broadcast_handle {.exportc: "lf_broadcast_t".} = object
  raw*: ptr BroadcastRing[pointer]
```

### `lf_broadcast_t`

```nim
lf_broadcast_t = lf_broadcast_handle
```

### `lfq_broadcast_handle`

```nim
lfq_broadcast_handle = lf_broadcast_handle
```

### `lfq_broadcast_t`

```nim
lfq_broadcast_t = lf_broadcast_handle
```

### `lf_broadcast_cursor_handle`

```nim
lf_broadcast_cursor_handle {.exportc: "lf_broadcast_cursor_t".} = object
  raw*: ptr BroadcastCursor[pointer]
```

### `lf_broadcast_cursor_t`

```nim
lf_broadcast_cursor_t = lf_broadcast_cursor_handle
```

### `lfq_broadcast_cursor_handle`

```nim
lfq_broadcast_cursor_handle = lf_broadcast_cursor_handle
```

### `lfq_broadcast_cursor_t`

```nim
lfq_broadcast_cursor_t = lf_broadcast_cursor_handle
```

### `lf_topic_bus_handle`

```nim
lf_topic_bus_handle {.exportc: "lf_topic_bus_t".} = object
  raw*: ptr TopicBus[pointer]
```

### `lf_topic_bus_t`

```nim
lf_topic_bus_t = lf_topic_bus_handle
```

### `lfq_topic_bus_handle`

```nim
lfq_topic_bus_handle = lf_topic_bus_handle
```

### `lfq_topic_bus_t`

```nim
lfq_topic_bus_t = lf_topic_bus_handle
```

### `lf_rendezvous_t`

```nim
lf_rendezvous_t = lf_rendezvous_handle
```

### `lfq_rendezvous_handle`

```nim
lfq_rendezvous_handle = lf_rendezvous_handle
```

### `lfq_rendezvous_t`

```nim
lfq_rendezvous_t = lf_rendezvous_handle
```

### `lf_rate_limit_state_t`

```nim
lf_rate_limit_state_t {.exportc: "lf_rate_limit_state_t", bycopy.} = object
  last_timestamp_ns*: uint64
  tokens_or_level*: uint64
```

### `lfq_rate_limit_state_t`

```nim
lfq_rate_limit_state_t = lf_rate_limit_state_t
```

### `lf_token_bucket_t`

```nim
lf_token_bucket_t {.exportc: "lf_token_bucket_t", bycopy.} = object
  state* {.align: 128.}: RateLimitState
  capacity*: uint64
  refill_rate_per_sec*: uint64
  scale_factor*: uint64
```

### `lfq_token_bucket_t`

```nim
lfq_token_bucket_t = lf_token_bucket_t
```

### `lf_leaky_bucket_t`

```nim
lf_leaky_bucket_t {.exportc: "lf_leaky_bucket_t", bycopy.} = object
  state* {.align: 128.}: RateLimitState
  burst_tolerance_ns*: uint64
  leak_rate_per_sec*: uint64
  scale_factor*: uint64
```

### `lfq_leaky_bucket_t`

```nim
lfq_leaky_bucket_t = lf_leaky_bucket_t
```

### `lf_iovec_slice_t`

```nim
lf_iovec_slice_t {.exportc: "lf_iovec_slice_t", bycopy.} = object
  iov_base*: pointer
  iov_len*: csize_t
```

### `lfq_iovec_slice_t`

```nim
lfq_iovec_slice_t = lf_iovec_slice_t
```

### `lf_iovec_pair_t`

```nim
lf_iovec_pair_t {.exportc: "lf_iovec_pair_t", bycopy.} = object
  first*: lf_iovec_slice_t
  second*: lf_iovec_slice_t
```

### `lfq_iovec_pair_t`

```nim
lfq_iovec_pair_t = lf_iovec_pair_t
```

### `lf_stream_ring_handle`

```nim
lf_stream_ring_handle {.exportc: "lf_stream_ring_t".} = object
  raw*: ptr StreamRing
```

### `lf_stream_ring_t`

```nim
lf_stream_ring_t = lf_stream_ring_handle
```

### `lfq_stream_ring_handle`

```nim
lfq_stream_ring_handle = lf_stream_ring_handle
```

### `lfq_stream_ring_t`

```nim
lfq_stream_ring_t = lf_stream_ring_handle
```

### `lf_streambuffer_t`

```nim
lf_streambuffer_t = lf_stream_ring_handle
```

### `lfq_streambuffer_t`

```nim
lfq_streambuffer_t = lf_stream_ring_handle
```

### `lf_mpmc_stream_ring_handle`

```nim
lf_mpmc_stream_ring_handle {.exportc: "lf_mpmc_stream_ring_t".} = object
  raw*: ptr MPMCStreamRing
```

### `lf_mpmc_stream_ring_t`

```nim
lf_mpmc_stream_ring_t = lf_mpmc_stream_ring_handle
```

### `lfq_mpmc_stream_ring_handle`

```nim
lfq_mpmc_stream_ring_handle = lf_mpmc_stream_ring_handle
```

### `lfq_mpmc_stream_ring_t`

```nim
lfq_mpmc_stream_ring_t = lf_mpmc_stream_ring_handle
```

### `lf_skiplist_t`

```nim
lf_skiplist_t = lf_table_t
```

### `lfq_skiplist_t`

```nim
lfq_skiplist_t = lf_table_t
```

### `lf_mapping_fn`

```nim
lf_mapping_fn = proc (key: pointer; key_len: csize_t; user_data: pointer): pointer {.
    cdecl, gcsafe.}
```

### `lfq_mapping_fn`

```nim
lfq_mapping_fn = lf_mapping_fn
```

### `lf_update_fn`

```nim
lf_update_fn = proc (old_val: pointer; old_val_len: csize_t; user_data: pointer): pointer {.
    cdecl, gcsafe.}
```

### `lfq_update_fn`

```nim
lfq_update_fn = lf_update_fn
```

### `lf_arc_destructor_fn`

```nim
lf_arc_destructor_fn = proc (item: pointer; userData: pointer) {.cdecl, gcsafe,
    raises: [].}
```

### `lfq_arc_destructor_fn`

```nim
lfq_arc_destructor_fn = lf_arc_destructor_fn
```

### `lf_arc_guard_handle`

```nim
lf_arc_guard_handle {.exportc: "lf_arc_guard_t".} = object
  raw*: ArcGuard[pointer]
```

### `lf_arc_guard_t`

```nim
lf_arc_guard_t = lf_arc_guard_handle
```

### `lfq_arc_guard_handle`

```nim
lfq_arc_guard_handle = lf_arc_guard_handle
```

### `lfq_arc_guard_t`

```nim
lfq_arc_guard_t = lf_arc_guard_handle
```

### `lf_atomic_arc_handle`

```nim
lf_atomic_arc_handle {.exportc: "lf_atomic_arc_t".} = object
  raw*: AtomicArc[pointer]
```

### `lf_atomic_arc_t`

```nim
lf_atomic_arc_t = lf_atomic_arc_handle
```

### `lfq_atomic_arc_handle`

```nim
lfq_atomic_arc_handle = lf_atomic_arc_handle
```

### `lfq_atomic_arc_t`

```nim
lfq_atomic_arc_t = lf_atomic_arc_handle
```

### `lf_pqueue_destructor_fn`

```nim
lf_pqueue_destructor_fn = proc (item: pointer; user_data: pointer) {.cdecl,
    gcsafe.}
```

### `lfq_pqueue_destructor_fn`

```nim
lfq_pqueue_destructor_fn = lf_pqueue_destructor_fn
```

### `lf_pqueue_t`

```nim
lf_pqueue_t = object
```

### `lfq_pqueue_t`

```nim
lfq_pqueue_t = lf_pqueue_t
```

### `lf_flat_combiner_op_fn`

```nim
lf_flat_combiner_op_fn = proc (state: pointer; op_arg: pointer;
                               user_data: pointer): pointer {.cdecl, gcsafe.}
```

### `lfq_flat_combiner_op_fn`

```nim
lfq_flat_combiner_op_fn = lf_flat_combiner_op_fn
```

### `lf_flat_combiner_state_destructor_fn`

```nim
lf_flat_combiner_state_destructor_fn = proc (state: pointer; user_data: pointer) {.
    cdecl, gcsafe.}
```

### `lfq_flat_combiner_state_destructor_fn`

```nim
lfq_flat_combiner_state_destructor_fn = lf_flat_combiner_state_destructor_fn
```

### `lf_flat_combiner`

```nim
lf_flat_combiner {.exportc: "lf_flat_combiner_t".} = object
  defaultOpFn*: lf_flat_combiner_op_fn
  stateDestructor*: lf_flat_combiner_state_destructor_fn
  userData*: pointer
  raw*: FlatCombiner[pointer, pointer, pointer]
```

### `lf_flat_combiner_t`

```nim
lf_flat_combiner_t = lf_flat_combiner
```

### `lfq_flat_combiner`

```nim
lfq_flat_combiner = lf_flat_combiner
```

### `lfq_flat_combiner_t`

```nim
lfq_flat_combiner_t = lf_flat_combiner
```

### `lf_bstack`

```nim
lf_bstack {.exportc: "lf_bstack_t".} = object
  destructor*: lf_item_destructor_fn
  userData*: pointer
  destroyFn*: proc (s: ptr lf_bstack_t): lf_status_t {.nimcall, gcsafe,
      raises: [].}
  pushFn*: proc (s: ptr lf_bstack_t; item: pointer): lf_status_t {.nimcall,
      gcsafe, raises: [].}
  popFn*: proc (s: ptr lf_bstack_t; outItem: ptr pointer): lf_status_t {.
      nimcall, gcsafe, raises: [].}
  peekFn*: proc (s: ptr lf_bstack_t; outItem: ptr pointer): lf_status_t {.
      nimcall, gcsafe, raises: [].}
  clearFn*: proc (s: ptr lf_bstack_t): lf_status_t {.nimcall, gcsafe, raises: [].}
  lenFn*: proc (s: ptr lf_bstack_t): csize_t {.nimcall, gcsafe, raises: [].}
  capFn*: proc (s: ptr lf_bstack_t): csize_t {.nimcall, gcsafe, raises: [].}
  isEmptyFn*: proc (s: ptr lf_bstack_t): bool {.nimcall, gcsafe, raises: [].}
  isFullFn*: proc (s: ptr lf_bstack_t): bool {.nimcall, gcsafe, raises: [].}
```

### `lf_bstack_t`

```nim
lf_bstack_t = lf_bstack
```

### `lfq_bstack`

```nim
lfq_bstack = lf_bstack
```

### `lfq_bstack_t`

```nim
lfq_bstack_t = lf_bstack
```

### `lf_bpqueue`

```nim
lf_bpqueue {.exportc: "lf_bpqueue_t".} = object
  destructor*: lf_item_destructor_fn
  userData*: pointer
  destroyFn*: proc (pq: ptr lf_bpqueue_t): lf_status_t {.nimcall, gcsafe,
      raises: [].}
  pushFn*: proc (pq: ptr lf_bpqueue_t; priority: int64; item: pointer): lf_status_t {.
      nimcall, gcsafe, raises: [].}
  popMinFn*: proc (pq: ptr lf_bpqueue_t; outPriority: ptr int64;
                   outItem: ptr pointer): lf_status_t {.nimcall, gcsafe,
      raises: [].}
  peekMinFn*: proc (pq: ptr lf_bpqueue_t; outPriority: ptr int64;
                    outItem: ptr pointer): lf_status_t {.nimcall, gcsafe,
      raises: [].}
  clearFn*: proc (pq: ptr lf_bpqueue_t): lf_status_t {.nimcall, gcsafe,
      raises: [].}
  lenFn*: proc (pq: ptr lf_bpqueue_t): csize_t {.nimcall, gcsafe, raises: [].}
  capFn*: proc (pq: ptr lf_bpqueue_t): csize_t {.nimcall, gcsafe, raises: [].}
  isEmptyFn*: proc (pq: ptr lf_bpqueue_t): bool {.nimcall, gcsafe, raises: [].}
  isFullFn*: proc (pq: ptr lf_bpqueue_t): bool {.nimcall, gcsafe, raises: [].}
```

### `lf_bpqueue_t`

```nim
lf_bpqueue_t = lf_bpqueue
```

### `lfq_bpqueue`

```nim
lfq_bpqueue = lf_bpqueue
```

### `lfq_bpqueue_t`

```nim
lfq_bpqueue_t = lf_bpqueue
```

### `lf_btable_destructor_fn`

```nim
lf_btable_destructor_fn = proc (key: pointer; val: pointer; userData: pointer) {.
    cdecl, gcsafe.}
```

### `lfq_btable_destructor_fn`

```nim
lfq_btable_destructor_fn = lf_btable_destructor_fn
```

### `lf_btable_mapping_fn`

```nim
lf_btable_mapping_fn = proc (key: pointer; userData: pointer): pointer {.cdecl,
    gcsafe.}
```

### `lfq_btable_mapping_fn`

```nim
lfq_btable_mapping_fn = lf_btable_mapping_fn
```

### `lf_map_compute_fn`

```nim
lf_map_compute_fn = lf_btable_mapping_fn
```

### `lfq_map_compute_fn`

```nim
lfq_map_compute_fn = lf_btable_mapping_fn
```

### `lf_btable_update_fn`

```nim
lf_btable_update_fn = proc (key: pointer; oldVal: pointer; userData: pointer): pointer {.
    cdecl, gcsafe.}
```

### `lfq_btable_update_fn`

```nim
lfq_btable_update_fn = lf_btable_update_fn
```

### `lf_map_merge_fn`

```nim
lf_map_merge_fn = lf_btable_update_fn
```

### `lfq_map_merge_fn`

```nim
lfq_map_merge_fn = lf_btable_update_fn
```

### `lf_btable`

```nim
lf_btable {.exportc: "lf_btable_t".} = object
  destructor*: lf_btable_destructor_fn
  userData*: pointer
  destroyFn*: proc (t: ptr lf_btable_t): lf_status_t {.nimcall, gcsafe,
      raises: [].}
  putFn*: proc (t: ptr lf_btable_t; key: pointer; val: pointer;
                outInserted: ptr bool): lf_status_t {.nimcall, gcsafe,
      raises: [].}
  insertFn*: proc (t: ptr lf_btable_t; key: pointer; val: pointer;
                   outInserted: ptr bool): lf_status_t {.nimcall, gcsafe,
      raises: [].}
  getFn*: proc (t: ptr lf_btable_t; key: pointer; outVal: ptr pointer): lf_status_t {.
      nimcall, gcsafe, raises: [].}
  deleteFn*: proc (t: ptr lf_btable_t; key: pointer; outDeleted: ptr bool): lf_status_t {.
      nimcall, gcsafe, raises: [].}
  takeFn*: proc (t: ptr lf_btable_t; key: pointer; outVal: ptr pointer): lf_status_t {.
      nimcall, gcsafe, raises: [].}
  containsFn*: proc (t: ptr lf_btable_t; key: pointer): bool {.nimcall, gcsafe,
      raises: [].}
  computeIfAbsentFn*: proc (t: ptr lf_btable_t; key: pointer;
                            mappingFn: lf_btable_mapping_fn; userData: pointer;
                            outVal: ptr pointer): lf_status_t {.nimcall, gcsafe,
      raises: [].}
  atomicUpdateFn*: proc (t: ptr lf_btable_t; key: pointer;
                         updateFn: lf_btable_update_fn; userData: pointer;
                         outVal: ptr pointer): lf_status_t {.nimcall, gcsafe,
      raises: [].}
  upsertFn*: proc (t: ptr lf_btable_t; key: pointer; initialVal: pointer;
                   updateFn: lf_btable_update_fn; userData: pointer;
                   outVal: ptr pointer): lf_status_t {.nimcall, gcsafe,
      raises: [].}
  clearFn*: proc (t: ptr lf_btable_t): lf_status_t {.nimcall, gcsafe, raises: [].}
  lenFn*: proc (t: ptr lf_btable_t): csize_t {.nimcall, gcsafe, raises: [].}
  capFn*: proc (t: ptr lf_btable_t): csize_t {.nimcall, gcsafe, raises: [].}
  isEmptyFn*: proc (t: ptr lf_btable_t): bool {.nimcall, gcsafe, raises: [].}
  isFullFn*: proc (t: ptr lf_btable_t): bool {.nimcall, gcsafe, raises: [].}
```

### `lf_btable_t`

```nim
lf_btable_t = lf_btable
```

### `lfq_btable`

```nim
lfq_btable = lf_btable
```

### `lfq_btable_t`

```nim
lfq_btable_t = lf_btable
```

### `lf_bqueue128_destructor_fn`

```nim
lf_bqueue128_destructor_fn = proc (item: pointer; userData: pointer) {.cdecl,
    gcsafe, raises: [].}
```

### `lfq_bqueue128_destructor_fn`

```nim
lfq_bqueue128_destructor_fn = lf_bqueue128_destructor_fn
```

### `lf_bqueue128_t`

```nim
lf_bqueue128_t = object
  destructor*: lf_bqueue128_destructor_fn
  userData*: pointer
  destroyFn*: proc (q: ptr lf_bqueue128_t): lf_status_t {.nimcall, gcsafe,
      raises: [].}
  pushFn*: proc (q: ptr lf_bqueue128_t; item: pointer): lf_status_t {.nimcall,
      gcsafe, raises: [].}
  popFn*: proc (q: ptr lf_bqueue128_t; outItem: ptr pointer): lf_status_t {.
      nimcall, gcsafe, raises: [].}
  peekFn*: proc (q: ptr lf_bqueue128_t; outItem: ptr pointer): lf_status_t {.
      nimcall, gcsafe, raises: [].}
  clearFn*: proc (q: ptr lf_bqueue128_t): lf_status_t {.nimcall, gcsafe,
      raises: [].}
  lenFn*: proc (q: ptr lf_bqueue128_t): csize_t {.nimcall, gcsafe, raises: [].}
  capFn*: proc (q: ptr lf_bqueue128_t): csize_t {.nimcall, gcsafe, raises: [].}
  isEmptyFn*: proc (q: ptr lf_bqueue128_t): bool {.nimcall, gcsafe, raises: [].}
  isFullFn*: proc (q: ptr lf_bqueue128_t): bool {.nimcall, gcsafe, raises: [].}
```

### `lfq_bqueue128_t`

```nim
lfq_bqueue128_t = lf_bqueue128_t
```


## Constants

### `LFQ_ERR_PANIC`

```nim
LFQ_ERR_PANIC = LF_ERR_PANIC
```

### `LFQ_ERR_FAILURE`

```nim
LFQ_ERR_FAILURE = LF_ERR_FAILURE
```

### `LFQ_OK`

```nim
LFQ_OK = LF_OK
```

### `LFQ_ERR_EMPTY`

```nim
LFQ_ERR_EMPTY = LF_ERR_EMPTY
```

### `LFQ_ERR_FULL`

```nim
LFQ_ERR_FULL = LF_ERR_FULL
```

### `LFQ_ERR_CLOSED`

```nim
LFQ_ERR_CLOSED = LF_ERR_CLOSED
```

### `LFQ_ERR_INVALID_ARG`

```nim
LFQ_ERR_INVALID_ARG = LF_ERR_INVALID_ARG
```

### `LFQ_ERR_REGISTRY_FULL`

```nim
LFQ_ERR_REGISTRY_FULL = LF_ERR_REGISTRY_FULL
```

### `LFQ_ERR_UNSUPPORTED`

```nim
LFQ_ERR_UNSUPPORTED = LF_ERR_UNSUPPORTED
```

### `LFQ_OVERFLOW_DROP_OLDEST`

```nim
LFQ_OVERFLOW_DROP_OLDEST = LF_OVERFLOW_DROP_OLDEST
```

### `LFQ_OVERFLOW_BACKOFF`

```nim
LFQ_OVERFLOW_BACKOFF = LF_OVERFLOW_BACKOFF
```

### `LFQ_SUB_FROM_LATEST`

```nim
LFQ_SUB_FROM_LATEST = LF_SUB_FROM_LATEST
```

### `LFQ_SUB_FROM_EARLIEST`

```nim
LFQ_SUB_FROM_EARLIEST = LF_SUB_FROM_EARLIEST
```

### `LFQ_POLL_SUCCESS`

```nim
LFQ_POLL_SUCCESS = LF_POLL_SUCCESS
```

### `LFQ_POLL_EMPTY`

```nim
LFQ_POLL_EMPTY = LF_POLL_EMPTY
```

### `LFQ_POLL_LAGGED`

```nim
LFQ_POLL_LAGGED = LF_POLL_LAGGED
```


## Procedures & Functions

### `lf_unbounded_mpmc_create`

```nim
proc lf_unbounded_mpmc_create(segment_size: csize_t; max_threads: csize_t;
                              destructor: lf_item_destructor_fn;
                              user_data: pointer; out_queue: ptr ptr lf_queue_t): lf_status_t {.
    exportc: "lf_unbounded_mpmc_create", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lf_bounded_mpmc_create`

```nim
proc lf_bounded_mpmc_create(capacity: csize_t; max_producers: csize_t;
                            max_consumers: csize_t;
                            destructor: lf_item_destructor_fn;
                            user_data: pointer; out_queue: ptr ptr lf_queue_t): lf_status_t {.
    exportc: "lf_bounded_mpmc_create", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_queue_close`

```nim
proc lf_queue_close(queue: ptr lf_queue_t): lf_status_t {.
    exportc: "lf_queue_close", cdecl, gcsafe, raises: [], tags: [], forbids: [].}
```

### `lf_queue_destroy`

```nim
proc lf_queue_destroy(queue: ptr lf_queue_t): lf_status_t {.
    exportc: "lf_queue_destroy", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lf_producer_acquire`

```nim
proc lf_producer_acquire(queue: ptr lf_queue_t; out_prod: ptr ptr lf_producer_t): lf_status_t {.
    exportc: "lf_producer_acquire", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lf_producer_release`

```nim
proc lf_producer_release(prod: ptr lf_producer_t): lf_status_t {.
    exportc: "lf_producer_release", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lf_consumer_acquire`

```nim
proc lf_consumer_acquire(queue: ptr lf_queue_t; out_cons: ptr ptr lf_consumer_t): lf_status_t {.
    exportc: "lf_consumer_acquire", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lf_consumer_release`

```nim
proc lf_consumer_release(cons: ptr lf_consumer_t): lf_status_t {.
    exportc: "lf_consumer_release", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lf_push`

```nim
proc lf_push(prod: ptr lf_producer_t; item: pointer): lf_status_t {.
    exportc: "lf_push", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lf_pop`

```nim
proc lf_pop(cons: ptr lf_consumer_t; out_item: ptr pointer): lf_status_t {.
    exportc: "lf_pop", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lf_pop_batch`

```nim
proc lf_pop_batch(cons: ptr lf_consumer_t; out_items: ptr pointer;
                  max_count: csize_t): csize_t {.exportc: "lf_pop_batch", cdecl,
    gcsafe, raises: [], tags: [RootEffect], forbids: [].}
```

### `lf_queue_len`

```nim
proc lf_queue_len(queue: ptr lf_queue_t): csize_t {.exportc: "lf_queue_len",
    cdecl, gcsafe, raises: [], tags: [RootEffect], forbids: [].}
```

### `lf_queue_is_empty`

```nim
proc lf_queue_is_empty(queue: ptr lf_queue_t): bool {.
    exportc: "lf_queue_is_empty", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lf_queue_is_closed`

```nim
proc lf_queue_is_closed(queue: ptr lf_queue_t): bool {.
    exportc: "lf_queue_is_closed", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_queue_push`

```nim
proc lf_queue_push(prod: ptr lf_producer_t; item: pointer): lf_status_t {.
    exportc: "lf_queue_push", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lf_queue_pop`

```nim
proc lf_queue_pop(cons: ptr lf_consumer_t; out_item: ptr pointer): lf_status_t {.
    exportc: "lf_queue_pop", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lf_stack_create`

```nim
proc lf_stack_create(destructor: lf_item_destructor_fn; user_data: pointer;
                     out_stack: ptr ptr lf_stack_t): lf_status_t {.
    exportc: "lf_stack_create", cdecl, gcsafe, raises: [], tags: [], forbids: [].}
```

### `lf_stack_destroy`

```nim
proc lf_stack_destroy(stack: ptr lf_stack_t): lf_status_t {.
    exportc: "lf_stack_destroy", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lf_stack_push`

```nim
proc lf_stack_push(stack: ptr lf_stack_t; item: pointer): lf_status_t {.
    exportc: "lf_stack_push", cdecl, gcsafe, raises: [], tags: [], forbids: [].}
```

### `lf_stack_pop`

```nim
proc lf_stack_pop(stack: ptr lf_stack_t; out_item: ptr pointer): lf_status_t {.
    exportc: "lf_stack_pop", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lf_stack_peek`

```nim
proc lf_stack_peek(stack: ptr lf_stack_t; out_item: ptr pointer): lf_status_t {.
    exportc: "lf_stack_peek", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lf_stack_drain`

```nim
proc lf_stack_drain(stack: ptr lf_stack_t; out_items: ptr pointer;
                    max_count: csize_t): csize_t {.exportc: "lf_stack_drain",
    cdecl, gcsafe, raises: [], tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lf_stack_len`

```nim
proc lf_stack_len(stack: ptr lf_stack_t): csize_t {.exportc: "lf_stack_len",
    cdecl, gcsafe, raises: [], tags: [], forbids: [].}
```

### `lf_stack_is_empty`

```nim
proc lf_stack_is_empty(stack: ptr lf_stack_t): bool {.
    exportc: "lf_stack_is_empty", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_deque_create`

```nim
proc lf_deque_create(initial_capacity: csize_t;
                     destructor: lf_item_destructor_fn; user_data: pointer;
                     out_deque: ptr ptr lf_deque_t): lf_status_t {.
    exportc: "lf_deque_create", cdecl, gcsafe, raises: [], tags: [], forbids: [].}
```

### `lf_deque_destroy`

```nim
proc lf_deque_destroy(deque: ptr lf_deque_t): lf_status_t {.
    exportc: "lf_deque_destroy", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lf_deque_push`

```nim
proc lf_deque_push(deque: ptr lf_deque_t; item: pointer): lf_status_t {.
    exportc: "lf_deque_push", cdecl, gcsafe, raises: [], tags: [], forbids: [].}
```

### `lf_deque_pop`

```nim
proc lf_deque_pop(deque: ptr lf_deque_t; out_item: ptr pointer): lf_status_t {.
    exportc: "lf_deque_pop", cdecl, gcsafe, raises: [], tags: [], forbids: [].}
```

### `lf_deque_steal`

```nim
proc lf_deque_steal(deque: ptr lf_deque_t; out_item: ptr pointer): lf_status_t {.
    exportc: "lf_deque_steal", cdecl, gcsafe, raises: [], tags: [], forbids: [].}
```

### `lf_deque_steal_batch`

```nim
proc lf_deque_steal_batch(deque: ptr lf_deque_t; out_items: ptr pointer;
                          max_count: csize_t): csize_t {.
    exportc: "lf_deque_steal_batch", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_deque_len`

```nim
proc lf_deque_len(deque: ptr lf_deque_t): csize_t {.exportc: "lf_deque_len",
    cdecl, gcsafe, raises: [], tags: [], forbids: [].}
```

### `lf_deque_capacity`

```nim
proc lf_deque_capacity(deque: ptr lf_deque_t): csize_t {.
    exportc: "lf_deque_capacity", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_deque_is_empty`

```nim
proc lf_deque_is_empty(deque: ptr lf_deque_t): bool {.
    exportc: "lf_deque_is_empty", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_table_create`

```nim
proc lf_table_create(destructor: lf_entry_destructor_fn; user_data: pointer;
                     out_table: ptr ptr lf_table_t): lf_status_t {.
    exportc: "lf_table_create", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lf_table_destroy`

```nim
proc lf_table_destroy(table: ptr lf_table_t): lf_status_t {.
    exportc: "lf_table_destroy", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lf_table_put`

```nim
proc lf_table_put(table: ptr lf_table_t; key: pointer; val: pointer;
                  out_inserted: ptr bool): lf_status_t {.
    exportc: "lf_table_put", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lf_table_get`

```nim
proc lf_table_get(table: ptr lf_table_t; key: pointer; out_val: ptr pointer): lf_status_t {.
    exportc: "lf_table_get", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lf_table_delete`

```nim
proc lf_table_delete(table: ptr lf_table_t; key: pointer; out_deleted: ptr bool): lf_status_t {.
    exportc: "lf_table_delete", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lf_table_remove`

```nim
proc lf_table_remove(table: ptr lf_table_t; key: pointer; out_removed: ptr bool): lf_status_t {.
    exportc: "lf_table_remove", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lf_table_contains`

```nim
proc lf_table_contains(table: ptr lf_table_t; key: pointer): bool {.
    exportc: "lf_table_contains", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lf_table_len`

```nim
proc lf_table_len(table: ptr lf_table_t): csize_t {.exportc: "lf_table_len",
    cdecl, gcsafe, raises: [], tags: [], forbids: [].}
```

### `lf_table_is_empty`

```nim
proc lf_table_is_empty(table: ptr lf_table_t): bool {.
    exportc: "lf_table_is_empty", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_set_create`

```nim
proc lf_set_create(destructor: lf_item_destructor_fn; user_data: pointer;
                   out_set: ptr ptr lf_set_t): lf_status_t {.
    exportc: "lf_set_create", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lf_set_destroy`

```nim
proc lf_set_destroy(set: ptr lf_set_t): lf_status_t {.exportc: "lf_set_destroy",
    cdecl, gcsafe, raises: [], tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lf_set_insert`

```nim
proc lf_set_insert(set: ptr lf_set_t; item: pointer; out_inserted: ptr bool): lf_status_t {.
    exportc: "lf_set_insert", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lf_set_remove`

```nim
proc lf_set_remove(set: ptr lf_set_t; item: pointer; out_removed: ptr bool): lf_status_t {.
    exportc: "lf_set_remove", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lf_set_contains`

```nim
proc lf_set_contains(set: ptr lf_set_t; item: pointer): bool {.
    exportc: "lf_set_contains", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lf_set_len`

```nim
proc lf_set_len(set: ptr lf_set_t): csize_t {.exportc: "lf_set_len", cdecl,
    gcsafe, raises: [], tags: [], forbids: [].}
```

### `lf_set_is_empty`

```nim
proc lf_set_is_empty(set: ptr lf_set_t): bool {.exportc: "lf_set_is_empty",
    cdecl, gcsafe, raises: [], tags: [], forbids: [].}
```

### `lf_taskpool_create`

```nim
proc lf_taskpool_create(num_threads: csize_t; out_pool: ptr ptr lf_taskpool_t): lf_status_t {.
    exportc: "lf_taskpool_create", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_taskpool_destroy`

```nim
proc lf_taskpool_destroy(pool: ptr lf_taskpool_t): lf_status_t {.
    exportc: "lf_taskpool_destroy", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lf_taskpool_spawn`

```nim
proc lf_taskpool_spawn(pool: ptr lf_taskpool_t; task: lf_task_fn; arg: pointer): lf_status_t {.
    exportc: "lf_taskpool_spawn", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lf_taskpool_parallel_for`

```nim
proc lf_taskpool_parallel_for(pool: ptr lf_taskpool_t; start: csize_t;
                              stop: csize_t; task: lf_for_task_fn; arg: pointer;
                              chunk_size: csize_t): lf_status_t {.
    exportc: "lf_taskpool_parallel_for", cdecl, gcsafe, raises: [],
    tags: [RootEffect, TypestateOp], forbids: [].}
```

### `lf_taskpool_sync`

```nim
proc lf_taskpool_sync(pool: ptr lf_taskpool_t): lf_status_t {.
    exportc: "lf_taskpool_sync", cdecl, gcsafe, raises: [],
    tags: [RootEffect, TypestateOp], forbids: [].}
```

### `lf_taskpool_num_workers`

```nim
proc lf_taskpool_num_workers(pool: ptr lf_taskpool_t): csize_t {.
    exportc: "lf_taskpool_num_workers", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_ctrie_create`

```nim
proc lf_ctrie_create(destructor: lf_entry_destructor_fn; user_data: pointer;
                     out_ctrie: ptr ptr lf_ctrie_t): lf_status_t {.
    exportc: "lf_ctrie_create", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lf_ctrie_destroy`

```nim
proc lf_ctrie_destroy(ctrie: ptr lf_ctrie_t): lf_status_t {.
    exportc: "lf_ctrie_destroy", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lf_ctrie_insert`

```nim
proc lf_ctrie_insert(ctrie: ptr lf_ctrie_t; key: pointer; val: pointer;
                     out_inserted: ptr bool): lf_status_t {.
    exportc: "lf_ctrie_insert", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lf_ctrie_put`

```nim
proc lf_ctrie_put(ctrie: ptr lf_ctrie_t; key: pointer; val: pointer;
                  out_inserted: ptr bool): lf_status_t {.
    exportc: "lf_ctrie_put", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lf_ctrie_lookup`

```nim
proc lf_ctrie_lookup(ctrie: ptr lf_ctrie_t; key: pointer; out_val: ptr pointer): lf_status_t {.
    exportc: "lf_ctrie_lookup", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lf_ctrie_get`

```nim
proc lf_ctrie_get(ctrie: ptr lf_ctrie_t; key: pointer; out_val: ptr pointer): lf_status_t {.
    exportc: "lf_ctrie_get", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lf_ctrie_remove`

```nim
proc lf_ctrie_remove(ctrie: ptr lf_ctrie_t; key: pointer; out_removed: ptr bool): lf_status_t {.
    exportc: "lf_ctrie_remove", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lf_ctrie_delete`

```nim
proc lf_ctrie_delete(ctrie: ptr lf_ctrie_t; key: pointer; out_deleted: ptr bool): lf_status_t {.
    exportc: "lf_ctrie_delete", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lf_ctrie_contains`

```nim
proc lf_ctrie_contains(ctrie: ptr lf_ctrie_t; key: pointer): bool {.
    exportc: "lf_ctrie_contains", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lf_ctrie_len`

```nim
proc lf_ctrie_len(ctrie: ptr lf_ctrie_t): csize_t {.exportc: "lf_ctrie_len",
    cdecl, gcsafe, raises: [], tags: [], forbids: [].}
```

### `lf_ctrie_is_empty`

```nim
proc lf_ctrie_is_empty(ctrie: ptr lf_ctrie_t): bool {.
    exportc: "lf_ctrie_is_empty", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_ctrie_snapshot`

```nim
proc lf_ctrie_snapshot(ctrie: ptr lf_ctrie_t;
                       out_snapshot: ptr ptr lf_ctrie_snapshot_t): lf_status_t {.
    exportc: "lf_ctrie_snapshot", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lf_ctrie_snapshot_create`

```nim
proc lf_ctrie_snapshot_create(ctrie: ptr lf_ctrie_t;
                              out_snapshot: ptr ptr lf_ctrie_snapshot_t): lf_status_t {.
    exportc: "lf_ctrie_snapshot_create", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lf_ctrie_snapshot_destroy`

```nim
proc lf_ctrie_snapshot_destroy(snapshot: ptr lf_ctrie_snapshot_t): lf_status_t {.
    exportc: "lf_ctrie_snapshot_destroy", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_ctrie_snapshot_lookup`

```nim
proc lf_ctrie_snapshot_lookup(snapshot: ptr lf_ctrie_snapshot_t; key: pointer;
                              out_val: ptr pointer): lf_status_t {.
    exportc: "lf_ctrie_snapshot_lookup", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lf_ctrie_snapshot_get`

```nim
proc lf_ctrie_snapshot_get(snapshot: ptr lf_ctrie_snapshot_t; key: pointer;
                           out_val: ptr pointer): lf_status_t {.
    exportc: "lf_ctrie_snapshot_get", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lf_ctrie_snapshot_contains`

```nim
proc lf_ctrie_snapshot_contains(snapshot: ptr lf_ctrie_snapshot_t; key: pointer): bool {.
    exportc: "lf_ctrie_snapshot_contains", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lf_ctrie_snapshot_len`

```nim
proc lf_ctrie_snapshot_len(snapshot: ptr lf_ctrie_snapshot_t): csize_t {.
    exportc: "lf_ctrie_snapshot_len", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lf_ctrie_snapshot_is_empty`

```nim
proc lf_ctrie_snapshot_is_empty(snapshot: ptr lf_ctrie_snapshot_t): bool {.
    exportc: "lf_ctrie_snapshot_is_empty", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lf_broadcast_create`

```nim
proc lf_broadcast_create(capacity: csize_t; overflow_mode: lf_overflow_mode_t;
                         max_readers: csize_t;
                         out_broadcast: ptr ptr lf_broadcast_t): lf_status_t {.
    exportc: "lf_broadcast_create", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_broadcast_destroy`

```nim
proc lf_broadcast_destroy(broadcast: ptr lf_broadcast_t): lf_status_t {.
    exportc: "lf_broadcast_destroy", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_broadcast_publish`

```nim
proc lf_broadcast_publish(broadcast: ptr lf_broadcast_t; item: pointer): lf_status_t {.
    exportc: "lf_broadcast_publish", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_broadcast_subscribe`

```nim
proc lf_broadcast_subscribe(broadcast: ptr lf_broadcast_t;
                            origin: lf_sub_origin_t;
                            out_cursor: ptr ptr lf_broadcast_cursor_t): lf_status_t {.
    exportc: "lf_broadcast_subscribe", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_broadcast_unsubscribe`

```nim
proc lf_broadcast_unsubscribe(cursor: ptr lf_broadcast_cursor_t): lf_status_t {.
    exportc: "lf_broadcast_unsubscribe", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_broadcast_poll`

```nim
proc lf_broadcast_poll(cursor: ptr lf_broadcast_cursor_t; out_item: ptr pointer;
                       out_skipped_count: ptr csize_t;
                       out_result: ptr lf_poll_result_t): lf_status_t {.
    exportc: "lf_broadcast_poll", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_broadcast_try_read`

```nim
proc lf_broadcast_try_read(cursor: ptr lf_broadcast_cursor_t;
                           out_item: ptr pointer): lf_status_t {.
    exportc: "lf_broadcast_try_read", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_broadcast_len`

```nim
proc lf_broadcast_len(broadcast: ptr lf_broadcast_t): csize_t {.
    exportc: "lf_broadcast_len", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_broadcast_capacity`

```nim
proc lf_broadcast_capacity(broadcast: ptr lf_broadcast_t): csize_t {.
    exportc: "lf_broadcast_capacity", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_broadcast_subscriber_count`

```nim
proc lf_broadcast_subscriber_count(broadcast: ptr lf_broadcast_t): csize_t {.
    exportc: "lf_broadcast_subscriber_count", cdecl, gcsafe, raises: [],
    tags: [], forbids: [].}
```

### `lf_broadcast_is_empty`

```nim
proc lf_broadcast_is_empty(broadcast: ptr lf_broadcast_t): bool {.
    exportc: "lf_broadcast_is_empty", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_broadcast_cursor_lag`

```nim
proc lf_broadcast_cursor_lag(cursor: ptr lf_broadcast_cursor_t): csize_t {.
    exportc: "lf_broadcast_cursor_lag", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_topic_bus_create`

```nim
proc lf_topic_bus_create(default_capacity: csize_t;
                         default_overflow_mode: lf_overflow_mode_t;
                         default_max_readers: csize_t;
                         out_bus: ptr ptr lf_topic_bus_t): lf_status_t {.
    exportc: "lf_topic_bus_create", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lf_topic_bus_destroy`

```nim
proc lf_topic_bus_destroy(bus: ptr lf_topic_bus_t): lf_status_t {.
    exportc: "lf_topic_bus_destroy", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_topic_bus_publish`

```nim
proc lf_topic_bus_publish(bus: ptr lf_topic_bus_t; topic: cstring; item: pointer): lf_status_t {.
    exportc: "lf_topic_bus_publish", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lf_topic_bus_subscribe`

```nim
proc lf_topic_bus_subscribe(bus: ptr lf_topic_bus_t; topic: cstring;
                            origin: lf_sub_origin_t;
                            out_cursor: ptr ptr lf_broadcast_cursor_t): lf_status_t {.
    exportc: "lf_topic_bus_subscribe", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lf_topic_bus_topic_count`

```nim
proc lf_topic_bus_topic_count(bus: ptr lf_topic_bus_t): csize_t {.
    exportc: "lf_topic_bus_topic_count", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_topic_bus_has_topic`

```nim
proc lf_topic_bus_has_topic(bus: ptr lf_topic_bus_t; topic: cstring): bool {.
    exportc: "lf_topic_bus_has_topic", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lf_rendezvous_create`

```nim
proc lf_rendezvous_create(out_chan: ptr ptr lf_rendezvous_t): lf_status_t {.
    exportc: "lf_rendezvous_create", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_rendezvous_destroy`

```nim
proc lf_rendezvous_destroy(chan: ptr lf_rendezvous_t): lf_status_t {.
    exportc: "lf_rendezvous_destroy", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_rendezvous_close`

```nim
proc lf_rendezvous_close(chan: ptr lf_rendezvous_t): lf_status_t {.
    exportc: "lf_rendezvous_close", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lf_rendezvous_is_closed`

```nim
proc lf_rendezvous_is_closed(chan: ptr lf_rendezvous_t): bool {.
    exportc: "lf_rendezvous_is_closed", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_rendezvous_send`

```nim
proc lf_rendezvous_send(chan: ptr lf_rendezvous_t; payload: pointer;
                        out_corr_id: ptr uint64): lf_status_t {.
    exportc: "lf_rendezvous_send", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lf_rendezvous_recv`

```nim
proc lf_rendezvous_recv(chan: ptr lf_rendezvous_t; out_payload: ptr pointer;
                        out_corr_id: ptr uint64): lf_status_t {.
    exportc: "lf_rendezvous_recv", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lf_rendezvous_try_send`

```nim
proc lf_rendezvous_try_send(chan: ptr lf_rendezvous_t; payload: pointer;
                            out_corr_id: ptr uint64): lf_status_t {.
    exportc: "lf_rendezvous_try_send", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lf_rendezvous_try_recv`

```nim
proc lf_rendezvous_try_recv(chan: ptr lf_rendezvous_t; out_payload: ptr pointer;
                            out_corr_id: ptr uint64): lf_status_t {.
    exportc: "lf_rendezvous_try_recv", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lf_rendezvous_send_timeout`

```nim
proc lf_rendezvous_send_timeout(chan: ptr lf_rendezvous_t; payload: pointer;
                                timeout_ms: int32; out_corr_id: ptr uint64): lf_status_t {.
    exportc: "lf_rendezvous_send_timeout", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lf_rendezvous_recv_timeout`

```nim
proc lf_rendezvous_recv_timeout(chan: ptr lf_rendezvous_t;
                                out_payload: ptr pointer; timeout_ms: int32;
                                out_corr_id: ptr uint64): lf_status_t {.
    exportc: "lf_rendezvous_recv_timeout", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lf_token_bucket_init`

```nim
proc lf_token_bucket_init(bucket: ptr lf_token_bucket_t; capacity: uint64;
                          refill_rate: uint64): cint {.
    exportc: "lf_token_bucket_init", cdecl, gcsafe, raises: [],
    tags: [TimeEffect], forbids: [].}
```

### `lfq_token_bucket_init`

```nim
proc lfq_token_bucket_init(bucket: ptr lf_token_bucket_t; capacity: uint64;
                           refill_rate: uint64): cint {.
    exportc: "lfq_token_bucket_init", cdecl, gcsafe, raises: [],
    tags: [TimeEffect], forbids: [].}
```

### `lf_token_bucket_create`

```nim
proc lf_token_bucket_create(capacity: uint64; refill_rate: uint64): ptr lf_token_bucket_t {.
    exportc: "lf_token_bucket_create", cdecl, gcsafe, raises: [],
    tags: [TimeEffect], forbids: [].}
```

### `lf_token_bucket_destroy`

```nim
proc lf_token_bucket_destroy(bucket: ptr lf_token_bucket_t) {.
    exportc: "lf_token_bucket_destroy", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_token_bucket_reset`

```nim
proc lf_token_bucket_reset(bucket: ptr lf_token_bucket_t; tokens: uint64) {.
    exportc: "lf_token_bucket_reset", cdecl, gcsafe, raises: [],
    tags: [TimeEffect], forbids: [].}
```

### `lf_token_bucket_try_acquire`

```nim
proc lf_token_bucket_try_acquire(bucket: ptr lf_token_bucket_t; tokens: uint64): bool {.
    exportc: "lf_token_bucket_try_acquire", cdecl, gcsafe, raises: [],
    tags: [TimeEffect], forbids: [].}
```

### `lfq_token_bucket_try_acquire`

```nim
proc lfq_token_bucket_try_acquire(bucket: ptr lf_token_bucket_t; tokens: uint64): bool {.
    exportc: "lfq_token_bucket_try_acquire", cdecl, gcsafe, raises: [],
    tags: [TimeEffect], forbids: [].}
```

### `lf_token_bucket_acquire_timeout`

```nim
proc lf_token_bucket_acquire_timeout(bucket: ptr lf_token_bucket_t;
                                     tokens: uint64; timeout_ns: int64): bool {.
    exportc: "lf_token_bucket_acquire_timeout", cdecl, gcsafe, raises: [],
    tags: [TimeEffect], forbids: [].}
```

### `lfq_token_bucket_acquire_timeout`

```nim
proc lfq_token_bucket_acquire_timeout(bucket: ptr lf_token_bucket_t;
                                      tokens: uint64; timeout_ns: int64): bool {.
    exportc: "lfq_token_bucket_acquire_timeout", cdecl, gcsafe, raises: [],
    tags: [TimeEffect], forbids: [].}
```

### `lf_token_bucket_available`

```nim
proc lf_token_bucket_available(bucket: ptr lf_token_bucket_t): uint64 {.
    exportc: "lf_token_bucket_available", cdecl, gcsafe, raises: [],
    tags: [TimeEffect], forbids: [].}
```

### `lfq_token_bucket_available`

```nim
proc lfq_token_bucket_available(bucket: ptr lf_token_bucket_t): uint64 {.
    exportc: "lfq_token_bucket_available", cdecl, gcsafe, raises: [],
    tags: [TimeEffect], forbids: [].}
```

### `lf_leaky_bucket_init`

```nim
proc lf_leaky_bucket_init(bucket: ptr lf_leaky_bucket_t;
                          burst_tolerance_ns: uint64; leak_rate: uint64): cint {.
    exportc: "lf_leaky_bucket_init", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_leaky_bucket_init`

```nim
proc lfq_leaky_bucket_init(bucket: ptr lf_leaky_bucket_t;
                           burst_tolerance_ns: uint64; leak_rate: uint64): cint {.
    exportc: "lfq_leaky_bucket_init", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_leaky_bucket_create`

```nim
proc lf_leaky_bucket_create(burst_tolerance_ns: uint64; leak_rate: uint64): ptr lf_leaky_bucket_t {.
    exportc: "lf_leaky_bucket_create", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_leaky_bucket_destroy`

```nim
proc lf_leaky_bucket_destroy(bucket: ptr lf_leaky_bucket_t) {.
    exportc: "lf_leaky_bucket_destroy", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_leaky_bucket_reset`

```nim
proc lf_leaky_bucket_reset(bucket: ptr lf_leaky_bucket_t) {.
    exportc: "lf_leaky_bucket_reset", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_leaky_bucket_try_consume`

```nim
proc lf_leaky_bucket_try_consume(bucket: ptr lf_leaky_bucket_t; weight: uint64): bool {.
    exportc: "lf_leaky_bucket_try_consume", cdecl, gcsafe, raises: [],
    tags: [TimeEffect], forbids: [].}
```

### `lfq_leaky_bucket_try_consume`

```nim
proc lfq_leaky_bucket_try_consume(bucket: ptr lf_leaky_bucket_t; weight: uint64): bool {.
    exportc: "lfq_leaky_bucket_try_consume", cdecl, gcsafe, raises: [],
    tags: [TimeEffect], forbids: [].}
```

### `lf_leaky_bucket_consume_timeout`

```nim
proc lf_leaky_bucket_consume_timeout(bucket: ptr lf_leaky_bucket_t;
                                     weight: uint64; timeout_ns: int64): bool {.
    exportc: "lf_leaky_bucket_consume_timeout", cdecl, gcsafe, raises: [],
    tags: [TimeEffect], forbids: [].}
```

### `lfq_leaky_bucket_consume_timeout`

```nim
proc lfq_leaky_bucket_consume_timeout(bucket: ptr lf_leaky_bucket_t;
                                      weight: uint64; timeout_ns: int64): bool {.
    exportc: "lfq_leaky_bucket_consume_timeout", cdecl, gcsafe, raises: [],
    tags: [TimeEffect], forbids: [].}
```

### `lf_leaky_bucket_water_level`

```nim
proc lf_leaky_bucket_water_level(bucket: ptr lf_leaky_bucket_t): uint64 {.
    exportc: "lf_leaky_bucket_water_level", cdecl, gcsafe, raises: [],
    tags: [TimeEffect], forbids: [].}
```

### `lfq_leaky_bucket_water_level`

```nim
proc lfq_leaky_bucket_water_level(bucket: ptr lf_leaky_bucket_t): uint64 {.
    exportc: "lfq_leaky_bucket_water_level", cdecl, gcsafe, raises: [],
    tags: [TimeEffect], forbids: [].}
```

### `lf_stream_ring_create`

```nim
proc lf_stream_ring_create(capacity: csize_t; use_virtual_mirror: bool): ptr lf_stream_ring_t {.
    exportc: "lf_stream_ring_create", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_stream_ring_destroy`

```nim
proc lf_stream_ring_destroy(ring: ptr lf_stream_ring_t) {.
    exportc: "lf_stream_ring_destroy", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_streambuffer_create`

```nim
proc lf_streambuffer_create(capacity: csize_t; use_virtual_mirror: bool): ptr lf_streambuffer_t {.
    exportc: "lf_streambuffer_create", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_streambuffer_destroy`

```nim
proc lf_streambuffer_destroy(ring: ptr lf_streambuffer_t) {.
    exportc: "lf_streambuffer_destroy", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_stream_ring_capacity`

```nim
proc lf_stream_ring_capacity(ring: ptr lf_stream_ring_t): csize_t {.
    exportc: "lf_stream_ring_capacity", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_stream_ring_available_read`

```nim
proc lf_stream_ring_available_read(ring: ptr lf_stream_ring_t): csize_t {.
    exportc: "lf_stream_ring_available_read", cdecl, gcsafe, raises: [],
    tags: [], forbids: [].}
```

### `lf_stream_ring_available_write`

```nim
proc lf_stream_ring_available_write(ring: ptr lf_stream_ring_t): csize_t {.
    exportc: "lf_stream_ring_available_write", cdecl, gcsafe, raises: [],
    tags: [], forbids: [].}
```

### `lf_stream_ring_is_empty`

```nim
proc lf_stream_ring_is_empty(ring: ptr lf_stream_ring_t): bool {.
    exportc: "lf_stream_ring_is_empty", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_stream_ring_is_full`

```nim
proc lf_stream_ring_is_full(ring: ptr lf_stream_ring_t): bool {.
    exportc: "lf_stream_ring_is_full", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_streambuffer_capacity`

```nim
proc lf_streambuffer_capacity(ring: ptr lf_streambuffer_t): csize_t {.
    exportc: "lf_streambuffer_capacity", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_streambuffer_available_read`

```nim
proc lf_streambuffer_available_read(ring: ptr lf_streambuffer_t): csize_t {.
    exportc: "lf_streambuffer_available_read", cdecl, gcsafe, raises: [],
    tags: [], forbids: [].}
```

### `lf_streambuffer_available_write`

```nim
proc lf_streambuffer_available_write(ring: ptr lf_streambuffer_t): csize_t {.
    exportc: "lf_streambuffer_available_write", cdecl, gcsafe, raises: [],
    tags: [], forbids: [].}
```

### `lf_streambuffer_is_empty`

```nim
proc lf_streambuffer_is_empty(ring: ptr lf_streambuffer_t): bool {.
    exportc: "lf_streambuffer_is_empty", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_streambuffer_is_full`

```nim
proc lf_streambuffer_is_full(ring: ptr lf_streambuffer_t): bool {.
    exportc: "lf_streambuffer_is_full", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_stream_ring_try_write`

```nim
proc lf_stream_ring_try_write(ring: ptr lf_stream_ring_t; src: pointer;
                              len: csize_t): csize_t {.
    exportc: "lf_stream_ring_try_write", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_stream_ring_try_read`

```nim
proc lf_stream_ring_try_read(ring: ptr lf_stream_ring_t; dst: pointer;
                             max_len: csize_t): csize_t {.
    exportc: "lf_stream_ring_try_read", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_stream_ring_write_blocking`

```nim
proc lf_stream_ring_write_blocking(ring: ptr lf_stream_ring_t; src: pointer;
                                   len: csize_t; timeout_ns: int64): csize_t {.
    exportc: "lf_stream_ring_write_blocking", cdecl, gcsafe, raises: [],
    tags: [TimeEffect], forbids: [].}
```

### `lf_stream_ring_read_blocking`

```nim
proc lf_stream_ring_read_blocking(ring: ptr lf_stream_ring_t; dst: pointer;
                                  max_len: csize_t; timeout_ns: int64): csize_t {.
    exportc: "lf_stream_ring_read_blocking", cdecl, gcsafe, raises: [],
    tags: [TimeEffect], forbids: [].}
```

### `lf_streambuffer_try_write`

```nim
proc lf_streambuffer_try_write(ring: ptr lf_streambuffer_t; src: pointer;
                               len: csize_t): csize_t {.
    exportc: "lf_streambuffer_try_write", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_streambuffer_try_read`

```nim
proc lf_streambuffer_try_read(ring: ptr lf_streambuffer_t; dst: pointer;
                              max_len: csize_t): csize_t {.
    exportc: "lf_streambuffer_try_read", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_streambuffer_write_blocking`

```nim
proc lf_streambuffer_write_blocking(ring: ptr lf_streambuffer_t; src: pointer;
                                    len: csize_t; timeout_ns: int64): csize_t {.
    exportc: "lf_streambuffer_write_blocking", cdecl, gcsafe, raises: [],
    tags: [TimeEffect], forbids: [].}
```

### `lf_streambuffer_read_blocking`

```nim
proc lf_streambuffer_read_blocking(ring: ptr lf_streambuffer_t; dst: pointer;
                                   max_len: csize_t; timeout_ns: int64): csize_t {.
    exportc: "lf_streambuffer_read_blocking", cdecl, gcsafe, raises: [],
    tags: [TimeEffect], forbids: [].}
```

### `lf_stream_ring_acquire_write_iov`

```nim
proc lf_stream_ring_acquire_write_iov(ring: ptr lf_stream_ring_t;
                                      requested_len: csize_t): lf_iovec_pair_t {.
    exportc: "lf_stream_ring_acquire_write_iov", cdecl, gcsafe, raises: [],
    tags: [], forbids: [].}
```

### `lf_stream_ring_commit_write`

```nim
proc lf_stream_ring_commit_write(ring: ptr lf_stream_ring_t;
                                 bytes_written: csize_t) {.
    exportc: "lf_stream_ring_commit_write", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_stream_ring_acquire_read_iov`

```nim
proc lf_stream_ring_acquire_read_iov(ring: ptr lf_stream_ring_t;
                                     requested_len: csize_t): lf_iovec_pair_t {.
    exportc: "lf_stream_ring_acquire_read_iov", cdecl, gcsafe, raises: [],
    tags: [], forbids: [].}
```

### `lf_stream_ring_commit_read`

```nim
proc lf_stream_ring_commit_read(ring: ptr lf_stream_ring_t; bytes_read: csize_t) {.
    exportc: "lf_stream_ring_commit_read", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_streambuffer_acquire_write_iov`

```nim
proc lf_streambuffer_acquire_write_iov(ring: ptr lf_streambuffer_t;
                                       requested_len: csize_t): lf_iovec_pair_t {.
    exportc: "lf_streambuffer_acquire_write_iov", cdecl, gcsafe, raises: [],
    tags: [], forbids: [].}
```

### `lf_streambuffer_commit_write`

```nim
proc lf_streambuffer_commit_write(ring: ptr lf_streambuffer_t;
                                  bytes_written: csize_t) {.
    exportc: "lf_streambuffer_commit_write", cdecl, gcsafe, raises: [],
    tags: [], forbids: [].}
```

### `lf_streambuffer_acquire_read_iov`

```nim
proc lf_streambuffer_acquire_read_iov(ring: ptr lf_streambuffer_t;
                                      requested_len: csize_t): lf_iovec_pair_t {.
    exportc: "lf_streambuffer_acquire_read_iov", cdecl, gcsafe, raises: [],
    tags: [], forbids: [].}
```

### `lf_streambuffer_commit_read`

```nim
proc lf_streambuffer_commit_read(ring: ptr lf_streambuffer_t;
                                 bytes_read: csize_t) {.
    exportc: "lf_streambuffer_commit_read", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_mpmc_stream_ring_create`

```nim
proc lf_mpmc_stream_ring_create(capacity: csize_t): ptr lf_mpmc_stream_ring_t {.
    exportc: "lf_mpmc_stream_ring_create", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_mpmc_stream_ring_destroy`

```nim
proc lf_mpmc_stream_ring_destroy(ring: ptr lf_mpmc_stream_ring_t) {.
    exportc: "lf_mpmc_stream_ring_destroy", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_mpmc_stream_ring_capacity`

```nim
proc lf_mpmc_stream_ring_capacity(ring: ptr lf_mpmc_stream_ring_t): csize_t {.
    exportc: "lf_mpmc_stream_ring_capacity", cdecl, gcsafe, raises: [],
    tags: [], forbids: [].}
```

### `lf_mpmc_stream_ring_available_read`

```nim
proc lf_mpmc_stream_ring_available_read(ring: ptr lf_mpmc_stream_ring_t): csize_t {.
    exportc: "lf_mpmc_stream_ring_available_read", cdecl, gcsafe, raises: [],
    tags: [], forbids: [].}
```

### `lf_mpmc_stream_ring_available_write`

```nim
proc lf_mpmc_stream_ring_available_write(ring: ptr lf_mpmc_stream_ring_t): csize_t {.
    exportc: "lf_mpmc_stream_ring_available_write", cdecl, gcsafe, raises: [],
    tags: [], forbids: [].}
```

### `lf_mpmc_stream_ring_is_empty`

```nim
proc lf_mpmc_stream_ring_is_empty(ring: ptr lf_mpmc_stream_ring_t): bool {.
    exportc: "lf_mpmc_stream_ring_is_empty", cdecl, gcsafe, raises: [],
    tags: [], forbids: [].}
```

### `lf_mpmc_stream_ring_is_full`

```nim
proc lf_mpmc_stream_ring_is_full(ring: ptr lf_mpmc_stream_ring_t): bool {.
    exportc: "lf_mpmc_stream_ring_is_full", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_mpmc_stream_ring_try_write`

```nim
proc lf_mpmc_stream_ring_try_write(ring: ptr lf_mpmc_stream_ring_t;
                                   src: pointer; len: csize_t): csize_t {.
    exportc: "lf_mpmc_stream_ring_try_write", cdecl, gcsafe, raises: [],
    tags: [], forbids: [].}
```

### `lf_mpmc_stream_ring_try_read`

```nim
proc lf_mpmc_stream_ring_try_read(ring: ptr lf_mpmc_stream_ring_t; dst: pointer;
                                  max_len: csize_t): csize_t {.
    exportc: "lf_mpmc_stream_ring_try_read", cdecl, gcsafe, raises: [],
    tags: [], forbids: [].}
```

### `lf_ctrie_compute_if_absent`

```nim
proc lf_ctrie_compute_if_absent(trie: ptr lf_ctrie_t; key: pointer;
                                key_len: csize_t; mapping_fn: lf_mapping_fn;
                                user_data: pointer; out_val: ptr pointer;
                                out_val_len: ptr csize_t): bool {.
    exportc: "lf_ctrie_compute_if_absent", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lf_ctrie_atomic_update`

```nim
proc lf_ctrie_atomic_update(trie: ptr lf_ctrie_t; key: pointer;
                            key_len: csize_t; update_fn: lf_update_fn;
                            user_data: pointer; out_val: ptr pointer;
                            out_val_len: ptr csize_t): bool {.
    exportc: "lf_ctrie_atomic_update", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lf_skiplist_compute_if_absent`

```nim
proc lf_skiplist_compute_if_absent(map: ptr lf_table_t; key: pointer;
                                   key_len: csize_t; mapping_fn: lf_mapping_fn;
                                   user_data: pointer; out_val: ptr pointer;
                                   out_val_len: ptr csize_t): bool {.
    exportc: "lf_skiplist_compute_if_absent", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lf_skiplist_atomic_update`

```nim
proc lf_skiplist_atomic_update(map: ptr lf_table_t; key: pointer;
                               key_len: csize_t; update_fn: lf_update_fn;
                               user_data: pointer; out_val: ptr pointer;
                               out_val_len: ptr csize_t): bool {.
    exportc: "lf_skiplist_atomic_update", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lf_table_compute_if_absent`

```nim
proc lf_table_compute_if_absent(map: ptr lf_table_t; key: pointer;
                                key_len: csize_t; mapping_fn: lf_mapping_fn;
                                user_data: pointer; out_val: ptr pointer;
                                out_val_len: ptr csize_t): bool {.
    exportc: "lf_table_compute_if_absent", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lf_table_atomic_update`

```nim
proc lf_table_atomic_update(map: ptr lf_table_t; key: pointer; key_len: csize_t;
                            update_fn: lf_update_fn; user_data: pointer;
                            out_val: ptr pointer; out_val_len: ptr csize_t): bool {.
    exportc: "lf_table_atomic_update", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lf_arc_guard_create`

```nim
proc lf_arc_guard_create(item: pointer; destructor: lf_arc_destructor_fn;
                         userData: pointer; outGuard: ptr ptr lf_arc_guard_t): lf_status_t {.
    exportc: "lf_arc_guard_create", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_arc_guard_get`

```nim
proc lf_arc_guard_get(guard: ptr lf_arc_guard_t): pointer {.
    exportc: "lf_arc_guard_get", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_arc_guard_clone`

```nim
proc lf_arc_guard_clone(guard: ptr lf_arc_guard_t;
                        outClone: ptr ptr lf_arc_guard_t): lf_status_t {.
    exportc: "lf_arc_guard_clone", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_arc_guard_release`

```nim
proc lf_arc_guard_release(guard: ptr lf_arc_guard_t): lf_status_t {.
    exportc: "lf_arc_guard_release", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lf_atomic_arc_create`

```nim
proc lf_atomic_arc_create(initialItem: pointer;
                          destructor: lf_arc_destructor_fn; userData: pointer;
                          outArc: ptr ptr lf_atomic_arc_t): lf_status_t {.
    exportc: "lf_atomic_arc_create", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_atomic_arc_destroy`

```nim
proc lf_atomic_arc_destroy(arc: ptr lf_atomic_arc_t): lf_status_t {.
    exportc: "lf_atomic_arc_destroy", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lf_atomic_arc_is_null`

```nim
proc lf_atomic_arc_is_null(arc: ptr lf_atomic_arc_t): bool {.
    exportc: "lf_atomic_arc_is_null", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_atomic_arc_load`

```nim
proc lf_atomic_arc_load(arc: ptr lf_atomic_arc_t;
                        outGuard: ptr ptr lf_arc_guard_t): lf_status_t {.
    exportc: "lf_atomic_arc_load", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lf_atomic_arc_store`

```nim
proc lf_atomic_arc_store(arc: ptr lf_atomic_arc_t; newItem: pointer;
                         destructor: lf_arc_destructor_fn; userData: pointer): lf_status_t {.
    exportc: "lf_atomic_arc_store", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lf_atomic_arc_store_guard`

```nim
proc lf_atomic_arc_store_guard(arc: ptr lf_atomic_arc_t;
                               guard: ptr lf_arc_guard_t): lf_status_t {.
    exportc: "lf_atomic_arc_store_guard", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lf_atomic_arc_swap`

```nim
proc lf_atomic_arc_swap(arc: ptr lf_atomic_arc_t; newItem: pointer;
                        destructor: lf_arc_destructor_fn; userData: pointer;
                        outOldGuard: ptr ptr lf_arc_guard_t): lf_status_t {.
    exportc: "lf_atomic_arc_swap", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_atomic_arc_swap_guard`

```nim
proc lf_atomic_arc_swap_guard(arc: ptr lf_atomic_arc_t;
                              guard: ptr lf_arc_guard_t;
                              outOldGuard: ptr ptr lf_arc_guard_t): lf_status_t {.
    exportc: "lf_atomic_arc_swap_guard", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_atomic_arc_compare_exchange_guard`

```nim
proc lf_atomic_arc_compare_exchange_guard(arc: ptr lf_atomic_arc_t;
    inoutExpected: ptr ptr lf_arc_guard_t; desired: ptr lf_arc_guard_t;
    outSwapped: ptr bool): lf_status_t {.
    exportc: "lf_atomic_arc_compare_exchange_guard", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lf_atomic_arc_compare_exchange`

```nim
proc lf_atomic_arc_compare_exchange(arc: ptr lf_atomic_arc_t;
                                    inoutExpected: ptr ptr lf_arc_guard_t;
                                    desiredItem: pointer;
                                    destructor: lf_arc_destructor_fn;
                                    userData: pointer; outSwapped: ptr bool): lf_status_t {.
    exportc: "lf_atomic_arc_compare_exchange", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lf_pqueue_create`

```nim
proc lf_pqueue_create(destructor: lf_pqueue_destructor_fn; user_data: pointer;
                      out_pqueue: ptr ptr lf_pqueue_t): lf_status_t {.
    exportc: "lf_pqueue_create", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lf_pqueue_clear`

```nim
proc lf_pqueue_clear(pqueue: ptr lf_pqueue_t): lf_status_t {.
    exportc: "lf_pqueue_clear", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lf_pqueue_destroy`

```nim
proc lf_pqueue_destroy(pqueue: ptr lf_pqueue_t): lf_status_t {.
    exportc: "lf_pqueue_destroy", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lf_pqueue_push`

```nim
proc lf_pqueue_push(pqueue: ptr lf_pqueue_t; priority: int64; item: pointer): lf_status_t {.
    exportc: "lf_pqueue_push", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lf_pqueue_pop_min`

```nim
proc lf_pqueue_pop_min(pqueue: ptr lf_pqueue_t; out_priority: ptr int64;
                       out_item: ptr pointer): lf_status_t {.
    exportc: "lf_pqueue_pop_min", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lf_pqueue_peek_min`

```nim
proc lf_pqueue_peek_min(pqueue: ptr lf_pqueue_t; out_priority: ptr int64;
                        out_item: ptr pointer): lf_status_t {.
    exportc: "lf_pqueue_peek_min", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lf_pqueue_len`

```nim
proc lf_pqueue_len(pqueue: ptr lf_pqueue_t): csize_t {.exportc: "lf_pqueue_len",
    cdecl, gcsafe, raises: [], tags: [], forbids: [].}
```

### `lf_pqueue_is_empty`

```nim
proc lf_pqueue_is_empty(pqueue: ptr lf_pqueue_t): bool {.
    exportc: "lf_pqueue_is_empty", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_flat_combiner_create`

```nim
proc lf_flat_combiner_create(state: pointer;
                             default_op_fn: lf_flat_combiner_op_fn;
    state_destructor: lf_flat_combiner_state_destructor_fn; user_data: pointer;
                             max_combining_rounds: csize_t;
                             cleanup_interval: csize_t;
                             out_combiner: ptr ptr lf_flat_combiner_t): lf_status_t {.
    exportc: "lf_flat_combiner_create", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_flat_combiner_destroy`

```nim
proc lf_flat_combiner_destroy(combiner: ptr lf_flat_combiner_t): lf_status_t {.
    exportc: "lf_flat_combiner_destroy", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lf_flat_combiner_combine`

```nim
proc lf_flat_combiner_combine(combiner: ptr lf_flat_combiner_t; op_arg: pointer;
                              out_result: ptr pointer): lf_status_t {.
    exportc: "lf_flat_combiner_combine", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_flat_combiner_combine_fn`

```nim
proc lf_flat_combiner_combine_fn(combiner: ptr lf_flat_combiner_t;
                                 op_fn: lf_flat_combiner_op_fn; op_arg: pointer;
                                 op_user_data: pointer; out_result: ptr pointer): lf_status_t {.
    exportc: "lf_flat_combiner_combine_fn", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_flat_combiner_pass_count`

```nim
proc lf_flat_combiner_pass_count(combiner: ptr lf_flat_combiner_t): uint64 {.
    exportc: "lf_flat_combiner_pass_count", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_flat_combiner_total_combined_ops`

```nim
proc lf_flat_combiner_total_combined_ops(combiner: ptr lf_flat_combiner_t): uint64 {.
    exportc: "lf_flat_combiner_total_combined_ops", cdecl, gcsafe, raises: [],
    tags: [], forbids: [].}
```

### `lf_flat_combiner_active_records`

```nim
proc lf_flat_combiner_active_records(combiner: ptr lf_flat_combiner_t): csize_t {.
    exportc: "lf_flat_combiner_active_records", cdecl, gcsafe, raises: [],
    tags: [], forbids: [].}
```

### `lf_bstack_create`

```nim
proc lf_bstack_create(capacity: csize_t; destructor: lf_item_destructor_fn;
                      user_data: pointer; out_stack: ptr ptr lf_bstack_t): lf_status_t {.
    exportc: "lf_bstack_create", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_bstack_destroy`

```nim
proc lf_bstack_destroy(stack: ptr lf_bstack_t): lf_status_t {.
    exportc: "lf_bstack_destroy", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lf_bstack_push`

```nim
proc lf_bstack_push(stack: ptr lf_bstack_t; item: pointer): lf_status_t {.
    exportc: "lf_bstack_push", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lf_bstack_pop`

```nim
proc lf_bstack_pop(stack: ptr lf_bstack_t; out_item: ptr pointer): lf_status_t {.
    exportc: "lf_bstack_pop", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lf_bstack_peek`

```nim
proc lf_bstack_peek(stack: ptr lf_bstack_t; out_item: ptr pointer): lf_status_t {.
    exportc: "lf_bstack_peek", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lf_bstack_drain`

```nim
proc lf_bstack_drain(stack: ptr lf_bstack_t; out_items: ptr pointer;
                     max_count: csize_t): csize_t {.exportc: "lf_bstack_drain",
    cdecl, gcsafe, raises: [], tags: [RootEffect], forbids: [].}
```

### `lf_bstack_clear`

```nim
proc lf_bstack_clear(stack: ptr lf_bstack_t): lf_status_t {.
    exportc: "lf_bstack_clear", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lf_bstack_len`

```nim
proc lf_bstack_len(stack: ptr lf_bstack_t): csize_t {.exportc: "lf_bstack_len",
    cdecl, gcsafe, raises: [], tags: [RootEffect], forbids: [].}
```

### `lf_bstack_capacity`

```nim
proc lf_bstack_capacity(stack: ptr lf_bstack_t): csize_t {.
    exportc: "lf_bstack_capacity", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lf_bstack_is_empty`

```nim
proc lf_bstack_is_empty(stack: ptr lf_bstack_t): bool {.
    exportc: "lf_bstack_is_empty", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lf_bstack_is_full`

```nim
proc lf_bstack_is_full(stack: ptr lf_bstack_t): bool {.
    exportc: "lf_bstack_is_full", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lf_bpqueue_create`

```nim
proc lf_bpqueue_create(capacity: csize_t; destructor: lf_item_destructor_fn;
                       user_data: pointer; out_pqueue: ptr ptr lf_bpqueue_t): lf_status_t {.
    exportc: "lf_bpqueue_create", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_bpqueue_destroy`

```nim
proc lf_bpqueue_destroy(pqueue: ptr lf_bpqueue_t): lf_status_t {.
    exportc: "lf_bpqueue_destroy", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lf_bpqueue_push`

```nim
proc lf_bpqueue_push(pqueue: ptr lf_bpqueue_t; priority: int64; item: pointer): lf_status_t {.
    exportc: "lf_bpqueue_push", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lf_bpqueue_pop_min`

```nim
proc lf_bpqueue_pop_min(pqueue: ptr lf_bpqueue_t; out_priority: ptr int64;
                        out_item: ptr pointer): lf_status_t {.
    exportc: "lf_bpqueue_pop_min", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lf_bpqueue_peek_min`

```nim
proc lf_bpqueue_peek_min(pqueue: ptr lf_bpqueue_t; out_priority: ptr int64;
                         out_item: ptr pointer): lf_status_t {.
    exportc: "lf_bpqueue_peek_min", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lf_bpqueue_clear`

```nim
proc lf_bpqueue_clear(pqueue: ptr lf_bpqueue_t): lf_status_t {.
    exportc: "lf_bpqueue_clear", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lf_bpqueue_len`

```nim
proc lf_bpqueue_len(pqueue: ptr lf_bpqueue_t): csize_t {.
    exportc: "lf_bpqueue_len", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lf_bpqueue_capacity`

```nim
proc lf_bpqueue_capacity(pqueue: ptr lf_bpqueue_t): csize_t {.
    exportc: "lf_bpqueue_capacity", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lf_bpqueue_is_empty`

```nim
proc lf_bpqueue_is_empty(pqueue: ptr lf_bpqueue_t): bool {.
    exportc: "lf_bpqueue_is_empty", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lf_bpqueue_is_full`

```nim
proc lf_bpqueue_is_full(pqueue: ptr lf_bpqueue_t): bool {.
    exportc: "lf_bpqueue_is_full", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lf_btable_create`

```nim
proc lf_btable_create(capacity: csize_t; destructor: lf_btable_destructor_fn;
                      user_data: pointer; out_table: ptr ptr lf_btable_t): lf_status_t {.
    exportc: "lf_btable_create", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_btable_destroy`

```nim
proc lf_btable_destroy(table: ptr lf_btable_t): lf_status_t {.
    exportc: "lf_btable_destroy", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lf_btable_put`

```nim
proc lf_btable_put(table: ptr lf_btable_t; key: pointer; val: pointer;
                   out_inserted: ptr bool): lf_status_t {.
    exportc: "lf_btable_put", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lf_btable_insert`

```nim
proc lf_btable_insert(table: ptr lf_btable_t; key: pointer; val: pointer;
                      out_inserted: ptr bool): lf_status_t {.
    exportc: "lf_btable_insert", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lf_btable_get`

```nim
proc lf_btable_get(table: ptr lf_btable_t; key: pointer; out_val: ptr pointer): lf_status_t {.
    exportc: "lf_btable_get", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lf_btable_delete`

```nim
proc lf_btable_delete(table: ptr lf_btable_t; key: pointer;
                      out_deleted: ptr bool): lf_status_t {.
    exportc: "lf_btable_delete", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lf_btable_remove`

```nim
proc lf_btable_remove(table: ptr lf_btable_t; key: pointer;
                      out_removed: ptr bool): lf_status_t {.
    exportc: "lf_btable_remove", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lf_btable_take`

```nim
proc lf_btable_take(table: ptr lf_btable_t; key: pointer; out_val: ptr pointer): lf_status_t {.
    exportc: "lf_btable_take", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lf_btable_contains`

```nim
proc lf_btable_contains(table: ptr lf_btable_t; key: pointer): bool {.
    exportc: "lf_btable_contains", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lf_btable_compute_if_absent`

```nim
proc lf_btable_compute_if_absent(table: ptr lf_btable_t; key: pointer;
                                 mapping_fn: lf_btable_mapping_fn;
                                 user_data: pointer; out_val: ptr pointer): lf_status_t {.
    exportc: "lf_btable_compute_if_absent", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lf_btable_atomic_update`

```nim
proc lf_btable_atomic_update(table: ptr lf_btable_t; key: pointer;
                             update_fn: lf_btable_update_fn; user_data: pointer;
                             out_val: ptr pointer): lf_status_t {.
    exportc: "lf_btable_atomic_update", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lf_btable_upsert`

```nim
proc lf_btable_upsert(table: ptr lf_btable_t; key: pointer;
                      initial_val: pointer; update_fn: lf_btable_update_fn;
                      user_data: pointer; out_val: ptr pointer): lf_status_t {.
    exportc: "lf_btable_upsert", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lf_btable_clear`

```nim
proc lf_btable_clear(table: ptr lf_btable_t): lf_status_t {.
    exportc: "lf_btable_clear", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lf_btable_len`

```nim
proc lf_btable_len(table: ptr lf_btable_t): csize_t {.exportc: "lf_btable_len",
    cdecl, gcsafe, raises: [], tags: [RootEffect], forbids: [].}
```

### `lf_btable_capacity`

```nim
proc lf_btable_capacity(table: ptr lf_btable_t): csize_t {.
    exportc: "lf_btable_capacity", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lf_btable_is_empty`

```nim
proc lf_btable_is_empty(table: ptr lf_btable_t): bool {.
    exportc: "lf_btable_is_empty", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lf_btable_is_full`

```nim
proc lf_btable_is_full(table: ptr lf_btable_t): bool {.
    exportc: "lf_btable_is_full", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lf_bqueue128_create`

```nim
proc lf_bqueue128_create(capacity: csize_t;
                         destructor: lf_bqueue128_destructor_fn;
                         user_data: pointer; out_queue: ptr ptr lf_bqueue128_t): lf_status_t {.
    exportc: "lf_bqueue128_create", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lf_bqueue128_destroy`

```nim
proc lf_bqueue128_destroy(queue: ptr lf_bqueue128_t): lf_status_t {.
    exportc: "lf_bqueue128_destroy", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lf_bqueue128_push`

```nim
proc lf_bqueue128_push(queue: ptr lf_bqueue128_t; item: pointer): lf_status_t {.
    exportc: "lf_bqueue128_push", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lf_bqueue128_pop`

```nim
proc lf_bqueue128_pop(queue: ptr lf_bqueue128_t; out_item: ptr pointer): lf_status_t {.
    exportc: "lf_bqueue128_pop", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lf_bqueue128_peek`

```nim
proc lf_bqueue128_peek(queue: ptr lf_bqueue128_t; out_item: ptr pointer): lf_status_t {.
    exportc: "lf_bqueue128_peek", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lf_bqueue128_clear`

```nim
proc lf_bqueue128_clear(queue: ptr lf_bqueue128_t): lf_status_t {.
    exportc: "lf_bqueue128_clear", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lf_bqueue128_len`

```nim
proc lf_bqueue128_len(queue: ptr lf_bqueue128_t): csize_t {.
    exportc: "lf_bqueue128_len", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lf_bqueue128_capacity`

```nim
proc lf_bqueue128_capacity(queue: ptr lf_bqueue128_t): csize_t {.
    exportc: "lf_bqueue128_capacity", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lf_bqueue128_is_empty`

```nim
proc lf_bqueue128_is_empty(queue: ptr lf_bqueue128_t): bool {.
    exportc: "lf_bqueue128_is_empty", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lf_bqueue128_is_full`

```nim
proc lf_bqueue128_is_full(queue: ptr lf_bqueue128_t): bool {.
    exportc: "lf_bqueue128_is_full", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lfq_unbounded_mpmc_create`

```nim
proc lfq_unbounded_mpmc_create(segment_size: csize_t; max_threads: csize_t;
                               destructor: lfq_item_destructor_fn;
                               user_data: pointer;
                               out_queue: ptr ptr lfq_queue_t): lfq_status_t {.
    exportc: "lfq_unbounded_mpmc_create", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lfq_bounded_mpmc_create`

```nim
proc lfq_bounded_mpmc_create(capacity: csize_t; max_producers: csize_t;
                             max_consumers: csize_t;
                             destructor: lfq_item_destructor_fn;
                             user_data: pointer; out_queue: ptr ptr lfq_queue_t): lfq_status_t {.
    exportc: "lfq_bounded_mpmc_create", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_queue_close`

```nim
proc lfq_queue_close(queue: ptr lfq_queue_t): lfq_status_t {.
    exportc: "lfq_queue_close", cdecl, gcsafe, raises: [], tags: [], forbids: [].}
```

### `lfq_queue_destroy`

```nim
proc lfq_queue_destroy(queue: ptr lfq_queue_t): lfq_status_t {.
    exportc: "lfq_queue_destroy", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lfq_producer_acquire`

```nim
proc lfq_producer_acquire(queue: ptr lfq_queue_t;
                          out_prod: ptr ptr lfq_producer_t): lfq_status_t {.
    exportc: "lfq_producer_acquire", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lfq_producer_release`

```nim
proc lfq_producer_release(prod: ptr lfq_producer_t): lfq_status_t {.
    exportc: "lfq_producer_release", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lfq_consumer_acquire`

```nim
proc lfq_consumer_acquire(queue: ptr lfq_queue_t;
                          out_cons: ptr ptr lfq_consumer_t): lfq_status_t {.
    exportc: "lfq_consumer_acquire", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lfq_consumer_release`

```nim
proc lfq_consumer_release(cons: ptr lfq_consumer_t): lfq_status_t {.
    exportc: "lfq_consumer_release", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lfq_push`

```nim
proc lfq_push(prod: ptr lfq_producer_t; item: pointer): lfq_status_t {.
    exportc: "lfq_push", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lfq_pop`

```nim
proc lfq_pop(cons: ptr lfq_consumer_t; out_item: ptr pointer): lfq_status_t {.
    exportc: "lfq_pop", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lfq_pop_batch`

```nim
proc lfq_pop_batch(cons: ptr lfq_consumer_t; out_items: ptr pointer;
                   max_count: csize_t): csize_t {.exportc: "lfq_pop_batch",
    cdecl, gcsafe, raises: [], tags: [RootEffect], forbids: [].}
```

### `lfq_queue_len`

```nim
proc lfq_queue_len(queue: ptr lfq_queue_t): csize_t {.exportc: "lfq_queue_len",
    cdecl, gcsafe, raises: [], tags: [RootEffect], forbids: [].}
```

### `lfq_queue_is_empty`

```nim
proc lfq_queue_is_empty(queue: ptr lfq_queue_t): bool {.
    exportc: "lfq_queue_is_empty", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lfq_queue_is_closed`

```nim
proc lfq_queue_is_closed(queue: ptr lfq_queue_t): bool {.
    exportc: "lfq_queue_is_closed", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_queue_push`

```nim
proc lfq_queue_push(prod: ptr lfq_producer_t; item: pointer): lfq_status_t {.
    exportc: "lfq_queue_push", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lfq_queue_pop`

```nim
proc lfq_queue_pop(cons: ptr lfq_consumer_t; out_item: ptr pointer): lfq_status_t {.
    exportc: "lfq_queue_pop", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lfq_stack_create`

```nim
proc lfq_stack_create(destructor: lfq_item_destructor_fn; user_data: pointer;
                      out_stack: ptr ptr lfq_stack_t): lfq_status_t {.
    exportc: "lfq_stack_create", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_stack_destroy`

```nim
proc lfq_stack_destroy(stack: ptr lfq_stack_t): lfq_status_t {.
    exportc: "lfq_stack_destroy", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lfq_stack_push`

```nim
proc lfq_stack_push(stack: ptr lfq_stack_t; item: pointer): lfq_status_t {.
    exportc: "lfq_stack_push", cdecl, gcsafe, raises: [], tags: [], forbids: [].}
```

### `lfq_stack_pop`

```nim
proc lfq_stack_pop(stack: ptr lfq_stack_t; out_item: ptr pointer): lfq_status_t {.
    exportc: "lfq_stack_pop", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lfq_stack_peek`

```nim
proc lfq_stack_peek(stack: ptr lfq_stack_t; out_item: ptr pointer): lfq_status_t {.
    exportc: "lfq_stack_peek", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lfq_stack_drain`

```nim
proc lfq_stack_drain(stack: ptr lfq_stack_t; out_items: ptr pointer;
                     max_count: csize_t): csize_t {.exportc: "lfq_stack_drain",
    cdecl, gcsafe, raises: [], tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lfq_stack_len`

```nim
proc lfq_stack_len(stack: ptr lfq_stack_t): csize_t {.exportc: "lfq_stack_len",
    cdecl, gcsafe, raises: [], tags: [], forbids: [].}
```

### `lfq_stack_is_empty`

```nim
proc lfq_stack_is_empty(stack: ptr lfq_stack_t): bool {.
    exportc: "lfq_stack_is_empty", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_deque_create`

```nim
proc lfq_deque_create(initial_capacity: csize_t;
                      destructor: lfq_item_destructor_fn; user_data: pointer;
                      out_deque: ptr ptr lfq_deque_t): lfq_status_t {.
    exportc: "lfq_deque_create", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_deque_destroy`

```nim
proc lfq_deque_destroy(deque: ptr lfq_deque_t): lfq_status_t {.
    exportc: "lfq_deque_destroy", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lfq_deque_push`

```nim
proc lfq_deque_push(deque: ptr lfq_deque_t; item: pointer): lfq_status_t {.
    exportc: "lfq_deque_push", cdecl, gcsafe, raises: [], tags: [], forbids: [].}
```

### `lfq_deque_pop`

```nim
proc lfq_deque_pop(deque: ptr lfq_deque_t; out_item: ptr pointer): lfq_status_t {.
    exportc: "lfq_deque_pop", cdecl, gcsafe, raises: [], tags: [], forbids: [].}
```

### `lfq_deque_steal`

```nim
proc lfq_deque_steal(deque: ptr lfq_deque_t; out_item: ptr pointer): lfq_status_t {.
    exportc: "lfq_deque_steal", cdecl, gcsafe, raises: [], tags: [], forbids: [].}
```

### `lfq_deque_steal_batch`

```nim
proc lfq_deque_steal_batch(deque: ptr lfq_deque_t; out_items: ptr pointer;
                           max_count: csize_t): csize_t {.
    exportc: "lfq_deque_steal_batch", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_deque_len`

```nim
proc lfq_deque_len(deque: ptr lfq_deque_t): csize_t {.exportc: "lfq_deque_len",
    cdecl, gcsafe, raises: [], tags: [], forbids: [].}
```

### `lfq_deque_capacity`

```nim
proc lfq_deque_capacity(deque: ptr lfq_deque_t): csize_t {.
    exportc: "lfq_deque_capacity", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_deque_is_empty`

```nim
proc lfq_deque_is_empty(deque: ptr lfq_deque_t): bool {.
    exportc: "lfq_deque_is_empty", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_table_create`

```nim
proc lfq_table_create(destructor: lfq_entry_destructor_fn; user_data: pointer;
                      out_table: ptr ptr lfq_table_t): lfq_status_t {.
    exportc: "lfq_table_create", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lfq_table_destroy`

```nim
proc lfq_table_destroy(table: ptr lfq_table_t): lfq_status_t {.
    exportc: "lfq_table_destroy", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lfq_table_put`

```nim
proc lfq_table_put(table: ptr lfq_table_t; key: pointer; val: pointer;
                   out_inserted: ptr bool): lfq_status_t {.
    exportc: "lfq_table_put", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lfq_table_get`

```nim
proc lfq_table_get(table: ptr lfq_table_t; key: pointer; out_val: ptr pointer): lfq_status_t {.
    exportc: "lfq_table_get", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lfq_table_delete`

```nim
proc lfq_table_delete(table: ptr lfq_table_t; key: pointer;
                      out_deleted: ptr bool): lfq_status_t {.
    exportc: "lfq_table_delete", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lfq_table_remove`

```nim
proc lfq_table_remove(table: ptr lfq_table_t; key: pointer;
                      out_removed: ptr bool): lfq_status_t {.
    exportc: "lfq_table_remove", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lfq_table_contains`

```nim
proc lfq_table_contains(table: ptr lfq_table_t; key: pointer): bool {.
    exportc: "lfq_table_contains", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lfq_table_len`

```nim
proc lfq_table_len(table: ptr lfq_table_t): csize_t {.exportc: "lfq_table_len",
    cdecl, gcsafe, raises: [], tags: [], forbids: [].}
```

### `lfq_table_is_empty`

```nim
proc lfq_table_is_empty(table: ptr lfq_table_t): bool {.
    exportc: "lfq_table_is_empty", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_set_create`

```nim
proc lfq_set_create(destructor: lfq_item_destructor_fn; user_data: pointer;
                    out_set: ptr ptr lfq_set_t): lfq_status_t {.
    exportc: "lfq_set_create", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lfq_set_destroy`

```nim
proc lfq_set_destroy(set: ptr lfq_set_t): lfq_status_t {.
    exportc: "lfq_set_destroy", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lfq_set_insert`

```nim
proc lfq_set_insert(set: ptr lfq_set_t; item: pointer; out_inserted: ptr bool): lfq_status_t {.
    exportc: "lfq_set_insert", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lfq_set_remove`

```nim
proc lfq_set_remove(set: ptr lfq_set_t; item: pointer; out_removed: ptr bool): lfq_status_t {.
    exportc: "lfq_set_remove", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lfq_set_contains`

```nim
proc lfq_set_contains(set: ptr lfq_set_t; item: pointer): bool {.
    exportc: "lfq_set_contains", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lfq_set_len`

```nim
proc lfq_set_len(set: ptr lfq_set_t): csize_t {.exportc: "lfq_set_len", cdecl,
    gcsafe, raises: [], tags: [], forbids: [].}
```

### `lfq_set_is_empty`

```nim
proc lfq_set_is_empty(set: ptr lfq_set_t): bool {.exportc: "lfq_set_is_empty",
    cdecl, gcsafe, raises: [], tags: [], forbids: [].}
```

### `lfq_taskpool_create`

```nim
proc lfq_taskpool_create(num_threads: csize_t; out_pool: ptr ptr lfq_taskpool_t): lfq_status_t {.
    exportc: "lfq_taskpool_create", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_taskpool_destroy`

```nim
proc lfq_taskpool_destroy(pool: ptr lfq_taskpool_t): lfq_status_t {.
    exportc: "lfq_taskpool_destroy", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lfq_taskpool_spawn`

```nim
proc lfq_taskpool_spawn(pool: ptr lfq_taskpool_t; task: lfq_task_fn;
                        arg: pointer): lfq_status_t {.
    exportc: "lfq_taskpool_spawn", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lfq_taskpool_parallel_for`

```nim
proc lfq_taskpool_parallel_for(pool: ptr lfq_taskpool_t; start: csize_t;
                               stop: csize_t; task: lfq_for_task_fn;
                               arg: pointer; chunk_size: csize_t): lfq_status_t {.
    exportc: "lfq_taskpool_parallel_for", cdecl, gcsafe, raises: [],
    tags: [RootEffect, TypestateOp], forbids: [].}
```

### `lfq_taskpool_sync`

```nim
proc lfq_taskpool_sync(pool: ptr lfq_taskpool_t): lfq_status_t {.
    exportc: "lfq_taskpool_sync", cdecl, gcsafe, raises: [],
    tags: [RootEffect, TypestateOp], forbids: [].}
```

### `lfq_taskpool_num_workers`

```nim
proc lfq_taskpool_num_workers(pool: ptr lfq_taskpool_t): csize_t {.
    exportc: "lfq_taskpool_num_workers", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_ctrie_create`

```nim
proc lfq_ctrie_create(destructor: lfq_entry_destructor_fn; user_data: pointer;
                      out_ctrie: ptr ptr lfq_ctrie_t): lfq_status_t {.
    exportc: "lfq_ctrie_create", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lfq_ctrie_destroy`

```nim
proc lfq_ctrie_destroy(ctrie: ptr lfq_ctrie_t): lfq_status_t {.
    exportc: "lfq_ctrie_destroy", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lfq_ctrie_insert`

```nim
proc lfq_ctrie_insert(ctrie: ptr lfq_ctrie_t; key: pointer; val: pointer;
                      out_inserted: ptr bool): lfq_status_t {.
    exportc: "lfq_ctrie_insert", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lfq_ctrie_put`

```nim
proc lfq_ctrie_put(ctrie: ptr lfq_ctrie_t; key: pointer; val: pointer;
                   out_inserted: ptr bool): lfq_status_t {.
    exportc: "lfq_ctrie_put", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lfq_ctrie_lookup`

```nim
proc lfq_ctrie_lookup(ctrie: ptr lfq_ctrie_t; key: pointer; out_val: ptr pointer): lfq_status_t {.
    exportc: "lfq_ctrie_lookup", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lfq_ctrie_get`

```nim
proc lfq_ctrie_get(ctrie: ptr lfq_ctrie_t; key: pointer; out_val: ptr pointer): lfq_status_t {.
    exportc: "lfq_ctrie_get", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lfq_ctrie_remove`

```nim
proc lfq_ctrie_remove(ctrie: ptr lfq_ctrie_t; key: pointer;
                      out_removed: ptr bool): lfq_status_t {.
    exportc: "lfq_ctrie_remove", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lfq_ctrie_delete`

```nim
proc lfq_ctrie_delete(ctrie: ptr lfq_ctrie_t; key: pointer;
                      out_deleted: ptr bool): lfq_status_t {.
    exportc: "lfq_ctrie_delete", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lfq_ctrie_contains`

```nim
proc lfq_ctrie_contains(ctrie: ptr lfq_ctrie_t; key: pointer): bool {.
    exportc: "lfq_ctrie_contains", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lfq_ctrie_len`

```nim
proc lfq_ctrie_len(ctrie: ptr lfq_ctrie_t): csize_t {.exportc: "lfq_ctrie_len",
    cdecl, gcsafe, raises: [], tags: [], forbids: [].}
```

### `lfq_ctrie_is_empty`

```nim
proc lfq_ctrie_is_empty(ctrie: ptr lfq_ctrie_t): bool {.
    exportc: "lfq_ctrie_is_empty", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_ctrie_snapshot`

```nim
proc lfq_ctrie_snapshot(ctrie: ptr lfq_ctrie_t;
                        out_snapshot: ptr ptr lfq_ctrie_snapshot_t): lfq_status_t {.
    exportc: "lfq_ctrie_snapshot", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lfq_ctrie_snapshot_create`

```nim
proc lfq_ctrie_snapshot_create(ctrie: ptr lfq_ctrie_t;
                               out_snapshot: ptr ptr lfq_ctrie_snapshot_t): lfq_status_t {.
    exportc: "lfq_ctrie_snapshot_create", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lfq_ctrie_snapshot_destroy`

```nim
proc lfq_ctrie_snapshot_destroy(snapshot: ptr lfq_ctrie_snapshot_t): lfq_status_t {.
    exportc: "lfq_ctrie_snapshot_destroy", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_ctrie_snapshot_lookup`

```nim
proc lfq_ctrie_snapshot_lookup(snapshot: ptr lfq_ctrie_snapshot_t; key: pointer;
                               out_val: ptr pointer): lfq_status_t {.
    exportc: "lfq_ctrie_snapshot_lookup", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lfq_ctrie_snapshot_get`

```nim
proc lfq_ctrie_snapshot_get(snapshot: ptr lfq_ctrie_snapshot_t; key: pointer;
                            out_val: ptr pointer): lfq_status_t {.
    exportc: "lfq_ctrie_snapshot_get", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lfq_ctrie_snapshot_contains`

```nim
proc lfq_ctrie_snapshot_contains(snapshot: ptr lfq_ctrie_snapshot_t;
                                 key: pointer): bool {.
    exportc: "lfq_ctrie_snapshot_contains", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lfq_ctrie_snapshot_len`

```nim
proc lfq_ctrie_snapshot_len(snapshot: ptr lfq_ctrie_snapshot_t): csize_t {.
    exportc: "lfq_ctrie_snapshot_len", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lfq_ctrie_snapshot_is_empty`

```nim
proc lfq_ctrie_snapshot_is_empty(snapshot: ptr lfq_ctrie_snapshot_t): bool {.
    exportc: "lfq_ctrie_snapshot_is_empty", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lfq_broadcast_create`

```nim
proc lfq_broadcast_create(capacity: csize_t; overflow_mode: lfq_overflow_mode_t;
                          max_readers: csize_t;
                          out_broadcast: ptr ptr lfq_broadcast_t): lfq_status_t {.
    exportc: "lfq_broadcast_create", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_broadcast_destroy`

```nim
proc lfq_broadcast_destroy(broadcast: ptr lfq_broadcast_t): lfq_status_t {.
    exportc: "lfq_broadcast_destroy", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_broadcast_publish`

```nim
proc lfq_broadcast_publish(broadcast: ptr lfq_broadcast_t; item: pointer): lfq_status_t {.
    exportc: "lfq_broadcast_publish", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_broadcast_subscribe`

```nim
proc lfq_broadcast_subscribe(broadcast: ptr lfq_broadcast_t;
                             origin: lfq_sub_origin_t;
                             out_cursor: ptr ptr lfq_broadcast_cursor_t): lfq_status_t {.
    exportc: "lfq_broadcast_subscribe", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_broadcast_unsubscribe`

```nim
proc lfq_broadcast_unsubscribe(cursor: ptr lfq_broadcast_cursor_t): lfq_status_t {.
    exportc: "lfq_broadcast_unsubscribe", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_broadcast_poll`

```nim
proc lfq_broadcast_poll(cursor: ptr lfq_broadcast_cursor_t;
                        out_item: ptr pointer; out_skipped_count: ptr csize_t;
                        out_result: ptr lfq_poll_result_t): lfq_status_t {.
    exportc: "lfq_broadcast_poll", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_broadcast_try_read`

```nim
proc lfq_broadcast_try_read(cursor: ptr lfq_broadcast_cursor_t;
                            out_item: ptr pointer): lfq_status_t {.
    exportc: "lfq_broadcast_try_read", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_broadcast_len`

```nim
proc lfq_broadcast_len(broadcast: ptr lfq_broadcast_t): csize_t {.
    exportc: "lfq_broadcast_len", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_broadcast_capacity`

```nim
proc lfq_broadcast_capacity(broadcast: ptr lfq_broadcast_t): csize_t {.
    exportc: "lfq_broadcast_capacity", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_broadcast_subscriber_count`

```nim
proc lfq_broadcast_subscriber_count(broadcast: ptr lfq_broadcast_t): csize_t {.
    exportc: "lfq_broadcast_subscriber_count", cdecl, gcsafe, raises: [],
    tags: [], forbids: [].}
```

### `lfq_broadcast_is_empty`

```nim
proc lfq_broadcast_is_empty(broadcast: ptr lfq_broadcast_t): bool {.
    exportc: "lfq_broadcast_is_empty", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_broadcast_cursor_lag`

```nim
proc lfq_broadcast_cursor_lag(cursor: ptr lfq_broadcast_cursor_t): csize_t {.
    exportc: "lfq_broadcast_cursor_lag", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_topic_bus_create`

```nim
proc lfq_topic_bus_create(default_capacity: csize_t;
                          default_overflow_mode: lfq_overflow_mode_t;
                          default_max_readers: csize_t;
                          out_bus: ptr ptr lfq_topic_bus_t): lfq_status_t {.
    exportc: "lfq_topic_bus_create", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lfq_topic_bus_destroy`

```nim
proc lfq_topic_bus_destroy(bus: ptr lfq_topic_bus_t): lfq_status_t {.
    exportc: "lfq_topic_bus_destroy", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_topic_bus_publish`

```nim
proc lfq_topic_bus_publish(bus: ptr lfq_topic_bus_t; topic: cstring;
                           item: pointer): lfq_status_t {.
    exportc: "lfq_topic_bus_publish", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lfq_topic_bus_subscribe`

```nim
proc lfq_topic_bus_subscribe(bus: ptr lfq_topic_bus_t; topic: cstring;
                             origin: lfq_sub_origin_t;
                             out_cursor: ptr ptr lfq_broadcast_cursor_t): lfq_status_t {.
    exportc: "lfq_topic_bus_subscribe", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lfq_topic_bus_topic_count`

```nim
proc lfq_topic_bus_topic_count(bus: ptr lfq_topic_bus_t): csize_t {.
    exportc: "lfq_topic_bus_topic_count", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_topic_bus_has_topic`

```nim
proc lfq_topic_bus_has_topic(bus: ptr lfq_topic_bus_t; topic: cstring): bool {.
    exportc: "lfq_topic_bus_has_topic", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lfq_rendezvous_create`

```nim
proc lfq_rendezvous_create(out_chan: ptr ptr lfq_rendezvous_t): lfq_status_t {.
    exportc: "lfq_rendezvous_create", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_rendezvous_destroy`

```nim
proc lfq_rendezvous_destroy(chan: ptr lfq_rendezvous_t): lfq_status_t {.
    exportc: "lfq_rendezvous_destroy", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_rendezvous_close`

```nim
proc lfq_rendezvous_close(chan: ptr lfq_rendezvous_t): lfq_status_t {.
    exportc: "lfq_rendezvous_close", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lfq_rendezvous_is_closed`

```nim
proc lfq_rendezvous_is_closed(chan: ptr lfq_rendezvous_t): bool {.
    exportc: "lfq_rendezvous_is_closed", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_rendezvous_send`

```nim
proc lfq_rendezvous_send(chan: ptr lfq_rendezvous_t; payload: pointer;
                         out_corr_id: ptr uint64): lfq_status_t {.
    exportc: "lfq_rendezvous_send", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lfq_rendezvous_recv`

```nim
proc lfq_rendezvous_recv(chan: ptr lfq_rendezvous_t; out_payload: ptr pointer;
                         out_corr_id: ptr uint64): lfq_status_t {.
    exportc: "lfq_rendezvous_recv", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lfq_rendezvous_try_send`

```nim
proc lfq_rendezvous_try_send(chan: ptr lfq_rendezvous_t; payload: pointer;
                             out_corr_id: ptr uint64): lfq_status_t {.
    exportc: "lfq_rendezvous_try_send", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lfq_rendezvous_try_recv`

```nim
proc lfq_rendezvous_try_recv(chan: ptr lfq_rendezvous_t;
                             out_payload: ptr pointer; out_corr_id: ptr uint64): lfq_status_t {.
    exportc: "lfq_rendezvous_try_recv", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lfq_rendezvous_send_timeout`

```nim
proc lfq_rendezvous_send_timeout(chan: ptr lfq_rendezvous_t; payload: pointer;
                                 timeout_ms: int32; out_corr_id: ptr uint64): lfq_status_t {.
    exportc: "lfq_rendezvous_send_timeout", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lfq_rendezvous_recv_timeout`

```nim
proc lfq_rendezvous_recv_timeout(chan: ptr lfq_rendezvous_t;
                                 out_payload: ptr pointer; timeout_ms: int32;
                                 out_corr_id: ptr uint64): lfq_status_t {.
    exportc: "lfq_rendezvous_recv_timeout", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lfq_token_bucket_create`

```nim
proc lfq_token_bucket_create(capacity: uint64; refill_rate: uint64): ptr lfq_token_bucket_t {.
    exportc: "lfq_token_bucket_create", cdecl, gcsafe, raises: [],
    tags: [TimeEffect], forbids: [].}
```

### `lfq_token_bucket_destroy`

```nim
proc lfq_token_bucket_destroy(bucket: ptr lfq_token_bucket_t) {.
    exportc: "lfq_token_bucket_destroy", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_token_bucket_reset`

```nim
proc lfq_token_bucket_reset(bucket: ptr lfq_token_bucket_t; tokens: uint64) {.
    exportc: "lfq_token_bucket_reset", cdecl, gcsafe, raises: [],
    tags: [TimeEffect], forbids: [].}
```

### `lfq_leaky_bucket_create`

```nim
proc lfq_leaky_bucket_create(burst_tolerance_ns: uint64; leak_rate: uint64): ptr lfq_leaky_bucket_t {.
    exportc: "lfq_leaky_bucket_create", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_leaky_bucket_destroy`

```nim
proc lfq_leaky_bucket_destroy(bucket: ptr lfq_leaky_bucket_t) {.
    exportc: "lfq_leaky_bucket_destroy", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_leaky_bucket_reset`

```nim
proc lfq_leaky_bucket_reset(bucket: ptr lfq_leaky_bucket_t) {.
    exportc: "lfq_leaky_bucket_reset", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_stream_ring_create`

```nim
proc lfq_stream_ring_create(capacity: csize_t; use_virtual_mirror: bool): ptr lfq_stream_ring_t {.
    exportc: "lfq_stream_ring_create", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_stream_ring_destroy`

```nim
proc lfq_stream_ring_destroy(ring: ptr lfq_stream_ring_t) {.
    exportc: "lfq_stream_ring_destroy", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_streambuffer_create`

```nim
proc lfq_streambuffer_create(capacity: csize_t; use_virtual_mirror: bool): ptr lfq_streambuffer_t {.
    exportc: "lfq_streambuffer_create", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_streambuffer_destroy`

```nim
proc lfq_streambuffer_destroy(ring: ptr lfq_streambuffer_t) {.
    exportc: "lfq_streambuffer_destroy", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_stream_ring_capacity`

```nim
proc lfq_stream_ring_capacity(ring: ptr lfq_stream_ring_t): csize_t {.
    exportc: "lfq_stream_ring_capacity", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_stream_ring_available_read`

```nim
proc lfq_stream_ring_available_read(ring: ptr lfq_stream_ring_t): csize_t {.
    exportc: "lfq_stream_ring_available_read", cdecl, gcsafe, raises: [],
    tags: [], forbids: [].}
```

### `lfq_stream_ring_available_write`

```nim
proc lfq_stream_ring_available_write(ring: ptr lfq_stream_ring_t): csize_t {.
    exportc: "lfq_stream_ring_available_write", cdecl, gcsafe, raises: [],
    tags: [], forbids: [].}
```

### `lfq_stream_ring_is_empty`

```nim
proc lfq_stream_ring_is_empty(ring: ptr lfq_stream_ring_t): bool {.
    exportc: "lfq_stream_ring_is_empty", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_stream_ring_is_full`

```nim
proc lfq_stream_ring_is_full(ring: ptr lfq_stream_ring_t): bool {.
    exportc: "lfq_stream_ring_is_full", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_streambuffer_capacity`

```nim
proc lfq_streambuffer_capacity(ring: ptr lfq_streambuffer_t): csize_t {.
    exportc: "lfq_streambuffer_capacity", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_streambuffer_available_read`

```nim
proc lfq_streambuffer_available_read(ring: ptr lfq_streambuffer_t): csize_t {.
    exportc: "lfq_streambuffer_available_read", cdecl, gcsafe, raises: [],
    tags: [], forbids: [].}
```

### `lfq_streambuffer_available_write`

```nim
proc lfq_streambuffer_available_write(ring: ptr lfq_streambuffer_t): csize_t {.
    exportc: "lfq_streambuffer_available_write", cdecl, gcsafe, raises: [],
    tags: [], forbids: [].}
```

### `lfq_streambuffer_is_empty`

```nim
proc lfq_streambuffer_is_empty(ring: ptr lfq_streambuffer_t): bool {.
    exportc: "lfq_streambuffer_is_empty", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_streambuffer_is_full`

```nim
proc lfq_streambuffer_is_full(ring: ptr lfq_streambuffer_t): bool {.
    exportc: "lfq_streambuffer_is_full", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_stream_ring_try_write`

```nim
proc lfq_stream_ring_try_write(ring: ptr lfq_stream_ring_t; src: pointer;
                               len: csize_t): csize_t {.
    exportc: "lfq_stream_ring_try_write", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_stream_ring_try_read`

```nim
proc lfq_stream_ring_try_read(ring: ptr lfq_stream_ring_t; dst: pointer;
                              max_len: csize_t): csize_t {.
    exportc: "lfq_stream_ring_try_read", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_stream_ring_write_blocking`

```nim
proc lfq_stream_ring_write_blocking(ring: ptr lfq_stream_ring_t; src: pointer;
                                    len: csize_t; timeout_ns: int64): csize_t {.
    exportc: "lfq_stream_ring_write_blocking", cdecl, gcsafe, raises: [],
    tags: [TimeEffect], forbids: [].}
```

### `lfq_stream_ring_read_blocking`

```nim
proc lfq_stream_ring_read_blocking(ring: ptr lfq_stream_ring_t; dst: pointer;
                                   max_len: csize_t; timeout_ns: int64): csize_t {.
    exportc: "lfq_stream_ring_read_blocking", cdecl, gcsafe, raises: [],
    tags: [TimeEffect], forbids: [].}
```

### `lfq_streambuffer_try_write`

```nim
proc lfq_streambuffer_try_write(ring: ptr lfq_streambuffer_t; src: pointer;
                                len: csize_t): csize_t {.
    exportc: "lfq_streambuffer_try_write", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_streambuffer_try_read`

```nim
proc lfq_streambuffer_try_read(ring: ptr lfq_streambuffer_t; dst: pointer;
                               max_len: csize_t): csize_t {.
    exportc: "lfq_streambuffer_try_read", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_streambuffer_write_blocking`

```nim
proc lfq_streambuffer_write_blocking(ring: ptr lfq_streambuffer_t; src: pointer;
                                     len: csize_t; timeout_ns: int64): csize_t {.
    exportc: "lfq_streambuffer_write_blocking", cdecl, gcsafe, raises: [],
    tags: [TimeEffect], forbids: [].}
```

### `lfq_streambuffer_read_blocking`

```nim
proc lfq_streambuffer_read_blocking(ring: ptr lfq_streambuffer_t; dst: pointer;
                                    max_len: csize_t; timeout_ns: int64): csize_t {.
    exportc: "lfq_streambuffer_read_blocking", cdecl, gcsafe, raises: [],
    tags: [TimeEffect], forbids: [].}
```

### `lfq_stream_ring_acquire_write_iov`

```nim
proc lfq_stream_ring_acquire_write_iov(ring: ptr lfq_stream_ring_t;
                                       requested_len: csize_t): lfq_iovec_pair_t {.
    exportc: "lfq_stream_ring_acquire_write_iov", cdecl, gcsafe, raises: [],
    tags: [], forbids: [].}
```

### `lfq_stream_ring_commit_write`

```nim
proc lfq_stream_ring_commit_write(ring: ptr lfq_stream_ring_t;
                                  bytes_written: csize_t) {.
    exportc: "lfq_stream_ring_commit_write", cdecl, gcsafe, raises: [],
    tags: [], forbids: [].}
```

### `lfq_stream_ring_acquire_read_iov`

```nim
proc lfq_stream_ring_acquire_read_iov(ring: ptr lfq_stream_ring_t;
                                      requested_len: csize_t): lfq_iovec_pair_t {.
    exportc: "lfq_stream_ring_acquire_read_iov", cdecl, gcsafe, raises: [],
    tags: [], forbids: [].}
```

### `lfq_stream_ring_commit_read`

```nim
proc lfq_stream_ring_commit_read(ring: ptr lfq_stream_ring_t;
                                 bytes_read: csize_t) {.
    exportc: "lfq_stream_ring_commit_read", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_streambuffer_acquire_write_iov`

```nim
proc lfq_streambuffer_acquire_write_iov(ring: ptr lfq_streambuffer_t;
                                        requested_len: csize_t): lfq_iovec_pair_t {.
    exportc: "lfq_streambuffer_acquire_write_iov", cdecl, gcsafe, raises: [],
    tags: [], forbids: [].}
```

### `lfq_streambuffer_commit_write`

```nim
proc lfq_streambuffer_commit_write(ring: ptr lfq_streambuffer_t;
                                   bytes_written: csize_t) {.
    exportc: "lfq_streambuffer_commit_write", cdecl, gcsafe, raises: [],
    tags: [], forbids: [].}
```

### `lfq_streambuffer_acquire_read_iov`

```nim
proc lfq_streambuffer_acquire_read_iov(ring: ptr lfq_streambuffer_t;
                                       requested_len: csize_t): lfq_iovec_pair_t {.
    exportc: "lfq_streambuffer_acquire_read_iov", cdecl, gcsafe, raises: [],
    tags: [], forbids: [].}
```

### `lfq_streambuffer_commit_read`

```nim
proc lfq_streambuffer_commit_read(ring: ptr lfq_streambuffer_t;
                                  bytes_read: csize_t) {.
    exportc: "lfq_streambuffer_commit_read", cdecl, gcsafe, raises: [],
    tags: [], forbids: [].}
```

### `lfq_mpmc_stream_ring_create`

```nim
proc lfq_mpmc_stream_ring_create(capacity: csize_t): ptr lfq_mpmc_stream_ring_t {.
    exportc: "lfq_mpmc_stream_ring_create", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_mpmc_stream_ring_destroy`

```nim
proc lfq_mpmc_stream_ring_destroy(ring: ptr lfq_mpmc_stream_ring_t) {.
    exportc: "lfq_mpmc_stream_ring_destroy", cdecl, gcsafe, raises: [],
    tags: [], forbids: [].}
```

### `lfq_mpmc_stream_ring_capacity`

```nim
proc lfq_mpmc_stream_ring_capacity(ring: ptr lfq_mpmc_stream_ring_t): csize_t {.
    exportc: "lfq_mpmc_stream_ring_capacity", cdecl, gcsafe, raises: [],
    tags: [], forbids: [].}
```

### `lfq_mpmc_stream_ring_available_read`

```nim
proc lfq_mpmc_stream_ring_available_read(ring: ptr lfq_mpmc_stream_ring_t): csize_t {.
    exportc: "lfq_mpmc_stream_ring_available_read", cdecl, gcsafe, raises: [],
    tags: [], forbids: [].}
```

### `lfq_mpmc_stream_ring_available_write`

```nim
proc lfq_mpmc_stream_ring_available_write(ring: ptr lfq_mpmc_stream_ring_t): csize_t {.
    exportc: "lfq_mpmc_stream_ring_available_write", cdecl, gcsafe, raises: [],
    tags: [], forbids: [].}
```

### `lfq_mpmc_stream_ring_is_empty`

```nim
proc lfq_mpmc_stream_ring_is_empty(ring: ptr lfq_mpmc_stream_ring_t): bool {.
    exportc: "lfq_mpmc_stream_ring_is_empty", cdecl, gcsafe, raises: [],
    tags: [], forbids: [].}
```

### `lfq_mpmc_stream_ring_is_full`

```nim
proc lfq_mpmc_stream_ring_is_full(ring: ptr lfq_mpmc_stream_ring_t): bool {.
    exportc: "lfq_mpmc_stream_ring_is_full", cdecl, gcsafe, raises: [],
    tags: [], forbids: [].}
```

### `lfq_mpmc_stream_ring_try_write`

```nim
proc lfq_mpmc_stream_ring_try_write(ring: ptr lfq_mpmc_stream_ring_t;
                                    src: pointer; len: csize_t): csize_t {.
    exportc: "lfq_mpmc_stream_ring_try_write", cdecl, gcsafe, raises: [],
    tags: [], forbids: [].}
```

### `lfq_mpmc_stream_ring_try_read`

```nim
proc lfq_mpmc_stream_ring_try_read(ring: ptr lfq_mpmc_stream_ring_t;
                                   dst: pointer; max_len: csize_t): csize_t {.
    exportc: "lfq_mpmc_stream_ring_try_read", cdecl, gcsafe, raises: [],
    tags: [], forbids: [].}
```

### `lfq_ctrie_compute_if_absent`

```nim
proc lfq_ctrie_compute_if_absent(trie: ptr lfq_ctrie_t; key: pointer;
                                 key_len: csize_t; mapping_fn: lfq_mapping_fn;
                                 user_data: pointer; out_val: ptr pointer;
                                 out_val_len: ptr csize_t): bool {.
    exportc: "lfq_ctrie_compute_if_absent", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lfq_ctrie_atomic_update`

```nim
proc lfq_ctrie_atomic_update(trie: ptr lfq_ctrie_t; key: pointer;
                             key_len: csize_t; update_fn: lfq_update_fn;
                             user_data: pointer; out_val: ptr pointer;
                             out_val_len: ptr csize_t): bool {.
    exportc: "lfq_ctrie_atomic_update", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lfq_skiplist_compute_if_absent`

```nim
proc lfq_skiplist_compute_if_absent(map: ptr lfq_table_t; key: pointer;
                                    key_len: csize_t;
                                    mapping_fn: lfq_mapping_fn;
                                    user_data: pointer; out_val: ptr pointer;
                                    out_val_len: ptr csize_t): bool {.
    exportc: "lfq_skiplist_compute_if_absent", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lfq_skiplist_atomic_update`

```nim
proc lfq_skiplist_atomic_update(map: ptr lfq_table_t; key: pointer;
                                key_len: csize_t; update_fn: lfq_update_fn;
                                user_data: pointer; out_val: ptr pointer;
                                out_val_len: ptr csize_t): bool {.
    exportc: "lfq_skiplist_atomic_update", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lfq_table_compute_if_absent`

```nim
proc lfq_table_compute_if_absent(map: ptr lfq_table_t; key: pointer;
                                 key_len: csize_t; mapping_fn: lfq_mapping_fn;
                                 user_data: pointer; out_val: ptr pointer;
                                 out_val_len: ptr csize_t): bool {.
    exportc: "lfq_table_compute_if_absent", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lfq_table_atomic_update`

```nim
proc lfq_table_atomic_update(map: ptr lfq_table_t; key: pointer;
                             key_len: csize_t; update_fn: lfq_update_fn;
                             user_data: pointer; out_val: ptr pointer;
                             out_val_len: ptr csize_t): bool {.
    exportc: "lfq_table_atomic_update", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lfq_arc_guard_create`

```nim
proc lfq_arc_guard_create(item: pointer; destructor: lfq_arc_destructor_fn;
                          userData: pointer; outGuard: ptr ptr lfq_arc_guard_t): lfq_status_t {.
    exportc: "lfq_arc_guard_create", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_arc_guard_get`

```nim
proc lfq_arc_guard_get(guard: ptr lfq_arc_guard_t): pointer {.
    exportc: "lfq_arc_guard_get", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_arc_guard_clone`

```nim
proc lfq_arc_guard_clone(guard: ptr lfq_arc_guard_t;
                         outClone: ptr ptr lfq_arc_guard_t): lfq_status_t {.
    exportc: "lfq_arc_guard_clone", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_arc_guard_release`

```nim
proc lfq_arc_guard_release(guard: ptr lfq_arc_guard_t): lfq_status_t {.
    exportc: "lfq_arc_guard_release", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lfq_atomic_arc_create`

```nim
proc lfq_atomic_arc_create(initialItem: pointer;
                           destructor: lfq_arc_destructor_fn; userData: pointer;
                           outArc: ptr ptr lfq_atomic_arc_t): lfq_status_t {.
    exportc: "lfq_atomic_arc_create", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_atomic_arc_destroy`

```nim
proc lfq_atomic_arc_destroy(arc: ptr lfq_atomic_arc_t): lfq_status_t {.
    exportc: "lfq_atomic_arc_destroy", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lfq_atomic_arc_is_null`

```nim
proc lfq_atomic_arc_is_null(arc: ptr lfq_atomic_arc_t): bool {.
    exportc: "lfq_atomic_arc_is_null", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_atomic_arc_load`

```nim
proc lfq_atomic_arc_load(arc: ptr lfq_atomic_arc_t;
                         outGuard: ptr ptr lfq_arc_guard_t): lfq_status_t {.
    exportc: "lfq_atomic_arc_load", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lfq_atomic_arc_store`

```nim
proc lfq_atomic_arc_store(arc: ptr lfq_atomic_arc_t; newItem: pointer;
                          destructor: lfq_arc_destructor_fn; userData: pointer): lfq_status_t {.
    exportc: "lfq_atomic_arc_store", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lfq_atomic_arc_store_guard`

```nim
proc lfq_atomic_arc_store_guard(arc: ptr lfq_atomic_arc_t;
                                guard: ptr lfq_arc_guard_t): lfq_status_t {.
    exportc: "lfq_atomic_arc_store_guard", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lfq_atomic_arc_swap`

```nim
proc lfq_atomic_arc_swap(arc: ptr lfq_atomic_arc_t; newItem: pointer;
                         destructor: lfq_arc_destructor_fn; userData: pointer;
                         outOldGuard: ptr ptr lfq_arc_guard_t): lfq_status_t {.
    exportc: "lfq_atomic_arc_swap", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_atomic_arc_swap_guard`

```nim
proc lfq_atomic_arc_swap_guard(arc: ptr lfq_atomic_arc_t;
                               guard: ptr lfq_arc_guard_t;
                               outOldGuard: ptr ptr lfq_arc_guard_t): lfq_status_t {.
    exportc: "lfq_atomic_arc_swap_guard", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_atomic_arc_compare_exchange_guard`

```nim
proc lfq_atomic_arc_compare_exchange_guard(arc: ptr lfq_atomic_arc_t;
    inoutExpected: ptr ptr lfq_arc_guard_t; desired: ptr lfq_arc_guard_t;
    outSwapped: ptr bool): lfq_status_t {.
    exportc: "lfq_atomic_arc_compare_exchange_guard", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lfq_atomic_arc_compare_exchange`

```nim
proc lfq_atomic_arc_compare_exchange(arc: ptr lfq_atomic_arc_t;
                                     inoutExpected: ptr ptr lfq_arc_guard_t;
                                     desiredItem: pointer;
                                     destructor: lfq_arc_destructor_fn;
                                     userData: pointer; outSwapped: ptr bool): lfq_status_t {.
    exportc: "lfq_atomic_arc_compare_exchange", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lfq_pqueue_create`

```nim
proc lfq_pqueue_create(destructor: lfq_pqueue_destructor_fn; user_data: pointer;
                       out_pqueue: ptr ptr lfq_pqueue_t): lfq_status_t {.
    exportc: "lfq_pqueue_create", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lfq_pqueue_clear`

```nim
proc lfq_pqueue_clear(pqueue: ptr lfq_pqueue_t): lfq_status_t {.
    exportc: "lfq_pqueue_clear", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lfq_pqueue_destroy`

```nim
proc lfq_pqueue_destroy(pqueue: ptr lfq_pqueue_t): lfq_status_t {.
    exportc: "lfq_pqueue_destroy", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lfq_pqueue_push`

```nim
proc lfq_pqueue_push(pqueue: ptr lfq_pqueue_t; priority: int64; item: pointer): lfq_status_t {.
    exportc: "lfq_pqueue_push", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lfq_pqueue_pop_min`

```nim
proc lfq_pqueue_pop_min(pqueue: ptr lfq_pqueue_t; out_priority: ptr int64;
                        out_item: ptr pointer): lfq_status_t {.
    exportc: "lfq_pqueue_pop_min", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lfq_pqueue_peek_min`

```nim
proc lfq_pqueue_peek_min(pqueue: ptr lfq_pqueue_t; out_priority: ptr int64;
                         out_item: ptr pointer): lfq_status_t {.
    exportc: "lfq_pqueue_peek_min", cdecl, gcsafe, raises: [],
    tags: [TypestateOp, RootEffect], forbids: [].}
```

### `lfq_pqueue_len`

```nim
proc lfq_pqueue_len(pqueue: ptr lfq_pqueue_t): csize_t {.
    exportc: "lfq_pqueue_len", cdecl, gcsafe, raises: [], tags: [], forbids: [].}
```

### `lfq_pqueue_is_empty`

```nim
proc lfq_pqueue_is_empty(pqueue: ptr lfq_pqueue_t): bool {.
    exportc: "lfq_pqueue_is_empty", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_flat_combiner_create`

```nim
proc lfq_flat_combiner_create(state: pointer;
                              default_op_fn: lfq_flat_combiner_op_fn;
    state_destructor: lfq_flat_combiner_state_destructor_fn; user_data: pointer;
                              max_combining_rounds: csize_t;
                              cleanup_interval: csize_t;
                              out_combiner: ptr ptr lfq_flat_combiner_t): lfq_status_t {.
    exportc: "lfq_flat_combiner_create", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_flat_combiner_destroy`

```nim
proc lfq_flat_combiner_destroy(combiner: ptr lfq_flat_combiner_t): lfq_status_t {.
    exportc: "lfq_flat_combiner_destroy", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lfq_flat_combiner_combine`

```nim
proc lfq_flat_combiner_combine(combiner: ptr lfq_flat_combiner_t;
                               op_arg: pointer; out_result: ptr pointer): lfq_status_t {.
    exportc: "lfq_flat_combiner_combine", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_flat_combiner_combine_fn`

```nim
proc lfq_flat_combiner_combine_fn(combiner: ptr lfq_flat_combiner_t;
                                  op_fn: lfq_flat_combiner_op_fn;
                                  op_arg: pointer; op_user_data: pointer;
                                  out_result: ptr pointer): lfq_status_t {.
    exportc: "lfq_flat_combiner_combine_fn", cdecl, gcsafe, raises: [],
    tags: [], forbids: [].}
```

### `lfq_flat_combiner_pass_count`

```nim
proc lfq_flat_combiner_pass_count(combiner: ptr lfq_flat_combiner_t): uint64 {.
    exportc: "lfq_flat_combiner_pass_count", cdecl, gcsafe, raises: [],
    tags: [], forbids: [].}
```

### `lfq_flat_combiner_total_combined_ops`

```nim
proc lfq_flat_combiner_total_combined_ops(combiner: ptr lfq_flat_combiner_t): uint64 {.
    exportc: "lfq_flat_combiner_total_combined_ops", cdecl, gcsafe, raises: [],
    tags: [], forbids: [].}
```

### `lfq_flat_combiner_active_records`

```nim
proc lfq_flat_combiner_active_records(combiner: ptr lfq_flat_combiner_t): csize_t {.
    exportc: "lfq_flat_combiner_active_records", cdecl, gcsafe, raises: [],
    tags: [], forbids: [].}
```

### `lfq_bstack_create`

```nim
proc lfq_bstack_create(capacity: csize_t; destructor: lfq_item_destructor_fn;
                       user_data: pointer; out_stack: ptr ptr lfq_bstack_t): lfq_status_t {.
    exportc: "lfq_bstack_create", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_bstack_destroy`

```nim
proc lfq_bstack_destroy(stack: ptr lfq_bstack_t): lfq_status_t {.
    exportc: "lfq_bstack_destroy", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lfq_bstack_push`

```nim
proc lfq_bstack_push(stack: ptr lfq_bstack_t; item: pointer): lfq_status_t {.
    exportc: "lfq_bstack_push", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lfq_bstack_pop`

```nim
proc lfq_bstack_pop(stack: ptr lfq_bstack_t; out_item: ptr pointer): lfq_status_t {.
    exportc: "lfq_bstack_pop", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lfq_bstack_peek`

```nim
proc lfq_bstack_peek(stack: ptr lfq_bstack_t; out_item: ptr pointer): lfq_status_t {.
    exportc: "lfq_bstack_peek", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lfq_bstack_drain`

```nim
proc lfq_bstack_drain(stack: ptr lfq_bstack_t; out_items: ptr pointer;
                      max_count: csize_t): csize_t {.
    exportc: "lfq_bstack_drain", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lfq_bstack_clear`

```nim
proc lfq_bstack_clear(stack: ptr lfq_bstack_t): lfq_status_t {.
    exportc: "lfq_bstack_clear", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lfq_bstack_len`

```nim
proc lfq_bstack_len(stack: ptr lfq_bstack_t): csize_t {.
    exportc: "lfq_bstack_len", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lfq_bstack_capacity`

```nim
proc lfq_bstack_capacity(stack: ptr lfq_bstack_t): csize_t {.
    exportc: "lfq_bstack_capacity", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lfq_bstack_is_empty`

```nim
proc lfq_bstack_is_empty(stack: ptr lfq_bstack_t): bool {.
    exportc: "lfq_bstack_is_empty", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lfq_bstack_is_full`

```nim
proc lfq_bstack_is_full(stack: ptr lfq_bstack_t): bool {.
    exportc: "lfq_bstack_is_full", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lfq_bpqueue_create`

```nim
proc lfq_bpqueue_create(capacity: csize_t; destructor: lfq_item_destructor_fn;
                        user_data: pointer; out_pqueue: ptr ptr lfq_bpqueue_t): lfq_status_t {.
    exportc: "lfq_bpqueue_create", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_bpqueue_destroy`

```nim
proc lfq_bpqueue_destroy(pqueue: ptr lfq_bpqueue_t): lfq_status_t {.
    exportc: "lfq_bpqueue_destroy", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lfq_bpqueue_push`

```nim
proc lfq_bpqueue_push(pqueue: ptr lfq_bpqueue_t; priority: int64; item: pointer): lfq_status_t {.
    exportc: "lfq_bpqueue_push", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lfq_bpqueue_pop_min`

```nim
proc lfq_bpqueue_pop_min(pqueue: ptr lfq_bpqueue_t; out_priority: ptr int64;
                         out_item: ptr pointer): lfq_status_t {.
    exportc: "lfq_bpqueue_pop_min", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lfq_bpqueue_peek_min`

```nim
proc lfq_bpqueue_peek_min(pqueue: ptr lfq_bpqueue_t; out_priority: ptr int64;
                          out_item: ptr pointer): lfq_status_t {.
    exportc: "lfq_bpqueue_peek_min", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lfq_bpqueue_clear`

```nim
proc lfq_bpqueue_clear(pqueue: ptr lfq_bpqueue_t): lfq_status_t {.
    exportc: "lfq_bpqueue_clear", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lfq_bpqueue_len`

```nim
proc lfq_bpqueue_len(pqueue: ptr lfq_bpqueue_t): csize_t {.
    exportc: "lfq_bpqueue_len", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lfq_bpqueue_capacity`

```nim
proc lfq_bpqueue_capacity(pqueue: ptr lfq_bpqueue_t): csize_t {.
    exportc: "lfq_bpqueue_capacity", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lfq_bpqueue_is_empty`

```nim
proc lfq_bpqueue_is_empty(pqueue: ptr lfq_bpqueue_t): bool {.
    exportc: "lfq_bpqueue_is_empty", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lfq_bpqueue_is_full`

```nim
proc lfq_bpqueue_is_full(pqueue: ptr lfq_bpqueue_t): bool {.
    exportc: "lfq_bpqueue_is_full", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lfq_btable_create`

```nim
proc lfq_btable_create(capacity: csize_t; destructor: lfq_btable_destructor_fn;
                       user_data: pointer; out_table: ptr ptr lfq_btable_t): lfq_status_t {.
    exportc: "lfq_btable_create", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_btable_destroy`

```nim
proc lfq_btable_destroy(table: ptr lfq_btable_t): lfq_status_t {.
    exportc: "lfq_btable_destroy", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lfq_btable_put`

```nim
proc lfq_btable_put(table: ptr lfq_btable_t; key: pointer; val: pointer;
                    out_inserted: ptr bool): lfq_status_t {.
    exportc: "lfq_btable_put", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lfq_btable_insert`

```nim
proc lfq_btable_insert(table: ptr lfq_btable_t; key: pointer; val: pointer;
                       out_inserted: ptr bool): lfq_status_t {.
    exportc: "lfq_btable_insert", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lfq_btable_get`

```nim
proc lfq_btable_get(table: ptr lfq_btable_t; key: pointer; out_val: ptr pointer): lfq_status_t {.
    exportc: "lfq_btable_get", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lfq_btable_delete`

```nim
proc lfq_btable_delete(table: ptr lfq_btable_t; key: pointer;
                       out_deleted: ptr bool): lfq_status_t {.
    exportc: "lfq_btable_delete", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lfq_btable_remove`

```nim
proc lfq_btable_remove(table: ptr lfq_btable_t; key: pointer;
                       out_removed: ptr bool): lfq_status_t {.
    exportc: "lfq_btable_remove", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lfq_btable_take`

```nim
proc lfq_btable_take(table: ptr lfq_btable_t; key: pointer; out_val: ptr pointer): lfq_status_t {.
    exportc: "lfq_btable_take", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lfq_btable_contains`

```nim
proc lfq_btable_contains(table: ptr lfq_btable_t; key: pointer): bool {.
    exportc: "lfq_btable_contains", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lfq_btable_compute_if_absent`

```nim
proc lfq_btable_compute_if_absent(table: ptr lfq_btable_t; key: pointer;
                                  mapping_fn: lfq_btable_mapping_fn;
                                  user_data: pointer; out_val: ptr pointer): lfq_status_t {.
    exportc: "lfq_btable_compute_if_absent", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lfq_btable_atomic_update`

```nim
proc lfq_btable_atomic_update(table: ptr lfq_btable_t; key: pointer;
                              update_fn: lfq_btable_update_fn;
                              user_data: pointer; out_val: ptr pointer): lfq_status_t {.
    exportc: "lfq_btable_atomic_update", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lfq_btable_upsert`

```nim
proc lfq_btable_upsert(table: ptr lfq_btable_t; key: pointer;
                       initial_val: pointer; update_fn: lfq_btable_update_fn;
                       user_data: pointer; out_val: ptr pointer): lfq_status_t {.
    exportc: "lfq_btable_upsert", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lfq_btable_clear`

```nim
proc lfq_btable_clear(table: ptr lfq_btable_t): lfq_status_t {.
    exportc: "lfq_btable_clear", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lfq_btable_len`

```nim
proc lfq_btable_len(table: ptr lfq_btable_t): csize_t {.
    exportc: "lfq_btable_len", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lfq_btable_capacity`

```nim
proc lfq_btable_capacity(table: ptr lfq_btable_t): csize_t {.
    exportc: "lfq_btable_capacity", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lfq_btable_is_empty`

```nim
proc lfq_btable_is_empty(table: ptr lfq_btable_t): bool {.
    exportc: "lfq_btable_is_empty", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lfq_btable_is_full`

```nim
proc lfq_btable_is_full(table: ptr lfq_btable_t): bool {.
    exportc: "lfq_btable_is_full", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lfq_bqueue128_create`

```nim
proc lfq_bqueue128_create(capacity: csize_t;
                          destructor: lfq_bqueue128_destructor_fn;
                          user_data: pointer; out_queue: ptr ptr lfq_bqueue128_t): lfq_status_t {.
    exportc: "lfq_bqueue128_create", cdecl, gcsafe, raises: [], tags: [],
    forbids: [].}
```

### `lfq_bqueue128_destroy`

```nim
proc lfq_bqueue128_destroy(queue: ptr lfq_bqueue128_t): lfq_status_t {.
    exportc: "lfq_bqueue128_destroy", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lfq_bqueue128_push`

```nim
proc lfq_bqueue128_push(queue: ptr lfq_bqueue128_t; item: pointer): lfq_status_t {.
    exportc: "lfq_bqueue128_push", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lfq_bqueue128_pop`

```nim
proc lfq_bqueue128_pop(queue: ptr lfq_bqueue128_t; out_item: ptr pointer): lfq_status_t {.
    exportc: "lfq_bqueue128_pop", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lfq_bqueue128_peek`

```nim
proc lfq_bqueue128_peek(queue: ptr lfq_bqueue128_t; out_item: ptr pointer): lfq_status_t {.
    exportc: "lfq_bqueue128_peek", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lfq_bqueue128_clear`

```nim
proc lfq_bqueue128_clear(queue: ptr lfq_bqueue128_t): lfq_status_t {.
    exportc: "lfq_bqueue128_clear", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lfq_bqueue128_len`

```nim
proc lfq_bqueue128_len(queue: ptr lfq_bqueue128_t): csize_t {.
    exportc: "lfq_bqueue128_len", cdecl, gcsafe, raises: [], tags: [RootEffect],
    forbids: [].}
```

### `lfq_bqueue128_capacity`

```nim
proc lfq_bqueue128_capacity(queue: ptr lfq_bqueue128_t): csize_t {.
    exportc: "lfq_bqueue128_capacity", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lfq_bqueue128_is_empty`

```nim
proc lfq_bqueue128_is_empty(queue: ptr lfq_bqueue128_t): bool {.
    exportc: "lfq_bqueue128_is_empty", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

### `lfq_bqueue128_is_full`

```nim
proc lfq_bqueue128_is_full(queue: ptr lfq_bqueue128_t): bool {.
    exportc: "lfq_bqueue128_is_full", cdecl, gcsafe, raises: [],
    tags: [RootEffect], forbids: [].}
```

