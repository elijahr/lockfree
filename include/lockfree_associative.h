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
typedef struct lfq_ctrie lfq_ctrie_t;
#endif

#ifndef LFQ_TABLE_DEFINED
#define LFQ_TABLE_DEFINED
typedef struct lfq_table lfq_table_t;
#endif

#ifndef LFQ_SKIPLIST_DEFINED
#define LFQ_SKIPLIST_DEFINED
typedef struct lfq_table lfq_skiplist_t;
#endif

/* C-compatible callback signatures */
typedef void* (*lfq_mapping_fn)(const void* key, size_t key_len, void* user_data);
typedef void* (*lfq_update_fn)(const void* old_val, size_t old_val_len, void* user_data);

/* Ctrie Atomic Operations */
bool lfq_ctrie_compute_if_absent(
    lfq_ctrie_t* trie,
    const void* key, size_t key_len,
    lfq_mapping_fn mapping_fn, void* user_data,
    void** out_val, size_t* out_val_len
);

bool lfq_ctrie_atomic_update(
    lfq_ctrie_t* trie,
    const void* key, size_t key_len,
    lfq_update_fn update_fn, void* user_data,
    void** out_val, size_t* out_val_len
);

/* SkipListMap Atomic Operations */
bool lfq_skiplist_compute_if_absent(
    lfq_skiplist_t* map,
    const void* key, size_t key_len,
    lfq_mapping_fn mapping_fn, void* user_data,
    void** out_val, size_t* out_val_len
);

bool lfq_skiplist_atomic_update(
    lfq_skiplist_t* map,
    const void* key, size_t key_len,
    lfq_update_fn update_fn, void* user_data,
    void** out_val, size_t* out_val_len
);

/* Table Aliases for SkipListMap */
bool lfq_table_compute_if_absent(
    lfq_table_t* map,
    const void* key, size_t key_len,
    lfq_mapping_fn mapping_fn, void* user_data,
    void** out_val, size_t* out_val_len
);

bool lfq_table_atomic_update(
    lfq_table_t* map,
    const void* key, size_t key_len,
    lfq_update_fn update_fn, void* user_data,
    void** out_val, size_t* out_val_len
);

#ifdef __cplusplus
}
#endif

#endif /* LOCKFREE_ASSOCIATIVE_H */
