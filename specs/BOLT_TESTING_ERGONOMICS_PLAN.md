# Bolt Testing Ergonomics Plan

Date: 2026-04-23
Status: Draft

## Problem

Bolt's current testing model is semantically strong but ergonomically heavier than `swift-dependencies` for a very common test shape:

1. build an isolated module graph for the test, and then
2. override one or two registrations for that scope.

Today that requires nested lexical scopes:

```swift
await Bolt.withModules([AppModule(), FeatureModule()]) {
  await Bolt.withOverrides {
    Factory(APIClient.self) { _ in MockAPIClient() }
  } _: {
    let model = FeatureModel()
    await model.load()
    #expect(model.client is MockAPIClient)
  }
}
```

This is correct and explicit, but it creates extra closure depth compared to `swift-dependencies`' flatter testing APIs and its `DependenciesTestSupport` trait layer.

## Goals

1. Reduce closure nesting for the common `withModules { withOverrides { ... } }` testing pattern.
2. Add a first-class single-root module testing API so feature-module tests read naturally at the call site.
3. Preserve Bolt's existing runtime model:
   - `withModules` builds a fresh scoped graph.
   - `withOverrides` overlays the current scoped container.
4. Keep behavior explicit and source-compatible.
5. Add Swift Testing trait support in a separate test-support product so that test code can avoid explicit wrappers in many cases.
6. Roll out trait support using a versioned package manifest, analogous to the way `swift-dependencies` uses toolchain-specific manifests for newer capabilities.

## Non-goals

1. Replacing Bolt's container/module model with a value-environment model.
2. Introducing implicit global test state.
3. Allowing duplicate registrations across modules as an alternative override mechanism.
4. Hiding `Bolt.withModules` / `Bolt.withOverrides` from users who prefer the explicit forms.

## Proposed Changes

### 1) Add a sugar overload for `withModules(..., overrides:)`

Add sync and async overloads that compose Bolt's existing scoped graph and override behavior:

```swift
public static func withModules<R>(
  _ modules: [DependencyModule],
  overrides: @DependencyBuilder () -> [Registration],
  _ body: () throws -> R
) rethrows -> R

public static func withModules<R>(
  _ modules: [DependencyModule],
  overrides: @DependencyBuilder () -> [Registration],
  _ body: () async throws -> R
) async rethrows -> R
```

Semantics:
- Build a fresh container from `modules` using the existing planner/build path.
- Enter that graph with `withContainer`.
- Apply `withOverrides` inside that graph.
- Execute `body` in the doubly-scoped context.

Equivalent desugaring:

```swift
let container = buildContainer(from: modules)
return try withContainer(container) {
  try withOverrides(overrides) {
    try body()
  }
}
```

#### Why this is the right amount of sugar

- It removes the most common nesting pain without changing Bolt's mental model.
- It does not weaken module duplicate-registration rules.
- It reuses existing implementation paths, so behavior stays consistent with the explicit nested form.

### 2) Add module-rooted graph sugar on `DependencyModule`

Add sync and async convenience methods on `DependencyModule` that root a scoped test graph at that module instance and optionally apply overrides:

```swift
extension DependencyModule {
  public func withTestGraph<R>(
    overrides: @DependencyBuilder () -> [Registration] = { [] },
    _ body: () throws -> R
  ) rethrows -> R

  public func withTestGraph<R>(
    overrides: @DependencyBuilder () -> [Registration] = { [] },
    _ body: () async throws -> R
  ) async rethrows -> R
}
```

Semantics:
- Treat `self` as the root module for the scoped graph.
- Resolve transitive `dependentModules` exactly as `Bolt.withModules([self], ...)` does.
- Apply `overrides` as graph-scoped overrides, not as module-local provenance-aware rewrites.

Equivalent desugaring:

```swift
try Bolt.withModules([self], overrides: overrides) {
  try body()
}
```

and:

```swift
try await Bolt.withModules([self], overrides: overrides) {
  try await body()
}
```

#### Why this should be graph-rooted, not "module-local override"

Bolt does not currently preserve module ownership/provenance on built registrations. At runtime, resolution is by dependency key in the active container chain, not by originating module.

That means this API must be documented as:
- "build a test graph rooted at this module"
- not "override only registrations declared by this module"

