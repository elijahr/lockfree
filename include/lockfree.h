#ifndef LOCKFREE_H
#define LOCKFREE_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* -------------------------------------------------------------------------
 * Status Codes & Common Types
 * ------------------------------------------------------------------------- */

#ifndef LF_STATUS_DEFINED
#define LF_STATUS_DEFINED
typedef enum lf_status {
    LF_ERR_PANIC           = -2,
    LF_ERR_FAILURE         = -1,
    LF_OK                  =  0,
    LF_ERR_EMPTY           =  1,
    LF_ERR_FULL            =  2,
    LF_ERR_CLOSED          =  3,
    LF_ERR_INVALID_ARG     =  4,
    LF_ERR_REGISTRY_FULL   =  5,
    LF_ERR_UNSUPPORTED     =  6
} lf_status_t;

#ifndef LFQ_STATUS_DEFINED
#define LFQ_STATUS_DEFINED
#define lfq_status_t lf_status_t
#define lfq_status lf_status
#define LFQ_OK                  LF_OK
#define LFQ_ERR_EMPTY           LF_ERR_EMPTY
#define LFQ_ERR_FULL            LF_ERR_FULL
#define LFQ_ERR_CLOSED          LF_ERR_CLOSED
#define LFQ_ERR_INVALID_ARG     LF_ERR_INVALID_ARG
#define LFQ_ERR_REGISTRY_FULL   LF_ERR_REGISTRY_FULL
#define LFQ_ERR_UNSUPPORTED     LF_ERR_UNSUPPORTED
#define LFQ_ERR_FAILURE         LF_ERR_FAILURE
#define LFQ_ERR_PANIC           LF_ERR_PANIC
#endif
#endif

typedef void (*lf_item_destructor_fn)(void* item, void* user_data);
#define lfq_item_destructor_fn lf_item_destructor_fn

/* -------------------------------------------------------------------------
 * 1. Queue (MPMC FIFO Queue)
 * ------------------------------------------------------------------------- */

typedef struct lf_queue     lf_queue_t;
typedef struct lf_producer  lf_producer_t;
typedef struct lf_consumer  lf_consumer_t;
#define lfq_queue lf_queue
#define lfq_queue_t lf_queue_t
#define lfq_producer lf_producer
#define lfq_producer_t lf_producer_t
#define lfq_consumer lf_consumer
#define lfq_consumer_t lf_consumer_t

/* Queue Lifecycle */
lf_status_t lf_unbounded_mpmc_create(
    size_t segment_size,
    size_t max_threads,
    lf_item_destructor_fn destructor,
    void* user_data,
    lf_queue_t** out_queue
);
#define lfq_unbounded_mpmc_create lf_unbounded_mpmc_create

lf_status_t lf_bounded_mpmc_create(
    size_t capacity,
    size_t max_producers,
    size_t max_consumers,
    lf_item_destructor_fn destructor,
    void* user_data,
    lf_queue_t** out_queue
);
#define lfq_bounded_mpmc_create lf_bounded_mpmc_create

lf_status_t lf_queue_close(lf_queue_t* queue);
#define lfq_queue_close lf_queue_close
lf_status_t lf_queue_destroy(lf_queue_t* queue);
#define lfq_queue_destroy lf_queue_destroy

/* Queue Thread Registration */
lf_status_t lf_producer_acquire(lf_queue_t* queue, lf_producer_t** out_prod);
#define lfq_producer_acquire lf_producer_acquire
lf_status_t lf_producer_release(lf_producer_t* prod);
#define lfq_producer_release lf_producer_release

lf_status_t lf_consumer_acquire(lf_queue_t* queue, lf_consumer_t** out_cons);
#define lfq_consumer_acquire lf_consumer_acquire
lf_status_t lf_consumer_release(lf_consumer_t* cons);
#define lfq_consumer_release lf_consumer_release

/* Queue Fast-Path Operations (Pointer Payload) */
lf_status_t lf_push(lf_producer_t* prod, void* item);
#define lfq_push lf_push
lf_status_t lf_pop(lf_consumer_t* cons, void** out_item);
#define lfq_pop lf_pop
lf_status_t lf_queue_push(lf_producer_t* prod, void* item);
#define lfq_queue_push lf_queue_push
lf_status_t lf_queue_pop(lf_consumer_t* cons, void** out_item);
#define lfq_queue_pop lf_queue_pop

