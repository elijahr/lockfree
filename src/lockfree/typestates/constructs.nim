## ===========================================================================
## First-Class Domain Typestate Extension Constructs (`lockfree/typestates/constructs`)
## ===========================================================================
##
## Bridges user-defined `nim-typestates` state machines with `lockfree`
## transport primitives (`BQueue`, `Queue`, `Bound`, `Channel`, `TreiberStack`,
## `BStack`, `ChaseLevDeque`, `BroadcastRing`, `RendezvousChannel`).
##
## Features:
## - Re-exports the `nim-typestates` DSL (`typestate`, `transition`,
##   `notATransition`, `destructorTransition`, `verifyTypestates`, `TypestateOp`)
##   so consumer projects can author compile-time state machines directly via
##   `import lockfree/typestates` or `import lockfree`.
## - `TypestateGate[Base, InState, OutState, Transport]`: Zero-overhead
##   type-safe transport gate that accepts `sink InState` on ingress (`sendState` /
##   `trySendState` / `pushBottom`) and yields `Option[OutState]` on egress
##   (`recvState` / `tryRecvState` / `stealState`), enforcing domain state
##   transitions across thread/channel boundaries with move-only ARC/ORC safety.
## - `TypestatePipelineStage[Base, InState, MidState, OutState, InTransport, OutTransport]`:
##   Composable multi-stage typestate actor/pipeline step that consumes `InState`
##   from `inbound`, applies a `InState -> MidState` transition proc, and forwards
##   `MidState -> OutState` into `outbound`.

import std/options
export options

import ../internal/typestates_dsl
export typestates_dsl

type
  TypestateGate*[Base, InState, OutState, Transport] = object
    ## Zero-overhead typestate transport gate parameterized by:
    ## - `Base`: The underlying carrier type stored in `Transport`
    ## - `InState`: Required source typestate (`distinct Base`) on ingress
    ## - `OutState`: Resulting target typestate (`distinct Base`) on egress
    ## - `Transport`: Any `lockfree` queue, stack, deque, ring, channel, or `Bound` endpoint
    transport*: ptr Transport

  TypestatePipelineStage*[
    Base,
    InState,
    MidState,
    OutState,
    InTransport,
    OutTransport
  ] = object
    ## Composable pipeline stage bridging an `inbound` transport (`Base` -> `InState`)
    ## and an `outbound` transport (`MidState` -> `OutState`).
    inbound*: TypestateGate[Base, InState, InState, InTransport]
    outbound*: TypestateGate[Base, MidState, OutState, OutTransport]

proc initTypestateGate*[Base, InState, OutState, Transport](
    transport: var Transport
): TypestateGate[Base, InState, OutState, Transport] {.inline, notATransition.} =
  ## Wraps `transport` in a compile-time `InState -> OutState` typestate gate.
  static:
    doAssert sizeof(InState) == sizeof(Base),
      "TypestateGate requires InState to be a distinct Base with identical representation"
    doAssert sizeof(OutState) == sizeof(Base),
      "TypestateGate requires OutState to be a distinct Base with identical representation"
  TypestateGate[Base, InState, OutState, Transport](transport: addr transport)

proc trySendState*[Base, InState, OutState, Transport, ItemT](
    gate: TypestateGate[Base, InState, OutState, Transport],
    item: sink ItemT
): bool {.inline, notATransition.} =
  ## Consumes `item` in state `InState` via `move` (preserving ARC/ORC ownership
  ## without extra copies) and enqueues/pushes it into `gate.transport`.
  mixin trySend, tryPush, push, pushBottom, publish
  when not (ItemT is InState):
    {.
      error:
        "TypestateGate domain state mismatch: trySendState requires InState payload transition, got incompatible state type."
    .}
  else:
    doAssert gate.transport != nil, "TypestateGate is uninitialized"
    var baseVal: Base = Base(move(item))
    when compiles(gate.transport[].trySend(move(baseVal))):
      gate.transport[].trySend(move(baseVal))
    elif compiles(gate.transport[].tryPush(move(baseVal))):
      gate.transport[].tryPush(move(baseVal))
    elif compiles(gate.transport[].push(move(baseVal))):
      when typeof(gate.transport[].push(move(baseVal))) is bool:
        gate.transport[].push(move(baseVal))
      else:
        gate.transport[].push(move(baseVal))
        true
    elif compiles(gate.transport[].pushBottom(move(baseVal))):
      gate.transport[].pushBottom(move(baseVal))
      true
    elif compiles(gate.transport[].publish(move(baseVal))):
      discard gate.transport[].publish(move(baseVal))
      true
    else:
      {.error: "Transport type does not support trySend, tryPush, push, pushBottom, or publish".}