This avoids misleading semantics around:
- dependent modules,
- shared dependencies across multiple roots,
- and hypothetical per-module namespacing that Bolt does not implement today.

#### Why this is worth shipping alongside the top-level sugar

- It makes the most common feature test read naturally:
  - `FeatureModule().withTestGraph { ... }`
  - `FeatureModule().withTestGraph(overrides: { ... }) { ... }`
- It keeps `Bolt.withModules([...], overrides:)` available for multi-root and graph-shaping scenarios.
- It stays fully aligned with Bolt's current explicit container model.

### 3) Add a `BoltTestSupport` product with Swift Testing traits

Add a separate library product/target that is intended for test targets only:

- Product: `BoltTestSupport`
- Target: `Sources/BoltTestSupport`

Initial trait surface:

```swift
extension Trait {
  public static func boltDependencies(
    modules: @escaping @Sendable @ModuleBuilder () -> [DependencyModule]
  ) -> Self

  public static func boltDependencies(
    modules: @escaping @Sendable @ModuleBuilder () -> [DependencyModule],
    overrides: @escaping @Sendable @DependencyBuilder () -> [Registration]
  ) -> Self
}
```

Example usage:

```swift
@Suite(
  .boltDependencies(modules: {
    AppModule()
    FeatureModule()
  })
)
struct FeatureTests {
  @Test func liveGraphSmoke() {
    let model = FeatureModel()
    #expect(model != nil)
  }
}
```

And with overrides:

```swift
@Test(
  .boltDependencies(
    modules: {
      AppModule()
      FeatureModule()
    },
    overrides: {
      Factory(APIClient.self) { _ in MockAPIClient() }
      Factory(Analytics.self) { _ in NoopAnalytics() }
    }
  )
)
func featureUsesMockAPI() async {
  let model = FeatureModel()
  await model.load()
  #expect(model.client is MockAPIClient)
}
```

#### Why a single combined trait family

This plan intentionally prefers **one combined trait family** over separate `.boltModules(...)` and `.boltOverrides { ... }` traits.

Reasoning:
- Separate traits introduce ordering questions:
  - does the override trait run inside or outside the module trait?
  - how do suite-level and test-level traits combine?
- A combined trait makes the scope explicit:
  - build graph
  - apply overrides
  - run test
- This matches the sugar overload and keeps the public story simple.

A separate `boltOverrides` trait can be reconsidered later if there is strong demand and trait composition behavior is well understood.

### 4) Add a `Package@swift-6.2.swift` manifest overlay

Add a toolchain-specific manifest that exposes `BoltTestSupport` only on newer toolchains.

Rationale:
- It mirrors the **versioned manifest** strategy used by `swift-dependencies` for newer package capabilities.
- It lets Bolt keep the base `Package.swift` small and conservative.
- It allows `BoltTestSupport` to assume the modern Swift Testing trait APIs available on the targeted toolchain, instead of carrying multi-compiler compatibility shims in the first release.

### Why `6.2`

This plan assumes a `Package@swift-6.2.swift` rollout because that is the requested direction and gives us a clean floor for trait APIs.

If CI later shows that the desired trait surface works cleanly on Swift 6.1, we can rename the overlay to `Package@swift-6.1.swift` in a follow-up without changing the core design.

## Proposed API Examples

### Runtime sugar API

Before:

```swift
Bolt.withModules([AppModule(), FeatureModule()]) {
  Bolt.withOverrides {
    Factory(APIClient.self) { _ in MockAPIClient() }
  } _: {
    let model = FeatureModel()
    #expect(model.client is MockAPIClient)
  }
}
```

After:

```swift
Bolt.withModules(
  [AppModule(), FeatureModule()],
  overrides: {
    Factory(APIClient.self) { _ in MockAPIClient() }
  }
) {
  let model = FeatureModel()
  #expect(model.client is MockAPIClient)
}
```

Async:

```swift
await Bolt.withModules(
  [AppModule(), FeatureModule()],
  overrides: {
    Factory(APIClient.self) { _ in MockAPIClient() }
  }
) {
  let model = FeatureModel()
  await model.load()
  #expect(model.client is MockAPIClient)
}
```

### Module-rooted sugar API

Single-root sync:

