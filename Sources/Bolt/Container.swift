import Foundation

public final class Container: Resolver, @unchecked Sendable {
    @TaskLocal nonisolated(unsafe) static var taskLocalCurrent: Container?

    public static var current: Container {
        Self.taskLocalCurrent ?? Bolt.shared
    }

    private let lock = NSLock()
    private var baseRegistrations: [Key: Registration] = [:]
    private var baseSingletons: [Key: Any] = [:]
    private var overrideLayers: [OverrideLayer] = []
    private var singletonInitializations: [SingletonInitializationKey: DispatchGroup] = [:]
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
            for index in self.overrideLayers.indices {
                self.overrideLayers[index].singletons.removeAll()
            }
        }
    }

    public func resetAll() {
        self.lock.withLock {
            self.baseRegistrations.removeAll()
            self.baseSingletons.removeAll()
            self.overrideLayers.removeAll()
            self.singletonInitializations.removeAll()
        }
    }

    fileprivate func resolve<T>(
        _ type: T.Type, named: String?, params: Any?, context: ResolutionContext
    )
        -> T
    {
        let key = Key(type, name: named)
        let lookup = self.lock.withLock {
            self.lookupRegistration(for: key)
        }
        guard let lookup else {
            fatalError(Self.missingRegistrationMessage(for: key))
        }
        let registration = lookup.registration

        if registration.scope == .singleton {
            let initializationKey = SingletonInitializationKey(key: key, owner: lookup.owner)
            let state = self.lock.withLock {
                self.singletonState(for: initializationKey)
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
                        self.singletonInitializations.removeValue(forKey: initializationKey)
                        inFlight.leave()
                    }
                    if let cached = self.readSingleton(for: key, owner: lookup.owner) {
                        return cached
                    }
                    self.writeSingleton(resolved, for: key, owner: lookup.owner)
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

    func effectiveRegistrationsForValidation() -> [Key: Registration] {
        self.lock.withLock {
            var merged = self.baseRegistrations
            for layer in self.overrideLayers {
                for (key, registration) in layer.registrations {
                    merged[key] = registration
                }
            }
            return merged
        }
    }

    static func withCurrent<R>(_ container: Container, _ body: () throws -> R) rethrows -> R {
        try Self.$taskLocalCurrent.withValue(container) {
            try body()
        }
    }

    func withOverrideLayer<R>(
        @DependencyBuilder _ overrides: () -> [Registration], _ body: () throws -> R
    ) rethrows -> R {
        let layerID = self.pushOverrideLayer(overrides())
        defer {
            self.popOverrideLayer(id: layerID)
        }
        return try body()
    }

    private func pushOverrideLayer(_ registrations: [Registration]) -> UUID {
        let layerID = UUID()
        self.lock.withLock {
            var byKey: [Key: Registration] = [:]
            for registration in registrations {
                if byKey[registration.key] != nil {
                    self.handleDuplicateRegistration(for: registration.key)
                    continue
                }
                byKey[registration.key] = registration
            }
            self.overrideLayers.append(OverrideLayer(id: layerID, registrations: byKey, singletons: [:]))
        }
        return layerID
    }

    private func popOverrideLayer(id: UUID) {
        self.lock.withLock {
            guard let index = self.overrideLayers.lastIndex(where: { $0.id == id }) else { return }
            self.overrideLayers.remove(at: index)
        }
    }

    private func lookupRegistration(for key: Key) -> RegistrationLookup? {
        for index in self.overrideLayers.indices.reversed() {
            guard let registration = self.overrideLayers[index].registrations[key] else { continue }
            let cached = self.overrideLayers[index].singletons[key]
            return RegistrationLookup(
                registration: registration,
                owner: .overrideLayer(id: self.overrideLayers[index].id),
                cachedSingleton: cached
            )
        }

        guard let registration = self.baseRegistrations[key] else { return nil }
        return RegistrationLookup(
            registration: registration,
            owner: .base,
            cachedSingleton: self.baseSingletons[key]
        )
    }

    private func readSingleton(for key: Key, owner: RegistrationOwner) -> Any? {
        switch owner {
        case .base:
            return self.baseSingletons[key]
        case .overrideLayer(let id):
            guard let index = self.overrideLayers.lastIndex(where: { $0.id == id }) else { return nil }
            return self.overrideLayers[index].singletons[key]
        }
    }

    private func writeSingleton(_ value: Any, for key: Key, owner: RegistrationOwner) {
        switch owner {
        case .base:
            self.baseSingletons[key] = value
        case .overrideLayer(let id):
            guard let index = self.overrideLayers.lastIndex(where: { $0.id == id }) else { return }
            self.overrideLayers[index].singletons[key] = value
        }
    }

    private func singletonState(for key: SingletonInitializationKey) -> SingletonState {
        if let cached = self.readSingleton(for: key.key, owner: key.owner) {
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

private struct OverrideLayer {
    let id: UUID
    let registrations: [Key: Registration]
    var singletons: [Key: Any]
}

private struct RegistrationLookup {
    let registration: Registration
    let owner: RegistrationOwner
    let cachedSingleton: Any?
}

private enum RegistrationOwner: Hashable {
    case base
    case overrideLayer(id: UUID)
}

private struct SingletonInitializationKey: Hashable {
    let key: Key
    let owner: RegistrationOwner
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
