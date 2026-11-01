# SPDX-License-Identifier: MIT
#
# What the interactive mode builds: the tree of tree.nix for a lockfile,
# with the fetchers of the nixpkgs the swiftpm-purifier command was built
# with. Its entries have the same store paths as the entries of the
# sandboxed build, because a fetch's store path depends only on its name
# and hash.
{
  lockFile,
  nixpkgs,
}:
let
  pkgs = import nixpkgs { };
in
import ./tree.nix {
  lock = import ./lock.nix { inherit lockFile; };
  inherit (pkgs)
    fetchurl
    fetchgit
    runCommand
    unzip
    ;
  patchArtifact = pkgs.callPackage ./patch-artifact.nix { };
}
