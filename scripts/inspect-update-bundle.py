#!/usr/bin/env python3
"""Inspect a built app bundle for Sparkle inclusion, metadata, and signing.

Usage: inspect-update-bundle.py MODE APP_PATH, where MODE is disabled,
fixture, release, or updater-free. The script uses macOS `file`, `otool`,
`nm`, `plutil`, and `codesign` tools. It performs no network access.
"""

import plistlib
import re
import subprocess
import sys
from pathlib import Path


class InspectionError(Exception):
    pass


def command(args, *, required=True):
    result = subprocess.run(args, text=True, capture_output=True)
    if required and result.returncode != 0:
        raise InspectionError(f"{args[0]} failed for {args[-1]}: {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout + result.stderr


def read_plist(path: Path):
    try:
        with path.open("rb") as file:
            value = plistlib.load(file)
    except (OSError, plistlib.InvalidFileException) as error:
        raise InspectionError(f"Cannot read plist {path}: {error}") from error
    if not isinstance(value, dict):
        raise InspectionError(f"Expected a plist dictionary at {path}")
    return value


def ensure(condition, message):
    if not condition:
        raise InspectionError(message)


def inspect_entitlements(app: Path, mode: str):
    result = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(app)], text=True, capture_output=True)
    if result.returncode != 0:
        raise InspectionError(f"codesign could not read entitlements for {app}: {result.stderr.strip() or result.stdout.strip()}")
    combined = result.stdout + result.stderr
    start = combined.find("<plist")
    entitlements = {}
    if start >= 0:
        try:
            xml = combined[start:]
            xml = re.sub(r"<!DOCTYPE[^>]*>", "", xml, flags=re.DOTALL)
            xml = xml[:xml.find("</plist>") + len("</plist>")]
            entitlements = plistlib.loads(xml.encode())
        except plistlib.InvalidFileException as error:
            raise InspectionError(f"Cannot parse codesign entitlements for {app}: {error}") from error
    disable_library_validation = entitlements.get("com.apple.security.cs.disable-library-validation") is True
    if mode in ("disabled", "fixture"):
        ensure(disable_library_validation, f"{mode} direct bundle must carry disable-library-validation entitlement")
    elif mode == "release":
        ensure(not disable_library_validation, "release direct bundle must not disable library validation")
    return "present" if disable_library_validation else "absent"


def inspect_macho(app: Path):
    binaries = []
    seen = set()
    for path in app.rglob("*"):
        if not path.is_file() or path.resolve() in seen:
            continue
        seen.add(path.resolve())
        description = command(["file", str(path)], required=False)
        if "Mach-O" in description:
            binaries.append(path)
    linked = {}
    symbol_hits = []
    for binary in binaries:
        linkage = command(["otool", "-L", str(binary)], required=False)
        linked[binary] = linkage
        symbols = command(["nm", "-g", str(binary)], required=False)
        if re.search(r"sparkle|SPUUpdater|SUUpdater", symbols, re.IGNORECASE):
            symbol_hits.append(binary)
    return binaries, linked, symbol_hits


