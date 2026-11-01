# swiftpm-purifier

A command and a Nix library that make Nix the dependency backend of a
[SwiftPM](https://www.swift.org/documentation/package-manager/) package.
SwiftPM still resolves and plans the build. `swiftpm-purifier lock` records
every dependency SwiftPM fetched in `swiftpm-purifier.lock.json`, with its
content hash. Nix then builds the package in its sandbox from that lockfile,
with no generated Nix files to commit, and `swift` runs offline on the same
locked dependencies during development.

## How it works

`swiftpm-purifier lock` copies the package to a temporary directory and runs
`swift package resolve` there with an empty SwiftPM cache. SwiftPM records
what it fetched in `.build/workspace-state.json`, and the lock run turns
each record into an entry the Nix library can fetch:

| What SwiftPM fetched | Lockfile entry |
|---|---|
| A package from git (`.package(url:)`), from its mirror when one is configured | a git checkout at `Packages/<name>`, with submodules, by its `nix-prefetch-git` hash |
| A package from a registry (`.package(id:)`) | the registry's source archive, unpacked at `Packages/<scope>/<name>/<version>` |
| A remote binary target (`.binaryTarget(url:checksum:)`) | the archive at `.build/artifacts/...`, by the checksum in the manifest |

A dependency by path (`.package(path:)`) and a local binary target
(`.binaryTarget(path:)`) are part of the package source, and the lockfile
records only where they are.

The lockfile also holds SwiftPM's workspace state, with each fetched
dependency marked as edited, and every product of the package from
`swift package dump-package`. A build links the entries into the package
and writes that workspace state, and SwiftPM then builds without fetching
anything. Binary targets ship prebuilt files for other systems, so the
build patches their ELF executables and libraries with `autoPatchelfHook`
to run under Nix.

`swiftpm-purifier lock` relocks only when `Package.swift` or
`Package.resolved` changed since the lockfile was made; `relock` relocks
regardless. When the package has no `Package.resolved`, the lock run
writes the one SwiftPM made.

## Use

Lock the package in the current directory, and commit the lockfile with
`Package.resolved`:

```zsh
nix run github:nix-purifiers/swiftpm-purifier -- lock
```

The flake's `overlays.default` adds `buildSwiftPMProject` to a package
set, so a package written for `callPackage` takes it by name:

```nix
# package.nix
{ buildSwiftPMProject }:
(buildSwiftPMProject { src = ./.; }).packages.hello
```

```nix
{
  inputs.swiftpm-purifier.url = "github:nix-purifiers/swiftpm-purifier";
  inputs.nixpkgs.follows = "swiftpm-purifier/nixpkgs";

  outputs = { nixpkgs, swiftpm-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [
          swiftpm-purifier.overlays.default
          (final: prev: { hello = final.callPackage ./package.nix { }; })
        ];
      };
    in
    {
      packages.${system}.hello = pkgs.hello;
    };
}
```

`buildSwiftPMProject { src; }` returns:

- `packages.<product>`, one per product of the package. An executable is
  its binary under `bin/`. A dynamic or static library is its library file
  under `lib/` with its Swift modules. SwiftPM publishes an automatic
  library, a plugin and a macro as source, so their package is the
  package's source archive.
- `project`, the build with every product installed.
- `sourceArchive`, the package's source as a registry serves it.
- `release <version>`, a `.tar.gz` per executable with `SHA256SUMS`.
- `tree`, the locked dependencies laid out for SwiftPM.

Its arguments are `src`; `lockFile`, which defaults to the lockfile in
`src`; `doCheck`, which runs `swift test`; `buildConfig`, `release` (the
default) or `debug`; `fetchurl` and `fetchgit`, which replace the package
set's fetchers, for credentials or mirrors; `artifactBuildInputs`, libraries
the prebuilt files of binary targets need beyond the C and C++ runtime,
curl, libxml2, zlib, OpenSSL, SQLite and ICU; and any argument of
`stdenv.mkDerivation`. A lockfile older than `Package.swift` or
`Package.resolved` stops the evaluation with a message to relock.

### Interactive mode

`nix develop github:nix-purifiers/swiftpm-purifier` gives a shell whose
`swift` runs through `swiftpm-purifier swift`. In a package with an
up-to-date lockfile, it realizes the locked dependencies through Nix,
links them into `Packages/` and `.build/artifacts/`, and writes the
workspace state that marks them as edited, so `swift build`, `swift test`
and `swift run` work offline. A GC root under `.build/swiftpm-purifier`
keeps the dependencies alive. When the lockfile is out of date, it warns,
removes its links, and leaves SwiftPM to resolve the usual way until
`swiftpm-purifier lock` renews it. `swiftpm-purifier uninstall` removes the
links. SwiftPM's default `.gitignore` already ignores `/Packages`.

### Publishing

A package registry serves a release as its source archive.
`swiftpm-purifier publish <scope.name> <version>` builds that archive
through Nix and uploads it (SE-0391) to the registry configured for the
scope, or to `--registry <url>`. `SWIFTPM_PURIFIER_REGISTRY_TOKEN` is sent
as a bearer token. For executables, `release <version>` builds the
archives to attach to a release.

## Limits

- **x86_64-linux only, for now.** nixpkgs marks its Swift 6.3 compiler
  broken on aarch64-linux, where it fails to link with the gold linker.
  nixpkgs expects the Swift 6.4 update, which links with LLD, to fix it,
  and aarch64-linux joins the flake's systems then. On macOS, SwiftPM
  builds against Xcode's toolchain, which the Nix sandbox does not have.
- **No dependencies from a git repository on the local disk.** A
  `.package(url: "/path/to/repo")` dependency names a repository that
  exists only on one machine, so no lockfile can make it fetchable
  elsewhere. Depend on it by path inside the package, or by its remote URL.
- **Editor support is untested.** The toolchain includes sourcekit-lsp,
  and the interactive mode also writes its workspace state into
  `.build/index-build`, where sourcekit-lsp builds its background index.
  In the Nix build sandbox, nixpkgs' sourcekit-lsp 6.3.3 reports that it
  cannot find the SourceKit plugin of its toolchain and cannot create a
  build server, so it resolves no symbols, with or without
  swiftpm-purifier, and no check covers it until nixpkgs' sourcekit-lsp
  works there.
- **No prebuilt swift-syntax.** SwiftPM 6 downloads prebuilt swift-syntax
  libraries for macros when it can. The lock does not record them, so the
  build and the interactive mode pass `--disable-experimental-prebuilts`
  and build swift-syntax from source.

## Tests

`nix flake check` builds every fixture under `tests/fixtures` from its
lockfile in the sandbox and runs it: dependencies from git, a dependency by
path with dependencies of its own, a macro, and a binary target whose
patched executable a prebuild command runs. It also checks the release
archives, the source archive, the stale-lockfile error and the command's
unit tests. `tests/cli.sh` covers what needs the network: relocking every
fixture reproduces its lockfile, the interactive mode, and a registry
dependency against a stand-in registry, which also receives a published
archive.

## Credit

swiftpm-purifier follows the design of
[sbt-purifier](https://github.com/nix-purifiers/sbt-purifier). The purifier
idea was inspired by nixcloud's [cargo (libnix)](https://github.com/nixcloud/cargo).

## License

MIT
