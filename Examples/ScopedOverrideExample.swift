import Bolt
import Foundation

protocol ExampleClock {
    func now() -> Date
}

struct LiveExampleClock: ExampleClock {
    func now() -> Date {
        Date()
    }
}

struct FixedExampleClock: ExampleClock {
    let date: Date

    func now() -> Date {
        self.date
    }
}

final class ExampleGreetingService {
    private let clock: ExampleClock

    init(clock: ExampleClock) {
        self.clock = clock
    }

    func greeting(for name: String) -> String {
        let timestamp = Int(self.clock.now().timeIntervalSince1970)
        return "Hello \(name) @ \(timestamp)"
    }
}

final class ScopedOverrideModule: DependencyModule {
    override func defineDependencies(into container: Container) {
        container.register {
            Singleton(ExampleClock.self) { _ in LiveExampleClock() }
            Factory(
                ExampleGreetingService.self,
                dependencies: [Key(ExampleClock.self)]
            ) { resolver in
                let clock: ExampleClock = resolver.get()
                return ExampleGreetingService(clock: clock)
            }
        }
    }
}

func runScopedOverrideExample() {
    let container = Container()
    ScopedOverrideModule().defineDependencies(into: container)

    Bolt.withContainer(container) {
        let liveService: ExampleGreetingService = Bolt.inject()
        _ = liveService.greeting(for: "Live")

        Bolt.withOverrides {
            Singleton(ExampleClock.self) { _ in
                FixedExampleClock(date: Date(timeIntervalSince1970: 1_700_000_000))
            }
        } _: {
            let deterministicService: ExampleGreetingService = Bolt.inject()
            _ = deterministicService.greeting(for: "Test")
        }
    }
}
