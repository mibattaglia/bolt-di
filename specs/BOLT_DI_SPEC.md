# Bolt Dependency Injection Framework Spec (v1)

Date: 2026-02-11

## Implementation Status
- [x] Phase 1: Package bootstrap (SPM + CocoaPods skeleton)
- [x] Phase 2: Core model and registration DSL surface
- [x] Phase 3: Container engine (strict mode)
- [x] Phase 4: Override and task-local scoping
- [x] Phase 5: Bolt facade and property wrappers
- [x] Phase 6: Validation subsystem
- [x] Phase 7: Full test suite and packaging finish

Phase 7 validation note:
- `swift package clean && xcrun swift test` completed successfully.
- `pod lib lint` could not be executed in this environment because CocoaPods CLI (`pod`) is not installed.

Related design plan:
- Testing ergonomics expansion: `specs/BOLT_TESTING_ERGONOMICS_PLAN.md`

## References
- https://github.com/WhoopInc/WhoopDI
- https://github.com/hmlongco/Factory
- https://github.com/pointfreeco/swift-dependencies

## Goals
- Provide a fast, lightweight DI framework for Swift with runtime resolution errors.
- Support cross-module dependency registration and resolution.
- Provide ergonomic property wrappers and a required result-builder DSL for registration.
- Support local/scoped dependency injection for tests and production call-site customization.
- Support parameterized dependency resolution (runtime arguments at `get`/`inject` call time).
- Support dependency lifecycles: v1 includes `factory` and `singleton`; API must allow future `cached` and `graph`.
- Provide container-based scoping and task-local override management.
- Provide CocoaPods support (hard requirement), plus SPM.
- Provide validation tooling for tests (WhoopDIValidator-style).

## Non-goals (v1)
- Macros or code generation.
- Compile-time dependency checking.
- Automatic registration scanning/reflection.

## Terminology
- **Registration**: A mapping from a key (type + optional name) to a factory closure and scope.
- **Container**: Owns registrations, override layers, and scope storage.
- **Module**: A logical collection of registrations. Modules are additive.
- **Override layer**: A higher-priority registration set used for tests or localized overrides.
- **Local injection**: Temporarily applying scoped registrations for one lexical operation.
- **Parameterized registration**: A registration whose factory consumes runtime arguments during resolution.
- **Dependency descriptor**: Public error-facing identifier (`typeName` + optional `name`) used in validation output.

## Public API Surface

### Core Types
```swift
public struct ServiceKey: Hashable {
    public let typeID: ObjectIdentifier
    public let name: String?
}

public enum Scope {
    case factory
    case singleton
    // Future: cached, graph
}

public protocol Resolver {
    func get<T>(_ type: T.Type = T.self, named: String? = nil) -> T
    func get<T, P>(_ type: T.Type = T.self, named: String? = nil, params: P) -> T
}
```

### Facade
```swift
public enum Bolt {
    public static var shared: Container { get }

    public static func setup(modules: [DependencyModule])
    public static func withModules<R>(
        _ modules: [DependencyModule],
        _ body: () throws -> R
    ) rethrows -> R
    public static func withModules<R>(
        _ modules: [DependencyModule],
        _ body: () async throws -> R
    ) async rethrows -> R

    // Convenience crash-on-failure API for app runtime ergonomics.
    public static func inject<T>(_ type: T.Type = T.self, named: String? = nil) -> T
    public static func inject<T, P>(_ type: T.Type = T.self, named: String? = nil, params: P) -> T

    public static func withContainer<R>(_ container: Container, _ body: () throws -> R) rethrows -> R
    public static func withContainer<R>(_ container: Container, _ body: () async throws -> R) async rethrows -> R
    public static func withOverrides<R>(
        @DependencyBuilder _ overrides: () -> [Registration],
        _ body: () throws -> R
    ) rethrows -> R
    public static func withOverrides<R>(
        @DependencyBuilder _ overrides: () -> [Registration],
        _ body: () async throws -> R
    ) async rethrows -> R
}
```

### Container
```swift
public final class Container: Resolver {
    public static var current: Container { get }

    public init()

    // Public registration API (DSL only).
    public func register(@DependencyBuilder _ registrations: () -> [Registration])

    // Primary resolution API (crash-on-failure).
    public func get<T>(_ type: T.Type = T.self, named: String? = nil) -> T
    public func get<T, P>(_ type: T.Type = T.self, named: String? = nil, params: P) -> T

    public func resetScopes()
    public func resetAll()
}
```

### DependencyModule
```swift
open class DependencyModule {
    public init() {}

    open var serviceKey: ServiceKey { get }
    open var body: ModuleDefinition { get }
}
```

