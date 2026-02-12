import Testing

@testable import Bolt

private final class OrderedValue {
    let value: String

    init(value: String) {
        self.value = value
    }
}

private final class OrderedModuleA: DependencyModule {
    override func defineDependencies(into container: Container) {
        container.register {
            Factory(String.self) { _ in "A" }
        }
    }
}

private final class OrderedModuleB: DependencyModule {
    override var dependentModules: [DependencyModule] {
        [OrderedModuleA()]
    }

    override func defineDependencies(into container: Container) {
        container.register {
            Factory(OrderedValue.self) { resolver in
                OrderedValue(value: resolver.get(String.self))
            }
        }
    }
}

private final class LabeledModule: DependencyModule {
    let label: String

    init(label: String) {
        self.label = label
        super.init()
    }

    override func defineDependencies(into container: Container) {
        container.register {
            Factory(String.self, named: self.label) { _ in self.label }
        }
    }
}

@Suite("Bolt Setup And Overrides")
struct BoltSetupAndOverridesSuite {
    @Test func setupAppliesModulesInOrderForDependentResolution() {
        Bolt.setup(modules: [OrderedModuleB()])

        let value: OrderedValue = Bolt.inject()
        #expect(value.value == "A")
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

    @Test func setupRunsDistinctModuleInstancesEvenWhenTypesMatch() {
        Bolt.setup(modules: [LabeledModule(label: "A"), LabeledModule(label: "B")])

        let first: String = Bolt.inject(named: "A")
        let second: String = Bolt.inject(named: "B")

        #expect(first == "A")
        #expect(second == "B")
    }
}
