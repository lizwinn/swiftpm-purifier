// swift-tools-version:6.0
// SPDX-License-Identifier: MIT
import PackageDescription

let package = Package(
  name: "hello",
  products: [
    .executable(name: "hello", targets: ["hello"]),
    .library(name: "Greeting", targets: ["Greeting"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
  ],
  targets: [
    .target(
      name: "Greeting",
      dependencies: [.product(name: "OrderedCollections", package: "swift-collections")]
    ),
    .executableTarget(
      name: "hello",
      dependencies: [
        "Greeting",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
    ),
    .testTarget(name: "GreetingTests", dependencies: ["Greeting"]),
  ]
)
