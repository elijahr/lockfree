# StreamBuffer (Byte Streaming Ring Buffer)

`lockfree/streambuffer` implements a high-performance, lock-free byte streaming
ring buffer for contiguous binary streams, network packets, and audio/video
pipelines.

## Overview

- **Core Type**: `StreamBuffer`
- **Operations**:
  - `write(data, len)`: Write byte sequences atomically or in contiguous chunks.
  - `read(buffer, len)`: Read byte sequences out of the buffer.
  - `peek(buffer, len)`: Inspect bytes without advancing consumer read pointer.
- **Progress Guarantee**: Wait-free SPSC; lock-free MPMC.

## Example

```nim
import lockfree

var stream = newStreamBuffer(capacity = 4096)

let data = "Hello, lockfree streaming!"
let written = stream.write(data[0].unsafeAddr, data.len)

var buf = newString(data.len)
let readBytes = stream.read(buf[0].addr, buf.len)
assert buf == data
```

::: lockfree/streambuffer
