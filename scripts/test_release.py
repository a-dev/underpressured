#!/usr/bin/env python3
"""Unit tests for the local release pipeline; all inputs are temporary fixtures."""

import base64
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET


SCRIPT = Path(__file__).with_name("release.py")
SPEC = importlib.util.spec_from_file_location("release", SCRIPT)
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)
KEY = base64.b64encode(bytes(range(32))).decode()


def args(root, **overrides):
    d = Path(root)
    values = dict(
        history=d / "history.json", notes=d / "notes.html", output=d / "candidate",
        key_file=d / "private.key", sparkle_bin=d / "sparkle/bin",
        feed_url="https://updates.example.test/appcast.xml",
        download_url_prefix="https://downloads.example.test/releases/",
        public_key=KEY, identity="Developer ID Application: Example (ABCDE12345)",
        team="ABCDE12345", notary_profile="release-profile",
        acknowledgements_reviewed=True, dry_run=True,
    )
    values.update(overrides)
    return type("Args", (), values)()


def prereq_fixture(root):
    d = Path(root)
    a = args(d)
    a.history.write_text('{"published_builds": []}')
    a.notes.write_text("<html>Release notes</html>")
    a.key_file.write_bytes(b"fixture only")
    a.key_file.chmod(0o600)
    a.sparkle_bin.mkdir(parents=True)
    for name in ("sign_update", "generate_appcast"):
        p = a.sparkle_bin / name
        p.write_text("fixture")
        p.chmod(0o700)
    resources = a.sparkle_bin.parent / "Sparkle.xcframework/macos-arm64/ Sparkle.framework/Resources"
    resources.mkdir(parents=True)
    (resources / "Info.plist").write_bytes(plistlib.dumps({"CFBundleShortVersionString": "2.10.0"}))
    return a


def repository(root):
    path = Path(root) / "checkout"
    path.mkdir(exist_ok=True)
    return path


