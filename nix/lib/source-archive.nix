# SPDX-License-Identifier: MIT
#
# The source archive of a package, the file a package registry serves for
# a release (SE-0292): a zip of the package root under one top-level
# directory named after the package, without build state (.build, the
# Packages directory of edited dependencies) or version control. The build
# makes it for `sourceArchive`, and `swiftpm-purifier publish` uploads it.
{
  runCommand,
  zip,
}:
{
  src,
  name,
}:
let
  # Imported without build state or version control, so a package root
  # with a .build directory gives the same archive as a clean checkout.
  source = builtins.path {
    path = src;
    name = "source";
    filter =
      path: type:
      !(builtins.elem (baseNameOf path) [
        ".build"
        "Packages"
        ".git"
        ".swiftpm"
      ]);
  };
in
runCommand "${name}-source.zip"
  {
    nativeBuildInputs = [ zip ];
  }
  ''
    mkdir root
    cp -r ${source} root/${name}
    chmod -R u+w root
    cd root
    find ${name} -exec touch -h -d @1 {} +
    find ${name} -print | LC_ALL=C sort | zip -qX $out -@
  ''
