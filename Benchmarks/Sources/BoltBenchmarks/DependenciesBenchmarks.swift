import Benchmark
import Dependencies

private struct DependenciesLeaf: Sendable {}
private struct DependenciesMid: Sendable {
    let leaf: DependenciesLeaf
}
private struct DependenciesRoot: Sendable {
    let mid: DependenciesMid
}

private enum DependenciesLeafFactoryKey: DependencyKey {
    static let liveValue: @Sendable () -> DependenciesLeaf = { DependenciesLeaf() }
}

private enum DependenciesMidFactoryKey: DependencyKey {
    static let liveValue: @Sendable () -> DependenciesMid = {
        @Dependency(\.dependenciesLeafFactory) var makeLeaf
        return DependenciesMid(leaf: makeLeaf())
    }
}

private enum DependenciesRootFactoryKey: DependencyKey {
    static let liveValue: @Sendable () -> DependenciesRoot = {
        @Dependency(\.dependenciesMidFactory) var makeMid
        return DependenciesRoot(mid: makeMid())
    }
}

private enum DependenciesSingletonLeafKey: DependencyKey {
    static let liveValue: DependenciesLeaf = .init()
}

private extension DependencyValues {
    var dependenciesLeafFactory: @Sendable () -> DependenciesLeaf {
        get { self[DependenciesLeafFactoryKey.self] }
        set { self[DependenciesLeafFactoryKey.self] = newValue }
    }

    var dependenciesMidFactory: @Sendable () -> DependenciesMid {
        get { self[DependenciesMidFactoryKey.self] }
        set { self[DependenciesMidFactoryKey.self] = newValue }
    }

    var dependenciesRootFactory: @Sendable () -> DependenciesRoot {
        get { self[DependenciesRootFactoryKey.self] }
        set { self[DependenciesRootFactoryKey.self] = newValue }
    }

    var dependenciesSingletonLeaf: DependenciesLeaf {
        get { self[DependenciesSingletonLeafKey.self] }
        set { self[DependenciesSingletonLeafKey.self] = newValue }
    }
}

private struct DependenciesResolver {
    @Dependency(\.dependenciesLeafFactory) var makeLeaf
    @Dependency(\.dependenciesRootFactory) var makeRoot
    @Dependency(\.dependenciesSingletonLeaf) var singletonLeaf
}

func registerDependenciesBenchmarks() {
    let resolver = DependenciesResolver()

    benchmark("tier_a_dependencies_factory_resolve_leaf") {
        _ = resolver.makeLeaf()
    }

    benchmark("tier_a_dependencies_factory_resolve_root") {
        _ = resolver.makeRoot()
    }

    benchmark("tier_a_dependencies_singleton_warm_resolve") {
        _ = resolver.singletonLeaf
        _ = resolver.singletonLeaf
    }

    benchmark("tier_a_dependencies_override_scope") {
        withDependencies {
            $0.dependenciesLeafFactory = { DependenciesLeaf() }
        } operation: {
            _ = resolver.makeRoot()
        }
    }
}
