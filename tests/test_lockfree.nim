import unittest
import lockfree

suite "lockfree":
  test "hello returns expected greeting":
    check hello() == "hello from lockfree"

  test "version present":
    check projectVersion == "0.0.1"
