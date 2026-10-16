/**
 * @file lockfree_pqueue.h
 * @brief Standalone C99/C11 Header for Lindén-Jonsson Lock-Free Priority Queue
 *
 * Exposes the Lindén-Jonsson lock-free concurrent priority queue
 * (`SkipListPriorityQueue`) across the C ABI boundary (`lfq_pqueue_*`),
 * supporting 64-bit signed integer priority keys, `void*` payloads, strict
 * FIFO tie-breaking for duplicate priorities, and optional payload cleanup
 * callbacks upon destruction.
 */

#ifndef LOCKFREE_PQUEUE_H
#define LOCKFREE_PQUEUE_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ==========================================================================
 * 1. Status Codes & Callback Types (Shared with lockfree.h)
 * ========================================================================== */

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

/**
 * @brief Optional cleanup callback invoked for remaining payloads when the
 * priority queue is destroyed.
 */
typedef void (*lfq_pqueue_destructor_fn)(void* item, void* user_data);

/* ==========================================================================
 * 2. Opaque Handle & C ABI Operations (lfq_pqueue_*)
 * ========================================================================== */

/**
 * @brief Opaque handle to a lock-free concurrent priority queue.
 */
typedef struct lfq_pqueue lfq_pqueue_t;

/**
 * @brief Creates a new lock-free concurrent priority queue.
 *
 * @param destructor Optional callback invoked on remaining items during destroy (may be NULL).
 * @param user_data  Optional opaque user context passed to destructor (may be NULL).
 * @param out_pqueue Out-pointer receiving the allocated priority queue handle.
 * @return LFQ_OK on success, or LFQ_ERR_INVALID_ARG / LFQ_ERR_FAILURE.
 */
lfq_status_t lfq_pqueue_create(
    lfq_pqueue_destructor_fn destructor,
    void* user_data,
    lfq_pqueue_t** out_pqueue
);

/**
 * @brief Destroys a lock-free priority queue and releases all internal resources.
 *
 * @param pqueue Priority queue handle.
 * @return LFQ_OK on success, or LFQ_ERR_INVALID_ARG.
 */
lfq_status_t lfq_pqueue_destroy(lfq_pqueue_t* pqueue);

/**
 * @brief Inserts a `(priority, item)` entry into the priority queue.
 * Lower numerical `priority` values are popped first (min-priority queue).
 * Entries with equal `priority` are popped in strict FIFO insertion order.
 *
 * @param pqueue   Priority queue handle.
 * @param priority 64-bit signed priority key (lower = higher priority).
 * @param item     Opaque payload pointer (`void*`).
 * @return LFQ_OK on success, or LFQ_ERR_INVALID_ARG / LFQ_ERR_FAILURE.
 */
lfq_status_t lfq_pqueue_push(
    lfq_pqueue_t* pqueue,
    int64_t priority,
    void* item
);

/**
 * @brief Atomically removes and returns the minimum-priority entry.
 *
 * @param pqueue       Priority queue handle.
 * @param out_priority Optional out-pointer receiving the popped priority (may be NULL).
 * @param out_item     Out-pointer receiving the popped payload pointer (`void*`).
 * @return LFQ_OK if an item was popped, LFQ_ERR_EMPTY if the queue is empty,
 *         or LFQ_ERR_INVALID_ARG.
 */
lfq_status_t lfq_pqueue_pop_min(
    lfq_pqueue_t* pqueue,
    int64_t* out_priority,
    void** out_item
);

/**
 * @brief Inspects the minimum-priority entry without removing it.
 *
 * @param pqueue       Priority queue handle.
 * @param out_priority Optional out-pointer receiving the minimum priority (may be NULL).
 * @param out_item     Out-pointer receiving the minimum payload pointer (`void*`).
 * @return LFQ_OK if an item was observed, LFQ_ERR_EMPTY if the queue is empty,
 *         or LFQ_ERR_INVALID_ARG.
 */
lfq_status_t lfq_pqueue_peek_min(
    const lfq_pqueue_t* pqueue,
    int64_t* out_priority,
    void** out_item
);

/**
 * @brief Clears all entries from the priority queue (invoking the configured
 * destructor, if any, on each removed item).
 *
 * @param pqueue Priority queue handle.
 * @return LFQ_OK on success, or LFQ_ERR_INVALID_ARG.
 */
lfq_status_t lfq_pqueue_clear(lfq_pqueue_t* pqueue);

/**
 * @brief Returns the approximate number of active items in the priority queue.
 *
 * @param pqueue Priority queue handle.
 * @return Current active item count (0 if `pqueue` is NULL or empty).
 */
size_t lfq_pqueue_len(const lfq_pqueue_t* pqueue);

/**
 * @brief Returns `true` if the priority queue currently contains no active items.
 *
 * @param pqueue Priority queue handle.
 * @return `true` if empty or NULL, `false` otherwise.
 */
bool lfq_pqueue_is_empty(const lfq_pqueue_t* pqueue);

#ifdef __cplusplus
}
#endif

#endif /* LOCKFREE_PQUEUE_H */
