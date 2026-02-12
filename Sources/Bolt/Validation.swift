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

public enum ValidationMode: Sendable {
    case basic
    case strictTest
}

public struct ValidationRequirement: Sendable {
    let key: Key

    public init<T>(_ type: T.Type = T.self, named: String? = nil) {
        self.key = Key(type, name: named)
    }
}

public struct BoltValidator {
    private let container: Container

    public init(container: Container) {
        self.container = container
    }

    public init(modules: [DependencyModule]) {
        let container = Container(registrationBehavior: .collecting)
        do {
            let orderedModules = try DependencyModule.orderedModules(from: modules)
            for module in orderedModules {
                module.defineDependencies(into: container)
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

    public func validate(_ onError: (ValidationError) -> Void) {
        self.validate(mode: .basic, required: [], onError)
    }

    public func validate(
        mode: ValidationMode = .basic,
        required requirements: [ValidationRequirement] = [],
        _ onError: (ValidationError) -> Void
    ) {
        let registrations = self.container.effectiveRegistrationsForValidation()

        for error in self.container.collectedValidationErrors() {
            onError(error)
        }

        for registration in registrations.values {
            if let error = self.typeMismatchError(for: registration) {
                onError(error)
            }
        }

        guard mode == .strictTest else { return }
        for requirement in requirements {
            guard registrations[requirement.key] == nil else { continue }
            onError(self.missingRegistrationError(for: requirement.key))
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

    private func missingRegistrationError(for key: Key) -> ValidationError {
        let descriptor = ValidationError.DependencyDescriptor(
            typeName: key.typeName,
            name: key.name
        )
        return ValidationError(
            kind: .missingRegistration,
            dependency: descriptor,
            message:
                "Bolt validation failed: Missing registration for \(key.typeName) (name: \(key.name.map { "\"\($0)\"" } ?? "nil"))."
        )
    }

}
