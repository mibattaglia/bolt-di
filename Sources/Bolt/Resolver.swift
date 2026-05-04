public protocol Resolver {
    func get<T>(
        _ type: T.Type,
        named: String?,
        isolation: isolated (any Actor)?
    ) -> T

    func get<T, P>(
        _ type: T.Type,
        named: String?,
        params: P,
        isolation: isolated (any Actor)?
    ) -> T
}

extension Resolver {
    public func get<T>(
        _ type: T.Type = T.self,
        named: String? = nil,
        isolation: isolated (any Actor)? = #isolation
    ) -> T {
        self.get(type, named: named, isolation: isolation)
    }

    public func get<T, P>(
        _ type: T.Type = T.self,
        named: String? = nil,
        params: P,
        isolation: isolated (any Actor)? = #isolation
    ) -> T {
        self.get(type, named: named, params: params, isolation: isolation)
    }
}
