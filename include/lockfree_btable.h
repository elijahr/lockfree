/**
 * @file lockfree_btable.h
 * @brief Standalone C99/C11 Header for Preallocated Zero-SMR Bounded Concurrent Hash Table
 *
 * Exposes `BTable[K, V, Cap]` across the C ABI boundary (`lfq_btable_*`),
 * providing a preallocated, zero-SMR, zero-hot-path-heap-allocation concurrent
 * hash table backed by a tombstone-aware open-addressing probe array (`<= 50%`
 * load factor) with atomic `put`, `insert`, `get`, `delete`/`remove`, `take`,
 * `compute_if_absent`, `atomic_update`, `upsert`, and `clear`.
 */

#ifndef LOCKFREE_BTABLE_H
#define LOCKFREE_BTABLE_H

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
 * @brief Optional cleanup callback invoked for remaining `(key, val)` entries
 * when the bounded table is cleared or destroyed.
 */
typedef void (*lf_btable_destructor_fn)(void* key, void* val, void* user_data);
#define lfq_btable_destructor_fn lf_btable_destructor_fn

/**
 * @brief Factory callback invoked under the table combiner lease by
 * `lfq_btable_compute_if_absent` when `key` is not present.
 */
typedef void* (*lf_btable_mapping_fn)(const void* key, void* user_data);
#define lfq_btable_mapping_fn lf_btable_mapping_fn
typedef lf_btable_mapping_fn lf_map_compute_fn;
#define lfq_map_compute_fn lf_map_compute_fn

/**
 * @brief In-place update callback invoked under the table combiner lease by
 * `lfq_btable_atomic_update` and `lfq_btable_upsert` when `key` is present.
 */
typedef void* (*lf_btable_update_fn)(const void* key, void* old_val, void* user_data);
#define lfq_btable_update_fn lf_btable_update_fn
typedef lf_btable_update_fn lf_map_merge_fn;
#define lfq_map_merge_fn lf_map_merge_fn

/* ==========================================================================
 * 2. Opaque Handle & C ABI Operations (lfq_btable_*)
 * ========================================================================== */

#ifndef LFQ_BTABLE_DEFINED
#define LFQ_BTABLE_DEFINED
/**
 * @brief Opaque handle to a preallocated zero-SMR bounded concurrent hash table.
 */
typedef struct lf_btable lf_btable_t;
#define lfq_btable lf_btable
#define lfq_btable_t lf_btable_t
#endif

/**
 * @brief Creates a new preallocated bounded concurrent hash table.
 *
 * @param capacity   Maximum number of active key-value entries (`1 .. 65536`).
 * @param destructor Optional callback invoked on remaining `(key, val)` pairs during clear/destroy (may be NULL).
 * @param user_data  Optional opaque user context passed to destructor (may be NULL).
 * @param out_table  Out-pointer receiving the allocated bounded table handle.
 * @return LFQ_OK on success, LFQ_ERR_INVALID_ARG if `capacity == 0` or `out_table == NULL`,
 *         or LFQ_ERR_UNSUPPORTED if `capacity > 65536`.
 */
lf_status_t lf_btable_create(
    size_t capacity,
    lf_btable_destructor_fn destructor,
    void* user_data,
    lf_btable_t** out_table
);
#define lfq_btable_create lf_btable_create

/**
 * @brief Destroys a bounded hash table, invoking `destructor` (if non-NULL)
 * on any remaining active entries and releasing the preallocated storage block.
 *
 * @param table Bounded table handle.
 * @return LFQ_OK on success, or LFQ_ERR_INVALID_ARG if `table == NULL`.
 */
lf_status_t lf_btable_destroy(lf_btable_t* table);
#define lfq_btable_destroy lf_btable_destroy

