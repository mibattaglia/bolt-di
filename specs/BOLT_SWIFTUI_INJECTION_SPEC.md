# Bolt SwiftUI Injection Spec

Status: Proposed

Owner: Bolt maintainers

Last updated: 2026-02-16

## 1. Problem Statement

Bolt currently supports lexical/task-local dependency scoping using:

- `Bolt.withContainer`
- `Bolt.withModules`
- `Bolt.withOverrides`

These APIs work well for tests and non-UI composition, but they do not map cleanly to SwiftUI view lifecycle evaluation in previews and runtime rendering.

### Current mismatch

`@Injected` in Bolt is a plain property wrapper whose `wrappedValue` calls `Bolt.inject(...)` at read time. In SwiftUI, property reads can happen after view construction, outside the lexical scope where `withModules`/`withOverrides` were applied.

Result:

- Preview and view rendering can resolve from `Bolt.shared` unexpectedly.
- Scoped preview overrides may not be visible when `body` is evaluated.
- Developers must fall back to initializer injection at composition boundaries for reliability.

## 2. Goals

1. Provide first-class SwiftUI dependency injection ergonomics comparable to reference libraries.
2. Preserve Bolt core principles:
   - lightweight
   - explicit runtime behavior
   - no hidden global magic
3. Keep source compatibility for existing Bolt users.
4. Preserve crash-on-failure semantics during resolution.
5. Support predictable preview-only and subtree-only overrides.

## 3. Non-Goals

1. No changes to the core DI registration model (`Factory`, `Singleton`, `FactoryWithParams`).
2. No implicit mutation of global `Bolt.shared` when configuring SwiftUI subtrees.
3. No replacement of existing lexical APIs (`withModules`, `withOverrides`, `withContainer`).
4. No support for parameterized injection through SwiftUI property wrappers in v1.

## 4. High-Level Design

Introduce a separate SwiftUI-focused integration layer in a new target:

- Target name: `BoltSwiftUI`
- Depends on: `Bolt`
- Imports: `SwiftUI`

The SwiftUI layer uses `Environment` propagation rather than lexical task-local scopes.

### Core concept

- Store a `Container` in SwiftUI environment.
- Resolve dependencies from that environment container inside view properties.
- Allow subtree graph configuration via view modifiers that install a container into environment.

This aligns injection with SwiftUI rendering behavior (where `body` and dynamic properties are evaluated).

## 5. Proposed API

## 5.1 Environment container access

```swift
public extension EnvironmentValues {
    var boltContainer: Container { get set }
}
```

Behavior:

- Default value: `Bolt.shared`
- Explicit values override parent subtree values.

## 5.2 SwiftUI property wrapper

```swift
@propertyWrapper
public struct Injected<T>: DynamicProperty {
    public init(_ type: T.Type = T.self, named: String? = nil)
    public var wrappedValue: T { get }
}
```

Behavior:

- Reads `Environment(\.boltContainer)`.
- Resolves via `container.get(type, named: named)`.
- Crash-on-failure behavior is preserved.

Naming note:

- If symbol collision with core `Bolt.Injected` is undesirable, introduce `@ViewInjected` in `BoltSwiftUI`.
- Recommendation: keep `@Injected` for ergonomic parity, document module import guidance.

## 5.3 View modifiers

```swift
public extension View {
    func boltContainer(_ container: Container) -> some View
    func boltModules(_ modules: [DependencyModule]) -> some View
    func boltOverrides(@DependencyBuilder _ overrides: () -> [Registration]) -> some View
}
```

Behavior:

- `.boltContainer`: installs explicit container into environment.
- `.boltModules`: builds a fresh container from module plan and installs it.
- `.boltOverrides`: derives a new container from current environment container with selected overrides and installs it.

Modifier composition:

- Order is lexical like standard view modifiers.
- Example: `MyView().boltModules([A()]).boltOverrides { ... }` means overrides are applied to the modules container.

## 6. Required Core Additions

To support non-lexical subtree override composition, Bolt core needs one additive API:

```swift
public extension Container {
    func derived(@DependencyBuilder applying overrides: () -> [Registration]) -> Container
}
```

Semantics:

- Produces a new container snapshot:
  - base registrations inherited from source container
  - provided overrides replace matching keys
- Singleton behavior:
  - non-overridden singletons should preserve base singleton instances where possible
  - overridden singletons should use override-specific cache in derived container

Why additive API is needed:

- Existing `withScopedOverrides` is lexical and closure-bound.
- SwiftUI environment configuration needs persistent derived containers, not temporary scoped state.

## 7. Resolution Semantics in SwiftUI

