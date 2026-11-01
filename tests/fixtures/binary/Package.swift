// swift-tools-version:6.0
// SPDX-License-Identifier: MIT
import PackageDescription

let package = Package(
  name: "binary",
  products: [
    .executable(name: "binary", targets: ["binary"])
  ],
  targets: [
    .binaryTarget(
      name: "SwiftLintBinary",
      url:
        "https://github.com/realm/SwiftLint/releases/download/0.65.1/SwiftLintBinary.artifactbundle.zip",
      checksum: "c3a1d77647ca18c1b7e9be7dbc6cd4490d26422f28814b76370244ff61970869"
    ),
    .plugin(
      name: "LintVersion",
      capability: .buildTool(),
      dependencies: ["SwiftLintBinary"]
    ),
    .executableTarget(name: "binary", plugins: ["LintVersion"]),
  ]
)
