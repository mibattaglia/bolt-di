// swift-tools-version: 6.0

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
  ],
  targets: [
    .target(
      name: "Bolt"
    ),
    .testTarget(
      name: "BoltTests",
      dependencies: ["Bolt"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
