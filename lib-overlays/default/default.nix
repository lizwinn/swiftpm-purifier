# SPDX-License-Identifier: MIT
#
# The `swiftpm-purifier` library namespace, built on the purifier library
# of the `purifier` project:
#
# - `buildSwiftPMProject { pkgs, src, fetchers ? { }, ... }`, the builder
#   (nix/lib/build-swiftpm-project.nix);
# - `tree { pkgs, lockFile, fetchers ? { } }`, the locked dependencies of a
#   lockfile laid out for SwiftPM, which `swiftpm-purifier prefetch` links
#   into a package.
{ ... }:
{

  overlay = final: prev: {
    swiftpm-purifier = {
      buildSwiftPMProject = import ../../nix/lib/build-swiftpm-project.nix { inherit (final) purifier; };

      tree =
        {
          pkgs,
          lockFile,
          fetchers ? { },
        }:
        import ../../nix/lib/tree.nix {
          lock = import ../../nix/lib/lock.nix { inherit lockFile; };
          fetchEntry = final.purifier.fetchEntry ({ inherit pkgs; } // fetchers);
          inherit (pkgs) runCommand;
          patchArtifact = pkgs.callPackage ../../nix/lib/patch-artifact.nix { };
        };
    };
  };

}
