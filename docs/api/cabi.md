# C ABI (`libcabi` & `lockfree.h`)

`lockfree/cabi` implements the canonical C99 / C++11 foreign function interface
(FFI) declared in `include/lockfree.h`.

## Overview

- **C Header**: `include/lockfree.h`
- **Supported Collections in C**: Bounded Queue, Unbounded Queue, Treiber Stack, Chase-Lev Deque, SkipList Map & Set, Ctrie, Broadcast Ring, TaskPool, StreamBuffer, RateLimiter.
- **Opaque Handles**: `lfq_queue_t*`, `lfq_producer_t*`, `lfq_consumer_t*`, `lfq_stack_t*`, `lfq_deque_t*`, `lfq_skiplist_t*`, `lfq_set_t*`, `lfq_ctrie_t*`, `lfq_broadcast_t*`, `lfq_taskpool_t*`.
- **Status Codes**: `lfq_status_t` (`LFQ_OK`, `LFQ_ERR_EMPTY`, `LFQ_ERR_FULL`, `LFQ_ERR_CLOSED`, `LFQ_ERR_INVALID_ARG`, `LFQ_ERR_PANIC`).
- **Exception Firewall**: `cAbiBoundary` prevents any Nim panic or exception from crossing into C.
- **Payload Transport**: Zero-copy 64-bit pointer payload transport (`void*`).

## C Example

```c
#include "lockfree.h"
#include <stdio.h>
#include <assert.h>

int main(void) {
    lfq_queue_t* q = NULL;
    lfq_status_t rc = lfq_bounded_create(1024, sizeof(void*), &q);
    assert(rc == LFQ_OK);

    int val = 42;
    rc = lfq_bounded_push(q, &val);
    assert(rc == LFQ_OK);

    void* out = NULL;
    rc = lfq_bounded_pop(q, &out);
    assert(rc == LFQ_OK && *(int*)out == 42);

    lfq_bounded_destroy(q);
    return 0;
}
```

::: lockfree/cabi
