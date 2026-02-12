@resultBuilder
public enum DependencyBuilder {
  public static func buildBlock(_ components: Registration...) -> [Registration] {
    components
  }

  public static func buildExpression<T>(_ expression: Factory<T>) -> Registration {
    expression.registration
  }

  public static func buildExpression<T>(_ expression: Singleton<T>) -> Registration {
    expression.registration
  }

  public static func buildExpression<P, T>(_ expression: FactoryWithParams<P, T>) -> Registration {
    expression.registration
  }

  public static func buildExpression<P, T>(_ expression: SingletonWithParams<P, T>) -> Registration
  {
    expression.registration
  }

  public static func buildExpression(_ expression: Registration) -> Registration {
    expression
  }

  public static func buildOptional(_ component: [Registration]?) -> [Registration] {
    component ?? []
  }

  public static func buildEither(first component: [Registration]) -> [Registration] {
    component
  }

  public static func buildEither(second component: [Registration]) -> [Registration] {
    component
  }

  public static func buildArray(_ components: [[Registration]]) -> [Registration] {
    components.flatMap { $0 }
  }
}
