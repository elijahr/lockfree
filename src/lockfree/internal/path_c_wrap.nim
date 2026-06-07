## Path-C wrap/unwrap helpers — Wave C (v5.0.0).
##
## Encode user-facing ``T`` into its ``SlotEncoding(T)`` slot form at push
## time; decode back at pop time. Identity for POD ``T``. Internal-only.
##
## Lifecycle model (LOCKED by Wave C operator directive 2026-06-06):
## library inc paired with library dec WITHIN library scopes. For
## ``ref X`` the push wrapper does an explicit ``incRefSlot`` so the
## queue claims +1 of the cell's refcount lifetime; on the caller side
## the local binding's scope-exit ``=destroy`` balances back to net +1
## owned by the slot. Pop is a destructive read via ``move`` — the
## queue relinquishes the bits without a library ``decRefSlot`` (the
## caller's binding inherits the queue's +1). The queue-side library
## dec is the destroy-walk: ``disposeSlotEncoded`` runs ``decRefSlot``
## on every UNPOPPED slot, releasing the +1 the slot claimed at push.
##
## Type dispatch (mirrors ``SlotEncoding`` in slot_encoding.nim):
##   * ``ref X``    → ``ManagedRef[X]``    via ``toManagedRef`` / ``toRef``
##   * ``string``   → ``ManagedSlice[char]`` via ``wrap`` / ``unwrap``
##   * ``seq[U]``   → ``ManagedSlice[U]``    via ``wrap`` / ``unwrap``
##   * else (POD)   → ``T`` identity (assumed sizeof(T) <= sizeof(uint))

import ../managed_ref
import ../managed_slice
import ./slot_encoding

template wrapOrIdentity*[T](item: sink T): auto =
  ## Encode a user-facing ``T`` into its ``SlotEncoding(T)`` form.
  ##
  ## * ``ref X`` — bit-cast the pointer to ``ManagedRef[X]`` AND call
  ##   ``incRefSlot`` so the queue claims +1 of the cell's refcount
  ##   lifetime. The caller's ``sink`` consumption fires ``=destroy``
  ##   on the original binding when its scope ends, balancing back to
  ##   net +1 owned by the slot. The destroy-walk
  ##   (``disposeSlotEncoded`` → ``decRefSlot``) releases the +1 on any
  ##   UNPOPPED slot; pop transfers the +1 to the caller's binding via
  ##   destructive ``move`` (no library dec at pop).
  ## * ``string`` / ``seq[U]`` — box transfer via ``managed_slice.wrap``;
  ##   the queue holds the box pointer and ``disposeSlot`` frees the
  ##   box on destroy-walk.
  ## * POD — identity; ``sink`` consumes the source binding.
  bind wrap, toManagedRef, incRefSlot
  when T is ref:
    # Library +1 BEFORE the ``sink`` consumption inside ``toManagedRef``.
    #
    # ``toManagedRef`` takes ``sink ref X`` and the compiler emits
    # ``=destroy`` (``nimDecRefIsLast`` → dispose) on that parameter at
    # the end of ``toManagedRef``. If we incRefSlot AFTER toManagedRef
    # we would bump a freed pointer (use-after-free): the sink would
    # decrement to zero, dispose the cell, and then GC_ref would touch
    # the corpse. Bumping FIRST (on a non-sink view of the same bits)
    # keeps the cell alive across the sink's destroy: refcount goes
    # 1 → 2 (inc) → 1 (sink destroy) → +1 owned by the slot. Paired
    # with ``decRefSlot`` in ``disposeSlotEncoded[ref X]`` on the
    # destroy-walk; balanced on the caller side by ``=destroy`` of the
    # caller's source binding at scope exit (the sink consumes the
    # caller's local just as it consumes ours here).
    let mrefView = cast[ManagedRef[typeof(item[])]](item)
    incRefSlot(mrefView)
    toManagedRef(item)
  elif T is string:
    wrap(item)
  elif T is seq:
    wrap(item)
  else:
    # POD identity. ``sink`` still consumes the source binding.
    item

template unwrapOrIdentity*[T](encoded: SlotEncoding(T)): T =
  ## Decode a ``SlotEncoding(T)`` slot value back to user-facing ``T``.
  ## Pointer-bit / box-pointer transfer only — NO library refcount
  ## touch at pop. Pop is a destructive read (``move`` on the slot);
  ## the queue's +1 refcount share (claimed by ``wrapOrIdentity`` at
  ## push) is INHERITED by the caller's binding. ``=destroy`` will
  ## fire on the caller's binding when their local leaves scope.
  bind unwrap, toRef
  when T is ref:
    toRef(encoded)
  elif T is string:
    unwrap(encoded)
  elif T is seq:
    unwrap(encoded)
  else:
    encoded

template disposeSlotEncoded*[T](encoded: SlotEncoding(T)) =
  ## Per-slot destroy-walk for an UNPOPPED slot. Reconstructs the
  ## value and runs ``=destroy``. Internal-only. Used by queue / bqueue
  ## destructors when walking abandoned items.
  ##
  ## * POD ``T``     — identity. The encoded value is bit-for-bit ``T``;
  ##                   no managed resources, no-op.
  ## * ``ref X``     — delegate to ``managed_ref.decRefSlot`` which
  ##                   drops the cell's refcount via the per-MM shim
  ##                   (arc/orc/atomicArc/refc → ``GC_unref``; none →
  ##                   no-op; nimony → ``arcDec``). This is the
  ##                   analogue of ``managed_slice.disposeSlot`` for
  ##                   the ref-T arm. We intentionally do NOT use the
  ##                   "reconstruct a local ``ref X`` and let it leave
  ##                   scope" pattern: under ``--mm:arc`` the compiler's
  ##                   cursor inference treats such a local as a
  ##                   non-owning borrow and elides ``=destroy``,
  ##                   leaking the refcount. ``decRefSlot`` calls
  ##                   ``GC_unref`` on the bit-cast ``ref X`` directly,
  ##                   which is immune to cursor elision.
  ## * ``string`` /
  ##   ``seq[U]``    — delegate to ``managed_slice.disposeSlot`` which
  ##                   destroys the box payload and frees the box.
  ##
  ## All arms tolerate the zero / nil-bits sentinel: ``decRefSlot``
  ## short-circuits on nil bits via its own guard;
  ## ``managed_slice.disposeSlot`` checks the box pointer for nil.
  bind decRefSlot, disposeSlot
  when T is ref:
    # NOTE: we cannot use the "reconstruct ref X and let it die"
    # pattern here. Under --mm:arc the compiler's cursor inference
    # treats the local as a non-owning borrow and elides =destroy,
    # which leaks the refcount. Routing through ``decRefSlot`` (which
    # calls ``GC_unref`` on a bit-cast view) forces the per-MM drop
    # without any local binding for the cursor pass to scrutinise.
    # ``encoded`` is already ``ManagedRef[X]`` per SlotEncoding(T) for
    # ``T is ref X``, so we hand it to decRefSlot directly.
    decRefSlot(encoded)
  elif T is string:
    disposeSlot(encoded)
  elif T is seq:
    disposeSlot(encoded)
  else:
    discard
