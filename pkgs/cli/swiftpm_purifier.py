# SPDX-License-Identifier: MIT
"""swiftpm-purifier: Nix as the dependency backend of SwiftPM packages.

`swiftpm-purifier lock` resolves the package in a copy with an empty
SwiftPM cache, and records every dependency SwiftPM fetched in
swiftpm-purifier.lock.json, with its content hash. Nix then fetches the
locked dependencies and builds the package in its sandbox
(`buildSwiftPMProject`), and `swiftpm-purifier swift` runs SwiftPM on
them offline.
"""

import argparse
import base64
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
from pathlib import Path

LOCK_NAME = "swiftpm-purifier.lock.json"
LOCK_VERSION = 1
ROOT_PLACEHOLDER = "@root@"
MANIFEST_PATTERN = re.compile(r"Package(@swift-[0-9.]+)?\.swift")
# What the interactive mode keeps under .build: the Nix GC root of the
# realized tree, and a record of the links it made.
STATE_DIR = Path(".build") / "swiftpm-purifier"


class PurifierError(Exception):
    pass


def sri_sha256(digest: bytes) -> str:
    return "sha256-" + base64.b64encode(digest).decode()


def sri_from_hex(hex_digest: str) -> str:
    return sri_sha256(bytes.fromhex(hex_digest))


def file_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def manifest_hash(root: Path) -> str:
    """The hash of the package's manifests, as build-swiftpm-project.nix
    computes it: the SHA-256 of the JSON list of [name, hex SHA-256] of
    each manifest, in name order, written without spaces."""
    manifests = sorted(p.name for p in root.iterdir() if MANIFEST_PATTERN.fullmatch(p.name))
    listing = [[name, file_sha256(root / name)] for name in manifests]
    return hashlib.sha256(json.dumps(listing, separators=(",", ":")).encode()).hexdigest()


def resolved_hash(root: Path):
    resolved = root / "Package.resolved"
    if not resolved.exists():
        return None
    return sri_sha256(hashlib.sha256(resolved.read_bytes()).digest())


def is_current(root: Path, lock: dict) -> bool:
    return lock.get("resolvedHash") == resolved_hash(root) and lock.get("manifestHash") == manifest_hash(root)


def find_root(start: Path) -> Path:
    for directory in [start, *start.parents]:
        if (directory / "Package.swift").exists():
            return directory
    raise PurifierError(f"no Package.swift in {start} or above it")


def tool(name: str) -> str:
    """The path of a tool, from the variable the wrapper sets, or PATH."""
    return os.environ.get(f"SWIFTPM_PURIFIER_{name.upper().replace('-', '_')}") or name


def run(command, **kwargs):
    return subprocess.run([str(c) for c in command], check=True, **kwargs)


def output(command, **kwargs) -> str:
    return run(command, stdout=subprocess.PIPE, text=True, **kwargs).stdout


# The lock run.


def swiftpm_isolation(work: Path):
    """Flags that point SwiftPM's caches at empty directories in the lock
    run's directory. SwiftPM's configuration is a copy of the user
    configuration, so registries, mirrors and credentials still apply."""
    config = work / "config"
    user_config = Path.home() / ".swiftpm" / "configuration"
    if user_config.is_dir():
        shutil.copytree(user_config, config)
    else:
        config.mkdir()
    return [
        "--disable-dependency-cache",
        "--manifest-cache",
        "none",
        "--cache-path",
        work / "cache",
        "--config-path",
        config,
        "--security-path",
        work / "security",
    ]


def copy_package(root: Path, destination: Path):
    def ignore(directory, names):
        if Path(directory) == root:
            return [n for n in names if n in (".build", "Packages", ".git")]
        return [n for n in names if n == ".build"]

    shutil.copytree(root, destination, ignore=ignore, symlinks=True)


def read_json(path: Path):
    return json.loads(path.read_text()) if path.exists() else None


