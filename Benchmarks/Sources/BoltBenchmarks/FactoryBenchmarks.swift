import Benchmark
import Factory
import Foundation

private final class FactoryLeaf {}
private final class FactoryMid {
    let leaf: FactoryLeaf
    init(leaf: FactoryLeaf) { self.leaf = leaf }
}
private final class FactoryRoot {
    let mid: FactoryMid
    init(mid: FactoryMid) { self.mid = mid }
}

private typealias FactoryLeafFactory = Factory<FactoryLeaf>
private typealias FactoryMidFactory = Factory<FactoryMid>
private typealias FactoryRootFactory = Factory<FactoryRoot>

extension Container {
    fileprivate var benchFactoryLeaf: FactoryLeafFactory {
        self { FactoryLeaf() }
    }

    fileprivate var benchFactoryMid: FactoryMidFactory {
        self { FactoryMid(leaf: self.benchFactoryLeaf()) }
    }

    fileprivate var benchFactoryRoot: FactoryRootFactory {
        self { FactoryRoot(mid: self.benchFactoryMid()) }
    }

    fileprivate var benchSingletonLeaf: FactoryLeafFactory {
        self { FactoryLeaf() }.singleton
    }
}

private func runNestedFactoryOverrides(
    container: Container,
    depth: Int,
    resolve: Bool
) {
    func run(level: Int) {
        guard level < depth else {
            if resolve {
                _ = container.benchFactoryRoot()
            }
            return
        }

        container.manager.push()
        defer { container.manager.pop() }
        container.benchFactoryLeaf.register { FactoryLeaf() }
        run(level: level + 1)
    }

    run(level: 0)
}

func registerFactoryBenchmarks() {
    let factoryContainer = Container.shared
    factoryContainer.benchFactoryLeaf.register { FactoryLeaf() }
    factoryContainer.benchFactoryMid.register { FactoryMid(leaf: factoryContainer.benchFactoryLeaf()) }
    factoryContainer.benchFactoryRoot.register { FactoryRoot(mid: factoryContainer.benchFactoryMid()) }
    factoryContainer.benchSingletonLeaf.register { FactoryLeaf() }

    benchmark("tier_a_factory_factory_resolve_leaf") {
        _ = factoryContainer.benchFactoryLeaf()
    }

    benchmark("tier_a_factory_factory_resolve_root") {
        _ = factoryContainer.benchFactoryRoot()
    }

    benchmark("tier_a_factory_singleton_warm_resolve") {
        _ = factoryContainer.benchSingletonLeaf()
        _ = factoryContainer.benchSingletonLeaf()
    }

    benchmark("tier_a_factory_override_scope") {
        factoryContainer.manager.push()
        defer { factoryContainer.manager.pop() }
        factoryContainer.benchFactoryLeaf.register { FactoryLeaf() }
        _ = factoryContainer.benchFactoryRoot()
    }

    benchmark("tier_b_factory_override_scope_entry_depth_3") {
        runNestedFactoryOverrides(
            container: factoryContainer,
            depth: 3,
            resolve: false
        )
    }

    benchmark("tier_b_factory_override_scope_entry_depth_10") {
        runNestedFactoryOverrides(
            container: factoryContainer,
            depth: 10,
            resolve: false
        )
    }

    benchmark("tier_b_factory_override_scope_resolve_depth_3") {
        runNestedFactoryOverrides(
            container: factoryContainer,
            depth: 3,
            resolve: true
        )
    }

    benchmark("tier_b_factory_override_scope_resolve_depth_10") {
        runNestedFactoryOverrides(
            container: factoryContainer,
            depth: 10,
            resolve: true
        )
    }
}
