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

  test "buildCompileCmd enforces --parallelBuild:1, per-bundle nimcache reuse, release debug-info stripping, and MSVC per-bundle /Fd: PDB":
    delEnv("LFQ_NIMCACHE_TAG")
    let defaultCacheRoot = getHomeDir() / ".cache" / "nim" / "test_runner_orc_c_vcc"
    let expectedDwcasCache = defaultCacheRoot / "t_dwcas"
    let binExt = when defined(windows): ".exe" else: ""

    let releaseVccCmd = buildCompileCmd(
      testPath = "tests/t_dwcas.nim",
      mm = "orc",
      backend = "c",
      cc = "vcc",
      nimcacheDir = "",
      isRelease = true,
      isDanger = false,
      workerSlot = 0
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
      "--opt:none",
      "--assertions:on",
      "--debugger:off",
      "--debuginfo:off",
      "--nimcache:" & expectedDwcasCache,
      "--out:" & (expectedDwcasCache / ("t_dwcas" & binExt)),
      "--passC:/Fd:" & (expectedDwcasCache / "vc140.pdb"),
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
      isDanger = true,
      workerSlot = 3
    )
    let customQueueCache = "/tmp/custom_nimcache" / "t_queue"
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
      "--nimcache:" & customQueueCache,
      "--out:" & (customQueueCache / ("t_queue" & binExt)),
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
      isDanger = false,
      workerSlot = 2
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
      "--nimcache:" & expectedDwcasCache,
      "--out:" & (expectedDwcasCache / ("t_dwcas" & binExt)),
      "--passC:/Fd:" & (expectedDwcasCache / "vc140.pdb"),
      "-r",
      "tests/t_dwcas.nim"
    ]

    let bundledVccCmd = buildCompileCmd(
      testPath = "tests/unit/runner_primitives.nim",
      mm = "orc",
      backend = "c",
      cc = "vcc",
      nimcacheDir = "",
      isRelease = true,
      isDanger = false,
      workerSlot = 1,
      isBundled = true
    )
    let expectedPrimitivesCache = defaultCacheRoot / "runner_primitives"
    check bundledVccCmd == @[
      "c",
      "--mm:orc",
      "--threads:on",
      "--parallelBuild:2",
      "--path:src",
      "-d:testing",
      "--verbosity:0",
      "--hints:off",
      "--warnings:off",
      "--cc:vcc",
      "-d:release",
      "-u:debug",
      "--opt:none",
      "--assertions:on",
      "--debugger:off",
      "--debuginfo:off",
      "--nimcache:" & expectedPrimitivesCache,
      "--out:" & (expectedPrimitivesCache / ("runner_primitives" & binExt)),
      "--passC:/Fd:" & (expectedPrimitivesCache / "vc140.pdb"),
      "-r",
      "tests/unit/runner_primitives.nim"
    ]

    putEnv("LFQ_NIMCACHE_TAG", "nim_2.2.12")
    let taggedCmd = buildCompileCmd(
      testPath = "tests/t_dwcas.nim",
      mm = "orc",
      backend = "c",
      cc = "vcc",
      nimcacheDir = "",
      isRelease = true,
      isDanger = false,
      workerSlot = 0
    )
    delEnv("LFQ_NIMCACHE_TAG")
    let expectedTaggedCache = getHomeDir() / ".cache" / "nim" / "test_runner_orc_c_vcc_nim_2.2.12" / "t_dwcas"
    check "--nimcache:" & expectedTaggedCache in taggedCmd

    check findQueueBundles().len == 8
    check findStructureBundles().len == 2
    check findSyncBundles().len == 2
    check findUnitBundles().len == 13
    check findConcurrencyBundles().len == 5
    check resolveBundledMode(0, "", bundledFlag = false, unbundledFlag = false) == true
    check resolveBundledMode(0, "", bundledFlag = true, unbundledFlag = false) == true
    check resolveBundledMode(0, "", bundledFlag = false, unbundledFlag = true) == false
    check resolveBundledMode(1, "", bundledFlag = false, unbundledFlag = false) == false
    check resolveBundledMode(0, "dwcas", bundledFlag = false, unbundledFlag = false) == false
