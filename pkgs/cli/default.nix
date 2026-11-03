# SPDX-License-Identifier: MIT
#
# The swiftpm-purifier command, a Python script with the tools it runs
# (swift, nix-prefetch-git and nix) named by environment variables. Its
# unit tests run in the build.
{
  lib,
  stdenvNoCC,
  makeWrapper,
  python3,
  swiftPackages,
  nix,
  nix-prefetch-git,
  git,
  unzip,
}:
let
  # The environment nixpkgs' setup hooks give a build with the Swift
  # toolchain: the compiler and linker flags its wrappers read, and PATH.
  # SwiftPM compiles and links manifests with that toolchain, so the
  # command runs it in this environment, as `nix develop` would.
  swiftEnvironment = swiftPackages.stdenv.mkDerivation {
    name = "swiftpm-purifier-swift-environment";
    nativeBuildInputs = [
      swiftPackages.swift
      swiftPackages.swiftpm
      git
      # SwiftPM unpacks binary-target archives with unzip.
      unzip
    ];
    buildInputs = [
      swiftPackages.swift
      swiftPackages.swiftpm
    ];
    dontUnpack = true;
    dontBuild = true;
    installPhase = ''
      for name in $(printf '%s\n' "''${!NIX_@}" | grep -vE '^NIX_(BUILD_[A-Z_]+|LOG_FD|STORE|ATTRS_[A-Z_]+|SSL_CERT_FILE|ENFORCE_PURITY|PATH)$'); do
        value=''${!name}
        # The rpath to this derivation's own lib/ does not belong in the
        # command's builds.
        value=''${value//-rpath $out\/lib/}
        printf 'export %s=%q\n' "$name" "$value"
      done > $out
      printf 'export PATH=%q"''${PATH:+:$PATH}"\n' "$PATH" >> $out
    ''
    # On macOS the SDK's setup hook names the SDK in DEVELOPER_DIR and
    # SDKROOT, where SwiftPM and xcrun look for it.
    + lib.optionalString swiftPackages.stdenv.hostPlatform.isDarwin ''
      for name in "''${!DEVELOPER_DIR@}" "''${!SDKROOT@}"; do
        printf 'export %s=%q\n' "$name" "''${!name}"
      done >> $out
    '';
  };
in
stdenvNoCC.mkDerivation {
  pname = "swiftpm-purifier";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ./swiftpm_purifier.py
      ./test_swiftpm_purifier.py
    ];
  };

  nativeBuildInputs = [ makeWrapper ];
  nativeCheckInputs = [ python3 ];

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    (cd pkgs/cli && python3 -m unittest -v test_swiftpm_purifier)
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/libexec/swiftpm-purifier
    cp pkgs/cli/swiftpm_purifier.py $out/libexec/swiftpm-purifier/
    # SWIFTPM_PURIFIER_FLAKE is this flake's source, whose package set the
    # interactive mode and `publish` build with, so they use the builder
    # and the purifier library a Nix build uses.
    makeWrapper ${lib.getExe python3} $out/bin/swiftpm-purifier \
      --add-flags $out/libexec/swiftpm-purifier/swiftpm_purifier.py \
      --set SWIFTPM_PURIFIER_FLAKE ${../..} \
      --set SWIFTPM_PURIFIER_SWIFT ${swiftPackages.swift}/bin/swift \
      --set SWIFTPM_PURIFIER_NIX_PREFETCH_GIT ${lib.getExe nix-prefetch-git} \
      --set SWIFTPM_PURIFIER_NIX ${lib.getExe nix} \
      --run 'source ${swiftEnvironment}'
    runHook postInstall
  '';

  meta = {
    description = "Nix as the dependency backend of SwiftPM packages";
    mainProgram = "swiftpm-purifier";
    license = lib.licenses.mit;
  };
}
