// swift-tools-version:6.0
// SPDX-License-Identifier: MIT
import PackageDescription

let package = Package(
  name: "Shout",
  products: [
    .library(name: "Shout", targets: ["Shout"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-algorithms.git", from: "1.2.0")
  ],
  targets: [
    .target(
      name: "Shout",
      dependencies: [.product(name: "Algorithms", package: "swift-algorithms")]
    )
  ]
)
