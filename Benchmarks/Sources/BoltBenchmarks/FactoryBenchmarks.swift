import Benchmark
import Factory

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
}
