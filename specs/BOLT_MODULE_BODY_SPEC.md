# Bolt Module Body DSL Spec (Breaking)

Date: 2026-02-13
Status: Draft

## Summary
Replace Bolt's module API with a single result-builder `body` that declares both:
- dependent modules
- registrations (`Factory`, `Singleton`, `FactoryWithParams`)

This is a breaking change. There is no legacy fallback for `dependentModules` or `defineDependencies(into:)`.

## Goals
- Make module definitions fully DSL-driven and ergonomic.
- Eliminate split configuration across two overridable members.
- Keep module graph behavior deterministic.
- Preserve current runtime semantics for registration and resolution.

## Non-goals
- Backward compatibility with legacy module APIs.
- Macro/codegen support.
- Changing runtime behavior of `Container.get` / `Bolt.inject` crash-on-failure semantics.

## Breaking API

### New module definition surface
```swift
open class DependencyModule {
    public init() {}

    @ModuleBuilder
    open var body: ModuleDefinition {
        ModuleDefinition()
    }
}
```

### Module body DSL
```swift
final class NetworkModule: DependencyModule {
    override var body: ModuleDefinition {
        DependentModules {
            CoreModule()
            AuthModule(environment: .prod)
        }

        Singleton { _ in APIClient.live }

        Factory { resolver in
            UserService(api: resolver.get())
        }

        FactoryWithParams(named: "greeting") { (_: Resolver, name: String) in
            "Hello, \(name)!"
        }
    }
}
```

### Supported module body expressions
- `DependentModules { ... }`
- `Factory { ... }`
- `Singleton { ... }`
- `FactoryWithParams { ... }`
- linear declaration lists only (no control-flow composition in module body)

## New Types

```swift
public struct ModuleDefinition {
    public let dependentModules: [DependencyModule]
    public let registrations: [Registration]
}

@resultBuilder
public enum ModuleBuilder {
    public static func buildBlock(_ components: ModuleComponent...) -> [ModuleComponent]
    public static func buildExpression(_ expression: DependentModules) -> ModuleComponent
    public static func buildExpression(_ expression: DependencyModule) -> ModuleComponent
    public static func buildExpression<T>(_ expression: Factory<T>) -> ModuleComponent
    public static func buildExpression<T>(_ expression: Singleton<T>) -> ModuleComponent
    public static func buildExpression<P, T>(_ expression: FactoryWithParams<P, T>) -> ModuleComponent
    public static func buildFinalResult(_ component: [ModuleComponent]) -> ModuleDefinition
    public static func buildFinalResult(_ component: [ModuleComponent]) -> [DependencyModule]
}

public struct DependentModules {
    public init(@ModuleBuilder _ content: () -> [DependencyModule])
    public let values: [DependencyModule]
}
```

Notes:
- `ModuleComponent` is an internal aggregation primitive used by `ModuleBuilder`.
- There is no dedicated `DependentModulesBuilder`; `DependentModules` reuses `ModuleBuilder`.
- `ModuleBuilder` finalizes differently by context (top-level module body vs dependency-only group), mirroring SwiftUI-style builder ergonomics.

## Internal Integration Plan

### Internal collected type
`ModuleBuilder` collects an internal, non-public enum:

```swift
enum ModuleComponent {
    case dependency(DependencyModule)
    case registration(Registration)
}
```

The builder does not decide graph behavior. It only emits a linear component list in lexical order.

### Builder lowering rules
- `buildExpression(_ expression: DependencyModule)` lowers to `.dependency(expression)`.
- `buildExpression(_ expression: DependentModules)` appends each wrapped module as `.dependency(...)` in declaration order.
- `buildExpression(Factory/Singleton/FactoryWithParams)` lowers to `.registration(...)`.
- No `buildOptional`/`buildEither`/`buildArray` support is provided; module declarations are intentionally linear.

### Context-sensitive finalization
- In `DependencyModule.body`, `buildFinalResult` reduces `[ModuleComponent]` into:
  - `ModuleDefinition.dependentModules`: all `.dependency` items
  - `ModuleDefinition.registrations`: all `.registration` items
- In `DependentModules { ... }`, `buildFinalResult` reduces `[ModuleComponent]` into `[DependencyModule]` and traps/fails fast if any `.registration` is present.

