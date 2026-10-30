## Driver for lockfree' compile-fail test suite.
##
## Each entry asserts (a) the expected exit status from `nim c` (zero
## for positive cases, non-zero for negative cases) and (b) that the
## compiler's combined stdout+stderr contains a pinned error-message
## substring specific to the failure mode under test.
##
## Pinning the substring (rather than just the exit status) guards
## against silent regressions where the compile-fail still happens but
## the underlying check has rotted — e.g., a future overload-set change
## that drops the γ bounded-asymmetry guard, or a Strategy/cardinality
## phantom-param tightening that silently widens lookup.
##
## Ported from nebr 0.8.0's `tests/should_fail/runner.nim`
## with a project-specific case table covering the
## 5 conditions enumerated in :
##   1. Consumer ST=stManual vs Queue ST=stEager (Strategy phantom).
##   2. ccCons=ccSingle queue rejects ccMulti DebraManager/handle.
##   3. ccCons=ccMulti  queue rejects ccSingle DebraManager.
##   4. (γ) bounded-asymmetry: retireOnCAS on Queue[..., rkNone, ...].
##   5. (γ) bounded-asymmetry: retireOnPublish on
##      Queue[..., ccCons=ccMulti, rkEbr, ...].
##
##

import std/[os, osproc, strformat, strutils, times]

when defined(posix):
  import std/posix
elif defined(windows):
  import std/winlean
  proc peekNamedPipe(hPipe: Handle, lpBuffer: pointer, nBufferSize: int32,
                     lpBytesRead: ptr int32, lpTotalBytesAvail: ptr int32,
                     lpBytesLeftThisMessage: ptr int32): WINBOOL {.
      stdcall, dynlib: "kernel32", importc: "PeekNamedPipe".}

type
  ExpectedOutcome = enum
    eoCompiles # `nim c` must exit 0; no substring needed.
    eoCompileFails # `nim c` must exit non-zero; substring must appear.

  Case = object
    name: string
    file: string
    outcome: ExpectedOutcome
    substring: string

