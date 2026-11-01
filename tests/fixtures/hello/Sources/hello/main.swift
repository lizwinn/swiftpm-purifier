// SPDX-License-Identifier: MIT
import ArgumentParser
import Greeting

struct Hello: ParsableCommand {
  @Argument(help: "The names to greet.")
  var names: [String] = ["Nix"]

  func run() {
    for line in greetings(for: names) {
      print(line)
    }
  }
}

Hello.main()