This keeps one builder while enforcing that dependency groups contain only modules.

### Setup pipeline integration
`Bolt.setup(modules:)` integration steps:
1. Read `module.body` once per visited module instance.
2. Use `body.dependentModules` to traverse/DFS the graph.
3. Preserve existing cycle detection and deterministic ordering guarantees.
4. After ordering, register `body.registrations` for each ordered module into the target container.

Implementation note:
- During `orderedModules(from:)`, cache each module instance's computed `ModuleDefinition` in a local dictionary keyed by `ObjectIdentifier(module)` to avoid recomputing `body` multiple times.
- Reuse that cache during registration to avoid duplicate builder work.

### Concrete call flow and ownership
This section defines exactly who calls what and when.

#### 1) Entry point
- Caller: application/test code
- Call: `Bolt.setup(modules: [DependencyModule])`
- Owner: `Bolt` facade

#### 2) Graph planning phase
- Caller: `Bolt.setup`
- Call: `DependencyModule.planGraph(from roots: [DependencyModule]) -> ModulePlan`
- Owner: `DependencyModule` graph utility
- Output: `ModulePlan` containing:
  - `orderedModules: [DependencyModule]`
  - `definitionsByInstanceID: [ObjectIdentifier: ModuleDefinition]`

`planGraph` responsibilities:
- DFS roots in lexical order.
- For each visited module instance:
  - evaluate `module.body` once
  - store `ModuleDefinition` in `definitionsByInstanceID`
  - read `definition.dependentModules` for traversal edges
- detect cycles using the current type-stack mechanism
- preserve distinct instance semantics (no silent dedup beyond already-visited instance IDs)

#### 3) Registration phase
- Caller: `Bolt.setup`
- Inputs: `ModulePlan.orderedModules`, `ModulePlan.definitionsByInstanceID`
- Owner: `Bolt.setup` orchestration
- For each module in `orderedModules`:
  - lookup `definition = definitionsByInstanceID[ObjectIdentifier(module)]`
  - call `container.register { ... }` with `definition.registrations`

Note:
- Registration storage and resolution remain in `Container`; module DSL only changes how registration lists are produced.

#### 4) Activation phase
- Caller: `Bolt.setup`
- Owner: `Bolt` facade
- Action: publish prepared container to `Bolt.shared` under existing lock.

### Data shape through the pipeline
Exact data transformations:

1. User module source:
- `DependencyModule.body` declarations

2. Builder collection:
- `ModuleBuilder` emits `[ModuleComponent]`
- `ModuleComponent` values are either:
  - `.dependency(DependencyModule)`
  - `.registration(Registration)`

3. Builder finalization:
- Top-level `body` context:
  - `[ModuleComponent] -> ModuleDefinition(dependentModules, registrations)`
- `DependentModules { ... }` context:
  - `[ModuleComponent] -> [DependencyModule]`
  - any `.registration` triggers immediate failure

4. Graph planning:
- `[DependencyModule roots] + ModuleDefinition.dependentModules` edges
  -> `ModulePlan(orderedModules, definitionsByInstanceID)`

5. Registration handoff:
- `ModuleDefinition.registrations`
  -> `Container.register(@DependencyBuilder)` / internal registration map

6. Runtime resolution:
- unchanged existing path (`Container.get` / `Bolt.inject`)

### Proposed internal structs and signatures
Non-public integration surface:

```swift
struct ModulePlan {
    let orderedModules: [DependencyModule]
    let definitionsByInstanceID: [ObjectIdentifier: ModuleDefinition]
}

extension DependencyModule {
    static func planGraph(from roots: [DependencyModule]) throws -> ModulePlan
}
```

`Bolt.setup` pseudocode:

```swift
public static func setup(modules: [DependencyModule]) {
    let container = Container()
    let plan = try DependencyModule.planGraph(from: modules)

    for module in plan.orderedModules {
        let id = ObjectIdentifier(module)
        guard let definition = plan.definitionsByInstanceID[id] else {
            fatalError("Bolt: Internal error: missing module definition cache.")
        }
        container.register(definition.registrations)
    }

    sharedLock.withLock { sharedStorage = container }
}
```

