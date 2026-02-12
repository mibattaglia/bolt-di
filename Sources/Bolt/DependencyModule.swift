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
        var visitedInstances = Set<ObjectIdentifier>()
        var stackTypeIDs: [ObjectIdentifier] = []
        var stackTypeNames: [String] = []
        var ordered: [DependencyModule] = []

        func visit(_ module: DependencyModule) throws {
            let instanceID = ObjectIdentifier(module)
            if visitedInstances.contains(instanceID) { return }

            let typeID = ObjectIdentifier(type(of: module))
            let typeName = String(reflecting: type(of: module))
            if let cycleStart = stackTypeIDs.lastIndex(of: typeID) {
                let path = Array(stackTypeNames[cycleStart...]) + [typeName]
                throw ModuleGraphError.cycle(path: path)
            }

            stackTypeIDs.append(typeID)
            stackTypeNames.append(typeName)
            let dependencies = module.dependentModules
            for dependency in dependencies {
                try visit(dependency)
            }

            _ = stackTypeIDs.popLast()
            _ = stackTypeNames.popLast()
            visitedInstances.insert(instanceID)
            ordered.append(module)
        }

        for root in roots {
            try visit(root)
        }
        return ordered
    }
}
