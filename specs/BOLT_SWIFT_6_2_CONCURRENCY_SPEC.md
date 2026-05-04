# Bolt Swift 6.2 Concurrency Modernization Spec

Date: 2026-04-23
Status: Draft

Related docs:
- `specs/BOLT_DI_SPEC.md`
- `specs/BOLT_SWIFT_TESTING_CONCURRENCY_PARITY_PLAN.md`
- `specs/BOLT_TESTING_ERGONOMICS_PLAN.md`

## Summary

This document defines Bolt's intended concurrency model in a Swift 6.2 world.

The goal is **not** to turn Bolt into an actor-only or async-only DI framework. The goal is to make Bolt's **container, scoping, and singleton machinery** safe and explicit under modern Swift concurrency while preserving Bolt's current ergonomics:

- synchronous resolution APIs (`Bolt.inject`, `Container.get`)
- task-local graph scoping (`withContainer`, `withOverrides`, `withModules`)
- support for non-`Sendable` consumer objects and legacy reference types

A key design choice in this spec is:

> Bolt will **not** require registration closures (`Factory`, `Singleton`, `FactoryWithParams`) to be `@Sendable`.

That is intentional. Many valid DI registrations capture module state, configuration objects, or other reference types that are not `Sendable`. Bolt should support those use cases.

Instead, Bolt will draw a clearer boundary:

- Bolt is responsible for the concurrency safety of its **runtime container internals**.
- Bolt is **not** responsible for proving that user-registered services are themselves safe to share across tasks.

## Problem

Bolt's current concurrency direction is mostly correct:

- task-local scoping is the right model for lexical dependency overrides
- the public API remains synchronous and easy to use
- tests already cover several concurrent-resolution scenarios

However, the current implementation still relies on several Swift concurrency escape hatches and some shared-state patterns that are weaker than what Swift 6.2 encourages:

1. `@unchecked Sendable` is used for multiple core runtime types.
2. `nonisolated(unsafe)` is used for several stored properties and statics.
3. Some lock-backed state has unsynchronized read paths.
4. Build-time mutation and runtime resolution are still mixed in the same types.
5. Package/test-support code is not yet fully ready for stricter Swift 6.2 isolation defaults such as `NonisolatedNonsendingByDefault`.

In practice, this means Bolt compiles and works today, but the internal ownership model is not yet expressed as clearly or as safely as it should be for a Swift 6.2 minimum world.

## Goals

1. Preserve Bolt's synchronous DI ergonomics.
2. Preserve task-local scoping semantics.
3. Preserve support for non-`Sendable` registered services and non-`Sendable` registration captures.
4. Remove or reduce unsafe isolation escape hatches where they are unnecessary.
5. Eliminate internal shared-state patterns that depend on unsynchronized reads.
6. Separate mutable graph construction concerns from runtime resolution concerns where practical.
7. Prefer explicit ownership and immutable runtime data over broad shared mutable state.
8. Make package/test-support code compatible with Swift 6.2 isolation defaults.
9. Keep source compatibility unless a future follow-up explicitly chooses to change public API.

## Non-goals

1. Requiring all registered service types to conform to `Sendable`.
2. Requiring `Factory`, `Singleton`, or `FactoryWithParams` closures to be `@Sendable`.
3. Converting `Bolt.inject` / `Container.get` into async APIs.
4. Blanket `@MainActor` isolation.
5. Replacing Bolt's container model with a value-environment system.
6. Eliminating every lock regardless of runtime/platform constraints.
7. Using `@unchecked Sendable` as a permanent blanket strategy for all internal concurrency concerns.

## Design Principles

### 1) Keep the public API synchronous and explicit

Bolt's current model is intentionally synchronous. Resolution should continue to look like:

```swift
let service: APIClient = Bolt.inject()
```

This is a core ergonomics property and should not be sacrificed just to force actor isolation through the entire system.

### 2) Keep task-local scoping as the contextual override mechanism

`@TaskLocal` remains the correct mechanism for:

- `Container.current`
- `Bolt.withContainer`
- `Bolt.withOverrides`
- `Bolt.withModules`

Task-local scoping composes naturally with lexical APIs and async suspension points.

### 3) Do not require `@Sendable` registration closures

Bolt registrations may legitimately capture:

- module instance state
- legacy configuration objects
- reference-typed factories/builders
- test doubles and mutable fixtures

Requiring `@Sendable` would reject many normal DI patterns and would over-constrain the library's intended use.

### 4) Make container internals safe even when services are not

Bolt should guarantee the safety of:

- registration lookup
- scoped override graph selection
- singleton cache creation/reset behavior
- internal module planning/build behavior

Bolt should not claim that a resolved singleton instance of an arbitrary reference type is safe to use concurrently unless the user made that service safe.

### 5) Prefer immutability over synchronization when possible

Where runtime state can be made immutable after graph construction, that is preferred over broad shared mutable state plus locks.

### 6) Use unsafe escape hatches only with a specific, documented invariant

If `@unchecked Sendable`, `nonisolated(unsafe)`, or similar escape hatches remain, each usage must have:

- a narrow purpose
- a documented safety invariant
- a reason the safer alternative is not currently viable

## Current Audit Findings

The following implementation areas motivate this spec:

### A. Singleton cache paths need stricter synchronization

Current singleton cache access uses lock-backed mutation but also includes lock-free reads. That is weaker than the intended model and should be tightened so cache access follows one consistent synchronization rule.

### B. Registration snapshot access should not rely on unsafe shared reads

The current container implementation keeps mutable registration state plus a separate snapshot used for reads. The snapshot strategy should not depend on unsynchronized shared-state access.

### C. Global/type-level intern tables should be narrowed or better isolated

