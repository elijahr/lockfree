# Rate Limiting & Byte Streaming

`lockfree` includes specialized high-performance utilities for traffic shaping
and binary data streaming.

---

## 1. Rate Limiting (`lockfree/ratelimit`)

Both `TokenBucket` and `LeakyBucket` operate entirely without locks or background
timer threads, using 128-bit DWCAS to synchronize token replenishment and time
stamps in a single atomic instruction.

### Token Bucket (`TokenBucket`)

The classic token bucket algorithm permits burst traffic up to a maximum
capacity, replenishing tokens smoothly over time based on nanosecond clock
deltas:

```nim
import lockfree

# 5,000 requests/sec with burst capacity of 100 tokens
var limiter = newTokenBucket(ratePerSec = 5000, burstCapacity = 100)

if limiter.tryAcquire(tokens = 1):
  # Allowed
  discard
```

### Leaky Bucket (`LeakyBucket`)

Implements the Generic Cell Rate Algorithm (GCRA). It acts as a traffic
smoother, enforcing a continuous, uniform spacing between successive events:

```nim
import lockfree

# 1,000 events/sec smoothed with 10ms tolerance
var smoother = newLeakyBucket(ratePerSec = 1000, maxBurstTimeMs = 10)

if smoother.tryAcquire():
  # Cadence adhered to
  discard
```

---

## 2. Lock-Free StreamBuffer (`lockfree/streambuffer`)

`StreamBuffer` provides a continuous circular byte stream optimized for
streaming I/O, audio buffers, and network packet framing.

### Features

- **Byte-Oriented**: Reads and writes raw bytes directly from pointers or string buffers.
- **Contiguous Reads/Writes**: Calculates available contiguous linear buffer segments to avoid intermediate copies where possible.
- **Inspection**: Supports `peek()` to inspect incoming bytes without advancing the read position.

### Example

```nim
import lockfree

var stream = newStreamBuffer(capacity = 8192)

let payload = "STREAM_DATA_CHUNK"
discard stream.write(payload[0].unsafeAddr, payload.len)

var dest = newString(payload.len)
discard stream.read(dest[0].addr, dest.len)
assert dest == payload
```

See the [RateLimiter API](../api/ratelimit.md) and [StreamBuffer API](../api/streambuffer.md).
