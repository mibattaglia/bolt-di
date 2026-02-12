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

private final class MissingDependencyMarker {}

private final class ValidatorMissingDependencyModule: DependencyModule {
    override func defineDependencies(into container: Container) {
        container.register {
            Factory(
                Int.self,
                dependencies: [Key(MissingDependencyMarker.self)]
            ) { _ in
                1
            }
        }
    }
}

private final class CycleA {}
private final class CycleB {}

private final class ValidatorCircularDependencyModule: DependencyModule {
    override func defineDependencies(into container: Container) {
        container.register {
            Factory(
                CycleA.self,
                dependencies: [Key(CycleB.self)]
            ) { _ in
                CycleA()
            }

            Factory(
                CycleB.self,
                dependencies: [Key(CycleA.self)]
            ) { _ in
                CycleB()
            }
        }
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
                dependencies: [],
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

    @Test func detectsMissingRegistrationsFromDependencyMetadata() {
        let validator = BoltValidator(modules: [ValidatorMissingDependencyModule()])

        var errors: [ValidationError] = []
        validator.validate { error in
            errors.append(error)
        }

        #expect(errors.count == 1)
        #expect(errors.first?.kind == .missingRegistration)
        #expect(errors.first?.dependency?.typeName == String(reflecting: MissingDependencyMarker.self))
    }

    @Test func detectsCircularDependenciesFromDependencyMetadata() {
        let validator = BoltValidator(modules: [ValidatorCircularDependencyModule()])

        var errors: [ValidationError] = []
        validator.validate { error in
            errors.append(error)
        }

        #expect(errors.count == 1)
        #expect(errors.first?.kind == .circularDependency)
        #expect(errors.first?.message.contains("CycleA") == true)
        #expect(errors.first?.message.contains("CycleB") == true)
    }
}