### Property Wrappers
```swift
@propertyWrapper
public struct Injected<T> {
    public init(_ type: T.Type = T.self, named: String? = nil)
    public var wrappedValue: T { get }
}
```

### Result-Builder DSL
```swift
@resultBuilder
public enum DependencyBuilder {
    public static func buildBlock(_ components: Registration...) -> [Registration]
    public static func buildExpression<T>(_ expression: Factory<T>) -> Registration
    public static func buildExpression<T>(_ expression: Singleton<T>) -> Registration
    public static func buildExpression<P, T>(_ expression: FactoryWithParams<P, T>) -> Registration
}

public struct Registration {
    // Internal metadata; erased factory storage remains internal to keep API flexible.
    let key: ServiceKey
    let scope: Scope
}

public struct Factory<T> {
    public init(
        _ type: T.Type = T.self,
        named: String? = nil,
        _ factory: @escaping (Resolver) -> T
    )
    var registration: Registration { get }
}

public struct Singleton<T> {
    public init(
        _ type: T.Type = T.self,
        named: String? = nil,
        _ factory: @escaping (Resolver) -> T
    )
    var registration: Registration { get }
}

public struct FactoryWithParams<P, T> {
    public init(
        _ type: T.Type = T.self,
        named: String? = nil,
        _ factory: @escaping (Resolver, P) -> T
    )
    var registration: Registration { get }
}
```

### Validator (Testing)
```swift
public struct BoltValidator {
    // Validate already-built container.
    public init(container: Container)

    // Validate module graph before calling Bolt.setup (enables duplicate detection without traps).
    public init(modules: [DependencyModule])

    public func validate(_ onError: (ValidationError) -> Void)
}

public struct ValidationError: Error {
    public struct DependencyDescriptor: Hashable {
        public let typeName: String
        public let name: String?
    }

    public enum Kind {
        case duplicateRegistration
        case missingRegistration
        case typeMismatch
        case circularDependency
    }

    public let kind: Kind
    public let dependency: DependencyDescriptor?
    public let message: String
}
```

## ServiceKey Design Points

### 1) Keying and Resolution
- Dependency lookup uses `ServiceKey(type, name: String?)`.
- `ServiceKey` uses normalized type identity for O(1) lookup and stable cross-module matching.
- `name` is optional and string-based.
- Parameterized and non-parameterized registrations share the same key model.
- A service key may have only one registration definition (mixing `Factory`, `Singleton`, and `FactoryWithParams` for the same key is invalid).

### 2) Registration Rules
- `register { ... }` adds registrations to the base registry.
- Duplicate keys in base registry are runtime traps in strict registration APIs.
- `withOverrides { ... }` adds higher-priority temporary registrations.
- Duplicate keys inside one override layer are reported as validation errors and can trap in debug.
Public API shape:
- A single public registration type (`Registration`) is used for both base and override builders.
- Consumers use the same `Factory`/`Singleton` DSL in both `register { ... }` and `withOverrides { ... }`.
- `Factory` and `Singleton` are struct-based builders configured via initializers in v1 (no fluent modifier API yet).
Internal model:
- Container converts override registrations into internal override-layer entries.
- Internal override entries own separate singleton caches and optional override-only metadata.
- Container has internal-only override layer operations used by `withOverrides`.

### 3) Crash-on-failure Resolution Surface
- `Container.get`, `Bolt.inject()`, and `@Injected` are crash-on-failure by design.
- `Resolver` exposes one method (`get`) for API simplicity and consistent call sites.
- Parameterized resolution uses the same crash behavior via `get(..., params:)` / `inject(..., params:)`.
- Non-crashing diagnostics are provided by validator tooling rather than throwing resolution APIs.

### 4) Resolution Order and Scope Behavior
- Resolve from topmost override layer to bottom, then base registry.
- `factory`: evaluate closure every time.
- `singleton`: cache per registration owner.
Owner rules:
- Base registration singleton cache lives in base scope storage.
- Override registration singleton cache lives in that override layer.
- Popping an override layer destroys that layer's singleton cache.
- This prevents test override singletons from leaking after `withOverrides`.
Parameterized registration rules:
- Parameterized entries are represented by `FactoryWithParams`.

### 5) Module Setup
- `Bolt.setup(modules:)` creates a new container, applies modules in order, and assigns `Bolt.shared`.
- Modules may resolve previously registered dependencies during setup.
- Ordering is explicit and deterministic.
- In debug builds, overlapping `Bolt.setup(modules:)` calls fail fast with an actionable message to use `Bolt.withModules`.
- `Bolt.withModules` builds the same planned module graph but scopes it lexically/task-locally via `withContainer`.
- Combine `Bolt.withModules` with nested `Bolt.withOverrides` when tests need a fresh graph plus a few overrides.
- `Bolt.withModules` does not mutate `Bolt.shared` and is the recommended test setup path.

