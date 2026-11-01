# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.swiftpm-purifier` (`.cli`, the swiftpm-purifier command, and
# `.toolchain`, the Swift toolchain whose `swift` runs through it), and the
# builder `pkgs.buildSwiftPMProject` (nix/lib/build-swiftpm-project.nix)
# beside them, where nixpkgs keeps its own builders, so a package written
# for callPackage takes it by name. A consumer that lists this flake in
# `projects` holds the overlay as `swiftpm-purifier/default`, which its
# package sets apply by default.
{ closure-lib, ... }:
let
  packages = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "swiftpm-purifier";
in
{
  overlay =
    final: prev:
    packages final prev
    // {
      buildSwiftPMProject = final.callPackage ../../nix/lib/build-swiftpm-project.nix {
        inherit (closure-lib) purifier;
      };
    };
}