/* Queue Batch Operations */
size_t lf_pop_batch(lf_consumer_t* cons, void** out_items, size_t max_count);
#define lfq_pop_batch lf_pop_batch

/* Queue Introspection */
size_t lf_queue_len(const lf_queue_t* queue);
#define lfq_queue_len lf_queue_len
bool lf_queue_is_empty(const lf_queue_t* queue);
#define lfq_queue_is_empty lf_queue_is_empty
bool lf_queue_is_closed(const lf_queue_t* queue);
#define lfq_queue_is_closed lf_queue_is_closed

/* -------------------------------------------------------------------------
 * 2. Stack (MPMC LIFO Stack with Elimination-Backoff)
 * ------------------------------------------------------------------------- */

typedef struct lf_stack lf_stack_t;
#define lfq_stack lf_stack
#define lfq_stack_t lf_stack_t

/* Stack Lifecycle */
lf_status_t lf_stack_create(
    lf_item_destructor_fn destructor,
    void* user_data,
    lf_stack_t** out_stack
);
#define lfq_stack_create lf_stack_create
lf_status_t lf_stack_destroy(lf_stack_t* stack);
#define lfq_stack_destroy lf_stack_destroy

/* Stack Operations */
lf_status_t lf_stack_push(lf_stack_t* stack, void* item);
#define lfq_stack_push lf_stack_push
lf_status_t lf_stack_pop(lf_stack_t* stack, void** out_item);
#define lfq_stack_pop lf_stack_pop
lf_status_t lf_stack_peek(const lf_stack_t* stack, void** out_item);
#define lfq_stack_peek lf_stack_peek
size_t lf_stack_drain(lf_stack_t* stack, void** out_items, size_t max_count);
#define lfq_stack_drain lf_stack_drain

/* Stack Introspection */
size_t lf_stack_len(const lf_stack_t* stack);
#define lfq_stack_len lf_stack_len
bool lf_stack_is_empty(const lf_stack_t* stack);
#define lfq_stack_is_empty lf_stack_is_empty

/* -------------------------------------------------------------------------
 * 3. Deque (Single-Worker / Multi-Thief Work-Stealing Deque)
 * ------------------------------------------------------------------------- */

typedef struct lf_deque lf_deque_t;
#define lfq_deque lf_deque
#define lfq_deque_t lf_deque_t

/* Deque Lifecycle */
lf_status_t lf_deque_create(
    size_t initial_capacity,
    lf_item_destructor_fn destructor,
    void* user_data,
    lf_deque_t** out_deque
);
#define lfq_deque_create lf_deque_create
lf_status_t lf_deque_destroy(lf_deque_t* deque);
#define lfq_deque_destroy lf_deque_destroy

/* Worker Operations (Single-Worker Thread) */
lf_status_t lf_deque_push(lf_deque_t* deque, void* item);
#define lfq_deque_push lf_deque_push
lf_status_t lf_deque_pop(lf_deque_t* deque, void** out_item);
#define lfq_deque_pop lf_deque_pop

/* Thief Operations (Concurrent Multi-Thief Threads) */
lf_status_t lf_deque_steal(lf_deque_t* deque, void** out_item);
#define lfq_deque_steal lf_deque_steal
size_t lf_deque_steal_batch(lf_deque_t* deque, void** out_items, size_t max_count);
#define lfq_deque_steal_batch lf_deque_steal_batch

/* Deque Introspection */
size_t lf_deque_len(const lf_deque_t* deque);
#define lfq_deque_len lf_deque_len
size_t lf_deque_capacity(const lf_deque_t* deque);
#define lfq_deque_capacity lf_deque_capacity
bool lf_deque_is_empty(const lf_deque_t* deque);
#define lfq_deque_is_empty lf_deque_is_empty

/* -------------------------------------------------------------------------
 * 4. Table (MPMC Ordered Key-Value Map based on SkipListMap)
 * ------------------------------------------------------------------------- */

#ifndef LFQ_TABLE_DEFINED
#define LFQ_TABLE_DEFINED
typedef struct lf_table lf_table_t;
#define lfq_table lf_table
#define lfq_table_t lf_table_t
#endif

typedef void (*lf_entry_destructor_fn)(void* key, void* val, void* user_data);
#define lfq_entry_destructor_fn lf_entry_destructor_fn

