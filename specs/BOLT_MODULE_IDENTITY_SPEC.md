# Bolt ServiceKey Module Identity Spec

Date: 2026-04-23
Status: Draft

## Summary

Change Bolt's module graph planner to mimic WhoopDI more closely by using a public `serviceKey` on `DependencyModule`.

Proposed behavior:

- Bolt adds `open var serviceKey: ServiceKey` to `DependencyModule`
- default module identity is `ServiceKey(type(of: self))`, matching WhoopDI
- dependent modules are deduped by `serviceKey`, not by module instance identity
- the first discovered module for a given `serviceKey` wins
- later modules with the same `serviceKey` are ignored during graph planning
- modules of the same concrete type can still participate more than once **if** they override `serviceKey` to be distinct

This is a breaking change and **no backwards compatibility is required**.

Because we want to mimic WhoopDI closely and we do not need to preserve the old public naming, this spec also proposes renaming Bolt's public dependency key type from `Key` to `ServiceKey`.

That keeps Bolt aligned around one concept:

- registration lookup uses `ServiceKey`
- validation identifies dependencies by `ServiceKey`
- module identity uses `DependencyModule.serviceKey`

## Problem

Bolt currently plans module graphs by **instance identity**.

Today:

- `DependencyModule.planGraph(from:)` keys visited modules by `ObjectIdentifier(module)`
- each distinct `FooModule()` allocation is treated as a distinct graph node
- `DependentModules { ... }` therefore behaves like transitive module installation, not like logical module requirements

That causes crashes like:

```text
Fatal error: Bolt: Duplicate registration for HybrdNetworking.APIClientProtocol (name: nil). Use withOverrides { ... } to replace in scoped contexts.
```

### Example failure

```swift
final class FeatureAModule: DependencyModule {
    override var body: ModuleDefinition {
        DependentModules {
            HybrdNetworkingModule()
        }

        Factory(FeatureAService.self) { resolver in
            FeatureAService(api: resolver.get())
        }
    }
}

final class FeatureBModule: DependencyModule {
    override var body: ModuleDefinition {
        DependentModules {
            HybrdNetworkingModule()
        }

        Factory(FeatureBService.self) { resolver in
            FeatureBService(api: resolver.get())
        }
    }
}

final class HybrdNetworkingModule: DependencyModule {
    override var body: ModuleDefinition {
        Singleton(HybrdNetworking.APIClientProtocol.self) { _ in
            LiveAPIClient()
        }
    }
}

Bolt.setup(modules: [
    FeatureAModule(),
    FeatureBModule(),
])
```

Under the current planner, Bolt sees:

- `FeatureAModule` instance A
- `HybrdNetworkingModule` instance A
- `FeatureBModule` instance B
- `HybrdNetworkingModule` instance B

Both networking module instances register the same dependency key, so container registration traps.

## Why WhoopDI is the right model here

Bolt's README already cites WhoopDI as inspiration, and WhoopDI's module traversal semantics are the right precedent for this fix.

### Relevant WhoopDI code

WhoopDI's `DependencyModule` exposes a public module identity:

```swift
open class DependencyModule {
    open var moduleDependencies: [DependencyModule] {
        []
    }

    open var serviceKey: ServiceKey {
        ServiceKey(type(of: self))
    }
}
```

WhoopDI's `DependencyTree` dedupes by that `serviceKey`:

```swift
final class DependencyTree {
    private var moduleSet: Set<ServiceKey> = []
    private var allModules: [DependencyModule] = []

    private func traverseTree(for module: DependencyModule) {
        if moduleSet.contains(module.serviceKey) { return }
        moduleSet.insert(module.serviceKey)

        module.moduleDependencies.forEach {
            traverseTree(for: $0)
        }

        allModules.append(module)
    }
}
```

And WhoopDI's tests explicitly override `serviceKey` to create distinct logical module identities for the same module type:

```swift
fileprivate class KeyedModule: DependencyModule {
    private let key: String
    private let keyedModuleDependencies: [DependencyModule]

    init(key: String, keyedModuleDependencies: [DependencyModule]) {
        self.key = key
        self.keyedModuleDependencies = keyedModuleDependencies
        super.init()
    }

    override var serviceKey: ServiceKey {
        ServiceKey(Self.self, name: key)
    }

    override var moduleDependencies: [DependencyModule] {
        keyedModuleDependencies
    }
}
```

That means WhoopDI supports both:

1. default coalescing by type, and
2. opt-in distinct identities by overriding `serviceKey`

