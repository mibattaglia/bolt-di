import Testing

@testable import Bolt

private final class ScopedBox {
    let label: String

    init(label: String) {
        self.label = label
    }
}

@Suite("Container Task-Local Scoping")
struct ContainerTaskLocalScopingSuite {
    @Test func withContainerAppliesWithinLexicalScope() {
        let outer = Container()
        outer.register {
            Factory(String.self) { _ in "outer" }
        }

        let inner = Container()
        inner.register {
            Factory(String.self) { _ in "inner" }
        }

        Bolt.withContainer(outer) {
            let first: String = Container.current.get()
            #expect(first == "outer")

            Bolt.withContainer(inner) {
                let nested: String = Container.current.get()
                #expect(nested == "inner")
            }

            let afterNested: String = Container.current.get()
            #expect(afterNested == "outer")
        }
    }
}

@Suite("Container Scoped Overrides")
struct ContainerScopedOverridesSuite {
    @Test func topmostOverrideWinsAndRestoresAfterPop() {
        let container = Container()
        container.register {
            Factory(String.self) { _ in "base" }
        }

        Bolt.withContainer(container) {
            let base: String = Container.current.get()
            #expect(base == "base")

            Bolt.withOverrides {
                Factory(String.self) { _ in "override-1" }
            } _: {
                let firstOverride: String = Container.current.get()
                #expect(firstOverride == "override-1")

                Bolt.withOverrides {
                    Factory(String.self) { _ in "override-2" }
                } _: {
                    let secondOverride: String = Container.current.get()
                    #expect(secondOverride == "override-2")
                }

                let restoredFirstOverride: String = Container.current.get()
                #expect(restoredFirstOverride == "override-1")
            }

            let restoredBase: String = Container.current.get()
            #expect(restoredBase == "base")
        }
    }

    @Test func overrideSingletonCacheIsIsolatedPerLayerLifetime() {
        let container = Container()
        container.register {
            Singleton(ScopedBox.self) { _ in ScopedBox(label: "base") }
        }

        var firstLayerInstance: ScopedBox?
        var secondLayerInstance: ScopedBox?

        Bolt.withContainer(container) {
            let baseBefore: ScopedBox = Container.current.get()
            #expect(baseBefore.label == "base")

            Bolt.withOverrides {
                Singleton(ScopedBox.self) { _ in ScopedBox(label: "override") }
            } _: {
                let one: ScopedBox = Container.current.get()
                let two: ScopedBox = Container.current.get()
                #expect(one === two)
                #expect(one.label == "override")
                firstLayerInstance = one
            }

            Bolt.withOverrides {
                Singleton(ScopedBox.self) { _ in ScopedBox(label: "override") }
            } _: {
                let current: ScopedBox = Container.current.get()
                #expect(current.label == "override")
                secondLayerInstance = current
            }

            let baseAfter: ScopedBox = Container.current.get()
            #expect(baseAfter === baseBefore)
            #expect(baseAfter.label == "base")
        }

        #expect(firstLayerInstance != nil)
        #expect(secondLayerInstance != nil)
        #expect(firstLayerInstance !== secondLayerInstance)
    }

    @Test func overridesAreTaskLocalForConcurrentResolutions() async {
        let container = Container()
        container.register {
            Factory(String.self) { _ in "base" }
        }

        let values = await withTaskGroup(of: String.self, returning: [String].self) { group in
            group.addTask {
                Bolt.withContainer(container) {
                    Bolt.withOverrides {
                        Factory(String.self) { _ in "task-a" }
                    } _: {
                        let value: String = Bolt.inject()
                        return value
                    }
                }
            }

            group.addTask {
                Bolt.withContainer(container) {
                    Bolt.withOverrides {
                        Factory(String.self) { _ in "task-b" }
                    } _: {
                        let value: String = Bolt.inject()
                        return value
                    }
                }
            }

            group.addTask {
                Bolt.withContainer(container) {
                    let value: String = Bolt.inject()
                    return value
                }
            }

            var resolved: [String] = []
            for await value in group {
                resolved.append(value)
            }
            return resolved
        }

        #expect(Set(values) == ["task-a", "task-b", "base"])
    }

    @Test func asyncWithOverridesRetainsOverrideAcrossAwait() async {
        let container = Container()
        container.register {
            Factory(String.self) { _ in "base" }
        }

        await Bolt.withContainer(container) {
            let base: String = Bolt.inject()
            #expect(base == "base")

            let overridden = await Bolt.withOverrides {
                Factory(String.self) { _ in "override" }
            } _: {
                await Task.yield()
                let value: String = Bolt.inject()
                return value
            }

            #expect(overridden == "override")

            let restored: String = Bolt.inject()
            #expect(restored == "base")
        }
    }
}