class ReleaseTests(unittest.TestCase):
    def test_versions_and_build_validation(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "version.xcconfig"
            p.write_text("MARKETING_VERSION = 1.2.3\nCURRENT_PROJECT_VERSION = 42\n")
            self.assertEqual(release.versions(p), ("1.2.3", "42"))
            for text, message in [
                ("MARKETING_VERSION = 1.2\nCURRENT_PROJECT_VERSION = 42\n", "marketing version"),
                ("MARKETING_VERSION = 1.2.3\nCURRENT_PROJECT_VERSION = 0\n", "build"),
                ("MARKETING_VERSION = 1.2.3\nCURRENT_PROJECT_VERSION = 42\nCURRENT_PROJECT_VERSION = 43\n", "expected one CURRENT_PROJECT_VERSION"),
            ]:
                p.write_text(text)
                with self.assertRaisesRegex(ValueError, message):
                    release.versions(p)

    def test_history_requires_valid_unique_and_increasing_builds(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "history.json"
            for value, build, message in [
                ({"published_builds": []}, "1", None),
                ({"published_builds": [1, 4]}, "5", None),
                ({}, "5", "requires published_builds"),
                ({"published_builds": [1, True]}, "5", "positive integers"),
                ({"published_builds": [2, 2]}, "5", "duplicate"),
                ({"published_builds": [5]}, "5", "must exceed"),
            ]:
                p.write_text(json.dumps(value))
                if message:
                    with self.assertRaisesRegex(ValueError, message):
                        release.history(p, build)
                else:
                    release.history(p, build)

    def test_urls_require_absolute_clean_https(self):
        for url in ("https://example.test/a",):
            release.https(url)
        for url in ("http://example.test", "/relative", "https://u:p@example.test", "https://example.test/?x=1", "https://example.test/#frag", "https://example.test/a b"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                release.https(url)

    def test_prerequisites_valid_dry_run_reads_only_and_checks_sparkle_pin(self):
        with tempfile.TemporaryDirectory() as d:
            a = prereq_fixture(d)
            with patch.object(release, "ROOT", repository(d)), patch.object(release, "run") as run:
                pinfile = repository(d) / "Underpressured.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
                pinfile.parent.mkdir(parents=True)
                pinfile.write_text('{"pins":[{"identity":"sparkle","state":{"version":"2.10.0"}}]}')
                release.prerequisites(a, "1")
                run.assert_not_called()
                self.assertFalse(a.output.exists())
                pinfile.write_text('{"pins":[{"identity":"sparkle","state":{"version":"2.11.0"}}]}')
                with self.assertRaisesRegex(ValueError, "Sparkle pin"):
                    release.prerequisites(a, "1")

    def test_prerequisites_reject_history_notes_urls_key_and_output(self):
        cases = [
            ("history", lambda a: a.history.write_text('{"published_builds":[2]}'), "must exceed"),
            ("notes", lambda a: a.notes.write_text(""), "nonempty HTML"),
            ("feed", lambda a: setattr(a, "feed_url", "http://bad.test"), "absolute HTTPS"),
            ("download", lambda a: setattr(a, "download_url_prefix", "https://x.test/?q=1"), "absolute HTTPS"),
            ("key bytes", lambda a: setattr(a, "public_key", base64.b64encode(b"short").decode()), "32 bytes"),
            ("key mode", lambda a: a.key_file.chmod(0o644), "permissions"),
            ("output exists", lambda a: a.output.mkdir(), "output must not exist"),
        ]
        for label, mutate, message in cases:
            with self.subTest(label=label), tempfile.TemporaryDirectory() as d:
                a = prereq_fixture(d)
                pinfile = repository(d) / "Underpressured.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
                pinfile.parent.mkdir(parents=True)
                pinfile.write_text('{"pins":[{"identity":"sparkle","state":{"version":"2.10.0"}}]}')
                mutate(a)
                with patch.object(release, "ROOT", repository(d)), self.assertRaisesRegex(ValueError, message):
                    release.prerequisites(a, "2")

    def test_real_prerequisites_stop_when_tool_missing(self):
        with tempfile.TemporaryDirectory() as d:
            a = prereq_fixture(d)
            a.dry_run = False
            pinfile = repository(d) / "Underpressured.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
            pinfile.parent.mkdir(parents=True)
            pinfile.write_text('{"pins":[{"identity":"sparkle","state":{"version":"2.10.0"}}]}')
            (repository(d) / "LICENSE").write_text("fixture license")
            with patch.object(release, "ROOT", repository(d)), patch.object(release, "run", return_value=""), patch.object(release.shutil, "which", return_value=None):
                with self.assertRaisesRegex(ValueError, "missing tool: xcodebuild"):
                    release.prerequisites(a, "1")

    def test_real_preflight_stops_for_license_ack_dirty_identity_profile_and_key_mismatch(self):
        cases = ("license", "ack", "dirty", "identity", "profile", "key")
        for case in cases:
            with self.subTest(case=case), tempfile.TemporaryDirectory() as d:
                base = Path(d)
                checkout = base / "checkout"
                checkout.mkdir()
                a = prereq_fixture(base)
                a.dry_run = False
                pins = checkout / "Underpressured.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
                pins.parent.mkdir(parents=True)
                pins.write_text('{"pins":[{"identity":"sparkle","state":{"version":"2.10.0"}}]}')
                (checkout / "LICENSE").write_text("fixture")
                a.acknowledgements_reviewed = True
                if case == "license":
                    (checkout / "LICENSE").unlink()
                elif case == "ack":
                    a.acknowledgements_reviewed = False
                elif case == "identity":
                    a.identity = "Mac Developer: Wrong"
                elif case == "profile":
                    a.notary_profile = "   "
                run_results = ["", "Xcode 27.0\nBuild version fixture", a.identity]
                if case == "dirty":
                    run_results[0] = " M dirty-file"
                elif case == "key":
                    run_results.extend(["history", "signature"])
                with patch.object(release, "ROOT", checkout), patch.object(release.shutil, "which", return_value="/fake/tool"), patch.object(release, "run", side_effect=run_results) as run, patch.object(release, "verify_public", side_effect=ValueError("public/private key mismatch")):
                    with self.assertRaises(ValueError):
                        release.prerequisites(a, "1")
                self.assertFalse(any("build-deps.sh" in str(call) for call in run.call_args_list))
                if case in ("license", "ack", "dirty", "identity", "profile"):
                    self.assertLessEqual(run.call_count, 1 if case in ("license", "ack", "dirty") else 0)
                else:
                    self.assertTrue(any("sign_update" in str(call) for call in run.call_args_list))

    def test_commands_encode_local_pipeline_and_release_metadata(self):
        with tempfile.TemporaryDirectory() as d:
            a = args(d)
            plan = release.commands(a, "1.2.3", "45")
            self.assertEqual(plan[0][:2], ["bash", release.ROOT / "scripts/build-deps.sh"])
            self.assertTrue(any("SPARKLE_FEED_URL=" + a.feed_url in map(str, cmd) for cmd in plan))
            self.assertTrue(any("SPARKLE_PUBLIC_ED_KEY=" + a.public_key in map(str, cmd) for cmd in plan))
            self.assertTrue(any("Underpressured-1.2.3-45.zip" in part for part in map(str, plan)))
            self.assertIn("--maximum-deltas", plan[-1])
            self.assertIn("--embed-release-notes", plan[-1])

    def test_execute_stops_at_first_failed_command_in_order(self):
        with tempfile.TemporaryDirectory() as d:
            a = args(d, dry_run=False)
            plan = [["first"], ["second"], ["third"]]
            seen = []
            def fake_run(cmd):
                seen.append(list(map(str, cmd)))
                if cmd == ["second"]:
                    raise subprocess.CalledProcessError(1, cmd, stderr="failed")
                return ""
            with patch.object(release, "run", side_effect=fake_run):
                with self.assertRaises(subprocess.CalledProcessError):
                    release.execute(a, "1.2.3", "1", plan)
            self.assertEqual(seen, [["first"], ["second"]])
            self.assertEqual(stat.S_IMODE(a.output.stat().st_mode), 0o700)

    def test_notary_rejection_stops_before_later_steps(self):
        with tempfile.TemporaryDirectory() as d:
            a = args(d, dry_run=False)
            plan = [["xcrun", "notarytool", "submit", "app.zip"], ["later"]]
            with patch.object(release, "run", return_value='{"status":"Invalid"}') as run:
                with self.assertRaisesRegex(ValueError, "notarization was not Accepted"):
                    release.execute(a, "1.2.3", "1", plan)
            self.assertEqual(run.call_count, 1)

    def test_execute_success_preserves_release_order_and_writes_hashes(self):
        with tempfile.TemporaryDirectory() as d:
            a = args(d, dry_run=False)
            a.notes.write_text("<html>Fixture release notes</html>")
            a.history.write_text('{"published_builds": []}')
            version, build = "1.2.3", "7"
            plan = release.commands(a, version, build)
            app = a.output / "export/Underpressured.app"
            zip_path = a.output / "updates/Underpressured-1.2.3-7.zip"
            dmg = a.output / "Underpressured-1.2.3-7.dmg"
            signature = base64.b64encode(bytes(64)).decode()
            archive_app = a.output / "updates/appcast.xml"
            archive = []

            def fake_run(cmd):
                command = list(map(str, cmd))
                archive.append(command)
                if command[:2] == ["xcodebuild", "-exportArchive"]:
                    app.mkdir(parents=True, exist_ok=True)
                if command[0] == "ditto" and command[1:4] == ["-c", "-k", "--sequesterRsrc"] and command[-1] == str(zip_path):
                    zip_path.write_bytes(b"fixture zip")
                elif command[0] == "hdiutil":
                    dmg.write_bytes(b"fixture dmg")
                elif command[0].endswith("generate_appcast"):
                    xml = f'''<rss xmlns:sparkle="{release.SPARKLE}"><channel><item><description>Notes</description><enclosure url="{a.download_url_prefix.rstrip('/')}/{zip_path.name}" length="{zip_path.stat().st_size}" sparkle:version="{build}" sparkle:shortVersionString="{version}" sparkle:edSignature="{signature}"/><sparkle:minimumSystemVersion>27.0</sparkle:minimumSystemVersion></item></channel></rss>'''
                    archive_app.write_text(xml)
                if command[:3] == ["xcrun", "notarytool", "submit"]:
                    return json.dumps({"status": "Accepted", "id": "fixture-id"})
                if command[:3] == ["xcrun", "notarytool", "log"]:
                    return '{"id":"fixture-id"}'
                return ""

            def manifest(path):
                return {"fixture": ("file", 0o644, "same")}

            signed = subprocess.CompletedProcess([], 0, "", "runtime Timestamp=now Authority=Developer ID Application: Fixture")
            with patch.object(release, "run", side_effect=fake_run), patch.object(release, "verify_app") as verify_app, patch.object(release, "tree_manifest", side_effect=manifest) as tree_manifest, patch.object(release.subprocess, "run", return_value=signed), patch.object(release, "verify_feed", wraps=release.verify_feed), patch.object(release, "verify_public"):
                release.execute(a, version, build, plan)

            labels = ["notarytool submit" if "notarytool" in c and "submit" in c else "staple app" if "stapler" in c and "staple" in c and ".app" in c[-1] else "update zip" if c[0] == "ditto" and c[-1] == str(zip_path) else "hdiutil" if c[0] == "hdiutil" else "generate_appcast" if c[0].endswith("generate_appcast") else "roundtrip" if c[0] == "ditto" and "-x" in c else "sign_update verify" if "--verify" in c else "command" for c in archive]
            self.assertLess(labels.index("notarytool submit"), labels.index("staple app"))
            self.assertLess(labels.index("staple app"), labels.index("update zip"))
            self.assertLess(labels.index("update zip"), labels.index("hdiutil"))
            self.assertLess(labels.index("roundtrip"), labels.index("generate_appcast"))
            self.assertTrue(verify_app.call_count >= 2)
            self.assertTrue(tree_manifest.called)
            hashes = json.loads((a.output / "SHA256.json").read_text())
            self.assertEqual(set(hashes), {"updates/Underpressured-1.2.3-7.zip", "Underpressured-1.2.3-7.dmg", "updates/appcast.xml"})
            self.assertEqual(len([c for c in archive if "notarytool" in c and "submit" in c]), 2)
            self.assertTrue((a.output / "published-history-input.json").is_file())
            metadata = json.loads((a.output / "publication.json").read_text())
            self.assertEqual(metadata, dict(version=version, build=int(build), feed_url=a.feed_url, download_url_prefix=a.download_url_prefix.rstrip("/"), public_key=a.public_key))
            self.assertTrue((a.output / "notarize-app.zip.notary-log.json").is_file())

    def test_dry_run_main_prints_plan_without_output_or_subprocess(self):
        with tempfile.TemporaryDirectory() as d:
            a = prereq_fixture(d)
            repo = repository(d)
            pinfile = repo / "Underpressured.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
            pinfile.parent.mkdir(parents=True)
            pinfile.write_text('{"pins":[{"identity":"sparkle","state":{"version":"2.10.0"}}]}')
            config = repo / "Config/Version.xcconfig"
            config.parent.mkdir(parents=True)
            config.write_text("MARKETING_VERSION = 1.2.3\nCURRENT_PROJECT_VERSION = 1\n")
            with patch.object(release, "ROOT", repo), patch.object(release, "run") as run, patch.object(release.sys, "argv", ["release.py", "--dry-run", "--history", str(a.history), "--notes", str(a.notes), "--output", str(a.output), "--key-file", str(a.key_file), "--sparkle-bin", str(a.sparkle_bin), "--feed-url", a.feed_url, "--download-url-prefix", a.download_url_prefix, "--public-key", a.public_key, "--identity", a.identity, "--team", a.team, "--notary-profile", a.notary_profile]):
                with patch("builtins.print") as printer:
                    self.assertEqual(release.main(), 0)
                run.assert_not_called()
                self.assertFalse(a.output.exists())
                self.assertTrue(any("DRY RUN" in str(call) for call in printer.call_args_list))

    def test_tree_manifest_checks_modes_bytes_and_symlinks(self):
        with tempfile.TemporaryDirectory() as d:
            app = Path(d) / "App.app"
            (app / "Contents/MacOS").mkdir(parents=True)
            exe = app / "Contents/MacOS/tool"
            exe.write_bytes(b"binary")
            exe.chmod(0o755)
            os.symlink("Contents/MacOS/tool", app / "tool-link")
            manifest = release.tree_manifest(app)
            self.assertEqual(manifest["Contents/MacOS/tool"][0:2], ("file", 0o755))
            self.assertEqual(manifest["tool-link"], ("link", "Contents/MacOS/tool"))
            exe.write_bytes(b"changed")
            self.assertNotEqual(release.tree_manifest(app), manifest)
            (app / "bad-link").symlink_to("/tmp/outside")
            with self.assertRaisesRegex(ValueError, "escaping or dangling"):
                release.tree_manifest(app)
            (app / "bad-link").unlink()
            exe.chmod(0o777)
            with self.assertRaisesRegex(ValueError, "writable"):
                release.tree_manifest(app)

    def test_verify_app_checks_metadata_executable_and_arm64(self):
        with tempfile.TemporaryDirectory() as d:
            app = Path(d) / "Underpressured.app"
            macos = app / "Contents/MacOS"
            macos.mkdir(parents=True)
            exe = macos / "Underpressured"
            exe.write_bytes(b"x")
            exe.chmod(0o755)
            info = dict(CFBundleExecutable="Underpressured", CFBundleShortVersionString="1.2.3", CFBundleVersion="7", LSMinimumSystemVersion="27.0", CFBundleIdentifier="app.underpressured.Underpressured", SUFeedURL="https://updates.test/feed", SUPublicEDKey=KEY)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
            signed = subprocess.CompletedProcess([], 0, "", "runtime Timestamp=x Authority=Developer ID Application: Test")
            with patch.object(release, "run", side_effect=["arm64", "runtime Timestamp=x Authority=Developer ID Application: Test", ""]), patch.object(release.subprocess, "run", return_value=signed):
                release.verify_app(app, "1.2.3", "7", info["SUFeedURL"], KEY)
            info["CFBundleVersion"] = "8"
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
            with self.assertRaisesRegex(ValueError, "wrong app CFBundleVersion"):
                release.verify_app(app, "1.2.3", "7", info["SUFeedURL"], KEY)

    def test_verify_feed_checks_metadata_signature_url_length_and_notes(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            archive = root / "App-1.2.3-4.zip"
            archive.write_bytes(b"zip data")
            signature = base64.b64encode(bytes(64)).decode()
            xml = f'''<rss xmlns:sparkle="{release.SPARKLE}"><channel><item><description>Notes</description><enclosure url="https://download.test/{archive.name}" length="{archive.stat().st_size}" sparkle:version="4" sparkle:shortVersionString="1.2.3" sparkle:edSignature="{signature}"/><sparkle:minimumSystemVersion>27.0</sparkle:minimumSystemVersion></item></channel></rss>'''
            feed = root / "appcast.xml"
            feed.write_text(xml)
            self.assertEqual(release.verify_feed(feed, archive, "1.2.3", "4", "https://download.test"), signature)
            feed.write_text(xml.replace("length=\"8\"", "length=\"9\""))
            with self.assertRaisesRegex(ValueError, "archive length"):
                release.verify_feed(feed, archive, "1.2.3", "4", "https://download.test")

            invalid = [
                (xml.replace('sparkle:version="4"', 'sparkle:version="3"'), "version mismatch"),
                (xml.replace('sparkle:shortVersionString="1.2.3"', 'sparkle:shortVersionString="1.2.4"'), "version mismatch"),
                (xml.replace("<sparkle:minimumSystemVersion>27.0", "<sparkle:minimumSystemVersion>26.0"), "minimum OS mismatch"),
                (xml.replace("</sparkle:minimumSystemVersion>", "</sparkle:minimumSystemVersion><sparkle:hardwareRequirements>x86_64</sparkle:hardwareRequirements>"), "architecture mismatch"),
                (xml.replace("https://download.test/", "https://other.test/"), "download URL mismatch"),
                (xml.replace(f'sparkle:edSignature="{signature}"', 'sparkle:edSignature="bad"'), "Only base64 data"),
                (xml.replace("<description>Notes</description>", ""), "missing release notes"),
            ]
            for invalid_xml, message in invalid:
                with self.subTest(message=message):
                    feed.write_text(invalid_xml)
                    with self.assertRaises(ValueError):
                        release.verify_feed(feed, archive, "1.2.3", "4", "https://download.test")


if __name__ == "__main__":
    unittest.main()
