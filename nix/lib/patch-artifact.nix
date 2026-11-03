# SPDX-License-Identifier: MIT
#
# Makes the executables and libraries of a binary target's artifact bundle
# run under Nix. A bundle ships prebuilt ELF files that name the system's
# dynamic linker (/lib64/ld-linux-x86-64.so.2) and find their libraries in
# the system's library directories, which a Nix system does not have.
# autoPatchelfHook points them at the linker and libraries of the package
# set.
#
# The libraries on offer are the C and C++ runtime and the C libraries
# that prebuilt Swift tools commonly link (curl, libxml2, zlib, OpenSSL,
# SQLite and ICU); autoPatchelfHook links only those a file asks for, by
# soname. libxml2 comes in the current series and in 2.13, whose soname
# (libxml2.so.2) binaries built on older distributions ask for.
# `buildInputs` adds libraries beyond these. Files for other platforms in
# the bundle, such as macOS binaries, are left as they are.
#
# On macOS nothing is patched: a bundle's macOS files name the system's
# libraries by absolute path, under /usr/lib and /System, which every Mac
# has, and its ELF files are for other platforms.
{
  lib,
  stdenv,
  autoPatchelfHook,
  curl,
  libxml2,
  libxml2_13,
  zlib,
  openssl,
  sqlite,
  icu,
  buildInputs ? [ ],
}:
name: unpacked:
stdenv.mkDerivation {
  inherit name;
  src = unpacked;
  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  nativeBuildInputs = lib.optionals stdenv.hostPlatform.isLinux [ autoPatchelfHook ];
  buildInputs =
    lib.optionals stdenv.hostPlatform.isLinux [
      stdenv.cc.cc.lib
      curl
      libxml2
      libxml2_13
      zlib
      openssl
      sqlite
      icu
    ]
    ++ buildInputs;
  installPhase = ''
    cp -r --no-preserve=mode $src $out
    find $src -type f -perm -u+x -printf '%P\n' | while read -r file; do
      chmod +x "$out/$file"
    done
  '';
}
