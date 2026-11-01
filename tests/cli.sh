#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Tests what the flake's checks cannot run in the Nix sandbox, because it
# needs the network or runs Nix. Each section is a contract check that a CI
# job runs by name:
#
# - relock: a relock of each fixture reproduces its committed lockfile
#   (conformance-relock).
# - interactive: `swift` runs and tests on the locked dependencies; with a
#   stale lockfile it stops and names `swiftpm-purifier lock`;
#   `swiftpm-purifier uninstall` removes the links; `--lockfile` and
#   SWIFTPM_PURIFIER_LOCKFILE use a lockfile kept outside the package.
# - tampered: a lockfile whose hash of an entry was changed, and whose
#   contentHash was recomputed to match, fails the fetch with a hash
#   mismatch.
# - rebuild: `nix build --rebuild` of a fixture gives the same output
#   (conformance-rebuild).
# - offline: after `swiftpm-purifier prefetch`, `swift build`, `swift test`
#   and `swift run` work with no network (conformance-offline). The
#   commands run under `unshare -rn`, or under the command prefix in
#   SWIFTPM_PURIFIER_TEST_OFFLINE.
# - registry: a dependency from a package registry, against a stand-in
#   registry (tests/registry.py): `swiftpm-purifier publish` uploads a
#   package's source archive, a second package depends on it by registry
#   identity, its lock records the archive, Nix builds it, and `swift run`
#   runs it with the registry gone.
#
# Run it from anywhere: tests/cli.sh [section...]. Without arguments it
# runs every section.
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

# The Nix expression of the build of the package at $1, with the lockfile
# at $2 when one is given.
project() {
  echo "
    let
      flake = builtins.getFlake \"$repo\";
      pkgs = import flake.inputs.nixpkgs {
        system = builtins.currentSystem;
        overlays = [ flake.overlays.default ];
      };
    in
    flake.lib.swiftpm-purifier.buildSwiftPMProject {
      inherit pkgs;
      src = $1;
      ${2:+lockFile = $2;}
    }"
}

# A copy of a fixture under $work that the tests may change.
fixture() {
  cp -r "$tests/fixtures/$1" "$work/$2"
  chmod -R u+w "$work/$2"
}

nix build --out-link "$work/toolchain" "$repo#toolchain"
bin=$work/toolchain/bin

relock() {
  echo "== relocking the fixtures reproduces their lockfiles"
  mkdir -p "$work/relock"
  for name in hello paths binary macro; do
    fixture "$name" "relock/$name"
    (cd "$work/relock/$name" && "$bin/swiftpm-purifier" relock)
    diff -u "$tests/fixtures/$name/swiftpm-purifier.lock.json" "$work/relock/$name/swiftpm-purifier.lock.json" \
      || fail "relocking $name changed its lockfile"
  done
}

