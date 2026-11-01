// SPDX-License-Identifier: MIT

/// Pairs an expression's value with its source text.
@freestanding(expression)
public macro stringify<T>(_ value: T) -> (T, String) =
  #externalMacro(module: "StringifyMacros", type: "StringifyMacro")