const cases = @[
  Case(
    name:
      "t_queue_cardinality_mismatch §6.3 (1) — Consumer ST=stManual vs Queue ST=stEager",
    file: "tests/should_fail/strategy_st_mismatch.nim",
    outcome: eoCompileFails,
    substring: "stManual",
  ),
  Case(
    name:
      "t_queue_cardinality_mismatch §6.3 (2) — ccCons=ccSingle queue rejects ccMulti handle",
    file: "tests/should_fail/cc_consumer_single_rejects_multi.nim",
    outcome: eoCompileFails,
    # Tightened: pin the EXPECTED manager-cardinality signature
    # the guard enforces (ccSingle), not the bare constructor name the
    # compiler echoes from the call line. A different error on the same
    # construction line can no longer false-match.
    substring: "DebraManager[MaxThreads, ccSingle]",
  ),
  Case(
    name:
      "t_queue_cardinality_mismatch §6.3 (3) — ccCons=ccMulti queue rejects ccSingle manager",
    file: "tests/should_fail/cc_consumer_multi_rejects_single.nim",
    outcome: eoCompileFails,
    # Tightened: pin the EXPECTED manager-cardinality signature
    # the guard enforces (ccMulti), not the bare constructor name.
    substring: "DebraManager[MaxThreads, ccMulti]",
  ),
  Case(
    name:
      "t_queue_bounded_no_retire §6.3 (4) — retireOnCAS on Queue[..., rkNone, ...] (γ guard)",
    file: "tests/should_fail/bounded_no_retire_on_cas.nim",
    outcome: eoCompileFails,
    substring: "retireOnCAS",
  ),
  Case(
    name:
      "t_queue_bounded_no_retire §6.3 (5) — retireOnPublish on Queue[..., ccCons=ccMulti, rkEbr, ...] (γ guard)",
    file: "tests/should_fail/bounded_no_retire_on_publish_mc.nim",
    outcome: eoCompileFails,
    substring: "retireOnPublish",
  ),
  # Family-level coverage of `{.error.}` cardinality gates. One case per
  # BQueue/Queue * push/pop family, exercising the cardinality
  # `{.error.}` overload through the family-named thin-wrappers
  # (`newMpscQueue`, `newSpmcQueue`, `newMpmcQueue`,
  # `newUnboundedSpmcQueue`). Family-level rather than per-individual-
  # wrapper.
  Case(
    name:
      "t_bqueue_cardinality §6.3 (6) — direct push on ccProd=ccMulti BQueue is forbidden",
    file: "tests/should_fail/bqueue_multi_producer_direct_push.nim",
    outcome: eoCompileFails,
    substring: "multi-producer BQueue",
  ),
  Case(
    name:
      "t_bqueue_cardinality §6.3 (7) — direct pop on ccCons=ccMulti BQueue is forbidden",
    file: "tests/should_fail/bqueue_multi_consumer_direct_pop.nim",
    outcome: eoCompileFails,
    substring: "multi-consumer BQueue",
  ),
  Case(
    name:
      "t_queue_cardinality §6.3 (8) — direct pop on ccCons=ccMulti Queue is forbidden",
    file: "tests/should_fail/queue_multi_consumer_direct_pop.nim",
    outcome: eoCompileFails,
    substring: "multi-consumer Queue",
  ),
  Case(
    name:
      "t_bqueue_cardinality §6.3 (9) — direct batch push on ccProd=ccMulti BQueue is forbidden",
    file: "tests/should_fail/bqueue_multi_producer_batch_push.nim",
    outcome: eoCompileFails,
    substring: "batch push on a multi-producer BQueue",
  ),
  # Cases (10)-(14) cover the Middle-axis Claim-state typestate
  # and the deliberate-negative cross-module containment. The
  # ccSingle-attach cases all assert the same substring fragment
  # `BQueueProducer` / `BQueueConsumer` / `QueueProducer` /
  # `QueueConsumer` — these are the user-visible alias names that
  # appear in the Nim "type mismatch" diagnostic;
  # no `*Multi`/`*Single` backing-type leakage.
  Case(
    name: "t_bqueue_claimstate §6.3 (10) — ccSingle BQueueProducer cannot attach",
    file: "tests/should_fail/bqueue_producer_attach_ccsingle.nim",
    outcome: eoCompileFails,
    # Tightened (T2-010): pin the failure MODE (the ccSingle alias is not
    # declared), not just the echoed identifier — an unrelated error on
    # the same declaration line can no longer false-match.
    substring: "undeclared identifier: 'BQueueProducer'",
  ),
  Case(
    name: "t_bqueue_claimstate §6.3 (11) — ccSingle BQueueConsumer cannot attach",
    file: "tests/should_fail/bqueue_consumer_attach_ccsingle.nim",
    outcome: eoCompileFails,
    # Tightened (T2-010): pin the failure mode, not the echoed identifier.
    substring: "undeclared identifier: 'BQueueConsumer'",
  ),
  Case(
    name: "t_queue_claimstate §6.3 (12) — ccSingle QueueProducer cannot attach",
    file: "tests/should_fail/queue_producer_attach_ccsingle.nim",
    outcome: eoCompileFails,
    # Tightened (T2-010): pin the failure mode, not the echoed identifier.
    substring: "undeclared identifier: 'QueueProducer'",
  ),
  Case(
    name: "t_queue_claimstate §6.3 (13) — ccSingle QueueConsumer cannot attach",
    file: "tests/should_fail/queue_consumer_attach_ccsingle.nim",
    outcome: eoCompileFails,
    # Tightened (T2-010): pin the failure mode, not the echoed identifier.
    substring: "undeclared identifier: 'QueueConsumer'",
  ),
  Case(
    name:
      "t_bqueue_lifecycle §6.3 — cross-module state-preserving op requires {.notATransition.}",
    file: "tests/should_fail/bqueue_cross_module_no_notATransition.nim",
    outcome: eoCompileFails,
    substring: "notATransition",
  ),
  Case(
    name: "endpoint L1 — push on Unbound endpoint is a lifecycle violation",
    file: "tests/should_fail/endpoint_push_on_unbound.nim",
    outcome: eoCompileFails,
    # Tightened (T2-010): the bare word "push" matched any mention of
    # push in the output. Pin the actual diagnostic (no push routine is
    # declared for an Unbound endpoint).
    substring: "undeclared routine: 'push'",
  ),
  Case(
    name: "endpoint L2 (tripwire a) — SPSC push on consumer-tag endpoint",
    file: "tests/should_fail/endpoint_push_on_consumer_tag.nim",
    outcome: eoCompileFails,
    substring: "SpscConsumerTag",
  ),
  Case(
    name: "endpoint L2 (tripwire b) — SPSC pop on producer-tag endpoint",
    file: "tests/should_fail/endpoint_pop_on_producer_tag.nim",
    outcome: eoCompileFails,
    substring: "SpscProducerTag",
  ),
  Case(
    name: "endpoint L2 (tripwire c) — forbids-region calling tagged push",
    file: "tests/should_fail/endpoint_forbids_region.nim",
    outcome: eoCompileFails,
    substring: "forbids",
  ),
  Case(
    name: "endpoint L2 (tripwire d) — MPMC push on consumer-tag endpoint",
    file: "tests/should_fail/endpoint_mpmc_push_on_consumer_tag.nim",
    outcome: eoCompileFails,
    substring: "MpmcConsumerTag",
  ),
  Case(
    name:
      "spawn — defineProducerWorker inside proc body must compile-fail (module-scope guard)",
    file: "tests/should_fail/spawn_nested_scope.nim",
    outcome: eoCompileFails,
    # Tightened (T2-010): pin the full guard diagnostic, not the bare
    # fragment "top level".
    substring: "'export' is only allowed at top level",
  ),
  Case(
    name:
      "unbounded MPMC Queue rejects sizeof(T) > 8",
    file: "tests/should_fail/unbounded_mpmc_wide_T_rejected.nim",
    outcome: eoCompileFails,
    # Two layered guards reject wide T on the ccMulti × ccMulti arm:
    #   1. debra's `enforceDwcasConstraints` static assertion (fires at
    #      construction-time via `Atomic[Pair[uint64, T]].store` in
    #      `newSegment`): "sizeof(B) <= 8 Pair half-type ... must be
    #      <= 8 bytes (DWCAS pairs two 64-bit registers)".
    #   2. The v5.0.0 `{.error.}` in `proc push` (queue.nim):
    #      "requires sizeof(T) <= 8".
    # Construction trips (1) before `push` is expanded, so we pin
    # against debra's substring — the OUTER enforcement layer. If the
    # narrowing is ever removed from the unbounded MPMC arm, BOTH
    # layers stop firing and the test fails — the tripwire is sound
    # either way.
    substring: "Pair half-type",
  ),
  # The managed-slice wrap[U] supportsCopyMem guard has no negative
  # compile-fail case: the box-pattern transport handles inner-element
  # lifecycle via the compiler-emitted seq =destroy, so the guard was
  # dropped and the compile-fail no longer applies.
  # design §2.5 REJECT rows. The Path-C admission gate
  # (src/lockfree/internal/path_c_admit.nim) emits verbatim `{.error.}`
  # messages for rows 7 (distinct ref alias) and 8 (nested ref). The
  # admit template expands inside `push`, so each test must actually
  # invoke push to materialise the static-dispatch chain.
  Case(
    name:
      "t_path_c_matrix §2.5 — distinct ref alias rejected by path_c_admit",
    file: "tests/composition/should_fail/t_path_c_reject_distinct_ref.nim",
    outcome: eoCompileFails,
    substring: "distinct ref alias",
  ),
  Case(
    name:
      "t_path_c_matrix §2.5 — nested `ref ref X` rejected by path_c_admit",
    file: "tests/composition/should_fail/t_path_c_reject_nested_ref.nim",
    outcome: eoCompileFails,
    substring: "nested ref",
  ),
  Case(
    name:
      "deque role guard — DequeOwnerTag endpoint cannot call steal()",
    file: "tests/should_fail/deque_owner_cannot_steal.nim",
    outcome: eoCompileFails,
    substring: "steal on a DequeOwnerTag endpoint is forbidden",
  ),
  Case(
    name:
      "deque role guard — DequeThiefTag endpoint cannot call pushBottom()",
    file: "tests/should_fail/deque_thief_cannot_push_bottom.nim",
    outcome: eoCompileFails,
    substring: "pushBottom on a DequeThiefTag endpoint is forbidden",
  ),
  Case(
    name:
      "btable role guard — TableReaderTag endpoint cannot call put()",
    file: "tests/should_fail/btable_reader_cannot_put.nim",
    outcome: eoCompileFails,
    substring: "Cannot call 'put' on a read-only BTable endpoint",
  ),
  Case(
    name:
      "stack role guard — MpmcConsumerTag TreiberStack endpoint cannot call push()",
    file: "tests/should_fail/stack_consumer_cannot_push.nim",
    outcome: eoCompileFails,
    substring: "push on a consumer-tagged TreiberStack endpoint",
  ),
  Case(
    name:
      "bstack role guard — MpmcProducerTag BStack endpoint cannot call pop()",
    file: "tests/should_fail/bstack_producer_cannot_pop.nim",
    outcome: eoCompileFails,
    substring: "pop on a producer-tagged BStack endpoint",
  ),
  Case(
    name:
      "typestate construct — TypestateGate rejects wrong domain state on sendState()",
    file: "tests/should_fail/typestate_gate_wrong_state_rejected.nim",
    outcome: eoCompileFails,
    substring: "TypestateGate domain state mismatch: sendState requires InState payload transition",
  ),
  Case(
    name:
      "bqueue copy-safety — BQueue cannot be copied",
    file: "tests/should_fail/bqueue_copy_forbidden.nim",
    outcome: eoCompileFails,
    substring: "is not available for type <BQueue>",
  ),
  Case(
    name:
      "ratelimit copy-safety — TokenBucket cannot be copied",
    file: "tests/should_fail/ratelimit_copy_forbidden.nim",
    outcome: eoCompileFails,
    substring: "is not available for type <TokenBucket>",
  ),
  Case(
    name:
      "bqueue128 copy-safety — BQueue128 cannot be copied",
    file: "tests/should_fail/bqueue128_copy_forbidden.nim",
    outcome: eoCompileFails,
    substring: "is not available for type <BQueue128>",
  ),
  Case(
    name:
      "stack128 copy-safety — TaggedStack cannot be copied",
    file: "tests/should_fail/stack128_copy_forbidden.nim",
    outcome: eoCompileFails,
    substring: "is not available for type <TaggedStack>",
  ),
  Case(
    name:
      "tokenbucket64 copy-safety — TokenBucket64 cannot be copied",
    file: "tests/should_fail/tokenbucket64_copy_forbidden.nim",
    outcome: eoCompileFails,
    substring: "is not available for type <TokenBucket64>",
  ),
]


