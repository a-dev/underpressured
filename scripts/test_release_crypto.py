#!/usr/bin/env python3
"""Exercise the pinned Sparkle signing tools against a temporary app fixture.

This test uses only temporary keys and files. It never accesses Keychain or
the release pipeline's output directories.
"""
import importlib.util
import base64
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPARKLE_BIN = Path(os.environ.get("UP_RELEASE_TEST_SPARKLE_BIN",
                                ROOT / "DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"))
APP = Path.home() / "Library/Developer/Xcode/DerivedData"
APP_RELATIVE = Path("Build/Products/Debug/Underpressured.app")
SPEC = importlib.util.spec_from_file_location("release", ROOT / "scripts/release.py")
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)

KEYGEN_SWIFT = r'''import CryptoKit
import Foundation
let seed = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
try seed.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
try key.publicKey.rawRepresentation.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
'''


def find_app():
    if "UP_RELEASE_TEST_APP" in os.environ:
        app = Path(os.environ["UP_RELEASE_TEST_APP"])
        return app if app.is_dir() else None
    local_app = ROOT / "DerivedData" / APP_RELATIVE
    if local_app.is_dir():
        return local_app
    if APP.is_dir():
        return next((p for p in APP.glob("*/" + str(APP_RELATIVE)) if p.is_dir()), None)
    return None


class ReleaseCryptoIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app_source = find_app()
        if cls.app_source is None:
            if "UP_RELEASE_TEST_APP" in os.environ:
                raise RuntimeError("Explicit release integration app is missing: " + os.environ["UP_RELEASE_TEST_APP"])
            raise unittest.SkipTest(
                "No development bundle at ~/Library/Developer/Xcode/DerivedData/*/"
                "Build/Products/Debug/Underpressured.app"
            )
        for tool in ("sign_update", "generate_appcast"):
            if not os.access(SPARKLE_BIN / tool, os.X_OK):
                if "UP_RELEASE_TEST_SPARKLE_BIN" in os.environ:
                    raise RuntimeError(f"Explicit pinned Sparkle tool is unavailable: {SPARKLE_BIN / tool}")
                raise unittest.SkipTest(f"Pinned Sparkle tool is unavailable: {SPARKLE_BIN / tool}")
        if not shutil.which("swift") or not shutil.which("ditto"):
            raise unittest.SkipTest("swift and ditto are required for this macOS integration test")

    def test_sparkle_archive_signature_matches_cryptokit_public_key(self):
        with tempfile.TemporaryDirectory(prefix="underpressured-release-crypto-") as temp:
            root = Path(temp)
            swift_env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(root / "module-cache"))
            seed_path, public_path = root / "seed", root / "public"
            generator = root / "generate-key.swift"
            generator.write_text(KEYGEN_SWIFT)
            subprocess.run(["swift", str(generator), str(seed_path), str(public_path)],
                           check=True, env=swift_env)
            seed, public = seed_path.read_bytes(), public_path.read_bytes()
            self.assertEqual(len(seed), 32)
            self.assertEqual(len(public), 32)

            app = root / "Underpressured.app"
            subprocess.run(["ditto", str(self.app_source), str(app)], check=True)
            info_path = app / "Contents/Info.plist"
            info = plistlib.loads(info_path.read_bytes())
            info.update({
                "CFBundleShortVersionString": "0.1.0",
                "CFBundleVersion": "1",
                "CFBundlePackageType": "APPL",
                "LSMinimumSystemVersion": "27.0",
                "SUFeedURL": "https://updates.invalid/appcast.xml",
                "SUPublicEDKey": base64.b64encode(public).decode("ascii"),
            })
            info_path.write_bytes(plistlib.dumps(info))
            # Editing Info.plist invalidates the copied development signature.
            # Re-sign locally so Sparkle sees a valid app bundle; '-' uses an
            # ad-hoc identity and does not consult Keychain.
            subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(app)], check=True)

            updates = root / "updates"
            updates.mkdir()
            archive = updates / "Underpressured-0.1.0-1.zip"
            subprocess.run([
                "ditto", "-c", "-k", "--sequesterRsrc", "--keepParent",
                str(app), str(archive),
            ], check=True)
            restored = root / "restored"
            subprocess.run(["ditto", "-x", "-k", str(archive), str(restored)], check=True)
            self.assertEqual(release.tree_manifest(app),
                             release.tree_manifest(restored / "Underpressured.app"))
            subprocess.run(["codesign", "--verify", "--deep", "--strict",
                            str(restored / "Underpressured.app")], check=True)
            archive.with_suffix(".html").write_text("<html><body>Test release</body></html>")

            key_file = root / "ed25519-private-key"
            # Sparkle's private key file contains the base64-encoded 32-byte seed.
            key_file.write_text(base64.b64encode(seed).decode("ascii") + "\n")
            key_file.chmod(0o600)
            signature_result = subprocess.run([
                str(SPARKLE_BIN / "sign_update"), "--ed-key-file", str(key_file),
                "-p", str(archive),
            ], capture_output=True, text=True)
            self.assertEqual(signature_result.returncode, 0,
                             signature_result.stdout + signature_result.stderr)
            direct_signature = signature_result.stdout.strip()
            self.assertEqual(len(base64.b64decode(direct_signature, validate=True)), 64)

            generated = subprocess.run([
                str(SPARKLE_BIN / "generate_appcast"),
                "--ed-key-file", str(key_file),
                "--download-url-prefix", "https://updates.invalid/downloads/",
                "--embed-release-notes", "--maximum-deltas", "0",
                "-o", str(updates / "appcast.xml"), str(updates),
            ], capture_output=True, text=True)
            self.assertEqual(generated.returncode, 0, generated.stdout + generated.stderr)

            feed = updates / "appcast.xml"
            signature = release.verify_feed(
                feed, archive, "0.1.0", "1", "https://updates.invalid/downloads"
            )
            public_b64 = base64.b64encode(public).decode("ascii")
            verifier = ROOT / "scripts/verify-release-signature.swift"
            subprocess.run(["swift", str(verifier), public_b64, str(archive), signature],
                           check=True, env=swift_env)
            self.assertEqual(signature, direct_signature)
            subprocess.run([
                str(SPARKLE_BIN / "sign_update"), "--ed-key-file", str(key_file),
                "--verify", str(archive), signature,
            ], check=True, capture_output=True, text=True)

            corrupted = root / "corrupted.zip"
            data = bytearray(archive.read_bytes())
            data[len(data) // 2] ^= 1
            corrupted.write_bytes(data)
            self.assertNotEqual(
                subprocess.run(["swift", str(verifier), public_b64, str(corrupted), signature],
                               capture_output=True, env=swift_env).returncode,
                0,
                "modified archive unexpectedly verified",
            )
            other_public = root / "other-public"
            # A different public key must reject the signature.
            other_public.write_bytes(bytes([public[0] ^ 1]) + public[1:])
            wrong_key_b64 = base64.b64encode(other_public.read_bytes()).decode("ascii")
            self.assertNotEqual(
                subprocess.run(["swift", str(verifier), wrong_key_b64, str(archive), signature],
                               capture_output=True, env=swift_env).returncode,
                0,
                "signature unexpectedly verified with a different public key",
            )


if __name__ == "__main__":
    unittest.main()
