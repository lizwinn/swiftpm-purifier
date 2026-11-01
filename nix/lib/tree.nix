# SPDX-License-Identifier: MIT
#
# The locked dependencies of a package, laid out the way SwiftPM expects
# them under the package root: each entry at its `path` (`Packages/<name>`
# for a package dependency, `.build/artifacts/...` for a binary target),
# and `workspace-state.json.in`, the workspace state the lock run recorded,
# with every package dependency marked as edited. The template names the
# package root `@root@`; whoever links the tree into a package fills it in.
#
# `patchArtifact` (patch-artifact.nix) makes the prebuilt files of each
# binary target run under Nix.
{
  lock,
  fetchurl,
  fetchgit,
  runCommand,
  unzip,
  patchArtifact,
}:
let
  fetch = import ./fetch.nix {
    inherit
      lock
      fetchurl
      fetchgit
      runCommand
      unzip
      ;
  };

  isBinaryTarget = artifact: builtins.match "\\.build/artifacts/.*" artifact.path != null;

  place =
    artifact:
    if isBinaryTarget artifact then
      patchArtifact (lock.artifactName artifact) (fetch artifact)
    else
      fetch artifact;

  links = builtins.concatStringsSep "\n" (
    map (artifact: ''
      mkdir -p "$(dirname "$out/${artifact.path}")"
      ln -s ${place artifact} "$out/${artifact.path}"
    '') lock.artifacts
  );
in
runCommand "swiftpm-purifier-tree"
  {
    workspaceState = builtins.toJSON lock.workspaceState;
    passAsFile = [ "workspaceState" ];
  }
  ''
    mkdir -p $out
    ${links}
    cp "$workspaceStatePath" $out/workspace-state.json.in
  ''
