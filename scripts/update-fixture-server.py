#!/usr/bin/env python3
"""Serve local Sparkle update fixtures for manual or automated testing.

Usage: python3 scripts/update-fixture-server.py [--port 8765] [--directory DIR]
       [--archive PATH --signature BASE64]

The server binds only to 127.0.0.1 and logs every request. Without --directory,
it creates a temporary fixture root for its lifetime. --archive and --signature
enable /valid.xml and /update.zip; they do not generate keys or contact a network.
"""

from __future__ import annotations

import argparse
import base64
from io import BytesIO
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import tempfile
from pathlib import Path
from urllib.parse import urlparse
from zipfile import ZIP_DEFLATED, ZipFile


WRONG_SIGNATURE = base64.b64encode(bytes(64)).decode("ascii")
SYNTHETIC_SIGNATURE = base64.b64encode(bytes(range(64))).decode("ascii")


def feed(version: str, url: str | None = None, length: int = 100,
         signature: str = SYNTHETIC_SIGNATURE) -> bytes:
    item = ""
    if version:
        enclosure = ""
        if url:
            enclosure = (
                f'<enclosure url="{url}" length="{length}" sparkle:version="{version}" '
                f'type="application/octet-stream" sparkle:edSignature="{signature}" />'
            )
        item = f'<item><title>Fixture update</title>{enclosure}</item>' if url else f'<item><title>Current version</title><sparkle:version>{version}</sparkle:version></item>'
    return (
        '<?xml version="1.0" encoding="utf-8"?>'
        '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
        f'<channel><title>Local update fixtures</title>{item}</channel></rss>'
    ).encode("utf-8")


class FixtureHandler(BaseHTTPRequestHandler):
    server_version = "SparkleFixture/1.0"

    def do_GET(self):
        path = urlparse(self.path).path
        if path in ("/current.xml", "/available.xml", "/download-failure.xml", "/invalid-signature.xml", "/valid.xml", "/malformed.xml"):
            if path == "/current.xml":
                body, status, content_type = feed("0", self._url("/current.zip"), self.server.current_archive.stat().st_size), 200, "application/rss+xml"
            elif path == "/available.xml":
                body, status, content_type = feed("9999", self._url("/missing.zip")), 200, "application/rss+xml"
            elif path == "/download-failure.xml":
                body, status, content_type = feed("9999", self._url("/missing.zip")), 200, "application/rss+xml"
            elif path == "/invalid-signature.xml":
                invalid_archive = self.server.invalid_archive
                body, status, content_type = feed("9999", self._url("/invalid.zip"), invalid_archive.stat().st_size, WRONG_SIGNATURE), 200, "application/rss+xml"
            elif path == "/valid.xml" and self.server.archive_path:
                archive = self.server.archive_path
                body, status, content_type = feed("9999", self._url("/update.zip"), archive.stat().st_size, self.server.signature), 200, "application/rss+xml"
            elif path == "/malformed.xml":
                body, status, content_type = b"<rss><channel><item>", 200, "application/rss+xml"
            else:
                body, status, content_type = b"Not Found", 404, "text/plain"
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if path == "/missing.zip":
            self.send_error(404, "fixture intentionally missing")
            return
        if path == "/invalid.zip":
            self._send_file(self.server.invalid_archive)
            return
        if path == "/current.zip":
            self._send_file(self.server.current_archive)
            return
        if path == "/update.zip" and self.server.archive_path:
            self._send_file(self.server.archive_path)
            return
        self.send_error(404)

    def _url(self, path: str) -> str:
        return "http://127.0.0.1:{}{}".format(self.server.server_port, path)

    def _send_file(self, path: Path):
        try:
            data = path.read_bytes()
        except OSError:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, format, *args):
        super().log_message(format, *args)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8765, help="loopback port (default: 8765; use 0 for an ephemeral port)")
    parser.add_argument("--directory", type=Path, help="fixture root; a temporary directory is used when omitted")
    parser.add_argument("--archive", type=Path, help="locally supplied archive to serve as /update.zip")
    parser.add_argument("--signature", help="base64 Ed25519 signature for --archive (required with --archive)")
    args = parser.parse_args()
    if bool(args.archive) != bool(args.signature):
        parser.error("--archive and --signature must be supplied together")
    temporary = tempfile.TemporaryDirectory(prefix="sparkle-fixtures-") if args.directory is None else None
    fixture_directory = args.directory or Path(temporary.name)
    fixture_directory.mkdir(parents=True, exist_ok=True)
    archive_data = BytesIO()
    with ZipFile(archive_data, "w", ZIP_DEFLATED) as archive:
        archive.writestr("fixture.txt", "valid ZIP payload; signature fixture intentionally mismatches\n")
    (fixture_directory / "invalid.zip").write_bytes(archive_data.getvalue())
    (fixture_directory / "current.zip").write_bytes(archive_data.getvalue())
    server = ThreadingHTTPServer(("127.0.0.1", args.port), FixtureHandler)
    server.fixture_directory = fixture_directory
    server.current_archive = fixture_directory / "current.zip"
    server.archive_path = args.archive.resolve() if args.archive else None
    server.invalid_archive = server.archive_path or (fixture_directory / "invalid.zip")
    server.signature = args.signature
    print(f"Serving Sparkle fixtures at http://127.0.0.1:{server.server_port}/", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        if temporary:
            temporary.cleanup()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