Bolt should copy that model instead of inventing a new internal-only identity abstraction.

## Decision

Bolt should adopt the same module identity pattern as WhoopDI.

### Specifically

1. `DependencyModule` gets a public, overridable `serviceKey`.
2. The default implementation is `ServiceKey(type(of: self))`.
3. Graph planning dedupes modules by `serviceKey`.
4. The planner's cache is keyed by `serviceKey`.
5. The first discovered module for a given `serviceKey` wins.
6. Later modules with the same `serviceKey` are ignored.
7. If users need multiple logical modules of the same type in one graph, they can override `serviceKey`.
8. Because no backwards compatibility is required, Bolt should rename its existing public `Key` type to `ServiceKey`.

## Public API changes

## 1. Rename `Key` to `ServiceKey`

### Before

```swift
public struct Key: Hashable, Sendable {
    public let typeID: ObjectIdentifier
    public let name: String?

    public init<T>(_ type: T.Type, name: String? = nil)
}
```

### After

```swift
public struct ServiceKey: Hashable, Sendable {
    public let typeID: ObjectIdentifier
    public let name: String?

    public init(_ type: Any.Type, name: String? = nil)
}
```

Notes:

- The underlying implementation can stay as optimized as today's `Key` implementation.
- The important public change is the name and usage pattern.
- This keeps Bolt aligned with WhoopDI terminology.

## 2. Add `serviceKey` to `DependencyModule`

### Before

```swift
open class DependencyModule {
    public init() {}

    open var body: ModuleDefinition {
        ModuleDefinition()
    }
}
```

### After

```swift
open class DependencyModule {
    public init() {}

    open var serviceKey: ServiceKey {
        ServiceKey(type(of: self))
    }

    open var body: ModuleDefinition {
        ModuleDefinition()
    }
}
```

This is the core WhoopDI-style addition.

## 3. Same-type distinct modules become opt-in via `serviceKey`

### Default behavior: coalesce

```swift
final class NetworkModule: DependencyModule {}

Bolt.withModules([
    NetworkModule(),
    NetworkModule(),
]) {
    // Only one logical NetworkModule participates.
}
```

### Override behavior: distinct logical modules

```swift
final class APIFlavorModule: DependencyModule {
    let environment: String

    init(environment: String) {
        self.environment = environment
        super.init()
    }

    override var serviceKey: ServiceKey {
        ServiceKey(type(of: self), name: self.environment)
    }

    @ModuleBuilder
    override var body: ModuleDefinition {
        Singleton(String.self, named: self.environment) { _ in self.environment }
    }
}

Bolt.withModules([
    APIFlavorModule(environment: "prod"),
    APIFlavorModule(environment: "staging"),
]) {
    let prod: String = Bolt.inject(named: "prod")
    let staging: String = Bolt.inject(named: "staging")
    // Both participate because serviceKey is distinct.
}
```

That behavior is not a new Bolt-specific pattern. It is the same pattern WhoopDI already supports.

## Proposed runtime semantics

During `planGraph(from:)`:

- visited set is keyed by `ServiceKey`
- cycle detection stack is keyed by `ServiceKey`
- cached module definitions are keyed by `ServiceKey`
- `orderedModules` contains one representative module instance per unique `serviceKey`

### Consequences

#### 1. Shared dependent modules coalesce by default

```swift
final class FeatureAModule: DependencyModule {
    override var body: ModuleDefinition {
        DependentModules {
            NetworkModule()
        }
    }
}

final class FeatureBModule: DependencyModule {
    override var body: ModuleDefinition {
        DependentModules {
            NetworkModule()
        }
    }
}
```

`NetworkModule` is planned once because both instances share the default `serviceKey`.

#### 2. Duplicate top-level roots of the same type coalesce by default

```swift
Bolt.setup(modules: [
    NetworkModule(),
    NetworkModule(),
])
```

Only the first root wins.

#### 3. Same type can appear more than once when `serviceKey` differs

```swift
Bolt.setup(modules: [
    APIFlavorModule(environment: "prod"),
    APIFlavorModule(environment: "staging"),
])
```

Both participate because their `serviceKey`s differ.

#### 4. `DependentModules` becomes requirement-like in the common case

Feature modules may each declare `NetworkModule()` as a dependency without accidentally installing duplicate copies of the same logical module into the graph.

## Detailed code changes

## Diff: replace `Key` with `ServiceKey`

### `Sources/Bolt/Key.swift` -> `Sources/Bolt/ServiceKey.swift`