/**
 * @brief Inserts `(key, val)` or updates `key`'s value in-place if already present.
 * Updating an existing key at full capacity succeeds (`LFQ_OK`, `*out_inserted = false`).
 *
 * @param table        Bounded table handle.
 * @param key          Key pointer (`void*`).
 * @param val          Value pointer (`void*`).
 * @param out_inserted Optional out-pointer set to `true` if `key` was newly inserted,
 *                     or `false` if an existing key was updated (may be NULL).
 * @return LFQ_OK on insert or update, LFQ_ERR_FULL if `key` is absent and `len == capacity`,
 *         or LFQ_ERR_INVALID_ARG if `table == NULL`.
 */
lf_status_t lf_btable_put(
    lf_btable_t* table,
    void* key,
    void* val,
    bool* out_inserted
);
#define lfq_btable_put lf_btable_put

/**
 * @brief Inserts `(key, val)` only if `key` is not already present.
 * If `key` already exists, leaves the existing value unchanged (`LFQ_OK`, `*out_inserted = false`).
 *
 * @param table        Bounded table handle.
 * @param key          Key pointer (`void*`).
 * @param val          Value pointer (`void*`).
 * @param out_inserted Optional out-pointer set to `true` if `key` was inserted,
 *                     or `false` if `key` already existed or table was full (may be NULL).
 * @return LFQ_OK if inserted or if `key` already existed, LFQ_ERR_FULL if `key` is absent
 *         and `len == capacity`, or LFQ_ERR_INVALID_ARG if `table == NULL`.
 */
lf_status_t lf_btable_insert(
    lf_btable_t* table,
    void* key,
    void* val,
    bool* out_inserted
);
#define lfq_btable_insert lf_btable_insert

/**
 * @brief Looks up `key` in the bounded table.
 *
 * @param table   Bounded table handle.
 * @param key     Key pointer (`void*`).
 * @param out_val Out-pointer receiving the associated value (`void*`).
 * @return LFQ_OK if found, LFQ_ERR_EMPTY if `key` is absent,
 *         or LFQ_ERR_INVALID_ARG if `table == NULL` or `out_val == NULL`.
 */
lf_status_t lf_btable_get(
    const lf_btable_t* table,
    void* key,
    void** out_val
);
#define lfq_btable_get lf_btable_get

/**
 * @brief Removes `key` from the bounded table if present.
 *
 * @param table       Bounded table handle.
 * @param key         Key pointer (`void*`).
 * @param out_deleted Optional out-pointer set to `true` if removed, `false` if absent (may be NULL).
 * @return LFQ_OK if `key` was found and removed, LFQ_ERR_EMPTY if `key` was absent,
 *         or LFQ_ERR_INVALID_ARG if `table == NULL`.
 */
lf_status_t lf_btable_delete(
    lf_btable_t* table,
    void* key,
    bool* out_deleted
);
#define lfq_btable_delete lf_btable_delete

/**
 * @brief Alias for `lfq_btable_delete`.
 */
lf_status_t lf_btable_remove(
    lf_btable_t* table,
    void* key,
    bool* out_removed
);
#define lfq_btable_remove lf_btable_remove

/**
 * @brief Atomically removes `key` and returns its associated value in `*out_val`.
 *
 * @param table   Bounded table handle.
 * @param key     Key pointer (`void*`).
 * @param out_val Out-pointer receiving the removed value (`void*`).
 * @return LFQ_OK if `key` was removed, LFQ_ERR_EMPTY if `key` was absent,
 *         or LFQ_ERR_INVALID_ARG if `table == NULL` or `out_val == NULL`.
 */
lf_status_t lf_btable_take(
    lf_btable_t* table,
    void* key,
    void** out_val
);
#define lfq_btable_take lf_btable_take

/**
 * @brief Returns `true` if `key` is currently present in the bounded table.
 */
bool lf_btable_contains(
    const lf_btable_t* table,
    void* key
);
#define lfq_btable_contains lf_btable_contains