`ServiceKey` internal tables and other static mutable state should be reviewed for stronger ownership and a smaller unsafe surface.

### D. Build-time mutation and runtime resolution are too intertwined

Registration mutation, runtime lookup, validation bookkeeping, and cache access currently live too close together. This makes it harder to reason about isolation and makes concurrency escape hatches more tempting.

### E. Swift 6.2 future-default compatibility needs to be explicit

Package support code currently needs a targeted pass for stricter 6.2 closure isolation defaults, especially in Swift Testing integration.

## Concurrency Model Decisions

## 1) Public registration APIs remain non-`@Sendable`

The following APIs remain intentionally unconstrained:

```swift
public struct Factory<T>
public struct Singleton<T>
public struct FactoryWithParams<P, T>
```

Their stored closures are not upgraded to `@Sendable` by this spec.

Rationale:
- preserves common module patterns that capture `self`
- preserves support for legacy and reference-heavy service graphs
- avoids turning DI registration into a broad sendability migration problem for consumers

Consequence:
- Bolt cannot rely on the compiler to prove the sendability of user captures at the registration boundary
- Bolt must keep its internal concurrency guarantees focused on container mechanics, not arbitrary service payloads

Representative supported patterns:

```swift
final class AppModule: DependencyModule {
    let configuration: LegacyConfiguration

    init(configuration: LegacyConfiguration) {
        self.configuration = configuration
        super.init()
    }

    @ModuleBuilder
    override var body: ModuleDefinition {
        Factory(APIClient.self) { _ in
            LiveAPIClient(configuration: self.configuration)
        }

        Singleton(SessionStore.self) { _ in
            SessionStore(configuration: self.configuration)
        }
    }
}
```

The spec intentionally preserves patterns like the above, where registration closures capture module instance state that may not be `Sendable`.

Representative anti-goal:

```diff
-public struct Factory<T> {
-    private let factory: (Resolver) -> T
-}
+public struct Factory<T> {
+    private let factory: @Sendable (Resolver) -> T
+}
```

That tightening is deliberately out of scope for this spec.

## 2) Bolt guarantees runtime container safety, not service payload safety

The runtime guarantee is:

- concurrent resolution through the same container does not corrupt Bolt's internal state
- scoped overrides remain task-local and lexically bounded
- singleton initialization and reuse obey the documented cache semantics

The runtime guarantee is not:

- every value returned from Bolt is `Sendable`
- every singleton registered in Bolt is safe to share across tasks

Documentation should explicitly state that shared mutable services remain the consumer's responsibility and that actors are preferred for mutable shared services.

## 3) Runtime graphs should become effectively immutable after construction

Bolt should move toward an internal model where runtime lookup operates over immutable graph data.

Preferred direction:
- registration planning/building produces an immutable runtime graph representation
- scoped override layers are immutable once created
- runtime resolution reads from immutable graph state plus narrowly synchronized singleton cells

This does not require changing the public API immediately. It is primarily an internal architecture goal.

## 4) Mutable graph-building concerns should be isolated from runtime resolution

The implementation should distinguish between:

- graph construction
- validation collection
- runtime resolution
- singleton cache state

A practical direction is to introduce an internal builder/planner layer that assembles a runtime graph before resolution begins.

This can remain source-compatible by keeping the current public APIs while changing the internal storage model.

## 5) Lock removal should be selective, not ideological

Bolt should remove locks where a better ownership model exists, but should not force actor isolation into synchronous hot paths just to eliminate all locks.

The priority order is:

1. remove unsafely shared mutable state
2. replace lock-free shared reads with consistent ownership/synchronization
3. narrow synchronization to the smallest runtime cells that truly need it
4. only then consider whether some remaining locks can be removed entirely

## 6) Region-based isolation is a supporting tool, not the primary solution

Swift 6.2 region-based isolation is useful for:

- fresh values produced and transferred once
- helper APIs that create graph/configuration values and immediately hand them off
- test-support/build-support boundaries

It is not the primary solution for:

- singleton caches
- process-global shared tables
- mutable container registries

Those are true shared mutable state and still require stronger ownership or synchronization.

## Implementation Strategy

### Phase 1: Eliminate unsafe internal read patterns

Status: Proposed

1. Tighten singleton cache access so all reads/writes obey one synchronization rule.
2. Remove unsafe shared-read registration snapshot patterns.
3. Remove unnecessary `nonisolated(unsafe)` uses, especially where Swift 6.2 can express the same intent directly.
4. Keep the existing task-local scoping semantics unchanged.

Acceptance:
- No singleton cache path depends on unsynchronized reads.
- Registration lookup no longer depends on unsafe snapshot sharing.
- Public API behavior remains unchanged.

### Phase 2: Move toward immutable runtime graph storage

Status: Proposed

1. Introduce an internal immutable runtime graph representation.
2. Restrict mutation to build/setup/override assembly paths.
3. Ensure scoped override containers are immutable after initialization.
4. Narrow the set of runtime components that need synchronization to singleton caches and a small number of explicitly shared cells.

Acceptance:
- Runtime resolution primarily reads immutable graph data.
- Graph mutation is no longer interleaved with hot-path resolution logic.
- The number of internal unsafe annotations decreases.

### Phase 3: Modernize lock usage where synchronization is still required

Status: Proposed

1. Replace production `NSLock`-based mutual exclusion with `OSAllocatedUnfairLock` on Bolt's current deployment floor.
2. Use `withLock` for `Sendable` state and `withLockUnchecked` only where the protected state is intentionally non-`Sendable`.
3. Do not adopt `Synchronization.Mutex` as the sole solution unless minimum OS support is raised to its availability floor.
4. Continue the invariant that user factory closures must not execute while an unfair lock is held.