def mirrors(package: Path, config: Path) -> dict:
    """SwiftPM's mirrors, original URL to mirror URL. The package
    configuration wins over the user configuration, as in SwiftPM."""
    result = {}
    for source in (config / "mirrors.json", package / ".swiftpm" / "configuration" / "mirrors.json"):
        data = read_json(source) or {}
        for entry in data.get("object", []):
            result[entry["original"]] = entry["mirror"]
    return result


def registries(package: Path, config: Path) -> dict:
    """SwiftPM's registries: the default URL under "[default]", and one per
    scope. The package configuration wins over the user configuration."""
    result = {}
    for source in (config / "registries.json", package / ".swiftpm" / "configuration" / "registries.json"):
        data = read_json(source) or {}
        for scope, registry in data.get("registries", {}).items():
            result[scope] = registry["url"].rstrip("/")
    return result


def prefetch_git(url: str, rev: str) -> str:
    result = json.loads(
        output([tool("nix-prefetch-git"), "--quiet", "--fetch-submodules", "--url", url, "--rev", rev])
    )
    return result["hash"]


def prefetch_file(url: str) -> str:
    result = json.loads(output([tool("nix"), "store", "prefetch-file", "--hash-type", "sha256", "--json", url]))
    return result["hash"]


def lock_dependency(dependency, package: Path, config: Path):
    """The library entry for one dependency of SwiftPM's workspace state,
    and its record for the workspace-state template, or (None, record) for
    a dependency that is part of the package source."""
    ref = dependency["packageRef"]
    state = dependency["state"]
    subpath = dependency["subpath"]
    kind = ref["kind"]
    path = f"Packages/{subpath}"
    edited = {
        "basedOn": dict(dependency, basedOn=None),
        "packageRef": ref,
        "state": {"name": "edited", "path": None},
        "subpath": subpath,
    }
    if state["name"] == "fileSystem":
        return None, dependency
    if state["name"] == "sourceControlCheckout" and kind == "remoteSourceControl":
        url = mirrors(package, config).get(ref["location"], ref["location"])
        rev = state["checkoutState"]["revision"]
        entry = {
            "path": path,
            "git": {"url": url, "rev": rev, "submodules": True, "leaveDotGit": False},
            "hash": prefetch_git(url, rev),
        }
        return entry, edited
    if state["name"] == "sourceControlCheckout" and kind == "localSourceControl":
        raise PurifierError(
            f"{ref['identity']} is a git repository at {ref['location']} on this machine. "
            "A lockfile cannot name a repository that exists only on one machine, so a Nix "
            "build elsewhere could not fetch it. Depend on it by path (`.package(path:)`) "
            "inside the package, or by its remote URL."
        )
    if state["name"] == "registryDownload":
        identity = ref["identity"]
        scope, _, name = identity.partition(".")
        known = registries(package, config)
        registry = known.get(scope) or known.get("[default]")
        if registry is None:
            raise PurifierError(f"no registry is configured for {identity}")
        version = state["version"]
        url = f"{registry}/{urllib.parse.quote(scope)}/{urllib.parse.quote(name)}/{version}.zip"
        entry = {
            "path": path,
            "archive": {"url": url, "mirrors": [], "stripTop": True},
            "hash": prefetch_file(url),
        }
        return entry, edited
    raise PurifierError(f"{ref['identity']}: SwiftPM state {state['name']!r} of kind {kind!r} is not supported")


def lock_artifact(artifact, package: Path):
    """The library entry for one binary target of SwiftPM's workspace
    state, and its record, or (None, record) for a local binary target."""
    source = artifact["source"]
    if source["type"] != "remote":
        return None, artifact
    artifact_path = Path(artifact["path"])
    directory = artifact_path.parent.relative_to(package)
    entry = {
        "path": str(directory),
        "archive": {"url": source["url"], "mirrors": [], "stripTop": False},
        "hash": sri_from_hex(source["checksum"]),
    }
    return entry, artifact


