## Pin-scope cardinality phantom — local placeholder.
##
## The canonical home of `PinScopeCardinality` is nebr. This file declares a
## LOCAL placeholder enum with the same member identifiers (ccSingle, ccMulti)
## the upstream surface exposes, so the Queue shell can compile without taking a
## hard dependency on the upstream module resolution order.
##
## DO NOT add fields or methods to this enum. It exists only to give the Queue
## shell a parseable type for its `ccProd: static PinScopeCardinality` and
## `ccCons: static PinScopeCardinality` generic params.

import ../cardinality
export cardinality
