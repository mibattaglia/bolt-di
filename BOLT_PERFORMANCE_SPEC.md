# Bolt Performance Optimization Spec (v0.2)

Date: 2026-02-12
Status: Draft (Updated)
Owner: Bolt maintainers

## Intent
Make Bolt fast enough to compete directly with reference libraries, while keeping implementation understandable and maintainable.

This is a middle-ground strategy:
- Obsess over measured speed.
- Avoid over-engineered internals and hard-to-manage complexity.

## Benchmark Signal (Current)
Median ns/op from 5 release runs in `Benchmarks/`:

- Factory leaf resolve:
  - WhoopDI: 208
  - Factory: 209
  - swift-dependencies: 417
  - Bolt: 583
- Factory root resolve:
  - WhoopDI: 667
  - Factory: 667
  - swift-dependencies: 1500
  - Bolt: 1750
- Singleton warm resolve:
  - WhoopDI: 334
  - swift-dependencies: 834
  - Bolt: 1042
  - Factory: 1083
- Override/scope:
  - WhoopDI local inject: 959
  - swift-dependencies override scope: 1583
  - Factory override scope: 1667
  - Bolt override scope: 2958

## Guiding Principles
1. Benchmark first, optimize second.
2. Prefer simple internal changes with clear impact.
3. Keep a single resolver model (no fragmented engines).
4. Preserve external API and behavior unless explicitly approved.
5. Stop optimizing when complexity exceeds measurable gain.

## Goals
- Improve Bolt’s core hot paths materially.
- Close major gaps vs references in factory/root/singleton/override benchmarks.
- Keep internal architecture straightforward for long-term maintenance.

## Non-goals
- Chasing every microbenchmark at any complexity cost.
- Large-scale rewrite of DI architecture.
- Compile-time DI or macro-driven registration.

## Scope
This spec covers implementation-level performance work in:
- `Container` resolution paths
- singleton caching and synchronization
- scoped override setup and lookup
- benchmark reproducibility and reporting

## Proposed Changes (Pragmatic Set)

### A) Fast Path for Common Resolution
#### Why
Most calls are non-parameterized factory/singleton resolves.

#### Change
In `Container.resolve`, branch early for common case:
- no params
- known registration kind
- direct closure call

Keep generic path for parameterized/fallback behavior.

#### Complexity budget
Low. One resolver flow with conditional fast path.

### B) Cheaper Singleton Warm Path
#### Why
Warm singleton lookups still pay locking/state costs.

#### Change
Optimize for read-heavy warm path:
- minimal lock hold time
- skip extra state transitions when cached value exists
- keep correctness guarantees for first initialization under contention

#### Complexity budget
Low/medium. No exotic lock-free architecture in this phase.

### C) Lighter Override Scope Entry
#### Why
`withOverrides` is currently expensive relative to references.

#### Change
Reduce per-scope setup overhead:
- avoid heavy merge/copy work when entering overrides
- keep lexical/task-local semantics exactly the same
- keep override precedence deterministic

Implementation may use a simple overlay reference stack, but avoid a deep re-architecture.

#### Complexity budget
Medium. Prefer the smallest change that materially improves benchmark time.

### D) Hot-path Hygiene
#### Why
Small overheads accumulate in tight loops.

#### Change
- Build detailed error messages only on failure paths.
- Avoid unnecessary temporary allocations in resolution loop.
- Keep parameter/type checks but avoid repeated work in common case.

#### Complexity budget
Low.

## Explicitly Deferred (for now)
- Full lock-free singleton design.
- Multi-engine resolution architecture.
- Aggressive unsafe/unchecked tricks without clear benchmark need.

## API and Behavior Constraints
- `Container.get` / `Bolt.inject` remain crash-on-failure.
- `withContainer` and `withOverrides` remain lexical/task-local.
- Validator stays module-centric and non-crashing.
- No public API expansion required for this optimization wave.

## Rollout Plan

### Phase 1: Measure + Fast Path
- Baseline benchmark artifacts committed.
- Implement common-case fast path in resolver.
- Verify no behavior regressions.

### Phase 2: Singleton + Override Improvements
- Optimize singleton warm path.
- Reduce override scope setup overhead.
- Add/extend concurrency and scoping tests.

### Phase 3: Tightening + Re-evaluate
- Apply low-risk hot-path hygiene improvements.
- Re-run full benchmark suite and compare deltas.
- Decide if further complexity is justified.

## Success Criteria
Primary targets (median ns/op improvement vs current Bolt):
- `bolt_factory_resolve_leaf`: >= 25% improvement
- `bolt_factory_resolve_root`: >= 20% improvement
- `bolt_singleton_warm_resolve`: >= 20% improvement
- `bolt_with_overrides_scope`: >= 35% improvement

Secondary targets:
- No test regressions.
- No major increase in code complexity (subjective review by maintainers).

## Regression Policy
Any performance patch must include:
- Before/after benchmark output (same machine/session class)
- Clear note on complexity tradeoff
- Test coverage for affected behavior

Reject changes that:
- add substantial complexity with marginal gains,
- weaken correctness guarantees,
- introduce hard-to-debug concurrency behavior.

## Benchmark Process
Use `Benchmarks/` package only.

Run command:
```bash
cd Benchmarks
swift run -c release BoltBenchmarks --format json --quiet
```

For signal quality:
- run multiple times (>= 5)
- compare medians, not single-run outliers
- track results in repo for trend visibility

## Open Questions
- Should we pin all benchmark dependency versions to exact tags/commits now?
- Do we want a CI workflow to run benchmarks manually (`workflow_dispatch`) and upload artifacts?
