import unittest2
import typestates

import lockfree/atomics
import lockfree/typestates/cas

suite "CAS typestate transitions":
  test "a pending attempt publishes its desired value":
    var atom: Atomic[int]
    atom.store(7, moRelaxed)
    var succeeded = false

    # Weak CAS may fail spuriously, so each retry prepares a fresh attempt.
    for retry in 0 ..< 100:
      let pending = prepareCAS(addr atom, 7, 11)
      check pending.expectedVal == 7
      check pending.desiredVal == 11
      var outcome = executeCAS(pending)
      match outcome:
        CASSucceeded(value):
          check value.newVal == 11
          succeeded = true
        CASFailed(value):
          check value.actualVal == 7
      if succeeded:
        break

    check succeeded
    check atom.load(moRelaxed) == 11

  test "a mismatched attempt reports the observed value without writing":
    var atom: Atomic[int]
    atom.store(7, moRelaxed)
    var outcome = executeCAS(prepareCAS(addr atom, 6, 11))
    match outcome:
      CASSucceeded(_):
        check false
      CASFailed(value):
        check value.actualVal == 7
    check atom.load(moRelaxed) == 7
