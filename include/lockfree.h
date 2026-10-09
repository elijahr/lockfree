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

#ifndef LFQ_STATUS_DEFINED
#define LFQ_STATUS_DEFINED
typedef enum lfq_status {
    LFQ_OK                  =  0,
    LFQ_ERR_EMPTY           =  1,
    LFQ_ERR_FULL            =  2,
    LFQ_ERR_CLOSED          =  3,
    LFQ_ERR_INVALID_ARG     =  4,
    LFQ_ERR_REGISTRY_FULL   =  5,
    LFQ_ERR_UNSUPPORTED     =  6,
    LFQ_ERR_FAILURE         = -1,
    LFQ_ERR_PANIC           = -2
} lfq_status_t;
#endif

typedef void (*lfq_item_destructor_fn)(void* item, void* user_data);

/* -------------------------------------------------------------------------
 * 1. Queue (MPMC FIFO Queue)
 * ------------------------------------------------------------------------- */

typedef struct lfq_queue     lfq_queue_t;
typedef struct lfq_producer  lfq_producer_t;
typedef struct lfq_consumer  lfq_consumer_t;

/* Queue Lifecycle */
lfq_status_t lfq_unbounded_mpmc_create(
    size_t segment_size,
    size_t max_threads,
    lfq_item_destructor_fn destructor,
    void* user_data,
    lfq_queue_t** out_queue
);

lfq_status_t lfq_bounded_mpmc_create(
    size_t capacity,
    size_t max_producers,
    size_t max_consumers,
    lfq_item_destructor_fn destructor,
    void* user_data,
    lfq_queue_t** out_queue
);

lfq_status_t lfq_queue_close(lfq_queue_t* queue);
lfq_status_t lfq_queue_destroy(lfq_queue_t* queue);

/* Queue Thread Registration */
lfq_status_t lfq_producer_acquire(lfq_queue_t* queue, lfq_producer_t** out_prod);
lfq_status_t lfq_producer_release(lfq_producer_t* prod);

lfq_status_t lfq_consumer_acquire(lfq_queue_t* queue, lfq_consumer_t** out_cons);
lfq_status_t lfq_consumer_release(lfq_consumer_t* cons);

/* Queue Fast-Path Operations (Pointer Payload) */
lfq_status_t lfq_push(lfq_producer_t* prod, void* item);
lfq_status_t lfq_pop(lfq_consumer_t* cons, void** out_item);
lfq_status_t lfq_queue_push(lfq_producer_t* prod, void* item);
lfq_status_t lfq_queue_pop(lfq_consumer_t* cons, void** out_item);

/* Queue Batch Operations */
size_t lfq_pop_batch(lfq_consumer_t* cons, void** out_items, size_t max_count);

/* Queue Introspection */
size_t lfq_queue_len(const lfq_queue_t* queue);
bool lfq_queue_is_empty(const lfq_queue_t* queue);
bool lfq_queue_is_closed(const lfq_queue_t* queue);

/* -------------------------------------------------------------------------
 * 2. Stack (MPMC LIFO Stack with Elimination-Backoff)
 * ------------------------------------------------------------------------- */

typedef struct lfq_stack lfq_stack_t;

/* Stack Lifecycle */
lfq_status_t lfq_stack_create(
    lfq_item_destructor_fn destructor,
    void* user_data,
    lfq_stack_t** out_stack
);
lfq_status_t lfq_stack_destroy(lfq_stack_t* stack);

/* Stack Operations */
lfq_status_t lfq_stack_push(lfq_stack_t* stack, void* item);
lfq_status_t lfq_stack_pop(lfq_stack_t* stack, void** out_item);
lfq_status_t lfq_stack_peek(const lfq_stack_t* stack, void** out_item);
size_t lfq_stack_drain(lfq_stack_t* stack, void** out_items, size_t max_count);

/* Stack Introspection */
size_t lfq_stack_len(const lfq_stack_t* stack);
bool lfq_stack_is_empty(const lfq_stack_t* stack);

/* -------------------------------------------------------------------------
 * 3. Deque (Single-Worker / Multi-Thief Work-Stealing Deque)
 * ------------------------------------------------------------------------- */

typedef struct lfq_deque lfq_deque_t;

