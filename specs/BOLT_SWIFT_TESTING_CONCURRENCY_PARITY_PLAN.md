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
Status: Complete (2026-02-13)

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
Status: Complete (2026-02-13)

1. Migrate tests that currently use `Bolt.setup` to `Bolt.withModules` where possible.
2. Keep only explicit `Bolt.setup` smoke tests for global wiring behavior.
3. Mark any remaining global-state tests as serialized.

Acceptance:
- Repeated `swift test` runs under parallel execution are stable.
- No flakes from missing registrations caused by cross-test graph replacement.

### Phase 3: Explicit global test guardrails
Status: Complete (2026-02-13)

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

## Agent Runbook (Implementation Guide)

Use this runbook for an implementation-focused agent pass. Keep diffs minimal and behavior explicit.

### Preconditions
1. Read: `README.md`, `specs/BOLT_DI_SPEC.md`, this plan.
2. Confirm baseline status:
   - `swift test`
3. Identify current API/implementation locations:
   - `Sources/Bolt` for `Bolt`, `Container`, and planning/setup paths.
   - `Tests/BoltTests` for existing setup/scoping tests.

### Step 1: Add `withModules` API
1. Add sync + async `Bolt.withModules` entry points mirroring existing `withContainer` style.
2. Reuse the same module planning/build path used by `Bolt.setup(modules:)` (single source of truth).
3. Execute body through `Bolt.withContainer` using the isolated container.
4. Preserve current crash-on-failure semantics for resolution APIs.

Definition of done:
- `withModules` compiles and is callable from tests.
- Implementation does not mutate `Bolt.shared`.

### Step 2: Add behavior tests for isolation
1. Add tests that run concurrent tasks, each with distinct `withModules` graphs, and assert no cross-talk.
2. Add nested scope test: `withModules` + nested `withOverrides` across async boundaries.
3. Add regression test proving `Bolt.setup(modules:)` still sets global bootstrap graph.

Definition of done:
- New tests fail without `withModules` behavior in place (when practical).
- New tests pass with implementation.

### Step 3: Migrate existing tests off global setup
1. Replace per-test `Bolt.setup` usage with `Bolt.withModules` where behavior intent is scoped resolution.
2. Keep only explicit global-state smoke coverage for `Bolt.setup`.
3. Mark remaining global-state tests as serialized (explicitly, no hidden auto-serialization).

Definition of done:
- Parallel `swift-testing` runs are stable.
- Global mutation tests are isolated and intentional.

### Step 4: Add debug-only guardrails for unsafe concurrent setup
1. Add debug/test-environment detection around concurrent `Bolt.setup` calls.
2. On overlap, emit a clear hard failure/diagnostic pointing to `Bolt.withModules`.
3. Ensure release behavior is unchanged.

Definition of done:
- Unsafe concurrent `setup` has an immediate, actionable failure mode in debug tests.
- No production behavior change.

### Step 5: Documentation updates
1. Update `README.md` testing guidance:
   - Prefer `withModules`/`withContainer` for tests.
   - Reserve `Bolt.setup` for app bootstrap.
2. Update `specs/BOLT_DI_SPEC.md` with concurrency-safe testing semantics.

Definition of done:
- Public docs match implemented behavior and recommended usage.

### Verification Checklist
1. Run:
   - `swift test`
2. Run repeatability gate:
   - `for i in {1..20}; do swift test >/tmp/bolt-test-$i.log || break; done`
3. If failures occur, capture first failing log and classify:
   - cross-test contamination
   - async scope leak
   - unrelated pre-existing failure

### Constraints and Guardrails
1. Do not change production semantics of `Bolt.setup` beyond debug-only misuse detection.
2. Do not introduce hidden global mutable override state.
3. Keep module ordering deterministic and preserve transitive `dependentModules` behavior.
4. Keep APIs explicit; avoid over-engineered test mode layers.

### Suggested Commit Slices
1. `Add Bolt.withModules sync/async scoped graph APIs`
2. `Migrate tests to withModules and isolate global setup smoke tests`
3. `Add debug concurrent setup guardrails for tests`
4. `Document concurrency-safe testing guidance`