interactive() {
  echo "== swift runs and tests on the locked dependencies"
  fixture hello interactive
  cd "$work/interactive"
  [ "$("$bin/swift" run hello Nix Swift Nix)" = "$(printf 'Hello, Nix!\nHello, Swift!')" ] || fail "swift run printed something else"
  for dependency in swift-argument-parser swift-collections; do
    [ -L "Packages/$dependency" ] || fail "Packages/$dependency is not a link"
    case "$(readlink "Packages/$dependency")" in /nix/store/*) ;; *) fail "Packages/$dependency is not in the store" ;; esac
  done
  "$bin/swift" test > /dev/null || fail "swift test failed"

  echo "== a stale lockfile stops swift and names swiftpm-purifier lock"
  cp Package.resolved "$work/Package.resolved"
  echo >> Package.resolved
  if "$bin/swift" build 2> "$work/stale.err" > /dev/null; then
    fail "swift build ran with a stale lockfile"
  fi
  grep -q 'run `swiftpm-purifier lock`' "$work/stale.err" || fail "the stop does not name swiftpm-purifier lock: $(cat "$work/stale.err")"
  [ ! -e Packages/swift-collections ] || fail "the links stayed with a stale lockfile"
  cp "$work/Package.resolved" Package.resolved

  echo "== uninstall removes the links"
  "$bin/swiftpm-purifier" prefetch
  [ -L Packages/swift-collections ] || fail "prefetch made no links"
  "$bin/swiftpm-purifier" uninstall
  [ ! -e Packages/swift-collections ] || fail "uninstall left the links"
  [ ! -e .build/workspace-state.json ] || fail "uninstall left the workspace state"

  echo "== a lockfile kept outside the package"
  mkdir -p "$work/external"
  fixture hello external/hello
  rm "$work/external/hello/swiftpm-purifier.lock.json"
  cd "$work/external/hello"
  "$bin/swiftpm-purifier" --lockfile "$work/external/hello.lock.json" lock
  [ ! -e swiftpm-purifier.lock.json ] || fail "lock --lockfile wrote the lockfile into the package"
  diff -u "$tests/fixtures/hello/swiftpm-purifier.lock.json" "$work/external/hello.lock.json" \
    || fail "the lockfile kept outside differs from the fixture's lockfile"
  [ "$(SWIFTPM_PURIFIER_LOCKFILE="$work/external/hello.lock.json" "$bin/swift" run hello Nix)" = "Hello, Nix!" ] \
    || fail "swift run with SWIFTPM_PURIFIER_LOCKFILE printed something else"
  cd "$work"
}

tampered() {
  echo "== a tampered hash in the lockfile fails the fetch"
  fixture hello tampered
  python3 - "$work/tampered/swiftpm-purifier.lock.json" "$repo/pkgs/cli" << 'EOF'
import json, sys
sys.path.insert(0, sys.argv[2])
import swiftpm_purifier
path = sys.argv[1]
lock = json.load(open(path))
# Another valid SHA-256 hash: the fetch succeeds, and its content does not match.
lock["artifacts"][0]["hash"] = "sha256-" + "A" * 43 + "="
lock["contentHash"] = swiftpm_purifier.content_hash(lock)
open(path, "w").write(json.dumps(lock, indent=2, sort_keys=True) + "\n")
EOF
  if nix build --impure --no-link --expr "($(project "$work/tampered")).project" 2> "$work/tampered.err"; then
    fail "a build with a tampered hash succeeded"
  fi
  grep -q 'hash mismatch' "$work/tampered.err" || fail "a tampered hash failed without a hash mismatch: $(tail -5 "$work/tampered.err")"
}

rebuild() {
  echo "== a rebuild of a fixture gives the same output"
  nix build --impure --no-link --expr "($(project "$repo/tests/fixtures/hello")).project"
  nix build --impure --no-link --rebuild --expr "($(project "$repo/tests/fixtures/hello")).project" \
    || fail "a rebuild of the hello fixture gave another output"
}

offline() {
  echo "== after prefetch, the everyday loop works with no network"
  local -a without_network
  read -r -a without_network <<< "${SWIFTPM_PURIFIER_TEST_OFFLINE:-unshare -rn}"
  fixture hello offline
  cd "$work/offline"
  "$bin/swiftpm-purifier" prefetch
  "${without_network[@]}" "$bin/swift" build > /dev/null || fail "swift build failed with no network"
  "${without_network[@]}" "$bin/swift" test > /dev/null || fail "swift test failed with no network"
  [ "$("${without_network[@]}" "$bin/swift" run hello Nix)" = "Hello, Nix!" ] || fail "swift run with no network printed something else"
  cd "$work"
}

registry() {
  echo "== a dependency from a package registry"
  mkdir -p "$work/archives"
  python3 "$tests/registry.py" "$work/archives" "$work/port" &
  registry_pid=$!
  for _ in $(seq 50); do
    [ -s "$work/port" ] && break
    sleep 0.1
  done
  local url=http://127.0.0.1:$(cat "$work/port")

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
  (cd "$work/greeter" && "$bin/swiftpm-purifier" lock && "$bin/swiftpm-purifier" publish nix.greeter 1.0.0 --registry "$url")
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
  "registries": {"[default]": {"supportsAvailability": false, "url": "$url"}},
  "security": {"default": {"signing": {"onUnsigned": "silentAllow"}}},
  "version": 1
}
EOF
  cd "$work/consumer"
  "$bin/swiftpm-purifier" lock
  python3 - "$url" << 'EOF'
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

  nix build --impure --out-link "$work/consumer-build" --expr "($(project "$work/consumer")).packages.consumer"
  [ "$("$work/consumer-build/bin/consumer")" = "Greetings, Nix!" ] || fail "the Nix build of the consumer printed something else"

  "$bin/swiftpm-purifier" prefetch
  kill "$registry_pid"
  registry_pid=
  [ "$("$bin/swift" run consumer)" = "Greetings, Nix!" ] || fail "swift run with the registry gone printed something else"
  cd "$work"
}

sections=("$@")
if [ ${#sections[@]} -eq 0 ]; then
  sections=(relock interactive tampered rebuild offline registry)
fi
for section in "${sections[@]}"; do
  case "$section" in
    relock | interactive | tampered | rebuild | offline | registry) "$section" ;;
    *) fail "no section $section" ;;
  esac
done
echo "all tests passed: ${sections[*]}"
