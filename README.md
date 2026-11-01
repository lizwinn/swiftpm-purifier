# swiftpm-purifier

A command and a Nix library that make Nix the dependency backend of a
[SwiftPM](https://www.swift.org/documentation/package-manager/) package.
SwiftPM still resolves and plans the build, and `Package.resolved` stays
its lockfile. `swiftpm-purifier lock` writes `swiftpm-purifier.lock.json`,
which records what `Package.resolved` lacks, such as the content hash of
each pin. Nix then builds the package in its sandbox from the two files,
with no generated Nix files to commit, and `swift` runs offline on the same
locked dependencies during development.

swiftpm-purifier meets the
[purifier contract](https://github.com/nix-purifiers/purifier/blob/main/CONTRACT.md)
that every nix-purifier shares.

## Quickstart

Lock the package in the current directory, and commit both lockfiles,
`Package.resolved` and `swiftpm-purifier.lock.json`, to the repository of
the project:

```zsh
nix run github:nix-purifiers/swiftpm-purifier -- lock
```

Then build the project from its directory, with no Nix file added to it.
Replace `hello` with a product of the package:

```zsh
nix build --impure --expr '
  let
    purifier = builtins.getFlake "github:nix-purifiers/swiftpm-purifier";
    pkgs = import purifier.inputs.nixpkgs {
      system = builtins.currentSystem;
      overlays = [ purifier.overlays.default ];
    };
  in
  (pkgs.swiftpm-purifier.buildSwiftPMProject { src = ./.; }).packages.hello'
```

This uses the purifier's pinned nixpkgs, matching the lock command above.
To build with ambient `<nixpkgs>` from your Nix search path instead,
replace `import purifier.inputs.nixpkgs` with `import <nixpkgs>`.
Both forms need no Nix files in your project. The build tool and language
versions must match the lockfile; with ambient nixpkgs, lock with the
purifier from that package set or pass a compatible toolchain to the builder.

The flake adds one attribute to the package set: the scope
`pkgs.swiftpm-purifier`, which holds the builder `buildSwiftPMProject`, the
`swiftpm-purifier` command as `cli`, and the Swift `toolchain`.

A project whose authors want a flake can package the project with one. The
flake can live in the repository of the project or in another one, and it
calls the builder directly:

```nix
{
  inputs.swiftpm-purifier.url = "github:nix-purifiers/swiftpm-purifier";
  inputs.nixpkgs.follows = "swiftpm-purifier/nixpkgs";

  outputs = { self, nixpkgs, swiftpm-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ swiftpm-purifier.overlays.default ];
      };
      project = pkgs.swiftpm-purifier.buildSwiftPMProject { src = self; };
    in
    {
      packages.${system}.default = project.packages.hello;
      checks.${system}.tests = project.tests;
    };
}
```

A package in an overlay that takes the scope as `{ swiftpm-purifier }:` calls
`swiftpm-purifier.buildSwiftPMProject` the same way.

`buildSwiftPMProject` takes these arguments:

- `src`, the root of the package.
- `lockFile`, which defaults to `swiftpm-purifier.lock.json` in `src` and
  may lie outside it.
- `packageResolved`, which defaults to `Package.resolved` in `src`. A copy
  kept outside the repository replaces the one in `src` in the build.
- `fetchers`, which goes unchanged to `fetchEntry` of the purifier library,
  so a company mirror or credentials go into `fetchers.fetchurl`.
- `buildConfig`, `release` (the default) or `debug`.
- `artifactBuildInputs`, libraries that the prebuilt files of binary
  targets need beyond the C and C++ runtime, curl, libxml2, zlib, OpenSSL,
  SQLite and ICU.
- Any argument of `stdenv.mkDerivation`.

It returns:

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

The builder is a package for `callPackage` in that scope. It takes
`swiftPackages`, `runCommand`, `zip`, `unzip`, `zstd`, `python3`,
`writeText`, `fetchurl`, `fetchgit` and the purifier library by name.
`swiftpm-purifier.buildSwiftPMProject.override` replaces any of them, and
`swiftpm-purifier.overrideScope` replaces what everything in the scope
shares.

`lib.swiftpm-purifier.readLock { src, lockFile ? ..., packageResolved ? ... }`
gives the lock in memory of the purifier contract:
`{ purifier, entries, outputs, problems }`. `problems` is empty for a usable
lock.

We recommend committing both lockfiles to the repository of the project.
The builder and the commands look for them there by default.

A flake can instead keep a build external: the flake that calls the builder
keeps the lockfiles outside the repository and passes them as `lockFile` and
`packageResolved`. This builds a project whose author commits neither
lockfile, or whose committed `Package.resolved` is stale or comes from
another version of SwiftPM. The commands take `--lockfile <path>` and
`--tool-lockfile <path>` for the two files, or the variables
`SWIFTPM_PURIFIER_LOCKFILE` and `SWIFTPM_PURIFIER_TOOL_LOCKFILE`. With
`--tool-lockfile`, `lock` and `update` write the `Package.resolved` there and
leave the copy in the tree as it is, and `lock` starts from the copy in the
tree when the outside one does not exist yet.

## Development loop

`nix develop github:nix-purifiers/swiftpm-purifier` gives a shell whose
`swift` runs through `swiftpm-purifier swift`. In a package with an
up-to-date lockfile, `swift build`, `swift test` and `swift run` use the
locked dependencies, which the shell links into `Packages/` and
`.build/artifacts/` from the Nix store. Outside that shell, run
`swiftpm-purifier swift build`.

`swiftpm-purifier` is a standalone command that runs SwiftPM, not a SwiftPM
package plugin. `swiftpm-purifier lock` records the downloads and keeps the
pins of `Package.resolved` as they are. It relocks when `Package.swift` or the pins
changed since the lockfile was made, and `relock` relocks regardless. A
relock of an unchanged package reproduces the lockfile byte for byte.

`swiftpm-purifier update [<package>...]` updates the pins through the
`swift package update` command of SwiftPM, for every package or the named
ones, and then relocks the lockfile against the result.

`swiftpm-purifier publish <scope.name> <version>` builds the `release` with
Nix and uploads it (SE-0391) to the registry configured for the scope, or
to `--registry <url>`. `SWIFTPM_PURIFIER_REGISTRY_TOKEN` is sent as a
bearer token.

For an external build, every command takes `--lockfile <path>` and
`--tool-lockfile <path>`, or reads `SWIFTPM_PURIFIER_LOCKFILE` and
`SWIFTPM_PURIFIER_TOOL_LOCKFILE`. Either one takes precedence over the
default location. The dev shell of a flake that calls the builder can set
both variables to the paths it passes as `lockFile` and `packageResolved`.

## Working offline

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
background index. Editor support does not work yet: the sourcekit-lsp 6.3.3
in nixpkgs cannot find the SourceKit plugin of its toolchain and cannot
create a build server, so it resolves no symbols, with or without
swiftpm-purifier.

## Troubleshooting

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

## Supported language repositories

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

x86_64-linux is the only supported system, so the flake's checks and its CI
run there and not on aarch64-linux. nixpkgs marks its Swift 6.3 compiler
broken on aarch64-linux, where it fails to link with the gold linker, and
aarch64-linux joins the flake's systems once nixpkgs updates to Swift 6.4,
which links with LLD. On macOS, SwiftPM builds against the Xcode toolchain,
which the Nix sandbox does not have.

## Examples

### vapor/toolbox

[vapor/toolbox](https://github.com/vapor/toolbox) is the command-line tool
of the Vapor web framework. It commits `Package.resolved` and no purifier
lockfile.

Lock the tool at a release, and build it from the clone:

```zsh
git clone --branch 20.0.2 https://github.com/vapor/toolbox
cd toolbox
nix run github:nix-purifiers/swiftpm-purifier -- lock
nix build --impure --expr '
  let
    purifier = builtins.getFlake "github:nix-purifiers/swiftpm-purifier";
    pkgs = import purifier.inputs.nixpkgs {
      system = builtins.currentSystem;
      overlays = [ purifier.overlays.default ];
    };
  in
  (pkgs.swiftpm-purifier.buildSwiftPMProject { src = ./.; }).packages.vapor'
./result/bin/vapor --help
```

To keep the purifier lockfile outside the clone, write it into a flake of
your own with `--lockfile`, and let that flake build the tool from its
source:

```zsh
nix run github:nix-purifiers/swiftpm-purifier -- --lockfile ../vapor-toolbox/swiftpm-purifier.lock.json lock
```

```nix
{
  inputs.swiftpm-purifier.url = "github:nix-purifiers/swiftpm-purifier";
  inputs.nixpkgs.follows = "swiftpm-purifier/nixpkgs";
  inputs.toolbox = {
    url = "github:vapor/toolbox/20.0.2";
    flake = false;
  };

  outputs = { nixpkgs, swiftpm-purifier, toolbox, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ swiftpm-purifier.overlays.default ];
      };
      project = pkgs.swiftpm-purifier.buildSwiftPMProject {
        src = toolbox;
        lockFile = ./swiftpm-purifier.lock.json;
      };
    in
    {
      packages.${system}.default = project.packages.vapor;
    };
}
```

To move to a newer release, change the tag in the flake input, and run
`swiftpm-purifier update` in a checkout of that release with the same
`--lockfile`.

## Credits

swiftpm-purifier follows the design of
[sbt-purifier](https://github.com/nix-purifiers/sbt-purifier). The purifier
idea came from the [cargo (libnix)](https://github.com/nixcloud/cargo)
project by nixcloud.

## License

MIT
