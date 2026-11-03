# SPDX-License-Identifier: MIT
#
# Builds a SwiftPM package and its lockfile (written by `swiftpm-purifier
# lock`) in the Nix sandbox.
#
# The file is a package for callPackage: the first argument set is what it
# takes from the package set by name, and the result is the builder. The
# overlay of this flake (`overlays.default`) adds it to the package set as
# `buildSwiftPMProject`, so a package written for callPackage takes it like
# any other builder:
#
#   { buildSwiftPMProject }: (buildSwiftPMProject { src = ./.; }).packages.hello
#
# and `buildSwiftPMProject.override` replaces any package it takes. The
# builder returns
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
# Arguments: `src`, the package root; `fetchers`, given unchanged to
# `fetchEntry` of the purifier library (a `fetchurl` there carries
# credentials or a mirror);
# `lockFile`, which defaults to the lockfile in `src` and may lie outside
# it, for a project whose author does not commit one; `packageResolved`,
# SwiftPM's own lockfile, which defaults to the copy in `src` and may be a
# copy kept outside the repository, which the build then uses in place of
# the one in `src`; `buildConfig`,
# `release` or `debug`; `artifactBuildInputs`, the libraries the prebuilt
# files of binary targets need beyond the C and C++ runtime and the
# libraries patch-artifact.nix offers; and any other argument of
# stdenv.mkDerivation, given to the build.
{
  lib,
  runCommand,
  zip,
  unzip,
  zstd,
  python3,
  writeText,
  fetchurl,
  fetchgit,
  callPackage,
  # The Swift toolchain: its stdenv builds, and its swift and swiftpm are
  # the tools of the build.
  swiftPackages,
  # The purifier library, whose fetchEntry, checkLock and entriesFor the
  # builder uses.
  purifier,
}:
{
  src,
  fetchers ? { },
  lockFile ? src + "/swiftpm-purifier.lock.json",
  # SwiftPM's lockfile, which a flake can keep outside `src`.
  packageResolved ? src + "/Package.resolved",
  buildConfig ? "release",
  artifactBuildInputs ? [ ],
  ...
}@args:
let
  inherit (swiftPackages) stdenv swift swiftpm;

  read = import ./lock.nix { inherit lockFile src packageResolved; };

  # checkLock of the purifier library stops the evaluation with the
  # problems lock.nix found: a stale, tampered, malformed or incomplete
  # lockfile, each with the command that fixes it.
  current = builtins.seq (purifier.checkLock read.lock) true;

  tree = import ./tree.nix {
    inherit read runCommand;
    entries = purifier.entriesFor stdenv.hostPlatform.system read.lock;
    # fetchEntry takes by name the fetchers of the two kinds of entry that
    # swiftpm-purifier writes, and the tools that unpack an archive.
    fetchEntry = purifier.fetchEntry (
      {
        inherit
          runCommand
          unzip
          zstd
          python3
          writeText
          fetchurl
          fetchgit
          ;
      }
      // fetchers
    );
    patchArtifact = callPackage ./patch-artifact.nix { buildInputs = artifactBuildInputs; };
  };

  name = read.package;

  # Links the tree into the package root and fills in the workspace state.
  linkTree = ''
    ${lib.optionalString (builtins.pathExists packageResolved) ''
      cp --no-preserve=mode ${packageResolved} Package.resolved
    ''}
    for entry in $(cd ${tree} && find . -mindepth 1 -type l -printf '%P\n'); do
      mkdir -p "$(dirname "$entry")"
      ln -sfn "$(readlink ${tree}/$entry)" "$entry"
    done
    mkdir -p .build
    substitute ${tree}/workspace-state.json.in .build/workspace-state.json --subst-var-by root "$PWD"
  '';

  extraArgs = builtins.removeAttrs args [
    "src"
    "fetchers"
    "lockFile"
    "packageResolved"
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
        # The macOS linker writes a debug map into each binary, which names
        # the object and source files under the build directory, and the
        # binary's UUID depends on the map. On macOS the build directory's
        # name differs from build to build, in length too, and the strip
        # removes the map but keeps the UUID. Linked without the map, which
        # names files the build deletes, every build gets the same UUID.
        # The flag goes to clang as -Wl,-S: nixpkgs' clang wrapper takes a
        # bare -S, as from -Xlinker -S, for a build without a link, and the
        # binary then loses its /usr/lib/swift rpath.
        + lib.optionalString stdenv.hostPlatform.isDarwin ''
          appendToVar swiftpmFlags -Xswiftc -Xclang-linker -Xswiftc -Wl,-S
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
    import ./source-archive.nix { inherit runCommand zip; } { inherit src name; };

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
