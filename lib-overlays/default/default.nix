# SPDX-License-Identifier: MIT
#
# The `swiftpm-purifier` library namespace, built on the purifier library
# of the `purifier` project:
#
# - `buildSwiftPMProject { pkgs, src, fetchers ? { }, ... }`, the builder
#   (nix/lib/build-swiftpm-project.nix);
# - `readLock { src, lockFile ? <in src> }`, the lock in memory of the
#   purifier contract: `{ purifier, entries, outputs, problems }`
#   (nix/lib/lock.nix);
# - `tree { pkgs, src, lockFile ? <in src>, fetchers ? { } }`, the locked
#   dependencies of a package laid out for SwiftPM, which
#   `swiftpm-purifier prefetch` links into the package.
{ ... }:
{

  overlay = final: prev: {
    swiftpm-purifier = {
      buildSwiftPMProject = import ../../nix/lib/build-swiftpm-project.nix { inherit (final) purifier; };

      readLock =
        {
          src,
          lockFile ? src + "/swiftpm-purifier.lock.json",
        }:
        (import ../../nix/lib/lock.nix { inherit src lockFile; }).lock;

      tree =
        {
          pkgs,
          src,
          lockFile ? src + "/swiftpm-purifier.lock.json",
          fetchers ? { },
        }:
        let
          read = import ../../nix/lib/lock.nix { inherit lockFile src; };
        in
        import ../../nix/lib/tree.nix {
          inherit read;
          entries = final.purifier.entriesFor pkgs.stdenv.hostPlatform.system read.lock;
          fetchEntry = final.purifier.fetchEntry ({ inherit pkgs; } // fetchers);
          inherit (pkgs) runCommand;
          patchArtifact = pkgs.callPackage ../../nix/lib/patch-artifact.nix { };
        };
    };
  };

}
