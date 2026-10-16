## Wrapper entrypoint forwarding to `benchmarks/nim/bench_flat_combiner.nim`.
import ./nim/bench_flat_combiner

when isMainModule:
  main()
