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
LOCK_VERSION = 3
# The lockfile `--lockfile` names, or for the `swift` verb
# SWIFTPM_PURIFIER_LOCKFILE; without either, the lockfile in the package.
LOCK_OVERRIDE = os.environ.get("SWIFTPM_PURIFIER_LOCKFILE")


def lock_path(root: Path) -> Path:
    return Path(LOCK_OVERRIDE).resolve() if LOCK_OVERRIDE else root / LOCK_NAME


def content_hash(lock: dict) -> str:
    """The hash of a lockfile without its contentHash, of the JSON that
    builtins.toJSON writes for it: keys in order and no spaces."""
    content = {key: value for key, value in lock.items() if key != "contentHash"}
    text = json.dumps(
        content, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    )
    return sri_sha256(hashlib.sha256(text.encode()).digest())


ROOT_PLACEHOLDER = "@root@"
MANIFEST_PATTERN = re.compile(r"Package(@swift-[0-9.]+)?\.swift")
# What the interactive mode keeps under .build: the Nix GC root of the
# realized tree, and a record of the links it made.
STATE_DIR = Path(".build") / "swiftpm-purifier"
# The scratch directories whose workspace state the interactive mode
# writes: the scratch directory of SwiftPM, and the one where sourcekit-lsp
# builds its background index, which keeps a workspace state of its own.
SCRATCH_DIRECTORIES = (Path(".build"), Path(".build") / "index-build")


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
    manifests = sorted(
        p.name for p in root.iterdir() if MANIFEST_PATTERN.fullmatch(p.name)
    )
    listing = [[name, file_sha256(root / name)] for name in manifests]
    return hashlib.sha256(
        json.dumps(listing, separators=(",", ":")).encode()
    ).hexdigest()


def resolved_hash(root: Path):
    resolved = root / "Package.resolved"
    if not resolved.exists():
        return None
    return sri_sha256(hashlib.sha256(resolved.read_bytes()).digest())


def is_current(root: Path, lock: dict) -> bool:
    return lock.get("resolvedHash") == resolved_hash(root) and lock.get(
        "manifestHash"
    ) == manifest_hash(root)


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


LOCK_KEYS = (
    "version",
    "package",
    "rootDirectory",
    "resolvedHash",
    "resolved",
    "manifestHash",
    "products",
    "workspaceState",
    "artifacts",
    "contentHash",
)


def read_lock(root: Path):
    """The package's lockfile, or None when it has none. A lockfile that is
    not valid JSON, lacks a field, or was changed after the lock run wrote
    it stops with the command that renews it."""
    path = lock_path(root)
    if not path.exists():
        return None
    try:
        lock = json.loads(path.read_text())
    except json.JSONDecodeError as error:
        raise PurifierError(
            f"{path} is not valid JSON ({error}); run `swiftpm-purifier relock` to write it again"
        )
    missing = (
        [key for key in LOCK_KEYS if key not in lock]
        if isinstance(lock, dict)
        else list(LOCK_KEYS)
    )
    if missing:
        raise PurifierError(
            f"{path} lacks {', '.join(missing)}; run `swiftpm-purifier relock` to write it again"
        )
    if lock["version"] != LOCK_VERSION:
        raise PurifierError(
            f"{path} has lock format version {lock['version']}, and this swiftpm-purifier reads "
            f"version {LOCK_VERSION}; run `swiftpm-purifier relock`"
        )
    if lock["contentHash"] != content_hash(lock):
        raise PurifierError(
            f"{path} does not match its contentHash, so it was changed after the lock run "
            "wrote it; run `swiftpm-purifier relock` to write it again"
        )
    return lock


def mirrors(package: Path, config: Path) -> dict:
    """SwiftPM's mirrors, original URL to mirror URL. The package
    configuration wins over the user configuration, as in SwiftPM."""
    result = {}
    for source in (
        config / "mirrors.json",
        package / ".swiftpm" / "configuration" / "mirrors.json",
    ):
        data = read_json(source) or {}
        for entry in data.get("object", []):
            result[entry["original"]] = entry["mirror"]
    return result


def registries(package: Path, config: Path) -> dict:
    """SwiftPM's registries: the default URL under "[default]", and one per
    scope. The package configuration wins over the user configuration."""
    result = {}
    for source in (
        config / "registries.json",
        package / ".swiftpm" / "configuration" / "registries.json",
    ):
        data = read_json(source) or {}
        for scope, registry in data.get("registries", {}).items():
            result[scope] = registry["url"].rstrip("/")
    return result


