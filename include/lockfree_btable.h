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
 * @brief Optional cleanup callback invoked for remaining `(key, val)` entries
 * when the bounded table is cleared or destroyed.
 */
typedef void (*lfq_btable_destructor_fn)(void* key, void* val, void* user_data);

/**
 * @brief Factory callback invoked under the table combiner lease by
 * `lfq_btable_compute_if_absent` when `key` is not present.
 */
typedef void* (*lfq_btable_mapping_fn)(const void* key, void* user_data);
typedef lfq_btable_mapping_fn lfq_map_compute_fn;

/**
 * @brief In-place update callback invoked under the table combiner lease by
 * `lfq_btable_atomic_update` and `lfq_btable_upsert` when `key` is present.
 */
typedef void* (*lfq_btable_update_fn)(const void* key, void* old_val, void* user_data);
typedef lfq_btable_update_fn lfq_map_merge_fn;

/* ==========================================================================
 * 2. Opaque Handle & C ABI Operations (lfq_btable_*)
 * ========================================================================== */

#ifndef LFQ_BTABLE_DEFINED
#define LFQ_BTABLE_DEFINED
/**
 * @brief Opaque handle to a preallocated zero-SMR bounded concurrent hash table.
 */
typedef struct lfq_btable lfq_btable_t;
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
lfq_status_t lfq_btable_create(
    size_t capacity,
    lfq_btable_destructor_fn destructor,
    void* user_data,
    lfq_btable_t** out_table
);

/**
 * @brief Destroys a bounded hash table, invoking `destructor` (if non-NULL)
 * on any remaining active entries and releasing the preallocated storage block.
 *
 * @param table Bounded table handle.
 * @return LFQ_OK on success, or LFQ_ERR_INVALID_ARG if `table == NULL`.
 */
lfq_status_t lfq_btable_destroy(lfq_btable_t* table);

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
lfq_status_t lfq_btable_put(
    lfq_btable_t* table,
    void* key,
    void* val,
    bool* out_inserted
);

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
lfq_status_t lfq_btable_insert(
    lfq_btable_t* table,
    void* key,
    void* val,
    bool* out_inserted
);

/**
 * @brief Looks up `key` in the bounded table.
 *
 * @param table   Bounded table handle.
 * @param key     Key pointer (`void*`).
 * @param out_val Out-pointer receiving the associated value (`void*`).
 * @return LFQ_OK if found, LFQ_ERR_EMPTY if `key` is absent,
 *         or LFQ_ERR_INVALID_ARG if `table == NULL` or `out_val == NULL`.
 */
lfq_status_t lfq_btable_get(
    const lfq_btable_t* table,
    void* key,
    void** out_val
);

/**
 * @brief Removes `key` from the bounded table if present.
 *
 * @param table       Bounded table handle.
 * @param key         Key pointer (`void*`).
 * @param out_deleted Optional out-pointer set to `true` if removed, `false` if absent (may be NULL).
 * @return LFQ_OK if `key` was found and removed, LFQ_ERR_EMPTY if `key` was absent,
 *         or LFQ_ERR_INVALID_ARG if `table == NULL`.
 */
lfq_status_t lfq_btable_delete(
    lfq_btable_t* table,
    void* key,
    bool* out_deleted
);

/**
 * @brief Alias for `lfq_btable_delete`.
 */
lfq_status_t lfq_btable_remove(
    lfq_btable_t* table,
    void* key,
    bool* out_removed
);

/**
 * @brief Atomically removes `key` and returns its associated value in `*out_val`.
 *
 * @param table   Bounded table handle.
 * @param key     Key pointer (`void*`).
 * @param out_val Out-pointer receiving the removed value (`void*`).
 * @return LFQ_OK if `key` was removed, LFQ_ERR_EMPTY if `key` was absent,
 *         or LFQ_ERR_INVALID_ARG if `table == NULL` or `out_val == NULL`.
 */
lfq_status_t lfq_btable_take(
    lfq_btable_t* table,
    void* key,
    void** out_val
);

/**
 * @brief Returns `true` if `key` is currently present in the bounded table.
 */
bool lfq_btable_contains(
    const lfq_btable_t* table,
    void* key
);

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
lfq_status_t lfq_btable_compute_if_absent(
    lfq_btable_t* table,
    void* key,
    lfq_btable_mapping_fn mapping_fn,
    void* user_data,
    void** out_val
);

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
lfq_status_t lfq_btable_atomic_update(
    lfq_btable_t* table,
    void* key,
    lfq_btable_update_fn update_fn,
    void* user_data,
    void** out_val
);

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
lfq_status_t lfq_btable_upsert(
    lfq_btable_t* table,
    void* key,
    void* initial_val,
    lfq_btable_update_fn update_fn,
    void* user_data,
    void** out_val
);

/**
 * @brief Clears all entries from the bounded table (invoking the configured
 * `destructor`, if any, on each active `(key, val)` pair) and resets all probe
 * slots to `Empty`.
 *
 * @param table Bounded table handle.
 * @return LFQ_OK on success, or LFQ_ERR_INVALID_ARG if `table == NULL`.
 */
lfq_status_t lfq_btable_clear(lfq_btable_t* table);

/**
 * @brief Returns the current number of active key-value entries (`0 .. capacity`).
 */
size_t lfq_btable_len(const lfq_btable_t* table);

/**
 * @brief Returns the configured entry capacity of the bounded table (`0` if `table == NULL`).
 */
size_t lfq_btable_capacity(const lfq_btable_t* table);

/**
 * @brief Returns `true` if the bounded table is empty or `NULL`.
 */
bool lfq_btable_is_empty(const lfq_btable_t* table);

/**
 * @brief Returns `true` if the bounded table has reached capacity (`false` if `table == NULL`).
 */
bool lfq_btable_is_full(const lfq_btable_t* table);

#ifdef __cplusplus
}
#endif

#endif /* LOCKFREE_BTABLE_H */
