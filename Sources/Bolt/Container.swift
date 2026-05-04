import Foundation

public final class Container: Resolver, @unchecked Sendable {
    @TaskLocal static var taskLocalCurrent: Container?

    public static var current: Container {
        Self.taskLocalCurrent ?? Bolt.shared
    }

    private let lock = NSLock()
    private var mutableRegistrations: [ServiceKey: Registration] = [:]
    nonisolated(unsafe) private var registrationSnapshot = RegistrationSnapshot(entries: [:])

    private let registrationBehavior: RegistrationBehavior
    private var validationErrors: [ValidationError] = []
    private let parent: Container?

    public init() {
        self.parent = nil
        self.registrationBehavior = .strict
    }

    init(registrationBehavior: RegistrationBehavior) {
        self.parent = nil
        self.registrationBehavior = registrationBehavior
    }

    private init(
        parent: Container,
        registrationBehavior: RegistrationBehavior,
        registrations: [ServiceKey: Registration]
    ) {
        self.parent = parent
        self.registrationBehavior = registrationBehavior
        self.mutableRegistrations = registrations
        self.registrationSnapshot = RegistrationSnapshot(entries: registrations)
    }

    public func register(@DependencyBuilder _ registrations: () -> [Registration]) {
        self.register(registrations())
    }

    func register(_ registrations: [Registration]) {
        self.lock.withLock {
            var updated = self.mutableRegistrations
            for registration in registrations {
                if updated[registration.key] != nil {
                    self.handleDuplicateRegistration(for: registration.key)
                    continue
                }
                updated[registration.key] = registration
            }

            self.mutableRegistrations = updated
            self.registrationSnapshot = RegistrationSnapshot(entries: updated)
        }
    }

    public func get<T>(
        _ type: T.Type = T.self,
        named: String? = nil,
        isolation: isolated (any Actor)? = #isolation
    ) -> T {
        let context = ResolutionContext(container: self, isolation: .capture(isolation))
        do {
            return try context.get(type, named: named, isolation: isolation)
        } catch {
            fatalError(Self.resolutionFailureMessage(error))
        }
    }

    public func get<T, P>(
        _ type: T.Type = T.self,
        named: String? = nil,
        params: P,
        isolation: isolated (any Actor)? = #isolation
    ) -> T {
        let context = ResolutionContext(container: self, isolation: .capture(isolation))
        do {
            return try context.get(type, named: named, params: params, isolation: isolation)
        } catch {
            fatalError(Self.resolutionFailureMessage(error))
        }
    }

    public func resetScopes() {
        for registration in self.registrationSnapshot.entries.values {
            registration.singletonCell?.clear()
        }
    }

    public func resetAll() {
        self.lock.withLock {
            self.mutableRegistrations.removeAll()
            self.registrationSnapshot = RegistrationSnapshot(entries: [:])
        }
    }

    fileprivate func resolve<T>(
        _ type: T.Type, named: String?, params: Any?, context: ResolutionContext
    ) throws -> T {
        let key = ServiceKey(type, name: named)
        guard let registration = self.lookupRegistration(for: key) else {
            throw ResolutionError.missingRegistration(key)
        }

        let resolved = try self.resolveRegistration(
            key: key,
            registration: registration,
            params: params,
            context: context
        )
        return try Self.castOrThrow(resolved, expected: type, key: key)
    }

    func validate(registration: Registration, params: Any?) throws {
        let context = ResolutionContext(container: self, isolation: registration.isolation)
        _ = try self.resolveRegistration(
            key: registration.key,
            registration: registration,
            params: params,
            context: context
        )
    }