```diff
-import Foundation
-
-public struct Key: Hashable, Sendable {
-    public let typeID: ObjectIdentifier
-    public let name: String?
-
-    public init<T>(_ type: T.Type, name: String? = nil) {
-        self.typeID = normalizedTypeIdentifier(for: type)
-        self.name = name
-    }
-
-    var typeName: String {
-        lookupTypeName(for: self.typeID) ?? "<unknown>"
-    }
-}
+import Foundation
+
+public struct ServiceKey: Hashable, Sendable {
+    public let typeID: ObjectIdentifier
+    public let name: String?
+
+    public init(_ type: Any.Type, name: String? = nil) {
+        self.typeID = normalizedTypeIdentifier(for: type)
+        self.name = name
+    }
+
+    var typeName: String {
+        lookupTypeName(for: self.typeID) ?? "<unknown>"
+    }
+}
```

The supporting `normalizedTypeIdentifier` machinery can stay exactly as it is today.

## Diff: `Sources/Bolt/Registration.swift`

```diff
 public struct Registration {
-    public let key: Key
+    public let key: ServiceKey
     let shape: RegistrationShape
     let factory: ErasedFactory
     let singletonCell: SingletonCell?
 
-    init(key: Key, scope: Scope, factory: ErasedFactory) {
+    init(key: ServiceKey, scope: Scope, factory: ErasedFactory) {
         self.key = key
         self.shape = RegistrationShape(scope: scope, hasParameters: factory.parameterType != nil)
         self.factory = factory
@@
     var registration: Registration {
         Registration(
-            key: Key(self.type, name: self.name),
+            key: ServiceKey(self.type, name: self.name),
             scope: .factory,
             factory: ErasedFactory(
                 outputType: T.self,
@@
     var registration: Registration {
         Registration(
-            key: Key(self.type, name: self.name),
+            key: ServiceKey(self.type, name: self.name),
             scope: .singleton,
             factory: ErasedFactory(
                 outputType: T.self,
@@
     var registration: Registration {
         Registration(
-            key: Key(self.type, name: self.name),
+            key: ServiceKey(self.type, name: self.name),
             scope: .factory,
             factory: ErasedFactory(
                 outputType: T.self,
```

## Diff: `Sources/Bolt/DependencyModule.swift`

This is the main planner change.

```diff
 open class DependencyModule {
     public init() {}
+
+    open var serviceKey: ServiceKey {
+        ServiceKey(type(of: self))
+    }
 
     open var body: ModuleDefinition {
         ModuleDefinition()
     }
 }
@@
 struct ModulePlan {
     let orderedModules: [DependencyModule]
-    let definitionsByInstanceID: [ObjectIdentifier: ModuleDefinition]
+    let definitionsByServiceKey: [ServiceKey: ModuleDefinition]
 }
 
 extension DependencyModule {
     static func orderedModules(from roots: [DependencyModule]) throws -> [DependencyModule] {
         try planGraph(from: roots).orderedModules
     }
 
     static func planGraph(from roots: [DependencyModule]) throws -> ModulePlan {
-        var visitedInstances = Set<ObjectIdentifier>()
-        var stackTypeIDs: [ObjectIdentifier] = []
-        var stackTypeNames: [String] = []
+        var visitedServiceKeys = Set<ServiceKey>()
+        var stackServiceKeys: [ServiceKey] = []
+        var stackDescriptions: [String] = []
         var ordered: [DependencyModule] = []
-        var definitionsByInstanceID: [ObjectIdentifier: ModuleDefinition] = [:]
+        var definitionsByServiceKey: [ServiceKey: ModuleDefinition] = [:]
 
         func visit(_ module: DependencyModule) throws {
-            let instanceID = ObjectIdentifier(module)
-            if visitedInstances.contains(instanceID) { return }
+            let serviceKey = module.serviceKey
+            if visitedServiceKeys.contains(serviceKey) { return }
 
-            let typeID = ObjectIdentifier(type(of: module))
-            let typeName = String(reflecting: type(of: module))
-            if let cycleStart = stackTypeIDs.lastIndex(of: typeID) {
-                let path = Array(stackTypeNames[cycleStart...]) + [typeName]
+            let description = "\(serviceKey.typeName) (name: \(serviceKey.name.map { \"\"\($0)\"\" } ?? \"nil\"))"
+            if let cycleStart = stackServiceKeys.lastIndex(of: serviceKey) {
+                let path = Array(stackDescriptions[cycleStart...]) + [description]
                 throw ModuleGraphError.cycle(path: path)
             }
 
-            stackTypeIDs.append(typeID)
-            stackTypeNames.append(typeName)
+            stackServiceKeys.append(serviceKey)
+            stackDescriptions.append(description)
 
             let definition = module.body
-            definitionsByInstanceID[instanceID] = definition
+            definitionsByServiceKey[serviceKey] = definition
 
             for dependency in definition.dependentModules {
                 try visit(dependency)
             }
 
-            _ = stackTypeIDs.popLast()
-            _ = stackTypeNames.popLast()
-            visitedInstances.insert(instanceID)
+            _ = stackServiceKeys.popLast()
+            _ = stackDescriptions.popLast()
+            visitedServiceKeys.insert(serviceKey)
             ordered.append(module)
         }
 
         for root in roots {
             try visit(root)
         }
 
         return ModulePlan(
             orderedModules: ordered,
-            definitionsByInstanceID: definitionsByInstanceID
+            definitionsByServiceKey: definitionsByServiceKey
         )
     }
 }
```