Notes:
- `OSAllocatedUnfairLock` is the default mutual-exclusion primitive for this spec on current Bolt platforms.
- `Synchronization.Mutex` remains attractive in Swift 6+, but is deferred until the package can rely on its availability everywhere Bolt supports.
- `NSCondition` may still appear as a waiting primitive for synchronous exactly-once singleton initialization; it is not the preferred mutual-exclusion primitive.

Acceptance:
- Remaining mutual exclusion in production code is centered on `OSAllocatedUnfairLock`.
- No lock is used merely to paper over a vague ownership story.
- No unfair lock surrounds user factory execution.

### Phase 4: Swift 6.2 package and support-surface hardening

Status: Proposed

1. Treat Swift 6.2 as the baseline package/toolchain story.
2. Add CI/build verification using stricter 6.2 isolation defaults, including `NonisolatedNonsendingByDefault`.
3. Fix any test-support protocol conformances that require explicit closure isolation annotations under those defaults.
4. Document the concurrency boundary clearly in README/specs.

Acceptance:
- Whole-package builds succeed under the chosen Swift 6.2 concurrency settings.
- Test support does not rely on accidental pre-6.2 inference behavior.
- Public docs explain Bolt's guarantees and non-guarantees.

## Exact Phase 1 Implementation Instructions

This section is intentionally prescriptive.

A coding agent implementing the first concurrency-hardening slice should follow these edits exactly and should **not** broaden the change into an architecture rewrite.

Scope of this slice:
- fix real unsynchronized-read issues
- replace production `NSLock`-based mutual exclusion with `OSAllocatedUnfairLock` where the package deployment floor already supports it
- keep singleton factory execution **outside** the unfair lock
- preserve a synchronized cached-value accessor so `Container` can still fast-path already-initialized singletons
- remove `registrationSnapshot`
- remove the unsafe task-local annotation
- make `BoltTestSupport` build under stricter Swift 6.2 closure isolation defaults
- do **not** refactor Bolt into actors
- do **not** add `@Sendable` requirements to registration closures
- do **not** change public API semantics

### Locking policy for this slice

For production sources in `Sources/Bolt`, the preferred primitive in this slice is `OSAllocatedUnfairLock`.

Add a convenience initializer in `Sources/Bolt/Locking.swift`:

```swift
extension OSAllocatedUnfairLock {
    init(checkedState: @Sendable @autoclosure () -> State) {
        self.init(uncheckedState: checkedState())
    }
}
```

Use that initializer when the initial-state expression can be formed in a `@Sendable` autoclosure.
Use `uncheckedState:` directly when constructing the initial state requires capturing intentionally non-`Sendable` values such as `Registration`.

Use `withLock` when the closure only moves `Sendable` data.
Use `withLockUnchecked` when the closure intentionally protects non-`Sendable` data such as:
- `Any`
- `Registration`
- dictionaries containing `Registration`

The `checkedState` initializer only improves initialization ergonomics. It does **not** remove the need for `withLockUnchecked` when accessing non-`Sendable` protected state.

`NSCondition` is permitted only inside `SingletonWaiter` to support synchronous exactly-once singleton initialization **without** executing the user factory closure while the unfair lock is held.

### File 1: `Sources/Bolt/Registration.swift`

#### Step 1.1 — add the import

##### Exact current line

```swift
import Foundation
```

##### Replace with

```swift
import Foundation
import os
```

#### Step 1.2 — replace the entire singleton cell block

##### Exact current block

```swift
final class SingletonCell: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Any?

    var cachedValue: Any? {
        self.value
    }

    func getOrCreate(_ build: () -> Any) -> Any {
        if let value = self.value {
            return value
        }

        self.lock.lock()
        defer { self.lock.unlock() }

        if let value = self.value {
            return value
        }

        let created = build()
        self.value = created
        return created
    }

    func clear() {
        self.lock.withLock {
            self.value = nil
        }
    }
}
```

##### Replace with this exact block

```swift
private final class SingletonWaiter: @unchecked Sendable {
    private let condition = NSCondition()
    private var value: Any?

    func finish(with value: Any) {
        self.condition.lock()
        self.value = value
        self.condition.broadcast()
        self.condition.unlock()
    }

    func waitForValue() -> Any {
        self.condition.lock()
        while self.value == nil {
            self.condition.wait()
        }
        let value = self.value!
        self.condition.unlock()
        return value
    }
}

private enum SingletonCellAction: @unchecked Sendable {
    case returnValue(Any)
    case build(SingletonWaiter)
    case wait(SingletonWaiter)
}

private enum SingletonCellState: @unchecked Sendable {
    case empty
    case initializing(SingletonWaiter)
    case initialized(Any)
}

final class SingletonCell: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(checkedState: SingletonCellState.empty)

    func cachedValue() -> Any? {
        self.state.withLockUnchecked { state in
            switch state {
            case .empty, .initializing:
                return nil
            case .initialized(let value):
                return value
            }
        }
    }

    func getOrCreate(_ build: () -> Any) -> Any {
        let action = self.state.withLockUnchecked { state -> SingletonCellAction in
            switch state {
            case .initialized(let value):
                return .returnValue(value)
            case .empty:
                let waiter = SingletonWaiter()
                state = .initializing(waiter)
                return .build(waiter)
            case .initializing(let waiter):
                return .wait(waiter)
            }
        }

        switch action {
        case .returnValue(let value):
            return value
        case .build(let waiter):
            let created = build()
            self.state.withLockUnchecked { state in
                state = .initialized(created)
            }
            waiter.finish(with: created)
            return created
        case .wait(let waiter):
            return waiter.waitForValue()
        }
    }

    func clear() {
        while true {
            let waiter = self.state.withLockUnchecked { state -> SingletonWaiter? in
                switch state {
                case .empty:
                    return nil
                case .initialized:
                    state = .empty
                    return nil
                case .initializing(let waiter):
                    return waiter
                }
            }

            guard let waiter else { return }
            _ = waiter.waitForValue()
        }
    }
}
```

