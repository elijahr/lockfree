---
name: Feature Request
about: Suggest an idea or architectural improvement for lockfree
title: '[FEAT] '
labels: enhancement
assignees: ''
---

**Problem or Use Case**
Is your feature request related to a problem or performance bottleneck? Please describe.

**Proposed Solution**
Describe the proposed primitive, queue topology, or API ergonomics.

**Concurrency & Safety Considerations**
- Expected progress guarantee (wait-free, lock-free, obstruction-free)
- ABA and memory reclamation implications (does it need NEBR?)
- Memory manager interactions (`orc` / `arc` / Path-C tokenization)

**Alternatives Considered**
A clear and concise description of any alternative solutions or features you've considered.

**Additional Context**
Add any other context, benchmarks, or academic paper references here.
