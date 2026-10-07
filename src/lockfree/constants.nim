## Constants for DEBRA+ implementation.

const
  DefaultMaxThreads* = 64 ## Default maximum number of threads that can be registered.

  DefaultCacheLineBytes* = when (defined(macosx) and defined(arm64)) or defined(powerpc): 128 else: 64
  CacheLineBytes* {.intdefine.}: int = DefaultCacheLineBytes
    ## Cache line size for alignment to prevent false sharing. Defaults to
    ## 128 on Apple Silicon (macOS ARM64) and PowerPC, and 64 on x86_64 and standard AArch64.
    ## Override with `-d:CacheLineBytes=64` or `-d:CacheLineBytes=128`.

when defined(windows):
  # Windows has no analog of SIGUSR1; the neutralization protocol uses
  # SuspendThread/ResumeThread directly (see `thread_id.nim` and
  # `signal.nim` for the Windows arm of the protocol). `QuiescentSignal`
  # is retained as a compile-time-only stub so call sites that pass it
  # to platform-neutral helpers compile, but it has no signal-delivery
  # meaning on Windows.
  const QuiescentSignal*: cint = 0
    ## Windows stub — see module comment. Not a real signal number.
else:
  import std/posix
  let QuiescentSignal* = SIGUSR1 ## POSIX signal used for thread neutralization.
