import Foundation
import Testing

@testable import Bolt

private final class APIClient {}

private final class UserService {
    let api: APIClient

    init(api: APIClient) {
        self.api = api
    }
}

private final class RootService {
    let userService: UserService

    init(userService: UserService) {
        self.userService = userService
    }
}

@Suite("Container Resolution")
struct ContainerResolutionSuite {
    @Test func factoryReturnsNewInstanceEachResolve() {
        let container = Container()
        container.register {
            Factory { _ in APIClient() }
        }

        let first = container.get(APIClient.self)
        let second = container.get(APIClient.self)

        #expect(first !== second)
    }

    @Test func singletonReturnsSameInstanceEachResolve() {
        let container = Container()
        container.register {
            Singleton { _ in APIClient() }
        }

        let first = container.get(APIClient.self)
        let second = container.get(APIClient.self)

        #expect(first === second)
    }

    @Test func nestedResolutionUsesResolver() {
        let container = Container()
        container.register {
            Singleton { _ in APIClient() }
            Factory { resolver in
                UserService(api: try resolver.get(APIClient.self))
            }
        }

        let api: APIClient = container.get()
        let service: UserService = container.get()

        #expect(service.api === api)
    }

    @Test func factoryRootResolutionBuildsGraphEachTime() {
        let container = Container()
        container.register {
            Factory { _ in APIClient() }
            Factory { resolver in
                UserService(api: try resolver.get(APIClient.self))
            }
            Factory { resolver in
                RootService(userService: try resolver.get(UserService.self))
            }
        }

        let first: RootService = container.get()
        let second: RootService = container.get()

        #expect(first !== second)
        #expect(first.userService !== second.userService)
        #expect(first.userService.api !== second.userService.api)
    }
}

@Suite("Container Parameters")
struct ContainerParameterizedResolutionSuite {
    @Test func factoryWithParamsUsesRuntimeValue() {
        let container = Container()
        container.register {
            FactoryWithParams(String.self, named: "greeting") { (_: Resolver, name: String) in
                "Hello, \(name)!"
            }
        }

        let michael: String = container.get(String.self, named: "greeting", params: "Michael")
        let sam: String = container.get(String.self, named: "greeting", params: "Sam")

        #expect(michael == "Hello, Michael!")
        #expect(sam == "Hello, Sam!")
    }

    @Test func factoryWithParamsCreatesNewInstanceEachResolve() {
        let container = Container()
        container.register {
            FactoryWithParams(NSString.self) { (_: Resolver, value: String) in
                NSString(string: value)
            }
        }

        let first: NSString = container.get(params: "first")
        let second: NSString = container.get(params: "second")

        #expect(first !== second)
        #expect(first as String == "first")
        #expect(second as String == "second")
    }
}

@Suite("Container Scope Management")
struct ContainerScopeManagementSuite {
    @Test func resetScopesClearsSingletonCache() {
        let container = Container()
        container.register {
            Singleton { _ in APIClient() }
        }

        let first = container.get(APIClient.self)
        container.resetScopes()
        let second = container.get(APIClient.self)

        #expect(first !== second)
    }
}
