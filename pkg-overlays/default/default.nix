# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.swiftpm-purifier` (`.cli`, `.toolchain`), and the builder
# `pkgs.buildSwiftPMProject` (nix/lib/build-swiftpm-project.nix) beside
# them, where nixpkgs keeps its own builders, so a package written for
# callPackage takes it by name. The builder is called in nixpkgs' Swift
# scope, so it builds with the Swift toolchain's stdenv. A consumer that
# lists this flake in `projects` holds the overlay as
# `swiftpm-purifier/default`, which its package sets apply by default.
{ closure-lib, ... }:
let
  packages = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "swiftpm-purifier";
in
{
  overlay =
    final: prev:
    packages final prev
    // {
      buildSwiftPMProject = final.swiftPackages.callPackage ../../nix/lib/build-swiftpm-project.nix { };
    };
}
