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
        UserService(api: resolver.get(APIClient.self))
      }
    }
  }
}

Bolt.setup(modules: [NetworkModule()])

let service: UserService = Bolt.inject()
```

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

### Dependency metadata for missing/cycle checks

`BoltValidator` detects missing registrations and cycles using explicit registration metadata:

```swift
container.register {
  Factory(ServiceA.self, dependencies: [Key(ServiceB.self)]) { _ in ServiceA() }
  Factory(ServiceB.self, dependencies: [Key(ServiceA.self)]) { _ in ServiceB() }
}
```

Without metadata, validator still reports duplicate and type-mismatch issues.
