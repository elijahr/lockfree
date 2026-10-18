## Compile-fail control: sending a wrong domain typestate into `TypestateGate` is rejected.
import lockfree
import lockfree/typestates

type
  PacketPayload = ref object of RootObj
    id: int
    body: string

  PacketDraft = distinct PacketPayload
  PacketValidated = distinct PacketPayload
  PacketDispatched = distinct PacketPayload

typestate PacketFlow:
  consumeOnTransition = false
  strictTransitions = true
  inheritsFromRootObj = true
  states:
    PacketDraft
    PacketValidated
    PacketDispatched
  initial:
    PacketDraft
  terminal:
    PacketDispatched
  transitions:
    PacketDraft -> PacketValidated
    PacketValidated -> PacketDispatched

var q = newBQueue[PacketPayload, ccSingle, ccSingle, 16, 0, 0]()
var gate = initTypestateGate[PacketPayload, PacketValidated, PacketDispatched, typeof(q)](q)
var draft = PacketDraft(PacketPayload(id: 1, body: "unvalidated"))
discard gate.sendState(draft)

verifyTypestates()