Where `container.register(definition.registrations)` is an internal convenience overload that bypasses rebuilding via `DependencyBuilder`.

### Single Planner Architecture (No Duplication)
This proposal requires exactly one graph-planning implementation for both runtime setup and validation.

#### Rule
- `DependencyModule.planGraph(from:)` is the only place that:
  - evaluates module `body`
  - traverses dependency edges
  - detects graph cycles
  - computes deterministic ordering
  - caches `ModuleDefinition` by module instance

#### Explicitly disallowed
- A second traversal implementation in `Bolt.setup`.
- A second traversal implementation in `BoltValidator`.
- Re-evaluating `module.body` in setup/validator after planning.
- Separate caches for setup and validator within the same planning invocation.

#### Shared consumers
- `Bolt.setup(modules:)`:
  - consumes `ModulePlan`
  - registers planned registrations into a fresh `Container`
  - publishes container to `Bolt.shared`
- `BoltValidator(modules:)`:
  - consumes `ModulePlan`
  - registers planned registrations into a collecting container
  - emits validation diagnostics

#### API adaptation from current code
Current shared helper:
- `DependencyModule.orderedModules(from:)` in `Sources/Bolt/DependencyModule.swift`

Required adaptation:
- replace with `planGraph(from:)` (or make `orderedModules` call into `planGraph` internally during migration branch work)
- all callers (`Bolt.setup`, `BoltValidator`) use only `planGraph`

#### Error mapping (single source)
- `planGraph` throws:
  - `ModuleGraphError.cycle(path:)`
  - optional future planning errors
- `Bolt.setup` maps to fatal errors (runtime behavior unchanged)
- `BoltValidator` maps to `ValidationError` entries (validator behavior unchanged)

#### Caching contract
- Cache key: `ObjectIdentifier(moduleInstance)`
- Cache value: `ModuleDefinition`
- Lifetime: one `planGraph` invocation
- Guarantee: each visited module instance has exactly one evaluated `body` per plan

#### Registration handoff contract
- `ModulePlan` is read-only by consumers.
- Consumers must not mutate definitions or reorder `orderedModules`.
- Registrations are applied in module order, and within each module in body lexical order.

#### Source ownership map
- `Sources/Bolt/DependencyModule.swift`
  - owns planning/traversal/cycle detection/cache production
- `Sources/Bolt/Bolt.swift`
  - owns setup orchestration and shared container publication
- `Sources/Bolt/Validation.swift`
  - owns validation orchestration and error emission
- `Sources/Bolt/Container.swift`
  - owns registration storage/resolution engine (unchanged semantics)

#### Implementation acceptance checks
- There is one planner function used by both setup and validator.
- `rg` on module traversal symbols shows no duplicate DFS implementation outside `DependencyModule` planner.
- Unit tests assert setup and validator see identical module ordering for same roots.
- Benchmarks run with planner-based implementation to confirm no regressions.

### Validator integration
- `BoltValidator(modules:)` uses the same module-ordering path as `Bolt.setup`.
- Validator consumes cached `ModuleDefinition.registrations` instead of invoking `defineDependencies`.
- Existing validator diagnostics and API remain unchanged.

### Container integration
- No container engine changes are required.
- `Container.register(@DependencyBuilder)` remains unchanged and continues receiving `[Registration]`.
- Module DSL changes only how module registrations are produced, not how registrations are stored or resolved.

### Failure behavior integration
- Cycle and duplicate-registration behavior remains unchanged.
- Invalid usage inside `DependentModules { ... }` (for example adding `Factory`) fails immediately during builder finalization with a clear fatal error message.

## Runtime Semantics

### Setup flow
`Bolt.setup(modules:)` behavior becomes:
1. Traverse the graph via each module's `body.dependentModules`.
2. Topologically order modules with deterministic ordering.
3. Register each module's `body.registrations` in ordered sequence.

### Determinism and graph rules
- Traversal order is deterministic based on lexical order of root input and `DependentModules` declarations.
- Distinct module instances are preserved as distinct graph nodes.
- Distinct instances must not be silently dropped.
- Cycles are detected and reported as fatal setup errors (same as today).

### Duplicate registration behavior
Unchanged from current strict semantics:
- duplicate key in base graph is an error
- override replacement remains lexical/task-local through `withOverrides`

