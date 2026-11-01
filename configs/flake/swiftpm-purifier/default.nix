# SPDX-License-Identifier: MIT
{ closure-lib, ... }:
{
  config,
  inputs,
  lib,
  ...
}:
{

  imports = [
    inputs.flake-parts.flakeModules.partitions
    closure-lib.caisson.modules.flake."purifier/purifier-packages"
  ];

  debug = false;

  # The flake's `packages` are the derivations of the scope
  # `pkgs.swiftpm-purifier`: the `cli` and the `toolchain`. The builder is a
  # function, so it stays out.
  purifier.scope = "swiftpm-purifier";

  caisson.libOverlays.exported = libOverlays: {
    inherit (libOverlays) default;
  };

  # `nix run github:nix-purifiers/swiftpm-purifier -- lock` locks the
  # SwiftPM package in the current directory.
  #
  # `nix develop github:nix-purifiers/swiftpm-purifier` gives a shell whose
  # `swift` runs against the package's locked dependencies.
  perSystem =
    { pkgs, ... }:
    {
      packages.default = pkgs.swiftpm-purifier.cli;
      devShells.default = pkgs.mkShell {
        packages = [ pkgs.swiftpm-purifier.toolchain ];
      };
    };

  partitionedAttrs.checks = "checks";
  partitionedAttrs.formatter = "formatter";

  partitions.formatter = {
    extraInputs = (lib.caisson.pins.flake-compat ../../../tests/dependencies).sources;
    module =
      { inputs, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem.treefmt.programs.nixfmt.enable = true;
        perSystem.treefmt.programs.ruff-format.enable = true;
      };
  };

  partitions.checks = {
    extraInputs = (lib.caisson.pins.flake-compat ../../../tests/dependencies).sources;
    module =
      { inputs, self, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem =
          { pkgs, ... }:
          {
            checks = import ../../../tests {
              inherit pkgs;
              overlay = self.overlays.default;
              library = self.lib.swiftpm-purifier;
            };
            treefmt.programs.nixfmt.enable = true;
            treefmt.programs.ruff-format.enable = true;
          };
      };
  };

}
