#!/usr/bin/env python3
"""Basic response checks for the loopback Sparkle fixture server."""

from pathlib import Path
from io import BytesIO
import re
import subprocess
import sys
import tempfile
import urllib.error
from urllib.request import urlopen
import unittest
from zipfile import ZIP_DEFLATED, ZipFile


SCRIPT = Path(__file__).with_name("update-fixture-server.py")


class UpdateFixtureServerTests(unittest.TestCase):
    def test_fixture_endpoints_and_optional_archive(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "valid.zip"
            archive_bytes = BytesIO()
            with ZipFile(archive_bytes, "w", ZIP_DEFLATED) as zip_file:
                zip_file.writestr("Contents/Info.plist", "fixture bundle metadata")
                zip_file.writestr("Contents/MacOS/Fixture", "fixture executable")
            archive.write_bytes(archive_bytes.getvalue())
            process = subprocess.Popen(
                [sys.executable, str(SCRIPT), "--port", "0", "--directory", directory,
                 "--archive", str(archive), "--signature", "fixture-signature"],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            )
            try:
                line = process.stdout.readline()
                match = re.search(r"127\.0\.0\.1:(\d+)", line)
                self.assertIsNotNone(match, line)
                base = f"http://127.0.0.1:{match.group(1)}"
                def get(path):
                    with urlopen(base + path, timeout=2) as response:
                        return response.status, response.headers, response.read()

                status, _, current = get("/current.xml")
                self.assertEqual(status, 200)
                self.assertIn(("url=\"" + base + "/current.zip\"").encode(), current)
                self.assertIn(b"sparkle:version=\"0\"", current)
                self.assertEqual(get("/current.zip")[0], 200)
                status, _, available = get("/available.xml")
                self.assertEqual(status, 200)
                self.assertIn(("url=\"" + base + "/missing.zip\" length=\"100\" sparkle:version=\"9999\"").encode(), available)
                self.assertIn(b"sparkle:edSignature=", available)
                status, _, invalid = get("/invalid-signature.xml")
                self.assertEqual(status, 200)
                self.assertIn(("url=\"" + base + "/invalid.zip\"").encode(), invalid)
                self.assertIn(("length=\"{}\"".format(archive.stat().st_size)).encode(), invalid)
                status, headers, invalid_zip = get("/invalid.zip")
                self.assertEqual(status, 200)
                self.assertEqual(int(headers["Content-Length"]), len(invalid_zip))
                self.assertEqual(invalid_zip, archive.read_bytes())
                self.assertEqual(get("/valid.xml")[0], 200)
                self.assertEqual(get("/update.zip")[2], archive.read_bytes())
                try:
                    urlopen(base + "/missing.zip", timeout=2)
                    self.fail("missing archive unexpectedly returned a response")
                except urllib.error.HTTPError as missing:
                    self.assertEqual(missing.code, 404)
                    missing.close()
                # The failure feed is valid; its referenced archive is the 404.
                status, _, failure_feed = get("/download-failure.xml")
                self.assertEqual(status, 200)
                self.assertIn((base + "/missing.zip").encode(), failure_feed)
                status, _, malformed = get("/malformed.xml")
                self.assertEqual(status, 200)
                self.assertEqual(malformed, b"<rss><channel><item>")
            finally:
                process.terminate()
                process.wait(timeout=3)
                process.stdout.close()
                process.stderr.close()


if __name__ == "__main__":
    unittest.main()