def template(value, package: Path):
    """`value` with the lock run's package directory replaced by
    @root@ in every string."""
    prefixes = sorted({str(package), str(package.resolve())}, key=len, reverse=True)
    if isinstance(value, str):
        for prefix in prefixes:
            value = value.replace(prefix, ROOT_PLACEHOLDER)
        return value
    if isinstance(value, list):
        return [template(v, package) for v in value]
    if isinstance(value, dict):
        return {k: template(v, package) for k, v in value.items()}
    return value


def products(package: Path, env, isolation):
    description = json.loads(output([tool("swift"), "package", *isolation, "dump-package"], cwd=package, env=env))
    result = []
    for product in description["products"]:
        kind, detail = next(iter(product["type"].items()))
        entry = {"name": product["name"], "type": kind}
        if kind == "library":
            entry["linkage"] = detail[0] if detail else "automatic"
        result.append(entry)
    return result, description["name"]


def swift_version(env) -> str:
    match = re.search(r"Swift version (\S+)", output([tool("swift"), "--version"], env=env))
    return match.group(1) if match else "unknown"


def relock(root: Path):
    with tempfile.TemporaryDirectory(prefix="swiftpm-purifier-") as temporary:
        work = Path(temporary)
        package = work / "package"
        copy_package(root, package)
        env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(work / "clang-module-cache"))
        isolation = swiftpm_isolation(work)
        print("swiftpm-purifier: resolving with an empty cache", file=sys.stderr)
        run([tool("swift"), "package", *isolation, "resolve"], cwd=package, env=env)

        resolved = package / "Package.resolved"
        if resolved.exists():
            existing = root / "Package.resolved"
            if not existing.exists() or existing.read_bytes() != resolved.read_bytes():
                shutil.copyfile(resolved, existing)
                print("swiftpm-purifier: wrote Package.resolved", file=sys.stderr)

        state = json.loads((package / ".build" / "workspace-state.json").read_text())
        config = work / "config"
        artifacts, dependencies, binaries = [], [], []
        for dependency in state["object"]["dependencies"]:
            entry, record = lock_dependency(dependency, package, config)
            if entry:
                artifacts.append(entry)
            dependencies.append(record)
        for artifact in state["object"].get("artifacts", []):
            entry, record = lock_artifact(artifact, package)
            if entry:
                artifacts.append(entry)
            binaries.append(record)
        if state["object"].get("prebuilts"):
            raise PurifierError("SwiftPM downloaded prebuilt libraries, which swiftpm-purifier does not lock yet")

        package_products, package_name = products(package, env, isolation)
        lock = {
            "version": LOCK_VERSION,
            "package": package_name,
            "swiftVersion": swift_version(env),
            "resolvedHash": resolved_hash(root),
            "manifestHash": manifest_hash(root),
            "products": package_products,
            "workspaceState": template(
                {
                    "object": {"artifacts": binaries, "dependencies": dependencies, "prebuilts": []},
                    "version": state["version"],
                },
                package,
            ),
            "artifacts": sorted(artifacts, key=lambda a: a["path"]),
        }
    (root / LOCK_NAME).write_text(json.dumps(lock, indent=2, sort_keys=True) + "\n")
    print(f"swiftpm-purifier: wrote {LOCK_NAME} with {len(lock['artifacts'])} entries", file=sys.stderr)


def lock_command(root: Path, force: bool):
    lock = read_json(root / LOCK_NAME)
    if lock and not force and is_current(root, lock):
        print(f"swiftpm-purifier: {LOCK_NAME} is up to date", file=sys.stderr)
        return
    relock(root)


# Interactive mode.


def nix_lib() -> Path:
    return Path(os.environ.get("SWIFTPM_PURIFIER_NIX_LIB", Path(__file__).resolve().parent.parent / "nix" / "lib"))


def recorded_links(root: Path) -> list:
    record = read_json(root / STATE_DIR / "links.json")
    return record or []


