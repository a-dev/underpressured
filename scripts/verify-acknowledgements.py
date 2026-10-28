#!/usr/bin/env python3
"""Verify acknowledgements against pinned, locally available dependency sources."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
NOTICE = ROOT / "Resources/Acknowledgements.txt"
LOCK = ROOT / "Underpressured.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
JPEGLI_COMMIT = "031a0077f5799a6041004267fc12b956c1f52a20"
SPARKLE_ARTIFACT_SHA256 = "17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959"


def fail(message: str) -> None:
    raise SystemExit(f"acknowledgements check failed: {message}")


def run(args: list[str], *, cwd: Path = ROOT) -> str:
    try:
        return subprocess.check_output(args, cwd=cwd, text=True, stderr=subprocess.PIPE)
    except subprocess.CalledProcessError as error:
        fail(error.stderr.strip() or f"command failed: {' '.join(args)}")


def sections() -> dict[str, str]:
    text = NOTICE.read_text(encoding="utf-8")
    chunks = re.split(r"\n\n\n===== (.*?) =====\n\n", text)
    if len(chunks) < 3 or (len(chunks) - 1) % 2:
        fail(f"cannot parse section headings in {NOTICE}")
    result = dict(zip(chunks[1::2], chunks[2::2]))
    if len(result) != len(chunks[1::2]):
        fail("duplicate acknowledgement section heading")
    return result


def same_text(actual: str, expected: str) -> bool:
    return actual.replace("\r\n", "\n").strip("\n") == expected.replace("\r\n", "\n").strip("\n")


def verify_license_file(acknowledgements: dict[str, str], heading: str, source: Path) -> None:
    if heading not in acknowledgements:
        fail(f"missing acknowledgement section: {heading}")
    if not source.is_file():
        fail(f"license source is missing: {source}")
    if not same_text(acknowledgements[heading], source.read_text(encoding="utf-8", errors="replace")):
        fail(f"bundled text does not match {source}")


def cargo_packages() -> dict[tuple[str, str], dict[str, str | None]]:
    metadata = json.loads(
        run(
            [
                "cargo", "metadata", "--offline", "--locked", "--manifest-path",
                "rust/up-codecs/Cargo.toml", "--format-version", "1",
                "--filter-platform", "aarch64-apple-darwin",
            ]
        )
    )
    metadata_by_key = {
        (package["name"], package["version"]): package for package in metadata["packages"]
    }
    tree = run(
        [
            "cargo", "tree", "--offline", "--locked", "--manifest-path",
            "rust/up-codecs/Cargo.toml", "--target", "aarch64-apple-darwin",
            "--edges", "normal", "--prefix", "none", "--format", "{p}",
        ]
    )
    resolved: dict[tuple[str, str], dict[str, str | None]] = {}
    for line in tree.splitlines():
        match = re.match(r"([^ ]+) v([^ ]+)", line.replace(" (*)", ""))
        if not match:
            continue
        key = match.groups()
        if key[0] == "up-codecs":
            continue
        package = metadata_by_key.get(key)
        if package is None:
            fail(f"cargo tree package is missing from metadata: {key[0]} {key[1]}")
        resolved[key] = package
    return resolved


def verify_cargo(acknowledgements: dict[str, str]) -> int:
    packages = cargo_packages()
    expected_headings = {
        f"{name} {version} ({package['license'] or 'See included license file'})"
        for (name, version), package in packages.items()
    }
    actual_headings = {
        heading for heading in acknowledgements
        if any(heading.startswith(f"{name} {version} (") for name, version in packages)
    }
    if actual_headings != expected_headings:
        fail(
            "Rust acknowledgement inventory differs from resolved macOS normal dependencies; "
            f"missing={sorted(expected_headings - actual_headings)}, "
            f"extra={sorted(actual_headings - expected_headings)}"
        )

    verified = 0
    for (name, version), package in sorted(packages.items()):
        heading = f"{name} {version} ({package['license'] or 'See included license file'})"
        manifest = Path(package["manifest_path"])
        source_root = manifest.parent
        preferred: list[Path] = []
        if package["license_file"]:
            preferred.append(Path(package["license_file"]))
        preferred.extend(
            path for path in source_root.iterdir()
            if path.is_file() and path.name.lower().startswith(("license", "copying"))
        )
        body = acknowledgements[heading]
        matched = [
            path for path in dict.fromkeys(preferred)
            if path.is_file() and same_text(body, path.read_text(encoding="utf-8", errors="replace"))
        ]
        if len(matched) != 1:
            fail(f"expected one exact source license match for {name} {version}; found {matched}")
        verified += 1
    libdeflate_sys = packages.get(("libdeflate-sys", "1.26.1"))
    if libdeflate_sys is None:
        fail("libdeflate-sys 1.26.1 is no longer in the resolved macOS graph")
    libdeflate_copying = Path(libdeflate_sys["manifest_path"]).parent / "libdeflate/COPYING"
    verify_license_file(
        acknowledgements,
        "libdeflate (bundled by libdeflate-sys 1.26.1)",
        libdeflate_copying,
    )
    print(f"Verified {verified} Rust license texts against offline Cargo metadata and source files.")
    print("Verified the nested libdeflate MIT license bundled by libdeflate-sys.")
    return verified


def verify_project_license(acknowledgements: dict[str, str]) -> None:
    verify_license_file(acknowledgements, "Underpressured", ROOT / "LICENSE")
    print("Verified the bundled project MIT license against LICENSE.")


def verify_native(acknowledgements: dict[str, str], jpegli_source: Path) -> None:
    build_script = (ROOT / "scripts/build-deps.sh").read_text(encoding="utf-8")
    pinned_commit = re.search(r"^JPEGLI_COMMIT=([0-9a-f]{40})$", build_script, re.MULTILINE)
    if pinned_commit is None or pinned_commit.group(1) != JPEGLI_COMMIT:
        fail("scripts/build-deps.sh jpegli commit differs from the checked license-source pin")
    actual_commit = run(["git", "rev-parse", "HEAD"], cwd=jpegli_source).strip()
    if actual_commit != JPEGLI_COMMIT:
        fail(f"jpegli checkout is {actual_commit}, expected {JPEGLI_COMMIT}")
    verify_license_file(
        acknowledgements,
        "jpegli (pinned source in scripts/build-deps.sh)",
        jpegli_source / "LICENSE",
    )
    verify_license_file(
        acknowledgements, "Highway (linked by jpegli)", jpegli_source / "third_party/highway/LICENSE"
    )
    verify_license_file(
        acknowledgements, "Little CMS (linked by jpegli)", jpegli_source / "third_party/lcms/LICENSE"
    )
    print(f"Verified jpegli and linked-library license texts at commit {actual_commit}.")


def sparkle_checkout(explicit: Path | None) -> Path | None:
    if explicit:
        return explicit
    candidates = sorted(
        (Path.home() / "Library/Developer/Xcode/DerivedData").glob(
            "*/SourcePackages/checkouts/Sparkle"
        )
    )
    return candidates[0] if len(candidates) == 1 else None


def verify_sparkle(acknowledgements: dict[str, str], source: Path) -> None:
    lock = json.loads(LOCK.read_text(encoding="utf-8"))
    pin = next((item for item in lock["pins"] if item["identity"] == "sparkle"), None)
    if pin is None or pin["state"]["version"] != "2.10.0":
        fail("Package.resolved does not pin Sparkle 2.10.0")
    revision = pin["state"]["revision"]
    actual_revision = run(["git", "rev-parse", "HEAD"], cwd=source).strip()
    if actual_revision != revision:
        fail(f"Sparkle checkout is {actual_revision}, expected {revision}")
    manifest = (source / "Package.swift").read_text(encoding="utf-8")
    if 'let version = "2.10.0"' not in manifest or SPARKLE_ARTIFACT_SHA256 not in manifest:
        fail("Sparkle Package.swift version or binary artifact checksum differs from the recorded pin")
    verify_license_file(acknowledgements, "Sparkle 2.10.0", source / "LICENSE")
    verify_license_file(
        acknowledgements,
        "ed25519-sparkle (vendored by Sparkle 2.10.0)",
        source / "Vendor/ed25519-sparkle/license.txt",
    )
    print(f"Verified Sparkle source license texts at revision {actual_revision}.")


def verify_app_bundle(app_bundle: Path) -> None:
    resources = app_bundle / "Contents/Resources/Acknowledgements.txt"
    if not resources.is_file() or not same_text(
        resources.read_text(encoding="utf-8"), NOTICE.read_text(encoding="utf-8")
    ):
        fail(f"app bundle does not contain the current acknowledgements text: {resources}")
    print(f"Verified current acknowledgements resource in {app_bundle}.")


def verify_sparkle_framework(acknowledgements: dict[str, str], app_bundle: Path) -> None:
    sparkle = app_bundle / "Contents/Frameworks/Sparkle.framework"
    if not sparkle.exists():
        fail(f"app bundle does not contain Sparkle.framework: {sparkle}")
    # The upstream Sparkle LICENSE is itself the inventory for the package's helper tools
    # and its separately licensed external components; keep these markers present.
    sparkle_text = acknowledgements["Sparkle 2.10.0"]
    for marker in ("bsdiff.c", "sais.c", "SUSignatureVerifier.m", "Portable C implementation of Ed25519"):
        if marker not in sparkle_text:
            fail(f"Sparkle acknowledgements omit upstream external-license entry: {marker}")
    print(f"Verified Sparkle.framework and its license coverage in {app_bundle}.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--jpegli-source", type=Path, default=ROOT / "Vendor/.build/jpegli",
        help="local source checkout created by scripts/build-deps.sh",
    )
    parser.add_argument(
        "--sparkle-source", type=Path,
        help="resolved Sparkle 2.10.0 checkout; auto-detected when exactly one exists in Xcode DerivedData",
    )
    parser.add_argument(
        "--skip-sparkle-check", action="store_true",
        help="verify Cargo and jpegli only when the locked Sparkle source checkout is unavailable",
    )
    parser.add_argument(
        "--app-bundle", type=Path,
        help="also check that a built app contains the current acknowledgements resource",
    )
    parser.add_argument(
        "--check-sparkle-framework", action="store_true",
        help="also require Sparkle.framework in --app-bundle and check its external-license entries",
    )
    args = parser.parse_args()
    acknowledgements = sections()
    verify_project_license(acknowledgements)
    verify_cargo(acknowledgements)
    verify_native(acknowledgements, args.jpegli_source)
    source = None if args.skip_sparkle_check else sparkle_checkout(args.sparkle_source)
    if source is None:
        if not args.skip_sparkle_check:
            fail("Sparkle checkout not found; pass --sparkle-source or explicitly use --skip-sparkle-check")
        print("Skipped Sparkle source verification.", file=sys.stderr)
    else:
        verify_sparkle(acknowledgements, source)
    if args.app_bundle:
        verify_app_bundle(args.app_bundle)
    if args.check_sparkle_framework:
        if not args.app_bundle:
            fail("--check-sparkle-framework requires --app-bundle")
        verify_sparkle_framework(acknowledgements, args.app_bundle)
    print("Acknowledgement checks passed.")


if __name__ == "__main__":
    main()
