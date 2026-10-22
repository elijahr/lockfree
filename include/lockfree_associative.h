#ifndef LOCKFREE_ASSOCIATIVE_H
#define LOCKFREE_ASSOCIATIVE_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Forward declarations */
#ifndef LFQ_CTRIE_DEFINED
#define LFQ_CTRIE_DEFINED
typedef struct lf_ctrie lf_ctrie_t;
#define lfq_ctrie lf_ctrie
#define lfq_ctrie_t lf_ctrie_t
#endif

#ifndef LFQ_TABLE_DEFINED
#define LFQ_TABLE_DEFINED
typedef struct lf_table lf_table_t;
#define lfq_table lf_table
#define lfq_table_t lf_table_t
#endif

#ifndef LFQ_SKIPLIST_DEFINED
#define LFQ_SKIPLIST_DEFINED
typedef struct lf_table lf_skiplist_t;
#define lfq_table lf_table
#define lfq_skiplist_t lf_skiplist_t
#endif

/* C-compatible callback signatures */
typedef void* (*lf_mapping_fn)(const void* key, size_t key_len, void* user_data);
#define lfq_mapping_fn lf_mapping_fn
typedef void* (*lf_update_fn)(const void* old_val, size_t old_val_len, void* user_data);
#define lfq_update_fn lf_update_fn

/* Ctrie Atomic Operations */
bool lf_ctrie_compute_if_absent(
    lf_ctrie_t* trie,
    const void* key, size_t key_len,
    lf_mapping_fn mapping_fn, void* user_data,
    void** out_val, size_t* out_val_len
);
#define lfq_ctrie_compute_if_absent lf_ctrie_compute_if_absent

bool lf_ctrie_atomic_update(
    lf_ctrie_t* trie,
    const void* key, size_t key_len,
    lf_update_fn update_fn, void* user_data,
    void** out_val, size_t* out_val_len
);
#define lfq_ctrie_atomic_update lf_ctrie_atomic_update

/* SkipListMap Atomic Operations */
bool lf_skiplist_compute_if_absent(
    lf_skiplist_t* map,
    const void* key, size_t key_len,
    lf_mapping_fn mapping_fn, void* user_data,
    void** out_val, size_t* out_val_len
);
#define lfq_skiplist_compute_if_absent lf_skiplist_compute_if_absent

bool lf_skiplist_atomic_update(
    lf_skiplist_t* map,
    const void* key, size_t key_len,
    lf_update_fn update_fn, void* user_data,
    void** out_val, size_t* out_val_len
);
#define lfq_skiplist_atomic_update lf_skiplist_atomic_update

/* Table Aliases for SkipListMap */
bool lf_table_compute_if_absent(
    lf_table_t* map,
    const void* key, size_t key_len,
    lf_mapping_fn mapping_fn, void* user_data,
    void** out_val, size_t* out_val_len
);
#define lfq_table_compute_if_absent lf_table_compute_if_absent

bool lf_table_atomic_update(
    lf_table_t* map,
    const void* key, size_t key_len,
    lf_update_fn update_fn, void* user_data,
    void** out_val, size_t* out_val_len
);
#define lfq_table_atomic_update lf_table_atomic_update

#ifdef __cplusplus
}
#endif

#endif /* LOCKFREE_ASSOCIATIVE_H */