```swift
FeatureModule().withTestGraph(
  overrides: {
    Factory(APIClient.self) { _ in MockAPIClient() }
  }
) {
  let model = FeatureModel()
  #expect(model.client is MockAPIClient)
}
```

Single-root async:

```swift
await FeatureModule().withTestGraph(
  overrides: {
    Factory(APIClient.self) { _ in MockAPIClient() }
  }
) {
  let model = FeatureModel()
  await model.load()
  #expect(model.client is MockAPIClient)
}
```

This should be documented as a graph rooted at `FeatureModule()`, including any transitive `dependentModules`, rather than a provenance-aware "override only this module" mechanism.

### Trait-based tests

Per-test graph:

```swift
@Test(
  .boltDependencies(modules: {
    FeatureModule()
  })
)
func featureGraphBuilds() {
  let model = FeatureModel()
  #expect(model != nil)
}
```

Per-test graph + override:

```swift
@Test(
  .boltDependencies(
    modules: {
      FeatureModule()
    },
    overrides: {
      Factory(APIClient.self) { _ in MockAPIClient() }
    }
  )
)
func featureUsesMockAPI() {
  let model = FeatureModel()
  #expect(model.client is MockAPIClient)
}
```

Suite-level default graph:

```swift
@Suite(
  .boltDependencies(modules: {
    AppModule()
    FeatureModule()
  })
)
struct FeatureSuite {
  @Test func scenarioA() {
    let model = FeatureModel()
    #expect(model != nil)
  }

  @Test func scenarioB() {
    let model = FeatureModel()
    #expect(model != nil)
  }
}
```

## Implementation Details

### A) Runtime sugar implementation

No container model changes are required.

Suggested implementation in `Sources/Bolt/Bolt.swift`:

```diff
 public enum Bolt {
@@
     public static func withModules<R>(_ modules: [DependencyModule], _ body: () throws -> R) rethrows -> R {
         let container = buildContainer(from: modules)
         return try withContainer(container) {
             try body()
         }
     }
+
+    public static func withModules<R>(
+        _ modules: [DependencyModule],
+        overrides: @DependencyBuilder () -> [Registration],
+        _ body: () throws -> R
+    ) rethrows -> R {
+        let container = buildContainer(from: modules)
+        return try withContainer(container) {
+            try withOverrides(overrides) {
+                try body()
+            }
+        }
+    }
@@
     public static func withModules<R>(_ modules: [DependencyModule], _ body: () async throws -> R) async rethrows -> R
     {
         let container = buildContainer(from: modules)
         return try await withContainer(container) {
             try await body()
         }
     }
+
+    public static func withModules<R>(
+        _ modules: [DependencyModule],
+        overrides: @DependencyBuilder () -> [Registration],
+        _ body: () async throws -> R
+    ) async rethrows -> R {
+        let container = buildContainer(from: modules)
+        return try await withContainer(container) {
+            try await withOverrides(overrides) {
+                try await body()
+            }
+        }
+    }
 }
```

### B) Module-rooted sugar implementation

Add convenience methods in `Sources/Bolt/DependencyModule.swift`.

Representative diff sketch:

```diff
 open class DependencyModule {
     public init() {}
 
     open var body: ModuleDefinition {
         ModuleDefinition()
     }
+
+    public func withTestGraph<R>(
+        overrides: @DependencyBuilder () -> [Registration] = { [] },
+        _ body: () throws -> R
+    ) rethrows -> R {
+        try Bolt.withModules([self], overrides: overrides) {
+            try body()
+        }
+    }
+
+    public func withTestGraph<R>(
+        overrides: @DependencyBuilder () -> [Registration] = { [] },
+        _ body: () async throws -> R
+    ) async rethrows -> R {
+        try await Bolt.withModules([self], overrides: overrides) {
+            try await body()
+        }
+    }
 }
```

Notes:
- This is intentionally rooted-graph sugar.
- It should not attempt to distinguish registrations declared directly by `self` from registrations coming from dependent modules.
- It relies entirely on existing planner/container behavior.

### C) Trait implementation strategy

Add a new file such as `Sources/BoltTestSupport/BoltTestingTrait.swift`.

