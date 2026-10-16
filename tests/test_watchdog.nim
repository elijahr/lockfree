## Per-Test Sentinel Watchdog Thread & Hang Prevention (`tests/test_watchdog.nim`)
##
## Provides a default-ON, turn-offable per-test sentinel watchdog thread
## integrated into `unittest2`'s `OutputFormatter` lifecycle:
## - Starts a per-test deadline timer on `testStarted`.
## - Cancels/disarms the timer immediately on `testEnded`.
## - Signals and joins the sentinel thread via `joinThread` in `testRunEnded`
##   for zero ThreadSanitizer (TSan) thread leaks.
## - If any individual test exceeds the configured threshold, prints a
##   diagnostic naming the hung `Suite` and `Test` to `stderr` and terminates
##   the process immediately via `_exit(124)`.
##
## Configuration:
## - Compile-time timeout (seconds): `-d:lockfreeTestTimeoutSec=180` (default: 180)
## - Compile-time disable switch:    `-d:lockfreeNoTestWatchdog`
## - Runtime timeout (seconds):      `LFQ_TEST_TIMEOUT_SEC=180`
## - Runtime timeout (milliseconds): `LFQ_TEST_TIMEOUT_MS=...` (for fast tests)
## - Runtime enable/disable switch:  `LFQ_TEST_WATCHDOG=0` (or `false`/`off`/`no`)

when not compileOption("threads"):
  {.error: "tests/test_watchdog requires --threads:on".}

import std/[exitprocs, locks, monotimes, os, strutils]
import unittest2

const
  lockfreeTestTimeoutSec* {.intdefine.} = 180
    ## Default per-test watchdog timeout in seconds (3 minutes).
  lockfreeNoTestWatchdog* {.booldefine.} = false
    ## Compile-time switch to disable the per-test watchdog by default.
  WatchdogPollIntervalMs = 5
    ## Poll interval (ms) for checking deadline expiry and shutdown flag.
  WatchdogExitCode* = 124
    ## Standard timeout exit status code when a hung test is aborted.
  MaxNameBytes = 256

when defined(posix):
  proc c_exit(status: cint) {.importc: "_exit", header: "<unistd.h>", noreturn.}
else:
  proc c_exit(status: cint) {.importc: "_exit", header: "<stdlib.h>", noreturn.}

type
  WatchdogSharedState = object
    lock: Lock
    initialized: bool
    stopFlag: bool
    testActive: bool
    testGen: uint64
    startTimeNs: int64
    deadlineNs: int64
    timeoutNs: int64
    suiteLen: int
    suiteBuf: array[MaxNameBytes, char]
    testLen: int
    testBuf: array[MaxNameBytes, char]

  WatchdogOutputFormatter* = ref object of OutputFormatter

var
  gState: WatchdogSharedState
  gWatchdogThread: Thread[ptr WatchdogSharedState]
  gThreadRunning: bool = false
  gFormatterInstalled: bool = false

proc copyToFixedBuf(dest: var array[MaxNameBytes, char], destLen: var int, src: string) {.inline.} =
  let n = min(src.len, MaxNameBytes)
  destLen = n
  for i in 0 ..< n:
    dest[i] = src[i]

proc readFixedBuf(src: array[MaxNameBytes, char], srcLen: int): string =
  let n = clamp(srcLen, 0, MaxNameBytes)
  result = newString(n)
  for i in 0 ..< n:
    result[i] = src[i]

proc resolveWatchdogEnabled*(
    envVal: string = getEnv("LFQ_TEST_WATCHDOG", ""),
    compileTimeDisabled: bool = lockfreeNoTestWatchdog
): bool {.gcsafe.} =
  ## Resolves whether the per-test watchdog is enabled from runtime environment
  ## (`LFQ_TEST_WATCHDOG`) and compile-time `-d:lockfreeNoTestWatchdog`.
  let norm = envVal.strip().toLowerAscii()
  if norm in ["0", "false", "off", "no", "disabled"]:
    return false
  if norm in ["1", "true", "on", "yes", "enabled"]:
    return true
  return not compileTimeDisabled

