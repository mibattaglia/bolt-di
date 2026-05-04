import Foundation
import Testing

@testable import Bolt

@MainActor
private final class MainActorService {
    let id = UUID()

    init() {}
}

@MainActor
private final class MainActorViewModel {
    let service: MainActorService

    init(service: MainActorService) {
        self.service = service
    }
}

@Suite("Factory Isolation")
struct FactoryIsolationSuite {
    @Test
    @MainActor
    func mainActorFactoryRegisteredInMainActorContextResolvesOnMainActor() {
        let container = Container()
        container.register {
            Factory { _ in MainActorService() }
        }

        let first: MainActorService = container.get()
        let second: MainActorService = container.get()

        #expect(first !== second)
    }

    @Test
    @MainActor
    func mainActorFactoryRegisteredInModuleBodyWithExplicitOverloadResolvesOnMainActor() {
        final class UIModule: DependencyModule {
            @ModuleBuilder
            override var body: ModuleDefinition {
                Factory(on: MainActor.self) { _ in MainActorService() }
            }
        }

        Bolt.withModules([UIModule()]) {
            let service: MainActorService = Bolt.inject()
            let expectedID = service.id
            #expect(service.id == expectedID)
        }
    }

    @Test
    @MainActor
    func mainActorFactoryNestedResolutionInheritsRootIsolation() {
        final class UIModule: DependencyModule {
            @ModuleBuilder
            override var body: ModuleDefinition {
                Factory(on: MainActor.self) { _ in MainActorService() }
                Factory(on: MainActor.self) { resolver in
                    MainActorViewModel(service: resolver.get())
                }
            }
        }

        Bolt.withModules([UIModule()]) {
            let model: MainActorViewModel = Bolt.inject()
            let expectedID = model.service.id
            #expect(model.service.id == expectedID)
        }
    }

    @Test
    @MainActor
    func nonisolatedFactoryResolvesFromMainActorContext() {
        final class Service {
            let value = 1
        }

        let container = Container()
        container.register {
            Factory { _ in Service() }
        }

        let service: Service = container.get()
        #expect(service.value == 1)
    }

    @Test
    @MainActor
    func mainActorFactoryWithParamsResolvesOnMainActor() {
        final class UIModule: DependencyModule {
            @ModuleBuilder
            override var body: ModuleDefinition {
                FactoryWithParams<String, MainActorViewModel>(on: MainActor.self) { resolver, _ in
                    MainActorViewModel(service: resolver.get())
                }
                Factory(on: MainActor.self) { _ in MainActorService() }
            }
        }

        Bolt.withModules([UIModule()]) {
            let model: MainActorViewModel = Bolt.inject(params: "user-id")
            let expectedID = model.service.id
            #expect(model.service.id == expectedID)
        }
    }
}