#### Required invariants after this change
- there are no unsynchronized reads of singleton cache state
- the user `build` closure executes **outside** `OSAllocatedUnfairLock`
- concurrent waiters block on `NSCondition` until the winning initializer publishes the value
- `cachedValue()` remains available as a synchronized accessor for `Container`

### File 2: `Sources/Bolt/Container.swift`

#### Step 2.1 — add the import

##### Exact current line

```swift
import Foundation
```

##### Replace with

```swift
import Foundation
import os
```

#### Step 2.2 — replace the header/storage block

##### Exact current block

```swift
public final class Container: Resolver, @unchecked Sendable {
    @TaskLocal nonisolated(unsafe) static var taskLocalCurrent: Container?

    public static var current: Container {
        Self.taskLocalCurrent ?? Bolt.shared
    }

    private let lock = NSLock()
    private var mutableRegistrations: [ServiceKey: Registration] = [:]
    nonisolated(unsafe) private var registrationSnapshot = RegistrationSnapshot(entries: [:])

    private let registrationBehavior: RegistrationBehavior
    private var validationErrors: [ValidationError] = []
    private let parent: Container?
```

##### Replace with this exact block

```swift
private struct ContainerState: @unchecked Sendable {
    var registrations: [ServiceKey: Registration]
    var validationErrors: [ValidationError]

    init(
        registrations: [ServiceKey: Registration] = [:],
        validationErrors: [ValidationError] = []
    ) {
        self.registrations = registrations
        self.validationErrors = validationErrors
    }
}

public final class Container: Resolver, @unchecked Sendable {
    @TaskLocal static var taskLocalCurrent: Container?

    public static var current: Container {
        Self.taskLocalCurrent ?? Bolt.shared
    }

    private let state: OSAllocatedUnfairLock<ContainerState>

    private let registrationBehavior: RegistrationBehavior
    private let parent: Container?
```

#### Step 2.3 — replace the two public/internal root initializers

##### Exact current block

```swift
    public init() {
        self.parent = nil
        self.registrationBehavior = .strict
    }

    init(registrationBehavior: RegistrationBehavior) {
        self.parent = nil
        self.registrationBehavior = registrationBehavior
    }
```

##### Replace with this exact block

```swift
    public init() {
        self.parent = nil
        self.registrationBehavior = .strict
        self.state = OSAllocatedUnfairLock(checkedState: ContainerState())
    }

    init(registrationBehavior: RegistrationBehavior) {
        self.parent = nil
        self.registrationBehavior = registrationBehavior
        self.state = OSAllocatedUnfairLock(checkedState: ContainerState())
    }
```

#### Step 2.4 — replace the override-layer initializer

This initializer must use `uncheckedState:` rather than `checkedState:` because the `registrations` argument is intentionally non-`Sendable` in this design.

##### Exact current block

```swift
    private init(
        parent: Container,
        registrationBehavior: RegistrationBehavior,
        registrations: [ServiceKey: Registration]
    ) {
        self.parent = parent
        self.registrationBehavior = registrationBehavior
        self.mutableRegistrations = registrations
        self.registrationSnapshot = RegistrationSnapshot(entries: registrations)
    }
```

##### Replace with this exact block

```swift
    private init(
        parent: Container,
        registrationBehavior: RegistrationBehavior,
        registrations: [ServiceKey: Registration]
    ) {
        self.parent = parent
        self.registrationBehavior = registrationBehavior
        self.state = OSAllocatedUnfairLock(
            uncheckedState: ContainerState(registrations: registrations)
        )
    }
```

#### Step 2.5 — replace `register(_:)`

##### Exact current block

```swift
    func register(_ registrations: [Registration]) {
        self.lock.withLock {
            var updated = self.mutableRegistrations
            for registration in registrations {
                if updated[registration.key] != nil {
                    self.handleDuplicateRegistration(for: registration.key)
                    continue
                }
                updated[registration.key] = registration
            }

            self.mutableRegistrations = updated
            self.registrationSnapshot = RegistrationSnapshot(entries: updated)
        }
    }
```

##### Replace with this exact block

```swift
    func register(_ registrations: [Registration]) {
        self.state.withLockUnchecked { state in
            var updated = state.registrations
            for registration in registrations {
                if updated[registration.key] != nil {
                    switch self.registrationBehavior {
                    case .strict:
                        fatalError(Self.duplicateRegistrationMessage(for: registration.key))
                    case .collecting:
                        let descriptor = ValidationError.DependencyDescriptor(
                            typeName: registration.key.typeName,
                            name: registration.key.name
                        )
                        state.validationErrors.append(
                            ValidationError(
                                kind: .duplicateRegistration,
                                dependency: descriptor,
                                message: Self.duplicateRegistrationMessage(for: registration.key)
                            )
                        )
                    }
                    continue
                }
                updated[registration.key] = registration
            }

            state.registrations = updated
        }
    }
```

#### Step 2.6 — replace `resetScopes()`

##### Exact current block

```swift
    public func resetScopes() {
        for registration in self.registrationSnapshot.entries.values {
            registration.singletonCell?.clear()
        }
    }
```

##### Replace with this exact block

```swift
    public func resetScopes() {
        for registration in self.localRegistrations() {
            registration.singletonCell?.clear()
        }
    }
```

