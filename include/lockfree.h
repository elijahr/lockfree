#ifndef LOCKFREE_H
#define LOCKFREE_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

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

typedef struct lfq_queue     lfq_queue_t;
typedef struct lfq_producer  lfq_producer_t;
typedef struct lfq_consumer  lfq_consumer_t;
typedef void (*lfq_item_destructor_fn)(void* item, void* user_data);

/* Lifecycle */
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

lfq_status_t lfq_queue_destroy(lfq_queue_t* queue);

/* Thread Registration */
lfq_status_t lfq_producer_acquire(lfq_queue_t* queue, lfq_producer_t** out_prod);
lfq_status_t lfq_producer_release(lfq_producer_t* prod);

lfq_status_t lfq_consumer_acquire(lfq_queue_t* queue, lfq_consumer_t** out_cons);
lfq_status_t lfq_consumer_release(lfq_consumer_t* cons);

/* Fast-Path Operations (Pointer Payload) */
lfq_status_t lfq_push(lfq_producer_t* prod, void* item);
lfq_status_t lfq_pop(lfq_consumer_t* cons, void** out_item);

/* Batch Operations */
size_t lfq_pop_batch(lfq_consumer_t* cons, void** out_items, size_t max_count);

/* Introspection */
size_t lfq_queue_len(const lfq_queue_t* queue);
bool lfq_queue_is_empty(const lfq_queue_t* queue);

#ifdef __cplusplus
}
#endif

#endif /* LOCKFREE_H */
