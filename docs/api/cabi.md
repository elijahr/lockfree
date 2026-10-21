# C ABI (`libcabi` & `lockfree.h`)

`lockfree/cabi` implements the canonical C99 / C++11 foreign function interface
(FFI) declared in `include/lockfree.h`.

## Overview

- **C Header**: `include/lockfree.h`
- **Supported Collections in C**: Bounded Queue, Unbounded Queue, Treiber Stack, Bounded Stack, Chase-Lev Deque, SkipList Map & Set, Ctrie, Bounded Hash Table, Bounded Priority Queue, Broadcast Ring, TaskPool, StreamBuffer, RateLimiter.
- **Modern Prefix (`lf_`)**: Primary symbols use `lf_` / `LF_`. Backward-compatibility aliases for `lfq_` / `LFQ_` are provided via preprocessor defines in C and dual-exported symbols in Nim.
- **Opaque Handles**: `lf_queue_t*`, `lf_producer_t*`, `lf_consumer_t*`, `lf_stack_t*`, `lf_bstack_t*`, `lf_deque_t*`, `lf_skiplist_t*`, `lf_set_t*`, `lf_ctrie_t*`, `lf_btable_t*`, `lf_bpqueue_t*`, `lf_broadcast_t*`, `lf_taskpool_t*`.
- **Status Codes**: `lf_status_t` (`LF_OK`, `LF_ERR_EMPTY`, `LF_ERR_FULL`, `LF_ERR_CLOSED`, `LF_ERR_INVALID_ARG`, `LF_ERR_REGISTRY_FULL`, `LF_ERR_UNSUPPORTED`, `LF_ERR_FAILURE`, `LF_ERR_PANIC`).
- **Exception Firewall**: `cAbiBoundary` prevents any Nim panic or exception from crossing into C.
- **Payload Transport**: Zero-copy 64-bit pointer payload transport (`void*`).

## C Example

```c
#include "lockfree.h"
#include <stdio.h>
#include <assert.h>

int main(void) {
    lf_queue_t* q = NULL;
    lf_status_t rc = lf_bounded_create(1024, sizeof(void*), &q);
    assert(rc == LF_OK);

    int val = 42;
    rc = lf_bounded_push(q, &val);
    assert(rc == LF_OK);

    void* out = NULL;
    rc = lf_bounded_pop(q, &out);
    assert(rc == LF_OK && *(int*)out == 42);

    lf_bounded_destroy(q);
    return 0;
}
```

::: lockfree/cabi
