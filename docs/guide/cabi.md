# C ABI Interoperability (`lockfree.h`)

`lockfree` provides a canonical C99 / C++11 Foreign Function Interface (FFI)
declared in `include/lockfree.h`. This allows any C, C++, Rust, Zig, or Go
codebase to link directly against `liblockfree` and utilize its lock-free
primitives.

---

## 1. Core Principles

- **Standard Prefix (`lf_`)**: Starting in v0.6.0, all types, functions, and status codes standardize on the clean `lf_` / `LF_` prefix, reflecting the toolkit's complete data structure scope. Legacy `lfq_` / `LFQ_` symbols remain 100% backward compatible via header `#define` aliases and dual-exported shared library symbols.
- **Opaque Handles**: C callers interact strictly through pointers to opaque structures (`lf_queue_t*`, `lf_stack_t*`, `lf_deque_t*`, `lf_skiplist_t*`, etc.).
- **Zero-Copy Pointer Transport**: Payloads are transferred as 64-bit raw pointers (`void*`), with no internal allocation or marshalling.
- **Exception Firewall (`cAbiBoundary`)**: Any Nim exception, panic, or defect is intercepted at the FFI boundary and converted into an error code (`LF_ERR_PANIC` or `LF_ERR_FAILURE`). Uncaught panics never escape to abort the host C process.
- **Thread Registration**: Threads interacting with Debra SMR register once via `lf_thread_register()` and unregister upon exit with `lf_thread_unregister()`.

---

## 2. Status Codes (`lf_status_t`)

| Status Code | Legacy Alias | Value | Description |
| :--- | :--- | :--- | :--- |
| `LF_OK` | `LFQ_OK` | `0` | Operation succeeded |
| `LF_ERR_EMPTY` | `LFQ_ERR_EMPTY` | `1` | Collection or queue is empty |
| `LF_ERR_FULL` | `LFQ_ERR_FULL` | `2` | Bounded capacity reached |
| `LF_ERR_CLOSED` | `LFQ_ERR_CLOSED` | `3` | Handle has been closed or terminated |
| `LF_ERR_INVALID_ARG` | `LFQ_ERR_INVALID_ARG` | `4` | Null pointer or invalid configuration |
| `LF_ERR_REGISTRY_FULL` | `LFQ_ERR_REGISTRY_FULL` | `5` | Maximum concurrent thread slots exhausted |
| `LF_ERR_UNSUPPORTED` | `LFQ_ERR_UNSUPPORTED` | `6` | Operation unsupported for handle type |
| `LF_ERR_FAILURE` | `LFQ_ERR_FAILURE` | `-1` | General operational error |
| `LF_ERR_PANIC` | `LFQ_ERR_PANIC` | `-2` | Caught panic intercepted by exception firewall |

---

## 3. C Example

```c
#include "lockfree.h"
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <assert.h>

int main(void) {
    // 1. Create a bounded MPMC queue with capacity 1024, 4 max producers, 4 max consumers
    lf_queue_t* q = NULL;
    lf_status_t rc = lf_bounded_mpmc_create(1024, 4, 4, NULL, NULL, &q);
    assert(rc == LF_OK);

    // 2. Acquire producer and consumer endpoint handles
    lf_producer_t* prod = NULL;
    lf_consumer_t* cons = NULL;
    assert(lf_producer_acquire(q, &prod) == LF_OK);
    assert(lf_consumer_acquire(q, &cons) == LF_OK);

    // 3. Push an item pointer
    assert(lf_push(prod, (void*)(uintptr_t)1337) == LF_OK);

    // 4. Pop an item pointer
    void* popped = NULL;
    assert(lf_pop(cons, &popped) == LF_OK);
    assert((uintptr_t)popped == 1337);

    // 5. Release handles and destroy the queue
    lf_producer_release(prod);
    lf_consumer_release(cons);
    lf_queue_destroy(q);
    printf("C ABI queue test completed successfully.\n");
    return 0;
}
```

---

## 4. Bounded Zero-SMR Primitives

For systems where dynamic node allocation or epoch-based safe memory reclamation (SMR) is undesirable, `lockfree` provides bounded zero-SMR primitives:

### A. Bounded Stack (`BStack`)

LIFO stack with bounded capacity, 64-bit ABA-tagged index CAS, and wait-free fast paths:

