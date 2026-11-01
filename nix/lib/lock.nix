# SPDX-License-Identifier: MIT
#
# Reads a swiftpm-purifier lockfile (written by `swiftpm-purifier lock`),
# and stops the evaluation, with the command that fixes it, when the
# lockfile is from another format version, lacks a field, or lacks the
# entry of a dependency its workspace state names.
#
# Needs no nixpkgs. `lockFile` is a path, or an absolute path as a string.
{ lockFile }:
let
  lock = builtins.fromJSON (builtins.readFile lockFile);

  supportedVersion = import ./lock-version.nix;

  relock = "Run `swiftpm-purifier relock` to write it again.";

  fields = [
    "version"
    "package"
    "rootDirectory"
    "resolvedHash"
    "manifestHash"
    "products"
    "workspaceState"
    "artifacts"
  ];
  missingFields = builtins.filter (field: !(lock ? ${field})) fields;

  # Every dependency the workspace state marks as edited lives at
  # Packages/<subpath>, and every remote binary target in the directory
  # above its bundle, so each needs an entry there.
  entryPaths = map (artifact: artifact.path) lock.artifacts;
  expectedPaths =
    map (dependency: "Packages/${dependency.subpath}") (
      builtins.filter (
        dependency: dependency.state.name == "edited"
      ) lock.workspaceState.object.dependencies
    )
    # Each bundle path starts with "@root@/", which is 7 characters.
    ++
      map (artifact: dirOf (builtins.substring 7 (builtins.stringLength artifact.path) artifact.path))
        (builtins.filter (artifact: artifact.source.type == "remote") lock.workspaceState.object.artifacts);
  missingEntries = builtins.filter (path: !(builtins.elem path entryPaths)) expectedPaths;

  # A store path name from a tree path. Store path names allow
  # [A-Za-z0-9+._?=-], must not start with a dot, and are at most 211
  # characters; every other character becomes "_", and a long name keeps
  # its end. The swift wrapper and the sandboxed build both name their
  # fetches with this function, so they share store paths.
  storeName =
    path:
    let
      # builtins.split alternates the text between matches with a list per
      # match.
      replaced = builtins.concatStringsSep "" (
        map (part: if builtins.isList part then "_" else part) (builtins.split "[^A-Za-z0-9+._?=-]" path)
      );
      length = builtins.stringLength replaced;
      tail = if length > 200 then builtins.substring (length - 200) 200 replaced else replaced;
      undotted = builtins.head (builtins.match "\\.*(.*)" tail);
    in
    if undotted == "" then "entry" else undotted;
in
assert
  (lock ? version && lock.version == supportedVersion)
  || throw "swiftpm-purifier: ${toString lockFile} has lock format version ${
    toString (lock.version or "none")
  }; this library reads version ${toString supportedVersion}. Run `swiftpm-purifier relock` with the swiftpm-purifier revision of this library.";
assert
  missingFields == [ ]
  || throw "swiftpm-purifier: ${toString lockFile} lacks ${builtins.concatStringsSep ", " missingFields}. ${relock}";
assert
  missingEntries == [ ]
  || throw "swiftpm-purifier: ${toString lockFile} has no entry for ${builtins.concatStringsSep ", " missingEntries}, which its workspace state names. ${relock}";
lock
// {
  inherit storeName;

  # The fetch name of an entry: its tree path, made a valid store name.
  artifactName = artifact: storeName artifact.path;
}
