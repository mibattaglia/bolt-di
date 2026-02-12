import Foundation
import Testing

@testable import Bolt

private final class CountingSingleton {
    let value: Int

    init(value: Int) {
        self.value = value
    }
}

private final class InitializationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.value += 1
        return self.value
    }

    func current() -> Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.value
    }
}

@Suite("Container Concurrency")
struct ContainerConcurrencySuite {
    @Test func singletonInitializesOnlyOnceAcrossConcurrentResolutions() async {
        let counter = InitializationCounter()
        let container = Container()
        container.register {
            Singleton(CountingSingleton.self) { _ in
                let value = counter.next()
                return CountingSingleton(value: value)
            }
        }

        await withTaskGroup(of: ObjectIdentifier.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    ObjectIdentifier(container.get(CountingSingleton.self))
                }
            }

            var identities: [ObjectIdentifier] = []
            for await identity in group {
                identities.append(identity)
            }

            let first = identities.first
            #expect(first != nil)
            for identity in identities {
                #expect(identity == first)
            }
        }

        let initializedCount = counter.current()
        #expect(initializedCount == 1)
    }

    @Test func factoryCreatesDistinctInstancesAcrossConcurrentResolutions() async {
        let counter = InitializationCounter()
        let container = Container()
        container.register {
            Factory(Int.self) { _ in
                counter.next()
            }
        }

        let values = await withTaskGroup(of: Int.self, returning: [Int].self) {
            group in
            for _ in 0..<32 {
                group.addTask {
                    container.get(Int.self)
                }
            }

            var resolved: [Int] = []
            for await value in group {
                resolved.append(value)
            }
            return resolved
        }

        let uniqueValues = Set(values)
        #expect(uniqueValues.count == values.count)
        #expect(counter.current() == 32)
    }
}