/* Table Lifecycle */
lf_status_t lf_table_create(
    lf_entry_destructor_fn destructor,
    void* user_data,
    lf_table_t** out_table
);
#define lfq_table_create lf_table_create
lf_status_t lf_table_destroy(lf_table_t* table);
#define lfq_table_destroy lf_table_destroy

/* Table Operations */
lf_status_t lf_table_put(lf_table_t* table, void* key, void* val, bool* out_inserted);
#define lfq_table_put lf_table_put
lf_status_t lf_table_get(const lf_table_t* table, void* key, void** out_val);
#define lfq_table_get lf_table_get
lf_status_t lf_table_delete(lf_table_t* table, void* key, bool* out_deleted);
#define lfq_table_delete lf_table_delete
lf_status_t lf_table_remove(lf_table_t* table, void* key, bool* out_removed);
#define lfq_table_remove lf_table_remove
bool lf_table_contains(const lf_table_t* table, void* key);
#define lfq_table_contains lf_table_contains

/* Table Introspection */
size_t lf_table_len(const lf_table_t* table);
#define lfq_table_len lf_table_len
bool lf_table_is_empty(const lf_table_t* table);
#define lfq_table_is_empty lf_table_is_empty

/* -------------------------------------------------------------------------
 * 5. Set (MPMC Ordered Set based on SkipListSet)
 * ------------------------------------------------------------------------- */

typedef struct lf_set lf_set_t;
#define lfq_set lf_set
#define lfq_set_t lf_set_t

/* Set Lifecycle */
lf_status_t lf_set_create(
    lf_item_destructor_fn destructor,
    void* user_data,
    lf_set_t** out_set
);
#define lfq_set_create lf_set_create
lf_status_t lf_set_destroy(lf_set_t* set);
#define lfq_set_destroy lf_set_destroy

/* Set Operations */
lf_status_t lf_set_insert(lf_set_t* set, void* item, bool* out_inserted);
#define lfq_set_insert lf_set_insert
lf_status_t lf_set_remove(lf_set_t* set, void* item, bool* out_removed);
#define lfq_set_remove lf_set_remove
bool lf_set_contains(const lf_set_t* set, void* item);
#define lfq_set_contains lf_set_contains

/* Set Introspection */
size_t lf_set_len(const lf_set_t* set);
#define lfq_set_len lf_set_len
bool lf_set_is_empty(const lf_set_t* set);
#define lfq_set_is_empty lf_set_is_empty

/* -------------------------------------------------------------------------
 * 6. TaskPool (Work-Stealing Task Scheduler)
 * ------------------------------------------------------------------------- */

typedef struct lf_taskpool lf_taskpool_t;
#define lfq_taskpool lf_taskpool
#define lfq_taskpool_t lf_taskpool_t

typedef void (*lf_task_fn)(void* arg);
#define lfq_task_fn lf_task_fn
typedef void (*lf_for_task_fn)(size_t index, void* arg);
#define lfq_for_task_fn lf_for_task_fn

/* TaskPool Lifecycle */
lf_status_t lf_taskpool_create(
    size_t num_threads,
    lf_taskpool_t** out_pool
);
#define lfq_taskpool_create lf_taskpool_create
lf_status_t lf_taskpool_destroy(lf_taskpool_t* pool);
#define lfq_taskpool_destroy lf_taskpool_destroy

/* TaskPool Operations */
lf_status_t lf_taskpool_spawn(
    lf_taskpool_t* pool,
    lf_task_fn task,
    void* arg
);
#define lfq_taskpool_spawn lf_taskpool_spawn
lf_status_t lf_taskpool_parallel_for(
    lf_taskpool_t* pool,
    size_t start,
    size_t stop,
    lf_for_task_fn task,
    void* arg,
    size_t chunk_size
);
#define lfq_taskpool_parallel_for lf_taskpool_parallel_for
lf_status_t lf_taskpool_sync(lf_taskpool_t* pool);
#define lfq_taskpool_sync lf_taskpool_sync
size_t lf_taskpool_num_workers(const lf_taskpool_t* pool);
#define lfq_taskpool_num_workers lf_taskpool_num_workers

/* -------------------------------------------------------------------------
 * 7. Ctrie (MPMC Lock-Free Concurrent Hash Trie with Wait-Free Snapshots)
 * ------------------------------------------------------------------------- */

