import Foundation

public struct Registration {
    public let key: Key
    let shape: RegistrationShape
    let factory: ErasedFactory
    let singletonCell: SingletonCell?

    init(key: Key, scope: Scope, factory: ErasedFactory) {
        self.key = key
        self.shape = RegistrationShape(scope: scope, hasParameters: factory.parameterType != nil)
        self.factory = factory
        switch scope {
        case .factory:
            self.singletonCell = nil
        case .singleton:
            self.singletonCell = SingletonCell()
        }
    }
}

enum RegistrationShape {
    case factoryNoParameters
    case factoryWithParameters
    case singletonNoParameters

    init(scope: Scope, hasParameters: Bool) {
        switch (scope, hasParameters) {
        case (.factory, false):
            self = .factoryNoParameters
        case (.factory, true):
            self = .factoryWithParameters
        case (.singleton, _):
            self = .singletonNoParameters
        }
    }
}

struct ErasedFactory {
    let outputType: Any.Type
    let parameterType: Any.Type?
    let call: (Resolver, Any?) -> Any
}

public struct Factory<T> {
    private let type: T.Type
    private let name: String?
    private let factory: (Resolver) -> T

    public init(
        _ type: T.Type = T.self,
        named: String? = nil,
        _ factory: @escaping (Resolver) -> T
    ) {
        self.type = type
        self.name = named
        self.factory = factory
    }

    var registration: Registration {
        Registration(
            key: Key(self.type, name: self.name),
            scope: .factory,
            factory: ErasedFactory(
                outputType: T.self,
                parameterType: nil,
                call: { resolver, _ in self.factory(resolver) }
            )
        )
    }
}

public struct Singleton<T> {
    private let type: T.Type
    private let name: String?
    private let factory: (Resolver) -> T

    public init(
        _ type: T.Type = T.self,
        named: String? = nil,
        _ factory: @escaping (Resolver) -> T
    ) {
        self.type = type
        self.name = named
        self.factory = factory
    }

    var registration: Registration {
        Registration(
            key: Key(self.type, name: self.name),
            scope: .singleton,
            factory: ErasedFactory(
                outputType: T.self,
                parameterType: nil,
                call: { resolver, _ in self.factory(resolver) }
            )
        )
    }
}

public struct FactoryWithParams<P, T> {
    private let type: T.Type
    private let name: String?
    private let factory: (Resolver, P) -> T

    public init(
        _ type: T.Type = T.self,
        named: String? = nil,
        _ factory: @escaping (Resolver, P) -> T
    ) {
        self.type = type
        self.name = named
        self.factory = factory
    }

    var registration: Registration {
        Registration(
            key: Key(self.type, name: self.name),
            scope: .factory,
            factory: ErasedFactory(
                outputType: T.self,
                parameterType: P.self,
                call: { resolver, params in
                    guard let typedParams = params as? P else {
                        fatalError(
                            "Bolt: Parameter type mismatch for \(String(reflecting: self.type)). Expected \(String(reflecting: P.self))."
                        )
                    }
                    return self.factory(resolver, typedParams)
                }
            )
        )
    }
}

final class SingletonCell: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Any?

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

    func clear() {
        self.lock.withLock {
            self.value = nil
        }
    }
}