    @discardableResult
    private func resolveRegistration(
        key: ServiceKey,
        registration: Registration,
        params: Any?,
        context: ResolutionContext
    ) throws -> Any {
        try self.assertIsolationCompatible(registration: registration, key: key, context: context)

        switch registration.shape {
        case .factoryNoParameters:
            if params != nil {
                throw ResolutionError.unexpectedParameter(key)
            }
            return try self.resolveFactory(
                key: key,
                registration: registration,
                params: nil,
                context: context
            )
        case .factoryWithParameters:
            guard let params else {
                throw ResolutionError.missingParameter(
                    key,
                    expected: registration.factory.parameterType!
                )
            }
            if registration.factory.acceptsParameter?(params) == false {
                throw ResolutionError.parameterTypeMismatch(
                    key,
                    expected: registration.factory.parameterType!,
                    actual: Swift.type(of: params)
                )
            }
            return try self.resolveFactory(
                key: key,
                registration: registration,
                params: params,
                context: context
            )
        case .singletonNoParameters:
            if params != nil {
                throw ResolutionError.unexpectedParameter(key)
            }
            return try self.resolveSingleton(
                key: key,
                registration: registration,
                context: context
            )
        }
    }

    private func resolveFactory(
        key: ServiceKey,
        registration: Registration,
        params: Any?,
        context: ResolutionContext
    ) throws -> Any {
        try self.pushResolutionServiceKey(key: key, context: context)
        defer { context.stack.removeLast() }
        let resolved = try registration.factory.call(context, params)
        try Self.assertOutputCompatible(resolved, registration: registration, key: key)
        return resolved
    }

    private func resolveSingleton(
        key: ServiceKey,
        registration: Registration,
        context: ResolutionContext
    ) throws -> Any {
        guard let singletonCell = registration.singletonCell else {
            throw ResolutionError.internalError(
                "Bolt: Internal error: singleton registration missing cache cell for \(Self.dependencyDescription(key)).",
                key: key
            )
        }

        if let cached = singletonCell.cachedValue {
            try Self.assertOutputCompatible(cached, registration: registration, key: key)
            return cached
        }

        try self.pushResolutionServiceKey(key: key, context: context)
        defer { context.stack.removeLast() }

        let resolved = try singletonCell.getOrCreate {
            try registration.factory.call(context, nil)
        }
        try Self.assertOutputCompatible(resolved, registration: registration, key: key)
        return resolved
    }

    @inline(__always)
    private func pushResolutionServiceKey(
        key: ServiceKey,
        context: ResolutionContext
    ) throws {
        if context.stack.contains(key) {
            throw ResolutionError.circularDependency(context.stack + [key])
        }

        context.stack.append(key)
    }

    func collectedValidationErrors() -> [ValidationError] {
        self.lock.withLock { self.validationErrors }
    }

    func recordValidationError(_ error: ValidationError) {
        self.lock.withLock {
            self.validationErrors.append(error)
        }
    }

    func effectiveRegistrationsForValidation() -> [ServiceKey: Registration] {
        var registrations: [ServiceKey: Registration] = [:]
        var chain: [Container] = []
        var current: Container? = self

        while let container = current {
            chain.append(container)
            current = container.parent
        }

        for container in chain.reversed() {
            for (key, registration) in container.registrationSnapshot.entries {
                registrations[key] = registration
            }
        }

        return registrations
    }

    static func withCurrent<R>(_ container: Container, _ body: () throws -> R) rethrows -> R {
        try Self.$taskLocalCurrent.withValue(container) {
            try body()
        }
    }

    static func withCurrent<R>(_ container: Container, _ body: () async throws -> R) async rethrows -> R {
        try await Self.$taskLocalCurrent.withValue(container) {
            try await body()
        }
    }

    func withScopedOverrides<R>(
        @DependencyBuilder _ overrides: () -> [Registration], _ body: () throws -> R
    ) rethrows -> R {
        let entries = self.buildOverrideEntries(from: overrides())
        let scoped = Container(
            parent: self,
            registrationBehavior: self.registrationBehavior,
            registrations: entries
        )
        return try Self.withCurrent(scoped) {
            try body()
        }
    }

    func withScopedOverrides<R>(
        @DependencyBuilder _ overrides: () -> [Registration], _ body: () async throws -> R
    ) async rethrows -> R {
        let entries = self.buildOverrideEntries(from: overrides())
        let scoped = Container(
            parent: self,
            registrationBehavior: self.registrationBehavior,
            registrations: entries
        )
        return try await Self.withCurrent(scoped) {
            try await body()
        }
    }

