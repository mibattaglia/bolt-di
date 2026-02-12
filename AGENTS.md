# AGENTS.md

## Purpose
Guidance for coding agents working in `swift-bolt`.

## Core Principles
- Keep Bolt lightweight and explicit; avoid hidden magic.
- Prefer clear runtime behavior over complex abstractions.
- Preserve source compatibility unless asked to break API.

## Repository Structure
- Source: `Sources/Bolt`
- Tests: `Tests/BoltTests`
- Primary docs: `README.md`, `BOLT_DI_SPEC.md`

## DI Model (Current)
- Scopes: `Factory`, `Singleton`, `FactoryWithParams`.
- `SingletonWithParams` is intentionally removed.
- `Bolt.inject` / `Container.get` are crash-on-failure APIs.
- `withContainer` swaps the full graph lexically/task-locally.
- `withOverrides` patches selected registrations lexically/task-locally.

## Validator Expectations
- Use `BoltValidator(modules:)` or `BoltValidator.validate(module:_:)`.
- Validator is module-centric and non-throwing via callback.
- Keep validator API simple; avoid over-engineered modes unless requested.

## Module Graph Rules
- Respect `DependencyModule.dependentModules` transitively.
- Module ordering must be deterministic.
- Avoid behavior that silently drops distinct module instances.

## Concurrency & Safety
- Assume concurrent resolution can happen.
- Maintain task-local scoping semantics.
- Avoid global mutable override state that leaks across tasks.

## Editing Rules
- Make focused, minimal diffs.
- Update tests for behavior changes.
- Update README when public API or usage semantics change.
- Do not add unrelated refactors in the same change.

## Verification
- Run `swift test` after code changes.
- If tests are added/changed, ensure they fail before fix when practical.
- Keep test names behavior-oriented and specific.

## Commit Guidance
- Use imperative commit messages.
- Group logically related changes per commit.
- Do not push unless explicitly asked.

## When Unsure
- Prefer the simplest design that matches README + tests.
- Ask for clarification before introducing new public surface area.
