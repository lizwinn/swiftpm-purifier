// SPDX-License-Identifier: MIT
import Algorithms

/// The distinct words in upper case, in the order they first appear,
/// joined by spaces.
public func shout(_ words: [String]) -> String {
  words.uniqued().map { $0.uppercased() }.joined(separator: " ")
}
