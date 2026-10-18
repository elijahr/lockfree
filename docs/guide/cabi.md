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
#include <assert.h>

int main(void) {
    // 1. Create a bounded MPMC queue with capacity 1024
    lfq_queue_t* q = NULL;
    lfq_status_t rc = lfq_bounded_create(1024, sizeof(void*), &q);
    assert(rc == LFQ_OK);

    // 2. Push an item pointer
    int payload = 1337;
    rc = lfq_bounded_push(q, &payload);
    assert(rc == LFQ_OK);

    // 3. Pop an item pointer
    void* popped = NULL;
    rc = lfq_bounded_pop(q, &popped);
    assert(rc == LFQ_OK);
    assert(*(int*)popped == 1337);

    // 4. Destroy the queue
    lfq_bounded_destroy(q);
    printf("C ABI queue test completed successfully.\n");
    return 0;
}
```

---

## 4. Bounded Zero-SMR Primitives (v0.5.0+)

For systems where dynamic node allocation or epoch-based safe memory reclamation (SMR) is undesirable, `lockfree` provides bounded zero-SMR primitives:

### A. Bounded Stack (`BStack`)

LIFO stack with bounded capacity and wait-free fast paths:

```c
lfq_bstack_t* stack = NULL;
assert(lfq_bstack_create(128, &stack) == LFQ_OK);

uintptr_t val = 42;
assert(lfq_bstack_push(stack, (void*)val) == LFQ_OK);

void* popped = NULL;
assert(lfq_bstack_pop(stack, &popped) == LFQ_OK);
assert((uintptr_t)popped == 42);

lfq_bstack_destroy(stack);
```

### B. Bounded Priority Queue (`BPriorityQueue`)

Bounded min/max priority queue with flat-combined linearization:

```c
lfq_bpqueue_t* pq = NULL;
assert(lfq_bpqueue_create(128, &pq) == LFQ_OK);

// Push priority items (priority int64, payload void*)
assert(lfq_bpqueue_push(pq, 10, (void*)100) == LFQ_OK);
assert(lfq_bpqueue_push(pq, 5, (void*)200) == LFQ_OK);

// Pop extracts lowest priority number first
int64_t prio = 0;
void* item = NULL;
assert(lfq_bpqueue_pop(pq, &prio, &item) == LFQ_OK);
assert(prio == 5 && (uintptr_t)item == 200);

lfq_bpqueue_destroy(pq);
```

### C. Bounded Table (`BTable`)

Bounded Robin Hood open-addressed concurrent hash table:

```c
lfq_btable_t* table = NULL;
assert(lfq_btable_create(256, &table) == LFQ_OK);

// Put key-value pair
assert(lfq_btable_put(table, 1234, (void*)5678) == LFQ_OK);

// Get value
void* out = NULL;
assert(lfq_btable_get(table, 1234, &out) == LFQ_OK);
assert((uintptr_t)out == 5678);

// Delete key
assert(lfq_btable_del(table, 1234) == LFQ_OK);

lfq_btable_destroy(table);
```

---

## 5. Compilation & Linking

Compile the C code linking against the shared library `liblockfree.so` / `liblockfree.dylib` (or static archive):

```bash
gcc -O3 -Iinclude -L. -llockfree -o example example.c
```

See the [C ABI API Reference](../api/cabi.md) and [`include/lockfree.h`](../../include/lockfree.h) for full function declarations across all collections.

