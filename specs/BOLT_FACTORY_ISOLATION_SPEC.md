# Bolt Factory Isolation Spec

Date: 2026-05-01
Status: Draft

## Target behavior

Bolt factory resolution remains synchronous while allowing factory registrations to require actor isolation. V1 focuses on `MainActor` public ergonomics and keeps the internal plumbing generic enough to support other actors later.

Required user-facing examples:

```swift
@MainActor
final class ImageLoader {
    init() {}
}

final class UIModule: DependencyModule {
    @ModuleBuilder
    override var body: ModuleDefinition {
        Factory(on: MainActor.self) { _ in
            ImageLoader()
        }
    }
}

@MainActor
func makeFeature() {
    let loader: ImageLoader = Bolt.inject()
}
```

No `async` `Bolt.inject` / `Container.get` APIs are added. Bolt must not internally hop actors with `await MainActor.run`, `Task`, dispatch sync, semaphores, or blocking.

## Explicit scope

Implement:

- `Factory` isolation.
- `FactoryWithParams` isolation, because it is factory-scoped and has the same construction problem.
- `#isolation` capture on factory registration and resolution.
- `Factory(on: MainActor.self)` and `FactoryWithParams(on: MainActor.self)` for nonisolated module bodies.
- Generic internal actor-isolation identity based on `ServiceKey`, not reflection-only strings.

Do not implement in this spec:

- `Singleton` isolation.
- property-wrapper isolation.
- async resolution APIs.
- custom global-actor explicit overloads such as `Factory(on: MyActor.self)`.

## Internal model

Use `ServiceKey` to identify actor types. Do not store `String(reflecting:)` as the primary identity for actor isolation.

Add this to `Sources/Bolt/Registration.swift` near the other internal registration types:

```swift
struct ActorIsolationIdentity: Equatable, Sendable {
    let actorKey: ServiceKey
    let instanceID: ObjectIdentifier

    var description: String {
        self.actorKey.typeName
    }
}

enum RegistrationIsolation: Equatable, Sendable {
    case none
    case actor(ActorIsolationIdentity)

    static func capture(_ isolation: isolated (any Actor)?) -> RegistrationIsolation {
        guard let isolation else { return .none }
        return .actor(
            ActorIsolationIdentity(
                actorKey: ServiceKey(Swift.type(of: isolation)),
                instanceID: ObjectIdentifier(isolation as AnyObject)
            )
        )
    }

    static var mainActor: RegistrationIsolation {
        .actor(
            ActorIsolationIdentity(
                actorKey: ServiceKey(MainActor.self),
                instanceID: ObjectIdentifier(MainActor.shared)
            )
        )
    }

    var description: String {
        switch self {
        case .none:
            return "nonisolated"
        case .actor(let identity):
            return identity.description
        }
    }
}
```

Rationale:

- `ServiceKey` already gives Bolt stable type identity and readable type names through its intern table.
- `instanceID` keeps the internal model correct for future actor-instance isolation. Two actor instances of the same type should not be treated as the same isolation domain.
- V1 public APIs only expose `MainActor`, but this shape avoids a `case mainActor` dead end.

## Phase 1 — Registration storage

### File: `Sources/Bolt/Registration.swift`

Replace `Registration` with an isolation-aware version:

```swift
public struct Registration {
    public let key: ServiceKey
    let shape: RegistrationShape
    let isolation: RegistrationIsolation
    let factory: ErasedFactory
    let singletonCell: SingletonCell?

    init(key: ServiceKey, scope: Scope, isolation: RegistrationIsolation, factory: ErasedFactory) {
        self.key = key
        self.shape = RegistrationShape(scope: scope, hasParameters: factory.parameterType != nil)
        self.isolation = isolation
        self.factory = factory
        switch scope {
        case .factory:
            self.singletonCell = nil
        case .singleton:
            self.singletonCell = SingletonCell()
        }
    }
}
```

Update all call sites of `Registration(...)` in this file to pass `isolation:`.

### `Factory` implicit isolation

Replace the current stored properties and initializer for `Factory<T>` with:

```swift
public struct Factory<T> {
    private let type: T.Type
    private let name: String?
    private let isolation: RegistrationIsolation
    private let factory: (Resolver) -> T

    public init(
        _ type: T.Type = T.self,
        named: String? = nil,
        isolation: isolated (any Actor)? = #isolation,
        _ factory: @escaping (Resolver) -> T
    ) {
        self.type = type
        self.name = named
        self.isolation = .capture(isolation)
        self.factory = factory
    }

    var registration: Registration {
        Registration(
            key: ServiceKey(self.type, name: self.name),
            scope: .factory,
            isolation: self.isolation,
            factory: ErasedFactory(
                outputType: T.self,
                parameterType: nil,
                call: { resolver, _ in self.factory(resolver) }
            )
        )
    }
}
```

Commentary:

- Existing calls like `Factory { _ in Service() }` remain valid.
- When called inside `@MainActor` or another actor-isolated context, `#isolation` captures that actor.
- The stored closure remains non-`@Sendable`.

### MainActor factory helper

Add this private helper in `Registration.swift`:

```swift
private func callMainActorFactory<T>(_ factory: @MainActor () -> T) -> T {
    nonisolated(unsafe) var result: T?
    MainActor.assumeIsolated {
        result = factory()
    }
    return result!
}
```

Commentary:

- `MainActor.assumeIsolated` is an assertion that execution is already on `MainActor`; it is not an actor hop.
- The `nonisolated(unsafe)` temporary avoids imposing `Sendable` on arbitrary service values.
- This helper must only be used for factories whose registration isolation is `.mainActor`, and resolution must check that current resolution isolation matches before invocation.

### Explicit `Factory(on: MainActor.self)` overload

Add this overload inside `Factory<T>`:

```swift
public init(
    _ type: T.Type = T.self,
    named: String? = nil,
    on actor: MainActor.Type,
    _ factory: @escaping @MainActor (Resolver) -> T
) {
    self.type = type
    self.name = named
    self.isolation = .mainActor
    self.factory = { resolver in
        callMainActorFactory {
            factory(resolver)
        }
    }
}
```

Commentary:

- This is the v1 ergonomic path for `DependencyModule.body`, which is nonisolated.
- The `actor` parameter is intentionally unused except to make the call site read `Factory(on: MainActor.self)`.
- Do not add a generic `Factory(on: A.Type)` overload. Swift cannot express `@A` closure isolation for a generic `A: GlobalActor` today.

### Singleton remains nonisolated

Update the current `Singleton<T>.registration` call to pass `.none`:

```swift
Registration(
    key: ServiceKey(self.type, name: self.name),
    scope: .singleton,
    isolation: .none,
    factory: ErasedFactory(...)
)
```

Do not add an `isolation:` parameter or `on: MainActor.Type` overload to `Singleton<T>`.

### `FactoryWithParams` implicit isolation

Replace `FactoryWithParams<P, T>` with this shape:

```swift
public struct FactoryWithParams<P, T> {
    private let type: T.Type
    private let name: String?
    private let isolation: RegistrationIsolation
    private let factory: (Resolver, P) -> T

    public init(
        _ type: T.Type = T.self,
        named: String? = nil,
        isolation: isolated (any Actor)? = #isolation,
        _ factory: @escaping (Resolver, P) -> T
    ) {
        self.type = type
        self.name = named
        self.isolation = .capture(isolation)
        self.factory = factory
    }

    public init(
        _ type: T.Type = T.self,
        named: String? = nil,
        on actor: MainActor.Type,
        _ factory: @escaping @MainActor (Resolver, P) -> T
    ) {
        self.type = type
        self.name = named
        self.isolation = .mainActor
        self.factory = { resolver, params in
            callMainActorFactory {
                factory(resolver, params)
            }
        }
    }

    var registration: Registration {
        Registration(
            key: ServiceKey(self.type, name: self.name),
            scope: .factory,
            isolation: self.isolation,
            factory: ErasedFactory(
                outputType: T.self,
                parameterType: P.self,
                call: { resolver, params in
                    guard let typedParams = params as? P else {
                        fatalError(
                            "Bolt: Parameter type mismatch for \(String(reflecting: self.type)). Expected \(String(reflecting: P.self))."
                        )
                    }
                    return self.factory(resolver, typedParams)
                }
            )
        )
    }
}
```