/* Deque Lifecycle */
lfq_status_t lfq_deque_create(
    size_t initial_capacity,
    lfq_item_destructor_fn destructor,
    void* user_data,
    lfq_deque_t** out_deque
);
lfq_status_t lfq_deque_destroy(lfq_deque_t* deque);

/* Worker Operations (Single-Worker Thread) */
lfq_status_t lfq_deque_push(lfq_deque_t* deque, void* item);
lfq_status_t lfq_deque_pop(lfq_deque_t* deque, void** out_item);

/* Thief Operations (Concurrent Multi-Thief Threads) */
lfq_status_t lfq_deque_steal(lfq_deque_t* deque, void** out_item);
size_t lfq_deque_steal_batch(lfq_deque_t* deque, void** out_items, size_t max_count);

/* Deque Introspection */
size_t lfq_deque_len(const lfq_deque_t* deque);
size_t lfq_deque_capacity(const lfq_deque_t* deque);
bool lfq_deque_is_empty(const lfq_deque_t* deque);

/* -------------------------------------------------------------------------
 * 4. Table (MPMC Ordered Key-Value Map based on SkipListMap)
 * ------------------------------------------------------------------------- */

#ifndef LFQ_TABLE_DEFINED
#define LFQ_TABLE_DEFINED
typedef struct lfq_table lfq_table_t;
#endif

typedef void (*lfq_entry_destructor_fn)(void* key, void* val, void* user_data);

/* Table Lifecycle */
lfq_status_t lfq_table_create(
    lfq_entry_destructor_fn destructor,
    void* user_data,
    lfq_table_t** out_table
);
lfq_status_t lfq_table_destroy(lfq_table_t* table);

/* Table Operations */
lfq_status_t lfq_table_put(lfq_table_t* table, void* key, void* val, bool* out_inserted);
lfq_status_t lfq_table_get(const lfq_table_t* table, void* key, void** out_val);
lfq_status_t lfq_table_delete(lfq_table_t* table, void* key, bool* out_deleted);
lfq_status_t lfq_table_remove(lfq_table_t* table, void* key, bool* out_removed);
bool lfq_table_contains(const lfq_table_t* table, void* key);

/* Table Introspection */
size_t lfq_table_len(const lfq_table_t* table);
bool lfq_table_is_empty(const lfq_table_t* table);

/* -------------------------------------------------------------------------
 * 5. Set (MPMC Ordered Set based on SkipListSet)
 * ------------------------------------------------------------------------- */

typedef struct lfq_set lfq_set_t;

/* Set Lifecycle */
lfq_status_t lfq_set_create(
    lfq_item_destructor_fn destructor,
    void* user_data,
    lfq_set_t** out_set
);
lfq_status_t lfq_set_destroy(lfq_set_t* set);

/* Set Operations */
lfq_status_t lfq_set_insert(lfq_set_t* set, void* item, bool* out_inserted);
lfq_status_t lfq_set_remove(lfq_set_t* set, void* item, bool* out_removed);
bool lfq_set_contains(const lfq_set_t* set, void* item);

/* Set Introspection */
size_t lfq_set_len(const lfq_set_t* set);
bool lfq_set_is_empty(const lfq_set_t* set);

/* -------------------------------------------------------------------------
 * 6. TaskPool (Work-Stealing Task Scheduler)
 * ------------------------------------------------------------------------- */

typedef struct lfq_taskpool lfq_taskpool_t;

typedef void (*lfq_task_fn)(void* arg);
typedef void (*lfq_for_task_fn)(size_t index, void* arg);

/* TaskPool Lifecycle */
lfq_status_t lfq_taskpool_create(
    size_t num_threads,
    lfq_taskpool_t** out_pool
);
lfq_status_t lfq_taskpool_destroy(lfq_taskpool_t* pool);

/* TaskPool Operations */
lfq_status_t lfq_taskpool_spawn(
    lfq_taskpool_t* pool,
    lfq_task_fn task,
    void* arg
);
lfq_status_t lfq_taskpool_parallel_for(
    lfq_taskpool_t* pool,
    size_t start,
    size_t stop,
    lfq_for_task_fn task,
    void* arg,
    size_t chunk_size
);
lfq_status_t lfq_taskpool_sync(lfq_taskpool_t* pool);
size_t lfq_taskpool_num_workers(const lfq_taskpool_t* pool);

/* -------------------------------------------------------------------------
 * 7. Ctrie (MPMC Lock-Free Concurrent Hash Trie with Wait-Free Snapshots)
 * ------------------------------------------------------------------------- */

