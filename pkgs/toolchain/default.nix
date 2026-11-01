# SPDX-License-Identifier: MIT
#
# A Swift toolchain whose `swift` runs through `swiftpm-purifier swift`:
# in a package with an up-to-date lockfile, SwiftPM builds, tests and runs
# on the locked dependencies, offline. The rest of the toolchain (swiftc,
# the SwiftPM subcommands, and sourcekit-lsp, the language server editors
# use) comes from nixpkgs unchanged; sourcekit-lsp reads the locked
# dependencies from the same links.
{
  symlinkJoin,
  writeShellScriptBin,
  swiftPackages,
  cli,
}:
let
  swift = writeShellScriptBin "swift" ''
    exec ${cli}/bin/swiftpm-purifier swift "$@"
  '';
in
symlinkJoin {
  name = "swiftpm-purifier-toolchain";
  paths = [
    swift
    cli
    swiftPackages.swift
    swiftPackages.swiftpm
    swiftPackages.sourcekit-lsp
  ];
  meta.mainProgram = "swift";
}