Commentary:

- Parameterized factories are factory scoped, so include them now.
- The explicit `MainActor` overload is needed for module-body construction of main-actor-bound view models with runtime parameters.

## Phase 2 — Resolver protocol

### File: `Sources/Bolt/Resolver.swift`

Replace the whole file with:

```swift
public protocol Resolver {
    func get<T>(
        _ type: T.Type,
        named: String?,
        isolation: isolated (any Actor)?
    ) -> T

    func get<T, P>(
        _ type: T.Type,
        named: String?,
        params: P,
        isolation: isolated (any Actor)?
    ) -> T
}

extension Resolver {
    public func get<T>(
        _ type: T.Type = T.self,
        named: String? = nil,
        isolation: isolated (any Actor)? = #isolation
    ) -> T {
        self.get(type, named: named, isolation: isolation)
    }

    public func get<T, P>(
        _ type: T.Type = T.self,
        named: String? = nil,
        params: P,
        isolation: isolated (any Actor)? = #isolation
    ) -> T {
        self.get(type, named: named, params: params, isolation: isolation)
    }
}
```

Commentary:

- The old exact requirements must be removed. If both old and new requirements exist, exact calls like `resolver.get(APIClient.self, named: nil)` can select the old requirement and lose isolation propagation.
- This may require external custom `Resolver` conformers to update. That is acceptable because consistent nested isolation depends on the protocol requirement carrying isolation.

## Phase 3 — Container resolution

### File: `Sources/Bolt/Container.swift`

#### Update public `get` methods

Replace:

```swift
public func get<T>(_ type: T.Type = T.self, named: String? = nil) -> T {
    let context = ResolutionContext(container: self)
    return context.get(type, named: named)
}

public func get<T, P>(_ type: T.Type = T.self, named: String? = nil, params: P) -> T {
    let context = ResolutionContext(container: self)
    return context.get(type, named: named, params: params)
}
```

with:

```swift
public func get<T>(
    _ type: T.Type = T.self,
    named: String? = nil,
    isolation: isolated (any Actor)? = #isolation
) -> T {
    let context = ResolutionContext(container: self, isolation: .capture(isolation))
    return context.get(type, named: named, isolation: isolation)
}

public func get<T, P>(
    _ type: T.Type = T.self,
    named: String? = nil,
    params: P,
    isolation: isolated (any Actor)? = #isolation
) -> T {
    let context = ResolutionContext(container: self, isolation: .capture(isolation))
    return context.get(type, named: named, params: params, isolation: isolation)
}
```

Commentary:

- Root resolution captures the caller's `#isolation` once.
- The context stores the captured value as `RegistrationIsolation`.

#### Add isolation check in `resolve`

In `resolve(_:named:params:context:)`, after registration lookup and before switching or before calling a specific resolver, call:

```swift
self.assertIsolationCompatible(registration: registration, key: key, context: context)
```

Concrete placement:

```swift
let key = ServiceKey(type, name: named)
guard let registration = self.lookupRegistration(for: key) else {
    fatalError(Self.missingRegistrationMessage(for: key))
}

self.assertIsolationCompatible(registration: registration, key: key, context: context)

switch registration.shape {
    ...
}
```

Commentary:

- This applies to all shapes, but `Singleton` registrations are `.none` in v1.
- Checking before the shape switch gives one consistent failure point.

#### Add `assertIsolationCompatible`

Add this private method inside `Container`:

```swift
private func assertIsolationCompatible(
    registration: Registration,
    key: ServiceKey,
    context: ResolutionContext
) {
    switch registration.isolation {
    case .none:
        return
    case .actor(let required):
        guard context.isolation == .actor(required) else {
            fatalError(
                Self.isolationMismatchMessage(
                    for: key,
                    required: required,
                    actual: context.isolation
                )
            )
        }
    }
}
```

#### Add isolation mismatch message

Add this static method near the other message builders:

