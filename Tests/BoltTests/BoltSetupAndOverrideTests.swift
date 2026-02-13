import Testing

@testable import Bolt

private final class OrderedValue {
    let value: String

    init(value: String) {
        self.value = value
    }
}

private final class OrderedModuleA: DependencyModule {
    @ModuleBuilder
    override var body: ModuleDefinition {
        Factory(String.self) { _ in "A" }
    }
}

private final class OrderedModuleB: DependencyModule {
    @ModuleBuilder
    override var body: ModuleDefinition {
        DependentModules {
            OrderedModuleA()
        }

        Factory(OrderedValue.self) { resolver in
            OrderedValue(value: resolver.get(String.self))
        }
    }
}

private final class ScopedStringModule: DependencyModule {
    let value: String

    init(value: String) {
        self.value = value
        super.init()
    }

    @ModuleBuilder
    override var body: ModuleDefinition {
        Factory(String.self) { _ in self.value }
    }
}

private final class LabeledModule: DependencyModule {
    let label: String

    init(label: String) {
        self.label = label
        super.init()
    }

    @ModuleBuilder
    override var body: ModuleDefinition {
        Factory(String.self, named: self.label) { _ in self.label }
    }
}

@Suite("Bolt Setup And Overrides")
struct BoltSetupAndOverridesSuite {
    @Test func withModulesAppliesModulesInOrderForDependentResolution() {
        Bolt.withModules([OrderedModuleB()]) {
            let value: OrderedValue = Bolt.inject()
            #expect(value.value == "A")
        }
    }

    @Test func withOverridesWorksForParameterizedRegistrations() {
        let container = Container()
        container.register {
            FactoryWithParams(String.self, named: "greeting") { (_: Resolver, name: String) in
                "Base \(name)"
            }
        }

        Bolt.withContainer(container) {
            let base: String = Bolt.inject(named: "greeting", params: "A")
            #expect(base == "Base A")

            Bolt.withOverrides {
                FactoryWithParams(String.self, named: "greeting") { (_: Resolver, name: String) in
                    "Override \(name)"
                }
            } _: {
                let overridden: String = Bolt.inject(named: "greeting", params: "A")
                #expect(overridden == "Override A")
            }

            let restored: String = Bolt.inject(named: "greeting", params: "A")
            #expect(restored == "Base A")
        }
    }

    @Test func withModulesRunsDistinctModuleInstancesEvenWhenTypesMatch() {
        Bolt.withModules([LabeledModule(label: "A"), LabeledModule(label: "B")]) {
            let first: String = Bolt.inject(named: "A")
            let second: String = Bolt.inject(named: "B")

            #expect(first == "A")
            #expect(second == "B")
        }
    }

    @Test func withModulesIsolatesConcurrentGraphs() async {
        let labels = Set((0..<32).map { "graph-\($0)" })

        let resolvedPairs = await withTaskGroup(of: (String, String).self, returning: [(String, String)].self)
        { group in
            for label in labels {
                group.addTask {
                    await Bolt.withModules([ScopedStringModule(value: label)]) {
                        await Task.yield()
                        let resolved: String = Bolt.inject()
                        return (label, resolved)
                    }
                }
            }

            var pairs: [(String, String)] = []
            for await pair in group {
                pairs.append(pair)
            }
            return pairs
        }

        #expect(resolvedPairs.count == labels.count)
        for (expected, actual) in resolvedPairs {
            #expect(expected == actual)
        }
    }

    @Test func withModulesSupportsNestedWithOverridesAcrossAsyncBoundaries() async {
        await Bolt.withModules([ScopedStringModule(value: "base")]) {
            let base: String = Bolt.inject()
            #expect(base == "base")

            let firstLayer = await Bolt.withOverrides {
                Factory(String.self) { _ in "override-1" }
            } _: {
                await Task.yield()
                let first: String = Bolt.inject()
                #expect(first == "override-1")

                let nested = await Bolt.withOverrides {
                    Factory(String.self) { _ in "override-2" }
                } _: {
                    await Task.yield()
                    let second: String = Bolt.inject()
                    return second
                }
                #expect(nested == "override-2")

                await Task.yield()
                let restoredFirst: String = Bolt.inject()
                #expect(restoredFirst == "override-1")
                return restoredFirst
            }

            #expect(firstLayer == "override-1")

            let restoredBase: String = Bolt.inject()
            #expect(restoredBase == "base")
        }
    }
}

@Suite("Bolt Global Setup Smoke", .serialized)
struct BoltGlobalSetupSmokeSuite {
    @Test func setupAppliesModulesToGlobalGraph() {
        Bolt.setup(modules: [OrderedModuleB()])

        let value: OrderedValue = Bolt.inject()
        #expect(value.value == "A")
    }
}
