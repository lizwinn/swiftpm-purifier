// swift-tools-version:6.0
// SPDX-License-Identifier: MIT
import CompilerPluginSupport
import PackageDescription

let package = Package(
  name: "macro",
  // swift-syntax's macro products require macOS 10.15.
  platforms: [
    .macOS(.v10_15)
  ],
  products: [
    .executable(name: "macro", targets: ["macro"])
  ],
  dependencies: [
    .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "602.0.0")
  ],
  targets: [
    .macro(
      name: "StringifyMacros",
      dependencies: [
        .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
        .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
      ]
    ),
    .target(name: "Stringify", dependencies: ["StringifyMacros"]),
    .executableTarget(name: "macro", dependencies: ["Stringify"]),
  ]
)