type
  RunningCase = object
    idx: int
    p: Process
    t0: float
    output: string

proc drainProcessOutput(rc: var RunningCase) =
  when defined(posix):
    let fd = rc.p.outputHandle.cint
    var buf: array[4096, char]
    while true:
      let n = posix.read(fd, addr buf[0], buf.len)
      if n > 0:
        let oldLen = rc.output.len
        rc.output.setLen(oldLen + n)
        copyMem(addr rc.output[oldLen], addr buf[0], n)
      else:
        break
  elif defined(windows):
    let h = cast[Handle](rc.p.outputHandle)
    var avail: int32 = 0
    while peekNamedPipe(h, nil, 0, nil, addr avail, nil) != 0 and avail > 0:
      var buf: array[4096, char]
      var bytesRead: int32 = 0
      let toRead = min(avail, int32(buf.len))
      if winlean.readFile(h, addr buf[0], toRead, addr bytesRead, nil) != 0 and bytesRead > 0:
        let oldLen = rc.output.len
        rc.output.setLen(oldLen + int(bytesRead))
        copyMem(addr rc.output[oldLen], addr buf[0], int(bytesRead))
      else:
        break

proc evaluateCase(c: Case, output: string, exitCode: int): bool =
  case c.outcome
  of eoCompiles:
    if exitCode != 0:
      echo &"[FAIL] {c.name}: expected exit 0, got {exitCode}"
      echo output
      return false
    echo &"[PASS] {c.name}"
    return true
  of eoCompileFails:
    if exitCode == 0:
      echo &"[FAIL] {c.name}: expected non-zero exit, got 0 (unexpected success)"
      echo output
      return false
    if not output.contains(c.substring):
      echo &"[FAIL] {c.name}: substring not found"
      echo &"       expected substring: {c.substring}"
      echo "       actual output:"
      echo output
      return false
    echo &"[PASS] {c.name} (exit {exitCode}, substring matched)"
    return true

