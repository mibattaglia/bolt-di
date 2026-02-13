import Foundation

enum SetupConcurrencyGuardState {
    case proceed
    case overlap
}

final class SetupConcurrencyGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var activeCalls = 0

    func begin() -> SetupConcurrencyGuardState {
        self.lock.withLock {
            self.activeCalls += 1
            return self.activeCalls > 1 ? .overlap : .proceed
        }
    }

    func end() {
        self.lock.withLock {
            self.activeCalls -= 1
        }
    }
}
