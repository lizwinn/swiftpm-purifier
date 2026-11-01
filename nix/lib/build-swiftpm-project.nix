# SPDX-License-Identifier: MIT
#
# Builds a SwiftPM package and its lockfile (written by `swiftpm-purifier
# lock`) in the Nix sandbox.
#
#   buildSwiftPMProject { src = ./.; }
#
# returns
#
# - `packages.<product>`, one per product the lock recorded from
#   `swift package dump-package`: an executable's binary under bin/, a
#   dynamic or static library's file under lib/ with its Swift modules,
#   and, for an automatic library, a plugin or a macro, which SwiftPM
#   publishes as source, the package's source archive;
# - `project`, the build with every product installed;
# - `sourceArchive`, the package's source as `swift package archive-source`
#   makes it, which a package registry serves;
# - `release <version>`, an archive per executable with SHA256SUMS;
# - `tree`, the locked dependencies laid out for SwiftPM.
#
# Arguments: `src`, the package root; `lockFile`, which defaults to the
# lockfile in `src`; `doCheck`, which runs `swift test`; `buildConfig`,
# `release` or `debug`; `fetchurl` and `fetchgit`, which replace the
# package set's fetchers, for credentials or mirrors; `artifactBuildInputs`,
# the libraries the prebuilt files of binary targets need beyond the C and
# C++ runtime; and any other argument of stdenv.mkDerivation, given to the
# build.
{
  lib,
  stdenv,
  swift,
  swiftpm,
  fetchurl,
  fetchgit,
  runCommand,
  unzip,
  zip,
  gnutar,
  gzip,
  callPackage,
}@pkgs:
{
  src,
  lockFile ? src + "/swiftpm-purifier.lock.json",
  doCheck ? false,
  buildConfig ? "release",
  fetchurl ? pkgs.fetchurl,
  fetchgit ? pkgs.fetchgit,
  artifactBuildInputs ? [ ],
  ...
}@args:
let
  lock = import ./lock.nix { inherit lockFile; };

  tree = import ./tree.nix {
    inherit
      lock
      fetchurl
      fetchgit
      runCommand
      unzip
      ;
    patchArtifact = callPackage ./patch-artifact.nix { buildInputs = artifactBuildInputs; };
  };

  # The lock is current when `Package.resolved` and the manifests hash to
  # what the lock run saw. The hashes are computed the way swiftpm-purifier
  # computes them.
  sha256 =
    file:
    builtins.convertHash {
      hash = builtins.hashFile "sha256" file;
      hashAlgo = "sha256";
      toHashFormat = "sri";
    };
  manifests = lib.sort (a: b: a < b) (
    builtins.filter (name: builtins.match "Package(@swift-[0-9.]+)?\\.swift" name != null) (
      builtins.attrNames (builtins.readDir src)
    )
  );
  manifestHash = builtins.hashString "sha256" (
    builtins.toJSON (
      map (name: [
        name
        (builtins.hashFile "sha256" (src + "/${name}"))
      ]) manifests
    )
  );
  resolvedHash =
    if builtins.pathExists (src + "/Package.resolved") then
      sha256 (src + "/Package.resolved")
    else
      null;
  current =
    (lock.resolvedHash == resolvedHash && lock.manifestHash == manifestHash)
    || throw "swiftpm-purifier: ${toString lockFile} is out of date with Package.swift or Package.resolved in ${toString src}. Run `swiftpm-purifier lock`.";

  name = lock.package;

  # Links the tree into the package root and fills in the workspace state.
  linkTree = ''
    for entry in $(cd ${tree} && find . -mindepth 1 \( -type l -o -name workspace-state.json.in \) -printf '%P\n'); do
      if [ "$entry" = workspace-state.json.in ]; then continue; fi
      mkdir -p "$(dirname "$entry")"
      ln -sfn "$(readlink ${tree}/$entry)" "$entry"
    done
    mkdir -p .build
    substitute ${tree}/workspace-state.json.in .build/workspace-state.json --subst-var-by root "$PWD"
  '';

  extraArgs = builtins.removeAttrs args [
    "src"
    "lockFile"
    "doCheck"
    "buildConfig"
    "fetchurl"
    "fetchgit"
    "artifactBuildInputs"
  ];

  project =
    assert current;
    stdenv.mkDerivation (
      {
        pname = name;
        version = "locked";
        inherit src doCheck;

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
          if [ "$(basename "$sourceRoot")" != ${lib.escapeShellArg lock.rootDirectory} ]; then
            mkdir swiftpm-purifier-root
            mv "$sourceRoot" swiftpm-purifier-root/${lib.escapeShellArg lock.rootDirectory}
            sourceRoot=swiftpm-purifier-root/${lib.escapeShellArg lock.rootDirectory}
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
          inherit lock tree;
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

  productsOf = type: builtins.filter (product: product.type == type) lock.products;
  names = products: map (product: product.name) products;
  staticLibraries = names (
    builtins.filter (product: product.type == "library" && product.linkage == "static") lock.products
  );

  sourceArchive =
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
      sourceArchive;

  packages = builtins.listToAttrs (
    map (product: {
      inherit (product) name;
      value = packageOf product;
    }) lock.products
  );

  release =
    version:
    runCommand "${name}-release-${version}"
      {
        nativeBuildInputs = [
          gnutar
          gzip
        ];
      }
      ''
        mkdir -p $out
        ${lib.concatMapStrings (executable: ''
          tar -C ${project}/bin -czhf "$out/${executable}_${version}_${stdenv.hostPlatform.system}.tar.gz" \
            --owner=0 --group=0 --mtime=@1 ${executable}
        '') (names (productsOf "executable"))}
        cd $out
        sha256sum *.tar.gz > SHA256SUMS
      '';
in
{
  inherit
    lock
    tree
    project
    packages
    sourceArchive
    release
    ;
}
