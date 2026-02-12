import Foundation

public enum Bolt {
    private static let sharedLock = NSLock()
    nonisolated(unsafe) private static var sharedStorage = Container()

    public static var shared: Container {
        sharedLock.withLock { sharedStorage }
    }

    public static func setup(modules: [DependencyModule]) {
        let container = Container()
        for module in modules {
            module.defineDependencies(into: container)
        }
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

    public static func withOverrides<R>(
        @DependencyBuilder _ overrides: () -> [Registration], _ body: () throws -> R
    ) rethrows -> R {
        try Container.current.withOverrideLayer(overrides) {
            try body()
        }
    }
}
