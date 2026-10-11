# BroadcastRing & TopicBus (Multicast Ring)

`lockfree/broadcast` provides lock-free multicast ring buffers and pub-sub topic
routing where a single publisher (or multiple publishers) broadcast messages to
independent readers holding isolated cursors.

## Overview

- **Core Types**: `BroadcastRing[T]`, `BroadcastCursor[T]`, `TopicBus[T]`
- **Multicast Fan-Out**: Every active cursor receives all published items according to its overflow policy.
- **Overflow Policies**:
  - `omDropOldest`: Lossy ring wrap-around with hazard pointer protection against Use-After-Free (UAF). Slow readers skip dropped messages.
  - `omBackpressure`: Lossless ring; publishers are rejected or spin when capacity is saturated.
- **Topic Multiplexing**: `TopicBus[T]` routes topics to distinct `BroadcastRing` instances dynamically.

## Example

```nim
import lockfree

var ring = newBroadcastRing[int, 1024](policy = omDropOldest)
var cursor = ring.createCursor()

discard ring.publish(100)
discard ring.publish(200)

var val: int
let res = cursor.tryRead(val)
assert res == crSuccess and val == 100
```

::: lockfree/broadcast
