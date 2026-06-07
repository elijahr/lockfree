import unittest2
import lockfree/atomics

import lockfree/smr/nebr/types
import lockfree/smr/nebr/typestates/manager

suite "Manager typestate":
  test "uninitializedManager creates ManagerUninitialized":
    var mgr: DebraManager[4, ccSingle]
    let ctx = uninitializedManager(addr mgr)
    check ctx is ManagerUninitialized[4]

  test "initialize transitions to ManagerReady":
    var mgr: DebraManager[4, ccSingle]
    let uninit = uninitializedManager(addr mgr)
    let ready = uninit.initialize()
    check ready is ManagerReady[4]
    # Verify initialization happened
    check mgr.globalEpoch.load(moRelaxed) == 1'u64

  test "shutdown transitions to ManagerShutdown":
    var mgr: DebraManager[4, ccSingle]
    let ready = uninitializedManager(addr mgr).initialize()
    let shutdown = ready.shutdown()
    check shutdown is ManagerShutdown[4]
