## High-Performance Parallel Test Runner for lockfree
## Runs test files concurrently across CPU cores, bypassing monolithic AST bloat.

import std/[os, osproc, strutils, times, terminal]

when defined(posix):
  import std/posix
elif defined(windows):
  import std/winlean
  proc peekNamedPipe(hPipe: Handle, lpBuffer: pointer, nBufferSize: int32,
                     lpBytesRead: ptr int32, lpTotalBytesAvail: ptr int32,
                     lpBytesLeftThisMessage: ptr int32): WINBOOL {.
      stdcall, dynlib: "kernel32", importc: "PeekNamedPipe".}

type
  TestResult = object
    path: string
    duration: float
    exitCode: int
    output: string

  RunningProcess = object
    path: string
    p: Process
    t0: float
    output: string
    workerSlot: int

proc drainProcessOutput(rp: var RunningProcess) =
  when defined(posix):
    let fd = rp.p.outputHandle.cint
    var buf: array[4096, char]
    while true:
      let n = posix.read(fd, addr buf[0], buf.len)
      if n > 0:
        let oldLen = rp.output.len
        rp.output.setLen(oldLen + n)
        copyMem(addr rp.output[oldLen], addr buf[0], n)
      else:
        break
  elif defined(windows):
    let h = cast[Handle](rp.p.outputHandle)
    var avail: int32 = 0
    if peekNamedPipe(h, nil, 0, nil, addr avail, nil) != 0 and avail > 0:
      var buf: array[4096, char]
      var bytesRead: int32 = 0
      let toRead = min(avail, int32(buf.len))
      if winlean.readFile(h, addr buf[0], toRead, addr bytesRead, nil) != 0 and bytesRead > 0:
        let oldLen = rp.output.len
        rp.output.setLen(oldLen + int(bytesRead))
        copyMem(addr rp.output[oldLen], addr buf[0], int(bytesRead))

proc parseImportsFrom(runnerRelPath: string): seq[string] =
  let runnerFile = currentSourcePath().parentDir() / runnerRelPath
  if fileExists(runnerFile):
    for line in lines(runnerFile):
      let trimmed = line.strip()
      if trimmed.startsWith("import ../"):
        let rel = trimmed.replace("import ../", "") & ".nim"
        let p = currentSourcePath().parentDir() / rel
        if fileExists(p):
          result.add(p)

proc findUnitTests(): seq[string] =
  parseImportsFrom("unit/runner.nim")

proc findConcurrencyTests(): seq[string] =
  parseImportsFrom("concurrency/runner.nim")

proc findQueueTests(): seq[string] =
  parseImportsFrom("unit/runner_queues.nim")

proc findStructureTests(): seq[string] =
  parseImportsFrom("unit/runner_structures.nim")

proc findSyncTests(): seq[string] =
  parseImportsFrom("unit/runner_sync.nim")

proc findPrimitiveTests(): seq[string] =
  parseImportsFrom("unit/runner_primitives.nim")

proc resolveTestPaths(relPaths: openArray[string]): seq[string] =
  let baseDir = currentSourcePath().parentDir()
  for rel in relPaths:
    let p = baseDir / rel
    if fileExists(p):
      result.add(p)

proc findQueueBundles*(): seq[string] =
  resolveTestPaths([
    "unit/runner_queues_lifecycle.nim",
    "unit/runner_queues_typestate.nim",
    "unit/runner_queues_unbounded.nim",
    "unit/runner_queues_unbounded_api.nim",
    "unit/runner_queues_unbounded_spsc_mpsc.nim",
    "unit/runner_queues_bounded.nim",
    "unit/runner_queues_composition.nim",
    "unit/runner_queues_lcrq.nim"
  ])

proc findStructureBundles*(): seq[string] =
  resolveTestPaths([
    "unit/runner_structures_trees.nim",
    "unit/runner_structures_containers.nim"
  ])

proc findSyncBundles*(): seq[string] =
  resolveTestPaths([
    "unit/runner_sync_channels.nim",
    "unit/runner_sync_primitives.nim"
  ])

proc findUnitBundles*(): seq[string] =
  result = findSyncBundles()
  result.add(findStructureBundles())
  result.add(findQueueBundles())
  result.add(resolveTestPaths([
    "unit/runner_primitives.nim"
  ]))

proc findConcurrencyBundles*(): seq[string] =
  resolveTestPaths([
    "concurrency/runner_concurrency_cabi.nim",
    "concurrency/runner_concurrency_io.nim",
    "concurrency/runner_concurrency_queues.nim",
    "concurrency/runner_concurrency_sync.nim",
    "concurrency/runner_concurrency_structures.nim"
  ])