def prefetch_git(url: str, rev: str) -> str:
    result = json.loads(
        output(
            [
                tool("nix-prefetch-git"),
                "--quiet",
                "--fetch-submodules",
                "--url",
                url,
                "--rev",
                rev,
            ]
        )
    )
    return result["hash"]


def prefetch_file(url: str) -> str:
    result = json.loads(
        output(
            [
                tool("nix"),
                "store",
                "prefetch-file",
                "--hash-type",
                "sha256",
                "--json",
                url,
            ]
        )
    )
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
            # SwiftPM uses an edited dependency as a plain source tree, so
            # the checkout needs no .git.
            "git": {
                "url": url,
                "rev": rev,
                "submodules": True,
                "leaveDotGit": False,
                "commitObject": None,
            },
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
    raise PurifierError(
        f"{ref['identity']}: SwiftPM state {state['name']!r} of kind {kind!r} is not supported"
    )


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
    description = json.loads(
        output(
            [tool("swift"), "package", *isolation, "dump-package"], cwd=package, env=env
        )
    )
    result = []
    for product in description["products"]:
        kind, detail = next(iter(product["type"].items()))
        entry = {"name": product["name"], "type": kind}
        if kind == "library":
            entry["linkage"] = detail[0] if detail else "automatic"
        result.append(entry)
    return result, description["name"]


def swift_version(env) -> str:
    match = re.search(
        r"Swift version (\S+)", output([tool("swift"), "--version"], env=env)
    )
    return match.group(1) if match else "unknown"