/**
 * @brief Atomically looks up `key`; if absent and `len < capacity`, computes
 * `mapping_fn(key, user_data)`, inserts it, and stores the value in `*out_val`.
 *
 * @param table      Bounded table handle.
 * @param key        Key pointer (`void*`).
 * @param mapping_fn Factory callback invoked only if `key` is absent.
 * @param user_data  Optional user context passed to `mapping_fn`.
 * @param out_val    Optional out-pointer receiving the existing or computed value (may be NULL).
 * @return LFQ_OK if found or computed, LFQ_ERR_FULL if `key` is absent and `len == capacity`,
 *         or LFQ_ERR_INVALID_ARG if `table == NULL` or `mapping_fn == NULL`.
 */
lf_status_t lf_btable_compute_if_absent(
    lf_btable_t* table,
    void* key,
    lf_btable_mapping_fn mapping_fn,
    void* user_data,
    void** out_val
);
#define lfq_btable_compute_if_absent lf_btable_compute_if_absent

/**
 * @brief Atomically updates the value for an existing `key` in-place via
 * `update_fn(key, old_val, user_data)`.
 *
 * @param table     Bounded table handle.
 * @param key       Key pointer (`void*`).
 * @param update_fn Transformation callback invoked when `key` is present.
 * @param user_data Optional user context passed to `update_fn`.
 * @param out_val   Optional out-pointer receiving the updated value (may be NULL).
 * @return LFQ_OK if `key` was found and updated, LFQ_ERR_EMPTY if `key` is absent,
 *         or LFQ_ERR_INVALID_ARG if `table == NULL` or `update_fn == NULL`.
 */
lf_status_t lf_btable_atomic_update(
    lf_btable_t* table,
    void* key,
    lf_btable_update_fn update_fn,
    void* user_data,
    void** out_val
);
#define lfq_btable_atomic_update lf_btable_atomic_update

/**
 * @brief Atomically inserts `(key, initial_val)` if `key` is absent (`len < capacity`),
 * or updates the existing entry via `update_fn(key, old_val, user_data)`.
 *
 * @param table       Bounded table handle.
 * @param key         Key pointer (`void*`).
 * @param initial_val Value inserted when `key` is absent.
 * @param update_fn   Transformation callback invoked when `key` is already present.
 * @param user_data   Optional user context passed to `update_fn`.
 * @param out_val     Optional out-pointer receiving the final value (may be NULL).
 * @return LFQ_OK on insert or update, LFQ_ERR_FULL if `key` is absent and `len == capacity`,
 *         or LFQ_ERR_INVALID_ARG if `table == NULL` or `update_fn == NULL`.
 */
lf_status_t lf_btable_upsert(
    lf_btable_t* table,
    void* key,
    void* initial_val,
    lf_btable_update_fn update_fn,
    void* user_data,
    void** out_val
);
#define lfq_btable_upsert lf_btable_upsert

/**
 * @brief Clears all entries from the bounded table (invoking the configured
 * `destructor`, if any, on each active `(key, val)` pair) and resets all probe
 * slots to `Empty`.
 *
 * @param table Bounded table handle.
 * @return LFQ_OK on success, or LFQ_ERR_INVALID_ARG if `table == NULL`.
 */
lf_status_t lf_btable_clear(lf_btable_t* table);
#define lfq_btable_clear lf_btable_clear

/**
 * @brief Returns the current number of active key-value entries (`0 .. capacity`).
 */
size_t lf_btable_len(const lf_btable_t* table);
#define lfq_btable_len lf_btable_len

/**
 * @brief Returns the configured entry capacity of the bounded table (`0` if `table == NULL`).
 */
size_t lf_btable_capacity(const lf_btable_t* table);
#define lfq_btable_capacity lf_btable_capacity

/**
 * @brief Returns `true` if the bounded table is empty or `NULL`.
 */
bool lf_btable_is_empty(const lf_btable_t* table);
#define lfq_btable_is_empty lf_btable_is_empty

/**
 * @brief Returns `true` if the bounded table has reached capacity (`false` if `table == NULL`).
 */
bool lf_btable_is_full(const lf_btable_t* table);
#define lfq_btable_is_full lf_btable_is_full

#ifdef __cplusplus
}
#endif

#endif /* LOCKFREE_BTABLE_H */
