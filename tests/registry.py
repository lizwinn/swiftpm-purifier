# SPDX-License-Identifier: MIT
"""A stand-in SwiftPM package registry for tests/cli.sh.

It serves the endpoints SwiftPM reads to resolve and download a package
(SE-0292) from the source archives in a directory, named
<scope>.<name>-<version>.zip, and accepts publish requests (SE-0391) into
the same directory.

    python3 registry.py <directory> <port file>

It listens on a free port of 127.0.0.1 and writes the port to the port
file once it is ready.
"""

import email.parser
import email.policy
import hashlib
import json
import re
import sys
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

DIRECTORY = Path(sys.argv[1])
JSON = "application/json"


def archives(scope, name):
    pattern = re.compile(re.escape(f"{scope}.{name}-") + r"(.+)\.zip")
    found = {}
    for path in DIRECTORY.glob(f"{scope}.{name}-*.zip"):
        match = pattern.fullmatch(path.name)
        if match:
            found[match.group(1)] = path
    return found


def manifest(archive: Path) -> bytes:
    with zipfile.ZipFile(archive) as contents:
        for entry in contents.namelist():
            if re.fullmatch(r"[^/]+/Package\.swift", entry):
                return contents.read(entry)
    raise FileNotFoundError("Package.swift")


class Registry(BaseHTTPRequestHandler):
    def send(self, status, body=b"", content_type=JSON, headers=()):
        self.send_response(status)
        self.send_header("Content-Version", "1")
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for key, value in headers:
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def problem(self, status, detail):
        self.send(
            status, json.dumps({"detail": detail}).encode(), "application/problem+json"
        )

    def do_GET(self):
        path = self.path.split("?")[0]
        parts = [p for p in path.split("/") if p]
        if parts[:1] == ["identifiers"]:
            return self.problem(404, "no identifiers for URLs")
        if len(parts) == 2:
            scope, name = parts
            releases = archives(scope, name)
            if not releases:
                return self.problem(404, "no such package")
            base = f"http://{self.headers['Host']}/{scope}/{name}"
            body = {"releases": {v: {"url": f"{base}/{v}"} for v in releases}}
            return self.send(200, json.dumps(body).encode())
        if len(parts) == 3 and parts[2].endswith(".zip"):
            scope, name, file = parts
            archive = archives(scope, name).get(file[: -len(".zip")])
            if archive is None:
                return self.problem(404, "no such release")
            return self.send(200, archive.read_bytes(), "application/zip")
        if len(parts) == 3:
            scope, name, version = parts
            archive = archives(scope, name).get(version)
            if archive is None:
                return self.problem(404, "no such release")
            checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
            body = {
                "id": f"{scope}.{name}",
                "version": version,
                "resources": [
                    {
                        "name": "source-archive",
                        "type": "application/zip",
                        "checksum": checksum,
                    }
                ],
                "metadata": {},
            }
            return self.send(200, json.dumps(body).encode())
        if len(parts) == 4 and parts[3] == "Package.swift":
            scope, name, version, _ = parts
            archive = archives(scope, name).get(version)
            if archive is None:
                return self.problem(404, "no such release")
            return self.send(200, manifest(archive), "text/x-swift")
        return self.problem(404, "unknown endpoint")

    def do_PUT(self):
        parts = [p for p in self.path.split("?")[0].split("/") if p]
        if len(parts) != 3:
            return self.problem(404, "unknown endpoint")
        scope, name, version = parts
        if version in archives(scope, name):
            return self.problem(409, "release exists")
        length = int(self.headers["Content-Length"])
        head = f"Content-Type: {self.headers['Content-Type']}\r\n\r\n".encode()
        form = email.parser.BytesParser(policy=email.policy.HTTP).parsebytes(
            head + self.rfile.read(length)
        )
        fields = {
            part.get_param("name", header="content-disposition"): part
            for part in form.iter_parts()
        }
        if "source-archive" not in fields:
            return self.problem(422, "no source-archive")
        archive = fields["source-archive"].get_payload(decode=True)
        (DIRECTORY / f"{scope}.{name}-{version}.zip").write_bytes(archive)
        return self.send(201, b"{}")

    def log_message(self, *args):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Registry)
Path(sys.argv[2]).write_text(str(server.server_address[1]))
server.serve_forever()
