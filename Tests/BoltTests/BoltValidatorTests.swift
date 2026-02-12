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
    override var dependentModules: [DependencyModule] {
        [ModuleCycleLeaf()]
    }
}

private final class ModuleCycleLeaf: DependencyModule {
    override var dependentModules: [DependencyModule] {
        [ModuleCycleRoot()]
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
}
