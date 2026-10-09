## lockfree/managed_slice
##
## Internal slot encoding for ``string`` and ``seq[U]`` payloads under Path C
## (`Queue[string, ...]` / `Queue[seq[U], ...]`). Unified encoding using the
## heap-box pattern.
##
## NEVER user-facing
## -----------------
##
## ``ManagedSlice[T]`` is the wire-format the queue stores in its slot array.
## The user-facing API is ``string`` / ``seq[U]``. ManagedSlice MUST NOT leak
## into public docs, examples, or signatures.
##
## Design pattern: heap-boxed payload pointer
## ------------------------------------------
##
## The slot bits are a ``distinct uint`` pointer at a heap-allocated box
## (``alloc0Shared``) that holds the V2 payload (``NimStringV2`` /
## ``NimSeqV2[U]``). Box layout deliberately mirrors a ``ptr object`` with a
## single ``v`` field of the payload type so that under arc/orc/atomicArc/refc
## the compiler-emitted destructor for ``v`` runs the V2 ``frees()`` path
## automatically when ``=destroy`` is called explicitly in ``disposeSlot``.
##
## Path C MM matrix
## ----------------
##
## * arc / orc / atomicArc / refc — sink-assign payload into the
##   zero-initialised box on ``wrap`` (compiler emits ``=sink``); ``move`` the
##   payload out and ``deallocShared`` the box on ``unwrap``; ``=destroy`` the
##   box payload + ``deallocShared`` the box on ``disposeSlot`` (destructor
##   walk).
## * none — strict bit-transport contract. The source binding is NOT zeroed on
##   ``wrap`` and the destination is NOT destroyed on ``disposeSlot``. The user
##   owns lifetime; we are a pointer-bit transport only.
##
## ABI stability
## -------------
##
## ``sizeof(ManagedSlice[T])`` == ``sizeof(uint)`` on every supported platform
## — asserted at compile time in the ``static:`` block below.

# Path C invariant: ``ManagedSlice`` is an internal slot encoding. The only
# legal importers are the queue cores (``lockfree/queue``, ``lockfree/bqueue``),
# the internal ``slot_encoding`` mapper, and the managed-payload tests.

# Under ``-d:lockfreeSliceDisposeTrace`` the dispose paths below call
# ``bumpStringDispose`` / ``bumpSeqDispose`` from the test-only trace shim so
# ``tests/composition/t_seq_char_dispose.nim`` can assert that a ``seq[char]``
# slot is routed to the SEQ disposer (``disposeSeqSlot``) and NOT the string
# disposer (``disposeSlot(ManagedSlice[char])``). The import is guarded by the
# define so it is NEVER pulled into release builds (zero-cost when the define is
# unset). The shim path is supplied by the ``testSliceDispose`` nimble task
# (``--path:tests/composition``); it imports only ``std/atomics`` so there is no
# import cycle back into ``managed_slice``.
when defined(lockfreeSliceDisposeTrace):
  import slice_dispose_trace_shim

type
  StringBox = ptr object
    v: string

  SeqBox[U] = ptr object
    v: seq[U]

  ManagedSlice*[T] = distinct uint
    ## Slot encoding for a ``string`` (``T = char``) or ``seq[U]`` (``T = U``)
    ## payload. Internal — see module doc-comment. Sized and aligned
    ## identically to ``uint``.

# ---------------------------------------------------------------------
# ABI claim: bit-identity with ``uint``.
# ---------------------------------------------------------------------
static:
  assert sizeof(ManagedSlice[char]) == sizeof(uint),
    "ManagedSlice[char] must be sizeof(uint) for §2.10 ABI parity"
  assert sizeof(ManagedSlice[int]) == sizeof(uint),
    "ManagedSlice[U] must be sizeof(uint) for §2.10 ABI parity"

# ---------------------------------------------------------------------
# wrap — heap-allocate the box and transfer payload into it.
#
# Per-MM: arc/orc/atomicArc/refc: ``box.v = s`` is a sink-assign into a
# zero-initialised LHS — safe; the compiler-emitted ``=sink`` moves the
# payload pointer and zeroes the source. (The box was allocated with
# alloc0Shared, so the LHS already satisfies the "zero-initialised destination"
# precondition for =sink.) none: bit-transport via copyMem; source binding is
# NOT zeroed, per the strict bit-transport contract.
# ---------------------------------------------------------------------

proc wrap*(s: sink string): ManagedSlice[char] {.inline.} =
  ## Pack a ``string`` into the slot encoding. Allocates a shared heap box and
  ## transfers the payload in. The caller's binding is consumed (``sink``).
  let box = cast[StringBox](allocShared0(sizeof(string)))
  when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc) or
       defined(gcRefc):
    box.v = s
  else:
    # mm:none — strict bit-transport. Source `s` not zeroed; caller owns
    # lifecycle.
    copyMem(addr box.v, addr s, sizeof(string))
  result = ManagedSlice[char](cast[uint](box))

