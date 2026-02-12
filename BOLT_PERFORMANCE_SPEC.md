# Bolt Performance Optimization Spec (v0.2)

Date: 2026-02-12
Status: Draft (Updated)
Owner: Bolt maintainers

## Intent
Make Bolt fast enough to compete directly with reference libraries, while keeping implementation understandable and maintainable.

This is a middle-ground strategy:
- Obsess over measured speed.
- Avoid over-engineered internals and hard-to-manage complexity.
- Reuse proven patterns from WhoopDI, Factory, and swift-dependencies first; only diverge when benchmarks show a clear, repeatable win.

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

## Reference-Guided Strategy
We are not inventing a novel DI runtime. We are taking the best internal patterns from strong reference libraries and adapting them to Bolt's API/behavior constraints.

Reuse targets:
- WhoopDI: straightforward singleton warm/cold behavior with low synchronization overhead.
- Factory: deterministic scoped override mechanics and practical state management.
- swift-dependencies: lexical/task-local override scoping model and reproducible override semantics.

Improve only where Bolt-specific benchmarks demonstrate clear gains.

## Measurement-First Rule (No Assumed Hot Path)
We do not assume a single dominant resolution shape (for example, factory/no-params).
We optimize all supported resolution paths and validate each one with dedicated benchmarks.

Benchmark matrix should include:
- `factory_no_params`
- `factory_with_params`
- `singleton_cold`
- `singleton_warm`
- `with_overrides_scope_entry`
- `with_overrides_resolve`

Any fast path must preserve or improve adjacent paths, not just one isolated benchmark.

## Proposed Changes (Pragmatic Set)

### A) Fast Path for Common Resolution
#### Why
`Container.resolve` currently pays generic branching/allocation overhead on paths that can be shorter.
Which paths are "common" must be determined by benchmark/profile data.

#### Change
In `Container.resolve`, add a thin dispatch stage that:
- loads registration metadata once (kind, parameter requirements, override-present flag)
- chooses the shortest valid execution path for that shape
- uses direct closure invocation where type/shape is already known

Keep generic path for parameterized/fallback behavior.

Code-level expectations:
- avoid repeated dictionary/task-local lookups inside one resolve call
- avoid building temporary wrappers for no-param resolves
- keep a single resolver implementation, but isolate small specialized branches
- avoid rebuilding expensive key metadata in hot loops; keep hot-path keys stable and precomputed where possible

Example shape-dispatch sketch:
```swift
func resolve<T>(_ type: T.Type, params: Any?) throws -> T {
  let key = ServiceKey(T.self)

  // 1) Check override chain once.
  let registration = overrideContext.lookup(key) ?? registrations[key]
  guard let registration else { throw ResolveError.missingRegistration(key) }

  // 2) Dispatch by precomputed shape.
  switch registration.shape {
  case .factoryNoParameters:
    return try cast(registration.makeFactoryWithoutParameters(self))
  case .factoryWithParameters:
    guard let params else { throw ResolveError.missingParams(key) }
    return try cast(registration.makeFactoryWithParameters(self, params))
  case .singletonNoParameters:
    return try cast(singletonStore.getOrCreate(registration, container: self))
  }
}
```

#### Complexity budget
Low. One resolver flow with conditional fast path.

### B) Cheaper Singleton Warm Path
#### Why
Warm singleton lookups still pay locking/state costs.

#### Change
Adopt the WhoopDI-style singleton pattern (simple double-checked locking):
- first check cached value without locking
- if empty, lock and check again
- initialize once and store
- return cached value for warm path

Code-level expectations:
- avoid allocating per-read helper objects
- keep initialization logic simple and explicit
- validate contention behavior with dedicated concurrent singleton tests
- treat existing wait/retry singleton state-machine flow as deprecated for this phase

Example singleton store sketch:
```swift
final class SingletonStore {
  private let lock = NSLock()
  private var values: [ServiceKey: Any] = [:]

  func getOrCreate(_ registration: Registration, container: Container) -> Any {
    if let cached = values[registration.key] {
      return cached
    }

    lock.lock()
    defer { lock.unlock() }

    if let cached = values[registration.key] {
      return cached
    }

    let created = registration.makeFactoryWithoutParameters(container)
    values[registration.key] = created
    return created
  }
}
```

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

Code-level expectations:
- represent overrides as layered maps (base + scope overlays) instead of eager merged copies
- resolve lookups by checking top-most overlay first, then falling through
- keep task-local push/pop O(1) in scope entry/exit
- guard against deep-scope lookup regressions by measuring nested override depth and using a hybrid strategy when needed

Tradeoff to evaluate explicitly:
- Entry-time merge/snapshot (Factory/swift-dependencies style) can make per-resolve lookup cheap but can cost more at scope entry.
- Layered overlays make scope entry cheap but can make lookup slower when nesting gets deep.
- Bolt should pick the strategy (or hybrid) that wins on total scope cost in benchmark scenarios, not just isolated entry or isolated lookup.

Example override layering sketch:
```swift
final class OverrideLayer {
  let parent: OverrideLayer?
  let entries: [ServiceKey: Registration]
  
  init(parent: OverrideLayer?, entries: [ServiceKey: Registration]) {
    self.parent = parent
    self.entries = entries
  }

  func lookup(_ key: ServiceKey) -> Registration? {
    if let value = entries[key] { return value }
    return parent?.lookup(key)
  }
}

func withOverrides(_ entries: [ServiceKey: Registration], operation: () throws -> Void) rethrows {
  let current = taskLocalOverrideLayer
  taskLocalOverrideLayer = OverrideLayer(parent: current, entries: entries)
  defer { taskLocalOverrideLayer = current }
  try operation()
}
```

#### Complexity budget
Medium. Prefer the smallest change that materially improves benchmark time.

### D) Hot-path Hygiene
#### Why
Small overheads accumulate in tight loops.

#### Change
- Build detailed error messages only on failure paths.
- Avoid unnecessary temporary allocations in resolution loop.
- Keep parameter/type checks but avoid repeated work in common case.
- Prefer stable precomputed identifiers/keys when repeatedly probing caches/registrations.

Key reuse example:
```swift
enum ServiceKeys {
  static let leaf = ServiceKey(Leaf.self)
}
```

Example failure-only message construction:
```swift
@inline(__always)
func missingRegistrationError(_ key: ServiceKey) -> ResolveError {
  // Only runs on failure path.
  ResolveError("No registration for \(key.debugName)")
}
```

#### Complexity budget
Low.

## Implementation Notes (Concrete Touchpoints)
- `Container.resolve`: centralize metadata read, perform single shape dispatch, and keep fallback generic path intact.
- Singleton storage: split warm-read logic from cold-init logic; keep synchronization surface small and explicit.
- Override context plumbing: move from eager materialization toward overlay references while preserving lexical/task-local behavior.
- Error construction: push string interpolation and diagnostic formatting behind failure guards.

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
- Implement profile-driven fast-path dispatch in resolver.
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
- `bolt_factory_resolve_with_params`: >= 20% improvement
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

For reproducibility:
- pin benchmark dependency versions (WhoopDI/Factory/swift-dependencies) to exact revisions/tags
- record pinned revisions with each benchmark artifact
- ensure benchmark package configuration resolves in-repo before collecting baseline/results

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
- Do we want a CI workflow to run benchmarks manually (`workflow_dispatch`) and upload artifacts?
