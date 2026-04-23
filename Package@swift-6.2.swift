// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "Bolt",
  platforms: [
    .iOS(.v17),
    .macOS(.v15),
    .watchOS(.v10),
  ],
  products: [
    .library(
      name: "Bolt",
      targets: ["Bolt"]
    ),
    .library(
      name: "BoltTestSupport",
      targets: ["BoltTestSupport"]
    ),
  ],
  targets: [
    .target(
      name: "Bolt"
    ),
    .target(
      name: "BoltTestSupport",
      dependencies: ["Bolt"]
    ),
    .testTarget(
      name: "BoltTests",
      dependencies: ["Bolt"]
    ),
    .testTarget(
      name: "BoltTestSupportTests",
      dependencies: ["Bolt", "BoltTestSupport"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
