---
name: bolt-scoping
description: Use Bolt container scoping and overrides safely in production and tests
license: Repository-internal
metadata:
  short-description: Bolt scoping patterns for container swapping and local overrides
---

# Bolt Scoping

## Goal
Choose the right scope API and avoid cross-task leakage.

## Quick start
1. Define a `DependencyModule` and register dependencies with `container.register { ... }`.
2. Use `Bolt.setup(modules:)` for app-wide live graph.
2. Use `Bolt.withContainer(container) { ... }` to swap the full graph.
3. Use `Bolt.withOverrides { ... } _: { ... }` to patch selected dependencies.

## Module registration example
```swift
final class AppModule: DependencyModule {
  override func defineDependencies(into container: Container) {
    container.register {
      Singleton(APIClient.self) { _ in LiveAPIClient() }
      Factory(UserService.self) { resolver in
        UserService(api: resolver.get(APIClient.self))
      }
    }
  }
}

Bolt.setup(modules: [AppModule()])
```

## Rules
- `withContainer` replaces the entire graph in lexical/task-local scope.
- `withOverrides` patches `Container.current` only in lexical/task-local scope.
- Prefer `withOverrides` for narrow test/customization changes.
- Prefer `withContainer` for feature-isolated graphs.

## Async usage
- Use async overloads when `await` is needed inside scope closures.
- Keep async child work created inside the intended scope.

## Example
```swift
await Bolt.withContainer(featureContainer) {
  let value: FeatureService = Bolt.inject()

  let testValue = await Bolt.withOverrides {
    Factory(APIClient.self) { _ in MockAPIClient() }
  } _: {
    await Task.yield()
    return Bolt.inject(FeatureService.self)
  }
}
```
