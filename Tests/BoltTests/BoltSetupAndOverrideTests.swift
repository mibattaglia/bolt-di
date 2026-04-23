import Foundation
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

private final class GuardFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set(_ value: Bool) {
        self.lock.withLock {
            self.value = value
        }
    }

    func get() -> Bool {
        self.lock.withLock { self.value }
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

private final class KeyedLabeledModule: DependencyModule {
    let label: String

    init(label: String) {
        self.label = label
        super.init()
    }

    override var serviceKey: ServiceKey {
        ServiceKey(type(of: self), name: self.label)
    }

    @ModuleBuilder
    override var body: ModuleDefinition {
        Factory(String.self, named: self.label) { _ in self.label }
    }
}

private final class SharedNetworkingModule: DependencyModule {
    let source: String

    init(source: String) {
        self.source = source
        super.init()
    }

    @ModuleBuilder
    override var body: ModuleDefinition {
        Singleton(String.self, named: "api-client-source") { _ in self.source }
    }
}

private class BaseFeatureUsingSharedNetworkingModule: DependencyModule {
    let featureName: String

    init(featureName: String) {
        self.featureName = featureName
        super.init()
    }

    @ModuleBuilder
    override var body: ModuleDefinition {
        DependentModules {
            SharedNetworkingModule(source: self.featureName)
        }

        Factory(String.self, named: self.featureName) { _ in self.featureName }
    }
}

private final class FeatureUsingSharedNetworkingModuleA: BaseFeatureUsingSharedNetworkingModule {
    init() {
        super.init(featureName: "feature-a")
    }
}

private final class FeatureUsingSharedNetworkingModuleB: BaseFeatureUsingSharedNetworkingModule {
    init() {
        super.init(featureName: "feature-b")
    }
}

private final class KeyedSharedNetworkingModule: DependencyModule {
    let source: String

    init(source: String) {
        self.source = source
        super.init()
    }

    override var serviceKey: ServiceKey {
        ServiceKey(type(of: self), name: self.source)
    }

    @ModuleBuilder
    override var body: ModuleDefinition {
        Singleton(String.self, named: self.source) { _ in self.source }
    }
}

private class BaseFeatureUsingKeyedNetworkingModule: DependencyModule {
    let featureName: String

    init(featureName: String) {
        self.featureName = featureName
        super.init()
    }

    @ModuleBuilder
    override var body: ModuleDefinition {
        DependentModules {
            KeyedSharedNetworkingModule(source: self.featureName)
        }
    }
}

private final class FeatureUsingKeyedNetworkingModuleA: BaseFeatureUsingKeyedNetworkingModule {
    init() {
        super.init(featureName: "feature-a")
    }
}

private final class FeatureUsingKeyedNetworkingModuleB: BaseFeatureUsingKeyedNetworkingModule {
    init() {
        super.init(featureName: "feature-b")
    }
}

private final class PlannerEvaluationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        self.lock.withLock {
            self.value += 1
        }
    }

    func count() -> Int {
        self.lock.withLock { self.value }
    }
}

private final class CountingModule: DependencyModule {
    private let counter: PlannerEvaluationCounter
    private let keyName: String?

    init(counter: PlannerEvaluationCounter, keyName: String? = nil) {
        self.counter = counter
        self.keyName = keyName
        super.init()
    }

    override var serviceKey: ServiceKey {
        guard let keyName else { return super.serviceKey }
        return ServiceKey(type(of: self), name: keyName)
    }

