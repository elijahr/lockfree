## SignalHandler typestate.
##
## Ensures signal handler is installed before DEBRA operations.
##
## The `install` transition delegates to the production
## `signal.installSignalHandler` (the single source of truth for the SIGUSR1
## neutralization handler), so driving this typestate installs the *real*
## handler rather than a placeholder. On Windows `installSignalHandler` is
## itself a no-op because the neutralization protocol uses
## SuspendThread/ResumeThread directly; the typestate transition is retained for
## API parity so callers compile unchanged.

import typestates

import ../signal

type
  SignalHandlerContext* = object of RootObj
    installed: bool

  HandlerUninstalled* = distinct SignalHandlerContext
  HandlerInstalled* = distinct SignalHandlerContext

typestate SignalHandlerContext:
  inheritsFromRootObj = true
  opaqueStates = true
  states HandlerUninstalled, HandlerInstalled
  initial:
    HandlerUninstalled
  terminal:
    HandlerInstalled
  transitions:
    HandlerUninstalled -> HandlerInstalled

proc initSignalHandler*(): HandlerUninstalled =
  ## Create uninstalled signal handler context.
  HandlerUninstalled(SignalHandlerContext(installed: false))

proc install*(h: sink HandlerUninstalled): HandlerInstalled {.transition.} =
  ## Install SIGUSR1 handler for DEBRA+ neutralization.
  ##
  ## Delegates to the production `signal.installSignalHandler` so this typestate
  ## installs the real neutralization handler (idempotent and thread-safe). On
  ## Windows `installSignalHandler` is a no-op (no async handler is needed); the
  ## transition still flips `installed = true` for API parity.
  installSignalHandler()
  result = HandlerInstalled(SignalHandlerContext(installed: true))

func isInstalled*(h: HandlerInstalled): bool {.notATransition.} =
  ## Check if handler is installed.
  h.SignalHandlerContext.installed
