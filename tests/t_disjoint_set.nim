import unittest2
import ../src/lockfree
import ../src/lockfree/disjoint_set
import ../src/lockfree/atomics
import ../src/lockfree/atomics/backoff

suite "DisjointSet (Wait-Free / Lock-Free Concurrent Union-Find / DSU)":
  test "Single-threaded initialization, singleton invariants, and negative controls":
    # Empty DisjointSet edge case
    var emptyDs = initDisjointSet(0)
    check emptyDs.len == 0
    check emptyDs.size == 0
    check emptyDs.numSets == 0

    # Negative control: negative size raises ValueError
    var raisedNegative = false
    try:
      discard initDisjointSet(-1)
    except ValueError:
      raisedNegative = true
    check raisedNegative == true

    # Initialize 16-element DisjointSet
    var ds = newDisjointSet(16)
    check ds.len == 16
    check ds.size == 16
    check ds.numSets == 16

    for i in 0 ..< 16:
      check ds.find(i) == i
      check ds.findNoCompress(i) == i
      check ds.isRoot(i) == true
      check ds.rank(i) == 0'u32
      check ds.sameSet(i, i) == true
      check ds.connected(i, i) == true
      for j in 0 ..< 16:
        if i != j:
          check ds.sameSet(i, j) == false
          check ds.connected(i, j) == false

    # Negative controls: out-of-bounds indices raise IndexDefect
    var raisedLow = false
    try:
      discard ds.find(-1)
    except IndexDefect:
      raisedLow = true
    check raisedLow == true

    var raisedHigh = false
    try:
      discard ds.find(16)
    except IndexDefect:
      raisedHigh = true
    check raisedHigh == true

    var raisedUnionOob = false
    try:
      discard ds.union(0, 16)
    except IndexDefect:
      raisedUnionOob = true
    check raisedUnionOob == true

    var raisedSameSetOob = false
    try:
      discard ds.sameSet(-1, 5)
    except IndexDefect:
      raisedSameSetOob = true
    check raisedSameSetOob == true

  test "Rank-based linking, deterministic index tie-breaking, and idempotent unions":
    var ds = initDisjointSet(10)

    # Equal-rank union (0, 1): smaller index 0 links under larger index 1, rank(1) becomes 1
    var root01 = -1
    check ds.tryUnion(0, 1, root01) == true
    check root01 == 1
    check ds.find(0) == 1
    check ds.find(1) == 1
    check ds.isRoot(0) == false
    check ds.isRoot(1) == true
    check ds.rank(1) == 1'u32
    check ds.numSets == 9
    check ds.sameSet(0, 1) == true

    # Idempotent union on already-connected elements returns false and preserves numSets
    check ds.union(0, 1) == false
    check ds.union(1, 0) == false
    check ds.union(0, 0) == false
    check ds.numSets == 9

    # Union lower-rank singleton (2, rank 0) with higher-rank root (1, rank 1):
    # 2 links under 1 without incrementing rank(1)
    check ds.union(2, 0) == true
    check ds.find(2) == 1
    check ds.rank(1) == 1'u32
    check ds.numSets == 8
    check ds.sameSet(0, 2) == true
    check ds.sameSet(1, 2) == true
    check ds.sameSet(2, 3) == false

    # Build a second rank-1 tree (3, 4) -> root 4 (rank 1), then merge with (1, rank 1) -> root 4 (rank 2)
    check ds.union(3, 4) == true
    check ds.find(3) == 4
    check ds.rank(4) == 1'u32
    check ds.numSets == 7

    check ds.union(0, 3) == true
    check ds.find(0) == 4
    check ds.find(2) == 4
    check ds.rank(4) == 2'u32
    check ds.numSets == 6

    for a in 0 .. 4:
      for b in 0 .. 4:
        check ds.sameSet(a, b) == true
      for c in 5 .. 9:
        check ds.sameSet(a, c) == false

  test "Path splitting compression, clear reuse, ARC/ORC copy/sink, and ptr overloads":
    var ds = initDisjointSet(64)

    # Construct a balanced binary union tree of depth 6 over 64 elements
    var step = 1
    while step < 64:
      var i = 0
      while i < 64:
        check ds.union(i, i + step) == true
        i += step * 2
      step *= 2

    check ds.numSets == 1
    # Root of 0..63 under min->max tie-breaking is element 63 with rank 6
    check ds.findNoCompress(0) == 63
    check ds.rank(63) == 6'u32

    # Repeatedly call find(0) to exercise path splitting all the way to root 63
    for _ in 0 ..< 6:
      check ds.find(0) == 63

    # Verify pointer overloads and ARC/ORC value copy sharing the same core
    var dsCopy = ds
    let pDs = addr ds
    check pDs.len == 64
    check pDs.numSets == 1
    check pDs.sameSet(0, 63) == true
    check dsCopy.find(31) == 63

    # Clear via copy handle and verify both handles observe the reset singleton state
    dsCopy.clear()
    check ds.numSets == 64
    check pDs.numSets == 64
    for i in 0 ..< 64:
      check ds.isRoot(i) == true
      check ds.rank(i) == 0'u32
    check ds.sameSet(0, 63) == false

  when compileOption("threads"):
    test "8-thread high-contention component merging and merge-count conservation":
      const
        NumThreads = 8
        NumComponents = 64
        ComponentSize = 64
        TotalElements = NumComponents * ComponentSize # 4096

      type
        MergeWorkerCtx = object
          ds: ptr DisjointSet
          tid: int
          mergedCount: ptr Atomic[int]

      var ds = initDisjointSet(TotalElements)
      var totalMerged: Atomic[int]
      totalMerged.store(0, moRelaxed)

      proc mergeWorker(ctx: MergeWorkerCtx) {.thread.} =
        var localMerged = 0
        # Pass 1: Strided overlapping pairs within each component
        for comp in 0 ..< NumComponents:
          let base = comp * ComponentSize
          for offset in 0 ..< ComponentSize - 1:
            let idx = (offset + ctx.tid * 7) mod (ComponentSize - 1)
            let u = base + idx
            let v = base + idx + 1
            if ctx.ds.union(u, v):
              inc localMerged
            # Also exercise diagonal/star links within the same component
            let starTarget = base + ((idx * 13 + ctx.tid) mod ComponentSize)
            if ctx.ds.union(u, starTarget):
              inc localMerged
        discard ctx.mergedCount[].fetchAdd(localMerged, moAcquireRelease)

      var threads: array[NumThreads, Thread[MergeWorkerCtx]]
      for t in 0 ..< NumThreads:
        createThread(
          threads[t],
          mergeWorker,
          MergeWorkerCtx(
            ds: addr ds,
            tid: t,
            mergedCount: addr totalMerged
          )
        )
      for t in 0 ..< NumThreads:
        joinThread(threads[t])

      # Exact conservation invariant: each of the 64 components of size 64
      # requires exactly 63 successful merges (64 * 63 = 4032 total merges)
      check totalMerged.load(moAcquire) == TotalElements - NumComponents
      check ds.numSets == NumComponents

      # Verify intra-component connectivity and inter-component isolation
      for comp in 0 ..< NumComponents:
        let base = comp * ComponentSize
        let rep = ds.find(base)
        check ds.isRoot(rep) == true
        for i in 1 ..< ComponentSize:
          check ds.find(base + i) == rep
          check ds.sameSet(base, base + i) == true
        if comp + 1 < NumComponents:
          let nextBase = (comp + 1) * ComponentSize
          check ds.sameSet(base, nextBase) == false

    test "8-thread parallel dependency-graph cycle detection & Kruskal spanning forest":
      const
        NumThreads = 8
        NumSubgraphs = 16
        VerticesPerSubgraph = 64
        TotalVertices = NumSubgraphs * VerticesPerSubgraph # 1024
        TreeEdgesPerSubgraph = VerticesPerSubgraph - 1     # 63
        BackEdgesPerSubgraph = VerticesPerSubgraph         # 64
        EdgesPerSubgraph = TreeEdgesPerSubgraph + BackEdgesPerSubgraph # 127
        TotalEdges = NumSubgraphs * EdgesPerSubgraph       # 2032

      type
        GraphEdge = object
          u: int32
          v: int32

        CycleWorkerCtx = object
          ds: ptr DisjointSet
          edges: ptr array[TotalEdges, GraphEdge]
          cursor: ptr Atomic[int]
          treeEdgeCount: ptr Atomic[int]
          cycleEdgeCount: ptr Atomic[int]

      var edges: array[TotalEdges, GraphEdge]
      var edgeIdx = 0
      for sg in 0 ..< NumSubgraphs:
        let base = sg * VerticesPerSubgraph
        # 63 spanning tree edges forming a connected tree over the subgraph
        for i in 0 ..< TreeEdgesPerSubgraph:
          edges[edgeIdx] = GraphEdge(u: int32(base + i), v: int32(base + i + 1))
          inc edgeIdx
        # 64 cycle-forming chords / back-edges within the same subgraph
        for i in 0 ..< BackEdgesPerSubgraph:
          let u = base + i
          let v = base + ((i + 17) mod VerticesPerSubgraph)
          edges[edgeIdx] = GraphEdge(u: int32(u), v: int32(v))
          inc edgeIdx
      check edgeIdx == TotalEdges

      var ds = initDisjointSet(TotalVertices)
      var cursor: Atomic[int]
      var treeEdgeCount: Atomic[int]
      var cycleEdgeCount: Atomic[int]
      cursor.store(0, moRelaxed)
      treeEdgeCount.store(0, moRelaxed)
      cycleEdgeCount.store(0, moRelaxed)

      proc cycleWorker(ctx: CycleWorkerCtx) {.thread.} =
        var localTree = 0
        var localCycle = 0
        while true:
          let idx = ctx.cursor[].fetchAdd(1, moRelaxed)
          if idx >= TotalEdges:
            break
          let e = ctx.edges[idx]
          if ctx.ds.union(int(e.u), int(e.v)):
            inc localTree
          else:
            # union returned false -> u and v were already connected (cycle edge!)
            doAssert ctx.ds.sameSet(int(e.u), int(e.v))
            inc localCycle
        discard ctx.treeEdgeCount[].fetchAdd(localTree, moAcquireRelease)
        discard ctx.cycleEdgeCount[].fetchAdd(localCycle, moAcquireRelease)

      var threads: array[NumThreads, Thread[CycleWorkerCtx]]
      for t in 0 ..< NumThreads:
        createThread(
          threads[t],
          cycleWorker,
          CycleWorkerCtx(
            ds: addr ds,
            edges: addr edges,
            cursor: addr cursor,
            treeEdgeCount: addr treeEdgeCount,
            cycleEdgeCount: addr cycleEdgeCount
          )
        )
      for t in 0 ..< NumThreads:
        joinThread(threads[t])

      # Matroid / spanning forest invariant: regardless of thread scheduling,
      # exactly 16 * 63 = 1008 edges merge components and 16 * 64 = 1024 edges
      # are detected as cycles.
      check treeEdgeCount.load(moAcquire) == NumSubgraphs * TreeEdgesPerSubgraph
      check cycleEdgeCount.load(moAcquire) == NumSubgraphs * BackEdgesPerSubgraph
      check ds.numSets == NumSubgraphs

    test "Concurrent writers + linearizable sameSet readers (Anderson-Woll verification)":
      const
        NumWriters = 4
        NumReaders = 4
        PartitionSize = 256
        TotalNodes = PartitionSize * 2 # 512 (Partition A: 0..255, Partition B: 256..511)

      type
        RwWorkerCtx = object
          ds: ptr DisjointSet
          tid: int
          writersDone: ptr Atomic[int]
          falseNegatives: ptr Atomic[int]
          falsePositives: ptr Atomic[int]

      var ds = initDisjointSet(TotalNodes)
      # Pre-link pairs (2*k, 2*k+1) before spawning readers so they are guaranteed connected
      for k in 0 ..< (TotalNodes div 2):
        check ds.union(2 * k, 2 * k + 1) == true

      var writersDone: Atomic[int]
      var falseNegatives: Atomic[int]
      var falsePositives: Atomic[int]
      writersDone.store(0, moRelaxed)
      falseNegatives.store(0, moRelaxed)
      falsePositives.store(0, moRelaxed)

      proc writerProc(ctx: RwWorkerCtx) {.thread.} =
        # Writers progressively merge even elements within Partition A (0..255)
        # and separately within Partition B (256..511), never bridging A and B.
        for i in 0 ..< PartitionSize - 1:
          let idx = (i + ctx.tid * 31) mod (PartitionSize - 1)
          discard ctx.ds.union(idx, idx + 1)
          discard ctx.ds.union(PartitionSize + idx, PartitionSize + idx + 1)
        discard ctx.writersDone[].fetchAdd(1, moRelease)

      proc readerProc(ctx: RwWorkerCtx) {.thread.} =
        var iter = 0
        while ctx.writersDone[].load(moAcquire) < NumWriters or iter < 256:
          let k = (iter + ctx.tid * 19) mod (TotalNodes div 2)
          # Pre-linked pair (2*k, 2*k+1) must ALWAYS report sameSet == true
          # even while their root is being concurrently linked into larger trees!
          if not ctx.ds.sameSet(2 * k, 2 * k + 1):
            discard ctx.falseNegatives[].fetchAdd(1, moRelaxed)
          # Partition A (0..255) and Partition B (256..511) must NEVER report sameSet == true
          let a = (iter * 7 + ctx.tid) mod PartitionSize
          let b = PartitionSize + ((iter * 11 + ctx.tid) mod PartitionSize)
          if ctx.ds.sameSet(a, b):
            discard ctx.falsePositives[].fetchAdd(1, moRelaxed)
          inc iter

      var wThreads: array[NumWriters, Thread[RwWorkerCtx]]
      var rThreads: array[NumReaders, Thread[RwWorkerCtx]]
      for i in 0 ..< NumWriters:
        createThread(
          wThreads[i],
          writerProc,
          RwWorkerCtx(
            ds: addr ds,
            tid: i,
            writersDone: addr writersDone,
            falseNegatives: addr falseNegatives,
            falsePositives: addr falsePositives
          )
        )
      for i in 0 ..< NumReaders:
        createThread(
          rThreads[i],
          readerProc,
          RwWorkerCtx(
            ds: addr ds,
            tid: i,
            writersDone: addr writersDone,
            falseNegatives: addr falseNegatives,
            falsePositives: addr falsePositives
          )
        )
      for i in 0 ..< NumWriters:
        joinThread(wThreads[i])
      for i in 0 ..< NumReaders:
        joinThread(rThreads[i])

      check falseNegatives.load(moAcquire) == 0
      check falsePositives.load(moAcquire) == 0
      check ds.numSets == 2
      check ds.sameSet(0, PartitionSize - 1) == true
      check ds.sameSet(PartitionSize, TotalNodes - 1) == true
      check ds.sameSet(0, PartitionSize) == false
