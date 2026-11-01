// SPDX-License-Identifier: MIT
import Greeting
import XCTest

final class GreetingTests: XCTestCase {
  func testRepeatedNamesAreGreetedOnce() {
    XCTAssertEqual(greetings(for: ["Nix", "Swift", "Nix"]), ["Hello, Nix!", "Hello, Swift!"])
  }
}