### Notes on cycle detection

The cycle detector should operate on logical module identity, which is now `serviceKey`.

That means:

- a repeated reference to the same logical module already on the active stack is a cycle
- a repeated reference to the same logical module after it has already been planned is just deduplication
- same concrete type with different `serviceKey`s are treated as different graph nodes

That is the correct behavior once `serviceKey` becomes the planner's identity primitive.

## Diff: `Sources/Bolt/Bolt.swift`

```diff
         for module in plan.orderedModules {
-            let instanceID = ObjectIdentifier(module)
-            guard let definition = plan.definitionsByInstanceID[instanceID] else {
+            guard let definition = plan.definitionsByServiceKey[module.serviceKey] else {
                 fatalError("Bolt: Internal error: missing module definition cache.")
             }
             container.register(definition.registrations)
         }
```

## Diff: `Sources/Bolt/Validation.swift`

```diff
         do {
             let plan = try DependencyModule.planGraph(from: modules)
             for module in plan.orderedModules {
-                let instanceID = ObjectIdentifier(module)
-                guard let definition = plan.definitionsByInstanceID[instanceID] else {
+                guard let definition = plan.definitionsByServiceKey[module.serviceKey] else {
                     fatalError("Bolt: Internal error: missing module definition cache.")
                 }
                 container.register(definition.registrations)
             }
```

## Diff: `Sources/Bolt/Container.swift`

This is mostly a mechanical rename from `Key` to `ServiceKey`.

Representative diff:

```diff
 public final class Container: Resolver, @unchecked Sendable {
@@
-    private var mutableRegistrations: [Key: Registration] = [:]
+    private var mutableRegistrations: [ServiceKey: Registration] = [:]
@@
-        let key = Key(type, name: named)
+        let key = ServiceKey(type, name: named)
@@
-    func effectiveRegistrationsForValidation() -> [Key: Registration] {
-        var registrations: [Key: Registration] = [:]
+    func effectiveRegistrationsForValidation() -> [ServiceKey: Registration] {
+        var registrations: [ServiceKey: Registration] = [:]
@@
-    private func lookupRegistration(for key: Key) -> Registration? {
+    private func lookupRegistration(for key: ServiceKey) -> Registration? {
@@
-    private static func duplicateRegistrationMessage(for key: Key) -> String {
+    private static func duplicateRegistrationMessage(for key: ServiceKey) -> String {
@@
-    private static func missingRegistrationMessage(for key: Key) -> String {
+    private static func missingRegistrationMessage(for key: ServiceKey) -> String {
@@
-    private static func circularDependencyMessage(for keys: [Key]) -> String {
+    private static func circularDependencyMessage(for keys: [ServiceKey]) -> String {
@@
-    private static func dependencyDescription(_ key: Key) -> String {
+    private static func dependencyDescription(_ key: ServiceKey) -> String {
```

The rest of the container changes are straightforward mechanical replacements.

## Test plan

## Tests to remove or rewrite

Bolt currently has tests/specs that encode instance-based semantics.

### Existing test that must change

`Tests/BoltTests/BoltSetupAndOverrideTests.swift`

Current test:

```swift
@Test func withModulesRunsDistinctModuleInstancesEvenWhenTypesMatch() {
    Bolt.withModules([LabeledModule(label: "A"), LabeledModule(label: "B")]) {
        let first: String = Bolt.inject(named: "A")
        let second: String = Bolt.inject(named: "B")

        #expect(first == "A")
        #expect(second == "B")
    }
}
```