#### Step 2.7 — replace `resetAll()`

##### Exact current block

```swift
    public func resetAll() {
        self.lock.withLock {
            self.mutableRegistrations.removeAll()
            self.registrationSnapshot = RegistrationSnapshot(entries: [:])
        }
    }
```

##### Replace with this exact block

```swift
    public func resetAll() {
        self.state.withLockUnchecked { state in
            state.registrations.removeAll()
        }
    }
```

#### Step 2.8 — update `resolveSingletonNoParameters`

##### Exact current block

```swift
    private func resolveSingletonNoParameters<T>(
        _ type: T.Type,
        key: ServiceKey,
        registration: Registration,
        context: ResolutionContext
    ) -> T {
        guard let singletonCell = registration.singletonCell else {
            fatalError(
                "Bolt: Internal error: singleton registration missing cache cell for \(Self.dependencyDescription(key))."
            )
        }

        if let cached = singletonCell.cachedValue {
            return Self.castOrFail(cached, expected: type, key: key)
        }

        self.pushResolutionServiceKeyOrFail(key: key, context: context)
        defer { context.stack.removeLast() }

        let resolved = singletonCell.getOrCreate {
            registration.factory.call(context, nil)
        }
        return Self.castOrFail(resolved, expected: type, key: key)
    }
```

##### Replace only the cached-value call so the block becomes

```swift
    private func resolveSingletonNoParameters<T>(
        _ type: T.Type,
        key: ServiceKey,
        registration: Registration,
        context: ResolutionContext
    ) -> T {
        guard let singletonCell = registration.singletonCell else {
            fatalError(
                "Bolt: Internal error: singleton registration missing cache cell for \(Self.dependencyDescription(key))."
            )
        }

        if let cached = singletonCell.cachedValue() {
            return Self.castOrFail(cached, expected: type, key: key)
        }

        self.pushResolutionServiceKeyOrFail(key: key, context: context)
        defer { context.stack.removeLast() }

        let resolved = singletonCell.getOrCreate {
            registration.factory.call(context, nil)
        }
        return Self.castOrFail(resolved, expected: type, key: key)
    }
```

This cached fast-path is required so already-initialized singleton reads do not unnecessarily push onto the resolution stack.

#### Step 2.9 — replace validation error helpers

##### Exact current block

```swift
    func collectedValidationErrors() -> [ValidationError] {
        self.lock.withLock { self.validationErrors }
    }

    func recordValidationError(_ error: ValidationError) {
        self.lock.withLock {
            self.validationErrors.append(error)
        }
    }
```

##### Replace with this exact block

```swift
    func collectedValidationErrors() -> [ValidationError] {
        self.state.withLock { $0.validationErrors }
    }

    func recordValidationError(_ error: ValidationError) {
        self.state.withLock { state in
            state.validationErrors.append(error)
        }
    }
```

#### Step 2.10 — replace the loop body in `effectiveRegistrationsForValidation()`

##### Exact current fragment

```swift
        for container in chain.reversed() {
            for (key, registration) in container.registrationSnapshot.entries {
                registrations[key] = registration
            }
        }
```

##### Replace with

```swift
        for container in chain.reversed() {
            for (key, registration) in container.currentRegistrations() {
                registrations[key] = registration
            }
        }
```

#### Step 2.11 — replace the duplicate-recording branch in `buildOverrideEntries(from:)`

##### Exact current block

```swift
                    self.lock.withLock {
                        self.validationErrors.append(
                            ValidationError(
                                kind: .duplicateRegistration,
                                dependency: descriptor,
                                message: Self.duplicateRegistrationMessage(for: registration.key)
                            )
                        )
                    }
```

##### Replace with

```swift
                    self.recordValidationError(
                        ValidationError(
                            kind: .duplicateRegistration,
                            dependency: descriptor,
                            message: Self.duplicateRegistrationMessage(for: registration.key)
                        )
                    )
```

#### Step 2.12 — insert helper methods immediately above `lookupRegistration(for:)`

##### Insert this exact block

```swift
    private func currentRegistrations() -> [ServiceKey: Registration] {
        self.state.withLockUnchecked { $0.registrations }
    }

    private func localRegistrations() -> [Registration] {
        self.state.withLockUnchecked { Array($0.registrations.values) }
    }

    private func localRegistration(for key: ServiceKey) -> Registration? {
        self.state.withLockUnchecked { $0.registrations[key] }
    }
```

#### Step 2.13 — replace `lookupRegistration(for:)`

##### Exact current block

```swift
    private func lookupRegistration(for key: ServiceKey) -> Registration? {
        if let registration = self.registrationSnapshot.entries[key] {
            return registration
        }
        return self.parent?.lookupRegistration(for: key)
    }
```

##### Replace with this exact block

```swift
    private func lookupRegistration(for key: ServiceKey) -> Registration? {
        if let registration = self.localRegistration(for: key) {
            return registration
        }
        return self.parent?.lookupRegistration(for: key)
    }
```

#### Step 2.14 — delete `handleDuplicateRegistration(for:)`

##### Delete this exact block entirely

```swift
    private func handleDuplicateRegistration(for key: ServiceKey) {
        switch self.registrationBehavior {
        case .strict:
            fatalError(Self.duplicateRegistrationMessage(for: key))
        case .collecting:
            let descriptor = ValidationError.DependencyDescriptor(typeName: key.typeName, name: key.name)
            self.validationErrors.append(
                ValidationError(
                    kind: .duplicateRegistration,
                    dependency: descriptor,
                    message: Self.duplicateRegistrationMessage(for: key)
                )
            )
        }
    }
```

#### Step 2.15 — delete `RegistrationSnapshot`

##### Delete this exact block entirely