The trait should:
- build fresh module instances per test invocation,
- build a fresh container per test invocation,
- optionally apply overrides inside that fresh graph,
- run recursively for suites so that each test gets isolated singleton caches and no shared mutable graph.

Representative implementation sketch:

```swift
#if canImport(Testing)
import Bolt
import Testing

public struct _BoltDependenciesTrait: TestScoping, TestTrait, SuiteTrait {
  let makeModules: @Sendable () -> [DependencyModule]
  let makeOverrides: @Sendable () -> [Registration]

  public var isRecursive: Bool { true }

  public func provideScope(
    for test: Test,
    testCase: Test.Case?,
    performing function: @Sendable () async throws -> Void
  ) async throws {
    try await Bolt.withModules(
      makeModules(),
      overrides: makeOverrides
    ) {
      try await function()
    }
  }
}

extension Trait where Self == _BoltDependenciesTrait {
  public static func boltDependencies(
    modules: @escaping @Sendable @ModuleBuilder () -> [DependencyModule]
  ) -> Self {
    Self(makeModules: modules, makeOverrides: { [] })
  }

  public static func boltDependencies(
    modules: @escaping @Sendable @ModuleBuilder () -> [DependencyModule],
    overrides: @escaping @Sendable @DependencyBuilder () -> [Registration]
  ) -> Self {
    Self(makeModules: modules, makeOverrides: overrides)
  }
}
#endif
```

### Why traits should accept module factories, not module arrays

This is important because `DependencyModule` is class-based and Bolt's module planner dedupes by logical `serviceKey`, not by allocation identity.

Using a closure:

```swift
modules: {
  AppModule()
  FeatureModule()
}
```

ensures each test gets fresh module instances rather than reusing a single array of module objects captured at trait construction time.

### D) Package manifest strategy

Add a new `Package@swift-6.2.swift` file that duplicates the base package definition and adds the new product/targets.

Representative diff sketch:

```diff
+// swift-tools-version: 6.2
+
+import PackageDescription
+
+let package = Package(
+  name: "Bolt",
+  platforms: [
+    .iOS(.v17),
+    .macOS(.v15),
+    .watchOS(.v10),
+  ],
+  products: [
+    .library(name: "Bolt", targets: ["Bolt"]),
+    .library(name: "BoltTestSupport", targets: ["BoltTestSupport"]),
+  ],
+  targets: [
+    .target(name: "Bolt"),
+    .target(
+      name: "BoltTestSupport",
+      dependencies: ["Bolt"]
+    ),
+    .testTarget(
+      name: "BoltTests",
+      dependencies: ["Bolt"]
+    ),
+    .testTarget(
+      name: "BoltTestSupportTests",
+      dependencies: ["Bolt", "BoltTestSupport"]
+    ),
+  ],
+  swiftLanguageModes: [.v6]
+)
```

Notes:
- `Package.swift` remains the conservative baseline.
- `Package@swift-6.2.swift` becomes the higher-priority manifest on 6.2+ toolchains.
- `BoltTestSupport` is documented as **test-target-only** even though SwiftPM cannot strictly enforce that.

## Test Plan

### 1) Runtime sugar tests

Add focused tests to `Tests/BoltTests` for the new overloads and module-rooted convenience methods:

1. `withModulesOverridingRegistrationsAppliesOverridesInsideScopedGraph`
2. `withModulesOverridingRegistrationsRestoresBaseGraphAfterScope`
3. `asyncWithModulesOverridingRegistrationsRetainsOverridesAcrossAwait`
4. `withModulesOverridingRegistrationsIsEquivalentToNestedWithOverrides`
5. `moduleWithTestGraphAppliesOverridesInsideRootedGraph`
6. `asyncModuleWithTestGraphRetainsOverridesAcrossAwait`
7. `moduleWithTestGraphIncludesDependentModulesTransitively`

Representative top-level shape:

```swift
@Test func withModulesOverridingRegistrationsAppliesOverridesInsideScopedGraph() {
  Bolt.withModules(
    [ScopedStringModule(value: "base")],
    overrides: {
      Factory(String.self) { _ in "override" }
    }
  ) {
    let value: String = Bolt.inject()
    #expect(value == "override")
  }
}
```

Representative module-rooted shape:

