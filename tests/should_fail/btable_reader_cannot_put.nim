## Compile-fail control: calling `put` on a `TableReaderTag` bound endpoint is rejected.
import lockfree

var tbl = initBTable[string, int, 16]()
withBoundReader(tbl, reader):
  discard reader.put("k", 1)
