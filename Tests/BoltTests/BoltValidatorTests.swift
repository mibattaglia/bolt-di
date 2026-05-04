import Foundation
import Testing

@testable import Bolt

private final class ValidatorDuplicateModuleA: DependencyModule {
    @ModuleBuilder
    override var body: ModuleDefinition {
        Factory(String.self) { _ in "a" }
    }
}

private final class ValidatorDuplicateModuleB: DependencyModule {
    @ModuleBuilder
    override var body: ModuleDefinition {
        Factory(String.self) { _ in "b" }
    }
}

private final class ModuleCycleRoot: DependencyModule {
    lazy var leaf = ModuleCycleLeaf(root: self)

    @ModuleBuilder
    override var body: ModuleDefinition {
        DependentModules {
            self.leaf
        }
    }
}

private final class ModuleCycleLeaf: DependencyModule {
    unowned let root: ModuleCycleRoot

    init(root: ModuleCycleRoot) {
        self.root = root
        super.init()
    }

    @ModuleBuilder
    override var body: ModuleDefinition {
        DependentModules {
            self.root
        }
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

private final class PlannerLeafModule: DependencyModule {
    private let counter: PlannerEvaluationCounter

    init(counter: PlannerEvaluationCounter) {
        self.counter = counter
        super.init()
    }

    override var body: ModuleDefinition {
        self.counter.increment()
        return ModuleDefinition(
            registrations: [
                Factory(Int.self) { _ in 1 }.registration
            ]
        )
    }
}

private final class PlannerRootModule: DependencyModule {
    let leaf: PlannerLeafModule
    private let counter: PlannerEvaluationCounter
    private let name: String

    init(leaf: PlannerLeafModule, counter: PlannerEvaluationCounter, name: String) {
        self.leaf = leaf
        self.counter = counter
        self.name = name
        super.init()
    }

    override var serviceKey: ServiceKey {
        // Distinct root names opt into distinct logical modules under serviceKey-based planning.
        ServiceKey(type(of: self), name: self.name)
    }

    override var body: ModuleDefinition {
        self.counter.increment()
        return ModuleDefinition(
            dependentModules: [self.leaf],
            registrations: [Factory(String.self, named: self.name) { _ in self.name }.registration]
        )
    }
}

@Suite("Bolt Validator")
struct BoltValidatorSuite {
    @Test func detectsDuplicateRegistrationsAcrossModules() {
        let validator = BoltValidator(
            modules: [ValidatorDuplicateModuleA(), ValidatorDuplicateModuleB()]
        )

        var errors: [ValidationError] = []
        validator.validate { error in
            errors.append(error)
        }

        #expect(errors.count == 1)
        #expect(errors.first?.kind == .duplicateRegistration)
        #expect(errors.first?.dependency?.typeName == String(reflecting: String.self))
    }

    @Test func detectsTypeMismatchInMalformedRegistration() {
        let container = Container()
        container.register {
            Registration(
                key: ServiceKey(String.self),
                scope: .factory,
                isolation: .none,
                factory: ErasedFactory(
                    outputType: Int.self,
                    parameterType: nil,
                    call: { _, _ in 42 }
                )
            )
        }

        let validator = BoltValidator(container: container)
        var errors: [ValidationError] = []
        validator.validate { error in
            errors.append(error)
        }

        #expect(errors.count == 1)
        #expect(errors.first?.kind == .typeMismatch)
        #expect(errors.first?.dependency?.typeName == String(reflecting: String.self))
    }

    @Test func reportsNoErrorsForValidContainer() {
        let container = Container()
        container.register {
            Singleton(Int.self) { _ in 1 }
            Factory(String.self) { _ in "ok" }
        }

        let validator = BoltValidator(container: container)
        var errors: [ValidationError] = []
        validator.validate { error in
            errors.append(error)
        }

        #expect(errors.isEmpty)
    }

    @Test func detectsCircularModuleDependencies() {
        let validator = BoltValidator(modules: [ModuleCycleRoot()])

        var errors: [ValidationError] = []
        validator.validate { error in
            errors.append(error)
        }

        #expect(errors.count == 1)
        #expect(errors.first?.kind == .circularDependency)
        #expect(errors.first?.message.contains("ModuleCycleRoot") == true)
        #expect(errors.first?.message.contains("ModuleCycleLeaf") == true)
    }

    @Test func moduleValidationConvenienceUsesModuleGraph() {
        var errors: [ValidationError] = []
        BoltValidator.validate(module: ValidatorDuplicateModuleA()) { error in
            errors.append(error)
        }

        #expect(errors.isEmpty)
    }

    @Test func withModulesAndValidatorEvaluateEachVisitedBodyExactlyOnce() {
        let setupLeafCounter = PlannerEvaluationCounter()
        let setupRootCounter = PlannerEvaluationCounter()
        let sharedLeafForSetup = PlannerLeafModule(counter: setupLeafCounter)
        let setupRootA = PlannerRootModule(
            leaf: sharedLeafForSetup,
            counter: setupRootCounter,
            name: "setup-a"
        )
        let setupRootB = PlannerRootModule(
            leaf: sharedLeafForSetup,
            counter: setupRootCounter,
            name: "setup-b"
        )

        Bolt.withModules([setupRootA, setupRootB]) {
            let first: String = Bolt.inject(named: "setup-a")
            let second: String = Bolt.inject(named: "setup-b")
            #expect(first == "setup-a")
            #expect(second == "setup-b")
        }
        let setupLeafEvaluations = setupLeafCounter.count()
        let setupRootEvaluations = setupRootCounter.count()

        let validatorLeafCounter = PlannerEvaluationCounter()
        let validatorRootCounter = PlannerEvaluationCounter()
        let sharedLeafForValidator = PlannerLeafModule(counter: validatorLeafCounter)
        let validatorRootA = PlannerRootModule(
            leaf: sharedLeafForValidator,
            counter: validatorRootCounter,
            name: "validator-a"
        )
        let validatorRootB = PlannerRootModule(
            leaf: sharedLeafForValidator,
            counter: validatorRootCounter,
            name: "validator-b"
        )

        _ = BoltValidator(modules: [validatorRootA, validatorRootB])
        let validatorLeafEvaluations = validatorLeafCounter.count()
        let validatorRootEvaluations = validatorRootCounter.count()

        #expect(setupLeafEvaluations == 1)
        #expect(setupRootEvaluations == 2)
        #expect(validatorLeafEvaluations == 1)
        #expect(validatorRootEvaluations == 2)
        #expect(setupLeafEvaluations == validatorLeafEvaluations)
        #expect(setupRootEvaluations == validatorRootEvaluations)
    }
}
