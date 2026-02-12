import Foundation

public struct DependencyEdge: Hashable, Sendable {
    public let from: Key
    public let to: Key

    public init(from: Key, to: Key) {
        self.from = from
        self.to = to
    }
}

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
    private let edges: [DependencyEdge]

    public init(container: Container, edges: [DependencyEdge] = []) {
        self.container = container
        self.edges = edges
    }

    public init(modules: [DependencyModule], edges: [DependencyEdge] = []) {
        let container = Container(registrationBehavior: .collecting)
        for module in modules {
            module.defineDependencies(into: container)
        }
        self.container = container
        self.edges = edges
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

        for error in self.missingRegistrationErrors(registrations: registrations) {
            onError(error)
        }

        for error in self.circularDependencyErrors(registrations: registrations) {
            onError(error)
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

    private func missingRegistrationErrors(registrations: [Key: Registration]) -> [ValidationError] {
        var missingKeys = Set<Key>()
        for edge in self.edges where registrations[edge.to] == nil {
            missingKeys.insert(edge.to)
        }

        return missingKeys.map { key in
            let descriptor = ValidationError.DependencyDescriptor(typeName: key.typeName, name: key.name)
            return ValidationError(
                kind: .missingRegistration,
                dependency: descriptor,
                message:
                    "Bolt: Missing registration for \(key.typeName) (name: \(key.name.map { "\"\($0)\"" } ?? "nil"))."
            )
        }
    }

    private func circularDependencyErrors(registrations: [Key: Registration]) -> [ValidationError] {
        enum VisitState {
            case visiting
            case visited
        }

        let availableKeys = Set(registrations.keys)
        let filteredEdges = self.edges.filter {
            availableKeys.contains($0.from) && availableKeys.contains($0.to)
        }
        let graph = Dictionary(grouping: filteredEdges, by: \.from)

        var visitStates: [Key: VisitState] = [:]
        var recursionStack: [Key] = []
        var cycleMessages = Set<String>()
        var errors: [ValidationError] = []

        func dfs(_ key: Key) {
            visitStates[key] = .visiting
            recursionStack.append(key)

            let dependencies = graph[key]?.map(\.to) ?? []
            for dependency in dependencies {
                if visitStates[dependency] == .visiting {
                    if let index = recursionStack.lastIndex(of: dependency) {
                        let cycle = Array(recursionStack[index...]) + [dependency]
                        let cyclePath = cycle.map {
                            "\($0.typeName) (name: \($0.name.map { "\"\($0)\"" } ?? "nil"))"
                        }.joined(separator: " -> ")
                        let message = "Bolt: Circular dependency detected: \(cyclePath)."
                        if cycleMessages.insert(message).inserted {
                            let descriptor = ValidationError.DependencyDescriptor(
                                typeName: dependency.typeName,
                                name: dependency.name
                            )
                            errors.append(
                                ValidationError(
                                    kind: .circularDependency,
                                    dependency: descriptor,
                                    message: message
                                )
                            )
                        }
                    }
                } else if visitStates[dependency] == nil {
                    dfs(dependency)
                }
            }

            _ = recursionStack.popLast()
            visitStates[key] = .visited
        }

        for key in graph.keys where visitStates[key] == nil {
            dfs(key)
        }

        return errors
    }
}
