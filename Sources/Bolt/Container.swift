import Foundation

public final class Container: Resolver, @unchecked Sendable {
    @TaskLocal nonisolated(unsafe) static var taskLocalCurrent: Container?

    public static var current: Container {
        Self.taskLocalCurrent ?? Bolt.shared
    }

    private let lock = NSLock()
    private var baseRegistrations: [Key: Registration] = [:]
    private var baseSingletons: [Key: Any] = [:]
    private var singletonInitializations: [Key: DispatchGroup] = [:]
    private let registrationBehavior: RegistrationBehavior
    private var validationErrors: [ValidationError] = []

    public init() {
        self.registrationBehavior = .strict
    }

    init(registrationBehavior: RegistrationBehavior) {
        self.registrationBehavior = registrationBehavior
    }

    public func register(@DependencyBuilder _ registrations: () -> [Registration]) {
        let values = registrations()
        self.lock.withLock {
            for registration in values {
                if self.baseRegistrations[registration.key] != nil {
                    self.handleDuplicateRegistration(for: registration.key)
                    continue
                }
                self.baseRegistrations[registration.key] = registration
            }
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
        self.lock.withLock {
            self.baseSingletons.removeAll()
            self.singletonInitializations.removeAll()
        }
    }

    public func resetAll() {
        self.lock.withLock {
            self.baseRegistrations.removeAll()
            self.baseSingletons.removeAll()
            self.singletonInitializations.removeAll()
        }
    }

    fileprivate func resolve<T>(
        _ type: T.Type, named: String?, params: Any?, context: ResolutionContext
    )
        -> T
    {
        let key = Key(type, name: named)
        guard let registration = self.lock.withLock({ self.baseRegistrations[key] }) else {
            fatalError(Self.missingRegistrationMessage(for: key))
        }

        if registration.scope == .singleton {
            let state = self.lock.withLock {
                self.singletonState(for: key)
            }
            switch state {
            case .cached(let cached):
                return Self.castOrFail(cached, expected: type, key: key)
            case .waiting(let inFlight):
                inFlight.wait()
                return self.resolve(type, named: named, params: params, context: context)
            case .initialize(let inFlight):
                let resolved = self.buildValue(
                    type,
                    key: key,
                    registration: registration,
                    params: params,
                    context: context
                )
                let finalValue: Any = self.lock.withLock {
                    defer {
                        self.singletonInitializations.removeValue(forKey: key)
                        inFlight.leave()
                    }
                    if let cached = self.baseSingletons[key] {
                        return cached
                    }
                    self.baseSingletons[key] = resolved
                    return resolved
                }
                return Self.castOrFail(finalValue, expected: type, key: key)
            }
        }

        return self.buildValue(type, key: key, registration: registration, params: params, context: context)
    }

    private func buildValue<T>(
        _ type: T.Type,
        key: Key,
        registration: Registration,
        params: Any?,
        context: ResolutionContext
    ) -> T {
        if context.stack.contains(key) {
            let cycle = context.stack + [key]
            fatalError(Self.circularDependencyMessage(for: cycle))
        }

        context.stack.append(key)
        defer {
            _ = context.stack.popLast()
        }

        let hasParam = params != nil
        let wantsParam = registration.factory.parameterType != nil
        if hasParam && !wantsParam {
            fatalError(Self.unexpectedParameterMessage(for: key))
        }
        if wantsParam && !hasParam {
            fatalError(
                Self.missingParameterMessage(
                    for: key,
                    expected: registration.factory.parameterType!
                )
            )
        }

        let resolved = registration.factory.factory(context, params)

        return Self.castOrFail(resolved, expected: type, key: key)
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
        self.lock.withLock { self.baseRegistrations }
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
        let derived = self.makeDerivedContainer(with: overrides())
        return try Self.withCurrent(derived) {
            try body()
        }
    }

    func withScopedOverrides<R>(
        @DependencyBuilder _ overrides: () -> [Registration], _ body: () async throws -> R
    ) async rethrows -> R {
        let derived = self.makeDerivedContainer(with: overrides())
        return try await Self.withCurrent(derived) {
            try await body()
        }
    }

    private func makeDerivedContainer(with overrides: [Registration]) -> Container {
        let derived = Container(registrationBehavior: self.registrationBehavior)

        let (baseRegistrationsSnapshot, baseSingletonsSnapshot, validationErrorsSnapshot) = self.lock.withLock {
            (self.baseRegistrations, self.baseSingletons, self.validationErrors)
        }

        var mergedRegistrations = baseRegistrationsSnapshot
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
            mergedRegistrations[registration.key] = registration
        }

        var mergedSingletons = baseSingletonsSnapshot
        for registration in overrides {
            mergedSingletons.removeValue(forKey: registration.key)
        }

        derived.lock.withLock {
            derived.baseRegistrations = mergedRegistrations
            derived.baseSingletons = mergedSingletons
            derived.validationErrors = validationErrorsSnapshot
        }
        return derived
    }

    private func singletonState(for key: Key) -> SingletonState {
        if let cached = self.baseSingletons[key] {
            return .cached(cached)
        }
        if let inFlight = self.singletonInitializations[key] {
            return .waiting(inFlight)
        }
        let inFlight = DispatchGroup()
        inFlight.enter()
        self.singletonInitializations[key] = inFlight
        return .initialize(inFlight)
    }

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

private enum SingletonState {
    case cached(Any)
    case waiting(DispatchGroup)
    case initialize(DispatchGroup)
}

enum RegistrationBehavior {
    case strict
    case collecting
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

extension NSLock {
    fileprivate func withLock<R>(_ body: () -> R) -> R {
        self.lock()
        defer { self.unlock() }
        return body()
    }
}
