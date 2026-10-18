##
## Role-discriminating effect tags shared across queue flavours.
##
## - `AnyThreadTag`: same-thread shortcut path (`getProducerHere` /
##   `getConsumerHere`). Bypasses per-spawn freshness; runtime `getThreadId()`
##   backstop catches misuse under `-d:debug`.
## - `SpscProducerTag` / `SpscConsumerTag`: SPSC has cardinality 1 per role, so
##   per-spawn freshness collapses; role discrimination still applies.
## - `MpmcProducerTag` / `MpmcConsumerTag`: Option A — MPMC gets role
##   discipline only (no per-spawn tag). Per-thread identity stays runtime-
##   checked (see migration guide).

type
  AnyThreadTag* = object of RootEffect

  SpscProducerTag* = object of RootEffect
  SpscConsumerTag* = object of RootEffect

  MpmcProducerTag* = object of RootEffect
  MpmcConsumerTag* = object of RootEffect

  DequeOwnerTag* = object of RootEffect
    ## Single owner-worker role tag for `ChaseLevDeque[T]` (`pushBottom` / `popBottom`).
  DequeThiefTag* = object of RootEffect
    ## Concurrent thief role tag for `ChaseLevDeque[T]` (`steal` / `stealBatch`).

  TableWriterTag* = object of RootEffect
    ## Read-write mutator role tag for `BTable[K, V, Cap, ccProd, ccCons]`.
  TableReaderTag* = object of RootEffect
    ## Read-only observer role tag for `BTable[K, V, Cap, ccProd, ccCons]`.