```swift
private final class RegistrationSnapshot: @unchecked Sendable {
    let entries: [ServiceKey: Registration]

    init(entries: [ServiceKey: Registration]) {
        self.entries = entries
    }
}
```

#### Notes for the implementing agent
- Do **not** convert `Container` to an actor.
- Do **not** add `@Sendable` to any factory closure type.
- `withLockUnchecked` is required here because `Registration` and containers of `Registration` are intentionally non-`Sendable` in this design.

### File 3: `Sources/Bolt/Bolt.swift`

#### Step 3.1 — add the import

##### Exact current line

```swift
import Foundation
```

##### Replace with

```swift
import Foundation
import os
```

#### Step 3.2 — replace global shared storage

##### Exact current block

```swift
public enum Bolt {
    private static let sharedLock = NSLock()
    nonisolated(unsafe) private static var sharedStorage = Container()
#if DEBUG
    private static let setupConcurrencyGuard = SetupConcurrencyGuard()
#endif

    public static var shared: Container {
        sharedLock.withLock { sharedStorage }
    }
```

##### Replace with this exact block

```swift
private struct SharedContainerState: Sendable {
    var container = Container()
}

public enum Bolt {
    private static let sharedStorage = OSAllocatedUnfairLock(checkedState: SharedContainerState())
#if DEBUG
    private static let setupConcurrencyGuard = SetupConcurrencyGuard()
#endif

    public static var shared: Container {
        sharedStorage.withLock { $0.container }
    }
```

#### Step 3.3 — replace the assignment inside `setup(modules:)`

##### Exact current block

```swift
        let container = buildContainer(from: modules)
        sharedLock.withLock {
            sharedStorage = container
        }
```

##### Replace with

```swift
        let container = buildContainer(from: modules)
        sharedStorage.withLock { state in
            state.container = container
        }
```

This removes the global mutable static slot and replaces it with a `static let` lock-owned state cell.

### File 4: `Sources/Bolt/SetupConcurrencyGuard.swift`

#### Step 4.1 — add the import

##### Exact current line

```swift
import Foundation
```

##### Replace with

```swift
import Foundation
import os
```

#### Step 4.2 — replace the implementation

##### Exact current block

```swift
enum SetupConcurrencyGuardState {
    case proceed
    case overlap
}

final class SetupConcurrencyGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var activeCalls = 0

    func begin() -> SetupConcurrencyGuardState {
        self.lock.withLock {
            self.activeCalls += 1
            return self.activeCalls > 1 ? .overlap : .proceed
        }
    }

    func end() {
        self.lock.withLock {
            self.activeCalls -= 1
        }
    }
}
```

##### Replace with this exact block

```swift
enum SetupConcurrencyGuardState {
    case proceed
    case overlap
}

private struct SetupConcurrencyGuardStorage: Sendable {
    var activeCalls = 0
}

final class SetupConcurrencyGuard: Sendable {
    private let state = OSAllocatedUnfairLock(checkedState: SetupConcurrencyGuardStorage())

    func begin() -> SetupConcurrencyGuardState {
        self.state.withLock { state in
            state.activeCalls += 1
            return state.activeCalls > 1 ? .overlap : .proceed
        }
    }

    func end() {
        self.state.withLock { state in
            state.activeCalls -= 1
        }
    }
}
```

### File 5: `Sources/Bolt/ServiceKey.swift`

#### Step 5.1 — add the import

##### Exact current line

```swift
import Foundation
```

##### Replace with

```swift
import Foundation
import os
```

#### Step 5.2 — replace the intern-table storage and helpers

##### Exact current block

```swift
private enum KeyInternals {
    static let lock = NSLock()
    nonisolated(unsafe) static var knownIdentifierTable: [ObjectIdentifier: ObjectIdentifier] = [:]
    nonisolated(unsafe) static var nameToIdentifierTable: [String: ObjectIdentifier] = [:]
    nonisolated(unsafe) static var identifierToNameTable: [ObjectIdentifier: String] = [:]
}

private func normalizedTypeIdentifier(for type: Any.Type) -> ObjectIdentifier {
    KeyInternals.lock.withLock {
        let requested = ObjectIdentifier(type)
        if let cached = KeyInternals.knownIdentifierTable[requested] {
            return cached
        }

        let name = String(reflecting: type)
        let normalized = KeyInternals.nameToIdentifierTable[name, default: requested]

        KeyInternals.knownIdentifierTable[requested] = normalized
        KeyInternals.identifierToNameTable[normalized] = name

        return normalized
    }
}

private func lookupTypeName(for identifier: ObjectIdentifier) -> String? {
    KeyInternals.lock.withLock {
        KeyInternals.identifierToNameTable[identifier]
    }
}
```

##### Replace with this exact block

```swift
private struct KeyInternalsState: Sendable {
    var knownIdentifierTable: [ObjectIdentifier: ObjectIdentifier] = [:]
    var nameToIdentifierTable: [String: ObjectIdentifier] = [:]
    var identifierToNameTable: [ObjectIdentifier: String] = [:]
}

private enum KeyInternals {
    static let state = OSAllocatedUnfairLock(checkedState: KeyInternalsState())
}

private func normalizedTypeIdentifier(for type: Any.Type) -> ObjectIdentifier {
    KeyInternals.state.withLock { state in
        let requested = ObjectIdentifier(type)
        if let cached = state.knownIdentifierTable[requested] {
            return cached
        }

        let name = String(reflecting: type)
        let normalized = state.nameToIdentifierTable[name, default: requested]

        state.knownIdentifierTable[requested] = normalized
        state.identifierToNameTable[normalized] = name

        return normalized
    }
}

private func lookupTypeName(for identifier: ObjectIdentifier) -> String? {
    KeyInternals.state.withLock { state in
        state.identifierToNameTable[identifier]
    }
}
```

