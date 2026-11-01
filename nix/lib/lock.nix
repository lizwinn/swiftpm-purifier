# SPDX-License-Identifier: MIT
#
# Reads a swiftpm-purifier lockfile (written by `swiftpm-purifier lock`).
#
# Needs no nixpkgs. `lockFile` is a path, or an absolute path as a string.
{ lockFile }:
let
  lock = builtins.fromJSON (builtins.readFile lockFile);

  supportedVersion = import ./lock-version.nix;

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
  lock.version == supportedVersion
  || throw "swiftpm-purifier: ${toString lockFile} has lock format version ${toString lock.version}; this library reads version ${toString supportedVersion}. Run `swiftpm-purifier relock` with the swiftpm-purifier revision of this library.";
lock
// {
  inherit storeName;

  # The fetch name of an entry: its tree path, made a valid store name.
  artifactName = artifact: storeName artifact.path;
}
