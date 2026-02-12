import Testing

@testable import Bolt

private final class APIClient {}

private final class UserService {
    let api: APIClient

    init(api: APIClient) {
        self.api = api
    }
}

private final class SessionClient {
    let value: String

    init(value: String) {
        self.value = value
    }
}

@Suite("Container Resolution")
struct ContainerResolutionSuite {
    @Test func factoryReturnsNewInstanceEachResolve() {
        let container = Container()
        container.register {
            Factory(APIClient.self) { _ in APIClient() }
        }

        let first = container.get(APIClient.self)
        let second = container.get(APIClient.self)

        #expect(first !== second)
    }

    @Test func singletonReturnsSameInstanceEachResolve() {
        let container = Container()
        container.register {
            Singleton(APIClient.self) { _ in APIClient() }
        }

        let first = container.get(APIClient.self)
        let second = container.get(APIClient.self)

        #expect(first === second)
    }

    @Test func nestedResolutionUsesResolver() {
        let container = Container()
        container.register {
            Singleton(APIClient.self) { _ in APIClient() }
            Factory(UserService.self) { resolver in
                UserService(api: resolver.get(APIClient.self))
            }
        }

        let api: APIClient = container.get()
        let service: UserService = container.get()

        #expect(service.api === api)
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

    @Test func singletonWithParamsInitializesOnceAndReuses() {
        let container = Container()
        container.register {
            SingletonWithParams(SessionClient.self) { (_: Resolver, value: String) in
                SessionClient(value: value)
            }
        }

        let first: SessionClient = container.get(params: "first")
        let second: SessionClient = container.get(params: "second")

        #expect(first === second)
        #expect(first.value == "first")
    }
}

@Suite("Container Scope Management")
struct ContainerScopeManagementSuite {
    @Test func resetScopesClearsSingletonCache() {
        let container = Container()
        container.register {
            Singleton(APIClient.self) { _ in APIClient() }
        }

        let first = container.get(APIClient.self)
        container.resetScopes()
        let second = container.get(APIClient.self)

        #expect(first !== second)
    }
}