def relock(root: Path):
    with tempfile.TemporaryDirectory(prefix="swiftpm-purifier-") as temporary:
        work = Path(temporary)
        # SwiftPM names the root package after its directory, and records
        # binary targets under that name, so the copy keeps the name.
        package = work / "packages" / root.name
        package.parent.mkdir()
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
            raise PurifierError(
                "SwiftPM downloaded prebuilt libraries, which swiftpm-purifier does not lock yet"
            )

        package_products, package_name = products(package, env, isolation)
        lock = {
            "version": LOCK_VERSION,
            "package": package_name,
            "rootDirectory": root.name,
            "swiftVersion": swift_version(env),
            "resolvedHash": resolved_hash(root),
            # Many packages do not commit Package.resolved, so the lock
            # carries it, and a build writes it when the source has none.
            "resolved": (root / "Package.resolved").read_text()
            if (root / "Package.resolved").exists()
            else None,
            "manifestHash": manifest_hash(root),
            "products": package_products,
            "workspaceState": template(
                {
                    "object": {
                        "artifacts": binaries,
                        "dependencies": dependencies,
                        "prebuilts": [],
                    },
                    "version": state["version"],
                },
                package,
            ),
            "artifacts": sorted(artifacts, key=lambda a: a["path"]),
        }
    lock["contentHash"] = content_hash(lock)
    path = lock_path(root)
    path.write_text(
        json.dumps(lock, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    )
    print(
        f"swiftpm-purifier: wrote {path} with {len(lock['artifacts'])} entries",
        file=sys.stderr,
    )


def lock_command(root: Path, force: bool):
    try:
        lock = read_lock(root)
    except PurifierError as error:
        # A lockfile that cannot be read is replaced.
        print(f"swiftpm-purifier: {error}", file=sys.stderr)
        lock = None
    if lock and not force and is_current(root, lock):
        print(f"swiftpm-purifier: {lock_path(root)} is up to date", file=sys.stderr)
        return
    relock(root)


# Publishing.


def multipart(fields):
    """A multipart/form-data body of (name, content type, bytes) fields."""
    boundary = "swiftpm-purifier-" + hashlib.sha256(os.urandom(16)).hexdigest()[:24]
    body = b""
    for name, content_type, data in fields:
        body += (
            f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="{name}"\r\n'
            f"Content-Type: {content_type}\r\n\r\n"
        ).encode()
        body += data + b"\r\n"
    body += f"--{boundary}--\r\n".encode()
    return f"multipart/form-data; boundary={boundary}", body


def publish(root: Path, identity: str, version: str, registry):
    """Builds the package's source archive through Nix and publishes it to
    a package registry (SE-0391), the archive the registry then serves to
    SwiftPM."""
    import urllib.request

    lock = read_lock(root)
    if lock is None or not is_current(root, lock):
        raise PurifierError(
            f"{lock_path(root)} is missing or out of date; run `swiftpm-purifier lock` first"
        )
    scope, dot, name = identity.partition(".")
    if not dot or not scope or not name:
        raise PurifierError(
            f"{identity} is not a registry identity of the form scope.name"
        )
    if registry is None:
        known = registries(root, Path.home() / ".swiftpm" / "configuration")
        registry = known.get(scope) or known.get("[default]")
        if registry is None:
            raise PurifierError(
                f"no registry is configured for {identity}; pass --registry"
            )
    archive = nix_build(
        """(purifier.buildSwiftPMProject {
          inherit pkgs;
          src = /. + builtins.getEnv "SWIFTPM_PURIFIER_ROOT";
          lockFile = /. + builtins.getEnv "SWIFTPM_PURIFIER_LOCK";
        }).release""",
        {
            "SWIFTPM_PURIFIER_ROOT": str(root),
            "SWIFTPM_PURIFIER_LOCK": str(lock_path(root)),
        },
    )
    content_type, body = multipart(
        [
            ("source-archive", "application/zip", Path(archive).read_bytes()),
            ("metadata", "application/json", b"{}"),
        ]
    )
    url = f"{registry.rstrip('/')}/{urllib.parse.quote(scope)}/{urllib.parse.quote(name)}/{version}"
    request = urllib.request.Request(url, data=body, method="PUT")
    request.add_header("Content-Type", content_type)
    request.add_header("Accept", "application/vnd.swift.registry.v1+json")
    token = os.environ.get("SWIFTPM_PURIFIER_REGISTRY_TOKEN")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(request) as response:
            print(
                f"swiftpm-purifier: published {identity} {version} to {registry} ({response.status})",
                file=sys.stderr,
            )
    except urllib.error.HTTPError as error:
        raise PurifierError(
            f"{url} answered {error.code}: {error.read().decode(errors='replace')}"
        )


# Interactive mode.


def nix_build(attribute: str, env: dict, out_link=None) -> str:
    """Builds `attribute`, an expression over `purifier` (the library of
    swiftpm-purifier's own flake, `lib.swiftpm-purifier`) and `pkgs` (its
    nixpkgs with its overlay), so prefetch and publishing use the builder
    and library a Nix build uses. `env` holds the values the expression
    reads with builtins.getEnv."""
    flake = os.environ.get(
        "SWIFTPM_PURIFIER_FLAKE", str(Path(__file__).resolve().parent.parent.parent)
    )
    expression = f"""
      let
        flake = builtins.getFlake "path:{flake}";
        purifier = flake.lib.swiftpm-purifier;
        pkgs = import flake.inputs.nixpkgs {{
          system = builtins.currentSystem;
          overlays = [ flake.overlays.default ];
        }};
      in
      {attribute}
    """
    command = [
        tool("nix"),
        "build",
        "--impure",
        "--print-out-paths",
        "--expr",
        expression,
    ]
    command += ["--out-link", out_link] if out_link else ["--no-link"]
    return output(command, env=dict(os.environ, **env)).strip()


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
    if (root / STATE_DIR / "links.json").exists():
        for scratch in SCRATCH_DIRECTORIES:
            state = root / scratch / "workspace-state.json"
            if state.exists():
                state.unlink()
    shutil.rmtree(root / STATE_DIR, ignore_errors=True)


def prefetch(root: Path):
    """Realizes, through Nix, everything day-to-day development needs: the
    locked dependencies and the toolchain with sourcekit-lsp, each kept by a
    GC root under .build/swiftpm-purifier. It links the dependencies into
    the package, with the workspace state that marks them as edited, so
    `swift build`, `swift test`, `swift run` and the editor work offline."""
    lock_file = lock_path(root)
    lock = read_lock(root)
    if lock is None:
        raise PurifierError(
            f"{root} has no {LOCK_NAME}; run `swiftpm-purifier lock` first"
        )
    if not is_current(root, lock):
        raise PurifierError(
            f"{lock_file} is out of date with Package.swift or Package.resolved; "
            "run `swiftpm-purifier lock`"
        )
    unlink(root)
    (root / STATE_DIR).mkdir(parents=True, exist_ok=True)
    gc_root = root / STATE_DIR / "tree"
    nix_build(
        'purifier.tree { inherit pkgs; lockFile = /. + builtins.getEnv "SWIFTPM_PURIFIER_LOCK"; }',
        {"SWIFTPM_PURIFIER_LOCK": str(lock_file)},
        out_link=gc_root,
    )
    nix_build(
        "pkgs.swiftpm-purifier.toolchain", {}, out_link=root / STATE_DIR / "toolchain"
    )
    tree = gc_root.resolve()
    links = []
    for entry in lock["artifacts"]:
        target = root / entry["path"]
        if target.exists() or target.is_symlink():
            if target.is_symlink() and str(os.readlink(target)).startswith(
                "/nix/store/"
            ):
                target.unlink()
            else:
                raise PurifierError(
                    f"{target} exists and is not a link swiftpm-purifier made; "
                    "move it away, or run SwiftPM without swiftpm-purifier"
                )
        target.parent.mkdir(parents=True, exist_ok=True)
        target.symlink_to(os.readlink(tree / entry["path"]))
        links.append(entry["path"])
    state = (
        (tree / "workspace-state.json.in")
        .read_text()
        .replace(ROOT_PLACEHOLDER, str(root.resolve()))
    )
    for scratch in SCRATCH_DIRECTORIES:
        (root / scratch).mkdir(parents=True, exist_ok=True)
        (root / scratch / "workspace-state.json").write_text(state)
    (root / STATE_DIR / "links.json").write_text(json.dumps(links) + "\n")


# The SwiftPM subcommands that build, and so would download prebuilt
# swift-syntax libraries for macros. The lock does not record prebuilts,
# so these build swift-syntax from source, as the sandboxed build does.
BUILDING_SUBCOMMANDS = ("build", "test", "run")


def swift_command(arguments):
    swift = tool("swift")
    if arguments and arguments[0] in BUILDING_SUBCOMMANDS:
        arguments = [arguments[0], "--disable-experimental-prebuilts", *arguments[1:]]
    try:
        root = find_root(Path.cwd())
    except PurifierError:
        os.execvp(swift, [swift, *arguments])
    lock = read_lock(root)
    if lock is None or arguments[:1] in ([], ["--version"], ["--help"]):
        os.execvp(swift, [swift, *arguments])
    if not is_current(root, lock):
        # SwiftPM would resolve and download what the lock does not hold.
        unlink(root)
        raise PurifierError(
            f"{lock_path(root)} is out of date with Package.swift or Package.resolved; "
            "run `swiftpm-purifier lock`, which resolves and records the new dependencies"
        )
    prefetch(root)
    os.execvp(swift, [swift, *arguments])


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    # Everything after `swift` belongs to SwiftPM, options included, so it
    # bypasses argparse.
    if argv[:1] == ["swift"]:
        try:
            swift_command(argv[1:])
        except (PurifierError, subprocess.CalledProcessError) as error:
            print(f"swiftpm-purifier: {error}", file=sys.stderr)
            return 1
    parser = argparse.ArgumentParser(
        prog="swiftpm-purifier", description=__doc__.splitlines()[0]
    )
    parser.add_argument(
        "--package-path",
        type=Path,
        help="the package root (default: found from the current directory)",
    )
    parser.add_argument(
        "--lockfile",
        type=Path,
        help=f"the purifier lockfile (default: {LOCK_NAME} in the package root)",
    )
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser(
        "lock", help="lock the package, unless its lockfile is up to date"
    )
    commands.add_parser("relock", help="lock the package")
    commands.add_parser(
        "prefetch",
        help="realize the locked dependencies and the toolchain, and link them into the package",
    )
    commands.add_parser("uninstall", help="remove the links prefetch made")
    publishing = commands.add_parser(
        "publish", help="publish the package's source archive to a registry"
    )
    publishing.add_argument(
        "identity", help="the package's registry identity, scope.name"
    )
    publishing.add_argument("version")
    publishing.add_argument(
        "--registry",
        help="the registry URL (default: the one configured for the scope)",
    )
    swift = commands.add_parser("swift", help="run swift on the locked dependencies")
    swift.add_argument("arguments", nargs=argparse.REMAINDER)
    options = parser.parse_args(argv)
    global LOCK_OVERRIDE
    if options.lockfile:
        LOCK_OVERRIDE = str(options.lockfile.resolve())

    try:
        if options.command == "swift":
            swift_command(options.arguments)
        root = (options.package_path or find_root(Path.cwd())).resolve()
        if options.command == "lock":
            lock_command(root, force=False)
        elif options.command == "relock":
            lock_command(root, force=True)
        elif options.command == "prefetch":
            prefetch(root)
        elif options.command == "uninstall":
            unlink(root)
        elif options.command == "publish":
            publish(root, options.identity, options.version, options.registry)
    except (PurifierError, subprocess.CalledProcessError) as error:
        print(f"swiftpm-purifier: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