#ifndef LFQ_CTRIE_DEFINED
#define LFQ_CTRIE_DEFINED
typedef struct lf_ctrie lf_ctrie_t;
#define lfq_ctrie lf_ctrie
#define lfq_ctrie_t lf_ctrie_t
#endif
typedef struct lf_ctrie_snapshot lf_ctrie_snapshot_t;
#define lfq_ctrie_snapshot lf_ctrie_snapshot
#define lfq_ctrie_snapshot_t lf_ctrie_snapshot_t

/* Ctrie Lifecycle */
lf_status_t lf_ctrie_create(
    lf_entry_destructor_fn destructor,
    void* user_data,
    lf_ctrie_t** out_ctrie
);
#define lfq_ctrie_create lf_ctrie_create
lf_status_t lf_ctrie_destroy(lf_ctrie_t* ctrie);
#define lfq_ctrie_destroy lf_ctrie_destroy

/* Ctrie Operations */
lf_status_t lf_ctrie_insert(
    lf_ctrie_t* ctrie,
    void* key,
    void* val,
    bool* out_inserted
);
#define lfq_ctrie_insert lf_ctrie_insert
lf_status_t lf_ctrie_put(
    lf_ctrie_t* ctrie,
    void* key,
    void* val,
    bool* out_inserted
);
#define lfq_ctrie_put lf_ctrie_put
lf_status_t lf_ctrie_lookup(
    const lf_ctrie_t* ctrie,
    void* key,
    void** out_val
);
#define lfq_ctrie_lookup lf_ctrie_lookup
lf_status_t lf_ctrie_get(
    const lf_ctrie_t* ctrie,
    void* key,
    void** out_val
);
#define lfq_ctrie_get lf_ctrie_get
lf_status_t lf_ctrie_remove(
    lf_ctrie_t* ctrie,
    void* key,
    bool* out_removed
);
#define lfq_ctrie_remove lf_ctrie_remove
lf_status_t lf_ctrie_delete(
    lf_ctrie_t* ctrie,
    void* key,
    bool* out_deleted
);
#define lfq_ctrie_delete lf_ctrie_delete
bool lf_ctrie_contains(const lf_ctrie_t* ctrie, void* key);
#define lfq_ctrie_contains lf_ctrie_contains

/* Ctrie Introspection */
size_t lf_ctrie_len(const lf_ctrie_t* ctrie);
#define lfq_ctrie_len lf_ctrie_len
bool lf_ctrie_is_empty(const lf_ctrie_t* ctrie);
#define lfq_ctrie_is_empty lf_ctrie_is_empty

/* Ctrie Wait-Free Snapshot Operations */
lf_status_t lf_ctrie_snapshot(
    lf_ctrie_t* ctrie,
    lf_ctrie_snapshot_t** out_snapshot
);
#define lfq_ctrie_snapshot lf_ctrie_snapshot
lf_status_t lf_ctrie_snapshot_create(
    lf_ctrie_t* ctrie,
    lf_ctrie_snapshot_t** out_snapshot
);
#define lfq_ctrie_snapshot_create lf_ctrie_snapshot_create
lf_status_t lf_ctrie_snapshot_destroy(
    lf_ctrie_snapshot_t* snapshot
);
#define lfq_ctrie_snapshot_destroy lf_ctrie_snapshot_destroy
lf_status_t lf_ctrie_snapshot_lookup(
    const lf_ctrie_snapshot_t* snapshot,
    void* key,
    void** out_val
);
#define lfq_ctrie_snapshot_lookup lf_ctrie_snapshot_lookup
lf_status_t lf_ctrie_snapshot_get(
    const lf_ctrie_snapshot_t* snapshot,
    void* key,
    void** out_val
);
#define lfq_ctrie_snapshot_get lf_ctrie_snapshot_get
bool lf_ctrie_snapshot_contains(
    const lf_ctrie_snapshot_t* snapshot,
    void* key
);
#define lfq_ctrie_snapshot_contains lf_ctrie_snapshot_contains
size_t lf_ctrie_snapshot_len(
    const lf_ctrie_snapshot_t* snapshot
);
#define lfq_ctrie_snapshot_len lf_ctrie_snapshot_len
bool lf_ctrie_snapshot_is_empty(
    const lf_ctrie_snapshot_t* snapshot
);
#define lfq_ctrie_snapshot_is_empty lf_ctrie_snapshot_is_empty

