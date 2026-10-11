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

## 4. Compilation & Linking

Compile the C code linking against the shared library `liblockfree.so` / `liblockfree.dylib` (or static archive):

```bash
gcc -O3 -Iinclude -L. -llockfree -o example example.c
```

See the [C ABI API Reference](../api/cabi.md) for full function declarations across all collections.
