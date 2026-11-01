# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds one attribute to the package set:
# the scope `pkgs.swiftpm-purifier`. The scope holds the packages of pkgs/
# (`.cli`, the swiftpm-purifier command, and `.toolchain`, the Swift
# toolchain whose `swift` runs through it) and the builder
# `.buildSwiftPMProject` (nix/lib/build-swiftpm-project.nix), a package for
# callPackage in that scope. `pkgs.swiftpm-purifier.overrideScope` replaces
# what everything in the scope shares, and `.buildSwiftPMProject.override`
# replaces what the builder takes. A consumer that lists this flake in
# `projects` holds the overlay as `swiftpm-purifier/default`, which its
# package sets apply by default.
{ closure-lib, ... }:
let
  packages = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "swiftpm-purifier";
in
{
  overlay =
    final: prev:
    let
      added = packages final prev;
    in
    added
    // {
      swiftpm-purifier = added.swiftpm-purifier.overrideScope (
        self: super: {
          buildSwiftPMProject = self.callPackage ../../nix/lib/build-swiftpm-project.nix {
            inherit (closure-lib) purifier;
          };
        }
      );
    };
}