proc wrap*[U](s: sink seq[U]): ManagedSlice[U] {.inline.} =
  ## Pack a ``seq[U]`` into the slot encoding. Allocates a shared heap box and
  ## transfers the payload in.
  ##
  ## `seq[ref U]` and `seq[seq[U]]` are ACCEPTED. The box-pattern transport
  ## handles inner-element lifecycle correctly via Nim's compiler-emitted seq
  ## ``=destroy`` when the box is reconstructed at pop or destroy-walk. The
  ## library's transport is the outer seq value (boxed here); inner refs/seqs
  ## are the seq's lifecycle problem. No ``supportsCopyMem(U)`` guard is applied
  ## here or in path_c_admit.nim.
  let box = cast[SeqBox[U]](allocShared0(sizeof(seq[U])))
  when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc):
    # arc/orc/atomicArc: ``box.v = s`` is a compiler-emitted ``=sink`` into the
    # zero-initialised box (the box was alloc0'd, satisfying the =sink
    # "destination already destroyed" precondition). The payload pointer moves;
    # the ``sink`` source ``s`` is consumed.
    box.v = s
  elif defined(gcRefc):
    # refc: ``box.v = s`` through a cast raw ``ptr object`` field is NOT
    # compiled as a ``=sink`` move. refc routes it through its legacy
    # ``genericAssign`` path, which shallow-shares the seq buffer and then runs
    # ``=destroy`` on the live ``sink`` source ``s`` at wrap's scope exit. The
    # box's shared payload is destroyed AGAIN at
    # ``disposeSeqSlot``/``unwrapSeq``, so each element's user ``=destroy`` runs
    # TWICE (double-destruction; observable as the destructor-walk live counter
    # going negative under --mm:refc, and a genuine double-free for elements
    # that own heap resources). Bit- transport the seq header into the box and
    # ``wasMoved`` the source so its scope-exit ``=destroy`` is a no-op: this
    # reproduces the move semantics arc/orc get from the compiler, destroying
    # each element exactly once. (Validated: ctor==dtor on refc/arc/orc.)
    copyMem(addr box.v, addr s, sizeof(seq[U]))
    wasMoved(s)
  else:
    # mm:none — strict bit-transport. Source `s` not zeroed; caller owns
    # lifecycle (see module doc-comment).
    copyMem(addr box.v, addr s, sizeof(seq[U]))
  result = ManagedSlice[U](cast[uint](box))

# ---------------------------------------------------------------------
# unwrap — move payload out of the box and deallocate the box.
# ---------------------------------------------------------------------

proc unwrap*(ms: ManagedSlice[char]): string {.inline.} =
  ## Unpack a ``string`` from the slot encoding. Frees the heap box. On
  ## arc/orc/atomicArc/refc the payload pointer is moved out (no refcount bump
  ## on the V2 payload); on mm:none the payload bits are copied out and the
  ## source bits are not zeroed.
  let box = cast[StringBox](ms.uint)
  when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc) or
       defined(gcRefc):
    result = move(box.v)
  else:
    copyMem(addr result, addr box.v, sizeof(string))
  deallocShared(box)

proc unwrapSeq*[U](ms: ManagedSlice[U]): seq[U] {.inline.} =
  ## Unpack a ``seq[U]`` from the slot encoding. Frees the heap box.
  ##
  ## Distinctly named (``unwrapSeq``, not ``unwrap``) so the seq path is never
  ## shadowed by the non-generic ``unwrap(ManagedSlice[char])``
  ## (string/StringBox) overload. ``ManagedSlice[char]`` is the slot encoding
  ## for BOTH ``string`` (``T = char``) and ``seq[char]`` (``U = char``); they
  ## collapse to the same instantiation, so Nim overload resolution would pick
  ## the non-generic string ``unwrap`` for a ``seq[char]`` slot, applying the
  ## StringBox layout to a SeqBox. The distinct name forces the SeqBox path
  ## explicitly. See ``internal/path_c_wrap.nim``.
  let box = cast[SeqBox[U]](ms.uint)
  when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc) or
       defined(gcRefc):
    result = move(box.v)
  else:
    copyMem(addr result, addr box.v, sizeof(seq[U]))
  deallocShared(box)

# ---------------------------------------------------------------------
# disposeSlot — destructor walk for unpopped slots.
#
# Used by the queue's destructor to release any payloads still in the ring when
# the queue itself is destroyed. Calls ``=destroy`` on the box's payload field
# (which runs the V2 ``frees()`` path under arc/orc/atomicArc/refc) and then
# frees the box itself. mm:none is a strict bit-transport contract: no
# destructor on the payload (caller owns it), just free the box.
# ---------------------------------------------------------------------

proc disposeSlot*(ms: ManagedSlice[char]) {.inline.} =
  ## Destroy-walk dispose for an unpopped string slot. Safe on the nil slot (0).
  ##
  ## Non-generic (string / StringBox) overload. ``disposeSeqSlot`` is the
  ## distinctly-named SEQ counterpart so a ``seq[char]`` slot is never routed
  ## here by overload resolution (StringBox vs SeqBox layout). See
  ## ``internal/path_c_wrap.nim``.
  if ms.uint == 0:
    return
  when defined(lockfreeSliceDisposeTrace):
    bumpStringDispose()
  let box = cast[StringBox](ms.uint)
  when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc) or
       defined(gcRefc):
    `=destroy`(box.v)
  # mm:none: no destructor — payload lifecycle is caller's.
  deallocShared(box)

proc disposeSeqSlot*[U](ms: ManagedSlice[U]) {.inline.} =
  ## Destroy-walk dispose for an unpopped seq slot. Safe on the nil slot (0).
  ##
  ## Distinctly named (``disposeSeqSlot``, not ``disposeSlot``) so the seq path
  ## is never shadowed by the non-generic ``disposeSlot(ManagedSlice[char])``
  ## (string/StringBox) overload. ``ManagedSlice[char]`` is the slot encoding
  ## for BOTH ``string`` and ``seq[char]``; they collapse to the same
  ## instantiation, so Nim overload resolution would pick the non-generic string
  ## ``disposeSlot`` for a ``seq[char]`` slot, running the StringBox destructor
  ## over a SeqBox. The distinct name forces the SeqBox path explicitly. See
  ## ``internal/path_c_wrap.nim``.
  if ms.uint == 0:
    return
  when defined(lockfreeSliceDisposeTrace):
    bumpSeqDispose()
  let box = cast[SeqBox[U]](ms.uint)
  when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc) or
       defined(gcRefc):
    `=destroy`(box.v)
  deallocShared(box)