That encodes the behavior we are explicitly replacing.

## Replacement tests

### 1. Default same-type modules coalesce by `serviceKey`

```swift
private final class LabeledModule: DependencyModule {
    let label: String

    init(label: String) {
        self.label = label
        super.init()
    }

    @ModuleBuilder
    override var body: ModuleDefinition {
        Factory(String.self, named: self.label) { _ in self.label }
    }
}

@Test func withModulesCoalescesDuplicateTopLevelModulesByDefaultServiceKey() {
    Bolt.withModules([LabeledModule(label: "A"), LabeledModule(label: "B")]) {
        let a: String = Bolt.inject(named: "A")
        #expect(a == "A")

        let validator = BoltValidator(modules: [LabeledModule(label: "A"), LabeledModule(label: "B")])
        var errors: [ValidationError] = []
        validator.validate { error in
            errors.append(error)
        }
        #expect(errors.isEmpty)
    }
}
```

Test intent:

- both modules share the default `serviceKey`
- planner keeps the first one
- second one is ignored
- no duplicate-registration error occurs

### 2. Same concrete type can participate twice when `serviceKey` is overridden

```swift
private final class KeyedLabeledModule: DependencyModule {
    let label: String

    init(label: String) {
        self.label = label
        super.init()
    }

    override var serviceKey: ServiceKey {
        ServiceKey(type(of: self), name: self.label)
    }

    @ModuleBuilder
    override var body: ModuleDefinition {
        Factory(String.self, named: self.label) { _ in self.label }
    }
}

@Test func withModulesAllowsSameConcreteTypeMultipleTimesWhenServiceKeyDiffers() {
    Bolt.withModules([
        KeyedLabeledModule(label: "A"),
        KeyedLabeledModule(label: "B"),
    ]) {
        let a: String = Bolt.inject(named: "A")
        let b: String = Bolt.inject(named: "B")
        #expect(a == "A")
        #expect(b == "B")
    }
}
```

This is the direct WhoopDI-style escape hatch.

### 3. Shared dependent module type is coalesced by default

```swift
private final class SharedNetworkingModule: DependencyModule {
    let source: String

    init(source: String) {
        self.source = source
        super.init()
    }

    @ModuleBuilder
    override var body: ModuleDefinition {
        Singleton(String.self, named: "api-client-source") { _ in self.source }
    }
}

private final class FeatureUsingSharedNetworkingModule: DependencyModule {
    let featureName: String

    init(featureName: String) {
        self.featureName = featureName
        super.init()
    }

    @ModuleBuilder
    override var body: ModuleDefinition {
        DependentModules {
            SharedNetworkingModule(source: self.featureName)
        }

        Factory(String.self, named: self.featureName) { _ in self.featureName }
    }
}

@Test func dependentModulesCoalesceByDefaultServiceKey() {
    Bolt.withModules([
        FeatureUsingSharedNetworkingModule(featureName: "feature-a"),
        FeatureUsingSharedNetworkingModule(featureName: "feature-b"),
    ]) {
        let source: String = Bolt.inject(named: "api-client-source")
        #expect(source == "feature-a")
    }
}
```

This verifies first-discovered wins for shared transitive modules.

### 4. Same dependent module type can appear twice when `serviceKey` differs

```swift
private final class KeyedSharedNetworkingModule: DependencyModule {
    let source: String

    init(source: String) {
        self.source = source
        super.init()
    }

    override var serviceKey: ServiceKey {
        ServiceKey(type(of: self), name: self.source)
    }

    @ModuleBuilder
    override var body: ModuleDefinition {
        Singleton(String.self, named: self.source) { _ in self.source }
    }
}

private final class FeatureUsingKeyedNetworkingModule: DependencyModule {
    let featureName: String

    init(featureName: String) {
        self.featureName = featureName
        super.init()
    }

    @ModuleBuilder
    override var body: ModuleDefinition {
        DependentModules {
            KeyedSharedNetworkingModule(source: self.featureName)
        }
    }
}

@Test func dependentModulesAllowSameConcreteTypeWhenServiceKeyDiffers() {
    Bolt.withModules([
        FeatureUsingKeyedNetworkingModule(featureName: "feature-a"),
        FeatureUsingKeyedNetworkingModule(featureName: "feature-b"),
    ]) {
        let a: String = Bolt.inject(named: "feature-a")
        let b: String = Bolt.inject(named: "feature-b")
        #expect(a == "feature-a")
        #expect(b == "feature-b")
    }
}
```