```c
lf_bstack_t* stack = NULL;
// lf_bstack_create(capacity, destructor, user_data, &out_stack)
assert(lf_bstack_create(128, NULL, NULL, &stack) == LF_OK);

uintptr_t val = 42;
assert(lf_bstack_push(stack, (void*)val) == LF_OK);

void* popped = NULL;
assert(lf_bstack_pop(stack, &popped) == LF_OK);
assert((uintptr_t)popped == 42);

lf_bstack_destroy(stack);
```

*Exported Operations*: `lf_bstack_create`, `lf_bstack_destroy`, `lf_bstack_push`, `lf_bstack_pop`, `lf_bstack_peek`, `lf_bstack_clear`, `lf_bstack_len`, `lf_bstack_capacity`, `lf_bstack_is_empty`, `lf_bstack_is_full`.

### B. Bounded Priority Queue (`BPriorityQueue`)

Bounded min-priority queue with flat-combined linearization:

```c
lf_bpqueue_t* pq = NULL;
// lf_bpqueue_create(capacity, destructor, user_data, &out_bpqueue)
assert(lf_bpqueue_create(128, NULL, NULL, &pq) == LF_OK);

// Push priority items (priority int64, payload void*)
assert(lf_bpqueue_push(pq, 10, (void*)100) == LF_OK);
assert(lf_bpqueue_push(pq, 5, (void*)200) == LF_OK);

// Pop extracts lowest numerical priority first via lf_bpqueue_pop_min
int64_t prio = 0;
void* item = NULL;
assert(lf_bpqueue_pop_min(pq, &prio, &item) == LF_OK);
assert(prio == 5 && (uintptr_t)item == 200);

lf_bpqueue_destroy(pq);
```

*Exported Operations*: `lf_bpqueue_create`, `lf_bpqueue_destroy`, `lf_bpqueue_push`, `lf_bpqueue_pop_min`, `lf_bpqueue_peek_min`, `lf_bpqueue_clear`, `lf_bpqueue_len`, `lf_bpqueue_capacity`, `lf_bpqueue_is_empty`, `lf_bpqueue_is_full`.

### C. Bounded Table (`BTable`)

Bounded linear-probing open-addressed concurrent hash table with per-slot seqlocks and flat-combining mutation batching:

```c
lf_btable_t* table = NULL;
// lf_btable_create(capacity, destructor, user_data, &out_table)
assert(lf_btable_create(256, NULL, NULL, &table) == LF_OK);

// Put key-value pair (table, key, val, &out_inserted)
assert(lf_btable_put(table, (void*)1234, (void*)5678, NULL) == LF_OK);

// Get value (table, key, &out_val)
void* out = NULL;
assert(lf_btable_get(table, (void*)1234, &out) == LF_OK);
assert((uintptr_t)out == 5678);

// Delete key (table, key, &out_deleted)
assert(lf_btable_delete(table, (void*)1234, NULL) == LF_OK);

lf_btable_destroy(table);
```

*Exported Operations*: `lf_btable_create`, `lf_btable_destroy`, `lf_btable_put`, `lf_btable_insert`, `lf_btable_get`, `lf_btable_delete`, `lf_btable_remove`, `lf_btable_contains`, `lf_btable_clear`, `lf_btable_len`, `lf_btable_capacity`, `lf_btable_is_empty`, `lf_btable_is_full`.

---

## 5. Backward Compatibility Guarantee

All legacy symbols (`lfq_*` and `LFQ_*`) remain fully supported without deprecation or recompilation requirements:
- **C Header**: `include/lockfree.h` maps all `lfq_*` identifiers to `lf_*` using preprocessor macros (e.g. `#define lfq_queue_t lf_queue_t`, `#define lfq_push lf_push`).
- **Shared Object ABI**: `liblockfree` exports both `lf_*` and `lfq_*` entry points, allowing legacy binaries compiled against v0.5.x to load dynamically without symbol resolution errors.

---

## 6. Compilation & Linking

Compile C code linking against the shared library `liblockfree.so` / `liblockfree.dylib` (or static archive):

```bash
gcc -O3 -Iinclude -L. -llockfree -o example example.c
```

See the [C ABI API Reference](../api/cabi.md) and [`include/lockfree.h`](https://github.com/elijahr/lockfree/blob/main/include/lockfree.h) for full function declarations across all collections.
