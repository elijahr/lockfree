## Common exception types for lockfree.

type InvalidCallDefect* = object of Defect
  ## Raised when a queue method is called incorrectly. For example, calling
  ## `queue.push()` directly on an MPSC queue instead of using
  ## `Producer.push()`.

type NoProducersAvailableError* = object of CatchableError
  ## Raised by `getProducer()` if all producers have been assigned to other
  ## threads.

type NoConsumersAvailableError* = object of CatchableError
  ## Raised by `getConsumer()` if all consumers have been assigned to other
  ## threads.

type ChannelClosedDefect* = object of Defect
  ## Raised when attempting an operation on a closed channel.

type RendezvousDefect* = object of Defect
  ## Raised when a rendezvous operation is unexpectedly interrupted.