/* -------------------------------------------------------------------------
 * 8. BroadcastRing (MPMC / SPMC Multicast Broadcast Ring Buffer)
 * ------------------------------------------------------------------------- */

typedef struct lf_broadcast lf_broadcast_t;
#define lfq_broadcast lf_broadcast
#define lfq_broadcast_t lf_broadcast_t
typedef struct lf_broadcast_cursor lf_broadcast_cursor_t;
#define lfq_broadcast_cursor lf_broadcast_cursor
#define lfq_broadcast_cursor_t lf_broadcast_cursor_t

typedef enum lf_overflow_mode {

    LF_OVERFLOW_DROP_OLDEST = 0,
    LF_OVERFLOW_BACKOFF     = 1

} lf_overflow_mode_t;
#define lfq_overflow_mode lf_overflow_mode
#define lfq_overflow_mode_t lf_overflow_mode_t
#define LFQ_OVERFLOW_DROP_OLDEST LF_OVERFLOW_DROP_OLDEST
#define LFQ_OVERFLOW_BACKOFF LF_OVERFLOW_BACKOFF

typedef enum lf_sub_origin {

    LF_SUB_FROM_LATEST   = 0,
    LF_SUB_FROM_EARLIEST = 1

} lf_sub_origin_t;
#define lfq_sub_origin lf_sub_origin
#define lfq_sub_origin_t lf_sub_origin_t
#define LFQ_SUB_FROM_LATEST LF_SUB_FROM_LATEST
#define LFQ_SUB_FROM_EARLIEST LF_SUB_FROM_EARLIEST

typedef enum lf_poll_result {

    LF_POLL_SUCCESS = 0,
    LF_POLL_EMPTY   = 1,
    LF_POLL_LAGGED  = 2

} lf_poll_result_t;
#define lfq_poll_result lf_poll_result
#define lfq_poll_result_t lf_poll_result_t
#define LFQ_POLL_SUCCESS LF_POLL_SUCCESS
#define LFQ_POLL_EMPTY LF_POLL_EMPTY
#define LFQ_POLL_LAGGED LF_POLL_LAGGED

/* BroadcastRing Lifecycle */
lf_status_t lf_broadcast_create(
    size_t capacity,
    lf_overflow_mode_t overflow_mode,
    size_t max_readers,
    lf_broadcast_t** out_broadcast
);
#define lfq_broadcast_create lf_broadcast_create
lf_status_t lf_broadcast_destroy(lf_broadcast_t* broadcast);
#define lfq_broadcast_destroy lf_broadcast_destroy

/* BroadcastRing Publishing */
lf_status_t lf_broadcast_publish(lf_broadcast_t* broadcast, void* item);
#define lfq_broadcast_publish lf_broadcast_publish

/* BroadcastRing Subscription & Cursor Operations */
lf_status_t lf_broadcast_subscribe(
    lf_broadcast_t* broadcast,
    lf_sub_origin_t origin,
    lf_broadcast_cursor_t** out_cursor
);
#define lfq_broadcast_subscribe lf_broadcast_subscribe
lf_status_t lf_broadcast_unsubscribe(lf_broadcast_cursor_t* cursor);
#define lfq_broadcast_unsubscribe lf_broadcast_unsubscribe

/* Cursor Consumption */
lf_status_t lf_broadcast_poll(
    lf_broadcast_cursor_t* cursor,
    void** out_item,
    size_t* out_skipped_count,
    lf_poll_result_t* out_result
);
#define lfq_broadcast_poll lf_broadcast_poll
lf_status_t lf_broadcast_try_read(
    lf_broadcast_cursor_t* cursor,
    void** out_item
);
#define lfq_broadcast_try_read lf_broadcast_try_read

/* BroadcastRing Introspection */
size_t lf_broadcast_len(const lf_broadcast_t* broadcast);
#define lfq_broadcast_len lf_broadcast_len
size_t lf_broadcast_capacity(const lf_broadcast_t* broadcast);
#define lfq_broadcast_capacity lf_broadcast_capacity
size_t lf_broadcast_subscriber_count(const lf_broadcast_t* broadcast);
#define lfq_broadcast_subscriber_count lf_broadcast_subscriber_count
bool lf_broadcast_is_empty(const lf_broadcast_t* broadcast);
#define lfq_broadcast_is_empty lf_broadcast_is_empty
size_t lf_broadcast_cursor_lag(const lf_broadcast_cursor_t* cursor);
#define lfq_broadcast_cursor_lag lf_broadcast_cursor_lag

