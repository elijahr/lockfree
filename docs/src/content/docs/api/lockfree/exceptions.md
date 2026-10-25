---
title: "lockfree/exceptions"
description: "API reference for lockfree/exceptions"
---

Common exception types for lockfree.


## Types

### `InvalidCallDefect`

```nim
InvalidCallDefect = object of Defect
```

Raised when a queue method is called incorrectly. For example, calling <tt class="docutils literal"><span class="pre"><span class="Identifier">queue</span><span class="Operator">.</span><span class="Identifier">push</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt> directly on an MPSC queue instead of using <tt class="docutils literal"><span class="pre"><span class="Identifier">Producer</span><span class="Operator">.</span><span class="Identifier">push</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt>.

### `NoProducersAvailableError`

```nim
NoProducersAvailableError = object of CatchableError
```

Raised by <tt class="docutils literal"><span class="pre"><span class="Identifier">getProducer</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt> if all producers have been assigned to other threads.

### `NoConsumersAvailableError`

```nim
NoConsumersAvailableError = object of CatchableError
```

Raised by <tt class="docutils literal"><span class="pre"><span class="Identifier">getConsumer</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt> if all consumers have been assigned to other threads.

### `ChannelClosedDefect`

```nim
ChannelClosedDefect = object of Defect
```

Raised when attempting an operation on a closed channel.

### `RendezvousDefect`

```nim
RendezvousDefect = object of Defect
```

Raised when a rendezvous operation is unexpectedly interrupted.