```swift
private static func isolationMismatchMessage(
    for key: ServiceKey,
    required: ActorIsolationIdentity,
    actual: RegistrationIsolation
) -> String {
    let dependency = dependencyDescription(key)
    let actualDescription = actual.description

    if required.actorKey == ServiceKey(MainActor.self) {
        return "Bolt: MainActor-isolated dependency \(dependency) was resolved from \(actualDescription) context. Resolve it from a @MainActor context, or explicitly hop before resolving with await MainActor.run { ... }."
    }

    return "Bolt: Actor-isolated dependency \(dependency) requires \(required.description) isolation, but current resolution isolation is \(actualDescription)."
}
```

Commentary:

- Use `ServiceKey(MainActor.self)` to recognize the main-actor case.
- Do not use reflection to identify `MainActor`.
- The exact wording may be adjusted, but it must include dependency description, required isolation, and actual isolation.

#### Update `ResolutionContext`

Replace the existing `ResolutionContext` with:

```swift
private final class ResolutionContext: Resolver {
    private unowned let container: Container
    fileprivate var stack: [ServiceKey] = []
    fileprivate let isolation: RegistrationIsolation

    init(container: Container, isolation: RegistrationIsolation) {
        self.container = container
        self.isolation = isolation
    }

    func get<T>(
        _ type: T.Type,
        named: String?,
        isolation: isolated (any Actor)?
    ) -> T {
        self.container.resolve(type, named: named, params: nil, context: self)
    }

    func get<T, P>(
        _ type: T.Type,
        named: String?,
        params: P,
        isolation: isolated (any Actor)?
    ) -> T {
        self.container.resolve(type, named: named, params: params, context: self)
    }
}
```

Commentary:

- Nested `resolver.get(...)` does not create a new root context.
- Ignore the nested `isolation` argument in `ResolutionContext`. The root operation's isolation is authoritative.
- This prevents a nested call from escalating a nonisolated root resolution into an actor-isolated one.

## Phase 4 — Bolt facade

### File: `Sources/Bolt/Bolt.swift`

Replace the two `inject` methods with:

```swift
public static func inject<T>(
    _ type: T.Type = T.self,
    named: String? = nil,
    isolation: isolated (any Actor)? = #isolation
) -> T {
    Container.current.get(type, named: named, isolation: isolation)
}

public static func inject<T, P>(
    _ type: T.Type = T.self,
    named: String? = nil,
    params: P,
    isolation: isolated (any Actor)? = #isolation
) -> T {
    Container.current.get(type, named: named, params: params, isolation: isolation)
}
```

Commentary:

- Existing calls remain source-compatible.
- `@MainActor` callers get implicit main-actor resolution through `#isolation`.

## Phase 5 — Tests

### File: `Tests/BoltTests/FactoryIsolationTests.swift`

Create this new file:

```swift
import Testing

@testable import Bolt

@MainActor
private final class MainActorService {
    init() {}
}

@MainActor
private final class MainActorViewModel {
    let service: MainActorService

    init(service: MainActorService) {
        self.service = service
    }
}

@Suite("Factory Isolation")
struct FactoryIsolationSuite {
    @Test
    @MainActor
    func mainActorFactoryRegisteredInMainActorContextResolvesOnMainActor() {
        let container = Container()
        container.register {
            Factory { _ in MainActorService() }
        }

        let first: MainActorService = container.get()
        let second: MainActorService = container.get()

        #expect(first !== second)
    }

    @Test
    @MainActor
    func mainActorFactoryRegisteredInModuleBodyWithExplicitOverloadResolvesOnMainActor() {
        final class UIModule: DependencyModule {
            @ModuleBuilder
            override var body: ModuleDefinition {
                Factory(on: MainActor.self) { _ in MainActorService() }
            }
        }

        Bolt.withModules([UIModule()]) {
            let service: MainActorService = Bolt.inject()
            #expect(service is MainActorService)
        }
    }

    @Test
    @MainActor
    func mainActorFactoryNestedResolutionInheritsRootIsolation() {
        final class UIModule: DependencyModule {
            @ModuleBuilder
            override var body: ModuleDefinition {
                Factory(on: MainActor.self) { _ in MainActorService() }
                Factory(on: MainActor.self) { resolver in
                    MainActorViewModel(service: resolver.get())
                }
            }
        }

        Bolt.withModules([UIModule()]) {
            let model: MainActorViewModel = Bolt.inject()
            #expect(model.service is MainActorService)
        }
    }

    @Test
    @MainActor
    func nonisolatedFactoryResolvesFromMainActorContext() {
        final class Service {}

        let container = Container()
        container.register {
            Factory { _ in Service() }
        }

        let service: Service = container.get()
        #expect(service is Service)
    }

    @Test
    @MainActor
    func mainActorFactoryWithParamsResolvesOnMainActor() {
        final class UIModule: DependencyModule {
            @ModuleBuilder
            override var body: ModuleDefinition {
                FactoryWithParams(MainActorViewModel.self, on: MainActor.self) { resolver, _: String in
                    MainActorViewModel(service: resolver.get())
                }
                Factory(on: MainActor.self) { _ in MainActorService() }
            }
        }

        Bolt.withModules([UIModule()]) {
            let model: MainActorViewModel = Bolt.inject(params: "user-id")
            #expect(model.service is MainActorService)
        }
    }
}
```

