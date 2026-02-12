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
            Factory(Int.self) { _ in
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
            Factory(CycleA.self) { _ in
                CycleA()
            }

            Factory(CycleB.self) { _ in
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

    @Test func detectsMissingRegistrationsFromValidatorEdges() {
        let validator = BoltValidator(
            modules: [ValidatorMissingDependencyModule()],
            edges: [
                DependencyEdge(
                    from: Key(Int.self),
                    to: Key(MissingDependencyMarker.self)
                )
            ]
        )

        var errors: [ValidationError] = []
        validator.validate { error in
            errors.append(error)
        }

        #expect(errors.count == 1)
        #expect(errors.first?.kind == .missingRegistration)
        #expect(errors.first?.dependency?.typeName == String(reflecting: MissingDependencyMarker.self))
    }

    @Test func detectsCircularDependenciesFromValidatorEdges() {
        let validator = BoltValidator(
            modules: [ValidatorCircularDependencyModule()],
            edges: [
                DependencyEdge(from: Key(CycleA.self), to: Key(CycleB.self)),
                DependencyEdge(from: Key(CycleB.self), to: Key(CycleA.self)),
            ]
        )

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
