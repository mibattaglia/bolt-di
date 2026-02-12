import Foundation

public final class Container: Resolver, @unchecked Sendable {
    @TaskLocal nonisolated(unsafe) static var taskLocalCurrent: Container?
    @TaskLocal nonisolated(unsafe) private static var taskLocalOverrideLayer: OverrideLayer?

    public static var current: Container {
        Self.taskLocalCurrent ?? Bolt.shared
    }

    private let lock = NSLock()
    private var baseRegistrations: [Key: Registration] = [:]
    private var baseSingletonStore = SingletonStore()
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
        self.baseSingletonStore.removeAll()
    }

    public func resetAll() {
        self.lock.withLock {
            self.baseRegistrations.removeAll()
        }
        self.baseSingletonStore.removeAll()
    }

    fileprivate func resolve<T>(
        _ type: T.Type, named: String?, params: Any?, context: ResolutionContext
    )
        -> T
    {
        let key = Key(type, name: named)
        let registrationLookup = self.lookupRegistration(for: key)
        guard let registration = registrationLookup.registration else {
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
                singletonStore: registrationLookup.singletonStore ?? self.baseSingletonStore,
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
        let resolved = self.resolveWithCycleTracking(key: key, context: context) {
            registration.factory.factory(context, nil)
        }
        return Self.castOrFail(resolved, expected: type, key: key)
    }

    private func resolveFactoryWithParameters<T>(
        _ type: T.Type,
        key: Key,
        registration: Registration,
        params: Any,
        context: ResolutionContext
    ) -> T {
        let resolved = self.resolveWithCycleTracking(key: key, context: context) {
            registration.factory.factory(context, params)
        }
        return Self.castOrFail(resolved, expected: type, key: key)
    }

    private func resolveSingletonNoParameters<T>(
        _ type: T.Type,
        key: Key,
        registration: Registration,
        singletonStore: SingletonStore,
        context: ResolutionContext
    ) -> T {
        if let cached = singletonStore.cachedValue(for: key) {
            return Self.castOrFail(cached, expected: type, key: key)
        }

        let resolved = self.resolveWithCycleTracking(key: key, context: context) {
            singletonStore.getOrCreateValue(for: key) {
                registration.factory.factory(context, nil)
            }
        }
        return Self.castOrFail(resolved, expected: type, key: key)
    }

    private func resolveWithCycleTracking<T>(
        key: Key,
        context: ResolutionContext,
        _ body: () -> T
    ) -> T {
        if context.stack.contains(key) {
            let cycle = context.stack + [key]
            fatalError(Self.circularDependencyMessage(for: cycle))
        }

        context.stack.append(key)
        defer {
            _ = context.stack.popLast()
        }

        return body()
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
        var registrations = self.lock.withLock { self.baseRegistrations }
        let layers = Self.taskLocalOverrideLayer?.layersRootToLeaf() ?? []
        for layer in layers {
            for (key, registration) in layer.entries {
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
        let layer = OverrideLayer(parent: Self.taskLocalOverrideLayer, entries: entries)
        return try Self.$taskLocalOverrideLayer.withValue(layer) {
            try body()
        }
    }

    func withScopedOverrides<R>(
        @DependencyBuilder _ overrides: () -> [Registration], _ body: () async throws -> R
    ) async rethrows -> R {
        let entries = self.buildOverrideEntries(from: overrides())
        let layer = OverrideLayer(parent: Self.taskLocalOverrideLayer, entries: entries)
        return try await Self.$taskLocalOverrideLayer.withValue(layer) {
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

    private func lookupRegistration(for key: Key) -> RegistrationLookup {
        if let overrideLookup = Self.taskLocalOverrideLayer?.lookup(key) {
            return RegistrationLookup(
                registration: overrideLookup.registration,
                singletonStore: overrideLookup.layer.singletonStore
            )
        }
        return RegistrationLookup(
            registration: self.lock.withLock { self.baseRegistrations[key] },
            singletonStore: nil
        )
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

private struct RegistrationLookup {
    let registration: Registration?
    let singletonStore: SingletonStore?
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

private final class SingletonStore: @unchecked Sendable {
    private let lock = NSLock()
    private var cells: [Key: SingletonCell]

    init(seed: [Key: Any] = [:]) {
        self.cells = seed.mapValues { SingletonCell(cached: $0) }
    }

    func getOrCreateValue(for key: Key, _ build: () -> Any) -> Any {
        let cell = self.lock.withLock {
            if let existing = self.cells[key] {
                return existing
            }
            let newCell = SingletonCell()
            self.cells[key] = newCell
            return newCell
        }
        return cell.getOrCreate(build)
    }

    func cachedValue(for key: Key) -> Any? {
        let cell = self.lock.withLock { self.cells[key] }
        return cell?.cachedValue
    }

    func removeAll() {
        self.lock.withLock {
            self.cells.removeAll()
        }
    }

    func snapshotValues() -> [Key: Any] {
        let snapshot = self.lock.withLock { self.cells }
        var values: [Key: Any] = [:]
        values.reserveCapacity(snapshot.count)
        for (key, cell) in snapshot {
            if let value = cell.cachedValue {
                values[key] = value
            }
        }
        return values
    }
}

private final class OverrideLayer: @unchecked Sendable {
    let parent: OverrideLayer?
    let entries: [Key: Registration]
    let singletonStore = SingletonStore()

    init(parent: OverrideLayer?, entries: [Key: Registration]) {
        self.parent = parent
        self.entries = entries
    }

    func lookup(_ key: Key) -> (registration: Registration, layer: OverrideLayer)? {
        if let registration = self.entries[key] {
            return (registration, self)
        }
        return self.parent?.lookup(key)
    }

    func layersRootToLeaf() -> [OverrideLayer] {
        var layers: [OverrideLayer] = []
        var current: OverrideLayer? = self
        while let layer = current {
            layers.append(layer)
            current = layer.parent
        }
        return layers.reversed()
    }
}

private final class SingletonCell: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Any?

    init(cached: Any? = nil) {
        self.value = cached
    }

    var cachedValue: Any? {
        self.value
    }

    func getOrCreate(_ build: () -> Any) -> Any {
        if let value = self.value {
            return value
        }

        self.lock.lock()
        defer { self.lock.unlock() }

        if let value = self.value {
            return value
        }

        let created = build()
        self.value = created
        return created
    }
}
