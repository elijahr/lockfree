---
name: Bug Report
about: Create a report to help us reproduce and fix an issue
title: '[BUG] '
labels: bug
assignees: ''
---

**Describe the Bug**
A clear and concise description of what the bug is.

**Queue Topology & Configuration**
- Queue Type (e.g. `BQueue`, `Queue`, `Channel`, C ABI `lfq_queue_t`)
- Cardinality (e.g. SPSC, MPSC, SPMC, MPMC)
- Payload Type `T` (e.g. `int`, `ref MyObj`, `string`, `ptr Data`)
- Capacity / Segment Size:

**Environment & Setup**
- OS: [e.g. Linux x86_64, macOS Apple Silicon, Windows]
- Nim Version: [e.g. 2.2.10]
- Memory Manager: [e.g. `--mm:orc`, `--mm:arc`, `--mm:atomicArc`, `--mm:refc`]
- Backend: [e.g. C, C++]
- Compiler Flags: [e.g. `-d:release`, `--threads:on`]

**To Reproduce**
Steps or a minimal reproducible code snippet (`repro.nim`):
```nim
import lockfree

# Minimal reproducer
```

**Expected Behavior**
A clear and concise description of what you expected to happen.

**Actual Behavior & Stack Trace / Sanitizer Output**
If running with ThreadSanitizer or AddressSanitizer, please paste the sanitizer report.
