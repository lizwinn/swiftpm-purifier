# SPDX-License-Identifier: MIT
#
# Builds a SwiftPM package and its lockfile (written by `swiftpm-purifier
# lock`) in the Nix sandbox. The flake publishes it as
# `lib.swiftpm-purifier.buildSwiftPMProject`:
#
#   buildSwiftPMProject { inherit pkgs; src = ./.; }
#
# returns
#
# - `packages.<product>`, one per product the lock recorded from
#   `swift package dump-package`: an executable's binary under bin/, a
#   dynamic or static library's file under lib/ with its Swift modules,
#   and, for an automatic library, a plugin or a macro, which SwiftPM
#   publishes as source, the package's source archive;
# - `tests`, the build with `swift test` run in the sandbox;
# - `release`, the package's source archive, which a package registry
#   serves and `swiftpm-purifier publish` uploads;
# - `fetches`, the purifier library entries the build fetches;
# - `project`, the build with every product installed;
# - `tree`, the locked dependencies laid out for SwiftPM.
#
# Arguments: `pkgs`, the package set whose Swift toolchain builds; `src`,
# the package root; `fetchers`, given unchanged to the purifier library's
# fetchEntry (a `fetchurl` there carries credentials or a mirror);
# `lockFile`, which defaults to the lockfile in `src` and may lie outside
# it, for a project whose author does not commit one (SwiftPM's own
# Package.resolved is always read from `src`); `buildConfig`,
# `release` or `debug`; `artifactBuildInputs`, the libraries the prebuilt
# files of binary targets need beyond the C and C++ runtime and the
# libraries patch-artifact.nix offers; and any other argument of
# stdenv.mkDerivation, given to the build.
{ purifier }:
{
  pkgs,
  src,
  fetchers ? { },
  lockFile ? src + "/swiftpm-purifier.lock.json",
  buildConfig ? "release",
  artifactBuildInputs ? [ ],
  ...
}@args:
let
  inherit (pkgs) lib runCommand;
  inherit (pkgs.swiftPackages) stdenv swift swiftpm;

  read = import ./lock.nix { inherit lockFile src; };

  # checkLock of the purifier library stops the evaluation with the
  # problems lock.nix found: a stale, tampered, malformed or incomplete
  # lockfile, each with the command that fixes it.
  current = builtins.seq (purifier.checkLock read.lock) true;

  tree = import ./tree.nix {
    inherit read runCommand;
    entries = purifier.entriesFor pkgs.stdenv.hostPlatform.system read.lock;
    fetchEntry = purifier.fetchEntry ({ inherit pkgs; } // fetchers);
    patchArtifact = pkgs.callPackage ./patch-artifact.nix { buildInputs = artifactBuildInputs; };
  };

  name = read.package;

  # Links the tree into the package root and fills in the workspace state.
  linkTree = ''
    for entry in $(cd ${tree} && find . -mindepth 1 -type l -printf '%P\n'); do
      mkdir -p "$(dirname "$entry")"
      ln -sfn "$(readlink ${tree}/$entry)" "$entry"
    done
    mkdir -p .build
    substitute ${tree}/workspace-state.json.in .build/workspace-state.json --subst-var-by root "$PWD"
  '';

  extraArgs = builtins.removeAttrs args [
    "pkgs"
    "src"
    "fetchers"
    "lockFile"
    "buildConfig"
    "artifactBuildInputs"
  ];

  project =
    assert current;
    stdenv.mkDerivation (
      {
        pname = name;
        version = "locked";
        inherit src;

        nativeBuildInputs = [
          swift
          swiftpm
        ]
        ++ (extraArgs.nativeBuildInputs or [ ]);

        swiftpmBuildConfig = buildConfig;

        # SwiftPM names the root package after its directory, and the
        # workspace state the lock recorded uses the name of the package's
        # directory at the lock run.
        postUnpack = ''
          if [ "$(basename "$sourceRoot")" != ${lib.escapeShellArg read.rootDirectory} ]; then
            mkdir swiftpm-purifier-root
            mv "$sourceRoot" swiftpm-purifier-root/${lib.escapeShellArg read.rootDirectory}
            sourceRoot=swiftpm-purifier-root/${lib.escapeShellArg read.rootDirectory}
          fi
        ''
        + (extraArgs.postUnpack or "");

        # SwiftPM downloads prebuilt swift-syntax libraries for macros when
        # it can. The lock does not record them, so swift-syntax builds
        # from source, here and in the interactive mode.
        swiftpmFlags = [ "--disable-experimental-prebuilts" ] ++ (extraArgs.swiftpmFlags or [ ]);

        # Clang and SwiftPM keep caches in the home directory, which the
        # sandbox does not have.
        preConfigure = ''
          export CLANG_MODULE_CACHE_PATH=$TMPDIR/clang-module-cache
          ${linkTree}
        ''
        + (extraArgs.preConfigure or "");

        # nixpkgs' install phase installs executables and dynamic libraries;
        # static libraries are installed here.
        postInstall = ''
          products=$(swift build -c ${buildConfig} --show-bin-path)
          for library in ${lib.escapeShellArgs staticLibraries}; do
            install -D -t "$out/lib" "$products/lib$library.a"
            for module in "$products"/Modules/*.swiftmodule "$products"/*.swiftmodule; do
              [ -e "$module" ] && install -D -t "$out/lib/swift/${stdenv.hostPlatform.parsed.kernel.name}" "$module"
            done
          done
        ''
        + (extraArgs.postInstall or "");

        passthru = {
          inherit (read) lock;
          inherit tree;
        };
      }
      // builtins.removeAttrs extraArgs [
        "nativeBuildInputs"
        "postUnpack"
        "preConfigure"
        "postInstall"
        "swiftpmFlags"
      ]
    );

  staticLibraries = map (product: product.name) (
    builtins.filter (product: product.type == "library" && product.linkage == "static") read.products
  );

  release =
    assert current;
    import ./source-archive.nix { inherit (pkgs) runCommand zip; } { inherit src name; };

  packageOf =
    product:
    if product.type == "executable" then
      runCommand product.name { meta.mainProgram = product.name; } ''
        mkdir -p $out/bin
        ln -s ${project}/bin/${product.name} $out/bin/${product.name}
      ''
    else if product.type == "library" && product.linkage != "automatic" then
      runCommand product.name { } ''
        mkdir -p $out/lib
        for file in ${project}/lib/lib${product.name}.*; do
          ln -s "$file" $out/lib/
        done
        if [ -d ${project}/lib/swift ]; then
          ln -s ${project}/lib/swift $out/lib/swift
        fi
      ''
    else
      release;
in
{
  inherit (read) lock;
  inherit tree project release;

  # The products by name, from the outputs of the checked lock, so a
  # lockfile with problems stops the evaluation with them.
  packages = builtins.mapAttrs (_: packageOf) (purifier.checkLock read.lock).outputs;

  tests = project.overrideAttrs { doCheck = true; };

  fetches = (purifier.checkLock read.lock).entries;
}
