# swiftpm-purifier

A command and a Nix library that make Nix the dependency backend of a
[SwiftPM](https://www.swift.org/documentation/package-manager/) package.
SwiftPM still resolves and plans the build, and `Package.resolved` stays
its lockfile. `swiftpm-purifier lock` writes `swiftpm-purifier.lock.json`,
which records only what `Package.resolved` lacks, such as the content hash
of each pin. Nix then builds the package in its sandbox from the two files,
with no generated Nix files to commit, and `swift` runs offline on the same
locked dependencies during development.

swiftpm-purifier meets the
[purifier contract](https://github.com/nix-purifiers/purifier/blob/main/CONTRACT.md)
that every nix-purifier shares.

## Quickstart

Lock the package in the current directory, and commit `Package.resolved`
and the lockfile:

```zsh
nix run github:nix-purifiers/swiftpm-purifier -- lock
```

Build it with the library function in your flake:

```nix
{
  inputs.swiftpm-purifier.url = "github:nix-purifiers/swiftpm-purifier";
  inputs.nixpkgs.follows = "swiftpm-purifier/nixpkgs";

  outputs = { nixpkgs, swiftpm-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      project = swiftpm-purifier.lib.swiftpm-purifier.buildSwiftPMProject {
        inherit pkgs;
        src = ./.;
      };
    in
    {
      packages.${system}.default = project.packages.hello;
      checks.${system}.tests = project.tests;
    };
}
```

`buildSwiftPMProject` returns:

- `packages.<product>`, one per product of the package. An executable is
  its binary under `bin/`. A dynamic or static library is its library file
  under `lib/` with its Swift modules. SwiftPM publishes an automatic
  library, a plugin and a macro as source, so their package is the source
  archive of the package.
- `tests`, the build with `swift test` run in the sandbox.
- `release`, the source archive of the package, which a package registry
  serves and `swiftpm-purifier publish` uploads.
- `fetches`, the purifier library entries that the build fetches.
- `project`, the build with every product installed, and `tree`, the locked
  dependencies laid out for SwiftPM.

Its arguments are `pkgs`; `src`; `lockFile`, which defaults to the
lockfile in `src` and may lie outside it; `fetchers`, which goes unchanged
to `fetchEntry` of the purifier library, so a company mirror or credentials
go into `fetchers.fetchurl`; `buildConfig`, `release` (the default) or
`debug`; `artifactBuildInputs`, libraries that the prebuilt files of binary
targets need beyond the C and C++ runtime, curl, libxml2, zlib, OpenSSL,
SQLite and ICU; and any argument of `stdenv.mkDerivation`.

`lib.swiftpm-purifier.readLock { src, lockFile ? ... }` gives the lock in
memory of the purifier contract: `{ purifier, entries, outputs, problems }`.
`problems` is empty for a usable lock.

A project whose author does not commit a purifier lockfile can be built by
a flake that keeps the lockfile and passes it as `lockFile`. The file
`Package.resolved` stays in `src`, because it is the lockfile of SwiftPM.
A project without a `Package.resolved` cannot be built externally yet.

## Everyday loop

`nix develop github:nix-purifiers/swiftpm-purifier` gives a shell whose
`swift` runs through `swiftpm-purifier swift`. In a package with an
up-to-date lockfile, `swift build`, `swift test` and `swift run` use the
locked dependencies, which the shell links into `Packages/` and
`.build/artifacts/` from the Nix store. Outside that shell, run
`swiftpm-purifier swift build`.

`swiftpm-purifier lock` records the downloads and keeps the pins of
`Package.resolved` as they are. It relocks only when `Package.swift` or the
pins changed since the lockfile was made, and `relock` relocks regardless.
A relock of an unchanged package reproduces the lockfile byte for byte.

`swiftpm-purifier update [<package>...]` updates the pins through the
`swift package update` command of SwiftPM, for every package or the named
ones, and then relocks the lockfile against the result.

`swiftpm-purifier publish <scope.name> <version>` builds the `release` with
Nix and uploads it (SE-0391) to the registry configured for the scope, or
to `--registry <url>`. `SWIFTPM_PURIFIER_REGISTRY_TOKEN` is sent as a
bearer token.

When the lockfile is not in the package, every command takes
`--lockfile <path>`, or reads `SWIFTPM_PURIFIER_LOCKFILE`. The dev shell of
a flake that calls the builder can set the variable to the path it passes
as `lockFile`.

## Offline work

`swiftpm-purifier prefetch` realizes in the Nix store the locked
dependencies and the toolchain, which includes sourcekit-lsp. It links the
dependencies into the package, writes the workspace state that marks them
as edited, and keeps everything alive with a garbage-collector root under
`.build/swiftpm-purifier`. After a prefetch, `swift build`, `swift test` and
`swift run` work with the network cut off. `swiftpm-purifier uninstall`
removes the links. The default `.gitignore` that SwiftPM writes already
ignores `/Packages`.

## Editor

The toolchain includes sourcekit-lsp, and `prefetch` also writes the
workspace state into `.build/index-build`, where sourcekit-lsp builds its
background index. No check covers an editor. In the Nix build sandbox, the
sourcekit-lsp 6.3.3 in nixpkgs reports that it cannot find the SourceKit
plugin of its toolchain and cannot create a build server, so it resolves no
symbols, with or without swiftpm-purifier. Editor support stays untested
until that sourcekit-lsp works there.

## Errors and fixes

A lockfile that is stale, changed by hand, malformed or incomplete fails
in the command and at Nix evaluation, with a message that names the command
that fixes it.

| Message | Cause | Fix |
|---|---|---|
| `is out of date with Package.resolved` or `with Package.swift` | The pins or the manifests changed since the lock run. | `swiftpm-purifier lock` |
| `does not match its contentHash` | The lockfile was edited after the lock run wrote it. | `swiftpm-purifier relock` |
| `lacks <field>` or `is not valid JSON` | The lockfile is incomplete or damaged. | `swiftpm-purifier relock` |
| `has lock format version N` | The lockfile is from another version of swiftpm-purifier. | `swiftpm-purifier relock` with the version that the flake pins |
| `hash mismatch` | The content of a download differs from the recorded hash. | Check the source, then `swiftpm-purifier relock` |

`swiftpm-purifier swift` stops with a stale lockfile, where SwiftPM would
resolve and download what the lock does not hold.

## Sources supported and refused

| What SwiftPM fetched | What the lockfile records | Status |
|---|---|---|
| A package from git (`.package(url:)`) | the content hash by `nix-prefetch-git`, with submodules; the fetch URL when a mirror replaces the location | supported |
| A package from a registry (`.package(id:)`) | the URL of the source archive that the registry serves, and its hash | supported |
| A remote binary target (`.binaryTarget(url:checksum:)`) | the URL, with the checksum of the manifest | supported |
| A package by path (`.package(path:)`) | where it is | part of the source |
| A local binary target (`.binaryTarget(path:)`) | where it is | part of the source |
| A git repository on the local disk | nothing | refused, because it exists on one machine only; depend on it by path or by its remote URL |
| Prebuilt swift-syntax libraries | nothing | refused; the build and `swift` pass `--disable-experimental-prebuilts` and build swift-syntax from source |

The lockfile entries follow the entry shapes of
[purifier](https://github.com/nix-purifiers/purifier), the library that the
nix-purifiers share, and that library fetches them. The lock run refuses a
dependency whose SwiftPM workspace state it cannot derive from
`Package.resolved`. Binary targets ship prebuilt files for other systems,
so the build patches their ELF executables and libraries with
`autoPatchelfHook` to run under Nix.

x86_64-linux is the only system for now. nixpkgs marks its Swift 6.3
compiler broken on aarch64-linux, where it fails to link with the gold
linker. nixpkgs expects the Swift 6.4 update, which links with LLD, to fix
it, and aarch64-linux joins the flake's systems then. On macOS, SwiftPM
builds against the Xcode toolchain, which the Nix sandbox does not have.

## Real-world projects

swift-format at `9f3ddd2` (swift-6.3.3-RELEASE) locks in 16 seconds, and it
builds, runs and passes its configuration tests offline in the everyday
loop. Its repository commits no `Package.resolved`, so a flake cannot build
it externally yet, and no check builds it. After a dependency is added to
it, `swift` stops with the stale-lockfile message, and a relock of 22
seconds brings the loop back.

No check builds a real-world project yet. The candidate is
[vapor/toolbox](https://github.com/vapor/toolbox) at `20.0.2`, which commits
its `Package.resolved`.

## Tests

`nix flake check` builds every fixture under `tests/fixtures` from its
lockfile in the sandbox and runs it: dependencies from git, a dependency by
path with dependencies of its own, a macro, and a binary target whose
patched executable a prebuild command runs. The contract checks
`conformance-stale`, `conformance-tampered`, `conformance-missing`,
`conformance-malformed` and `conformance-external` run there too, with the
unit tests of the command.

`tests/cli.sh` runs what needs the network or Nix itself, and its sections
are the CI jobs `conformance-relock`, `conformance-rebuild`,
`conformance-offline` and `conformance-update`, together with the
interactive mode, the tampered-hash build and a registry dependency
against a stand-in registry, which also receives a published archive.

## Credits

swiftpm-purifier follows the design of
[sbt-purifier](https://github.com/nix-purifiers/sbt-purifier). The purifier
idea came from the [cargo (libnix)](https://github.com/nixcloud/cargo)
project by nixcloud.

## License

MIT