    private func buildOverrideEntries(from overrides: [Registration]) -> [ServiceKey: Registration] {
        var entries: [ServiceKey: Registration] = [:]
        var overrideServiceKeys = Set<ServiceKey>()

        for registration in overrides {
            if overrideServiceKeys.contains(registration.key) {
                switch self.registrationBehavior {
                case .strict:
                    fatalError(Self.duplicateRegistrationMessage(for: registration.key))
                case .collecting:
                    let descriptor = ValidationError.DependencyDescriptor(
                        typeName: registration.key.typeName,
                        name: registration.key.name
                    )
                    self.lock.withLock {
                        self.validationErrors.append(
                            ValidationError(
                                kind: .duplicateRegistration,
                                dependency: descriptor,
                                message: Self.duplicateRegistrationMessage(for: registration.key)
                            )
                        )
                    }
                }
                continue
            }

            overrideServiceKeys.insert(registration.key)
            entries[registration.key] = registration
        }

        return entries
    }

    private func lookupRegistration(for key: ServiceKey) -> Registration? {
        if let registration = self.registrationSnapshot.entries[key] {
            return registration
        }
        return self.parent?.lookupRegistration(for: key)
    }

    @inline(__always)
    private static func castOrThrow<T>(_ value: Any, expected: T.Type, key: ServiceKey) throws -> T {
        guard let typed = value as? T else {
            throw ResolutionError.typeMismatch(key, expected: expected, actual: Swift.type(of: value))
        }
        return typed
    }

    private static func assertOutputCompatible(_ value: Any, registration: Registration, key: ServiceKey) throws {
        guard registration.factory.acceptsOutput(value) else {
            throw ResolutionError.typeMismatch(
                key,
                expected: registration.factory.outputType,
                actual: Swift.type(of: value)
            )
        }
    }

    private func assertIsolationCompatible(
        registration: Registration,
        key: ServiceKey,
        context: ResolutionContext
    ) throws {
        switch registration.isolation {
        case .none:
            return
        case .actor(let required):
            guard context.isolation == .actor(required) else {
                throw ResolutionError.isolationMismatch(key, required: required, actual: context.isolation)
            }
        }
    }

    private static func duplicateRegistrationMessage(for key: ServiceKey) -> String {
        "Bolt: Duplicate registration for \(key.typeName) (name: \(nameDescription(key.name))). Use withOverrides { ... } to replace in scoped contexts."
    }

    private static func dependencyDescription(_ key: ServiceKey) -> String {
        "\(key.typeName) (name: \(nameDescription(key.name)))"
    }

    private static func nameDescription(_ name: String?) -> String {
        guard let name else { return "nil" }
        return "\"\(name)\""
    }

    private static func resolutionFailureMessage(_ error: Error) -> String {
        if let error = error as? ResolutionError {
            return error.message
        }
        return "Bolt: Dependency resolution failed with error: \(error)."
    }

    private func handleDuplicateRegistration(for key: ServiceKey) {
        switch self.registrationBehavior {
        case .strict:
            fatalError(Self.duplicateRegistrationMessage(for: key))
        case .collecting:
            let descriptor = ValidationError.DependencyDescriptor(typeName: key.typeName, name: key.name)
            self.validationErrors.append(
                ValidationError(
                    kind: .duplicateRegistration,
                    dependency: descriptor,
                    message: Self.duplicateRegistrationMessage(for: key)
                )
            )
        }
    }
}

enum ResolutionError: Error {
    case missingRegistration(ServiceKey)
    case unexpectedParameter(ServiceKey)
    case missingParameter(ServiceKey, expected: Any.Type)
    case parameterTypeMismatch(ServiceKey, expected: Any.Type, actual: Any.Type)
    case typeMismatch(ServiceKey, expected: Any.Type, actual: Any.Type)
    case circularDependency([ServiceKey])
    case isolationMismatch(ServiceKey, required: ActorIsolationIdentity, actual: RegistrationIsolation)
    case internalError(String, key: ServiceKey?)