    override var body: ModuleDefinition {
        self.counter.increment()
        return ModuleDefinition(
            registrations: [
                Factory(Int.self, named: self.keyName) { _ in 1 }.registration
            ]
        )
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

    @Test func withModulesCoalescesDuplicateTopLevelModulesByDefaultServiceKey() throws {
        let first = LabeledModule(label: "A")
        let second = LabeledModule(label: "B")

        let plan = try DependencyModule.planGraph(from: [first, second])
        #expect(plan.orderedModules.count == 1)
        #expect(plan.orderedModules.first === first)

        Bolt.withModules([first, second]) {
            let resolved: String = Bolt.inject(named: "A")
            #expect(resolved == "A")
        }

        let validator = BoltValidator(modules: [first, second])
        var errors: [ValidationError] = []
        validator.validate { error in
            errors.append(error)
        }
        #expect(errors.isEmpty)
    }

    @Test func withModulesAllowsSameConcreteTypeMultipleTimesWhenServiceKeyDiffers() throws {
        let first = KeyedLabeledModule(label: "A")
        let second = KeyedLabeledModule(label: "B")

        let plan = try DependencyModule.planGraph(from: [first, second])
        #expect(plan.orderedModules.count == 2)

        Bolt.withModules([first, second]) {
            let a: String = Bolt.inject(named: "A")
            let b: String = Bolt.inject(named: "B")

            #expect(a == "A")
            #expect(b == "B")
        }
    }

    @Test func dependentModulesCoalesceByDefaultServiceKey() {
        Bolt.withModules([
            FeatureUsingSharedNetworkingModuleA(),
            FeatureUsingSharedNetworkingModuleB(),
        ]) {
            // feature-a is discovered first, so its shared dependency wins for the default serviceKey.
            let source: String = Bolt.inject(named: "api-client-source")
            let featureA: String = Bolt.inject(named: "feature-a")
            let featureB: String = Bolt.inject(named: "feature-b")

            #expect(source == "feature-a")
            #expect(featureA == "feature-a")
            #expect(featureB == "feature-b")
        }
    }

    @Test func dependentModulesAllowSameConcreteTypeWhenServiceKeyDiffers() {
        Bolt.withModules([
            FeatureUsingKeyedNetworkingModuleA(),
            FeatureUsingKeyedNetworkingModuleB(),
        ]) {
            let a: String = Bolt.inject(named: "feature-a")
            let b: String = Bolt.inject(named: "feature-b")

            #expect(a == "feature-a")
            #expect(b == "feature-b")
        }
    }

    @Test func plannerEvaluatesOneBodyPerUniqueServiceKey() {
        let sharedCounter = PlannerEvaluationCounter()
        _ = BoltValidator(modules: [
            CountingModule(counter: sharedCounter),
            CountingModule(counter: sharedCounter),
        ])
        #expect(sharedCounter.count() == 1)

        let distinctCounter = PlannerEvaluationCounter()
        _ = BoltValidator(modules: [
            CountingModule(counter: distinctCounter, keyName: "A"),
            CountingModule(counter: distinctCounter, keyName: "B"),
        ])
        #expect(distinctCounter.count() == 2)
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

@Suite("Bolt Setup Concurrency Guard")
struct BoltSetupConcurrencyGuardSuite {
    @Test func beginReturnsProceedForSingleCaller() {
        let guardrail = SetupConcurrencyGuard()
        let first = guardrail.begin()
        #expect(first == .proceed)
        guardrail.end()
    }

    @Test func beginReturnsOverlapWhenAnotherCallIsActive() async {
        let guardrail = SetupConcurrencyGuard()
        let firstEntered = GuardFlag()
        let firstCanExit = GuardFlag()
        firstCanExit.set(false)

        let states = await withTaskGroup(
            of: SetupConcurrencyGuardState.self,
            returning: [SetupConcurrencyGuardState].self
        ) { group in
            group.addTask {
                let state = guardrail.begin()
                firstEntered.set(true)
                while !firstCanExit.get() {
                    await Task.yield()
                }
                guardrail.end()
                return state
            }

            group.addTask {
                while !firstEntered.get() {
                    await Task.yield()
                }
                let state = guardrail.begin()
                guardrail.end()
                firstCanExit.set(true)
                return state
            }

            var collected: [SetupConcurrencyGuardState] = []
            for await state in group {
                collected.append(state)
            }
            return collected
        }

        #expect(states.count == 2)
        #expect(states.contains(.proceed))
        #expect(states.contains(.overlap))
    }

    @Test func beginCanProceedAgainAfterBalancedEnd() {
        let guardrail = SetupConcurrencyGuard()

        let first = guardrail.begin()
        #expect(first == .proceed)
        guardrail.end()

        let second = guardrail.begin()
        #expect(second == .proceed)
        guardrail.end()
    }
}
