import Bolt
import BoltTestSupport
import Testing

private final class TraitScopedBox {
}

private final class TraitStringModule: DependencyModule {
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

private final class TraitScopedBoxModule: DependencyModule {
    @ModuleBuilder
    override var body: ModuleDefinition {
        Singleton(TraitScopedBox.self) { _ in TraitScopedBox() }
    }
}

private actor TraitIdentityRecorder {
    struct Snapshot {
        let count: Int
        let uniqueCount: Int
    }

    private var identifiers: [ObjectIdentifier] = []

    func record(_ identifier: ObjectIdentifier) -> Snapshot {
        self.identifiers.append(identifier)
        return Snapshot(
            count: self.identifiers.count,
            uniqueCount: Set(self.identifiers).count
        )
    }
}

@Suite("Bolt Test Support Trait Basics")
struct BoltTestingTraitBasicsSuite {
    @Test(
        .boltDependencies(modules: {
            TraitStringModule(value: "base")
        })
    )
    func boltDependenciesTraitBuildsGraphAndResolves() {
        let value: String = Bolt.inject()
        #expect(value == "base")
    }

    @Test(
        .boltDependencies(
            modules: {
                TraitStringModule(value: "base")
            },
            overrides: {
                Factory(String.self) { _ in "override" }
            }
        )
    )
    func boltDependenciesTraitAppliesOverrides() {
        let value: String = Bolt.inject()
        #expect(value == "override")
    }
}

@Suite(
    "Bolt Test Support Trait Isolation",
    .boltDependencies(modules: {
        TraitScopedBoxModule()
    })
)
struct BoltTestingTraitIsolationSuite {
    private static let recorder = TraitIdentityRecorder()
    private static let expectedCount = 3

    @Test func firstTraitScopedTestGetsItsOwnSingletonCache() async {
        await Self.assertFreshSingletonScopePerTest()
    }

    @Test func secondTraitScopedTestGetsItsOwnSingletonCache() async {
        await Self.assertFreshSingletonScopePerTest()
    }

    @Test func thirdTraitScopedTestGetsItsOwnSingletonCache() async {
        await Self.assertFreshSingletonScopePerTest()
    }

    private static func assertFreshSingletonScopePerTest() async {
        let first: TraitScopedBox = Bolt.inject()
        let second: TraitScopedBox = Bolt.inject()
        #expect(first === second)

        let snapshot = await self.recorder.record(ObjectIdentifier(first))
        if snapshot.count == self.expectedCount {
            #expect(snapshot.uniqueCount == self.expectedCount)
        }
    }
}
