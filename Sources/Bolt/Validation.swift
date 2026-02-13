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

public struct BoltValidator {
    private let container: Container

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
                let instanceID = ObjectIdentifier(module)
                guard let definition = plan.definitionsByInstanceID[instanceID] else {
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

    public func validate(_ onError: (ValidationError) -> Void) {
        let registrations = self.container.effectiveRegistrationsForValidation()

        for error in self.container.collectedValidationErrors() {
            onError(error)
        }

        for registration in registrations.values {
            if let error = self.typeMismatchError(for: registration) {
                onError(error)
            }
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
