# Bolt

Bolt is a fast, lightweight Swift dependency injection framework with:
- Crash-on-failure runtime resolution (`Container.get`, `Bolt.inject`, `@Injected`)
- Result-builder registration DSL
- Factory and singleton scopes
- Task-local container scoping (`withContainer`) and lexical overrides (`withOverrides`)
- Validator tooling for duplicate, missing, type-mismatch, and circular graph errors

## Installation

### Swift Package Manager

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  dependencies: [
    .package(url: "https://github.com/mibattaglia/bolt-di.git", branch: "main")
  ],
  targets: [
    .target(
      name: "MyTarget",
      dependencies: [
        .product(name: "Bolt", package: "bolt-di")
      ]
    )
  ]
)
```

### CocoaPods

```ruby
pod 'Bolt'
```

## Runtime Usage

```swift
final class NetworkModule: DependencyModule {
  override func defineDependencies(into container: Container) {
    container.register {
      Singleton(APIClient.self) { _ in APIClient() }

      Factory(UserService.self) { resolver in
        let api: APIClient = resolver.get()
        return UserService(api: api)
      }
    }
  }
}

Bolt.setup(modules: [NetworkModule()])

let service: UserService = Bolt.inject()
```

## Best Practices

- Resolve dependencies at composition boundaries (app setup, feature assembly, coordinator entry points).
- Prefer passing resolved dependencies into child types via initializers rather than resolving deep in leaf objects.
- Use `withOverrides` for lexical test/customization scopes only.
- Keep runtime lookup ergonomic by relying on inferred `resolver.get()` where context provides type information.

### Named and parameterized registrations

```swift
container.register {
  Singleton(APIClient.self, named: "live") { _ in APIClient.live }
  FactoryWithParams(String.self, named: "greeting") { _, name in
    "Hello, \(name)"
  }
}

let live: APIClient = Bolt.inject(named: "live")
let greeting: String = Bolt.inject(named: "greeting", params: "Michael")
```

### Scoped overrides

```swift
Bolt.withOverrides {
  Factory(APIClient.self) { _ in MockAPIClient() }
} _: {
  let service: UserService = Bolt.inject()
}
```

### Property wrapper

```swift
final class FeatureViewModel {
  @Injected private var userService: UserService
}
```

## Validation

Use `BoltValidator` for non-crashing diagnostics:

```swift
let validator = BoltValidator(modules: [NetworkModule()])
validator.validate { error in
  print(error.message)
}
```

### Dependency edges for missing/cycle checks

`BoltValidator` detects missing registrations and cycles using explicit `edges` input:

```swift
let validator = BoltValidator(
  modules: [FeatureModule()],
  edges: [
    DependencyEdge(from: Key(ServiceA.self), to: Key(ServiceB.self)),
    DependencyEdge(from: Key(ServiceB.self), to: Key(ServiceA.self)),
  ]
)
```

Without edges, validator still reports duplicate and type-mismatch issues.

## References and Inspiration

- [WhoopDI](https://github.com/WhoopInc/WhoopDI)
- [swift-dependencies](https://github.com/pointfreeco/swift-dependencies)
- [Factory](https://github.com/hmlongco/Factory)
