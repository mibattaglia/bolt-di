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
    private let params = ValidationParamsStore()

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
        self.params.set(params, for: ServiceKey(type, name: named))
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

        let dynamicErrors = ValidationErrorSink()
        let paramsSnapshot = self.params.snapshot()
        for registration in orderedRegistrations {
            let operation = ValidationOperation(
                registrations: registrations,
                params: paramsSnapshot,
                root: registration,
                errors: dynamicErrors
            )
            ValidationThread.run {
                operation.run()
            }
        }

        for error in dynamicErrors.errors() {
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
}

private final class ValidationParamsStore: @unchecked Sendable {
    private let lock = NSLock()
    private var params: [ServiceKey: Any] = [:]

    func set(_ params: Any, for key: ServiceKey) {
        self.lock.withLock {
            self.params[key] = params
        }
    }

    func snapshot() -> [ServiceKey: Any] {
        self.lock.withLock { self.params }
    }
}

private final class ValidationErrorSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ValidationError] = []

    func append(_ error: ValidationError) {
        self.lock.withLock {
            self.storage.append(error)
        }
    }

    func errors() -> [ValidationError] {
        self.lock.withLock { self.storage }
    }
}

private final class ValidationOperation: @unchecked Sendable {
    private let registrations: [ServiceKey: Registration]
    private let params: [ServiceKey: Any]
    private let root: Registration
    private let errors: ValidationErrorSink

    init(
        registrations: [ServiceKey: Registration],
        params: [ServiceKey: Any],
        root: Registration,
        errors: ValidationErrorSink
    ) {
        self.registrations = registrations
        self.params = params
        self.root = root
        self.errors = errors
    }

    func run() {
        let resolver = ValidationResolver(
            registrations: self.registrations,
            params: self.params,
            errors: self.errors
        )
        resolver.resolveRoot(self.root)
    }
}

private final class ValidationResolver: Resolver {
    private let registrations: [ServiceKey: Registration]
    private let params: [ServiceKey: Any]
    private let errors: ValidationErrorSink
    private var stack: [ServiceKey] = []

    init(
        registrations: [ServiceKey: Registration],
        params: [ServiceKey: Any],
        errors: ValidationErrorSink
    ) {
        self.registrations = registrations
        self.params = params
        self.errors = errors
    }

    func resolveRoot(_ registration: Registration) {
        let key = registration.key
        let params = self.rootParams(for: registration)
        self.resolveErased(key: key, registration: registration, params: params)
    }

    func get<T>(
        _ type: T.Type,
        named: String?,
        isolation: isolated (any Actor)?
    ) -> T {
        self.resolve(type, named: named, params: nil)
    }

    func get<T, P>(
        _ type: T.Type,
        named: String?,
        params: P,
        isolation: isolated (any Actor)?
    ) -> T {
        self.resolve(type, named: named, params: params)
    }

    private func resolve<T>(_ type: T.Type, named: String?, params: Any?) -> T {
        let key = ServiceKey(type, name: named)
        guard let registration = self.registrations[key] else {
            self.fail(
                kind: .missingRegistration,
                key: key,
                message: "Bolt validation failed: Missing registration for \(Self.dependencyDescription(key))."
            )
        }

        let resolved = self.resolveErased(key: key, registration: registration, params: params)
        guard let typed = resolved as? T else {
            self.fail(
                kind: .typeMismatch,
                key: key,
                message: "Bolt validation failed: Type mismatch for \(Self.dependencyDescription(key)). Expected \(String(reflecting: type)), got \(String(reflecting: Swift.type(of: resolved)))."
            )
        }
        return typed
    }

    @discardableResult
    private func resolveErased(key: ServiceKey, registration: Registration, params: Any?) -> Any {
        let callParams: Any?
        switch registration.shape {
        case .factoryNoParameters, .singletonNoParameters:
            if params != nil {
                self.fail(
                    kind: .typeMismatch,
                    key: key,
                    message: "Bolt validation failed: Unexpected params for \(Self.dependencyDescription(key)). Registration is not parameterized."
                )
            }
            callParams = nil
        case .factoryWithParameters:
            guard let params else {
                self.fail(
                    kind: .missingRegistration,
                    key: key,
                    message: "Bolt validation failed: Missing params for \(Self.dependencyDescription(key)). Expected \(String(reflecting: registration.factory.parameterType!))."
                )
            }
            if registration.factory.acceptsParameter?(params) == false {
                self.fail(
                    kind: .typeMismatch,
                    key: key,
                    message: "Bolt validation failed: Parameter type mismatch for \(Self.dependencyDescription(key)). Expected \(String(reflecting: registration.factory.parameterType!)), got \(String(reflecting: Swift.type(of: params)))."
                )
            }
            callParams = params
        }

        self.push(key)
        defer { _ = self.stack.popLast() }

        let resolved = registration.factory.call(self, callParams)
        if !registration.factory.acceptsOutput(resolved) {
            self.fail(
                kind: .typeMismatch,
                key: key,
                message: "Bolt validation failed: Type mismatch for \(Self.dependencyDescription(key)). Expected \(String(reflecting: registration.factory.outputType)), got \(String(reflecting: Swift.type(of: resolved)))."
            )
        }
        return resolved
    }

    private func rootParams(for registration: Registration) -> Any? {
        switch registration.shape {
        case .factoryNoParameters, .singletonNoParameters:
            return nil
        case .factoryWithParameters:
            guard let params = self.params[registration.key] else {
                self.fail(
                    kind: .missingRegistration,
                    key: registration.key,
                    message: "Bolt validation failed: Missing params for \(Self.dependencyDescription(registration.key)). Expected \(String(reflecting: registration.factory.parameterType!)). Add params with BoltValidator.addParams(_:for:named:) before validating."
                )
            }
            return params
        }
    }

    private func push(_ key: ServiceKey) {
        if self.stack.contains(key) {
            let cycle = self.stack + [key]
            self.fail(
                kind: .circularDependency,
                key: key,
                message: "Bolt validation failed: Circular dependency detected: \(cycle.map(Self.dependencyDescription).joined(separator: " -> "))."
            )
        }
        self.stack.append(key)
    }

    private func fail(kind: ValidationError.Kind, key: ServiceKey, message: String) -> Never {
        self.errors.append(
            ValidationError(
                kind: kind,
                dependency: ValidationError.DependencyDescriptor(typeName: key.typeName, name: key.name),
                message: message
            )
        )
        pthread_exit(nil)
    }

    private static func dependencyDescription(_ key: ServiceKey) -> String {
        "\(key.typeName) (name: \(key.name.map { "\"\($0)\"" } ?? "nil"))"
    }
}

private enum ValidationThread {
    private final class State: @unchecked Sendable {
        let operation: @Sendable () -> Void

        init(operation: @escaping @Sendable () -> Void) {
            self.operation = operation
        }
    }

    static func run(_ operation: @escaping @Sendable () -> Void) {
        let state = State(operation: operation)
        let unmanaged = Unmanaged.passRetained(state)
        var thread: pthread_t? = nil
        let result = pthread_create(
            &thread,
            nil,
            { pointer in
                let state = Unmanaged<State>.fromOpaque(pointer).takeUnretainedValue()
                state.operation()
                return nil
            },
            unmanaged.toOpaque()
        )

        guard result == 0, let thread else {
            unmanaged.release()
            operation()
            return
        }

        pthread_join(thread, nil)
        unmanaged.release()
    }
}