```swift
@Test func moduleWithTestGraphIncludesDependentModulesTransitively() {
  OrderedModuleB().withTestGraph {
    let value: OrderedValue = Bolt.inject()
    #expect(value.value == "A")
  }
}
```

### 2) Trait tests

Add `Tests/BoltTestSupportTests` under the 6.2 manifest overlay.

Coverage goals:

1. A test trait can build a graph and resolve from it.
2. A test trait can apply overrides on top of the graph.
3. A suite-level trait creates fresh state per test rather than sharing singleton caches across sibling tests.
4. Trait-scoped tests remain isolated under concurrent Swift Testing execution.

Representative shape:

```swift
import Bolt
import BoltTestSupport
import Testing

@Suite(
  .boltDependencies(
    modules: {
      ScopedStringModule(value: "base")
    },
    overrides: {
      Factory(String.self) { _ in "override" }
    }
  )
)
struct BoltTraitSuite {
  @Test func overrideApplies() {
    let value: String = Bolt.inject()
    #expect(value == "override")
  }
}
```

### 3) Manifest smoke coverage

On a Swift 6.2 toolchain:
- `swift package dump-package` should show the `BoltTestSupport` product.
- `swift test` should build both `BoltTests` and `BoltTestSupportTests`.

On older supported toolchains:
- baseline package behavior should remain unchanged.

## Documentation Updates

When implementing, update the following:

1. `README.md`
   - Add `withModules(..., overrides:)` examples.
   - Add `FeatureModule().withTestGraph(...)` examples.
   - Clarify that `withTestGraph` roots a scoped graph at a module and is not a module-provenance-specific override mechanism.
   - Add a "Swift Testing traits" section for `BoltTestSupport`.
   - Explicitly state that `BoltTestSupport` is for test targets only.

2. `specs/BOLT_DI_SPEC.md`
   - Add the new `withModules(..., overrides:)` overloads to the public API surface.
   - Add `DependencyModule.withTestGraph(...)` to the public API surface.
   - Update client testing ergonomics guidance to mention the top-level sugar, module-rooted sugar, and trait product.

3. Potential new README manifest example:

```swift
.testTarget(
  name: "MyFeatureTests",
  dependencies: [
    .product(name: "Bolt", package: "bolt-di"),
    .product(name: "BoltTestSupport", package: "bolt-di"),
  ]
)
```

## Rollout Plan

### Phase 1: Runtime sugar

1. Add the sync/async `withModules(..., overrides:)` overloads.
2. Add sync/async `DependencyModule.withTestGraph(...)` convenience methods.
3. Add focused runtime tests.
4. Update README + spec docs.

Acceptance:
- Common nested test setup can be expressed in one top-level API call.
- Single-root feature module tests can be expressed directly from the module.
- `withTestGraph` behavior matches `Bolt.withModules([module], overrides: ...)`.
- Behavior matches explicit nested scoping.

### Phase 2: `BoltTestSupport`

1. Add `Package@swift-6.2.swift`.
2. Add `BoltTestSupport` product/target.
3. Implement `.boltDependencies(modules:overrides:)`.
4. Add trait tests.
5. Document consumer usage.

Acceptance:
- Swift 6.2+ consumers can use Bolt test traits from a dedicated test-support product.
- Each test still receives isolated task-local graph state.

## Open Questions

1. Should the sugar API also gain a `withContainer(container, overrides:)` counterpart for symmetry, or should we keep scope focused on the module-driven pain points first?
2. Is Swift 6.2 the right manifest floor, or can this ship as `Package@swift-6.1.swift` after validation?
3. Should Bolt eventually add a second convenience trait for container-driven tests, e.g. `.boltDependencies(container:overrides:)`, or keep the first release module-centric?
4. Should README recommend traits as the default style for Swift Testing, or present them as optional sugar on top of the explicit APIs?

## Recommendation

Proceed with both change sets, in this order:

1. ship the runtime sugar additions first:
   - `Bolt.withModules(..., overrides:)`
   - `DependencyModule.withTestGraph(...)`
2. then add `BoltTestSupport` behind `Package@swift-6.2.swift`.

That sequence keeps the core improvement small and low-risk while giving Bolt a clean path toward `swift-dependencies`-style testing ergonomics without changing Bolt's underlying DI model or pretending Bolt supports provenance-aware per-module overrides.
