/**
 * @file lockfree_flat_combiner.h
 * @brief C99/C11 Foreign Function Interface for Hendler-Incze-Shavit-Tzafrir
 *        Flat Combiner (`lf_flat_combiner_t`).
 */

#ifndef LOCKFREE_FLAT_COMBINER_H
#define LOCKFREE_FLAT_COMBINER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

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

/* ============================================================================
 * Opaque Handle & Function Pointer Types
 * ============================================================================ */

typedef struct lf_flat_combiner lf_flat_combiner_t;
#define lfq_flat_combiner lf_flat_combiner
#define lfq_flat_combiner_t lf_flat_combiner_t

/**
 * @brief Reducer callback executed by the active combiner thread while holding
 *        the combiner lease.
 *
 * @param state      Opaque pointer to the sequential data structure wrapped by the combiner.
 * @param op_arg     Per-operation input argument passed to `lfq_flat_combiner_combine`.
 * @param user_data  User context pointer passed at creation or per-operation.
 * @return           Per-operation result pointer returned to the caller.
 */
typedef void* (*lf_flat_combiner_op_fn)(void* state, void* op_arg, void* user_data);
#define lfq_flat_combiner_op_fn lf_flat_combiner_op_fn

/**
 * @brief Optional destructor callback invoked for `state` when
 *        `lfq_flat_combiner_destroy` is called.
 */
typedef void (*lf_flat_combiner_state_destructor_fn)(void* state, void* user_data);
#define lfq_flat_combiner_state_destructor_fn lf_flat_combiner_state_destructor_fn

/* ============================================================================
 * Lifecycle Management
 * ============================================================================ */

/**
 * @brief Allocates and initializes a new Flat Combiner instance wrapping `state`.
 *
 * @param state                  Pointer to the sequential data structure (may be NULL if unused).
 * @param default_op_fn          Default reducer callback used by `lfq_flat_combiner_combine` (may be NULL if only `lf_flat_combiner_combine_fn` is used).
 * @param state_destructor       Optional destructor invoked on `state` during `lfq_flat_combiner_destroy`.
 * @param user_data              User context pointer passed to `default_op_fn` and `state_destructor`.
 * @param max_combining_rounds   Max consecutive sweeps per combiner lease (0 uses default 16).
 * @param cleanup_interval       Passes between stale publication record pruning (0 uses default 64).
 * @param out_combiner           Out-parameter receiving the newly created `lf_flat_combiner_t*`.
 * @return `LFQ_OK` on success, `LFQ_ERR_INVALID_ARG` if `out_combiner == NULL`.
 */
lf_status_t lf_flat_combiner_create(
    void* state,
    lf_flat_combiner_op_fn default_op_fn,
    lf_flat_combiner_state_destructor_fn state_destructor,
    void* user_data,
    size_t max_combining_rounds,
    size_t cleanup_interval,
    lf_flat_combiner_t** out_combiner
);
#define lfq_flat_combiner_create lf_flat_combiner_create

/**
 * @brief Destroys a Flat Combiner instance, invoking `state_destructor` (if non-NULL)
 *        and freeing all publication records.
 */
lf_status_t lf_flat_combiner_destroy(lf_flat_combiner_t* combiner);
#define lfq_flat_combiner_destroy lf_flat_combiner_destroy

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
lf_status_t lf_flat_combiner_combine(
    lf_flat_combiner_t* combiner,
    void* op_arg,
    void** out_result
);
#define lfq_flat_combiner_combine lf_flat_combiner_combine

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
lf_status_t lf_flat_combiner_combine_fn(
    lf_flat_combiner_t* combiner,
    lf_flat_combiner_op_fn op_fn,
    void* op_arg,
    void* op_user_data,
    void** out_result
);
#define lfq_flat_combiner_combine_fn lf_flat_combiner_combine_fn

/* ============================================================================
 * Telemetry & Introspection
 * ============================================================================ */

/**
 * @brief Returns the number of combining passes executed by `combiner`.
 */
uint64_t lf_flat_combiner_pass_count(const lf_flat_combiner_t* combiner);
#define lfq_flat_combiner_pass_count lf_flat_combiner_pass_count

/**
 * @brief Returns the total number of operations combined across all passes.
 */
uint64_t lf_flat_combiner_total_combined_ops(const lf_flat_combiner_t* combiner);
#define lfq_flat_combiner_total_combined_ops lf_flat_combiner_total_combined_ops

/**
 * @brief Returns the number of currently linked thread publication records.
 */
size_t lf_flat_combiner_active_records(const lf_flat_combiner_t* combiner);
#define lfq_flat_combiner_active_records lf_flat_combiner_active_records

#ifdef __cplusplus
}
#endif

#endif /* LOCKFREE_FLAT_COMBINER_H */
