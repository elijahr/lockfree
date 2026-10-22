# DisjointSet (`lockfree/disjoint_set`)

Wait-free and lock-free concurrent Disjoint-Set Union (DSU / Union-Find) data structure based on packed 64-bit atomic words, wait-free path splitting, and rank-based union.

## Overview

- **Module**: `lockfree/disjoint_set`
- **Aliases**: `UnionFind`
- **Progress**: `find` and `sameSet` are wait-free; `union` is lock-free.
- **Safety**: Fully compatible with ARC, ORC, refc, and C++ memory management models.

## API Reference

::: lockfree/disjoint_set