## Performance Gate and Removal Policy
- This proposal is gated by Bolt benchmark requirements from `BOLT_PERFORMANCE_SPEC.md` and `BOLT_PERFORMANCE_RECOVERY_PLAN.md`.
- The module-body DSL must not introduce meaningful regressions in setup or resolution benchmarks.
- If benchmark results regress beyond accepted thresholds, this feature is eligible for rollback/removal.
- Benchmark evaluation must include:
  - Tier A (`tier_a_*`) comparability runs.
  - Tier B (`tier_b_*`) Bolt stress/feature-depth runs.

## Migration Guide

### Before
```swift
final class NetworkModule: DependencyModule {
    override var dependentModules: [DependencyModule] {
        [CoreModule()]
    }

    override func defineDependencies(into container: Container) {
        container.register {
            Singleton { _ in APIClient.live }
            Factory { resolver in UserService(api: resolver.get()) }
        }
    }
}
```

### After
```swift
final class NetworkModule: DependencyModule {
    override var body: ModuleDefinition {
        DependentModules {
            CoreModule()
        }

        Singleton { _ in APIClient.live }
        Factory { resolver in UserService(api: resolver.get()) }
    }
}
```

## Validation and Testing Impact
- Update validator internals to read module registrations from `body`.
- Keep validator API surface unchanged (`BoltValidator(modules:)`, `validate(module:_:)`).
- Add tests for:
  - mixed `DependentModules` + registrations in one body
  - deterministic ordering for sibling modules
  - distinct-instance preservation
  - cycle detection through `body`
  - invalid control-flow usage is rejected at compile time

## Open Questions
1. Should `ModuleDefinition` be public or internal with opaque builder return type?
2. Do we want async module definitions in the future, or keep module construction strictly synchronous?

## Implementation Runbook (Agent Execution Plan)
Use this runbook to implement the feature with no duplicate planning logic and strict quality gates.

### Phase 0: Preconditions
1. Confirm working tree is clean or unrelated changes are understood.
2. Read these files before editing:
   - `Sources/Bolt/DependencyModule.swift`
   - `Sources/Bolt/Bolt.swift`
   - `Sources/Bolt/Validation.swift`
   - `Sources/Bolt/DependencyBuilder.swift`
   - `Sources/Bolt/Registration.swift`
3. Re-read this spec’s sections:
   - “Single Planner Architecture (No Duplication)”
   - “Performance Gate and Removal Policy”

### Phase 1: Introduce module-body DSL types
Status: Complete (2026-02-13)

Target files:
- `Sources/Bolt/DependencyModule.swift` (preferred for module-surface types)
- optionally split into a new file if needed (for example `Sources/Bolt/ModuleBuilder.swift`)

Steps:
1. Replace legacy `DependencyModule` API surface with:
   - `@ModuleBuilder open var body: ModuleDefinition`
2. Add `ModuleDefinition` public type with:
   - `dependentModules: [DependencyModule]`
   - `registrations: [Registration]`
3. Add `DependentModules` public wrapper:
   - `init(@ModuleBuilder _ content: () -> [DependencyModule])`
4. Add internal `ModuleComponent` enum:
   - `.dependency(DependencyModule)`
   - `.registration(Registration)`
5. Add `ModuleBuilder` with only:
   - `buildBlock`
   - `buildExpression` overloads for `DependentModules`, `DependencyModule`, `Factory`, `Singleton`, `FactoryWithParams`
   - `buildFinalResult -> ModuleDefinition`
   - `buildFinalResult -> [DependencyModule]`
6. Enforce failure in `buildFinalResult -> [DependencyModule]` when a registration component appears.

Completion criteria:
- Module DSL compiles.
- No `buildOptional`/`buildEither`/`buildArray` in `ModuleBuilder`.

### Phase 2: Create single planner (`planGraph`)
Status: Complete (2026-02-13)

Target file:
- `Sources/Bolt/DependencyModule.swift`

Steps:
1. Introduce internal `ModulePlan`:
   - `orderedModules: [DependencyModule]`
   - `definitionsByInstanceID: [ObjectIdentifier: ModuleDefinition]`
