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

/**
 * @brief Optional cleanup callback invoked for remaining payloads when the
 * priority queue is destroyed.
 */
typedef void (*lf_pqueue_destructor_fn)(void* item, void* user_data);
#define lfq_pqueue_destructor_fn lf_pqueue_destructor_fn

/* ==========================================================================
 * 2. Opaque Handle & C ABI Operations (lfq_pqueue_*)
 * ========================================================================== */

/**
 * @brief Opaque handle to a lock-free concurrent priority queue.
 */
typedef struct lf_pqueue lf_pqueue_t;
#define lfq_pqueue lf_pqueue
#define lfq_pqueue_t lf_pqueue_t

/**
 * @brief Creates a new lock-free concurrent priority queue.
 *
 * @param destructor Optional callback invoked on remaining items during destroy (may be NULL).
 * @param user_data  Optional opaque user context passed to destructor (may be NULL).
 * @param out_pqueue Out-pointer receiving the allocated priority queue handle.
 * @return LFQ_OK on success, or LFQ_ERR_INVALID_ARG / LFQ_ERR_FAILURE.
 */
lf_status_t lf_pqueue_create(
    lf_pqueue_destructor_fn destructor,
    void* user_data,
    lf_pqueue_t** out_pqueue
);
#define lfq_pqueue_create lf_pqueue_create

/**
 * @brief Destroys a lock-free priority queue and releases all internal resources.
 *
 * @param pqueue Priority queue handle.
 * @return LFQ_OK on success, or LFQ_ERR_INVALID_ARG.
 */
lf_status_t lf_pqueue_destroy(lf_pqueue_t* pqueue);
#define lfq_pqueue_destroy lf_pqueue_destroy

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
lf_status_t lf_pqueue_push(
    lf_pqueue_t* pqueue,
    int64_t priority,
    void* item
);
#define lfq_pqueue_push lf_pqueue_push

/**
 * @brief Atomically removes and returns the minimum-priority entry.
 *
 * @param pqueue       Priority queue handle.
 * @param out_priority Optional out-pointer receiving the popped priority (may be NULL).
 * @param out_item     Out-pointer receiving the popped payload pointer (`void*`).
 * @return LFQ_OK if an item was popped, LFQ_ERR_EMPTY if the queue is empty,
 *         or LFQ_ERR_INVALID_ARG.
 */
lf_status_t lf_pqueue_pop_min(
    lf_pqueue_t* pqueue,
    int64_t* out_priority,
    void** out_item
);
#define lfq_pqueue_pop_min lf_pqueue_pop_min

/**
 * @brief Inspects the minimum-priority entry without removing it.
 *
 * @param pqueue       Priority queue handle.
 * @param out_priority Optional out-pointer receiving the minimum priority (may be NULL).
 * @param out_item     Out-pointer receiving the minimum payload pointer (`void*`).
 * @return LFQ_OK if an item was observed, LFQ_ERR_EMPTY if the queue is empty,
 *         or LFQ_ERR_INVALID_ARG.
 */
lf_status_t lf_pqueue_peek_min(
    const lf_pqueue_t* pqueue,
    int64_t* out_priority,
    void** out_item
);
#define lfq_pqueue_peek_min lf_pqueue_peek_min

/**
 * @brief Clears all entries from the priority queue (invoking the configured
 * destructor, if any, on each removed item).
 *
 * @param pqueue Priority queue handle.
 * @return LFQ_OK on success, or LFQ_ERR_INVALID_ARG.
 */
lf_status_t lf_pqueue_clear(lf_pqueue_t* pqueue);
#define lfq_pqueue_clear lf_pqueue_clear

/**
 * @brief Returns the approximate number of active items in the priority queue.
 *
 * @param pqueue Priority queue handle.
 * @return Current active item count (0 if `pqueue` is NULL or empty).
 */
size_t lf_pqueue_len(const lf_pqueue_t* pqueue);
#define lfq_pqueue_len lf_pqueue_len

/**
 * @brief Returns `true` if the priority queue currently contains no active items.
 *
 * @param pqueue Priority queue handle.
 * @return `true` if empty or NULL, `false` otherwise.
 */
bool lf_pqueue_is_empty(const lf_pqueue_t* pqueue);
#define lfq_pqueue_is_empty lf_pqueue_is_empty

#ifdef __cplusplus
}
#endif

#endif /* LOCKFREE_PQUEUE_H */
