// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "BoltBenchmarks",
  platforms: [
    .macOS(.v15)
  ],
  products: [
    .executable(name: "BoltBenchmarks", targets: ["BoltBenchmarks"])
  ],
  dependencies: [
    .package(path: ".."),
    .package(url: "https://github.com/google/swift-benchmark.git", from: "0.1.2"),
    .package(url: "https://github.com/WhoopInc/WhoopDI.git", branch: "main"),
    .package(url: "https://github.com/hmlongco/Factory.git", branch: "main"),
    .package(url: "https://github.com/pointfreeco/swift-dependencies.git", branch: "main")
  ],
  targets: [
    .executableTarget(
      name: "BoltBenchmarks",
      dependencies: [
        .product(name: "Bolt", package: "bolt-di"),
        .product(name: "Benchmark", package: "swift-benchmark"),
        .product(name: "WhoopDIKit", package: "WhoopDI"),
        .product(name: "Factory", package: "Factory"),
        .product(name: "Dependencies", package: "swift-dependencies")
      ]
    )
  ]
)
