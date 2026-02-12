import Benchmark
import Bolt
import Foundation

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

private func runNestedOverrides(depth: Int, resolve: Bool, container: Container) {
    Bolt.withContainer(container) {
        runOverrideLevel(current: 0, maxDepth: depth, resolve: resolve)
    }
}

private func runOverrideLevel(current: Int, maxDepth: Int, resolve: Bool) {
    guard current < maxDepth else {
        if resolve {
            _ = Bolt.inject(BoltRoot.self)
        }
        return
    }

    Bolt.withOverrides {
        Factory(BoltLeaf.self) { _ in BoltLeaf() }
    } _: {
        runOverrideLevel(current: current + 1, maxDepth: maxDepth, resolve: resolve)
    }
}

func registerBoltBenchmarks() {
    let boltFactoryContainer = makeFactoryContainer()
    let boltFactoryWithParamsContainer = makeFactoryWithParamsContainer()
    let boltSingletonContainer = makeSingletonContainer()

    benchmark("tier_a_bolt_factory_resolve_leaf") {
        _ = boltFactoryContainer.get(BoltLeaf.self)
    }

    benchmark("tier_a_bolt_factory_resolve_root") {
        _ = boltFactoryContainer.get(BoltRoot.self)
    }

    benchmark("tier_b_bolt_factory_resolve_with_params") {
        _ = boltFactoryWithParamsContainer.get(Int.self, params: 41)
    }

    benchmark("tier_a_bolt_singleton_warm_resolve") {
        _ = boltSingletonContainer.get(BoltLeaf.self)
        _ = boltSingletonContainer.get(BoltLeaf.self)
    }

    benchmark("tier_b_bolt_singleton_cold_resolve") {
        boltSingletonContainer.resetScopes()
        _ = boltSingletonContainer.get(BoltLeaf.self)
    }

    benchmark("tier_a_bolt_with_overrides_scope_entry_depth_1") {
        runNestedOverrides(depth: 1, resolve: false, container: boltFactoryContainer)
    }

    benchmark("tier_b_bolt_with_overrides_scope_entry_depth_3") {
        runNestedOverrides(depth: 3, resolve: false, container: boltFactoryContainer)
    }

    benchmark("tier_b_bolt_with_overrides_scope_entry_depth_10") {
        runNestedOverrides(depth: 10, resolve: false, container: boltFactoryContainer)
    }

    benchmark("tier_a_bolt_with_overrides_resolve_depth_1") {
        runNestedOverrides(depth: 1, resolve: true, container: boltFactoryContainer)
    }

    benchmark("tier_b_bolt_with_overrides_resolve_depth_3") {
        runNestedOverrides(depth: 3, resolve: true, container: boltFactoryContainer)
    }

    benchmark("tier_b_bolt_with_overrides_resolve_depth_10") {
        runNestedOverrides(depth: 10, resolve: true, container: boltFactoryContainer)
    }

    benchmark("tier_b_bolt_with_overrides_scope_entry_contention") {
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "bolt.overrides.contention", attributes: .concurrent)

        for _ in 0..<4 {
            group.enter()
            queue.async {
                runNestedOverrides(depth: 1, resolve: false, container: boltFactoryContainer)
                group.leave()
            }
        }

        group.wait()
    }
}
