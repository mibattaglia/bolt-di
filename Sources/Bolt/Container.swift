import Foundation

public final class Container: Resolver, @unchecked Sendable {
    @TaskLocal nonisolated(unsafe) static var taskLocalCurrent: Container?

    public static var current: Container {
        Self.taskLocalCurrent ?? Bolt.shared
    }

    private let lock = NSLock()
    private var mutableRegistrations: [Key: Registration] = [:]
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
        registrations: [Key: Registration]
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

    public func get<T>(_ type: T.Type = T.self, named: String? = nil) -> T {
        let context = ResolutionContext(container: self)
        return context.get(type, named: named)
    }

    public func get<T, P>(_ type: T.Type = T.self, named: String? = nil, params: P) -> T {
        let context = ResolutionContext(container: self)
        return context.get(type, named: named, params: params)
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
    ) -> T {
        let key = Key(type, name: named)
        guard let registration = self.lookupRegistration(for: key) else {
            fatalError(Self.missingRegistrationMessage(for: key))
        }

        switch registration.shape {
        case .factoryNoParameters:
            if params != nil {
                fatalError(Self.unexpectedParameterMessage(for: key))
            }
            return self.resolveFactoryNoParameters(
                type,
                key: key,
                registration: registration,
                context: context
            )
        case .factoryWithParameters:
            guard let params else {
                fatalError(
                    Self.missingParameterMessage(
                        for: key,
                        expected: registration.factory.parameterType!
                    )
                )
            }
            return self.resolveFactoryWithParameters(
                type,
                key: key,
                registration: registration,
                params: params,
                context: context
            )
        case .singletonNoParameters:
            if params != nil {
                fatalError(Self.unexpectedParameterMessage(for: key))
            }
            return self.resolveSingletonNoParameters(
                type,
                key: key,
                registration: registration,
                context: context
            )
        }
    }

    private func resolveFactoryNoParameters<T>(
        _ type: T.Type,
        key: Key,
        registration: Registration,
        context: ResolutionContext
    ) -> T {
        self.pushResolutionKeyOrFail(key: key, context: context)
        defer { context.stack.removeLast() }
        let resolved = registration.factory.call(context, nil)
        return Self.castOrFail(resolved, expected: type, key: key)
    }

    private func resolveFactoryWithParameters<T>(
        _ type: T.Type,
        key: Key,
        registration: Registration,
        params: Any,
        context: ResolutionContext
    ) -> T {
        self.pushResolutionKeyOrFail(key: key, context: context)
        defer { context.stack.removeLast() }
        let resolved = registration.factory.call(context, params)
        return Self.castOrFail(resolved, expected: type, key: key)
    }

    private func resolveSingletonNoParameters<T>(
        _ type: T.Type,
        key: Key,
        registration: Registration,
        context: ResolutionContext
    ) -> T {
        guard let singletonCell = registration.singletonCell else {
            fatalError(
                "Bolt: Internal error: singleton registration missing cache cell for \(Self.dependencyDescription(key))."
            )
        }

        if let cached = singletonCell.cachedValue {
            return Self.castOrFail(cached, expected: type, key: key)
        }

        self.pushResolutionKeyOrFail(key: key, context: context)
        defer { context.stack.removeLast() }

        let resolved = singletonCell.getOrCreate {
            registration.factory.call(context, nil)
        }
        return Self.castOrFail(resolved, expected: type, key: key)
    }

    @inline(__always)
    private func pushResolutionKeyOrFail(
        key: Key,
        context: ResolutionContext
    ) {
        if context.stack.contains(key) {
            let cycle = context.stack + [key]
            fatalError(Self.circularDependencyMessage(for: cycle))
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

    func effectiveRegistrationsForValidation() -> [Key: Registration] {
        var registrations: [Key: Registration] = [:]
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

    private func buildOverrideEntries(from overrides: [Registration]) -> [Key: Registration] {
        var entries: [Key: Registration] = [:]
        var overrideKeys = Set<Key>()

        for registration in overrides {
            if overrideKeys.contains(registration.key) {
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

            overrideKeys.insert(registration.key)
            entries[registration.key] = registration
        }

        return entries
    }

    private func lookupRegistration(for key: Key) -> Registration? {
        if let registration = self.registrationSnapshot.entries[key] {
            return registration
        }
        return self.parent?.lookupRegistration(for: key)
    }

    @inline(__always)
    private static func castOrFail<T>(_ value: Any, expected: T.Type, key: Key) -> T {
        guard let typed = value as? T else {
            fatalError(typeMismatchMessage(for: key, expected: expected, actual: Swift.type(of: value)))
        }
        return typed
    }

    private static func duplicateRegistrationMessage(for key: Key) -> String {
        "Bolt: Duplicate registration for \(key.typeName) (name: \(nameDescription(key.name))). Use withOverrides { ... } to replace in scoped contexts."
    }

    private static func missingRegistrationMessage(for key: Key) -> String {
        "Bolt: Missing registration for \(key.typeName) (name: \(nameDescription(key.name)))."
    }

    private static func circularDependencyMessage(for keys: [Key]) -> String {
        let path = keys.map(dependencyDescription).joined(separator: " -> ")
        return "Bolt: Circular dependency detected: \(path)."
    }

    private static func typeMismatchMessage(for key: Key, expected: Any.Type, actual: Any.Type)
        -> String
    {
        "Bolt: Type mismatch for \(dependencyDescription(key)). Expected \(String(reflecting: expected)), got \(String(reflecting: actual))."
    }

    private static func missingParameterMessage(for key: Key, expected: Any.Type) -> String {
        "Bolt: Missing params for \(dependencyDescription(key)). Expected \(String(reflecting: expected))."
    }

    private static func unexpectedParameterMessage(for key: Key) -> String {
        "Bolt: Unexpected params for \(dependencyDescription(key)). Registration is not parameterized."
    }

    private static func dependencyDescription(_ key: Key) -> String {
        "\(key.typeName) (name: \(nameDescription(key.name)))"
    }

    private static func nameDescription(_ name: String?) -> String {
        guard let name else { return "nil" }
        return "\"\(name)\""
    }

    private func handleDuplicateRegistration(for key: Key) {
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

enum RegistrationBehavior {
    case strict
    case collecting
}

private final class RegistrationSnapshot: @unchecked Sendable {
    let entries: [Key: Registration]

    init(entries: [Key: Registration]) {
        self.entries = entries
    }
}

private final class ResolutionContext: Resolver {
    private unowned let container: Container
    fileprivate var stack: [Key] = []

    init(container: Container) {
        self.container = container
    }

    func get<T>(_ type: T.Type, named: String?) -> T {
        self.container.resolve(type, named: named, params: nil, context: self)
    }

    func get<T, P>(_ type: T.Type, named: String?, params: P) -> T {
        self.container.resolve(type, named: named, params: params, context: self)
    }
}
