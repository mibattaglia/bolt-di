@propertyWrapper
public struct Injected<T> {
    private let type: T.Type
    private let name: String?

    public init(_ type: T.Type = T.self, named: String? = nil) {
        self.type = type
        self.name = named
    }

    public var wrappedValue: T {
        Bolt.inject(self.type, named: self.name)
    }
}
