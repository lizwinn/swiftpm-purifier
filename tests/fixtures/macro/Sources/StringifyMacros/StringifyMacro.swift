// SPDX-License-Identifier: MIT
import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `#stringify(x)` expands to `(x, "x")`.
public struct StringifyMacro: ExpressionMacro {
  public static func expansion(
    of node: some FreestandingMacroExpansionSyntax,
    in context: some MacroExpansionContext
  ) -> ExprSyntax {
    guard let argument = node.arguments.first?.expression else {
      fatalError("#stringify needs an argument")
    }
    return "(\(argument), \(literal: argument.description))"
  }
}

@main
struct StringifyPlugin: CompilerPlugin {
  let providingMacros: [Macro.Type] = [StringifyMacro.self]
}
