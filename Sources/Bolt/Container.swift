public final class Container: Resolver {
  public init() {}

  public func register(@DependencyBuilder _ registrations: () -> [Registration]) {
    _ = registrations()
    fatalError("Bolt: Container.register is not implemented yet.")
  }

  public func get<T>(_ type: T.Type = T.self, named: String? = nil) -> T {
    fatalError("Bolt: Container.get is not implemented yet.")
  }

  public func get<T, P>(_ type: T.Type = T.self, named: String? = nil, params: P) -> T {
    fatalError("Bolt: Container.get(params:) is not implemented yet.")
  }

  public func resetScopes() {
    fatalError("Bolt: Container.resetScopes is not implemented yet.")
  }

  public func resetAll() {
    fatalError("Bolt: Container.resetAll is not implemented yet.")
  }
}