This is part of phase 1. `ServiceKey` should not remain on `NSLock` while the rest of production code is moved to `OSAllocatedUnfairLock`.

### File 6: `Sources/BoltTestSupport/BoltTestingTrait.swift`

#### Step 6.1 — update the `provideScope` signature

##### Exact current block

```swift
    public func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        try await Bolt.withModules(
            self.makeModules(),
            overrides: self.makeOverrides
        ) {
            try await function()
        }
    }
```

##### Replace with this exact block

```swift
    public func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable @concurrent () async throws -> Void
    ) async throws {
        try await Bolt.withModules(
            self.makeModules(),
            overrides: self.makeOverrides
        ) {
            try await function()
        }
    }
```

### File 7: `Sources/Bolt/Locking.swift`

#### Step 7.1 — add the import

##### Exact current line

```swift
import Foundation
```

##### Replace with

```swift
import Foundation
import os
```

#### Step 7.2 — keep the `NSLock` helper and add the `OSAllocatedUnfairLock` helper

##### Exact current block

```swift
import Foundation

extension NSLock {
    @inline(__always)
    func withLock<R>(_ body: () -> R) -> R {
        self.lock()
        defer { self.unlock() }
        return body()
    }
}
```

##### Replace with this exact block

```swift
import Foundation
import os

extension NSLock {
    @inline(__always)
    func withLock<R>(_ body: () -> R) -> R {
        self.lock()
        defer { self.unlock() }
        return body()
    }
}

extension OSAllocatedUnfairLock {
    init(checkedState: @Sendable @autoclosure () -> State) {
        self.init(uncheckedState: checkedState())
    }
}
```

#### Notes for the implementing agent
- Do not delete the existing `NSLock.withLock` helper in this slice.
- `checkedState` is a convenience for initialization only.
- The presence of `checkedState` does **not** imply that subsequent access can avoid `withLockUnchecked` when the protected state is intentionally non-`Sendable`.

### Exact verification commands for phase 1

These exact phase-1 edits were validated in a temporary working copy on 2026-04-23 using the commands below.

Run all of the following after the code changes:

```bash
swift build --target Bolt -Xswiftc -warn-concurrency -Xswiftc -strict-concurrency=complete -Xswiftc -enable-upcoming-feature -Xswiftc NonisolatedNonsendingByDefault
swift build -Xswiftc -warn-concurrency -Xswiftc -strict-concurrency=complete -Xswiftc -enable-upcoming-feature -Xswiftc NonisolatedNonsendingByDefault
swift test
swift test --sanitize=thread
```

Expected outcomes:
- strict-concurrency build of target `Bolt` passes
- strict-concurrency build of the whole package passes, including `BoltTestSupport`
- `swift test` passes
- thread sanitizer test run passes

### Non-negotiable acceptance criteria for phase 1

1. `SingletonCell` has no unsynchronized reads.
2. `SingletonCell` does **not** execute `build` while holding `OSAllocatedUnfairLock`.
3. `SingletonCell` retains a synchronized cached-value accessor used by `Container`.
4. `Container` has no `registrationSnapshot` storage and no `RegistrationSnapshot` type.
5. `Container.taskLocalCurrent` uses `@TaskLocal` without `nonisolated(unsafe)`.
6. `Bolt.shared` storage is backed by `OSAllocatedUnfairLock` and no longer uses a mutable global `sharedStorage` slot.
7. `ServiceKey` intern tables use `OSAllocatedUnfairLock` rather than `NSLock` + `nonisolated(unsafe)` statics.
8. `SetupConcurrencyGuard` uses `OSAllocatedUnfairLock`.
9. `Locking.swift` defines the `OSAllocatedUnfairLock(checkedState:)` convenience initializer.
10. `BoltTestSupport` builds under `NonisolatedNonsendingByDefault`.
11. No public API becomes async.
12. No registration closure type becomes `@Sendable`.

### Deferred work — not part of phase 1

The following ideas remain valid for later phases, but they are intentionally **not** part of the first implementation slice:
- immutable runtime graph types
- builder/runtime separation for container construction
- `Synchronization.Mutex` adoption if minimum OS support is raised further
- actor-bound registration APIs

### Actor-based services remain the preferred modern-concurrency pattern

This spec still prefers actor-based **services** over actor-based **registrations**:

```swift
actor SessionStore {
    private(set) var token: String?

    func update(token: String?) {
        self.token = token
    }
}

final class AppModule: DependencyModule {
    @ModuleBuilder
    override var body: ModuleDefinition {
        Singleton(SessionStore.self) { _ in SessionStore() }
    }
}
```

That keeps Bolt's core runtime model synchronous while allowing consumers to adopt actor isolation where shared mutable service state exists.

## Lock Strategy

### Default primitives

1. Use `OSAllocatedUnfairLock` as the default mutual-exclusion primitive in production code.
2. Prefer the `checkedState` convenience initializer when the initial-state expression can be created in a `@Sendable` autoclosure.
3. Use `uncheckedState:` directly when the initial-state expression must capture intentionally non-`Sendable` values.
4. Use `withLock` when the protected state and return values are `Sendable`.
5. Use `withLockUnchecked` only when the lock is intentionally guarding non-`Sendable` state such as `Any` or `Registration`.
6. Use `NSCondition` only when a synchronous waiting primitive is required, as in the singleton waiters used to avoid executing factory closures under the unfair lock.
7. Do not introduce new `NSLock`-based mutual exclusion in production sources.

### What Bolt should try to remove

