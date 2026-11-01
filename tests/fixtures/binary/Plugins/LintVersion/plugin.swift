// SPDX-License-Identifier: MIT
import PackagePlugin

/// Runs the swiftlint binary of the binary target before each build. SwiftPM
/// allows only binary targets as the executables of prebuild commands, so
/// the build fails unless the locked binary runs.
@main
struct LintVersion: BuildToolPlugin {
  func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
    let swiftlint = try context.tool(named: "swiftlint")
    return [
      .prebuildCommand(
        displayName: "Run swiftlint version",
        executable: swiftlint.url,
        arguments: ["version"],
        outputFilesDirectory: context.pluginWorkDirectoryURL
      )
    ]
  }
}