/* -------------------------------------------------------------------------
 * 8b. TopicBus (Concurrent Multi-Topic Broadcast Bus backed by Ctrie)
 * ------------------------------------------------------------------------- */

typedef struct lf_topic_bus lf_topic_bus_t;
#define lfq_topic_bus lf_topic_bus
#define lfq_topic_bus_t lf_topic_bus_t

/* TopicBus Lifecycle */
lf_status_t lf_topic_bus_create(
    size_t default_capacity,
    lf_overflow_mode_t default_overflow_mode,
    size_t default_max_readers,
    lf_topic_bus_t** out_bus
);
#define lfq_topic_bus_create lf_topic_bus_create
lf_status_t lf_topic_bus_destroy(lf_topic_bus_t* bus);
#define lfq_topic_bus_destroy lf_topic_bus_destroy

/* TopicBus Publishing & Subscription (returns a standard lf_broadcast_cursor_t) */
lf_status_t lf_topic_bus_publish(
    lf_topic_bus_t* bus,
    const char* topic,
    void* item
);
#define lfq_topic_bus_publish lf_topic_bus_publish
lf_status_t lf_topic_bus_subscribe(
    lf_topic_bus_t* bus,
    const char* topic,
    lf_sub_origin_t origin,
    lf_broadcast_cursor_t** out_cursor
);
#define lfq_topic_bus_subscribe lf_topic_bus_subscribe

/* TopicBus Introspection */
size_t lf_topic_bus_topic_count(const lf_topic_bus_t* bus);
#define lfq_topic_bus_topic_count lf_topic_bus_topic_count
bool lf_topic_bus_has_topic(const lf_topic_bus_t* bus, const char* topic);
#define lfq_topic_bus_has_topic lf_topic_bus_has_topic

/* -------------------------------------------------------------------------
 * 9. RendezvousChannel (Zero-Buffer Synchronous Dual Channel)
 * ------------------------------------------------------------------------- */

#include "lockfree_rendezvous.h"

/* -------------------------------------------------------------------------
 * 10. Rate Limiters (Hardware 128-Bit DWCAS TokenBucket & LeakyBucket)
 * ------------------------------------------------------------------------- */

#include "lockfree_ratelimit.h"

/* -------------------------------------------------------------------------
 * 11. Stream Ring / Stream Buffer (Zero-Copy Streaming I/O)
 * ------------------------------------------------------------------------- */

#include "lockfree_streambuffer.h"

/* -------------------------------------------------------------------------
 * 12. Atomic Associative Map Operations (Ctrie & SkipListMap)
 * ------------------------------------------------------------------------- */

#include "lockfree_associative.h"

/* -------------------------------------------------------------------------
 * 13. Lock-Free 128-Bit DWCAS Atomic Shared Pointer (AtomicArc & ArcGuard)
 * ------------------------------------------------------------------------- */

#include "lockfree_atomic_arc.h"

/* -------------------------------------------------------------------------
 * 14. Lock-Free Priority Queue (Lindén-Jonsson SkipListPriorityQueue)
 * ------------------------------------------------------------------------- */

#include "lockfree_pqueue.h"

/* -------------------------------------------------------------------------
 * 15. Flat Combiner (Hendler-Incze-Shavit-Tzafrir Synchronization Adapter)
 * ------------------------------------------------------------------------- */

#include "lockfree_flat_combiner.h"

/* -------------------------------------------------------------------------
 * 16. Bounded Zero-SMR Lock-Free Stack (BStack)
 * ------------------------------------------------------------------------- */

#include "lockfree_bstack.h"

/* -------------------------------------------------------------------------
 * 17. Bounded Zero-SMR Binary Min-Heap Priority Queue (BPriorityQueue)
 * ------------------------------------------------------------------------- */

#include "lockfree_bpqueue.h"

/* -------------------------------------------------------------------------
 * 18. Bounded Zero-SMR Robin Hood Open-Addressing Hash Table (BTable)
 * ------------------------------------------------------------------------- */

#include "lockfree_btable.h"

#ifdef __cplusplus
}
#endif

#endif /* LOCKFREE_H */
