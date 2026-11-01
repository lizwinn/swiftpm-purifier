# SPDX-License-Identifier: MIT
#
# The fetcher for locked entries, in the shapes of the purifier library:
#
# - a file entry `{ path, url, mirrors, hash }` is a file, fetched from
#   `[ url ] ++ mirrors`;
# - an archive entry `{ path, archive = { url, mirrors, stripTop }, hash }`
#   is an archive file (`hash` covers the file as downloaded), unpacked
#   into a directory, without its single top-level directory when
#   `stripTop` is true;
# - a git entry `{ path, git = { url, rev, submodules, leaveDotGit }, hash }`
#   is a checkout, fetched with nixpkgs' fetchgit, so `hash` is the hash
#   nix-prefetch-git reports.
#
# `fetchurl` and `fetchgit` come from the package set, and a caller may
# replace them, for credentials or mirrors: fetchurl is called with
# { name, urls, hash }, and fetchgit with { name, url, rev, hash,
# fetchSubmodules, leaveDotGit }.
{
  lock,
  fetchurl,
  fetchgit,
  runCommand,
  unzip,
}:
artifact:
let
  name = lock.artifactName artifact;

  download =
    source:
    fetchurl {
      inherit name;
      urls = [ source.url ] ++ source.mirrors;
      inherit (artifact) hash;
    };
in
if artifact ? git then
  fetchgit {
    inherit name;
    inherit (artifact.git) url rev leaveDotGit;
    inherit (artifact) hash;
    fetchSubmodules = artifact.git.submodules;
  }
else if artifact ? archive then
  runCommand name
    {
      nativeBuildInputs = [ unzip ];
      archive = download artifact.archive;
      stripTop = if artifact.archive.stripTop then "1" else "";
    }
    ''
      mkdir unpacked
      # The fetched file is named after the entry's path, so its format
      # comes from its content.
      if unzip -tqq "$archive" > /dev/null 2>&1; then
        unzip -q "$archive" -d unpacked
      else
        tar -xf "$archive" -C unpacked
      fi
      if [ -n "$stripTop" ]; then
        entries=(unpacked/*)
        if [ "''${#entries[@]}" -ne 1 ] || [ ! -d "''${entries[0]}" ]; then
          echo "swiftpm-purifier: $archive has no single top-level directory to strip" >&2
          exit 1
        fi
        mv "''${entries[0]}" "$out"
      else
        mv unpacked "$out"
      fi
    ''
else
  download artifact