2. Replace/adapt `orderedModules(from:)` into `planGraph(from:)`.
3. Implement DFS with existing semantics:
   - deterministic order
   - cycle detection by module type stack
   - visited set by module instance
4. Evaluate `module.body` exactly once per visited instance and cache it.
5. Traverse edges using `definition.dependentModules`.

Completion criteria:
- One planner function exists and returns both ordering and cached definitions.
- No second DFS implementation appears anywhere else.

### Phase 3: Wire planner into runtime setup
Status: Complete (2026-02-13)

Target file:
- `Sources/Bolt/Bolt.swift`

Steps:
1. Update `Bolt.setup(modules:)` to call `DependencyModule.planGraph(from:)`.
2. Reuse cached `ModuleDefinition` from plan when registering.
3. Add internal convenience path to register `[Registration]` directly (if needed) to avoid unnecessary builder reconstruction.
4. Preserve current fatal error behavior/message style for graph failures.

Completion criteria:
- `Bolt.setup` no longer references legacy `dependentModules`/`defineDependencies`.
- Setup only consumes `ModulePlan`.

### Phase 4: Wire planner into validator
Status: Complete (2026-02-13)

Target file:
- `Sources/Bolt/Validation.swift`

Steps:
1. Update `BoltValidator.init(modules:)` to call the same `planGraph(from:)`.
2. Register `ModuleDefinition.registrations` from plan into collecting container.
3. Preserve current validation API and error mapping behavior.

Completion criteria:
- Validator uses same planner path as setup.
- No duplicate module traversal in validator.

### Phase 5: Remove legacy module API usage
Status: Complete (2026-02-13)

Target scope:
- all module declarations in tests/docs/source

Steps:
1. Remove/replace overrides of:
   - `dependentModules`
   - `defineDependencies(into:)`
2. Rewrite modules to `override var body: ModuleDefinition`.
3. Keep behavior identical in tests after migration.

Completion criteria:
- Codebase no longer depends on legacy module API.
- Build passes with new API only.

### Phase 6: Testing updates
Status: Complete (2026-02-13)

Target files:
- `Tests/BoltTests/BoltSetupAndOverrideTests.swift`
- `Tests/BoltTests/BoltValidatorTests.swift`
- any additional module graph tests

Required test coverage:
1. Setup and validator produce identical module ordering for same roots.
2. Distinct module instances remain distinct graph nodes.
3. Cycles detected through `body` dependencies.
4. `DependentModules { ... }` rejects registrations (runtime trap/unit crash test as appropriate).
5. Registration ordering is deterministic and lexical.
6. Existing resolution/scoping behavior remains unchanged.

Completion criteria:
- `swift test` passes.

### Phase 7: Documentation updates
Status: Complete (2026-02-13)

Target files:
- `README.md`
- `BOLT_DI_SPEC.md`
- this spec (`specs/BOLT_MODULE_BODY_SPEC.md`) if implementation details evolve

Steps:
1. Replace old module examples with `body` DSL examples.
2. Keep public docs aligned with final API surface.
3. Call out this as a breaking change in the relevant docs/changelog.

Completion criteria:
- No stale docs referencing legacy module API as current behavior.

### Phase 8: Performance gate (mandatory)
Status: Complete (2026-02-13)

Target commands:
- benchmark commands defined by existing performance specs

Steps:
1. Run Tier A benchmark set (`tier_a_*`).
2. Run Tier B benchmark set (`tier_b_*`).
3. Compare to pre-change baseline.
4. As follow-up, add cross-library Tier B parity benchmarks (WhoopDI/Factory/swift-dependencies) for depth/complexity comparability, since current Tier B coverage is Bolt-only.

Pass/fail policy:
- If regressions exceed accepted thresholds in performance specs, feature is rollback-eligible and should not ship as-is.

### Phase 9: Final quality checklist
Status: Complete (2026-02-13)

1. Search for duplicated traversal logic:
   - confirm only one planner implementation exists.
2. Search for legacy module API references:
   - confirm removal from runtime path.
3. Run full tests.
4. Run required benchmarks.
5. Verify docs match shipped API.

Suggested verification commands:
```bash
rg -n "orderedModules\\(|planGraph\\(|defineDependencies\\(|dependentModules" Sources Tests
swift test
```
