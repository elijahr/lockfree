/**
 * @file lockfree_flat_combiner.h
 * @brief C99/C11 Foreign Function Interface for Hendler-Incze-Shavit-Tzafrir
 *        Flat Combiner (`lfq_flat_combiner_t`).
 */

#ifndef LOCKFREE_FLAT_COMBINER_H
#define LOCKFREE_FLAT_COMBINER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

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

/* ============================================================================
 * Opaque Handle & Function Pointer Types
 * ============================================================================ */

typedef struct lfq_flat_combiner lfq_flat_combiner_t;

/**
 * @brief Reducer callback executed by the active combiner thread while holding
 *        the combiner lease.
 *
 * @param state      Opaque pointer to the sequential data structure wrapped by the combiner.
 * @param op_arg     Per-operation input argument passed to `lfq_flat_combiner_combine`.
 * @param user_data  User context pointer passed at creation or per-operation.
 * @return           Per-operation result pointer returned to the caller.
 */
typedef void* (*lfq_flat_combiner_op_fn)(void* state, void* op_arg, void* user_data);

/**
 * @brief Optional destructor callback invoked for `state` when
 *        `lfq_flat_combiner_destroy` is called.
 */
typedef void (*lfq_flat_combiner_state_destructor_fn)(void* state, void* user_data);

/* ============================================================================
 * Lifecycle Management
 * ============================================================================ */

/**
 * @brief Allocates and initializes a new Flat Combiner instance wrapping `state`.
 *
 * @param state                  Pointer to the sequential data structure (may be NULL if unused).
 * @param default_op_fn          Default reducer callback used by `lfq_flat_combiner_combine` (may be NULL if only `lfq_flat_combiner_combine_fn` is used).
 * @param state_destructor       Optional destructor invoked on `state` during `lfq_flat_combiner_destroy`.
 * @param user_data              User context pointer passed to `default_op_fn` and `state_destructor`.
 * @param max_combining_rounds   Max consecutive sweeps per combiner lease (0 uses default 16).
 * @param cleanup_interval       Passes between stale publication record pruning (0 uses default 64).
 * @param out_combiner           Out-parameter receiving the newly created `lfq_flat_combiner_t*`.
 * @return `LFQ_OK` on success, `LFQ_ERR_INVALID_ARG` if `out_combiner == NULL`.
 */
lfq_status_t lfq_flat_combiner_create(
    void* state,
    lfq_flat_combiner_op_fn default_op_fn,
    lfq_flat_combiner_state_destructor_fn state_destructor,
    void* user_data,
    size_t max_combining_rounds,
    size_t cleanup_interval,
    lfq_flat_combiner_t** out_combiner
);

/**
 * @brief Destroys a Flat Combiner instance, invoking `state_destructor` (if non-NULL)
 *        and freeing all publication records.
 */
lfq_status_t lfq_flat_combiner_destroy(lfq_flat_combiner_t* combiner);

/* ============================================================================
 * Combining Operations
 * ============================================================================ */

/**
 * @brief Submits `op_arg` to be executed on `state` using the combiner's
 *        `default_op_fn`.
 *
 * @param combiner    Active Flat Combiner handle.
 * @param op_arg      Operation input pointer passed to `default_op_fn`.
 * @param out_result  Optional out-parameter receiving the `void*` return value of `default_op_fn` (may be NULL).
 * @return `LFQ_OK` on success, `LFQ_ERR_INVALID_ARG` if `combiner == NULL` or `default_op_fn == NULL`.
 */
lfq_status_t lfq_flat_combiner_combine(
    lfq_flat_combiner_t* combiner,
    void* op_arg,
    void** out_result
);

/**
 * @brief Submits a custom per-call `op_fn(state, op_arg, op_user_data)` to be
 *        executed under the combiner lease.
 *
 * @param combiner      Active Flat Combiner handle.
 * @param op_fn         Operation callback to execute on `state`.
 * @param op_arg        Operation input pointer passed to `op_fn`.
 * @param op_user_data  Per-operation user context pointer passed to `op_fn`.
 * @param out_result    Optional out-parameter receiving the `void*` return value of `op_fn` (may be NULL).
 * @return `LFQ_OK` on success, `LFQ_ERR_INVALID_ARG` if `combiner == NULL` or `op_fn == NULL`.
 */
lfq_status_t lfq_flat_combiner_combine_fn(
    lfq_flat_combiner_t* combiner,
    lfq_flat_combiner_op_fn op_fn,
    void* op_arg,
    void* op_user_data,
    void** out_result
);

/* ============================================================================
 * Telemetry & Introspection
 * ============================================================================ */

/**
 * @brief Returns the number of combining passes executed by `combiner`.
 */
uint64_t lfq_flat_combiner_pass_count(const lfq_flat_combiner_t* combiner);

/**
 * @brief Returns the total number of operations combined across all passes.
 */
uint64_t lfq_flat_combiner_total_combined_ops(const lfq_flat_combiner_t* combiner);

/**
 * @brief Returns the number of currently linked thread publication records.
 */
size_t lfq_flat_combiner_active_records(const lfq_flat_combiner_t* combiner);

#ifdef __cplusplus
}
#endif

#endif /* LOCKFREE_FLAT_COMBINER_H */
