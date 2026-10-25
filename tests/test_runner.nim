## High-Performance Parallel Test Runner for lockfree
## Runs test files concurrently across CPU cores, bypassing monolithic AST bloat.

import std/[os, osproc, strutils, times, terminal, streams]

type
  TestResult = object
    path: string
    duration: float
    exitCode: int
    output: string

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

proc runParallel(
  tests: seq[string],
  maxWorkers: int,
  mm: string = "orc",
  backend: string = "c",
  nimcacheDir: string = ""
): int =
  var pending = tests
  var running: seq[tuple[path: string, p: Process, t0: float]] = @[]
  var results: seq[TestResult] = @[]
  let total = tests.len
  var completed = 0

  let startTime = epochTime()

  while pending.len > 0 or running.len > 0:
    # Fill worker pool
    while running.len < maxWorkers and pending.len > 0:
      let testPath = pending[0]
      pending.delete(0)
      let t0 = epochTime()
      let cmd = "nim"
      var args: seq[string] = @[
        if backend == "cpp": "cpp" else: "c",
        "--mm:" & mm,
        "--threads:on",
        "--path:src",
        "-d:testing",
        "--verbosity:0",
        "--hints:off",
        "--warnings:off"
      ]
      if nimcacheDir.len > 0:
        let testBase = testPath.extractFilename().changeFileExt("")
        args.add("--nimcache:" & (nimcacheDir / testBase))
      args.add("-r")
      args.add(testPath)

      let p = startProcess(cmd, args = args, options = {poStdErrToStdOut, poUsePath})
      running.add((testPath, p, t0))

    # Poll running processes
    var i = 0
    while i < running.len:
      let (testPath, p, t0) = running[i]
      let code = p.peekExitCode()
      if code != -1:
        let dur = epochTime() - t0
        let outStr = p.outputStream.readAll()
        p.close()
        running.delete(i)
        inc completed
        let res = TestResult(path: testPath, duration: dur, exitCode: code, output: outStr)
        results.add(res)

        let relName = testPath.extractFilename()
        if code == 0:
          styledWriteLine(stdout, fgGreen, "  [PASS] ", fgDefault, relName, " (", dur.formatFloat(ffDecimal, 2), "s) [", $completed, "/", $total, "]")
        else:
          styledWriteLine(stdout, fgRed, "  [FAIL] ", fgDefault, relName, " (exit ", $code, ")")
          echo outStr
      else:
        inc i

    sleep(10)

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
  var mm = "orc"
  var backend = "c"
  var nimcacheDir = ""

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
    elif param == "--cpp":
      backend = "cpp"
    elif param.startsWith("--mm:"):
      mm = param.split(":")[1]
    elif param.startsWith("--backend:"):
      backend = param.split(":")[1]
    elif param.startsWith("--workers:"):
      workers = parseInt(param.split(":")[1])
    elif param.startsWith("--nimcache:"):
      nimcacheDir = param.split(":")[1]
    elif param.startsWith("--filter:") or param.startsWith("-f:"):
      filterSubstr = param.split(":")[1]
    elif fileExists(param):
      directFiles.add(param.absolutePath())

  var tests: seq[string] = @[]
  if directFiles.len > 0:
    tests = directFiles
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

  echo "Running ", uniqueTests.len, " test suites across ", workers, " worker threads [MM: ", mm, ", Backend: ", backend, "]..."
  let code = runParallel(uniqueTests, workers, mm = mm, backend = backend, nimcacheDir = nimcacheDir)
  quit(code)