1. If subtree has `.boltContainer(containerX)`, injected reads resolve from `containerX`.
2. If subtree has `.boltModules([...])`, reads resolve from freshly built module container.
3. If subtree has `.boltOverrides { ... }`, reads resolve from derived container built from nearest environment container.
4. If no modifier is present, reads resolve from `Bolt.shared` (default env value).

## 8. Preview Behavior

Expected preview pattern:

```swift
#Preview("Feature - Empty") {
    FeatureView()
        .boltModules([FeaturePreviewModule()])
        .boltOverrides {
            Factory(Analytics.self) { _ in .noop }
        }
}
```

Advantages:

- Preview-only overrides are local to preview tree.
- No global mutations via `Bolt.setup` required.
- Works with SwiftUI render lifecycle and repeated evaluations.

## 9. Source Compatibility Strategy

1. Keep existing core `@Injected` available in `Bolt` target.
2. Add SwiftUI-specific `@Injected` in `BoltSwiftUI` OR add `@ViewInjected` to avoid ambiguity.
3. Do not change existing behavior of lexical APIs.

Recommended compatibility path:

- v1 in `BoltSwiftUI`: provide `@ViewInjected` to avoid symbol ambiguity.
- v2 consideration: typealias or migration tooling if maintainers prefer unification under `@Injected`.

## 10. Error and Diagnostics Model

Resolution failures remain fatal for consistency with Bolt:

- Missing registration
- Circular runtime dependency
- Scope mismatch

Optional debug diagnostics (future enhancement):

- Include container source hint in crash messages:
  - `environment container`
  - `Bolt.shared`
  - `derived override container`

## 11. Concurrency and Safety

- Environment-based container propagation is value-driven and subtree-scoped.
- No global mutable override state introduced.
- Existing task-local APIs remain unchanged for async non-SwiftUI flows.

Container thread-safety assumptions remain as currently implemented in Bolt core.

## 12. Test Plan

Add `BoltSwiftUITests` with behavior-oriented tests:

1. `viewInjectedResolvesFromEnvironmentContainer`
2. `viewInjectedFallsBackToBoltSharedWhenNoEnvironmentProvided`
3. `boltModulesBuildsIsolatedGraphForSubtree`
4. `boltOverridesAppliesOnTopOfNearestEnvironmentContainer`
5. `nestedBoltOverridesTopmostWinsWithinSubtree`
6. `siblingSubtreesReceiveIndependentOverrideLayers`
7. `previewStyleConfigurationDoesNotMutateBoltShared`
8. `nonOverriddenSingletonsRemainStableAcrossDerivedContainers` (if preserving base cache)

If feasible, include a minimal SwiftUI preview smoke target/test to validate compile-time ergonomics.

## 13. Documentation Changes

Update README with a new section: `SwiftUI Integration`.

Include:

- when to use `@Injected` vs initializer injection
- preview examples with `.boltModules` + `.boltOverrides`
- warning that lexical `withModules`/`withOverrides` are not sufficient for view `body` evaluation

## 14. Migration Guidance

Current reliable pattern in views:

- resolve at composition boundary
- pass dependencies via initializer

Migration for ergonomic SwiftUI injection:

1. Add `BoltSwiftUI` import.
2. Replace manual composition in simple view trees with `.boltModules`/`.boltOverrides` on subtree roots.
3. Use view wrapper (`@ViewInjected` or SwiftUI `@Injected`) for dependencies used directly in views.
4. Keep initializer injection for complex leaf boundaries where explicitness is preferred.

## 15. Rollout Plan

1. Land additive core API for derived containers.
2. Add `BoltSwiftUI` target and APIs.
3. Add tests and README section.
4. Add example preview snippets under `Sources/Bolt/Scratch.swift` or docs samples.
5. Collect feedback before introducing any naming consolidation.

## 16. Open Questions

1. Wrapper naming:
   - `@Injected` in SwiftUI target (ergonomic)
   - `@ViewInjected` (unambiguous)
2. Singleton cache behavior across derived containers:
   - strict copy-on-write cache isolation
   - shared cache for non-overridden registrations
3. Public API for deriving containers:
   - expose as `Container.derived(...)`
   - keep internal and only expose via SwiftUI modifiers

## 17. Alternatives Considered

1. Reuse lexical `withOverrides` directly in previews

Rejected: lexical scope does not align with SwiftUI render lifecycle.

2. Mutate `Bolt.shared` in preview setup

Rejected: global state is brittle and leaks between previews/tests.

3. Add hidden global override stack keyed by thread/task

Rejected: increases hidden behavior and risks cross-task leakage.

## 18. Success Criteria

1. Developers can write preview-only dependency overrides without touching `Bolt.shared`.
2. SwiftUI property wrapper injection resolves consistently during render updates.
3. Existing Bolt non-SwiftUI API remains source-compatible.
4. No regression in concurrency isolation guarantees.

