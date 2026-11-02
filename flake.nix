# SPDX-License-Identifier: MIT
{

  description = "swiftpm-purifier: Nix as the dependency backend of SwiftPM packages";

  inputs = {
    caisson.url = "github:nix-caisson/caisson";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # The library comes from the nixpkgs.lib mirror. The package sets
    # take nixpkgs.
    nixpkgs-lib.url = "github:nix-community/nixpkgs.lib";
    flake-parts.url = "github:hercules-ci/flake-parts";
    # The shared library of the nix-purifiers, which fetches the locked
    # entries.
    purifier.url = "github:nix-purifiers/purifier";
  };

  outputs =
    inputs@{ caisson, purifier, ... }:
    let
      lib = caisson.lib.caisson.mkLib {
        inherit (caisson.lib.caisson.pins.flake inputs) sources root;
        name = "swiftpm-purifier";
        # nixpkgs marks its Swift 6.3 compiler broken on aarch64-linux,
        # where it fails to link with the gold linker; nixpkgs expects the
        # Swift 6.4 update, which links with LLD, to fix it. aarch64-linux
        # joins the list when nixpkgs' Swift builds there.
        systems = [ "x86_64-linux" ];
        projects = {
          inherit caisson purifier;
        };

        configs = lib: lib.caisson.mkModules ./configs;

        pkgSets = lib: lib.caisson.nixpkgs.mkConfigurations { };

        libOverlays = lib: lib.caisson.mkLibOverlays ./lib-overlays;
        pkgOverlays = lib: lib.caisson.mkPkgOverlays ./pkg-overlays;
      };
    in
    lib.caisson.flake-parts.mkTopConfiguration { };

}
