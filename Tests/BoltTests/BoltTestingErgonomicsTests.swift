import Testing

@testable import Bolt

private final class ErgonomicScopedValue {
    let value: String

    init(value: String) {
        self.value = value
    }
}

private final class ErgonomicStringModule: DependencyModule {
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

private final class ErgonomicStringDependencyModule: DependencyModule {
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

private final class ErgonomicRootModule: DependencyModule {
    @ModuleBuilder
    override var body: ModuleDefinition {
        DependentModules {
            ErgonomicStringDependencyModule(value: "from-dependent-module")
        }

        Factory(ErgonomicScopedValue.self) { resolver in
            ErgonomicScopedValue(value: resolver.get(String.self))
        }
    }
}

@Suite("Bolt Testing Ergonomics")
struct BoltTestingErgonomicsSuite {
    @Test func withModulesOverridingRegistrationsAppliesOverridesInsideScopedGraph() {
        Bolt.withModules(
            [ErgonomicStringModule(value: "base")],
            overrides: {
                Factory(String.self) { _ in "override" }
            }
        ) {
            let value: String = Bolt.inject()
            #expect(value == "override")
        }
    }

    @Test func withModulesOverridingRegistrationsRestoresBaseGraphAfterScope() {
        let container = Container()
        container.register {
            Factory(String.self) { _ in "outer" }
        }

        Bolt.withContainer(container) {
            let before: String = Bolt.inject()
            #expect(before == "outer")

            Bolt.withModules(
                [ErgonomicStringModule(value: "base")],
                overrides: {
                    Factory(String.self) { _ in "override" }
                }
            ) {
                let inside: String = Bolt.inject()
                #expect(inside == "override")
            }

            let after: String = Bolt.inject()
            #expect(after == "outer")
        }
    }

    @Test func asyncWithModulesOverridingRegistrationsRetainsOverridesAcrossAwait() async {
        await Bolt.withModules(
            [ErgonomicStringModule(value: "base")],
            overrides: {
                Factory(String.self) { _ in "override" }
            }
        ) {
            await Task.yield()
            let value: String = Bolt.inject()
            #expect(value == "override")
        }
    }

    @Test func withModulesOverridingRegistrationsIsEquivalentToNestedWithOverrides() {
        let nested = Bolt.withModules([ErgonomicStringModule(value: "base")]) {
            Bolt.withOverrides {
                Factory(String.self) { _ in "override" }
            } _: {
                let value: String = Bolt.inject()
                return value
            }
        }

        let sugared = Bolt.withModules(
            [ErgonomicStringModule(value: "base")],
            overrides: {
                Factory(String.self) { _ in "override" }
            }
        ) {
            let value: String = Bolt.inject()
            return value
        }

        #expect(sugared == nested)
    }

    @Test func moduleWithTestGraphAppliesOverridesInsideRootedGraph() {
        ErgonomicStringModule(value: "base").withTestGraph(
            overrides: {
                Factory(String.self) { _ in "override" }
            }
        ) {
            let value: String = Bolt.inject()
            #expect(value == "override")
        }
    }

    @Test func asyncModuleWithTestGraphRetainsOverridesAcrossAwait() async {
        await ErgonomicStringModule(value: "base").withTestGraph(
            overrides: {
                Factory(String.self) { _ in "override" }
            }
        ) {
            await Task.yield()
            let value: String = Bolt.inject()
            #expect(value == "override")
        }
    }

    @Test func moduleWithTestGraphIncludesDependentModulesTransitively() {
        ErgonomicRootModule().withTestGraph {
            let value: ErgonomicScopedValue = Bolt.inject()
            #expect(value.value == "from-dependent-module")
        }
    }
}