proc resolveWatchdogTimeoutNs*(
    envSecVal: string = getEnv("LFQ_TEST_TIMEOUT_SEC", ""),
    envMsVal: string = getEnv("LFQ_TEST_TIMEOUT_MS", ""),
    defaultSec: int = lockfreeTestTimeoutSec
): int64 {.gcsafe.} =
  ## Resolves the per-test timeout threshold in nanoseconds.
  ## `LFQ_TEST_TIMEOUT_MS` takes precedence if set to a positive integer,
  ## followed by `LFQ_TEST_TIMEOUT_SEC`, then `lockfreeTestTimeoutSec` (default 180s).
  let msStripped = envMsVal.strip()
  if msStripped.len > 0:
    try:
      let ms = parseInt(msStripped)
      if ms > 0:
        return int64(ms) * 1_000_000'i64
    except ValueError:
      discard

  let secStripped = envSecVal.strip()
  if secStripped.len > 0:
    try:
      let sec = parseInt(secStripped)
      if sec > 0:
        return int64(sec) * 1_000_000_000'i64
    except ValueError:
      discard

  let fallbackSec = max(1, defaultSec)
  return int64(fallbackSec) * 1_000_000_000'i64

proc watchdogSentinelProc(state: ptr WatchdogSharedState) {.thread, nimcall, gcsafe.} =
  while true:
    acquire(state.lock)
    let shouldStop = state.stopFlag
    let isActive = state.testActive
    let deadlineNs = state.deadlineNs
    let startTimeNs = state.startTimeNs
    let timeoutNs = state.timeoutNs
    if shouldStop:
      release(state.lock)
      break

    if isActive:
      let nowNs = getMonoTime().ticks
      if nowNs >= deadlineNs:
        let suiteName = readFixedBuf(state.suiteBuf, state.suiteLen)
        let testName = readFixedBuf(state.testBuf, state.testLen)
        let elapsedSec = float64(nowNs - startTimeNs) / 1_000_000_000.0
        let thresholdSec = float64(timeoutNs) / 1_000_000_000.0
        release(state.lock)
        try:
          stderr.writeLine("")
          stderr.writeLine("================================================================================")
          stderr.writeLine("[LOCKFREE TEST WATCHDOG TIMEOUT]")
          stderr.writeLine("Hung test exceeded per-test timeout threshold (" &
            formatFloat(thresholdSec, ffDecimal, 3) & "s):")
          stderr.writeLine("  Suite:   " & (if suiteName.len > 0: suiteName else: "<default>"))
          stderr.writeLine("  Test:    " & testName)
          stderr.writeLine("  Elapsed: " & formatFloat(elapsedSec, ffDecimal, 3) & "s")
          stderr.writeLine("Aborting test runner process (exit code " & $WatchdogExitCode & ").")
          stderr.writeLine("================================================================================")
          stderr.flushFile()
          stdout.flushFile()
        except CatchableError:
          discard
        c_exit(cint(WatchdogExitCode))

    release(state.lock)
    os.sleep(WatchdogPollIntervalMs)

proc ensureWatchdogStateInit() {.raises: [].} =
  if not gState.initialized:
    initLock(gState.lock)
    gState.initialized = true
    gState.stopFlag = false
    gState.testActive = false
    gState.testGen = 0
    gState.timeoutNs = resolveWatchdogTimeoutNs()

proc startWatchdogThreadIfNeeded() {.raises: [].} =
  ensureWatchdogStateInit()
  if not gThreadRunning and resolveWatchdogEnabled():
    acquire(gState.lock)
    gState.stopFlag = false
    gState.timeoutNs = resolveWatchdogTimeoutNs()
    release(gState.lock)
    try:
      createThread(gWatchdogThread, watchdogSentinelProc, addr gState)
      gThreadRunning = true
    except CatchableError:
      gThreadRunning = false