#ifndef LFQ_CTRIE_DEFINED
#define LFQ_CTRIE_DEFINED
typedef struct lfq_ctrie lfq_ctrie_t;
#endif
typedef struct lfq_ctrie_snapshot lfq_ctrie_snapshot_t;

/* Ctrie Lifecycle */
lfq_status_t lfq_ctrie_create(
    lfq_entry_destructor_fn destructor,
    void* user_data,
    lfq_ctrie_t** out_ctrie
);
lfq_status_t lfq_ctrie_destroy(lfq_ctrie_t* ctrie);

/* Ctrie Operations */
lfq_status_t lfq_ctrie_insert(
    lfq_ctrie_t* ctrie,
    void* key,
    void* val,
    bool* out_inserted
);
lfq_status_t lfq_ctrie_put(
    lfq_ctrie_t* ctrie,
    void* key,
    void* val,
    bool* out_inserted
);
lfq_status_t lfq_ctrie_lookup(
    const lfq_ctrie_t* ctrie,
    void* key,
    void** out_val
);
lfq_status_t lfq_ctrie_get(
    const lfq_ctrie_t* ctrie,
    void* key,
    void** out_val
);
lfq_status_t lfq_ctrie_remove(
    lfq_ctrie_t* ctrie,
    void* key,
    bool* out_removed
);
lfq_status_t lfq_ctrie_delete(
    lfq_ctrie_t* ctrie,
    void* key,
    bool* out_deleted
);
bool lfq_ctrie_contains(const lfq_ctrie_t* ctrie, void* key);

/* Ctrie Introspection */
size_t lfq_ctrie_len(const lfq_ctrie_t* ctrie);
bool lfq_ctrie_is_empty(const lfq_ctrie_t* ctrie);

/* Ctrie Wait-Free Snapshot Operations */
lfq_status_t lfq_ctrie_snapshot(
    lfq_ctrie_t* ctrie,
    lfq_ctrie_snapshot_t** out_snapshot
);
lfq_status_t lfq_ctrie_snapshot_create(
    lfq_ctrie_t* ctrie,
    lfq_ctrie_snapshot_t** out_snapshot
);
lfq_status_t lfq_ctrie_snapshot_destroy(
    lfq_ctrie_snapshot_t* snapshot
);
lfq_status_t lfq_ctrie_snapshot_lookup(
    const lfq_ctrie_snapshot_t* snapshot,
    void* key,
    void** out_val
);
lfq_status_t lfq_ctrie_snapshot_get(
    const lfq_ctrie_snapshot_t* snapshot,
    void* key,
    void** out_val
);
bool lfq_ctrie_snapshot_contains(
    const lfq_ctrie_snapshot_t* snapshot,
    void* key
);
size_t lfq_ctrie_snapshot_len(
    const lfq_ctrie_snapshot_t* snapshot
);
bool lfq_ctrie_snapshot_is_empty(
    const lfq_ctrie_snapshot_t* snapshot
);

/* -------------------------------------------------------------------------
 * 8. BroadcastRing (MPMC / SPMC Multicast Broadcast Ring Buffer)
 * ------------------------------------------------------------------------- */

typedef struct lfq_broadcast lfq_broadcast_t;
typedef struct lfq_broadcast_cursor lfq_broadcast_cursor_t;

typedef enum lfq_overflow_mode {
    LFQ_OVERFLOW_DROP_OLDEST = 0,
    LFQ_OVERFLOW_BACKOFF     = 1
} lfq_overflow_mode_t;

typedef enum lfq_sub_origin {
    LFQ_SUB_FROM_LATEST   = 0,
    LFQ_SUB_FROM_EARLIEST = 1
} lfq_sub_origin_t;

typedef enum lfq_poll_result {
    LFQ_POLL_SUCCESS = 0,
    LFQ_POLL_EMPTY   = 1,
    LFQ_POLL_LAGGED  = 2
} lfq_poll_result_t;

/* BroadcastRing Lifecycle */
lfq_status_t lfq_broadcast_create(
    size_t capacity,
    lfq_overflow_mode_t overflow_mode,
    size_t max_readers,
    lfq_broadcast_t** out_broadcast
);
lfq_status_t lfq_broadcast_destroy(lfq_broadcast_t* broadcast);

