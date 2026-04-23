import Foundation

public enum Bolt {
    private static let sharedLock = NSLock()
    nonisolated(unsafe) private static var sharedStorage = Container()
#if DEBUG
    private static let setupConcurrencyGuard = SetupConcurrencyGuard()
#endif

    public static var shared: Container {
        sharedLock.withLock { sharedStorage }
    }

    public static func setup(modules: [DependencyModule]) {
#if DEBUG
        let setupGuardState = setupConcurrencyGuard.begin()
        if setupGuardState == .overlap {
            fatalError(
                "Bolt: Concurrent Bolt.setup(modules:) calls detected during debug/testing. Use Bolt.withModules(_:_: ) to isolate test graphs."
            )
        }
        defer { setupConcurrencyGuard.end() }
#endif
        let container = buildContainer(from: modules)
        sharedLock.withLock {
            sharedStorage = container
        }
    }

    public static func inject<T>(_ type: T.Type = T.self, named: String? = nil) -> T {
        Container.current.get(type, named: named)
    }

    public static func inject<T, P>(_ type: T.Type = T.self, named: String? = nil, params: P) -> T {
        Container.current.get(type, named: named, params: params)
    }

    public static func withContainer<R>(_ container: Container, _ body: () throws -> R) rethrows -> R {
        try Container.withCurrent(container) {
            try body()
        }
    }

    public static func withContainer<R>(_ container: Container, _ body: () async throws -> R) async rethrows -> R {
        try await Container.withCurrent(container) {
            try await body()
        }
    }

    public static func withModules<R>(_ modules: [DependencyModule], _ body: () throws -> R) rethrows -> R {
        let container = buildContainer(from: modules)
        return try withContainer(container) {
            try body()
        }
    }

    public static func withModules<R>(
        _ modules: [DependencyModule],
        @DependencyBuilder overrides: () -> [Registration],
        _ body: () throws -> R
    ) rethrows -> R {
        let container = buildContainer(from: modules)
        return try withContainer(container) {
            try withOverrides(overrides) {
                try body()
            }
        }
    }

    public static func withModules<R>(_ modules: [DependencyModule], _ body: () async throws -> R) async rethrows -> R
    {
        let container = buildContainer(from: modules)
        return try await withContainer(container) {
            try await body()
        }
    }

    public static func withModules<R>(
        _ modules: [DependencyModule],
        @DependencyBuilder overrides: () -> [Registration],
        _ body: () async throws -> R
    ) async rethrows -> R {
        let container = buildContainer(from: modules)
        return try await withContainer(container) {
            try await withOverrides(overrides) {
                try await body()
            }
        }
    }

    public static func withOverrides<R>(
        @DependencyBuilder _ overrides: () -> [Registration], _ body: () throws -> R
    ) rethrows -> R {
        try Container.current.withScopedOverrides(overrides) {
            try body()
        }
    }

    public static func withOverrides<R>(
        @DependencyBuilder _ overrides: () -> [Registration], _ body: () async throws -> R
    ) async rethrows -> R {
        try await Container.current.withScopedOverrides(overrides) {
            try await body()
        }
    }

    private static func buildContainer(from modules: [DependencyModule]) -> Container {
        let container = Container()
        let plan: ModulePlan
        do {
            plan = try DependencyModule.planGraph(from: modules)
        } catch ModuleGraphError.cycle(let path) {
            fatalError("Bolt: Circular module dependency detected: \(path.joined(separator: " -> ")).")
        } catch {
            fatalError("Bolt: Failed to resolve module dependencies.")
        }

        for module in plan.orderedModules {
            guard let definition = plan.definitionsByServiceKey[module.serviceKey] else {
                fatalError("Bolt: Internal error: missing module definition cache.")
            }
            container.register(definition.registrations)
        }

        return container
    }
}
