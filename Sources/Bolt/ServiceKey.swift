import Foundation

public struct ServiceKey: Hashable, Sendable {
    public let typeID: ObjectIdentifier
    public let name: String?

    public init(_ type: Any.Type, name: String? = nil) {
        self.typeID = normalizedTypeIdentifier(for: type)
        self.name = name
    }

    var typeName: String {
        lookupTypeName(for: self.typeID) ?? "<unknown>"
    }
}

private enum KeyInternals {
    static let lock = NSLock()
    nonisolated(unsafe) static var knownIdentifierTable: [ObjectIdentifier: ObjectIdentifier] = [:]
    nonisolated(unsafe) static var nameToIdentifierTable: [String: ObjectIdentifier] = [:]
    nonisolated(unsafe) static var identifierToNameTable: [ObjectIdentifier: String] = [:]
}

private func normalizedTypeIdentifier(for type: Any.Type) -> ObjectIdentifier {
    KeyInternals.lock.withLock {
        let requested = ObjectIdentifier(type)
        if let cached = KeyInternals.knownIdentifierTable[requested] {
            return cached
        }

        let name = String(reflecting: type)
        let normalized = KeyInternals.nameToIdentifierTable[name, default: requested]

        KeyInternals.knownIdentifierTable[requested] = normalized
        KeyInternals.identifierToNameTable[normalized] = name

        return normalized
    }
}

private func lookupTypeName(for identifier: ObjectIdentifier) -> String? {
    KeyInternals.lock.withLock {
        KeyInternals.identifierToNameTable[identifier]
    }
}
