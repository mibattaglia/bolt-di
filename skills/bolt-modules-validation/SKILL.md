---
name: bolt-modules-validation
description: Validate a feature module and its dependent modules using BoltValidator
license: Repository-internal
metadata:
  short-description: Module-centric validation for Bolt
---

# Bolt Module Validation

## Goal
Verify a `DependencyModule` graph is structurally valid before runtime use.

## Create a module
```swift
final class PaymentsModule: DependencyModule {
  @ModuleBuilder
  override var body: ModuleDefinition {
    DependentModules {
      NetworkModule()
      AuthModule()
    }

    Singleton(PaymentsAPI.self) { _ in LivePaymentsAPI() }
    Factory(PaymentsService.self) { resolver in
      PaymentsService(
        api: resolver.get(PaymentsAPI.self),
        auth: resolver.get(AuthService.self)
      )
    }
    FactoryWithParams(ReceiptFormatter.self) { _, locale in
      ReceiptFormatter(locale: locale)
    }
  }
}
```

## Quick start
1. Build the feature module.
2. Run `BoltValidator.validate(module:)`.
3. Fail test on each reported validation error.

## API
```swift
BoltValidator.validate(module: FeatureModule()) { error in
  Issue.record("DI validation failed: \(error.message)")
}
```

## What it validates
- Module dependency cycles.
- Duplicate registrations across transitive module graph.
- Registration type mismatches.

## Notes
- Dependencies declared in `DependentModules { ... }` are included transitively.
- This is non-crashing diagnostics; runtime `inject/get` remains crash-on-failure.
- Register module(s) at app start via `Bolt.setup(modules: [...])`.
