// swift-tools-version:6.0
// SPDX-License-Identifier: MIT
import PackageDescription

let package = Package(
  name: "paths",
  products: [
    .executable(name: "paths", targets: ["paths"])
  ],
  dependencies: [
    .package(path: "Libraries/Shout")
  ],
  targets: [
    .executableTarget(
      name: "paths",
      dependencies: [.product(name: "Shout", package: "Shout")]
    )
  ]
)
