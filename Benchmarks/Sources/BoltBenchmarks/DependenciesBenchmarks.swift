import Benchmark
import Dependencies
import Foundation

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

private func runNestedDependenciesOverrides(
    depth: Int,
    resolve: Bool,
    resolver: DependenciesResolver
) {
    func run(level: Int) {
        guard level < depth else {
            if resolve {
                _ = resolver.makeRoot()
            }
            return
        }

        withDependencies {
            $0.dependenciesLeafFactory = { DependenciesLeaf() }
        } operation: {
            run(level: level + 1)
        }
    }

    run(level: 0)
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

    benchmark("tier_b_dependencies_override_scope_entry_depth_3") {
        runNestedDependenciesOverrides(depth: 3, resolve: false, resolver: resolver)
    }

    benchmark("tier_b_dependencies_override_scope_entry_depth_10") {
        runNestedDependenciesOverrides(depth: 10, resolve: false, resolver: resolver)
    }

    benchmark("tier_b_dependencies_override_scope_resolve_depth_3") {
        runNestedDependenciesOverrides(depth: 3, resolve: true, resolver: resolver)
    }

    benchmark("tier_b_dependencies_override_scope_resolve_depth_10") {
        runNestedDependenciesOverrides(depth: 10, resolve: true, resolver: resolver)
    }

    benchmark("tier_b_dependencies_override_scope_entry_contention") {
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "dependencies.overrides.contention", attributes: .concurrent)

        for _ in 0..<4 {
            group.enter()
            queue.async {
                runNestedDependenciesOverrides(depth: 1, resolve: false, resolver: resolver)
                group.leave()
            }
        }

        group.wait()
    }
}