### 5. Planner evaluates one body per unique `serviceKey`

```swift
private final class CountingModule: DependencyModule {
    private let counter: PlannerEvaluationCounter
    private let keyName: String?

    init(counter: PlannerEvaluationCounter, keyName: String? = nil) {
        self.counter = counter
        self.keyName = keyName
        super.init()
    }

    override var serviceKey: ServiceKey {
        if let keyName {
            return ServiceKey(type(of: self), name: keyName)
        }
        return super.serviceKey
    }

    override var body: ModuleDefinition {
        self.counter.increment()
        return ModuleDefinition(
            registrations: [Factory(Int.self, named: keyName) { _ in 1 }.registration]
        )
    }
}

@Test func plannerEvaluatesOneBodyPerUniqueServiceKey() {
    let sharedCounter = PlannerEvaluationCounter()
    _ = BoltValidator(modules: [
        CountingModule(counter: sharedCounter),
        CountingModule(counter: sharedCounter),
    ])
    #expect(sharedCounter.count() == 1)

    let distinctCounter = PlannerEvaluationCounter()
    _ = BoltValidator(modules: [
        CountingModule(counter: distinctCounter, keyName: "A"),
        CountingModule(counter: distinctCounter, keyName: "B"),
    ])
    #expect(distinctCounter.count() == 2)
}
```

## Documentation changes

## README updates

Current README says:

```md
- Use `DependentModules { ... }` inside `DependencyModule.body` to declare transitive module requirements.
```

That line can remain, but README should explicitly document the WhoopDI-style identity rule.

### Proposed README diff

```diff
 - Use `DependentModules { ... }` inside `DependencyModule.body` to declare transitive module requirements.
+
+Dependent module planning uses WhoopDI-style `serviceKey` identity:
+- each module has a `serviceKey`
+- the default `serviceKey` is `ServiceKey(type(of: self))`
+- repeated modules with the same `serviceKey` are coalesced during graph planning
+- the first discovered module for a given `serviceKey` wins
+- if you need multiple logical modules of the same concrete type, override `serviceKey` to make them distinct
```

### README example to add

```swift
final class APIFlavorModule: DependencyModule {
    let environment: String

    init(environment: String) {
        self.environment = environment
        super.init()
    }

    override var serviceKey: ServiceKey {
        ServiceKey(type(of: self), name: self.environment)
    }

    @ModuleBuilder
    override var body: ModuleDefinition {
        Singleton(String.self, named: self.environment) { _ in self.environment }
    }
}
```

## Spec cleanup needed elsewhere

These docs currently encode the old instance-based model and should be updated if this spec is implemented:

- `specs/BOLT_MODULE_BODY_SPEC.md`
- `specs/BOLT_TESTING_ERGONOMICS_PLAN.md`
- `specs/BOLT_DI_SPEC.md`
- any README/tests referring to preservation of distinct module instances by allocation identity

## Acceptance criteria

1. Bolt no longer traps when two composed modules each declare the same dependent module type with the default `serviceKey`.
2. Graph planning coalesces modules by `serviceKey` instead of by object identity.
3. `DependencyModule` exposes public `serviceKey`, matching WhoopDI's pattern.
4. Bolt uses `ServiceKey` terminology publicly instead of `Key`.
5. Same concrete module type can appear multiple times when `serviceKey` is overridden to be distinct.
6. Existing tests/specs that rely on distinct-instance-by-allocation semantics are replaced.
7. `Bolt.setup` and `BoltValidator` both consume the same `serviceKey`-based planner output.

## Suggested implementation checklist

1. Rename public `Key` to `ServiceKey` across Bolt.
2. Add `open var serviceKey: ServiceKey` to `DependencyModule`.
3. Update `DependencyModule.planGraph(from:)` to dedupe and cache by `serviceKey`.
4. Update `Bolt.setup` to read planned definitions by `module.serviceKey`.
5. Update `BoltValidator` the same way.
6. Replace tests that assert same-type distinct-instance preservation by allocation identity.
7. Add tests for:
   - duplicate top-level same-type modules coalescing by default `serviceKey`
   - duplicate transitive same-type modules coalescing by default `serviceKey`
   - same concrete type participating twice when `serviceKey` differs
   - planner evaluating once per unique `serviceKey`
8. Update README and related specs to describe the WhoopDI-style `serviceKey` semantics.
