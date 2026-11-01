# SPDX-License-Identifier: MIT
#
# Reads a swiftpm-purifier lockfile (written by `swiftpm-purifier lock`)
# together with the manifests and the Package.resolved in `src`.
#
# Package.resolved names each remote dependency and the revision or
# version it is pinned to. The lockfile adds what Package.resolved lacks:
# the content hash of each pin, the package name that the manifest of each
# dependency declares, the URL a mirror or a registry serves it from, and
# what the manifests declare beyond the pins (binary targets, path
# dependencies and products).
#
# The result's `lock` is the lock in memory of the purifier contract:
# `entries`, the purifier library entries to fetch; `outputs`, the
# products by name; and `problems`, one message for a lockfile from
# another format version, with a missing field, changed by hand, or out of
# date with the manifests or the pins, each naming the command that fixes
# it. The other attributes are what the build needs besides: the SwiftPM
# workspace state that marks every pinned dependency as edited, and the
# package names from the manifest. They hold values only when `problems`
# is empty.
#
# Needs no nixpkgs. `lockFile` is a path, or an absolute path as a string.
{ lockFile, src }:
let
  relock = "Run `swiftpm-purifier relock` to write it again.";

  # Nix cannot catch a parse error, so a lockfile that is not valid JSON
  # fails evaluation, and the context names the command that fixes it.
  lock = builtins.addErrorContext "swiftpm-purifier: ${toString lockFile} is not valid JSON. ${relock}" (
    builtins.fromJSON (builtins.readFile lockFile)
  );

  supportedVersion = import ./lock-version.nix;

  fields = [
    "version"
    "package"
    "rootDirectory"
    "manifestHash"
    "products"
    "workspaceStateVersion"
    "pins"
    "binaryTargets"
    "localDependencies"
    "contentHash"
  ];
  missingFields = builtins.filter (field: !(lock ? ${field})) fields;

  # The lock run writes a hash of the lockfile without this field, of the
  # JSON swiftpm-purifier and builtins.toJSON both write: keys in order, no
  # spaces. A lockfile changed by hand no longer matches it.
  contentHash = builtins.convertHash {
    hash = builtins.hashString "sha256" (builtins.toJSON (builtins.removeAttrs lock [ "contentHash" ]));
    hashAlgo = "sha256";
    toHashFormat = "sri";
  };

  # The hash of the manifests, computed the way swiftpm-purifier computes
  # it: the SHA-256 of the JSON list of [name, hex SHA-256] of each
  # manifest, in name order.
  manifests = builtins.sort builtins.lessThan (
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

  # SwiftPM writes no Package.resolved for a package without remote
  # dependencies, and such a package has no pins.
  resolvedFile = src + "/Package.resolved";
  resolved =
    if builtins.pathExists resolvedFile then
      builtins.fromJSON (builtins.readFile resolvedFile)
    else
      {
        version = 3;
        pins = [ ];
      };
  resolvedPins = resolved.pins;

  # The revision, or for a registry pin the version, that a pin and the
  # lockfile's record of it name.
  pinnedAt = pin: pin.state.revision or pin.state.version;
  lockedAt = locked: locked.revision or locked.version;
  isRegistry = pin: pin.kind == "registry";

  covered = builtins.all (
    pin: lock.pins ? ${pin.identity} && lockedAt lock.pins.${pin.identity} == pinnedAt pin
  ) resolvedPins;
  sameSet =
    builtins.sort builtins.lessThan (map (pin: pin.identity) resolvedPins)
    == builtins.attrNames lock.pins;

  # The first problem in the order the checks depend on each other: a later
  # check reads what an earlier one verified.
  problem =
    if !(lock ? version && lock.version == supportedVersion) then
      "swiftpm-purifier: ${toString lockFile} has lock format version ${
        toString (lock.version or "none")
      }; this library reads version ${toString supportedVersion}. Run `swiftpm-purifier relock` with the swiftpm-purifier revision of this library."
    else if missingFields != [ ] then
      "swiftpm-purifier: ${toString lockFile} lacks ${builtins.concatStringsSep ", " missingFields}. ${relock}"
    else if lock.contentHash != contentHash then
      "swiftpm-purifier: ${toString lockFile} does not match its contentHash, so it was changed after the lock run wrote it. ${relock}"
    else if lock.manifestHash != manifestHash then
      "swiftpm-purifier: ${toString lockFile} is out of date with Package.swift in ${toString src}. Run `swiftpm-purifier lock`."
    else if
      !builtins.elem (resolved.version or null) [
        2
        3
      ]
    then
      "swiftpm-purifier: ${toString resolvedFile} has format version ${
        toString (resolved.version or "none")
      }, which predates Swift 5.6. Run `swiftpm-purifier lock`, which resolves with the current toolchain."
    else if !(covered && sameSet) then
      "swiftpm-purifier: ${toString lockFile} is out of date with Package.resolved in ${toString src}. Run `swiftpm-purifier lock`."
    else
      null;
  problems = if problem == null then [ ] else [ problem ];
  usable = problems == [ ];

  # SwiftPM keeps a source control checkout under the last component of the
  # URL without its `.git` suffix, which keeps the case of the URL where
  # the identity is lowercase, and a registry download under
  # scope/name/version. The lock run checks that the workspace state
  # SwiftPM wrote uses these paths.
  subpathOf =
    pin:
    if isRegistry pin then
      let
        parts = builtins.match "([^.]+)\\.(.+)" pin.identity;
      in
      "${builtins.elemAt parts 0}/${builtins.elemAt parts 1}/${pin.state.version}"
    else
      let
        base = builtins.elemAt (builtins.match ".*/([^/]+)/*" pin.location) 0;
        unsuffixed = builtins.match "(.*)\\.git" base;
      in
      if unsuffixed == null then base else builtins.head unsuffixed;

  packageRefOf = pin: {
    inherit (pin) identity kind;
    location = if isRegistry pin then pin.identity else pin.location;
    inherit (lock.pins.${pin.identity}) name;
  };

  checkoutStateOf =
    pin:
    if isRegistry pin then
      {
        name = "registryDownload";
        inherit (pin.state) version;
      }
    else
      {
        name = "sourceControlCheckout";
        checkoutState = pin.state;
      };

  recordOf =
    pin:
    let
      subpath = subpathOf pin;
      packageRef = packageRefOf pin;
    in
    {
      basedOn = {
        basedOn = null;
        inherit packageRef subpath;
        state = checkoutStateOf pin;
      };
      inherit packageRef subpath;
      state = {
        name = "edited";
        path = null;
      };
    };

  entryOf =
    pin:
    let
      locked = lock.pins.${pin.identity};
    in
    {
      path = "Packages/${subpathOf pin}";
      inherit (locked) hash;
    }
    // (
      if isRegistry pin then
        {
          archive = {
            inherit (locked) url;
            mirrors = [ ];
            stripTop = true;
          };
        }
      else
        {
          # SwiftPM uses an edited dependency as a plain source tree, so the
          # checkout needs no .git.
          git = {
            url = locked.url or pin.location;
            rev = pin.state.revision;
            submodules = true;
            leaveDotGit = false;
            commitObject = null;
          };
        }
    );

  # A remote binary target is fetched into the directory above its bundle.
  # Each bundle path starts with "@root@/", which is 7 characters, and its
  # hash is the checksum the manifest declares.
  binaryEntryOf = target: {
    path = dirOf (builtins.substring 7 (builtins.stringLength target.path) target.path);
    archive = {
      inherit (target.source) url;
      mirrors = [ ];
      stripTop = false;
    };
    hash = builtins.convertHash {
      hash = target.source.checksum;
      hashAlgo = "sha256";
      toHashFormat = "sri";
    };
  };

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
{
  lock = {
    purifier = "swiftpm-purifier";
    inherit problems;

    entries =
      if usable then
        map entryOf resolvedPins
        ++ map binaryEntryOf (builtins.filter (target: target.source.type == "remote") lock.binaryTargets)
      else
        [ ];

    # Each product of the package by name, with its type and, for a
    # library, its linkage.
    outputs =
      if usable then
        builtins.listToAttrs (
          map (product: {
            inherit (product) name;
            value = product;
          }) lock.products
        )
      else
        { };
  };

  inherit (lock) package rootDirectory products;
  inherit storeName;

  # The fetch name of an entry: its tree path, made a valid store name.
  entryName = entry: storeName entry.path;

  workspaceState = {
    object = {
      artifacts = lock.binaryTargets;
      dependencies = lock.localDependencies ++ map recordOf resolvedPins;
      prebuilts = [ ];
    };
    version = lock.workspaceStateVersion;
  };
}
