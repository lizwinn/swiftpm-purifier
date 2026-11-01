# SPDX-License-Identifier: MIT
#
# The flake's checks: builds of the fixtures from their lockfiles, each
# run, the release archives, and the behaviour of the Nix library on its
# own. tests/cli.sh covers the lock run and the interactive mode, which
# need the network or run Nix, and so cannot run in the sandbox.
{ pkgs, overlay }:
let
  pkgs' = pkgs.extend overlay;
  inherit (pkgs') lib runCommand buildSwiftPMProject;

  # An executable and a library, with two dependencies from git and a
  # test target.
  hello = buildSwiftPMProject {
    src = ./fixtures/hello;
    doCheck = true;
  };

  # A package with a dependency by path inside its source, which has a
  # dependency from git of its own.
  paths = buildSwiftPMProject { src = ./fixtures/paths; };

  # A macro, which builds against swift-syntax.
  macro = buildSwiftPMProject { src = ./fixtures/macro; };

  # A binary target from an artifact bundle, whose Linux executable a
  # prebuild command runs before each build.
  binary = buildSwiftPMProject { src = ./fixtures/binary; };

  # Runs a command and compares what it prints.
  prints =
    name: command: expected:
    runCommand name { inherit expected; } ''
      ${command} > actual
      printf '%s\n' "$expected" > expected-file
      if ! diff -u expected-file actual; then
        exit 1
      fi
      touch $out
    '';

  lockWithVersion =
    version:
    builtins.toFile "swiftpm-purifier.lock.json" (
      builtins.toJSON {
        inherit version;
        package = "p";
        rootDirectory = "p";
        swiftVersion = "6.3.3";
        resolvedHash = null;
        manifestHash = "";
        products = [ ];
        workspaceState.object = {
          dependencies = [ ];
          artifacts = [ ];
        };
        artifacts = [ ];
      }
    );

  # The hello fixture with its lockfile changed by `change`.
  helloWithLock =
    change:
    buildSwiftPMProject {
      src = ./fixtures/hello;
      lockFile = builtins.toFile "swiftpm-purifier.lock.json" (
        builtins.toJSON (
          change (builtins.fromJSON (builtins.readFile ./fixtures/hello/swiftpm-purifier.lock.json))
        )
      );
    };
  refuses = project: !(builtins.tryEval project.project.drvPath).success;
  readsVersion =
    version:
    (builtins.tryEval (import ../nix/lib/lock.nix { lockFile = lockWithVersion version; }).package)
    .success;
in
{
  fixture-hello =
    prints "fixture-hello" "${lib.getExe hello.packages.hello} Nix Swift Nix"
      "Hello, Nix!\nHello, Swift!";

  fixture-paths = prints "fixture-paths" (lib.getExe paths.packages.paths) "NIX SWIFT";

  fixture-macro = prints "fixture-macro" (lib.getExe macro.packages.macro) "6 * 7 = 42";

  fixture-binary =
    prints "fixture-binary" (lib.getExe binary.packages.binary)
      "built with a prebuild command from a binary target";

  # The patched executable of the artifact bundle runs.
  fixture-binary-artifact =
    prints "fixture-binary-artifact"
      "${binary.tree}/.build/artifacts/binary/SwiftLintBinary/SwiftLintBinary.artifactbundle/linux/${
        if pkgs'.stdenv.hostPlatform.isAarch64 then "arm64" else "amd64"
      }/swiftlint version"
      "0.65.1";

  # The source archive of the package, which is the package of its
  # automatic library product, holds the manifest and no build state.
  fixture-hello-source = runCommand "fixture-hello-source" { nativeBuildInputs = [ pkgs'.unzip ]; } ''
    test ${hello.packages.Greeting} = ${hello.sourceArchive}
    unzip -l ${hello.sourceArchive} | grep -q ' hello/Package.swift$'
    if unzip -l ${hello.sourceArchive} | grep -qE ' hello/(\.build|Packages)/'; then exit 1; fi
    touch $out
  '';

  # The release archive of the hello fixture, with sums that verify.
  fixture-hello-release =
    let
      release = hello.release "1.0.0";
    in
    runCommand "fixture-hello-release" { } ''
      cd ${release}
      sha256sum -c SHA256SUMS
      tar -tzf hello_1.0.0_${pkgs'.stdenv.hostPlatform.system}.tar.gz | grep -qx hello
      touch $out
    '';

  # A lockfile older than Package.resolved stops the build at evaluation.
  stale-lock =
    let
      stale = runCommand "stale" { } ''
        cp -r ${./fixtures/hello} $out
        chmod -R u+w $out
        echo >> $out/Package.resolved
      '';
    in
    assert !(builtins.tryEval (buildSwiftPMProject { src = stale; }).project.drvPath).success;
    runCommand "stale-lock" { } "touch $out";

  # A lockfile without the entry of a dependency its workspace state names
  # stops the build at evaluation.
  missing-entry =
    assert refuses (helloWithLock (lock: lock // { artifacts = builtins.tail lock.artifacts; }));
    runCommand "missing-entry" { } "touch $out";

  # A lockfile without one of its fields stops the build at evaluation.
  missing-field =
    assert refuses (helloWithLock (lock: builtins.removeAttrs lock [ "workspaceState" ]));
    runCommand "missing-field" { } "touch $out";

  # The swiftpm-purifier command, with its unit tests run in the build,
  # and the toolchain around it.
  inherit (pkgs'.swiftpm-purifier) cli toolchain;

  # lock.nix reads the version it supports and rejects any other.
  lock-version =
    assert readsVersion (import ../nix/lib/lock-version.nix);
    assert !(readsVersion 0);
    runCommand "lock-version" { } "touch $out";
}
