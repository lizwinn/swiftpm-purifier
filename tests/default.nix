# SPDX-License-Identifier: MIT
#
# The flake's checks: builds of the fixtures and of a pinned real-world
# project from their lockfiles, each run; the contract checks
# (`conformance-*`) that can run in the sandbox; and the command with its
# unit tests. The CI jobs conformance-relock, conformance-rebuild and
# conformance-offline run the contract checks that need the network or
# Nix itself (tests/cli.sh and .github/workflows/check.yml).
{
  pkgs,
  overlay,
  library,
}:
let
  pkgs' = pkgs.extend overlay;
  inherit (pkgs') lib runCommand;
  build = args: library.buildSwiftPMProject ({ pkgs = pkgs'; } // args);

  # An executable and a library, with two dependencies from git and a
  # test target.
  hello = build { src = ./fixtures/hello; };

  # A package with a dependency by path inside its source, which has a
  # dependency from git of its own.
  paths = build { src = ./fixtures/paths; };

  # A macro, which builds against swift-syntax.
  macro = build { src = ./fixtures/macro; };

  # A binary target from an artifact bundle, whose Linux executable a
  # prebuild command runs before each build.
  binary = build { src = ./fixtures/binary; };

  # swift-format, a real-world project, at its swift-6.3.3-RELEASE tag. Its
  # repository commits neither Package.resolved nor a purifier lockfile, so
  # the lockfile lies outside its source and carries Package.resolved. The
  # source is fetched at evaluation, so its manifests can be read without
  # import-from-derivation.
  swiftFormat = build {
    src = builtins.fetchTree {
      type = "github";
      owner = "swiftlang";
      repo = "swift-format";
      rev = "9f3ddd22382a36a5e50c4af9294f03ebfe5017fd";
      narHash = "sha256-YkOsFWaQJU786L9OB/n9jOL5G303cz0q62dw3yFWkA0=";
    };
    lockFile = ./projects/swift-format/swiftpm-purifier.lock.json;
  };

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

  # A lockfile with its contentHash computed as the lock run computes it.
  rehash =
    lock:
    lock
    // {
      contentHash = builtins.convertHash {
        hash = builtins.hashString "sha256" (builtins.toJSON (builtins.removeAttrs lock [ "contentHash" ]));
        hashAlgo = "sha256";
        toHashFormat = "sri";
      };
    };
  helloLock = builtins.fromJSON (builtins.readFile ./fixtures/hello/swiftpm-purifier.lock.json);
  lockFileOf = lock: builtins.toFile "swiftpm-purifier.lock.json" (builtins.toJSON lock);
  # The hello fixture built with `lock` as its lockfile.
  helloWith =
    lock:
    build {
      src = ./fixtures/hello;
      lockFile = lockFileOf lock;
    };
  refuses = project: !(builtins.tryEval project.project.drvPath).success;

  lockWithVersion =
    version:
    lockFileOf (rehash {
      inherit version;
      package = "p";
      rootDirectory = "p";
      swiftVersion = "6.3.3";
      resolvedHash = null;
      resolved = null;
      manifestHash = "";
      products = [ ];
      workspaceState.object = {
        dependencies = [ ];
        artifacts = [ ];
      };
      artifacts = [ ];
      contentHash = "";
    });
  readsVersion =
    version:
    (builtins.tryEval (import ../nix/lib/lock.nix { lockFile = lockWithVersion version; }).package)
    .success;

  # The hello fixture without its lockfile and Package.resolved, which
  # conformance-external gives from outside it.
  helloSourceOnly = builtins.path {
    path = ./fixtures/hello;
    name = "hello";
    filter =
      path: type:
      !(builtins.elem (baseNameOf path) [
        "swiftpm-purifier.lock.json"
        "Package.resolved"
      ]);
  };
in
{
  fixture-hello =
    prints "fixture-hello" "${lib.getExe hello.packages.hello} Nix Swift Nix"
      "Hello, Nix!\nHello, Swift!";

  # The test target of the hello fixture, run in the sandbox.
  fixture-hello-tests = hello.tests;

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

  project-swift-format =
    prints "project-swift-format"
      "printf 'let x=1\\n' | ${lib.getExe swiftFormat.packages.swift-format}"
      "let x = 1";

  # The release of the hello fixture is its source archive, which is also
  # the package of its automatic library product: the manifest under one
  # top-level directory, and no build state.
  fixture-hello-release =
    runCommand "fixture-hello-release" { nativeBuildInputs = [ pkgs'.unzip ]; }
      ''
        test ${hello.packages.Greeting} = ${hello.release}
        unzip -l ${hello.release} | grep -q ' hello/Package.swift$'
        if unzip -l ${hello.release} | grep -qE ' hello/(\.build|Packages)/'; then exit 1; fi
        touch $out
      '';

  # `fetches` lists the entries the build fetches.
  fixture-hello-fetches =
    assert
      map (entry: entry.path) hello.fetches == [
        "Packages/swift-argument-parser"
        "Packages/swift-collections"
      ];
    runCommand "fixture-hello-fetches" { } "touch $out";

  # A lockfile older than the project stops the build at evaluation.
  conformance-stale =
    assert refuses (helloWith (rehash (helloLock // { manifestHash = "0"; })));
    runCommand "conformance-stale" { } "touch $out";

  # A lockfile whose hash of an entry was changed stops the build at
  # evaluation, because it no longer matches its contentHash.
  conformance-tampered =
    let
      first = builtins.head helloLock.artifacts;
    in
    assert refuses (
      helloWith (
        helloLock
        // {
          artifacts = [
            (first // { hash = "sha256-" + lib.strings.replicate 43 "A" + "="; })
          ]
          ++ builtins.tail helloLock.artifacts;
        }
      )
    );
    runCommand "conformance-tampered" { } "touch $out";

  # A lockfile without the entry of a dependency its workspace state names
  # stops the build at evaluation.
  conformance-missing =
    assert refuses (
      helloWith (rehash (helloLock // { artifacts = builtins.tail helloLock.artifacts; }))
    );
    runCommand "conformance-missing" { } "touch $out";

  # A lockfile without one of its fields stops the build at evaluation.
  conformance-malformed =
    assert refuses (helloWith (rehash (builtins.removeAttrs helloLock [ "workspaceState" ])));
    runCommand "conformance-malformed" { } "touch $out";

  # A source that holds neither the purifier lockfile nor Package.resolved
  # builds from both kept outside it.
  conformance-external =
    let
      external = build {
        src = helloSourceOnly;
        lockFile = ./fixtures/hello/swiftpm-purifier.lock.json;
        "Package.resolved" = ./fixtures/hello/Package.resolved;
      };
    in
    prints "conformance-external" "${lib.getExe external.packages.hello} Nix" "Hello, Nix!";

  # The swiftpm-purifier command, with its unit tests run in the build,
  # and the toolchain around it.
  inherit (pkgs'.swiftpm-purifier) cli toolchain;

  # lock.nix reads the version it supports and rejects any other.
  lock-version =
    assert readsVersion (import ../nix/lib/lock-version.nix);
    assert !(readsVersion 0);
    runCommand "lock-version" { } "touch $out";
}
