# Bolt Swift Testing Concurrency Parity Plan

Date: 2026-02-13
Status: Draft

## Problem
`swift-testing` runs tests concurrently by default. Bolt currently exposes a process-global mutable graph (`Bolt.shared`) and `Bolt.setup(modules:)` mutates that global graph. Tests that call `Bolt.setup` can race and cause cross-test contamination.

Observed failure mode:
- Test A sets up graph X.
- Test B concurrently sets up graph Y.
- Test A resolves from Y and fails with missing registration/type mismatch.

## Goal
Reach practical parity with `swift-dependencies` in concurrent Swift Testing:
- Deterministic test behavior under default parallel test execution.
- No cross-test graph contamination for recommended test patterns.
- Clear, explicit testing APIs and guidance.

## Non-goals
- Removing `Bolt.setup` from production API.
- Introducing hidden magic that silently changes production runtime semantics.

## Design Principles
- Keep runtime behavior explicit.
- Make the safe path easy and the unsafe path obvious.
- Prefer task-local scoping for tests over global mutation.

## Proposed Mitigation Plan

### Phase 1: Testing API for graph isolation
1. Add `Bolt.withModules(_ modules: [DependencyModule], _ body: () throws -> R)` and async variant.
2. Implementation:
   - Build isolated `Container` from modules using shared planner path (`planGraph`).
   - Execute body using `Bolt.withContainer`.
3. Guarantee:
   - No writes to global `Bolt.shared`.
   - Full lexical + task-local isolation.

Acceptance:
- New API compiles and reuses existing setup/planner semantics.
- Existing behavior of `Bolt.setup` unchanged.

### Phase 2: Harden tests against global mutation races
1. Migrate tests that currently use `Bolt.setup` to `Bolt.withModules` where possible.
2. Keep only explicit `Bolt.setup` smoke tests for global wiring behavior.
3. Mark any remaining global-state tests as serialized.

Acceptance:
- Repeated `swift test` runs under parallel execution are stable.
- No flakes from missing registrations caused by cross-test graph replacement.

### Phase 3: Explicit global test guardrails
1. Add debug-only detection for suspicious `Bolt.setup` usage during tests:
   - If multiple concurrent `setup` calls occur, emit diagnostic/fatal message in debug tests.
2. Message should point users to `Bolt.withModules` for test isolation.

Acceptance:
- Clear failure mode for unsafe concurrent global setup in tests.
- No impact on release production behavior.

### Phase 4: Documentation parity track
1. Update `README.md` testing section:
   - Prefer `withModules`/`withContainer` for test graph setup.
   - Treat `Bolt.setup` as app bootstrap API, not per-test setup API.
2. Update `specs/BOLT_DI_SPEC.md` with concurrency-safe testing guidance.

Acceptance:
- Public docs reflect concurrency-safe test practices and API.

## Validation Matrix
1. Stress test: concurrent test tasks each building distinct module graphs and resolving distinct named services.
2. Nested override test: `withModules` + nested `withOverrides` across async boundaries.
3. Regression test: `Bolt.setup` still configures global app graph as before.
4. Repeatability gate: run test suite repeatedly (e.g., 20x loop) with zero cross-test contamination failures.

## Success Criteria (Parity Bar)
- Default `swift-testing` parallel execution passes consistently with no global graph flakes in migrated tests.
- Developers can write isolated tests without touching global state.
- Bolt testing ergonomics are on par with `swift-dependencies` task-local model for test isolation.

## Open Questions
1. Should `Bolt.withModules` be public API or test-only (`@_spi(Testing)`) initially?
2. Should debug guardrails be warning-only or hard-fail in test environments?
3. Do we enforce serialization automatically for tests that call `Bolt.setup`, or document it only?