### 6) Task-Local Container
- `Container.current` uses `@TaskLocal`, defaulting to `Bolt.shared`.
- `Bolt.withContainer` swaps task-local container in lexical scope.
- `Bolt.withOverrides` pushes and pops a layer with `defer` cleanup semantics.
- `withOverrides` is Bolt's local injection mechanism (WhoopDI-style scoped local definitions).

### 7) Concurrency Model Recommendation
Recommendation based on references:
- Use `final class Container` + internal lock-based synchronization for mutable state.
- Keep task-local selection (`@TaskLocal`) for contextual overrides.

Why this recommendation:
- Factory and WhoopDI both use lock-backed container state.
- swift-dependencies uses task-local context plus lock-isolated mutable storage.
- This keeps synchronous API ergonomics (`get()` and property wrappers) without forcing `async`/`await` or actor isolation in all call sites.

Implementation notes:
- Use one private lock for registry/override/scope state.
- Do not hold lock while executing user factory closures.
- Reacquire lock only for compare-and-store singleton path.
- Track a per-resolution stack to detect circular dependency recursion.

### 8) Validation
- `BoltValidator(container:)` verifies resolvability and type correctness for current registrations.
- `BoltValidator(modules:)` runs modules through a non-fatal collector mode to report duplicates and graph issues without runtime traps.
- Validation reports all errors via callback so tests can assert exact failures.
Parameterized validation behavior:
- Validator checks registration shape and key collisions for parameterized entries.
- Validator can only fully execute parameterized factories when provided sample parameter values.
- v1 validator does not auto-generate parameter samples; teams may add targeted resolution tests for parameterized dependencies.
Internal validation mechanics:
- Container exposes an internal resolution path that returns structured failure data instead of trapping.
- Container registration has an internal validation mode (`.strict` vs `.collecting`) used only by validator.
- `Bolt.setup` and public runtime APIs always use `.strict`; validator uses `.collecting`.

## Testing Strategy

### A) Framework Tests (Bolt package)
- Registration and resolution:
Verify factory returns new instance each call and singleton returns same instance.
- Error semantics:
Assert crash behavior/messages for missing registration and type mismatch, and assert validator emits structured errors.
- Crash wrappers:
Test `inject`/`get`/`@Injected` crash messages in dedicated crash tests.
- Override layering:
Verify top-layer wins, nesting works, and pop restores previous behavior.
- Override singleton isolation:
Ensure singleton created in override is dropped after pop.
- Local injection behavior:
Verify `withOverrides` changes resolution only within lexical scope.
- Task-local behavior:
Confirm `withContainer` and `withOverrides` apply only within scoped operation.
- Validation:
Confirm validator catches duplicate registrations, missing dependencies, and cycles.
- Concurrency stress:
Resolve singletons/factories from concurrent tasks and assert no races and no duplicate singleton initialization.
- Parameterized resolution:
Verify `FactoryWithParams` resolves correctly for multiple parameter values.

### B) Client Testing Ergonomics
- Encourage test-local graphs/containers rather than mutating shared global state.
- Prefer `Bolt.withModules([FeatureModule()])` for single-root feature module tests.
- Prefer `Bolt.withModules([...])` when graph shape should remain explicit at the call site.
- Use nested `withModules` + `withOverrides`, or `withContainer` + `withOverrides`, for per-test overrides.
- Use behavior-level assertions for resolved dependencies and run validator for graph diagnostics.
- Add targeted tests for parameterized dependencies with representative parameter values.
- Run `BoltValidator(modules:)` in a smoke test to catch graph regressions early.
- Planned Swift Testing ergonomics can live in a separate `BoltTestSupport` product exposed through a versioned manifest overlay; see `specs/BOLT_TESTING_ERGONOMICS_PLAN.md`.
- Treat `Bolt.setup` as app bootstrap API. If used in tests for explicit global smoke coverage, serialize those tests.

## CocoaPods and SPM Packaging
- Ship as Swift package target `Bolt`.
- Ship `Bolt.podspec` exposing same sources and module name.
- No macros.
- Minimum deployment targets: iOS 17, watchOS 10, macOS 15.
- Planned testing ergonomics expansion may add a SwiftPM-only `BoltTestSupport` product via `Package@swift-6.2.swift`; see `specs/BOLT_TESTING_ERGONOMICS_PLAN.md`.

## Example Usage

### 1) Basic module registration
```swift
final class NetworkModule: DependencyModule {
    override var body: ModuleDefinition {
        Singleton { _ in
            APIClient(baseURL: URL(string: "https://api.example.com")!)
        }

        Factory { resolver in
            UserService(api: resolver.get(APIClient.self, named: nil))
        }
    }
}
```

