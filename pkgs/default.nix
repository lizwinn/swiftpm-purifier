# SPDX-License-Identifier: MIT
{ callPackage, ... }:
let
  cli = callPackage ./cli { };
in
{
  # The swiftpm-purifier command.
  inherit cli;
  # The Swift toolchain with `swift` running through swiftpm-purifier, and
  # the swiftpm-purifier command beside it.
  toolchain = callPackage ./toolchain { inherit cli; };
}
