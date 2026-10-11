# RendezvousChannel

`lockfree/rendezvous` provides a synchronous, zero-capacity dual-queue channel
based on Scherer & Scott's synchronous queue algorithm, utilizing OS futex
primitives for efficient thread parking and waking.

## Overview

- **Capacity**: Zero (synchronous handoff). Senders block until a receiver arrives, and vice-versa.
- **Handoff Mechanism**: Direct bilateral thread-to-thread handoff.
- **Progress Guarantee**: Lock-free matching, OS futex waiting (`ulock_wait` on macOS, `WaitOnAddress` on Windows, futex on Linux).
- **Correlation**: Monotonic 64-bit correlation IDs.

## Example

```nim
import lockfree

var chan = newRendezvousChannel[int]()

# In thread A:
# chan.send(100) # blocks until thread B receives

# In thread B:
# let val = chan.recv() # pairs with thread A
```

::: lockfree/rendezvous
