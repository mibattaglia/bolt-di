import Foundation

// MARK: - Actor isolation model

struct ActorIsolationIdentity: Equatable, Sendable {
    let actorKey: ServiceKey
    let instanceID: ObjectIdentifier

    var description: String {
        self.actorKey.typeName
    }
}

enum RegistrationIsolation: Equatable, Sendable {
    case none
    case actor(ActorIsolationIdentity)

    static func capture(_ isolation: isolated (any Actor)?) -> RegistrationIsolation {
        guard let isolation else { return .none }
        return .actor(
            ActorIsolationIdentity(
                actorKey: ServiceKey(Swift.type(of: isolation)),
                instanceID: ObjectIdentifier(isolation as AnyObject)
            )
        )
    }

    static var mainActor: RegistrationIsolation {
        .actor(
            ActorIsolationIdentity(
                actorKey: ServiceKey(MainActor.self),
                instanceID: ObjectIdentifier(MainActor.shared)
            )
        )
    }

    var description: String {
        switch self {
        case .none:
            return "nonisolated"
        case .actor(let identity):
            return identity.description
        }
    }
}

private func callMainActorFactory<T>(_ factory: @MainActor () throws -> T) throws -> T where T: Sendable {
    try MainActor.assumeIsolated {
        try factory()
    }
}


// MARK: - Registration

public struct Registration {
    public let key: ServiceKey
    let shape: RegistrationShape
    let factory: ErasedFactory
    let singletonCell: SingletonCell?

    let isolation: RegistrationIsolation

    init(key: ServiceKey, scope: Scope, isolation: RegistrationIsolation, factory: ErasedFactory) {
        self.key = key
        self.shape = RegistrationShape(scope: scope, hasParameters: factory.parameterType != nil)
        self.isolation = isolation
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
    let call: (Resolver, Any?) throws -> Any
    let acceptsParameter: ((Any) -> Bool)?
    let acceptsOutput: (Any) -> Bool

    init(
        outputType: Any.Type,
        parameterType: Any.Type?,
        call: @escaping (Resolver, Any?) throws -> Any,
        acceptsParameter: ((Any) -> Bool)? = nil,
        acceptsOutput: @escaping (Any) -> Bool = { _ in true }
    ) {
        self.outputType = outputType
        self.parameterType = parameterType
        self.call = call
        self.acceptsParameter = acceptsParameter
        self.acceptsOutput = acceptsOutput
    }
}

public struct Factory<T> {
    private let type: T.Type
    private let name: String?
    private let isolation: RegistrationIsolation
    private let factory: (Resolver) throws -> T

    public init(
        _ type: T.Type = T.self,
        named: String? = nil,
        isolation: isolated (any Actor)? = #isolation,
        _ factory: @escaping (Resolver) throws -> T
    ) {
        self.type = type
        self.name = named
        self.isolation = .capture(isolation)
        self.factory = factory
    }

    public init(
        _ type: T.Type = T.self,
        named: String? = nil,
        on actor: MainActor.Type,
        _ factory: @escaping @MainActor (Resolver) throws -> T
    ) where T: Sendable {
        self.type = type
        self.name = named
        self.isolation = .mainActor
        self.factory = { resolver in
            nonisolated(unsafe) let unsafeResolver = resolver
            return try callMainActorFactory {
                try factory(unsafeResolver)
            }
        }
    }

    var registration: Registration {
        Registration(
            key: ServiceKey(self.type, name: self.name),
            scope: .factory,
            isolation: self.isolation,
            factory: ErasedFactory(
                outputType: T.self,
                parameterType: nil,
                call: { resolver, _ in try self.factory(resolver) },
                acceptsOutput: { $0 is T }
            )
        )
    }
}

public struct Singleton<T> {
    private let type: T.Type
    private let name: String?
    private let factory: (Resolver) throws -> T

    public init(
        _ type: T.Type = T.self,
        named: String? = nil,
        _ factory: @escaping (Resolver) throws -> T
    ) {
        self.type = type
        self.name = named
        self.factory = factory
    }

    var registration: Registration {
        Registration(
            key: ServiceKey(self.type, name: self.name),
            scope: .singleton,
            isolation: .none,
            factory: ErasedFactory(
                outputType: T.self,
                parameterType: nil,
                call: { resolver, _ in try self.factory(resolver) },
                acceptsOutput: { $0 is T }
            )
        )
    }
}

public struct FactoryWithParams<P, T> {
    private let type: T.Type
    private let name: String?
    private let isolation: RegistrationIsolation
    private let factory: (Resolver, P) throws -> T

    public init(
        _ type: T.Type = T.self,
        named: String? = nil,
        isolation: isolated (any Actor)? = #isolation,
        _ factory: @escaping (Resolver, P) throws -> T
    ) {
        self.type = type
        self.name = named
        self.isolation = .capture(isolation)
        self.factory = factory
    }

    public init(
        _ type: T.Type = T.self,
        named: String? = nil,
        on actor: MainActor.Type,
        _ factory: @escaping @MainActor (Resolver, P) throws -> T
    ) where T: Sendable {
        self.type = type
        self.name = named
        self.isolation = .mainActor
        self.factory = { resolver, params in
            nonisolated(unsafe) let unsafeResolver = resolver
            nonisolated(unsafe) let unsafeParams = params
            return try callMainActorFactory {
                try factory(unsafeResolver, unsafeParams)
            }
        }
    }

    var registration: Registration {
        Registration(
            key: ServiceKey(self.type, name: self.name),
            scope: .factory,
            isolation: self.isolation,
            factory: ErasedFactory(
                outputType: T.self,
                parameterType: P.self,
                call: { resolver, params in
                    guard let typedParams = params as? P else {
                        throw ResolutionError.parameterTypeMismatch(
                            ServiceKey(self.type, name: self.name),
                            expected: P.self,
                            actual: Swift.type(of: params as Any)
                        )
                    }
                    return try self.factory(resolver, typedParams)
                },
                acceptsParameter: { $0 is P },
                acceptsOutput: { $0 is T }
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

    func getOrCreate(_ build: () throws -> Any) throws -> Any {
        if let value = self.value {
            return value
        }

        self.lock.lock()
        defer { self.lock.unlock() }

        if let value = self.value {
            return value
        }

        let created = try build()
        self.value = created
        return created
    }

    func clear() {
        self.lock.withLock {
            self.value = nil
        }
    }
}