def inspect(mode: str, app: Path):
    ensure(mode in ("disabled", "fixture", "release", "updater-free"), f"Unsupported MODE '{mode}'")
    ensure(app.is_dir() and app.suffix == ".app", f"APP_PATH must be an existing .app bundle: {app}")
    info_path = app / "Contents/Info.plist"
    info = read_plist(info_path)
    sparkle_frameworks = [path for path in app.rglob("Sparkle.framework") if path.is_dir()]
    sparkle_named = [path for path in app.rglob("*") if "sparkle" in path.name.lower()]
    helpers = {name: [path for path in app.rglob(name) if path.exists()]
               for name in ("Downloader.xpc", "Installer.xpc", "Autoupdate", "Updater.app")}
    binaries, links, symbol_hits = inspect_macho(app)
    linked_sparkle = [binary for binary, output in links.items() if "Sparkle.framework" in output or re.search(r"\bSparkle\b", output)]
    app_executables = [binary for binary in binaries if binary.parent == app / "Contents/MacOS"]
    ensure(app_executables, "No Mach-O executable or debug dylib found in Contents/MacOS")

    if mode == "updater-free":
        ensure(not sparkle_named, "updater-free bundle contains Sparkle-named files: " + ", ".join(map(str, sparkle_named[:5])))
        ensure(not any(helpers.values()), "updater-free bundle contains Sparkle helpers: " + ", ".join(str(p) for group in helpers.values() for p in group))
        plist_paths = list(app.rglob("*.plist"))
        updater_metadata = []
        for plist_path in plist_paths:
            plist = read_plist(plist_path)
            keys = [key for key in plist if key.startswith("SU") or key == "UPUpdateMode"]
            if keys:
                updater_metadata.append(f"{plist_path}: {', '.join(keys)}")
        ensure(not updater_metadata, "updater-free bundle contains updater metadata: " + "; ".join(updater_metadata[:5]))
        ensure(not linked_sparkle, "updater-free Mach-O binary links Sparkle: " + ", ".join(map(str, linked_sparkle)))
        ensure(not symbol_hits, "updater-free Mach-O binary contains Sparkle symbols: " + ", ".join(map(str, symbol_hits)))
        command(["codesign", "--verify", "--deep", "--strict", str(app)])
        return {"binaries": binaries, "frameworks": 0, "helpers": 0, "entitlements": "not required"}

    ensure(len(sparkle_frameworks) == 1, f"Expected one embedded Sparkle.framework; found {len(sparkle_frameworks)}")
    framework = sparkle_frameworks[0]
    candidates = [framework / "Versions/Current/Resources/Info.plist", framework / "Resources/Info.plist", framework / "Info.plist"]
    framework_info_path = next((candidate for candidate in candidates if candidate.is_file()), None)
    ensure(framework_info_path is not None, "Cannot find Sparkle.framework Info.plist")
    framework_info = read_plist(framework_info_path)
    ensure(framework_info.get("CFBundleShortVersionString") == "2.10.0", "Embedded Sparkle.framework version must be 2.10.0")
    ensure(all(helpers[name] for name in helpers), "Sparkle framework is missing expected helpers: " + ", ".join(name for name, values in helpers.items() if not values))
    app_linked_sparkle = [binary for binary in app_executables if binary in linked_sparkle]
    ensure(app_linked_sparkle, "No app executable or debug dylib in Contents/MacOS links Sparkle.framework/Sparkle")
    ensure(info.get("SUAllowsAutomaticUpdates") is False, "direct bundle must set SUAllowsAutomaticUpdates to false")
    ensure(info.get("UPUpdateMode") == mode, f"UPUpdateMode must be {mode!r}")
    if mode == "release":
        ensure(isinstance(info.get("SUFeedURL"), str) and info["SUFeedURL"].startswith("https://"), "release bundle must contain an HTTPS SUFeedURL")
        ensure(isinstance(info.get("SUPublicEDKey"), str) and bool(info["SUPublicEDKey"]), "release bundle must contain SUPublicEDKey")
        ensure("SUEnableAutomaticChecks" not in info, "release bundle must omit SUEnableAutomaticChecks to preserve Sparkle consent")
    elif mode == "fixture":
        ensure(info.get("SUEnableAutomaticChecks") is False, "fixture bundle must disable scheduled checks")
        ensure(isinstance(info.get("SUFeedURL"), str) and bool(info["SUFeedURL"]), "fixture bundle must contain SUFeedURL")
        ensure(isinstance(info.get("SUPublicEDKey"), str) and bool(info["SUPublicEDKey"]), "fixture bundle must contain SUPublicEDKey")
    else:
        ensure(info.get("SUEnableAutomaticChecks") is False, "disabled bundle must disable scheduled checks")
        ensure("SUFeedURL" not in info and "SUPublicEDKey" not in info, "disabled bundle must omit feed and key metadata")
    entitlement_state = inspect_entitlements(app, mode)
    command(["codesign", "--verify", "--deep", "--strict", str(app)])
    return {"binaries": binaries, "frameworks": len(sparkle_frameworks), "helpers": sum(bool(v) for v in helpers.values()), "entitlements": entitlement_state}


def main():
    if len(sys.argv) != 3:
        print("usage: inspect-update-bundle.py MODE APP_PATH", file=sys.stderr)
        return 2
    mode, app_path = sys.argv[1:]
    try:
        result = inspect(mode, Path(app_path))
    except InspectionError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(f"Bundle inspection passed: mode={mode}, Mach-O binaries={len(result['binaries'])}, Sparkle frameworks={result['frameworks']}, helper types={result['helpers']}, disable-library-validation={result['entitlements']}")
    for binary in result["binaries"]:
        print(f"Mach-O: {binary}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
