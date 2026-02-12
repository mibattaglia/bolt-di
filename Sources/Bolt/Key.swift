import Foundation

public struct Key: Hashable, Sendable {
    public let typeID: ObjectIdentifier
    public let typeName: String
    public let name: String?

    public init<T>(_ type: T.Type, name: String? = nil) {
        self.typeID = ObjectIdentifier(type)
        self.typeName = String(reflecting: type)
        self.name = name
    }
}