/* BroadcastRing Publishing */
lfq_status_t lfq_broadcast_publish(lfq_broadcast_t* broadcast, void* item);

/* BroadcastRing Subscription & Cursor Operations */
lfq_status_t lfq_broadcast_subscribe(
    lfq_broadcast_t* broadcast,
    lfq_sub_origin_t origin,
    lfq_broadcast_cursor_t** out_cursor
);
lfq_status_t lfq_broadcast_unsubscribe(lfq_broadcast_cursor_t* cursor);

/* Cursor Consumption */
lfq_status_t lfq_broadcast_poll(
    lfq_broadcast_cursor_t* cursor,
    void** out_item,
    size_t* out_skipped_count,
    lfq_poll_result_t* out_result
);
lfq_status_t lfq_broadcast_try_read(
    lfq_broadcast_cursor_t* cursor,
    void** out_item
);

/* BroadcastRing Introspection */
size_t lfq_broadcast_len(const lfq_broadcast_t* broadcast);
size_t lfq_broadcast_capacity(const lfq_broadcast_t* broadcast);
size_t lfq_broadcast_subscriber_count(const lfq_broadcast_t* broadcast);
bool lfq_broadcast_is_empty(const lfq_broadcast_t* broadcast);
size_t lfq_broadcast_cursor_lag(const lfq_broadcast_cursor_t* cursor);

/* -------------------------------------------------------------------------
 * 9. RendezvousChannel (Zero-Buffer Synchronous Dual Channel)
 * ------------------------------------------------------------------------- */

typedef struct lfq_rendezvous lfq_rendezvous_t;
typedef struct lfq_rendezvous lf_rendezvous_t;

/* RendezvousChannel Lifecycle */
lfq_status_t lfq_rendezvous_create(lfq_rendezvous_t** out_chan);
lfq_status_t lfq_rendezvous_destroy(lfq_rendezvous_t* chan);
lfq_status_t lfq_rendezvous_close(lfq_rendezvous_t* chan);
bool lfq_rendezvous_is_closed(const lfq_rendezvous_t* chan);

/* Blocking Synchronous Handoff */
lfq_status_t lfq_rendezvous_send(
    lfq_rendezvous_t* chan,
    void* payload,
    uint64_t* out_corr_id
);
lfq_status_t lfq_rendezvous_recv(
    lfq_rendezvous_t* chan,
    void** out_payload,
    uint64_t* out_corr_id
);

/* Non-Blocking Synchronous Handoff (0 timeout) */
lfq_status_t lfq_rendezvous_try_send(
    lfq_rendezvous_t* chan,
    void* payload,
    uint64_t* out_corr_id
);
lfq_status_t lfq_rendezvous_try_recv(
    lfq_rendezvous_t* chan,
    void** out_payload,
    uint64_t* out_corr_id
);

/* Bounded Timeout Synchronous Handoff (milliseconds) */
lfq_status_t lfq_rendezvous_send_timeout(
    lfq_rendezvous_t* chan,
    void* payload,
    int32_t timeout_ms,
    uint64_t* out_corr_id
);
lfq_status_t lfq_rendezvous_recv_timeout(
    lfq_rendezvous_t* chan,
    void** out_payload,
    int32_t timeout_ms,
    uint64_t* out_corr_id
);

/* Section 9.1 C-Style Functions */
lf_rendezvous_t* lf_rendezvous_create(void);
void lf_rendezvous_destroy(lf_rendezvous_t* chan);
void lf_rendezvous_close(lf_rendezvous_t* chan);
int lf_rendezvous_send(lf_rendezvous_t* chan, void* payload, uint64_t* out_corr_id);
int lf_rendezvous_recv(lf_rendezvous_t* chan, void** out_payload, uint64_t* out_corr_id);
bool lf_rendezvous_try_send(lf_rendezvous_t* chan, void* payload, uint64_t* out_corr_id);
bool lf_rendezvous_try_recv(lf_rendezvous_t* chan, void** out_payload, uint64_t* out_corr_id);
bool lf_rendezvous_send_timeout(lf_rendezvous_t* chan, void* payload, int timeout_ms, uint64_t* out_corr_id);
bool lf_rendezvous_recv_timeout(lf_rendezvous_t* chan, void** out_payload, int timeout_ms, uint64_t* out_corr_id);

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

#ifdef __cplusplus
}
#endif

#endif /* LOCKFREE_H */


