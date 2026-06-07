## nim-debra lifted test suite (NEBR)
##
## Lifted from imports/nim-debra/tests/test.nim under T-INTEGRATE.e
## (umbrella v0.1.0 impl plan, PG-2). Test files renamed to
## `t_nebr_*` to avoid collision with lockfree' own `t_*`
## suite. Imports rewritten: `debra/...` -> `lockfree/...`
## per T-INTEGRATE.c sweep.
##
## NOTE: `t_nebr_item_processing` and `t_nebr_lockfree_stack_typestates`
## are EXCLUDED here because they import `../examples/item_processing`
## and `../examples/lockfree_stack_typestates` from upstream
## nim-debra/examples/. Those example sources have not been lifted
## (PG-4 deletes imports/nim-debra wholesale). PG-10 CI cells must
## either (a) lift the two example files into tests/smr/debra-legacy/_examples/
## and update those test imports, or (b) drop the two tests as
## non-applicable to the umbrella. Files remain on disk for review.

import ./t_nebr_types
import ./t_nebr_signal
import ./t_nebr_limbo
import ./t_nebr_signal_handler
import ./t_nebr_manager_typestate
import ./t_nebr_registration
import ./t_nebr_guard
import ./t_nebr_retire
import ./t_nebr_pinned_scope
import ./t_nebr_retire_on_cas
import ./t_nebr_reclaim
import ./t_nebr_neutralize
import ./t_nebr_advance
import ./t_nebr_slot
import ./t_nebr_convenience
import ./t_nebr_refptr
import ./t_nebr_integration
import ./t_nebr_atomics
import ./t_nebr_dwcas_roundtrip
import ./t_nebr_dwcas_generation_rollover
import ./t_nebr_dwcas_pair_ptr
import ./t_nebr_dwcas_pair_alignment
import ./t_nebr_dwcas_pair_shape_positive
import ./t_nebr_dwcas_memory_orders
import ./t_nebr_dwcas_fetch_ops
import ./t_nebr_atomics_dsl
import ./t_nebr_thread_id
import ./t_nebr_backoff
import ./t_nebr_bind_client
import ./t_nebr_manager_cc_surface
import ./t_nebr_unregister_thread
import ./t_nebr_unregister_thread_stress