proc shutdownTestWatchdog*() {.gcsafe, raises: [].} =
  ## Cancels any active test timer, signals the sentinel thread to stop,
  ## and joins it cleanly via `joinThread` for zero TSan thread leaks.
  {.cast(gcsafe).}:
    if not gState.initialized:
      return
    if gThreadRunning:
      acquire(gState.lock)
      gState.testActive = false
      gState.stopFlag = true
      release(gState.lock)
      joinThread(gWatchdogThread)
      gThreadRunning = false

proc isWatchdogThreadRunning*(): bool {.gcsafe, raises: [].} =
  {.cast(gcsafe).}:
    result = gThreadRunning

proc isWatchdogTestActive*(): bool {.gcsafe, raises: [].} =
  {.cast(gcsafe).}:
    if not gState.initialized:
      return false
    acquire(gState.lock)
    result = gState.testActive
    release(gState.lock)

method suiteStarted*(formatter: WatchdogOutputFormatter, suiteName: string) {.gcsafe, raises: [].} =
  {.cast(gcsafe).}:
    if not resolveWatchdogEnabled():
      return
    ensureWatchdogStateInit()
    acquire(gState.lock)
    copyToFixedBuf(gState.suiteBuf, gState.suiteLen, suiteName)
    release(gState.lock)

method testStarted*(formatter: WatchdogOutputFormatter, testName: string) {.gcsafe, raises: [].} =
  {.cast(gcsafe).}:
    if not resolveWatchdogEnabled():
      return
    startWatchdogThreadIfNeeded()
    let nowNs = getMonoTime().ticks
    let timeoutNs = resolveWatchdogTimeoutNs()
    acquire(gState.lock)
    copyToFixedBuf(gState.testBuf, gState.testLen, testName)
    inc gState.testGen
    gState.timeoutNs = timeoutNs
    gState.startTimeNs = nowNs
    gState.deadlineNs = nowNs + timeoutNs
    gState.testActive = true
    release(gState.lock)

method testEnded*(formatter: WatchdogOutputFormatter, testResult: TestResult) {.gcsafe, raises: [].} =
  {.cast(gcsafe).}:
    if not gState.initialized:
      return
    acquire(gState.lock)
    gState.testActive = false
    inc gState.testGen
    release(gState.lock)

method suiteEnded*(formatter: WatchdogOutputFormatter) {.gcsafe, raises: [].} =
  {.cast(gcsafe).}:
    if not gState.initialized:
      return
    acquire(gState.lock)
    gState.testActive = false
    gState.suiteLen = 0
    release(gState.lock)

method testRunEnded*(formatter: WatchdogOutputFormatter) {.gcsafe, raises: [].} =
  shutdownTestWatchdog()


proc installTestWatchdog*() =
  ## Idempotently registers `WatchdogOutputFormatter` with `unittest2` and
  ## starts the sentinel thread if enabled.
  if gFormatterInstalled:
    return
  gFormatterInstalled = true
  ensureWatchdogStateInit()
  addOutputFormatter(WatchdogOutputFormatter())
  if resolveWatchdogEnabled():
    startWatchdogThreadIfNeeded()
  addExitProc(proc() {.noconv.} =
    shutdownTestWatchdog()
  )

installTestWatchdog()

when declared(commandLineParams):
  if getEnv("LFQ_WATCHDOG_SELFTEST_HANG") == "1":
    var hangMs = 300
    try:
      let parsed = parseInt(getEnv("LFQ_WATCHDOG_SELFTEST_HANG_MS", "300").strip())
      if parsed > 0:
        hangMs = parsed
    except ValueError:
      discard
    suite "WatchdogSelfTestSuite":
      test "simulated_hung_test_case":
        var elapsed = 0
        while elapsed < hangMs:
          os.sleep(10)
          elapsed += 10
    shutdownTestWatchdog()
    quit(0)

