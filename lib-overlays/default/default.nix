# SPDX-License-Identifier: MIT
#
# The `swiftpm-purifier` library namespace. It holds `readLock { src,
# lockFile ? <in src>, packageResolved ? <in src> }`, the lock in memory of
# the purifier contract:
# `{ purifier, entries, outputs, problems }` (nix/lib/lock.nix). The
# builder needs a package set, so it is the package `buildSwiftPMProject`
# that the default package overlay adds.
{ ... }:
{

  overlay = final: prev: {
    swiftpm-purifier = (prev.swiftpm-purifier or { }) // {
      readLock =
        {
          src,
          lockFile ? src + "/swiftpm-purifier.lock.json",
          packageResolved ? src + "/Package.resolved",
        }:
        (import ../../nix/lib/lock.nix { inherit src lockFile packageResolved; }).lock;
    };
  };

}