proc buildCompileCmd*(
  testPath: string,
  mm: string = "orc",
  backend: string = "c",
  cc: string = "",
  nimcacheDir: string = "",
  isRelease: bool = false,
  isDanger: bool = false,
  workerSlot: int = 0,
  isBundled: bool = false
): seq[string] =
  result = @[
    if backend == "cpp": "cpp" else: "c",
    "--mm:" & mm,
    "--threads:on",
    if isBundled: "--parallelBuild:2" else: "--parallelBuild:1",
    "--path:src",
    "-d:testing",
    "--verbosity:0",
    "--hints:off",
    "--warnings:off"
  ]
  if cc.len > 0:
    result.add("--cc:" & cc)
  let optFlag = if cc == "vcc": "--opt:none" else: "--opt:speed"
  if isDanger:
    result.add("-d:danger")
    result.add("-u:debug")
    result.add(optFlag)
    result.add("--debugger:off")
    result.add("--debuginfo:off")
  elif isRelease:
    result.add("-d:release")
    result.add("-u:debug")
    result.add(optFlag)
    result.add("--assertions:on")
    result.add("--debugger:off")
    result.add("--debuginfo:off")

  let effNimcacheDir =
    if nimcacheDir.len > 0:
      nimcacheDir
    else:
      getHomeDir() / ".cache" / "nim" / ("test_runner_" & mm & "_" & backend & (if cc.len > 0: "_" & cc else: ""))
  let testBase = testPath.extractFilename().changeFileExt("")
  let perWorkerNimcache = effNimcacheDir / ("worker_" & $workerSlot)
  let outBin = perWorkerNimcache / (testBase & (when defined(windows): ".exe" else: ""))
  result.add("--nimcache:" & perWorkerNimcache)
  result.add("--out:" & outBin)
  if cc == "vcc":
    result.add("--passC:/Fd:" & (perWorkerNimcache / "vc140.pdb"))
  result.add("-r")
  result.add(testPath)

proc resolveBundledMode*(
  directFilesCount: int,
  filterSubstr: string,
  bundledFlag: bool = false,
  unbundledFlag: bool = false
): bool =
  if directFilesCount > 0 or filterSubstr.len > 0 or unbundledFlag:
    return false
  return true

proc runParallel(
  tests: seq[string],
  maxWorkers: int,
  mm: string = "orc",
  backend: string = "c",
  cc: string = "",
  nimcacheDir: string = "",
  isRelease: bool = false,
  isDanger: bool = false,
  timeoutSec: float = 300.0,
  isBundled: bool = false
): int =
  var running: seq[RunningProcess] = @[]
  var results: seq[TestResult] = @[]
  var freeSlots: seq[int] = @[]
  for slot in countdown(max(1, maxWorkers) - 1, 0):
    freeSlots.add(slot)
  let total = tests.len
  var nextIdx = 0
  var completed = 0

  let startTime = epochTime()

  while nextIdx < total or running.len > 0:
    # Fill worker pool
    while running.len < maxWorkers and nextIdx < total and freeSlots.len > 0:
      let testPath = tests[nextIdx]
      let workerSlot = freeSlots.pop()
      inc nextIdx
      let t0 = epochTime()
      let cmd = "nim"
      let args = buildCompileCmd(
        testPath = testPath,
        mm = mm,
        backend = backend,
        cc = cc,
        nimcacheDir = nimcacheDir,
        isRelease = isRelease,
        isDanger = isDanger,
        workerSlot = workerSlot,
        isBundled = isBundled
      )

      let p = startProcess(cmd, args = args, options = {poStdErrToStdOut, poUsePath})
      when defined(posix):
        let fd = p.outputHandle.cint
        let flags = fcntl(fd, F_GETFL, 0)
        discard fcntl(fd, F_SETFL, flags or O_NONBLOCK)

      running.add(RunningProcess(path: testPath, p: p, t0: t0, output: "", workerSlot: workerSlot))

    # Poll running processes and drain pipes continuously to prevent deadlocks
    var i = 0
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
        running[i].output.add("\n[TIMEOUT] Test exceeded " & $int(timeoutSec) & "s watchdog limit and was terminated.\n")

      if code != -1:
        drainProcessOutput(running[i])
        let testPath = running[i].path
        let outStr = running[i].output
        let finishedSlot = running[i].workerSlot
        running[i].p.close()
        running.delete(i)
        freeSlots.add(finishedSlot)
        inc completed
        let res = TestResult(path: testPath, duration: dur, exitCode: code, output: outStr)
        results.add(res)

        let relName = testPath.extractFilename()
        if code == 0:
          styledWriteLine(stdout, fgGreen, "  [PASS] ", fgDefault, relName, " (", dur.formatFloat(ffDecimal, 2), "s) [", $completed, "/", $total, "]")
          flushFile(stdout)
        else:
          styledWriteLine(stdout, fgRed, "  [FAIL] ", fgDefault, relName, " (exit ", $code, ")")
          echo outStr
          flushFile(stdout)
      else:
        inc i

    sleep(5)

  let totalDuration = epochTime() - startTime
  var failedCount = 0
  for r in results:
    if r.exitCode != 0:
      inc failedCount

  echo ""
  styledWriteLine(stdout, styleBright, "==================================================")
  if failedCount == 0:
    styledWriteLine(stdout, fgGreen, styleBright, "All ", $total, " test suites passed in ", totalDuration.formatFloat(ffDecimal, 2), "s!")
  else:
    styledWriteLine(stdout, fgRed, styleBright, $failedCount, " of ", $total, " test suites failed in ", totalDuration.formatFloat(ffDecimal, 2), "s!")
  styledWriteLine(stdout, styleBright, "==================================================")
  flushFile(stdout)

  return if failedCount == 0: 0 else: 1

