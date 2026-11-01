#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Tests what the flake's checks cannot run in the Nix sandbox, because it
# needs the network or runs Nix:
#
# 1. A relock of each fixture reproduces its committed lockfile.
# 2. The interactive mode: `swift` runs and tests on the locked
#    dependencies; with a stale lockfile it removes its links and leaves
#    SwiftPM to resolve the usual way; `swiftpm-purifier uninstall` removes
#    them too.
# 3. A lockfile with a tampered hash fails the build with a hash mismatch.
# 4. A dependency from a package registry, against a stand-in registry
#    (tests/registry.py): `swiftpm-purifier publish` uploads a package's
#    source archive, a second package depends on it by registry identity,
#    its lock records the archive, Nix builds it, and the interactive mode
#    runs it with the registry gone.
#
# Run it from anywhere: tests/cli.sh
set -euo pipefail

tests=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$tests")
work=$(mktemp -d)
registry_pid=
cleanup() {
  if [ -n "$registry_pid" ]; then kill "$registry_pid" 2> /dev/null || true; fi
  chmod -R u+w "$work" 2> /dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

nix build --out-link "$work/toolchain" "$repo#toolchain"
bin=$work/toolchain/bin

echo "== relocking the fixtures reproduces their lockfiles"
for fixture in hello paths binary macro; do
  mkdir -p "$work/relock"
  cp -r "$tests/fixtures/$fixture" "$work/relock/$fixture"
  chmod -R u+w "$work/relock/$fixture"
  (cd "$work/relock/$fixture" && "$bin/swiftpm-purifier" relock)
  diff -u "$tests/fixtures/$fixture/swiftpm-purifier.lock.json" "$work/relock/$fixture/swiftpm-purifier.lock.json" \
    || fail "relocking $fixture changed its lockfile"
done

echo "== the interactive mode runs and tests on the locked dependencies"
cp -r "$tests/fixtures/hello" "$work/hello"
chmod -R u+w "$work/hello"
cd "$work/hello"
[ "$("$bin/swift" run hello Nix Swift Nix)" = "$(printf 'Hello, Nix!\nHello, Swift!')" ] || fail "swift run printed something else"
for dependency in swift-argument-parser swift-collections; do
  [ -L "Packages/$dependency" ] || fail "Packages/$dependency is not a link"
  case "$(readlink "Packages/$dependency")" in /nix/store/*) ;; *) fail "Packages/$dependency is not in the store" ;; esac
done
"$bin/swift" test > /dev/null || fail "swift test failed"

echo "== a stale lockfile leaves SwiftPM to resolve the usual way"
cp Package.resolved "$work/Package.resolved"
echo >> Package.resolved
"$bin/swift" --version 2> "$work/stale.err" > /dev/null
grep -q 'out of date' "$work/stale.err" || fail "no warning about the stale lockfile"
[ ! -e Packages/swift-collections ] || fail "the links stayed with a stale lockfile"
cp "$work/Package.resolved" Package.resolved

echo "== uninstall removes the links"
"$bin/swift" --version > /dev/null
[ -L Packages/swift-collections ] || fail "the links did not come back"
"$bin/swiftpm-purifier" uninstall
[ ! -e Packages/swift-collections ] || fail "uninstall left the links"
[ ! -e .build/workspace-state.json ] || fail "uninstall left the workspace state"

echo "== a tampered hash in the lockfile fails the fetch"
cp -r "$tests/fixtures/hello" "$work/tampered"
chmod -R u+w "$work/tampered"
python3 - "$work/tampered/swiftpm-purifier.lock.json" << 'EOF'
import json, sys
path = sys.argv[1]
lock = json.load(open(path))
# Another valid SHA-256 hash: the fetch succeeds, and its content does not match.
lock["artifacts"][0]["hash"] = "sha256-" + "A" * 43 + "="
open(path, "w").write(json.dumps(lock, indent=2, sort_keys=True) + "\n")
EOF
if nix build --impure --no-link --expr "
  let
    flake = builtins.getFlake \"$repo\";
    pkgs = import flake.inputs.nixpkgs {
      system = builtins.currentSystem;
      overlays = [ flake.overlays.default ];
    };
  in
  (pkgs.buildSwiftPMProject { src = $work/tampered; }).project
" 2> "$work/tampered.err"; then
  fail "a build with a tampered hash succeeded"
fi
grep -q 'hash mismatch' "$work/tampered.err" || fail "a tampered hash failed without a hash mismatch: $(tail -5 "$work/tampered.err")"

echo "== a dependency from a package registry"
mkdir -p "$work/archives"
python3 "$tests/registry.py" "$work/archives" "$work/port" &
registry_pid=$!
for _ in $(seq 50); do [ -s "$work/port" ] && break; sleep 0.1; done
registry=http://127.0.0.1:$(cat "$work/port")

# The package to publish, with no dependencies.
mkdir -p "$work/greeter/Sources/Greeter"
cat > "$work/greeter/Package.swift" << 'EOF'
// swift-tools-version:6.0
import PackageDescription

let package = Package(
  name: "greeter",
  products: [.library(name: "Greeter", targets: ["Greeter"])],
  targets: [.target(name: "Greeter")]
)
EOF
cat > "$work/greeter/Sources/Greeter/Greeter.swift" << 'EOF'
public func greeting(for name: String) -> String { "Greetings, \(name)!" }
EOF
(cd "$work/greeter" && "$bin/swiftpm-purifier" lock && "$bin/swiftpm-purifier" publish nix.greeter 1.0.0 --registry "$registry")
[ -e "$work/archives/nix.greeter-1.0.0.zip" ] || fail "publish stored no archive"

# The package that depends on it by registry identity.
mkdir -p "$work/consumer/Sources/consumer"
cat > "$work/consumer/Package.swift" << 'EOF'
// swift-tools-version:6.0
import PackageDescription

let package = Package(
  name: "consumer",
  products: [.executable(name: "consumer", targets: ["consumer"])],
  dependencies: [.package(id: "nix.greeter", from: "1.0.0")],
  targets: [
    .executableTarget(name: "consumer", dependencies: [.product(name: "Greeter", package: "nix.greeter")])
  ]
)
EOF
cat > "$work/consumer/Sources/consumer/main.swift" << 'EOF'
import Greeter
print(greeting(for: "Nix"))
EOF
mkdir -p "$work/consumer/.swiftpm/configuration"
cat > "$work/consumer/.swiftpm/configuration/registries.json" << EOF
{
  "authentication": {},
  "registries": {"[default]": {"supportsAvailability": false, "url": "$registry"}},
  "security": {"default": {"signing": {"onUnsigned": "silentAllow"}}},
  "version": 1
}
EOF
cd "$work/consumer"
"$bin/swiftpm-purifier" lock
python3 - "$registry" << 'EOF'
import json, sys
lock = json.load(open("swiftpm-purifier.lock.json"))
[entry] = lock["artifacts"]
assert entry["path"] == "Packages/nix/greeter/1.0.0", entry
assert entry["archive"] == {"url": f"{sys.argv[1]}/nix/greeter/1.0.0.zip", "mirrors": [], "stripTop": True}, entry
EOF

# The Nix daemon fetches outside this process, where the registry on
# 127.0.0.1 may be out of reach. A fetch's store path depends only on its
# name and hash, so adding the archive under the entry's name does the
# fetch in advance, and the build still checks the hash the lock recorded.
nix store add-file --name 1.0.0.zip "$work/archives/nix.greeter-1.0.0.zip" > /dev/null

nix build --impure --out-link "$work/consumer-build" --expr "
  let
    flake = builtins.getFlake \"$repo\";
    pkgs = import flake.inputs.nixpkgs {
      system = builtins.currentSystem;
      overlays = [ flake.overlays.default ];
    };
  in
  (pkgs.buildSwiftPMProject { src = $work/consumer; }).packages.consumer
"
[ "$("$work/consumer-build/bin/consumer")" = "Greetings, Nix!" ] || fail "the Nix build of the consumer printed something else"

"$bin/swiftpm-purifier" install
kill "$registry_pid"
registry_pid=
[ "$("$bin/swift" run consumer)" = "Greetings, Nix!" ] || fail "swift run with the registry gone printed something else"

echo "all tests passed"