### 2) DSL registration in a module
```swift
final class AppModule: DependencyModule {
    override var body: ModuleDefinition {
        Singleton { _ in LiveAnalytics() }

        Factory { resolver in
            AppCoordinator(
                analytics: resolver.get(AnalyticsService.self, named: nil),
                userService: resolver.get(UserService.self, named: nil)
            )
        }
    }
}
```

### 3) Named registrations
```swift
final class APIFlavorModule: DependencyModule {
    override var body: ModuleDefinition {
        Singleton(named: "live") { _ in
            APIClient(baseURL: URL(string: "https://api.example.com")!)
        }

        Singleton(named: "staging") { _ in
            APIClient(baseURL: URL(string: "https://staging-api.example.com")!)
        }
    }
}
```

### 4) App setup
```swift
Bolt.setup(modules: [NetworkModule(), AppModule(), APIFlavorModule()])
let service: UserService = Bolt.inject()
```

### 5) Production consumer invocation patterns
```swift
// Option A: facade lookup
let service: UserService = Bolt.inject()

// Option B: explicit current container lookup
let analytics: AnalyticsService = Container.current.get()

// Option C: named dependency
let liveAPI: APIClient = Bolt.inject(named: "live")
```

```swift
final class FeatureViewModel {
    @Injected private var service: UserService
    @Injected(named: "live") private var api: APIClient
}
```

### 6) Production local injection (scoped)
```swift
func performPreviewRequest(token: String) -> UserService {
    Bolt.withOverrides {
        Factory { _ in AuthToken(rawValue: token) }
    } {
        Bolt.inject(UserService.self)
    }
}
```

### 7) Parameterized registration + resolution
```swift
final class SessionModule: DependencyModule {
    override var body: ModuleDefinition {
        FactoryWithParams(String.self, named: "greeting") { _, name in
            "Hello, \(name)!"
        }
    }
}

Bolt.setup(modules: [SessionModule()])
let greeting: String = Bolt.inject(named: "greeting", params: "Michael")
```

### 8) Client test with scoped module graph and overrides
```swift
@Test
func featureModule_usesMockAPI() {
    Bolt.withModules([FeatureModule()]) {
        Bolt.withOverrides {
            Singleton(APIClient.self) { _ in MockAPIClient() }
        } _: {
            let service: UserService = Bolt.inject()
            #expect(service.api is MockAPIClient)
        }
    }
}
```

### 9) Client test with scoped container overrides
```swift
@Test
func userService_usesMockAPI() {
    let container = Container()
    container.register {
        Singleton { _ in APIClient(baseURL: URL(string: "https://api.example.com")!) }
        Factory { resolver in UserService(api: resolver.get(APIClient.self, named: nil)) }
    }

    Bolt.withContainer(container) {
        Bolt.withOverrides {
            Singleton { _ in MockAPIClient() }
        } {
            let service = container.get(UserService.self)
            #expect(service.api is MockAPIClient)
        }
    }
}
```

### 10) Graph validation test
```swift
@Test
func dependencyGraph_isValid() {
    let validator = BoltValidator(modules: [NetworkModule(), AppModule(), APIFlavorModule()])
    validator.validate { error in
        Issue.record("Bolt validation failed: \(error.message)")
    }
}
```

## Error Messages (Examples)
- Missing dependency:
`Bolt: Missing registration for APIClient (name: nil).`
- Duplicate registration:
`Bolt: Duplicate registration for AnalyticsService (name: "live"). Use withOverrides { ... } to replace in scoped contexts.`
- Circular dependency:
`Bolt: Circular dependency detected: A -> B -> C -> A.`

## Risks and Mitigations

### Risk: Global shared container + task-local container drift
- **Issue**: App code may accidentally resolve from `Bolt.shared` while tests expect task-local overrides.
- **Mitigation**: Ensure `Container.current` is always used by `Bolt.inject()` and `@Injected`.

### Risk: Override stack misuse
- **Issue**: Forgetting to pop overrides can leak into subsequent tests.
- **Mitigation**: Use `withOverrides { ... }` and `withContainer { ... }` only; avoid manual push/pop in app code.

### Risk: Duplicate base registrations
- **Issue**: Some frameworks silently override.
- **Mitigation**: strict runtime traps + preflight `BoltValidator(modules:)`.

### Risk: Cross-module ordering dependencies
- **Issue**: Modules may rely on preceding modules.
- **Mitigation**: Keep module order explicit and document expected ordering.

## Future Extensions (Non-breaking)
- Add scopes: `cached` and `graph`.
- Add named scopes (e.g. `"session"`).
- Add `@LazyInjected` and `@InjectedObject` for SwiftUI-focused usage.
- Add optional macro package in a separate module.
