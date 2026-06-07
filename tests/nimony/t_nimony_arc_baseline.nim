## T-TEST-NIMONY local scope: verify nimony-gated arms don't regress
## the non-nimony build. CI Cell 14 (continue-on-error) validates
## actual nimony semantics; this test only ensures the arc baseline
## compiles + runs cleanly while the nimony branches are inert under
## standard Nim 2.x memory managers.
##
## Locally exercised:
##   * `src/lockfree/managed_ref.nim` `when defined(nimony):` block
##     (lines 275-309) — the nimony arm of `incRefSlot` / `decRefSlot`
##     which is inert under arc/orc/atomicArc/refc.
##
## Nimony-gated sites inventory (verified 2026-06-06):
##   * `src/lockfree/managed_ref.nim:275` — single `when defined(nimony):`
##     block (incRefSlot / decRefSlot arcops bridge).
##
## Partial-port TODOs inside the nimony arms (PG-10 Cell 14 inventory):
##   * OQ4.2 (managed_ref.nim:288, 299) — heap-header offset for
##     NimHeapHeader layout; current code assumes the rc field lives at
##     the slot bits address. Verified against
##     /tmp/nimony-research/lib/std/system/arcops.nim per Phase 2.5
##     fact-check; replacement deferred to v0.2.
##   * OQ4.4 (managed_ref.nim:306) — dispose-on-last-ref symbol omitted
##     in v0.1.0. `arcDec` returning true currently `discard`s the
##     last-ref signal; the leak is observable only under `-d:nimony`
##     (Cell 14, `continue-on-error`).
##
## Out of scope (local): actual nimony codegen / semantics — that lives
## entirely behind CI Cell 14.

import std/options
import lockfree/bqueue
import lockfree/role_tags

when defined(nimony):
  echo "nimony build detected; actual nimony tests would run here (CI Cell 14)"
else:
  # Arc baseline: verify the standard surface works while nimony
  # arms are inert. We exercise `ref T` (which routes through
  # managed_ref.nim's incRefSlot/decRefSlot — the non-nimony arm)
  # and `string` (the §4.4 payload-park path) to cover the two
  # accept-row populations whose lifecycle code lives near the
  # nimony gate.

  type Foo = ref object
    v: int

  block ref_payload_routes_through_non_nimony_arm:
    # `ref Foo` exercises managed_ref.nim's incRefSlot/decRefSlot.
    # Under arc, the templates at lines 155-192 own the dispatch and
    # the nimony arm at line 275 must remain inert. If the nimony
    # arm were ever expanded under arc (e.g., a missing `when` guard),
    # `arcInc` / `arcDec` would either fail to compile (no
    # `std/system/arcops` under standard Nim) or corrupt the ref's
    # refcount.
    var q: BQueue[Foo, ccSingle, ccSingle, 16, 0, 0]
    let pushed = q.push(Foo(v: 42))
    doAssert pushed == true, "SPSC push(ref Foo) must succeed on empty queue"
    let got = q.pop()
    doAssert got.isSome, "SPSC pop must return Some after a successful push"
    doAssert got.get.v == 42, "popped ref's payload must round-trip exactly"

  block string_payload_compiles_and_round_trips:
    # `string` exercises the §4.4 payload-park path. Co-located with
    # the ref test because the same nimony-gated module owns the slot
    # encoding helpers.
    var q: BQueue[string, ccSingle, ccSingle, 16, 0, 0]
    let pushed = q.push("hello")
    doAssert pushed == true, "SPSC push(string) must succeed on empty queue"
    let got = q.pop()
    doAssert got.isSome, "SPSC pop must return Some after a successful push"
    doAssert got.get == "hello", "popped string must round-trip exactly"

  echo "nimony arms inert under arc; baseline OK"