1. Locking that exists only because mutable state is too widely shared.
2. Lock-free fast paths that race with lock-protected writes.
3. Broad container-level locks that cover unrelated concerns.

### What Bolt may still keep

1. Narrow synchronization around singleton cache cells.
2. Small, well-scoped synchronization around shared intern tables when those tables continue to exist.
3. Build/setup coordination for explicitly global APIs such as `Bolt.setup`.
4. Condition-based waiting for synchronous exactly-once initialization.

### What Bolt should avoid

1. Semaphores or queue-hopping as a substitute for ownership.
2. Holding unfair locks while executing user registration closures.
3. Hiding concurrency invariants behind large `@unchecked Sendable` surfaces.
4. Mixing multiple unrelated synchronization strategies when one narrow lock-owned state cell would suffice.

## Isolation Guidance by Component

### `Container.current` and scoped graph selection

- Continue to use `@TaskLocal`.
- Avoid unsafe annotations that are not required by the compiler or runtime model.
- Preserve lexical/task-local semantics across async suspension points.

### Container runtime storage

- Prefer immutable runtime graph data.
- If a shared reference must remain mutable, isolate that mutability to a very small internal state cell.

### Singleton caches

- Treat cache state as explicitly synchronized state.
- Do not mix synchronized writes with unsynchronized reads.
- Keep cache lifetime semantics unchanged:
  - base graph singleton caches live with the base graph
  - override graph singleton caches live only for that override scope

### `Bolt.shared` and setup

- Global setup remains a special-case global mutation API.
- Debug/test guardrails against overlapping setup calls remain appropriate.
- The implementation should prefer the smallest necessary mutable shared state for the global root graph.

### Validation

- Validation should avoid adding more shared mutable runtime state than needed.
- Prefer collecting validation output in a dedicated phase or dedicated structure rather than intermixing it with hot runtime resolution data.

### `ServiceKey` internals

- Re-evaluate whether identifier/name interning is worth persistent mutable global tables.
- If retained, isolate those tables narrowly and document the invariant.
- If the complexity outweighs the benefit, simplify rather than preserving global mutable caches by default.

## Region-Based Isolation Guidance

Region-based isolation should be used where it adds clarity without forcing public API breakage.

Good candidates:
- test-support helpers that build fresh arrays of modules/registrations and immediately hand them off
- internal helpers that assemble a fresh runtime graph and transfer ownership once
- one-shot build/validation flows

Poor candidates:
- public registration closures
- returned services
- long-lived shared singleton caches
- mutable global registries

This means RBI is helpful at the edges of the system, but Bolt's core runtime safety still comes from explicit ownership and narrow synchronization.

## Package / Toolchain Guidance

In a Swift 6.2 minimum world, Bolt should standardize its package story around Swift 6.2 behavior rather than treating 6.2-only checking as optional.

Recommended package/tooling direction:
- prefer a single Swift 6.2 manifest when practical
- build/test the whole package under the chosen 6.2 concurrency settings
- explicitly validate test-support targets, not just the main Bolt target

Recommended verification modes:
- normal `swift test`
- thread sanitizer runs for concurrency-sensitive suites
- build with stricter concurrency flags/future defaults used in CI

## Testing and Verification Matrix

1. **Concurrent singleton resolution**
   - many tasks resolve the same singleton
   - exactly one initialization occurs
   - all resolutions observe the same instance

2. **Concurrent factory resolution**
   - many tasks resolve the same factory registration
   - each resolution builds independently
   - no cross-task corruption of resolution state

3. **Task-local scoping**
   - sibling tasks with distinct overrides do not leak into each other
   - nested `withContainer` and `withOverrides` restore prior state correctly

4. **Async retention across suspension**
   - overrides remain active across `await`
   - exiting scope restores prior container/override state

5. **Global setup guardrails**
   - overlapping `Bolt.setup` calls still fail fast in debug/test contexts
   - `withModules` remains the recommended isolation path

6. **Swift 6.2 support-surface verification**
   - whole package builds under stricter 6.2 isolation settings
   - Swift Testing trait support continues to conform under explicit closure isolation requirements

7. **Documentation verification**
   - public docs state that Bolt's container internals are concurrency-safe
   - public docs state that service payload safety is still the user's responsibility

## Success Criteria

This effort is successful when:

1. Bolt's internal concurrency model no longer depends on unsynchronized shared reads.
2. The number of `@unchecked Sendable` / `nonisolated(unsafe)` usages is materially reduced, or any remaining uses are narrowly justified.
3. Bolt's synchronous resolution API remains unchanged and ergonomic.
4. Task-local scoping behavior remains intact.
5. Consumers can continue registering non-`Sendable` services and closures that capture non-`Sendable` state.
6. The whole package, including support targets, is credible under Swift 6.2 concurrency checking.

## Open Questions

1. Should Bolt retain public `Container.register` mutation as-is long term, or should a future version expose a clearer builder/runtime split publicly?
2. Should `ServiceKey` keep its current interning strategy, or should the implementation simplify to reduce global mutable state?
3. Should Bolt introduce an internal lock abstraction now, or first simplify ownership and only then replace the remaining lock primitive(s)?
4. If/when Bolt raises minimum OS support further, should `Synchronization.Mutex` become the default synchronization primitive?
5. Should README include explicit examples showing actor-based services as the preferred approach for shared mutable singletons?

## Recommended First Implementation Slice

The smallest safe first pass for this spec is:

1. tighten singleton cache synchronization
2. remove unsafe registration snapshot sharing
3. remove unnecessary `nonisolated(unsafe)` from task-local scoping
4. make package/test-support code pass under the selected Swift 6.2 isolation defaults

That slice improves correctness and 6.2 readiness without changing Bolt's public programming model.
