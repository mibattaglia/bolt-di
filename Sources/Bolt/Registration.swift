import Foundation

public struct Registration {
  public let key: Key
  public let scope: Scope

  let factory: ErasedFactory

  init(key: Key, scope: Scope, factory: ErasedFactory) {
    self.key = key
    self.scope = scope
    self.factory = factory
  }
}

struct ErasedFactory {
  let outputType: Any.Type
  let parameterType: Any.Type?
  let factory: (Resolver, Any?) -> Any
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
        factory: { resolver, _ in self.factory(resolver) }
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
        factory: { resolver, _ in self.factory(resolver) }
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
        factory: { resolver, params in
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

public struct SingletonWithParams<P, T> {
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
      scope: .singleton,
      factory: ErasedFactory(
        outputType: T.self,
        parameterType: P.self,
        factory: { resolver, params in
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
