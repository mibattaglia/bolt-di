import Testing

@testable import Bolt

@Test func packageBuilds() {
  _ = Key(String.self)
}