    var message: String {
        switch self {
        case .missingRegistration(let key):
            return "Bolt: Missing registration for \(Self.dependencyDescription(key))."
        case .unexpectedParameter(let key):
            return "Bolt: Unexpected params for \(Self.dependencyDescription(key)). Registration is not parameterized."
        case .missingParameter(let key, let expected):
            return "Bolt: Missing params for \(Self.dependencyDescription(key)). Expected \(String(reflecting: expected))."
        case .parameterTypeMismatch(let key, let expected, let actual):
            return "Bolt: Parameter type mismatch for \(Self.dependencyDescription(key)). Expected \(String(reflecting: expected)), got \(String(reflecting: actual))."
        case .typeMismatch(let key, let expected, let actual):
            return "Bolt: Type mismatch for \(Self.dependencyDescription(key)). Expected \(String(reflecting: expected)), got \(String(reflecting: actual))."
        case .circularDependency(let keys):
            let path = keys.map(Self.dependencyDescription).joined(separator: " -> ")
            return "Bolt: Circular dependency detected: \(path)."
        case .isolationMismatch(let key, let required, let actual):
            let dependency = Self.dependencyDescription(key)
            let actualDescription = actual.description

            if required.actorKey == ServiceKey(MainActor.self) {
                return "Bolt: MainActor-isolated dependency \(dependency) was resolved from \(actualDescription) context. Resolve it from a @MainActor context, or explicitly hop before resolving with await MainActor.run { ... }."
            }

            return "Bolt: Actor-isolated dependency \(dependency) requires \(required.description) isolation, but current resolution isolation is \(actualDescription)."
        case .internalError(let message, _):
            return message
        }
    }

    var validationError: ValidationError {
        let key: ServiceKey?
        let kind: ValidationError.Kind

        switch self {
        case .missingRegistration(let serviceKey):
            key = serviceKey
            kind = .missingRegistration
        case .unexpectedParameter(let serviceKey):
            key = serviceKey
            kind = .typeMismatch
        case .missingParameter(let serviceKey, _):
            key = serviceKey
            kind = .missingRegistration
        case .parameterTypeMismatch(let serviceKey, _, _):
            key = serviceKey
            kind = .typeMismatch
        case .typeMismatch(let serviceKey, _, _):
            key = serviceKey
            kind = .typeMismatch
        case .circularDependency(let serviceKeys):
            key = serviceKeys.last
            kind = .circularDependency
        case .isolationMismatch(let serviceKey, _, _):
            key = serviceKey
            kind = .typeMismatch
        case .internalError(_, let serviceKey):
            key = serviceKey
            kind = .typeMismatch
        }

        let detail = self.message.hasPrefix("Bolt: ")
            ? String(self.message.dropFirst("Bolt: ".count))
            : self.message

        return ValidationError(
            kind: kind,
            dependency: key.map {
                ValidationError.DependencyDescriptor(typeName: $0.typeName, name: $0.name)
            },
            message: "Bolt validation failed: \(detail)"
        )
    }

    private static func dependencyDescription(_ key: ServiceKey) -> String {
        "\(key.typeName) (name: \(nameDescription(key.name)))"
    }

    private static func nameDescription(_ name: String?) -> String {
        guard let name else { return "nil" }
        return "\"\(name)\""
    }
}

enum RegistrationBehavior {
    case strict
    case collecting
}

private final class RegistrationSnapshot: @unchecked Sendable {
    let entries: [ServiceKey: Registration]

    init(entries: [ServiceKey: Registration]) {
        self.entries = entries
    }
}

private final class ResolutionContext: Resolver {
    private let container: Container
    fileprivate var stack: [ServiceKey] = []
    fileprivate let isolation: RegistrationIsolation

    init(container: Container, isolation: RegistrationIsolation) {
        self.container = container
        self.isolation = isolation
    }

    func get<T>(
        _ type: T.Type,
        named: String?,
        isolation: isolated (any Actor)?
    ) throws -> T {
        try self.container.resolve(type, named: named, params: nil, context: self)
    }

    func get<T, P>(
        _ type: T.Type,
        named: String?,
        params: P,
        isolation: isolated (any Actor)?
    ) throws -> T {
        try self.container.resolve(type, named: named, params: params, context: self)
    }
}
