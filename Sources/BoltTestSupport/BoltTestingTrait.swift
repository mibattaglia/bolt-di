#if canImport(Testing)
import Bolt
import Testing

public struct _BoltDependenciesTrait: TestTrait, SuiteTrait, TestScoping {
    let makeModules: @Sendable () -> [DependencyModule]
    let makeOverrides: @Sendable () -> [Registration]

    public var isRecursive: Bool { true }

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
}

extension Trait where Self == _BoltDependenciesTrait {
    public static func boltDependencies(
        @ModuleBuilder modules: @escaping @Sendable () -> [DependencyModule]
    ) -> Self {
        Self(makeModules: modules, makeOverrides: { [] })
    }

    public static func boltDependencies(
        @ModuleBuilder modules: @escaping @Sendable () -> [DependencyModule],
        @DependencyBuilder overrides: @escaping @Sendable () -> [Registration]
    ) -> Self {
        Self(makeModules: modules, makeOverrides: overrides)
    }
}
#endif
