#!/usr/bin/env python3
"""Focused tests for validate-direct-update-config.py."""

import base64
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("validate-direct-update-config.py")
KEY = base64.b64encode(bytes(range(32))).decode("ascii")


def run_validator(**overrides):
    env = os.environ.copy()
    for name in ("CONFIGURATION", "SPARKLE_FEED_URL", "SPARKLE_PUBLIC_ED_KEY", "SPARKLE_TEST_FEED"):
        env.pop(name, None)
    env.update(overrides)
    return subprocess.run([sys.executable, str(SCRIPT)], env=env, text=True, capture_output=True)


def run_with_plist(base_path, output_path, **overrides):
    env = os.environ.copy()
    for name in ("CONFIGURATION", "SPARKLE_FEED_URL", "SPARKLE_PUBLIC_ED_KEY", "SPARKLE_TEST_FEED"):
        env.pop(name, None)
    env.update(overrides)
    return subprocess.run([sys.executable, str(SCRIPT), str(output_path), str(base_path)], env=env, text=True, capture_output=True)


class ValidateDirectUpdateConfigTests(unittest.TestCase):
    def test_valid_release_configuration(self):
        result = run_validator(
            CONFIGURATION="Release",
            SPARKLE_FEED_URL="https://updates.example.com/appcast.xml",
            SPARKLE_PUBLIC_ED_KEY=KEY,
            SPARKLE_TEST_FEED="NO",
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_release_rejects_missing_and_invalid_inputs(self):
        cases = [
            ({"CONFIGURATION": "Release", "SPARKLE_PUBLIC_ED_KEY": KEY}, "SPARKLE_FEED_URL is required"),
            ({"CONFIGURATION": "Release", "SPARKLE_FEED_URL": "https://updates.example.com/feed"}, "SPARKLE_PUBLIC_ED_KEY is required"),
            ({"CONFIGURATION": "Release", "SPARKLE_FEED_URL": "http://updates.example.com/feed", "SPARKLE_PUBLIC_ED_KEY": KEY}, "must use HTTPS"),
            ({"CONFIGURATION": "Release", "SPARKLE_FEED_URL": "https://user:pass@example.com/feed", "SPARKLE_PUBLIC_ED_KEY": KEY}, "must not contain credentials"),
            ({"CONFIGURATION": "Release", "SPARKLE_FEED_URL": "https://example.com/feed?x=1", "SPARKLE_PUBLIC_ED_KEY": KEY}, "query or fragment"),
            ({"CONFIGURATION": "Release", "SPARKLE_FEED_URL": "https://example.com/feed?", "SPARKLE_PUBLIC_ED_KEY": KEY}, "query or fragment"),
            ({"CONFIGURATION": "Release", "SPARKLE_FEED_URL": "https://example.com/feed#", "SPARKLE_PUBLIC_ED_KEY": KEY}, "query or fragment"),
            ({"CONFIGURATION": "Release", "SPARKLE_FEED_URL": "https://localhost/feed", "SPARKLE_PUBLIC_ED_KEY": KEY}, "loopback host"),
            ({"CONFIGURATION": "Release", "SPARKLE_FEED_URL": "https://127.0.0.2/feed", "SPARKLE_PUBLIC_ED_KEY": KEY}, "loopback host"),
            ({"CONFIGURATION": "Release", "SPARKLE_FEED_URL": "https://127.1/feed", "SPARKLE_PUBLIC_ED_KEY": KEY}, "loopback host"),
            ({"CONFIGURATION": "Release", "SPARKLE_FEED_URL": "https://0177.0.0.1/feed", "SPARKLE_PUBLIC_ED_KEY": KEY}, "loopback host"),
            ({"CONFIGURATION": "Release", "SPARKLE_FEED_URL": "https://2130706433/feed", "SPARKLE_PUBLIC_ED_KEY": KEY}, "loopback host"),
            ({"CONFIGURATION": "Release", "SPARKLE_FEED_URL": "https://0x7f000001/feed", "SPARKLE_PUBLIC_ED_KEY": KEY}, "loopback host"),
            ({"CONFIGURATION": "Release", "SPARKLE_FEED_URL": "https://updates.localhost/feed", "SPARKLE_PUBLIC_ED_KEY": KEY}, "loopback host"),
            ({"CONFIGURATION": "Release", "SPARKLE_FEED_URL": "https://[::ffff:127.0.0.1]/feed", "SPARKLE_PUBLIC_ED_KEY": KEY}, "loopback host"),
            ({"CONFIGURATION": "Release", "SPARKLE_FEED_URL": "https://localHOST./feed", "SPARKLE_PUBLIC_ED_KEY": KEY}, "loopback host"),
            ({"CONFIGURATION": "Release", "SPARKLE_FEED_URL": "https://exam ple.com/feed", "SPARKLE_PUBLIC_ED_KEY": KEY}, "whitespace"),
            ({"CONFIGURATION": "Release", "SPARKLE_FEED_URL": "https://example.com/feed", "SPARKLE_PUBLIC_ED_KEY": KEY, "SPARKLE_TEST_FEED": "YES"}, "empty or NO in Release"),
            ({"CONFIGURATION": "Release", "SPARKLE_FEED_URL": "https://example.com/feed", "SPARKLE_PUBLIC_ED_KEY": "not-base64"}, "valid base64"),
            ({"CONFIGURATION": "Release", "SPARKLE_FEED_URL": "https://example.com/feed", "SPARKLE_PUBLIC_ED_KEY": base64.b64encode(b"short").decode()}, "exactly 32 bytes"),
        ]
        for values, message in cases:
            with self.subTest(values=values):
                result = run_validator(**values)
                self.assertEqual(result.returncode, 1)
                self.assertIn(message, result.stderr)

    def test_debug_defaults_are_safe(self):
        result = run_validator(CONFIGURATION="Debug")
        self.assertEqual(result.returncode, 0, result.stderr)
        for values in (
            {"SPARKLE_FEED_URL": "https://updates.example.com/feed"},
            {"SPARKLE_PUBLIC_ED_KEY": KEY},
            {"SPARKLE_FEED_URL": "https://updates.example.com/feed", "SPARKLE_PUBLIC_ED_KEY": KEY},
        ):
            with self.subTest(values=values):
                result = run_validator(CONFIGURATION="Debug", **values)
                self.assertEqual(result.returncode, 1)
                self.assertIn("Debug builds must leave", result.stderr)

    def test_explicit_debug_fixture_feed(self):
        for url in ("http://localhost:1234/appcast.xml", "https://127.0.0.1/feed", "http://[::1]:9000/feed"):
            with self.subTest(url=url):
                result = run_validator(
                    CONFIGURATION="Debug",
                    SPARKLE_TEST_FEED="YES",
                    SPARKLE_FEED_URL=url,
                    SPARKLE_PUBLIC_ED_KEY=KEY,
                )
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_fixture_opt_in_requires_loopback_and_key(self):
        for values, message in (
            ({"SPARKLE_FEED_URL": "https://updates.example.com/feed", "SPARKLE_PUBLIC_ED_KEY": KEY}, "requires a loopback host"),
            ({"SPARKLE_FEED_URL": "http://localhost/feed"}, "SPARKLE_PUBLIC_ED_KEY is required"),
            ({"SPARKLE_FEED_URL": "http://localhost/feed", "SPARKLE_PUBLIC_ED_KEY": KEY[:-2]}, "valid base64"),
        ):
            with self.subTest(values=values):
                result = run_validator(CONFIGURATION="Debug", SPARKLE_TEST_FEED="YES", **values)
                self.assertEqual(result.returncode, 1)
                self.assertIn(message, result.stderr)

    def test_generated_plists_keep_base_keys_and_set_mode_metadata(self):
        base = {"CFBundleDocumentTypes": [{"CFBundleTypeName": "Image"}], "SUFeedURL": "stale", "SUPublicEDKey": "stale"}
        with tempfile.TemporaryDirectory() as directory:
            base_path = Path(directory) / "Info.plist"
            base_path.write_bytes(plistlib.dumps(base))
            for configuration, extra, mode in (
                ("Debug", {}, "disabled"),
                ("Debug", {"SPARKLE_TEST_FEED": "YES", "SPARKLE_FEED_URL": "http://localhost/feed", "SPARKLE_PUBLIC_ED_KEY": KEY}, "fixture"),
                ("Release", {"SPARKLE_FEED_URL": "https://example.com/feed", "SPARKLE_PUBLIC_ED_KEY": KEY}, "release"),
            ):
                with self.subTest(configuration=configuration, mode=mode):
                    output_path = Path(directory) / f"{mode}.plist"
                    result = run_with_plist(base_path, output_path, CONFIGURATION=configuration, **extra)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    info = plistlib.loads(output_path.read_bytes())
                    self.assertEqual(info["CFBundleDocumentTypes"], base["CFBundleDocumentTypes"])
                    self.assertEqual(info["UPUpdateMode"], mode)
                    self.assertIs(info["SUAllowsAutomaticUpdates"], False)
                    if mode == "release":
                        self.assertNotIn("SUEnableAutomaticChecks", info)
                        self.assertEqual(info["SUFeedURL"], extra["SPARKLE_FEED_URL"])
                    elif mode == "fixture":
                        self.assertIs(info["SUEnableAutomaticChecks"], False)
                        self.assertEqual(info["SUPublicEDKey"], KEY)
                    else:
                        self.assertNotIn("SUFeedURL", info)
                        self.assertNotIn("SUPublicEDKey", info)
                        self.assertIs(info["SUEnableAutomaticChecks"], False)

    def test_validation_failure_does_not_create_output_plist(self):
        with tempfile.TemporaryDirectory() as directory:
            base_path = Path(directory) / "Info.plist"
            output_path = Path(directory) / "generated.plist"
            base_path.write_bytes(plistlib.dumps({"CFBundleDocumentTypes": []}))
            result = run_with_plist(base_path, output_path, CONFIGURATION="Debug", SPARKLE_FEED_URL="https://example.com/feed")
            self.assertEqual(result.returncode, 1)
            self.assertFalse(output_path.exists())

    def test_fixture_host_allowlist_is_exact(self):
        result = run_validator(
            CONFIGURATION="Debug", SPARKLE_TEST_FEED="YES",
            SPARKLE_FEED_URL="http://127.0.0.2/feed", SPARKLE_PUBLIC_ED_KEY=KEY,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("requires a loopback host", result.stderr)


if __name__ == "__main__":
    unittest.main()
