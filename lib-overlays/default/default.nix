# SPDX-License-Identifier: MIT
#
# The `swiftpm-purifier` library namespace. It holds nothing: the builder
# needs a package set, so it is the package `buildSwiftPMProject` that the
# default package overlay adds.
{ ... }:
{

  overlay = final: prev: {
    swiftpm-purifier = prev.swiftpm-purifier or { };
  };

}
