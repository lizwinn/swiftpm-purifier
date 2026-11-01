# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.swiftpm-purifier`: `.cli`, the swiftpm-purifier command, and
# `.toolchain`, the Swift toolchain whose `swift` runs through it. The
# builder is in the library, as `lib.swiftpm-purifier.buildSwiftPMProject`.
# A consumer that lists this flake in `projects` holds the overlay as
# `swiftpm-purifier/default`, which its package sets apply by default.
{ closure-lib, ... }:
{
  overlay = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "swiftpm-purifier";
}
