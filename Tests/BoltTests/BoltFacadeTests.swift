import Testing

@testable import Bolt

private final class NamedClient {
    let name: String

    init(name: String) {
        self.name = name
    }
}

private struct InjectedConsumer {
    @Injected var value: String
    @Injected(named: "live") var client: NamedClient
}

@Suite("Bolt Facade")
struct BoltFacadeSuite {
    @Test func injectResolvesFromCurrentContainer() {
        let container = Container()
        container.register {
            Factory(String.self) { _ in "from-container" }
        }

        Bolt.withContainer(container) {
            let value: String = Bolt.inject()
            #expect(value == "from-container")
        }
    }

    @Test func injectSupportsNamedAndParameterizedResolution() {
        let container = Container()
        container.register {
            Singleton(NamedClient.self, named: "live") { _ in NamedClient(name: "live") }
            FactoryWithParams(String.self, named: "greeting") { (_: Resolver, value: String) in
                "Hello, \(value)"
            }
        }

        Bolt.withContainer(container) {
            let client: NamedClient = Bolt.inject(named: "live")
            let greeting: String = Bolt.inject(named: "greeting", params: "Bolt")

            #expect(client.name == "live")
            #expect(greeting == "Hello, Bolt")
        }
    }

    @Test func injectedPropertyWrapperResolvesFromCurrentContainer() {
        let container = Container()
        container.register {
            Factory(String.self) { _ in "value" }
            Singleton(NamedClient.self, named: "live") { _ in NamedClient(name: "named") }
        }

        Bolt.withContainer(container) {
            let consumer = InjectedConsumer()
            #expect(consumer.value == "value")
            #expect(consumer.client.name == "named")
        }
    }
}
