import Testing

@testable import Bolt

@Suite("Package Smoke Tests")
struct PackageSmokeTests {
    @Test func packageBuilds() {
        _ = Key(String.self)
    }
}
