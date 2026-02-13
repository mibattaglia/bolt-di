---
name: bolt-scoping
description: Use Bolt container scoping and overrides safely in production and tests
license: Repository-internal
metadata:
  short-description: Bolt scoping patterns for setup, module/container swapping, and local overrides
---

# Bolt Scoping

## Goal
Choose the right scope API and avoid cross-task leakage.

## Quick start
1. Define a `DependencyModule` using `body` + `@ModuleBuilder`.
2. Use `Bolt.setup(modules:)` for app-wide live graph.
3. Use `Bolt.withModules(modules) { ... }` for per-test/per-scope module graphs.
4. Use `Bolt.withContainer(container) { ... }` to swap the full graph.
5. Use `Bolt.withOverrides { ... } _: { ... }` to patch selected dependencies.

## Module registration example
```swift
final class AppModule: DependencyModule {
  override var body: ModuleDefinition {
    Singleton(APIClient.self) { _ in LiveAPIClient() }
    Factory(UserService.self) { resolver in
      UserService(api: resolver.get(APIClient.self))
    }
  }
}

Bolt.setup(modules: [AppModule()])
```

## Test graph via modules
```swift
await Bolt.withModules([AppModule(), TestOverridesModule()]) {
  let value: UserService = Bolt.inject()
  #expect(value.api is MockAPIClient)
}
```

## Rules
- `setup` is app bootstrap/global state. Avoid using it as per-test setup.
- In debug builds, concurrent `setup` calls fail fast and point to `withModules`.
- `withModules` builds the same planned module graph but scopes it lexically/task-locally.
- `withContainer` replaces the entire graph in lexical/task-local scope.
- `withOverrides` patches `Container.current` only in lexical/task-local scope.
- Prefer `withOverrides` for narrow test/customization changes.
- Prefer `withModules` for module-driven isolated tests.
- Prefer `withContainer` for direct container-driven isolated tests.

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