Commentary:

- These tests intentionally run under `@MainActor` so resolution should be synchronous and implicit.
- The nested test proves `ResolutionContext` preserves root isolation through `resolver.get()`.
- The parameterized test proves `FactoryWithParams(on: MainActor.self)` works.

### Fatal-error test

If the project already has or later adds a subprocess fatal-error harness, add this behavior test:

```swift
mainActorFactoryResolutionFromNonisolatedContextFailsWithHelpfulMessage
```

Scenario:

1. Register `Factory(on: MainActor.self) { MainActorService() }`.
2. Resolve from a nonisolated function.
3. Assert the process traps with a message containing `MainActor-isolated dependency` and `@MainActor context`.

Do not block implementation on this if the project has no safe fatal-error test harness.

## Phase 6 — README

### File: `README.md`

Add a section under runtime usage or named/parameterized registrations:

````markdown
### MainActor-bound factories

Factory registrations can require actor isolation. Bolt keeps resolution synchronous: it does not hop to `MainActor` internally.

Use `Factory(on: MainActor.self)` when registering main-actor-bound services from a `DependencyModule.body`:

```swift
@MainActor
final class ImageLoader {
  init() {}
}

final class UIModule: DependencyModule {
  @ModuleBuilder
  override var body: ModuleDefinition {
    Factory(on: MainActor.self) { _ in ImageLoader() }
  }
}
```

Resolve from a `@MainActor` context with the normal APIs:

```swift
@MainActor
func makeFeature() {
  let loader: ImageLoader = Bolt.inject()
}
```

If the caller is not already on the main actor, hop before resolving:

```swift
await MainActor.run {
  let loader: ImageLoader = Bolt.inject()
}
```

Bolt does not support isolated singleton registrations yet. Prefer factory scope for actor-bound services.
```
````

Commentary:

- Do not document `@Injected` as supporting actor-isolated factories.
- Do not mention custom global actors as supported public API in v1.

## Phase 7 — Build and cleanup

Run:

```bash
swift test
```

If compilation fails because existing exact calls select old `Resolver`/`Container` signatures, remove the old signatures rather than keeping compatibility overloads that bypass isolation.

## Acceptance criteria

- Existing tests pass.
- New `FactoryIsolationTests` pass.
- Existing factory call sites compile unchanged.
- Existing parameterized factory call sites compile unchanged.
- `Factory(on: MainActor.self) { _ in MainActorType() }` compiles from nonisolated `DependencyModule.body`.
- `@MainActor` resolution with plain `Bolt.inject()` succeeds.
- Nested `resolver.get()` inside a main-actor factory succeeds without requiring explicit `isolation:` at the nested call site.
- Nonisolated resolution of a main-actor factory traps with a helpful message.
- `Singleton` public API is unchanged.
- No async Bolt resolution APIs are introduced.

## Notes for future extension

The internal representation is intentionally actor-generic:

```swift
RegistrationIsolation.actor(ActorIsolationIdentity(actorKey: ServiceKey, instanceID: ObjectIdentifier))
```

If Swift later supports generic global-actor closure types, Bolt can add public overloads for arbitrary global actors without changing the resolution model. Until then, only `MainActor` gets an explicit module-body overload.
