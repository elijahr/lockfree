# C ABI Interoperability (`lockfree.h`)

`lockfree` provides a canonical C99 / C++11 Foreign Function Interface (FFI)
declared in `include/lockfree.h`. This allows any C, C++, Rust, Zig, or Go
codebase to link directly against `liblockfree` and utilize its lock-free
primitives.

---

## 1. Core Principles

- **Opaque Handles**: C callers interact strictly through pointers to opaque structures (`lfq_queue_t*`, `lfq_stack_t*`, `lfq_deque_t*`, `lfq_skiplist_t*`, etc.).
- **Zero-Copy Pointer Transport**: Payloads are transferred as 64-bit raw pointers (`void*`), with no internal allocation or marshalling.
- **Exception Firewall (`cAbiBoundary`)**: Any Nim exception, panic, or defect is intercepted at the FFI boundary and converted into an error code (`LFQ_ERR_PANIC` or `LFQ_ERR_FAILURE`). Uncaught panics never escape to abort the host C process.
- **Thread Registration**: Threads interacting with Debra SMR register once via `lfq_thread_register()` and unregister upon exit with `lfq_thread_unregister()`.

---

## 2. Status Codes (`lfq_status_t`)

| Status Code | Value | Description |
| :--- | :--- | :--- |
| `LFQ_OK` | `0` | Operation succeeded |
| `LFQ_ERR_EMPTY` | `1` | Collection or queue is empty |
| `LFQ_ERR_FULL` | `2` | Bounded capacity reached |
| `LFQ_ERR_CLOSED` | `3` | Handle has been closed or terminated |
| `LFQ_ERR_INVALID_ARG` | `4` | Null pointer or invalid configuration |
| `LFQ_ERR_REGISTRY_FULL` | `5` | Maximum concurrent thread slots exhausted |
| `LFQ_ERR_FAILURE` | `-1` | General operational error |
| `LFQ_ERR_PANIC` | `-2` | Caught panic intercepted by exception firewall |

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
    lfq_queue_t* q = NULL;
    lfq_status_t rc = lfq_bounded_mpmc_create(1024, 4, 4, NULL, NULL, &q);
    assert(rc == LFQ_OK);

    // 2. Acquire producer and consumer endpoint handles
    lfq_producer_t* prod = NULL;
    lfq_consumer_t* cons = NULL;
    assert(lfq_producer_acquire(q, &prod) == LFQ_OK);
    assert(lfq_consumer_acquire(q, &cons) == LFQ_OK);

    // 3. Push an item pointer
    assert(lfq_push(prod, (void*)(uintptr_t)1337) == LFQ_OK);

    // 4. Pop an item pointer
    void* popped = NULL;
    assert(lfq_pop(cons, &popped) == LFQ_OK);
    assert((uintptr_t)popped == 1337);

    // 5. Release handles and destroy the queue
    lfq_producer_release(prod);
    lfq_consumer_release(cons);
    lfq_queue_destroy(q);
    printf("C ABI queue test completed successfully.\n");
    return 0;
}
```

---

## 4. Bounded Zero-SMR Primitives (v0.5.0+)

For systems where dynamic node allocation or epoch-based safe memory reclamation (SMR) is undesirable, `lockfree` provides bounded zero-SMR primitives:

### A. Bounded Stack (`BStack`)

LIFO stack with bounded capacity, 64-bit ABA-tagged index CAS, and wait-free fast paths:

```c
lfq_bstack_t* stack = NULL;
// lfq_bstack_create(capacity, destructor, user_data, &out_stack)
assert(lfq_bstack_create(128, NULL, NULL, &stack) == LFQ_OK);

uintptr_t val = 42;
assert(lfq_bstack_push(stack, (void*)val) == LFQ_OK);

void* popped = NULL;
assert(lfq_bstack_pop(stack, &popped) == LFQ_OK);
assert((uintptr_t)popped == 42);

lfq_bstack_destroy(stack);
```

*Exported Operations*: `lfq_bstack_create`, `lfq_bstack_destroy`, `lfq_bstack_push`, `lfq_bstack_pop`, `lfq_bstack_peek`, `lfq_bstack_clear`, `lfq_bstack_len`, `lfq_bstack_capacity`, `lfq_bstack_is_empty`, `lfq_bstack_is_full`.

### B. Bounded Priority Queue (`BPriorityQueue`)

Bounded min-priority queue with flat-combined linearization:

```c
lfq_bpqueue_t* pq = NULL;
// lfq_bpqueue_create(capacity, destructor, user_data, &out_bpqueue)
assert(lfq_bpqueue_create(128, NULL, NULL, &pq) == LFQ_OK);

// Push priority items (priority int64, payload void*)
assert(lfq_bpqueue_push(pq, 10, (void*)100) == LFQ_OK);
assert(lfq_bpqueue_push(pq, 5, (void*)200) == LFQ_OK);

// Pop extracts lowest numerical priority first via lfq_bpqueue_pop_min
int64_t prio = 0;
void* item = NULL;
assert(lfq_bpqueue_pop_min(pq, &prio, &item) == LFQ_OK);
assert(prio == 5 && (uintptr_t)item == 200);

lfq_bpqueue_destroy(pq);
```

*Exported Operations*: `lfq_bpqueue_create`, `lfq_bpqueue_destroy`, `lfq_bpqueue_push`, `lfq_bpqueue_pop_min`, `lfq_bpqueue_peek_min`, `lfq_bpqueue_clear`, `lfq_bpqueue_len`, `lfq_bpqueue_capacity`, `lfq_bpqueue_is_empty`, `lfq_bpqueue_is_full`.

### C. Bounded Table (`BTable`)

Bounded linear-probing open-addressed concurrent hash table with per-slot seqlocks and flat-combining mutation batching:

```c
lfq_btable_t* table = NULL;
// lfq_btable_create(capacity, destructor, user_data, &out_table)
assert(lfq_btable_create(256, NULL, NULL, &table) == LFQ_OK);

// Put key-value pair (table, key, val, &out_inserted)
assert(lfq_btable_put(table, (void*)1234, (void*)5678, NULL) == LFQ_OK);

// Get value (table, key, &out_val)
void* out = NULL;
assert(lfq_btable_get(table, (void*)1234, &out) == LFQ_OK);
assert((uintptr_t)out == 5678);

// Delete key (table, key, &out_deleted)
assert(lfq_btable_delete(table, (void*)1234, NULL) == LFQ_OK);

lfq_btable_destroy(table);
```

*Exported Operations*: `lfq_btable_create`, `lfq_btable_destroy`, `lfq_btable_put`, `lfq_btable_insert`, `lfq_btable_get`, `lfq_btable_delete`, `lfq_btable_remove`, `lfq_btable_contains`, `lfq_btable_clear`, `lfq_btable_len`, `lfq_btable_capacity`, `lfq_btable_is_empty`, `lfq_btable_is_full`.

---

## 5. Compilation & Linking

Compile the C code linking against the shared library `liblockfree.so` / `liblockfree.dylib` (or static archive):

```bash
gcc -O3 -Iinclude -L. -llockfree -o example example.c
```

See the [C ABI API Reference](../api/cabi.md) and [`include/lockfree.h`](https://github.com/elijahr/lockfree/blob/main/include/lockfree.h) for full function declarations across all collections.

