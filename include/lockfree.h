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

#ifdef __cplusplus
}
#endif

#endif /* LOCKFREE_H */
