## Pin-scope cardinality for Queue and BQueue producer/consumer constraints.

type PinScopeCardinality* = enum
  ccSingle ## Single-thread cardinality marker (SPSC, SPMC producer, MPSC consumer).
  ccMulti  ## Multi-thread cardinality marker (MPMC, MPSC producer, SPMC consumer).