proc sendState*[Base, InState, OutState, Transport, ItemT](
    gate: TypestateGate[Base, InState, OutState, Transport],
    item: sink ItemT
): bool {.discardable, inline, notATransition.} =
  ## Consumes `item` in state `InState` and sends/pushes it through `gate.transport`.
  when not (ItemT is InState):
    {.
      error:
        "TypestateGate domain state mismatch: sendState requires InState payload transition, got incompatible state type."
    .}
  else:
    gate.trySendState(move(item))

proc recvState*[Base, InState, OutState, Transport](
    gate: TypestateGate[Base, InState, OutState, Transport]
): Option[OutState] {.inline, notATransition.} =
  ## Pops/receives the next payload from `gate.transport` and transitions it into
  ## `OutState` via `move`.
  mixin tryRecv, pop, popBottom, steal
  doAssert gate.transport != nil, "TypestateGate is uninitialized"
  when compiles(gate.transport[].tryRecv()):
    var opt = gate.transport[].tryRecv()
    if opt.isSome:
      var raw = move(opt.get())
      return some(OutState(move(raw)))
    return none(OutState)
  elif compiles(gate.transport[].pop()):
    var opt = gate.transport[].pop()
    if opt.isSome:
      var raw = move(opt.get())
      return some(OutState(move(raw)))
    return none(OutState)
  elif compiles(gate.transport[].popBottom()):
    var opt = gate.transport[].popBottom()
    if opt.isSome:
      var raw = move(opt.get())
      return some(OutState(move(raw)))
    return none(OutState)
  elif compiles(gate.transport[].steal()):
    var opt = gate.transport[].steal()
    if opt.isSome:
      var raw = move(opt.get())
      return some(OutState(move(raw)))
    return none(OutState)
  else:
    {.error: "Transport type does not support tryRecv, pop, popBottom, or steal".}

proc tryRecvState*[Base, InState, OutState, Transport](
    gate: TypestateGate[Base, InState, OutState, Transport],
    outItem: var OutState
): bool {.inline, notATransition.} =
  ## Non-blocking receive into `outItem` in state `OutState`.
  var opt = gate.recvState()
  if opt.isSome:
    outItem = move(opt.get())
    return true
  return false

proc stealState*[Base, InState, OutState, Transport](
    gate: TypestateGate[Base, InState, OutState, Transport]
): Option[OutState] {.inline, notATransition.} =
  ## Work-stealing egress for `ChaseLevDeque` or thief `Bound` endpoints,
  ## yielding `Option[OutState]` via `move`.
  mixin steal
  doAssert gate.transport != nil, "TypestateGate is uninitialized"
  when compiles(gate.transport[].steal()):
    var opt = gate.transport[].steal()
    if opt.isSome:
      var raw = move(opt.get())
      return some(OutState(move(raw)))
    return none(OutState)
  else:
    {.error: "stealState requires a ChaseLevDeque or DequeThiefTag Bound endpoint supporting steal()".}

# ---------------------------------------------------------------------------
# `TypestatePipelineStage` Operations & Compile-Time Guards
# ---------------------------------------------------------------------------

proc initTypestatePipelineStage*[
    Base,
    InState,
    MidState,
    OutState,
    InTransport,
    OutTransport
](
    inbound: var InTransport,
    outbound: var OutTransport
): TypestatePipelineStage[Base, InState, MidState, OutState, InTransport, OutTransport] {.inline, notATransition.} =
  ## Initializes a typed pipeline stage that pops `InState` from `inbound`,
  ## transforms `InState -> MidState`, and pushes `MidState -> OutState` to `outbound`.
  TypestatePipelineStage[Base, InState, MidState, OutState, InTransport, OutTransport](
    inbound: initTypestateGate[Base, InState, InState, InTransport](inbound),
    outbound: initTypestateGate[Base, MidState, OutState, OutTransport](outbound)
  )

proc stepStage*[
    Base,
    InState,
    MidState,
    OutState,
    InTransport,
    OutTransport
](
    stage: TypestatePipelineStage[Base, InState, MidState, OutState, InTransport, OutTransport],
    transform: proc(s: sink InState): MidState {.gcsafe.}
): bool {.inline, notATransition.} =
  ## Pulls one `InState` item from `stage.inbound`, applies `transform` to
  ## transition `InState -> MidState`, and sends `MidState` into `stage.outbound`.
  ## Returns `true` if an item was processed and forwarded, or `false` if `inbound` was empty.
  var inOpt = stage.inbound.recvState()
  if inOpt.isNone:
    return false
  var midVal = transform(move(inOpt.get()))
  stage.outbound.trySendState(move(midVal))

