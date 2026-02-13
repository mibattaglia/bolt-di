---
name: bolt-testing
description: Safely evolve Bolt behavior with focused tests and README updates
license: Repository-internal
metadata:
  short-description: Bolt change workflow for tests and docs
---

# Bolt Testing Workflow

## Goal
Ship behavior changes with clear tests and matching docs.

## Quick start
1. Add/adjust tests in `Tests/BoltTests` for intended behavior.
2. Implement minimal source change in `Sources/Bolt`.
3. Run `xcrun swift test`.
4. Update `README.md` when public usage changes.

## Test priorities
- Scoping semantics (`withModules`, `withContainer`, `withOverrides`, async behavior).
- Global setup behavior (`Bolt.setup`) only in explicit serialized smoke coverage.
- Module ordering and dependency graph behavior.
- Validation behavior and error kinds.
- Concurrency behavior for singleton and factory resolution.

## Command
```bash
xcrun swift test
```

## Done criteria
- New/updated tests pass.
- No unrelated refactors in same diff.
- Public API behavior reflected in README examples.
