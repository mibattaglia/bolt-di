import Testing

@testable import Bolt

private final class ValidatorDuplicateModuleA: DependencyModule {
    override func defineDependencies(into container: Container) {
        container.register {
            Factory(String.self) { _ in "a" }
        }
    }
}

private final class ValidatorDuplicateModuleB: DependencyModule {
    override func defineDependencies(into container: Container) {
        container.register {
            Factory(String.self) { _ in "b" }
        }
    }
}

private final class ModuleCycleRoot: DependencyModule {
    lazy var leaf = ModuleCycleLeaf(root: self)

    override var dependentModules: [DependencyModule] {
        [self.leaf]
    }
}

private final class ModuleCycleLeaf: DependencyModule {
    unowned let root: ModuleCycleRoot

    init(root: ModuleCycleRoot) {
        self.root = root
        super.init()
    }

    override var dependentModules: [DependencyModule] {
        [self.root]
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
                key: Key(String.self),
                scope: .factory,
                factory: ErasedFactory(
                    outputType: Int.self,
                    parameterType: nil,
                    factory: { _, _ in 42 }
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

    @Test func strictTestModeReportsMissingRequiredRegistrations() {
        let container = Container()
        container.register {
            Factory(String.self) { _ in "ok" }
        }

        let validator = BoltValidator(container: container)
        var errors: [ValidationError] = []
        validator.validate(mode: .strictTest, required: [ValidationRequirement(Int.self)]) { error in
            errors.append(error)
        }

        #expect(errors.count == 1)
        #expect(errors.first?.kind == .missingRegistration)
        #expect(errors.first?.dependency?.typeName == String(reflecting: Int.self))
    }

    @Test func strictTestModePassesWhenRequiredRegistrationsExist() {
        let container = Container()
        container.register {
            Factory(String.self) { _ in "ok" }
        }

        let validator = BoltValidator(container: container)
        var errors: [ValidationError] = []
        validator.validate(
            mode: .strictTest,
            required: [ValidationRequirement(String.self)]
        ) { error in
            errors.append(error)
        }

        #expect(errors.isEmpty)
    }
}
