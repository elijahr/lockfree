import ./t_aligned_alloc
import ./t_atomic_dsl
import ./t_backoff
import ./t_slot_seq_generation_rollover
# v5.0.0: legacy bounded test imports removed. Per-family
# Mpsc/Spmc/Mpmc/Spsc coverage now lives in the t_queue_bounded_*
# files below, with verified pass-count parity (mpsc 28/28, spmc 27/27,
# mpmc 28/28, spsc 21/21, mpsc_threaded 2/2, spsc_threaded 2/2). The
# legacy tests/t_{mpsc,spmc,mpmc,spsc}{,_threaded}.nim files remain on
# disk until they are deleted alongside their src/ counterparts.
import ./t_queue_enums
import ./t_queue_type_shell
import ./t_queue_bounded_mpsc_smoke
import ./t_queue_bounded_mpsc
import ./t_queue_bounded_spmc
import ./t_queue_bounded_mpmc
import ./t_queue_bounded_spsc
import ./t_queue_bounded_mpsc_threaded
import ./t_queue_bounded_spsc_threaded
import ./t_queue_bounded_mpmc_threaded
import ./t_queue_bounded_spmc_threaded
import ./t_unbounded_mpmc
import ./t_unbounded_mpmc_threaded
import ./t_unbounded_mpmc_move_analyzer
import ./t_unbounded_mpsc
import ./t_unbounded_mpsc_threaded
import ./t_unbounded_padding
import ./t_unbounded_spmc
import ./t_unbounded_spmc_threaded
import ./t_unbounded_spsc
import ./t_unbounded_spsc_threaded
import ./t_unbounded_auto_create
import ./t_queue_strategy_phantom
import ./t_lcrq_cell_alias
import ./t_lcrq_cell_primitives
import ./t_lcrq_init
import ./t_lcrq_push_single
import ./t_lcrq_pop_single
import ./t_lcrq_pop_race
import ./t_lcrq_pop_slowpath
import ./t_lcrq_push_close_race
import ./t_wave_c_smoke
import ./t_managed_slice_smoke
import ./t_lcrq_pop_critical_repros
import ./t_bqueue_mpmc_wide_T_accepted
import ./t_drain
import ./t_iterators
import ./t_destructor_walk
import ./t_typestate_dual_api
# Un-orphan the pinscope-unwind
# regression test. It is a plain destructor-driven unittest (no special
# flags / MM / panics:on), so it runs in the umbrella across the orc /
# cpp / arc / refc lanes the `test` task sweeps.
import ./t_pinscope_unwind
import ./composition/t_path_c_matrix
# Un-orphan the refcount matrix so it
# gets compile coverage in the umbrella. The real inc/dec balance
# assertion fires only under `-d:lockfreeRefcountTrace` (via the
# `testRefcountTrace` task); in the plain umbrella it emits a visible
# skip notice instead of a 0==0 tautology.
import ./composition/t_refcount_use_patterns
import ./composition/t_seq_char_dispose
import ./composition/t_verify_pop_clears_spsc_bounded
import ./composition/t_verify_pop_clears_mpsc_bounded
import ./composition/t_verify_pop_clears_spmc_bounded
import ./composition/t_verify_pop_clears_mpmc_bounded
import ./composition/t_verify_pop_clears_spsc_unbounded
import ./composition/t_verify_pop_clears_mpsc_unbounded
import ./composition/t_verify_pop_clears_spmc_unbounded
import ./composition/t_verify_pop_clears_mpmc_unbounded

import ./t_wraparound
import ./t_batch_pop
import ./t_systems_opt
import ./t_dwcas
import ./t_queue_aliases
import ./t_stack
import ./t_deque
import ./t_skiplist
import ./t_set
import ./t_taskpool
import ./t_ctrie
import ./t_broadcast
import ./t_rendezvous
import ./t_channel
import ./t_user_guide_snippets
import ./t_ratelimit
import ./t_streambuffer
import ./t_associative

# chronos adapter tests gated on chronos availability
# (chronos is NOT in lockfree.nimble requires). When chronos
# is on the Nim search path, the suite participates in the aggregator;
# otherwise it is silently skipped so the rest of the matrix continues
# to compile. The prime+bracket import dance mirrors the workaround in
# src/lockfree/chronos.nim (see the doc block there for the Nim quirk
# this sidesteps).
when (
  compiles do:
    import chronos/asyncsync
):
  discard
when (
  compiles do:
    import chronos/[asyncsync]
):
  import ./t_chronos

export
  t_aligned_alloc, t_atomic_dsl, t_backoff, t_slot_seq_generation_rollover,
  t_queue_enums, t_queue_type_shell, t_queue_bounded_mpsc_smoke, t_queue_bounded_mpsc,
  t_queue_bounded_spmc, t_queue_bounded_mpmc, t_queue_bounded_spsc,
  t_queue_bounded_mpsc_threaded, t_queue_bounded_spsc_threaded,
  t_queue_bounded_mpmc_threaded, t_queue_bounded_spmc_threaded, t_unbounded_mpmc,
  t_unbounded_mpmc_threaded, t_unbounded_mpmc_move_analyzer, t_unbounded_mpsc, t_unbounded_mpsc_threaded,
  t_unbounded_padding, t_unbounded_spmc, t_unbounded_spmc_threaded, t_unbounded_spsc,
  t_unbounded_spsc_threaded, t_unbounded_auto_create, t_queue_strategy_phantom,
  t_lcrq_cell_alias, t_lcrq_cell_primitives, t_lcrq_init, t_lcrq_push_single,
  t_lcrq_pop_single, t_lcrq_pop_race, t_lcrq_pop_slowpath, t_lcrq_push_close_race,
  t_lcrq_pop_critical_repros, t_bqueue_mpmc_wide_T_accepted, t_wraparound,
  t_wave_c_smoke, t_managed_slice_smoke, t_drain, t_iterators, t_destructor_walk,
  t_typestate_dual_api, t_pinscope_unwind, t_path_c_matrix,
  t_verify_pop_clears_spsc_bounded,
  t_verify_pop_clears_mpsc_bounded, t_verify_pop_clears_spmc_bounded,
  t_verify_pop_clears_mpmc_bounded, t_verify_pop_clears_spsc_unbounded,
  t_verify_pop_clears_mpsc_unbounded, t_verify_pop_clears_spmc_unbounded,
  t_verify_pop_clears_mpmc_unbounded, t_refcount_use_patterns,
  t_seq_char_dispose,
  t_systems_opt, t_batch_pop, t_dwcas, t_queue_aliases, t_stack, t_deque, t_skiplist, t_set, t_taskpool, t_ctrie, t_broadcast, t_rendezvous, t_channel, t_user_guide_snippets, t_ratelimit, t_streambuffer

when defined(lockfreeAsyncdispatch):
  import ./t_async_bridge
  export t_async_bridge

when (
  compiles do:
    import chronos/asyncsync
):
  discard
when (
  compiles do:
    import chronos/[asyncsync]
):
  export t_chronos
