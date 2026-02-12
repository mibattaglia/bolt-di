import Benchmark
import Bolt

private final class BoltLeaf {}
private final class BoltMid {
    let leaf: BoltLeaf
    init(leaf: BoltLeaf) { self.leaf = leaf }
}
private final class BoltRoot {
    let mid: BoltMid
    init(mid: BoltMid) { self.mid = mid }
}

private func makeFactoryContainer() -> Container {
    let container = Container()
    container.register {
        Factory(BoltLeaf.self) { _ in BoltLeaf() }
        Factory(BoltMid.self) { resolver in
            BoltMid(leaf: resolver.get(BoltLeaf.self))
        }
        Factory(BoltRoot.self) { resolver in
            BoltRoot(mid: resolver.get(BoltMid.self))
        }
    }
    return container
}

private func makeFactoryWithParamsContainer() -> Container {
    let container = Container()
    container.register {
        FactoryWithParams(Int.self) { (_: Resolver, value: Int) in
            value + 1
        }
    }
    return container
}

private func makeSingletonContainer() -> Container {
    let container = Container()
    container.register {
        Singleton(BoltLeaf.self) { _ in BoltLeaf() }
    }
    return container
}

func registerBoltBenchmarks() {
    let boltFactoryContainer = makeFactoryContainer()
    let boltFactoryWithParamsContainer = makeFactoryWithParamsContainer()
    let boltSingletonContainer = makeSingletonContainer()

    benchmark("bolt_factory_resolve_leaf") {
        _ = boltFactoryContainer.get(BoltLeaf.self)
    }

    benchmark("bolt_factory_resolve_root") {
        _ = boltFactoryContainer.get(BoltRoot.self)
    }

    benchmark("bolt_factory_resolve_with_params") {
        _ = boltFactoryWithParamsContainer.get(Int.self, params: 41)
    }

    benchmark("bolt_singleton_warm_resolve") {
        _ = boltSingletonContainer.get(BoltLeaf.self)
        _ = boltSingletonContainer.get(BoltLeaf.self)
    }

    benchmark("bolt_singleton_cold_resolve") {
        boltSingletonContainer.resetScopes()
        _ = boltSingletonContainer.get(BoltLeaf.self)
    }

    benchmark("bolt_with_overrides_scope") {
        Bolt.withContainer(boltFactoryContainer) {
            Bolt.withOverrides {
                Factory(BoltLeaf.self) { _ in BoltLeaf() }
            } _: {
                _ = Bolt.inject(BoltRoot.self)
            }
        }
    }
}
