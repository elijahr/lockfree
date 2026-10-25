# lockfree

[![CI](https://github.com/axiomantic/lockfree/actions/workflows/ci.yml/badge.svg)](https://github.com/axiomantic/lockfree/actions/workflows/ci.yml)

[![Docs](https://img.shields.io/badge/docs-latest-blue.svg)](https://axiomantic.github.io/lockfree/)

[![Release](https://img.shields.io/github/v/release/axiomantic/lockfree)](https://github.com/axiomantic/lockfree/releases/latest)
[![License](https://img.shields.io/github/license/axiomantic/lockfree)](LICENSE)
[![Nim](https://img.shields.io/badge/Nim-2.2%2B-yellow.svg)](https://nim-lang.org)

Production-grade project built with Axiomantic standards.

## Quick Start

```nim
import lockfree

echo hello()
```

## Development

The `justfile` is the canonical command surface for common tasks:

```bash
just setup        # Install dependencies
just test         # Run test suite
just lint         # Check formatting (nph) and nimble check
just fmt          # Auto-format codebase with nph

just docs         # Extract API docs and launch local doc server
just docs-build   # Build static production documentation

just build        # Build release artifacts
```

## Upstream Updates

This project was initialized via [Polyform](https://github.com/axiomantic/polyform). To update boilerplate, CI workflows, and tooling from upstream:

```bash
uvx copier update --trust
```