def unlink(root: Path):
    """Removes the links and the workspace state the interactive mode made,
    so SwiftPM resolves and fetches the usual way."""
    for relative in recorded_links(root):
        link = root / relative
        if link.is_symlink():
            link.unlink()
    state = root / ".build" / "workspace-state.json"
    if (root / STATE_DIR / "links.json").exists() and state.exists():
        state.unlink()
    shutil.rmtree(root / STATE_DIR, ignore_errors=True)


def install(root: Path):
    """Realizes the locked dependencies through Nix and links them into the
    package, with the workspace state that marks them as edited."""
    lock_file = root / LOCK_NAME
    lock = json.loads(lock_file.read_text())
    unlink(root)
    (root / STATE_DIR).mkdir(parents=True, exist_ok=True)
    gc_root = root / STATE_DIR / "tree"
    run(
        [
            tool("nix-build"),
            nix_lib() / "realize.nix",
            "--argstr",
            "lockFile",
            lock_file.resolve(),
            "--arg",
            "nixpkgs",
            os.environ.get("SWIFTPM_PURIFIER_NIXPKGS", "<nixpkgs>"),
            "--out-link",
            gc_root,
        ],
        stdout=subprocess.DEVNULL,
    )
    tree = gc_root.resolve()
    links = []
    for entry in lock["artifacts"]:
        target = root / entry["path"]
        if target.exists() or target.is_symlink():
            if target.is_symlink() and str(os.readlink(target)).startswith("/nix/store/"):
                target.unlink()
            else:
                raise PurifierError(
                    f"{target} exists and is not a link swiftpm-purifier made; "
                    "move it away, or run SwiftPM without swiftpm-purifier"
                )
        target.parent.mkdir(parents=True, exist_ok=True)
        target.symlink_to(os.readlink(tree / entry["path"]))
        links.append(entry["path"])
    state = (tree / "workspace-state.json.in").read_text().replace(ROOT_PLACEHOLDER, str(root.resolve()))
    (root / ".build" / "workspace-state.json").write_text(state)
    (root / STATE_DIR / "links.json").write_text(json.dumps(links) + "\n")


def swift_command(arguments):
    swift = tool("swift")
    try:
        root = find_root(Path.cwd())
    except PurifierError:
        os.execvp(swift, [swift, *arguments])
    lock = read_json(root / LOCK_NAME)
    if lock is None:
        os.execvp(swift, [swift, *arguments])
    if is_current(root, lock):
        install(root)
    else:
        print(
            f"swiftpm-purifier: {LOCK_NAME} is out of date with Package.swift or Package.resolved; "
            "SwiftPM resolves the usual way until `swiftpm-purifier lock` renews it",
            file=sys.stderr,
        )
        unlink(root)
    os.execvp(swift, [swift, *arguments])


def main(argv=None):
    parser = argparse.ArgumentParser(prog="swiftpm-purifier", description=__doc__.splitlines()[0])
    parser.add_argument("--package-path", type=Path, help="the package root (default: found from the current directory)")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("lock", help="lock the package, unless its lockfile is up to date")
    commands.add_parser("relock", help="lock the package")
    commands.add_parser("install", help="link the locked dependencies into the package for SwiftPM")
    commands.add_parser("uninstall", help="remove the links install made")
    swift = commands.add_parser("swift", help="run swift on the locked dependencies")
    swift.add_argument("arguments", nargs=argparse.REMAINDER)
    options = parser.parse_args(argv)

    try:
        if options.command == "swift":
            swift_command(options.arguments)
        root = (options.package_path or find_root(Path.cwd())).resolve()
        if options.command == "lock":
            lock_command(root, force=False)
        elif options.command == "relock":
            lock_command(root, force=True)
        elif options.command == "install":
            install(root)
        elif options.command == "uninstall":
            unlink(root)
    except (PurifierError, subprocess.CalledProcessError) as error:
        print(f"swiftpm-purifier: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
