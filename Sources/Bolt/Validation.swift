import Foundation

public struct ValidationError: Error, Sendable {
    public struct DependencyDescriptor: Hashable, Sendable {
        public let typeName: String
        public let name: String?

        public init(typeName: String, name: String?) {
            self.typeName = typeName
            self.name = name
        }
    }

    public enum Kind: Sendable {
        case duplicateRegistration
        case missingRegistration
        case typeMismatch
        case circularDependency
    }

    public let kind: Kind
    public let dependency: DependencyDescriptor?
    public let message: String

    public init(kind: Kind, dependency: DependencyDescriptor?, message: String) {
        self.kind = kind
        self.dependency = dependency
        self.message = message
    }
}

public final class BoltValidator {
    private let container: Container
    private var params: [ServiceKey: Any] = [:]

    public static func validate(module: DependencyModule, _ onError: (ValidationError) -> Void) {
        BoltValidator(modules: [module]).validate(onError)
    }

    public init(container: Container) {
        self.container = container
    }

    public init(modules: [DependencyModule]) {
        let container = Container(registrationBehavior: .collecting)
        do {
            let plan = try DependencyModule.planGraph(from: modules)
            for module in plan.orderedModules {
                guard let definition = plan.definitionsByServiceKey[module.serviceKey] else {
                    fatalError("Bolt: Internal error: missing module definition cache.")
                }
                container.register(definition.registrations)
            }
        } catch ModuleGraphError.cycle(let path) {
            container.recordValidationError(
                ValidationError(
                    kind: .circularDependency,
                    dependency: nil,
                    message: "Bolt: Circular module dependency detected: \(path.joined(separator: " -> "))."
                )
            )
        } catch {
            container.recordValidationError(
                ValidationError(
                    kind: .circularDependency,
                    dependency: nil,
                    message: "Bolt: Failed to resolve module dependency graph."
                )
            )
        }
        self.container = container
    }

    public func addParams<T>(_ params: Any, for type: T.Type, named: String? = nil) {
        self.params[ServiceKey(type, name: named)] = params
    }

    public func validate(_ onError: (ValidationError) -> Void) {
        let registrations = self.container.effectiveRegistrationsForValidation()
        let orderedRegistrations = registrations.values.sorted { lhs, rhs in
            if lhs.key.typeName != rhs.key.typeName {
                return lhs.key.typeName < rhs.key.typeName
            }
            return (lhs.key.name ?? "") < (rhs.key.name ?? "")
        }

        for error in self.container.collectedValidationErrors() {
            onError(error)
        }

        for registration in orderedRegistrations {
            if let error = self.typeMismatchError(for: registration) {
                onError(error)
            }
        }

        for registration in orderedRegistrations {
            do {
                try self.container.validate(
                    registration: registration,
                    params: try self.validationParams(for: registration)
                )
            } catch let error as ResolutionError {
                onError(error.validationError)
            } catch {
                onError(
                    ValidationError(
                        kind: .typeMismatch,
                        dependency: ValidationError.DependencyDescriptor(
                            typeName: registration.key.typeName,
                            name: registration.key.name
                        ),
                        message: "Bolt validation failed: Dependency factory for \(registration.key.typeName) threw error: \(error)."
                    )
                )
            }
        }
    }

    private func validationParams(for registration: Registration) throws -> Any? {
        switch registration.shape {
        case .factoryNoParameters, .singletonNoParameters:
            return nil
        case .factoryWithParameters:
            guard let params = self.params[registration.key] else {
                throw ResolutionError.missingParameter(
                    registration.key,
                    expected: registration.factory.parameterType!
                )
            }
            return params
        }
    }

    private func typeMismatchError(for registration: Registration) -> ValidationError? {
        let expectedType = registration.key.typeID
        let actualType = ObjectIdentifier(registration.factory.outputType)
        guard expectedType != actualType else { return nil }

        let descriptor = ValidationError.DependencyDescriptor(
            typeName: registration.key.typeName,
            name: registration.key.name
        )
        return ValidationError(
            kind: .typeMismatch,
            dependency: descriptor,
            message:
                "Bolt validation failed: Type mismatch for \(registration.key.typeName) (name: \(registration.key.name.map { "\"\($0)\"" } ?? "nil"))."
        )
    }
}
