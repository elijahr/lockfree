## Unit & Subprocess Negative-Control Tests for Per-Test Sentinel Watchdog (`tests/t_test_watchdog.nim`)

import std/[os, osproc, strtabs, strutils]
import unittest2
import ./test_watchdog
import ./test_runner

proc cloneCurrentEnv(overrides: openArray[(string, string)]): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    result[k] = v
  for (k, v) in overrides:
    result[k] = v

suite "Per-Test Sentinel Watchdog (Task 1.9)":
  test "resolveWatchdogEnabled defaults to true and honors runtime/compile-time switches":
    check resolveWatchdogEnabled("", compileTimeDisabled = false) == true
    check resolveWatchdogEnabled("", compileTimeDisabled = true) == false

    for disabledVal in ["0", "false", "FALSE", "off", "no", "disabled", " 0 "]:
      check resolveWatchdogEnabled(disabledVal, compileTimeDisabled = false) == false

    for enabledVal in ["1", "true", "TRUE", "on", "yes", "enabled", " 1 "]:
      check resolveWatchdogEnabled(enabledVal, compileTimeDisabled = true) == true

  test "resolveWatchdogTimeoutNs defaults to 180s and honors LFQ_TEST_TIMEOUT_SEC / LFQ_TEST_TIMEOUT_MS":
    check lockfreeTestTimeoutSec == 180
    check resolveWatchdogTimeoutNs("", "", 180) == 180_000_000_000'i64
    check resolveWatchdogTimeoutNs("45", "", 180) == 45_000_000_000'i64
    check resolveWatchdogTimeoutNs("45", "125", 180) == 125_000_000'i64
    check resolveWatchdogTimeoutNs("invalid", "invalid", 180) == 180_000_000_000'i64
    check resolveWatchdogTimeoutNs("-5", "0", 180) == 180_000_000_000'i64

  test "sentinel thread and per-test timer are active during test execution":
    if resolveWatchdogEnabled():
      check isWatchdogThreadRunning() == true
      check isWatchdogTestActive() == true

  test "negative control: hung test exceeding threshold aborts with WatchdogExitCode (124) and diagnostic":
    let appBin = getAppFilename()
    check fileExists(appBin)

    let childEnv = cloneCurrentEnv([
      ("LFQ_WATCHDOG_SELFTEST_HANG", "1"),
      ("LFQ_WATCHDOG_SELFTEST_HANG_MS", "500"),
      ("LFQ_TEST_WATCHDOG", "1"),
      ("LFQ_TEST_TIMEOUT_MS", "25")
    ])
    let (output, exitCode) = execCmdEx(
      quoteShell(appBin),
      options = {poStdErrToStdOut, poUsePath},
      env = childEnv
    )
    check exitCode == WatchdogExitCode
    check "[LOCKFREE TEST WATCHDOG TIMEOUT]" in output
    check "Suite:   WatchdogSelfTestSuite" in output
    check "Test:    simulated_hung_test_case" in output

  test "turn-offable control: LFQ_TEST_WATCHDOG=0 disables timeout enforcement":
    let appBin = getAppFilename()
    check fileExists(appBin)

    let childEnv = cloneCurrentEnv([
      ("LFQ_WATCHDOG_SELFTEST_HANG", "1"),
      ("LFQ_WATCHDOG_SELFTEST_HANG_MS", "60"),
      ("LFQ_TEST_WATCHDOG", "0"),
      ("LFQ_TEST_TIMEOUT_MS", "15")
    ])
    let (output, exitCode) = execCmdEx(
      quoteShell(appBin),
      options = {poStdErrToStdOut, poUsePath},
      env = childEnv
    )
    check exitCode == 0
    check "[LOCKFREE TEST WATCHDOG TIMEOUT]" notin output

  test "buildCompileCmd enforces --parallelBuild:1, isolated nimcache, release debug-info stripping, and MSVC per-test /Fd: PDB":
    let defaultCacheRoot = getHomeDir() / ".cache" / "nim" / "test_runner_orc_c_vcc"
    let expectedPerTestCache = defaultCacheRoot / "t_dwcas"

    let releaseVccCmd = buildCompileCmd(
      testPath = "tests/t_dwcas.nim",
      mm = "orc",
      backend = "c",
      cc = "vcc",
      nimcacheDir = "",
      isRelease = true,
      isDanger = false
    )
    check releaseVccCmd == @[
      "c",
      "--mm:orc",
      "--threads:on",
      "--parallelBuild:1",
      "--path:src",
      "-d:testing",
      "--verbosity:0",
      "--hints:off",
      "--warnings:off",
      "--cc:vcc",
      "-d:release",
      "-u:debug",
      "--opt:speed",
      "--assertions:on",
      "--debugger:off",
      "--debuginfo:off",
      "--nimcache:" & expectedPerTestCache,
      "-r",
      "tests/t_dwcas.nim"
    ]

    let dangerCppCmd = buildCompileCmd(
      testPath = "tests/t_queue.nim",
      mm = "arc",
      backend = "cpp",
      cc = "",
      nimcacheDir = "/tmp/custom_nimcache",
      isRelease = false,
      isDanger = true
    )
    check dangerCppCmd == @[
      "cpp",
      "--mm:arc",
      "--threads:on",
      "--parallelBuild:1",
      "--path:src",
      "-d:testing",
      "--verbosity:0",
      "--hints:off",
      "--warnings:off",
      "-d:danger",
      "-u:debug",
      "--opt:speed",
      "--debugger:off",
      "--debuginfo:off",
      "--nimcache:" & ("/tmp/custom_nimcache" / "t_queue"),
      "-r",
      "tests/t_queue.nim"
    ]

    let debugVccCmd = buildCompileCmd(
      testPath = "tests/t_dwcas.nim",
      mm = "orc",
      backend = "c",
      cc = "vcc",
      nimcacheDir = "",
      isRelease = false,
      isDanger = false
    )
    check debugVccCmd == @[
      "c",
      "--mm:orc",
      "--threads:on",
      "--parallelBuild:1",
      "--path:src",
      "-d:testing",
      "--verbosity:0",
      "--hints:off",
      "--warnings:off",
      "--cc:vcc",
      "--nimcache:" & expectedPerTestCache,
      "--passC:/Fd:" & (expectedPerTestCache / "vc140.pdb"),
      "-r",
      "tests/t_dwcas.nim"
    ]
