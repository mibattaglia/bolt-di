import Bolt
import Foundation

struct ExampleUser {
    let id: Int
    let name: String
}

protocol ExampleUserAPI {
    func fetchUser(id: Int) -> ExampleUser
}

struct LiveExampleUserAPI: ExampleUserAPI {
    func fetchUser(id: Int) -> ExampleUser {
        ExampleUser(id: id, name: "Live User \(id)")
    }
}

final class ExampleUserService {
    private let api: ExampleUserAPI

    init(api: ExampleUserAPI) {
        self.api = api
    }

    func loadUser(id: Int) -> ExampleUser {
        self.api.fetchUser(id: id)
    }
}

final class ExampleFeatureViewModel {
    private let userService: ExampleUserService

    init(userService: ExampleUserService) {
        self.userService = userService
    }

    func title(for id: Int) -> String {
        self.userService.loadUser(id: id).name
    }
}

final class ExampleNetworkModule: DependencyModule {
    override func defineDependencies(into container: Container) {
        container.register {
            Singleton(ExampleUserAPI.self) { _ in LiveExampleUserAPI() }
            Factory(
                ExampleUserService.self,
                dependencies: [Key(ExampleUserAPI.self)]
            ) { resolver in
                let api: ExampleUserAPI = resolver.get()
                return ExampleUserService(api: api)
            }
        }
    }
}

final class ExampleFeatureModule: DependencyModule {
    override func defineDependencies(into container: Container) {
        container.register {
            Factory(
                ExampleFeatureViewModel.self,
                dependencies: [Key(ExampleUserService.self)]
            ) { resolver in
                let userService: ExampleUserService = resolver.get()
                return ExampleFeatureViewModel(userService: userService)
            }
        }
    }
}

func runBasicCompositionExample() {
    Bolt.setup(modules: [ExampleNetworkModule(), ExampleFeatureModule()])
    let viewModel: ExampleFeatureViewModel = Bolt.inject()
    _ = viewModel.title(for: 1)
}
