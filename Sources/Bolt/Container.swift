import Foundation

public final class Container: Resolver {
    private let lock = NSLock()
    private var baseRegistrations: [Key: Registration] = [:]
    private var baseSingletons: [Key: Any] = [:]

    public init() {}

    public func register(@DependencyBuilder _ registrations: () -> [Registration]) {
        let values = registrations()
        self.lock.withLock {
            for registration in values {
                if self.baseRegistrations[registration.key] != nil {
                    fatalError(Self.duplicateRegistrationMessage(for: registration.key))
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
        }
    }

    public func resetAll() {
        self.lock.withLock {
            self.baseRegistrations.removeAll()
            self.baseSingletons.removeAll()
        }
    }

    fileprivate func resolve<T>(
        _ type: T.Type, named: String?, params: Any?, context: ResolutionContext
    )
        -> T
    {
        let key = Key(type, name: named)
        let registration = self.lock.withLock {
            self.baseRegistrations[key]
        }
        guard let registration else {
            fatalError(Self.missingRegistrationMessage(for: key))
        }

        if registration.scope == .singleton,
            let cached = self.lock.withLock({ self.baseSingletons[key] })
        {
            return Self.castOrFail(cached, expected: type, key: key)
        }

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

        if registration.scope == .factory {
            return Self.castOrFail(resolved, expected: type, key: key)
        }

        let finalValue: Any = self.lock.withLock {
            if let cached = self.baseSingletons[key] {
                return cached
            }
            self.baseSingletons[key] = resolved
            return resolved
        }
        return Self.castOrFail(finalValue, expected: type, key: key)
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
