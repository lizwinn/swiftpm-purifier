// SPDX-License-Identifier: MIT
import OrderedCollections

/// Builds a greeting for each name, once per distinct name, in the order
/// the names first appear.
public func greetings(for names: [String]) -> [String] {
  OrderedSet(names).map { "Hello, \($0)!" }
}
