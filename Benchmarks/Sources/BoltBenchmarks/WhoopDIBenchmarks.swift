import Benchmark
import WhoopDIKit

private final class WhoopLeaf {}
private final class WhoopMid {
    let leaf: WhoopLeaf
    init(leaf: WhoopLeaf) { self.leaf = leaf }
}
private final class WhoopRoot {
    let mid: WhoopMid
    init(mid: WhoopMid) { self.mid = mid }
}

private final class WhoopBenchmarkModule: DependencyModule {
    override func defineDependencies() {
        factory(name: "leaf_factory") { WhoopLeaf() }
        factory(name: "mid_factory") { try WhoopMid(leaf: self.get("leaf_factory")) }
        factory(name: "root_factory") { try WhoopRoot(mid: self.get("mid_factory")) }
        singleton(name: "leaf_singleton") { WhoopLeaf() }
        factoryWithParams(name: "int_plus_one") { (value: Int) in value + 1 }
    }
}

func registerWhoopDIBenchmarks() {
    WhoopDI.setup(modules: [WhoopBenchmarkModule()])

    benchmark("tier_a_whoopdi_factory_resolve_leaf") {
        let _: WhoopLeaf = WhoopDI.inject("leaf_factory")
    }

    benchmark("tier_a_whoopdi_factory_resolve_root") {
        let _: WhoopRoot = WhoopDI.inject("root_factory")
    }

    benchmark("tier_a_whoopdi_singleton_warm_resolve") {
        let _: WhoopLeaf = WhoopDI.inject("leaf_singleton")
        let _: WhoopLeaf = WhoopDI.inject("leaf_singleton")
    }

    benchmark("tier_a_whoopdi_local_inject_scope") {
        let _: WhoopRoot = WhoopDI.inject("root_factory") { module in
            module.factory(name: "leaf_factory") { WhoopLeaf() }
        }
    }

    benchmark("tier_b_whoopdi_factory_resolve_with_params") {
        let _: Int = WhoopDI.inject("int_plus_one", 41)
    }

    benchmark("tier_b_whoopdi_local_inject_definition_heavy") {
        let _: WhoopRoot = WhoopDI.inject("root_factory") { module in
            module.factory(name: "leaf_factory") { WhoopLeaf() }
            for index in 0..<10 {
                module.factory(name: "local_aux_\(index)") { index }
            }
        }
    }
}
