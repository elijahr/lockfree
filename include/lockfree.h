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

typedef struct lfq_table lfq_table_t;

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

#ifdef __cplusplus
}
#endif

#endif /* LOCKFREE_H */
