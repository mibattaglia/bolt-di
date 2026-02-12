open class DependencyModule {
    public init() {}

    open var dependentModules: [DependencyModule] {
        []
    }

    open func defineDependencies(into container: Container) {}
}

enum ModuleGraphError: Error {
    case cycle(path: [String])
}

extension DependencyModule {
    static func orderedModules(from roots: [DependencyModule]) throws -> [DependencyModule] {
        var visiting = Set<ObjectIdentifier>()
        var visited = Set<ObjectIdentifier>()
        var stack: [ObjectIdentifier] = []
        var namesByID: [ObjectIdentifier: String] = [:]
        var instancesByID: [ObjectIdentifier: DependencyModule] = [:]
        var ordered: [DependencyModule] = []

        func visit(_ module: DependencyModule) throws {
            let id = ObjectIdentifier(type(of: module))
            if visited.contains(id) { return }

            if visiting.contains(id) {
                if let cycleStart = stack.lastIndex(of: id) {
                    let cycleIDs = Array(stack[cycleStart...]) + [id]
                    let path = cycleIDs.map { namesByID[$0] ?? "UnknownModule" }
                    throw ModuleGraphError.cycle(path: path)
                }
                throw ModuleGraphError.cycle(path: [namesByID[id] ?? "UnknownModule"])
            }

            if instancesByID[id] == nil {
                instancesByID[id] = module
            }
            namesByID[id] = String(reflecting: type(of: module))

            visiting.insert(id)
            stack.append(id)

            let dependencies = instancesByID[id]?.dependentModules ?? module.dependentModules
            for dependency in dependencies {
                try visit(dependency)
            }

            _ = stack.popLast()
            visiting.remove(id)
            visited.insert(id)
            if let canonical = instancesByID[id] {
                ordered.append(canonical)
            }
        }

        for root in roots {
            try visit(root)
        }
        return ordered
    }
}
