import Foundation

extension NSLock {
    @inline(__always)
    func withLock<R>(_ body: () -> R) -> R {
        self.lock()
        defer { self.unlock() }
        return body()
    }
}
