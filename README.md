<img width="256" height="256" alt="image" src="https://github.com/user-attachments/assets/9ddfe208-54e3-4e04-92eb-ee8206b757c3" />


# Bolt

Bolt is a fast, lightweight Swift dependency injection framework with:
- Crash-on-failure runtime resolution (`Container.get`, `Bolt.inject`, `@Injected`)
- Result-builder registration DSL
- Factory and singleton scopes
- Task-local container scoping (`withContainer`) and task-local lexical overrides (`withOverrides`)
- Validator tooling for duplicate/type-mismatch checks, module dependency cycle checks, and strict required-registration checks

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
- Use `DependencyModule.dependentModules` to declare transitive module requirements instead of manually duplicating setup lists.
- Use `withOverrides` for lexical test/customization scopes only.
- Keep runtime lookup ergonomic by relying on inferred `resolver.get()` where context provides type information.

## Scoping Patterns

Use these patterns depending on what you need to change:

- `Bolt.setup(modules:)`: Configure app-wide live dependencies in `Bolt.shared`.
- `Bolt.withContainer(...)`: Swap the entire dependency graph for a lexical scope.
- `Bolt.withOverrides { ... }`: Patch selected registrations in the current container for a lexical/task-local scope.

### App setup (live graph)

```swift
Bolt.setup(modules: [
  NetworkModule(),
  PersistenceModule()
])
```

### Per-test isolated container

```swift
@Test func featureUsesMockGraph() {
  let testContainer = Container()
  testContainer.register {
    Factory(APIClient.self) { _ in MockAPIClient() }
    Factory(Analytics.self) { _ in NoopAnalytics() }
  }

  Bolt.withContainer(testContainer) {
    let feature = FeatureViewModel()
    // assertions...
  }
}
```

### Focused override of one dependency

```swift
Bolt.withOverrides {
  Factory(APIClient.self) { _ in MockAPIClient() }
} _: {
  let feature = FeatureViewModel()
  // Only APIClient is overridden. Other dependencies come from the base container.
}
```

Notes:
- `withOverrides` targets `Container.current`: inside `withContainer`, it overrides that container; otherwise it overrides `Bolt.shared`.
- Overrides are lexical and task-local: they are automatically restored when the closure exits.

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

Validate a single feature module (including its `dependentModules`) directly:

```swift
BoltValidator.validate(module: NetworkModule()) { error in
  print(error.message)
}
```

## Benchmark Tiers

- Tier A (`tier_a_*`): head-to-head comparable benchmarks against WhoopDI, Factory, and swift-dependencies.
- Tier B (`tier_b_*`): Bolt stress/feature-depth benchmarks.

## References and Inspiration

- [WhoopDI](https://github.com/WhoopInc/WhoopDI)
- [swift-dependencies](https://github.com/pointfreeco/swift-dependencies)
- [Factory](https://github.com/hmlongco/Factory)
