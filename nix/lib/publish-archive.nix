# SPDX-License-Identifier: MIT
#
# What `swiftpm-purifier publish` builds: the source archive of
# source-archive.nix for the package at `src`, an absolute path, with the
# nixpkgs the swiftpm-purifier command was built with.
{
  nixpkgs,
  src,
  name,
}:
let
  pkgs = import nixpkgs { };
in
import ./source-archive.nix { inherit (pkgs) runCommand zip; } {
  src = /. + src;
  inherit name;
}
