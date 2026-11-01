# SPDX-License-Identifier: MIT
import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import swiftpm_purifier as sp


def checkout(identity, location, kind="remoteSourceControl"):
    return {
        "basedOn": None,
        "packageRef": {
            "identity": identity,
            "kind": kind,
            "location": location,
            "name": identity,
        },
        "state": {
            "checkoutState": {"revision": "a" * 40, "version": "1.0.0"},
            "name": "sourceControlCheckout",
        },
        "subpath": identity,
    }


class ManifestHash(unittest.TestCase):
    def test_matches_the_nix_formula(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Package.swift").write_text("// a\n")
            (root / "Package@swift-5.9.swift").write_text("// b\n")
            (root / "Other.swift").write_text("// ignored\n")
            listing = [
                ["Package.swift", hashlib.sha256(b"// a\n").hexdigest()],
                ["Package@swift-5.9.swift", hashlib.sha256(b"// b\n").hexdigest()],
            ]
            # builtins.toJSON writes no spaces.
            expected = hashlib.sha256(
                json.dumps(listing).replace(", ", ",").encode()
            ).hexdigest()
            self.assertEqual(sp.manifest_hash(root), expected)

    def test_resolved_hash_is_sri(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.assertIsNone(sp.resolved_hash(root))
            (root / "Package.resolved").write_text("{}")
            self.assertTrue(sp.resolved_hash(root).startswith("sha256-"))


class Template(unittest.TestCase):
    def test_replaces_the_package_directory(self):
        package = Path("/tmp/work/package")
        value = {
            "path": "/tmp/work/package/.build/artifacts/x",
            "list": ["/tmp/work/package"],
            "n": 1,
        }
        self.assertEqual(
            sp.template(value, package),
            {"path": "@root@/.build/artifacts/x", "list": ["@root@"], "n": 1},
        )


class LockDependency(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.package = Path(self.temporary.name) / "package"
        self.config = Path(self.temporary.name) / "config"
        self.package.mkdir()
        self.config.mkdir()

    def tearDown(self):
        self.temporary.cleanup()

    def test_remote_checkout_becomes_a_git_entry_and_an_edited_record(self):
        dependency = checkout(
            "swift-collections", "https://github.com/apple/swift-collections.git"
        )
        with mock.patch.object(sp, "prefetch_git", return_value="sha256-x") as prefetch:
            entry, record = sp.lock_dependency(dependency, self.package, self.config)
        prefetch.assert_called_once_with(
            "https://github.com/apple/swift-collections.git", "a" * 40
        )
        self.assertEqual(
            entry,
            {
                "path": "Packages/swift-collections",
                "git": {
                    "url": "https://github.com/apple/swift-collections.git",
                    "rev": "a" * 40,
                    "submodules": True,
                    "leaveDotGit": False,
                    "commitObject": None,
                },
                "hash": "sha256-x",
            },
        )
        self.assertEqual(record["state"], {"name": "edited", "path": None})
        self.assertEqual(record["basedOn"]["state"], dependency["state"])

    def test_a_mirror_is_fetched_in_place_of_the_original(self):
        mirrors = {
            "object": [
                {
                    "original": "https://a.example/x.git",
                    "mirror": "https://b.example/x.git",
                }
            ],
            "version": 1,
        }
        (self.config / "mirrors.json").write_text(json.dumps(mirrors))
        with mock.patch.object(sp, "prefetch_git", return_value="sha256-x"):
            entry, record = sp.lock_dependency(
                checkout("x", "https://a.example/x.git"), self.package, self.config
            )
        self.assertEqual(entry["git"]["url"], "https://b.example/x.git")
        self.assertEqual(record["packageRef"]["location"], "https://a.example/x.git")

    def test_a_path_dependency_is_part_of_the_source(self):
        dependency = {
            "basedOn": None,
            "packageRef": {
                "identity": "local",
                "kind": "fileSystem",
                "location": "/p/local",
                "name": "local",
            },
            "state": {"name": "fileSystem", "path": "/p/local"},
            "subpath": "local",
        }
        self.assertEqual(
            sp.lock_dependency(dependency, self.package, self.config),
            (None, dependency),
        )

    def test_a_local_repository_is_refused(self):
        dependency = checkout("local", "/home/someone/local", kind="localSourceControl")
        with self.assertRaises(sp.PurifierError):
            sp.lock_dependency(dependency, self.package, self.config)

    def test_a_registry_download_becomes_an_archive_entry(self):
        registries = {
            "registries": {"[default]": {"url": "https://registry.example/"}},
            "version": 1,
        }
        (self.config / "registries.json").write_text(json.dumps(registries))
        dependency = {
            "basedOn": None,
            "packageRef": {
                "identity": "nix.greeter",
                "kind": "registry",
                "location": "nix.greeter",
                "name": "nix.greeter",
            },
            "state": {"name": "registryDownload", "version": "1.2.0"},
            "subpath": "nix/greeter/1.2.0",
        }
        with mock.patch.object(
            sp, "prefetch_file", return_value="sha256-y"
        ) as prefetch:
            entry, record = sp.lock_dependency(dependency, self.package, self.config)
        prefetch.assert_called_once_with(
            "https://registry.example/nix/greeter/1.2.0.zip"
        )
        self.assertEqual(
            entry,
            {
                "path": "Packages/nix/greeter/1.2.0",
                "archive": {
                    "url": "https://registry.example/nix/greeter/1.2.0.zip",
                    "mirrors": [],
                    "stripTop": True,
                },
                "hash": "sha256-y",
            },
        )
        self.assertEqual(record["state"]["name"], "edited")


class LockArtifact(unittest.TestCase):
    def test_a_remote_binary_target_becomes_an_archive_entry(self):
        package = Path("/w/package")
        artifact = {
            "kind": "artifactsArchive",
            "packageRef": {"identity": "p"},
            "path": "/w/package/.build/artifacts/p/Tool/Tool.artifactbundle",
            "source": {
                "type": "remote",
                "url": "https://example/tool.zip",
                "checksum": "00" * 32,
            },
            "targetName": "Tool",
        }
        entry, record = sp.lock_artifact(artifact, package)
        self.assertEqual(entry["path"], ".build/artifacts/p/Tool")
        self.assertEqual(
            entry["archive"],
            {"url": "https://example/tool.zip", "mirrors": [], "stripTop": False},
        )
        self.assertEqual(entry["hash"], sp.sri_from_hex("00" * 32))
        self.assertIs(record, artifact)


if __name__ == "__main__":
    unittest.main()
