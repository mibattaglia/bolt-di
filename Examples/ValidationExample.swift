import Bolt
import Foundation

final class MissingDependencyType {}
final class ServiceA {}
final class ServiceB {}

final class BrokenGraphModule: DependencyModule {
    override func defineDependencies(into container: Container) {
        container.register {
            Factory(
                Int.self,
                dependencies: [Key(MissingDependencyType.self)]
            ) { _ in
                1
            }

            Factory(
                ServiceA.self,
                dependencies: [Key(ServiceB.self)]
            ) { _ in
                ServiceA()
            }

            Factory(
                ServiceB.self,
                dependencies: [Key(ServiceA.self)]
            ) { _ in
                ServiceB()
            }
        }
    }
}

func runValidationExample() {
    let validator = BoltValidator(modules: [BrokenGraphModule()])
    validator.validate { error in
        print("Validation issue: \(error.kind) - \(error.message)")
    }
}
