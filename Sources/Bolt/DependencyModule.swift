public struct ModuleDefinition {
    public let dependentModules: [DependencyModule]
    public let registrations: [Registration]

    public init(
        dependentModules: [DependencyModule] = [],
        registrations: [Registration] = []
    ) {
        self.dependentModules = dependentModules
        self.registrations = registrations
    }
}

public struct DependentModules {
    public let values: [DependencyModule]

    public init(@ModuleBuilder _ content: () -> [DependencyModule]) {
        self.values = content()
    }
}

public enum ModuleComponent {
    case dependency(DependencyModule)
    case registration(Registration)
}

@resultBuilder
public enum ModuleBuilder {
    public static func buildBlock(_ components: [ModuleComponent]...) -> [ModuleComponent] {
        components.flatMap { $0 }
    }

    public static func buildExpression(_ expression: DependentModules) -> [ModuleComponent] {
        expression.values.map { .dependency($0) }
    }

    public static func buildExpression(_ expression: DependencyModule) -> [ModuleComponent] {
        [.dependency(expression)]
    }

    public static func buildExpression<T>(_ expression: Factory<T>) -> [ModuleComponent] {
        [.registration(expression.registration)]
    }

    public static func buildExpression<T>(_ expression: Singleton<T>) -> [ModuleComponent] {
        [.registration(expression.registration)]
    }

    public static func buildExpression<P, T>(_ expression: FactoryWithParams<P, T>) -> [ModuleComponent] {
        [.registration(expression.registration)]
    }

    public static func buildFinalResult(_ component: [ModuleComponent]) -> ModuleDefinition {
        var dependentModules: [DependencyModule] = []
        var registrations: [Registration] = []

        for value in component {
            switch value {
            case .dependency(let module):
                dependentModules.append(module)
            case .registration(let registration):
                registrations.append(registration)
            }
        }

        return ModuleDefinition(
            dependentModules: dependentModules,
            registrations: registrations
        )
    }

    public static func buildFinalResult(_ component: [ModuleComponent]) -> [DependencyModule] {
        var dependentModules: [DependencyModule] = []

        for value in component {
            switch value {
            case .dependency(let module):
                dependentModules.append(module)
            case .registration:
                fatalError("Bolt: DependentModules can only contain module dependencies.")
            }
        }

        return dependentModules
    }
}

open class DependencyModule {
    public init() {}

    open var body: ModuleDefinition {
        ModuleDefinition()
    }
}

enum ModuleGraphError: Error {
    case cycle(path: [String])
}

struct ModulePlan {
    let orderedModules: [DependencyModule]
    let definitionsByInstanceID: [ObjectIdentifier: ModuleDefinition]
}

extension DependencyModule {
    static func orderedModules(from roots: [DependencyModule]) throws -> [DependencyModule] {
        try planGraph(from: roots).orderedModules
    }

    static func planGraph(from roots: [DependencyModule]) throws -> ModulePlan {
        var visitedInstances = Set<ObjectIdentifier>()
        var stackTypeIDs: [ObjectIdentifier] = []
        var stackTypeNames: [String] = []
        var ordered: [DependencyModule] = []
        var definitionsByInstanceID: [ObjectIdentifier: ModuleDefinition] = [:]

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

            let definition = module.body
            definitionsByInstanceID[instanceID] = definition

            for dependency in definition.dependentModules {
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

        return ModulePlan(
            orderedModules: ordered,
            definitionsByInstanceID: definitionsByInstanceID
        )
    }
}
