public protocol Resolver {
    func get<T>(_ type: T.Type, named: String?) -> T
    func get<T, P>(_ type: T.Type, named: String?, params: P) -> T
}

extension Resolver {
    public func get<T>(_ type: T.Type = T.self, named: String? = nil) -> T {
        self.get(type, named: named)
    }

    public func get<T, P>(_ type: T.Type = T.self, named: String? = nil, params: P) -> T {
        self.get(type, named: named, params: params)
    }
}