proc main() =
  # Child nim invocations use the worktree's nimble.paths (regenerated
  # by `nimble setup` / `nimble install -dy`) for dep resolution, with
  # isolated per-case `--nimcache` directories so parallel `nim c --compileOnly`
  # workers never collide.
  let maxWorkers = max(1, countProcessors())
  let ccEnv = getEnv("LFQ_CC", "")
  var timeoutSec = 180.0
  let envTimeout = getEnv("LFQ_TEST_TIMEOUT_SEC", "")
  if envTimeout.len > 0:
    try:
      timeoutSec = parseFloat(envTimeout)
    except ValueError:
      discard
  let cacheBase = getTempDir() / ("lockfree_should_fail_" & $getCurrentProcessId())
  var running: seq[RunningCase] = @[]
  var outputs = newSeq[string](cases.len)
  var exitCodes = newSeq[int](cases.len)
  var completed = newSeq[bool](cases.len)
  var nextIdx = 0
  var nextPrintIdx = 0
  var failed = 0

  while nextIdx < cases.len or running.len > 0:
    while running.len < maxWorkers and nextIdx < cases.len:
      let idx = nextIdx
      inc nextIdx
      let c = cases[idx]
      var args = @[
        "c",
        "--threads:on",
        "--hints:off",
        "--warnings:off",
        "--path:src",
        "--compileOnly",
        "--nimcache:" & (cacheBase / ("case_" & $idx)),
        c.file
      ]
      if ccEnv.len > 0:
        args.insert("--cc:" & ccEnv, 1)
      let p = startProcess("nim", args = args, options = {poStdErrToStdOut, poUsePath})
      when defined(posix):
        let fd = p.outputHandle.cint
        let flags = fcntl(fd, F_GETFL, 0)
        discard fcntl(fd, F_SETFL, flags or O_NONBLOCK)
      running.add(RunningCase(idx: idx, p: p, t0: epochTime(), output: ""))

    var i = 0
    var anyFinished = false
    while i < running.len:
      drainProcessOutput(running[i])
      var code = running[i].p.peekExitCode()
      let dur = epochTime() - running[i].t0
      if code == -1 and dur > timeoutSec:
        when defined(windows):
          discard execShellCmd("taskkill /F /T /PID " & $running[i].p.processID & " >NUL 2>&1")
        elif defined(posix):
          discard execShellCmd("pkill -KILL -P " & $running[i].p.processID & " >/dev/null 2>&1")
        running[i].p.kill()
        code = 124
        running[i].output.add("\n[TIMEOUT] Compile-fail case exceeded " & $int(timeoutSec) & "s watchdog limit and was terminated.\n")

      if code != -1:
        drainProcessOutput(running[i])
        let idx = running[i].idx
        outputs[idx] = running[i].output
        exitCodes[idx] = code
        completed[idx] = true
        running[i].p.close()
        running.delete(i)
        anyFinished = true
      else:
        inc i

    while nextPrintIdx < cases.len and completed[nextPrintIdx]:
      if not evaluateCase(cases[nextPrintIdx], outputs[nextPrintIdx], exitCodes[nextPrintIdx]):
        inc failed
      flushFile(stdout)
      inc nextPrintIdx

    if not anyFinished and running.len > 0:
      sleep(5)

  try:
    removeDir(cacheBase)
  except CatchableError:
    discard

  if failed > 0:
    echo &"\n{failed} compile-fail case(s) failed."
    quit(1)
  echo &"\nAll {cases.len} compile-fail cases passed."

main()
