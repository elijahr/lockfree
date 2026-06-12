## SlotEncoding[T] — compile-time mapping from user-facing T to encoded slot type.
##
## Unified encoding:
##   ref X    -> ManagedRef[X]    (8B distinct uint; refcount lifecycle)
##   string   -> ManagedSlice[char] (8B distinct uint; box pointer)
##   seq[U]   -> ManagedSlice[U]    (8B distinct uint; box pointer)
##   POD T    -> T (identity; assumed sizeof(T) <= sizeof(uint))
##
## Cells in Segment + MPMCCellArrayN are typed `LCRQCell[SlotEncoding(T)]` /
## `MPMCCell[SlotEncoding(T)]`.
##
## Internal-only. NEVER user-facing. The user writes `Queue[ref Foo, ...]`,
## `Queue[string, ...]`, or `Queue[seq[int], ...]`; this template performs
## the wire-format substitution invisibly inside the queue cores.

import ../managed_ref
import ../managed_slice

template SlotEncoding*(T: typedesc): typedesc =
  ## Map a user-facing payload type ``T`` to its slot-encoded wire type.
  ##
  ## Type-extraction grammar (verified under Nim 2.2.10):
  ##   * `typeof(default(T)[])`   — pointee of `ref X`
  ##   * `typeof(default(T)[0])`  — element of `seq[U]`.
  when T is ref:
    ManagedRef[typeof(default(T)[])]
  elif T is string:
    ManagedSlice[char]
  elif T is seq:
    ManagedSlice[typeof(default(T)[0])]
  else:
    T