when isMainModule:
  var runUnit = false
  var runConcurrency = false
  var runQueues = false
  var runStructures = false
  var runSync = false
  var runPrimitives = false
  var filterSubstr = ""
  var directFiles: seq[string] = @[]

  var workers = countProcessors()
  var workersExplicit = false
  var mm = "orc"
  var backend = "c"
  var cc = getEnv("LFQ_CC", "")
  var nimcacheDir = ""
  var isRelease = false
  var isDanger = false
  var bundledFlag = false
  var unbundledFlag = false
  var timeoutSec = 300.0
  let envTimeout = getEnv("LFQ_TEST_TIMEOUT_SEC", "")
  if envTimeout.len > 0:
    try:
      timeoutSec = parseFloat(envTimeout)
    except ValueError:
      discard

  for param in commandLineParams():
    if param == "--concurrency" or param == "-c":
      runConcurrency = true
    elif param == "--all" or param == "-a":
      runUnit = true
      runConcurrency = true
    elif param == "--unit" or param == "-u":
      runUnit = true
    elif param == "--queues" or param == "-q":
      runQueues = true
    elif param == "--structures" or param == "-s":
      runStructures = true
    elif param == "--sync":
      runSync = true
    elif param == "--primitives" or param == "-p":
      runPrimitives = true
    elif param == "--bundled" or param == "-b":
      bundledFlag = true
    elif param == "--no-bundled" or param == "--unbundled":
      unbundledFlag = true
    elif param == "--release" or param == "-d:release":
      isRelease = true
    elif param == "--danger" or param == "-d:danger":
      isDanger = true
    elif param == "--cpp":
      backend = "cpp"
    elif param.startsWith("--cc:"):
      cc = param.split(":")[1]
    elif param.startsWith("--mm:"):
      mm = param.split(":")[1]
    elif param.startsWith("--backend:"):
      backend = param.split(":")[1]
    elif param.startsWith("--workers:"):
      workers = parseInt(param.split(":")[1])
      workersExplicit = true
    elif param.startsWith("--timeout:"):
      timeoutSec = parseFloat(param.split(":")[1])
    elif param.startsWith("--nimcache:"):
      nimcacheDir = param.split(":")[1]
    elif param.startsWith("--filter:") or param.startsWith("-f:"):
      filterSubstr = param.split(":")[1]
    elif fileExists(param):
      directFiles.add(param.absolutePath())

  let useBundled = resolveBundledMode(
    directFilesCount = directFiles.len,
    filterSubstr = filterSubstr,
    bundledFlag = bundledFlag,
    unbundledFlag = unbundledFlag
  )
  if useBundled and not workersExplicit:
    workers = max(1, (countProcessors() * 3) div 4)

  var tests: seq[string] = @[]
  if directFiles.len > 0:
    tests = directFiles
  elif useBundled:
    if runQueues: tests.add(findQueueBundles())
    if runStructures: tests.add(findStructureBundles())
    if runSync: tests.add(findSyncBundles())
    if runPrimitives: tests.add(resolveTestPaths(["unit/runner_primitives.nim"]))
    if runConcurrency: tests.add(findConcurrencyBundles())
    if runUnit or (not runQueues and not runStructures and not runSync and not runPrimitives and not runConcurrency):
      tests.add(findUnitBundles())
  else:
    if runQueues: tests.add(findQueueTests())
    if runStructures: tests.add(findStructureTests())
    if runSync: tests.add(findSyncTests())
    if runPrimitives: tests.add(findPrimitiveTests())
    if runConcurrency: tests.add(findConcurrencyTests())
    if runUnit or (not runQueues and not runStructures and not runSync and not runPrimitives and not runConcurrency):
      tests.add(findUnitTests())

  if filterSubstr.len > 0:
    var filtered: seq[string] = @[]
    for t in tests:
      if filterSubstr.toLowerAscii() in t.toLowerAscii():
        filtered.add(t)
    tests = filtered

  # Deduplicate tests while preserving order
  var uniqueTests: seq[string] = @[]
  for t in tests:
    if t notin uniqueTests:
      uniqueTests.add(t)

  if uniqueTests.len == 0:
    echo "No matching tests found."
    quit(0)

  let optLabel = if isDanger: ", Danger" elif isRelease: ", Release" else: ", Debug"
  let ccLabel = if cc.len > 0: ", CC: " & cc else: ""
  let modeLabel = if useBundled: ", Bundled" else: ""
  echo "Running ", uniqueTests.len, " test suites across ", workers, " worker threads [MM: ", mm, ", Backend: ", backend, ccLabel, optLabel, modeLabel, "]..."
  flushFile(stdout)
  let code = runParallel(uniqueTests, workers, mm = mm, backend = backend, cc = cc, nimcacheDir = nimcacheDir, isRelease = isRelease, isDanger = isDanger, timeoutSec = timeoutSec, isBundled = useBundled)
  quit(code)
