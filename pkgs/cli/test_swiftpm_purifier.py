# SPDX-License-Identifier: MIT
import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import swiftpm_purifier as sp


def pin(identity, location, kind="remoteSourceControl"):
    """A pin of Package.resolved."""
    return {
        "identity": identity,
        "kind": kind,
        "location": location,
        "state": {"revision": "a" * 40, "version": "1.0.0"},
    }


def checkout(identity, location, kind="remoteSourceControl", name=None):
    """SwiftPM's workspace-state record of a checked-out dependency."""
    return {
        "basedOn": None,
        "packageRef": {
            "identity": identity,
            "kind": kind,
            "location": location,
            "name": name or identity,
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


class IsCurrent(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        (self.root / "Package.swift").write_text("// a\n")
        self.pins = [pin("x", "https://example/x.git")]
        (self.root / "Package.resolved").write_text(
            json.dumps({"pins": self.pins, "version": 3})
        )
        self.lock = {
            "manifestHash": sp.manifest_hash(self.root),
            "pins": {"x": {"revision": "a" * 40}},
        }

    def tearDown(self):
        self.temporary.cleanup()

    def test_a_lock_covering_every_pin_is_current(self):
        self.assertTrue(sp.is_current(self.root, self.lock))

    def test_a_moved_pin_is_out_of_date(self):
        self.lock["pins"]["x"]["revision"] = "b" * 40
        self.assertFalse(sp.is_current(self.root, self.lock))

    def test_an_extra_pin_is_out_of_date(self):
        self.lock["pins"]["y"] = {"revision": "a" * 40}
        self.assertFalse(sp.is_current(self.root, self.lock))

    def test_a_lockfile_of_swiftpm_kept_outside_is_the_one_checked(self):
        outside = self.root / "outside.resolved"
        outside.write_text(json.dumps({"pins": [], "version": 3}))
        self.lock["pins"] = {}
        with mock.patch.object(sp, "TOOL_LOCK_OVERRIDE", str(outside)):
            self.assertEqual(sp.resolved_path(self.root), outside.resolve())
            self.assertTrue(sp.is_current(self.root, self.lock))
        self.assertFalse(sp.is_current(self.root, self.lock))

    def test_no_package_resolved_means_no_pins(self):
        (self.root / "Package.resolved").unlink()
        self.assertEqual(sp.resolved_pins(self.root / "Package.resolved"), [])
        self.lock["pins"] = {}
        self.assertTrue(sp.is_current(self.root, self.lock))


class ReadLock(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def write(self, text):
        (self.root / sp.LOCK_NAME).write_text(text)

    def assert_refused(self, *phrases):
        with self.assertRaises(sp.PurifierError) as caught:
            sp.read_lock(self.root)
        message = str(caught.exception)
        self.assertIn("swiftpm-purifier relock", message)
        for phrase in phrases:
            self.assertIn(phrase, message)

    def test_no_lockfile_is_none(self):
        self.assertIsNone(sp.read_lock(self.root))

    def test_invalid_json_names_the_relock(self):
        self.write("{ not json")
        self.assert_refused("not valid JSON")

    def test_a_missing_field_is_named(self):
        lock = {key: None for key in sp.LOCK_KEYS if key != "pins"}
        lock["version"] = sp.LOCK_VERSION
        self.write(json.dumps(lock))
        self.assert_refused("lacks pins")

    def test_another_format_version_is_refused(self):
        lock = {key: None for key in sp.LOCK_KEYS}
        lock["version"] = sp.LOCK_VERSION + 1
        self.write(json.dumps(lock))
        self.assert_refused("lock format version")

    def test_a_lockfile_changed_by_hand_is_refused(self):
        lock = {key: [] for key in sp.LOCK_KEYS}
        lock["version"] = sp.LOCK_VERSION
        lock["contentHash"] = sp.content_hash(lock)
        self.write(json.dumps(lock))
        self.assertEqual(sp.read_lock(self.root)["version"], sp.LOCK_VERSION)
        lock["pins"] = {"x": {"hash": "sha256-x"}}
        self.write(json.dumps(lock))
        self.assert_refused("contentHash")

    def test_lock_replaces_an_unreadable_lockfile(self):
        self.write("{ not json")
        with mock.patch.object(sp, "relock") as relock:
            sp.lock_command(self.root, force=False)
        relock.assert_called_once_with(self.root)


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


class LockPin(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.package = Path(self.temporary.name) / "package"
        self.config = Path(self.temporary.name) / "config"
        self.package.mkdir()
        self.config.mkdir()

    def tearDown(self):
        self.temporary.cleanup()

    def test_a_remote_pin_records_its_hash_and_package_name(self):
        url = "https://github.com/swiftlang/swift-cmark.git"
        with mock.patch.object(sp, "prefetch_git", return_value="sha256-x") as prefetch:
            locked = sp.lock_pin(
                pin("swift-cmark", url),
                checkout("swift-cmark", url, name="cmark-gfm"),
                self.package,
                self.config,
            )
        prefetch.assert_called_once_with(url, "a" * 40)
        self.assertEqual(
            locked, {"name": "cmark-gfm", "revision": "a" * 40, "hash": "sha256-x"}
        )

    def test_a_checkout_keeps_the_case_of_the_url(self):
        url = "https://github.com/jpsim/Yams.git"
        self.assertEqual(sp.subpath_of(pin("yams", url)), "Yams")
        self.assertEqual(sp.subpath_of(pin("x", "https://example/x/")), "x")

    def test_the_derived_record_is_swiftpms_record_marked_as_edited(self):
        url = "https://example/x.git"
        record = sp.record_of(pin("x", url), "x")
        self.assertEqual(record["basedOn"], checkout("x", url))
        self.assertEqual(record["state"], {"name": "edited", "path": None})

    def test_a_record_that_differs_from_the_derived_one_is_refused(self):
        dependency = checkout("x", "https://example/x.git")
        dependency["subpath"] = "elsewhere"
        with self.assertRaises(sp.PurifierError) as caught:
            sp.lock_pin(
                pin("x", "https://example/x.git"), dependency, self.package, self.config
            )
        self.assertIn("does not derive", str(caught.exception))

    def test_a_mirror_is_recorded_as_the_fetch_url(self):
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
        with mock.patch.object(sp, "prefetch_git", return_value="sha256-x") as prefetch:
            locked = sp.lock_pin(
                pin("x", "https://a.example/x.git"),
                checkout("x", "https://a.example/x.git"),
                self.package,
                self.config,
            )
        prefetch.assert_called_once_with("https://b.example/x.git", "a" * 40)
        self.assertEqual(locked["url"], "https://b.example/x.git")

    def test_a_local_repository_is_refused(self):
        with self.assertRaises(sp.PurifierError):
            sp.lock_pin(
                pin("local", "/home/someone/local", kind="localSourceControl"),
                checkout("local", "/home/someone/local", kind="localSourceControl"),
                self.package,
                self.config,
            )

    def test_a_registry_pin_records_its_archive_url(self):
        registries = {
            "registries": {"[default]": {"url": "https://registry.example/"}},
            "version": 1,
        }
        (self.config / "registries.json").write_text(json.dumps(registries))
        registry_pin = {
            "identity": "nix.greeter",
            "kind": "registry",
            "location": "",
            "state": {"version": "1.2.0"},
        }
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
            locked = sp.lock_pin(registry_pin, dependency, self.package, self.config)
        prefetch.assert_called_once_with(
            "https://registry.example/nix/greeter/1.2.0.zip"
        )
        self.assertEqual(
            locked,
            {
                "name": "nix.greeter",
                "version": "1.2.0",
                "url": "https://registry.example/nix/greeter/1.2.0.zip",
                "hash": "sha256-y",
            },
        )


class UnlockedWrapperTest(unittest.TestCase):
    def test_unlocked_delegation_preserves_arguments_streams_and_status(self):
        import json
        import os
        import subprocess
        import sys
        import tempfile
        from pathlib import Path

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            native = root / "native"
            native.write_text(
                "#!" + sys.executable + "\n"
                "import json, sys\n"
                "print(json.dumps(sys.argv[1:]))\n"
                "print('native stderr', file=sys.stderr)\n"
                "sys.exit(23)\n"
            )
            native.chmod(0o755)
            environment = dict(os.environ)
            environment["SWIFTPM_PURIFIER_SWIFT"] = str(native)
            pass
            arguments = ["build", "argument with spaces", "--example=a=b"]
            command = [
                sys.executable,
                str(Path(__file__).with_name("swiftpm_purifier.py")),
                *["swift"],
                *arguments,
            ]
            result = subprocess.run(
                command, cwd=root, env=environment, capture_output=True, text=True
            )
            self.assertEqual(result.returncode, 23, result.stderr)
            self.assertEqual(json.loads(result.stdout), arguments)
            self.assertIn("warning:", result.stderr)
            self.assertIn("impurely", result.stderr)
            self.assertIn("native stderr", result.stderr)
            self.assertEqual([p.name for p in root.iterdir()], ["native"])

            # An existing malformed lock must never use this fallback.
            for name, contents in {
                "Package.swift": "// swift-tools-version: 6.0\n"
            }.items():
                (root / name).write_text(contents)
            (root / "swiftpm-purifier.lock.json").write_text("{broken json")
            result = subprocess.run(
                command, cwd=root, env=environment, capture_output=True, text=True
            )
            self.assertNotEqual(result.returncode, 23)
            self.assertNotIn("native stderr", result.stderr)


if __name__ == "__main__":
    unittest.main()
