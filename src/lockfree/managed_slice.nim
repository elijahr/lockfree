## lockfree/managed_slice
##
## Internal slot encoding for ``string`` and ``seq[U]`` payloads under
## Path C (`Queue[string, ...]` / `Queue[seq[U], ...]`). See design
## §4.4 (rewritten 2026-06-06 — unified encoding; box pattern, 3rd
## revision) of ``docs/internal/2026-06-05-umbrella-v0.1.0-design.md``.
##
## NEVER user-facing
## -----------------
##
## ``ManagedSlice[T]`` is the wire-format the queue stores in its slot
## array. The user-facing API is ``string`` / ``seq[U]``. ManagedSlice
## MUST NOT leak into public docs, examples, or signatures.
##
## Design pattern: heap-boxed payload pointer
## ------------------------------------------
##
## The slot bits are a ``distinct uint`` pointer at a heap-allocated
## box (``alloc0Shared``) that holds the V2 payload (``NimStringV2`` /
## ``NimSeqV2[U]``). Box layout deliberately mirrors a ``ptr object``
## with a single ``v`` field of the payload type so that under
## arc/orc/atomicArc/refc the compiler-emitted destructor for ``v``
## runs the V2 ``frees()`` path automatically when ``=destroy`` is
## called explicitly in ``disposeSlot``.
##
## Path C MM matrix
## ----------------
##
## * arc / orc / atomicArc / refc — sink-assign payload into the
##   zero-initialised box on ``wrap`` (compiler emits ``=sink``);
##   ``move`` the payload out and ``deallocShared`` the box on
##   ``unwrap``; ``=destroy`` the box payload + ``deallocShared`` the
##   box on ``disposeSlot`` (destructor walk).
## * none — strict bit-transport contract (§2.8). The source binding
##   is NOT zeroed on ``wrap`` and the destination is NOT destroyed
##   on ``disposeSlot``. The user owns lifetime; we are a pointer-bit
##   transport only.
##
## ABI stability (§2.10)
## ---------------------
##
## ``sizeof(ManagedSlice[T])`` == ``sizeof(uint)`` on every supported
## platform — asserted at compile time in the ``static:`` block below.

# Path C invariant: ``ManagedSlice`` is an internal slot encoding. The
# only legal importers are the queue cores (``lockfree/queue``,
# ``lockfree/bqueue``), the internal ``slot_encoding`` mapper, and the
# managed-payload tests.

type
  StringBox = ptr object
    v: string

  SeqBox[U] = ptr object
    v: seq[U]

  ManagedSlice*[T] = distinct uint
    ## Slot encoding for a ``string`` (``T = char``) or ``seq[U]``
    ## (``T = U``) payload. Internal — see module doc-comment. Sized
    ## and aligned identically to ``uint`` (§2.10).

# ---------------------------------------------------------------------
# §2.10 ABI claim: bit-identity with ``uint``.
# ---------------------------------------------------------------------
static:
  assert sizeof(ManagedSlice[char]) == sizeof(uint),
    "ManagedSlice[char] must be sizeof(uint) for §2.10 ABI parity"
  assert sizeof(ManagedSlice[int]) == sizeof(uint),
    "ManagedSlice[U] must be sizeof(uint) for §2.10 ABI parity"

# ---------------------------------------------------------------------
# wrap — heap-allocate the box and transfer payload into it.
#
# Per-MM:
#   arc/orc/atomicArc/refc: ``box.v = s`` is a sink-assign into a
#     zero-initialised LHS — safe; the compiler-emitted ``=sink``
#     moves the payload pointer and zeroes the source. (The box was
#     allocated with alloc0Shared, so the LHS already satisfies the
#     "zero-initialised destination" precondition for =sink.)
#   none: bit-transport via copyMem; source binding is NOT zeroed,
#     per the §2.8 strict contract.
# ---------------------------------------------------------------------

proc wrap*(s: sink string): ManagedSlice[char] {.inline.} =
  ## Pack a ``string`` into the slot encoding. Allocates a shared
  ## heap box and transfers the payload in. The caller's binding is
  ## consumed (``sink``).
  let box = cast[StringBox](allocShared0(sizeof(string)))
  when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc) or
       defined(gcRefc):
    box.v = s
  else:
    # mm:none — strict bit-transport. Source `s` not zeroed; caller
    # owns lifecycle per §2.8.
    copyMem(addr box.v, addr s, sizeof(string))
  result = ManagedSlice[char](cast[uint](box))

proc wrap*[U](s: sink seq[U]): ManagedSlice[U] {.inline.} =
  ## Pack a ``seq[U]`` into the slot encoding. Allocates a shared
  ## heap box and transfers the payload in.
  ##
  ## §2.5 rows 18-19 (`seq[ref U]`, `seq[seq[U]]`) are ACCEPTED as of
  ## 2026-06-06. The box-pattern transport handles inner-element
  ## lifecycle correctly via Nim's compiler-emitted seq ``=destroy``
  ## when the box is reconstructed at pop or destroy-walk. The
  ## library's transport is the outer seq value (boxed here); inner
  ## refs/seqs are the seq's lifecycle problem per design §2.5
  ## rationale. The former R7 ``supportsCopyMem(U)`` guard was
  ## removed alongside the matching assert in path_c_admit.nim.
  let box = cast[SeqBox[U]](allocShared0(sizeof(seq[U])))
  when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc) or
       defined(gcRefc):
    box.v = s
  else:
    copyMem(addr box.v, addr s, sizeof(seq[U]))
  result = ManagedSlice[U](cast[uint](box))

# ---------------------------------------------------------------------
# unwrap — move payload out of the box and deallocate the box.
# ---------------------------------------------------------------------

proc unwrap*(ms: ManagedSlice[char]): string {.inline.} =
  ## Unpack a ``string`` from the slot encoding. Frees the heap box.
  ## On arc/orc/atomicArc/refc the payload pointer is moved out (no
  ## refcount bump on the V2 payload); on mm:none the payload bits
  ## are copied out and the source bits are not zeroed.
  let box = cast[StringBox](ms.uint)
  when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc) or
       defined(gcRefc):
    result = move(box.v)
  else:
    copyMem(addr result, addr box.v, sizeof(string))
  deallocShared(box)

proc unwrap*[U](ms: ManagedSlice[U]): seq[U] {.inline.} =
  ## Unpack a ``seq[U]`` from the slot encoding. Frees the heap box.
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
# Used by the queue's destructor (§4.7.2) to release any payloads
# still in the ring when the queue itself is destroyed. Calls
# ``=destroy`` on the box's payload field (which runs the V2
# ``frees()`` path under arc/orc/atomicArc/refc) and then frees the
# box itself. mm:none is a strict bit-transport contract: no
# destructor on the payload (caller owns it), just free the box.
# ---------------------------------------------------------------------

proc disposeSlot*(ms: ManagedSlice[char]) {.inline.} =
  ## Destroy-walk dispose for an unpopped string slot. Safe on the
  ## nil slot (0).
  if ms.uint == 0:
    return
  let box = cast[StringBox](ms.uint)
  when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc) or
       defined(gcRefc):
    `=destroy`(box.v)
  # mm:none: no destructor — payload lifecycle is caller's per §2.8.
  deallocShared(box)

proc disposeSlot*[U](ms: ManagedSlice[U]) {.inline.} =
  ## Destroy-walk dispose for an unpopped seq slot. Safe on the nil
  ## slot (0).
  if ms.uint == 0:
    return
  let box = cast[SeqBox[U]](ms.uint)
  when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc) or
       defined(gcRefc):
    `=destroy`(box.v)
  deallocShared(box)
