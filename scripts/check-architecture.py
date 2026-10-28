#!/usr/bin/env python3
"""Check SwiftPM target edges and Swift source imports against the module boundary."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path


PRODUCTION_EDGES = {
    "UnderpressuredCore": set(),
    "UnderpressuredApplication": {"UnderpressuredCore"},
    "AppModel": {"UnderpressuredApplication", "UnderpressuredCore"},
    "LocalFileSystem": {"UnderpressuredApplication", "UnderpressuredCore"},
    "ImageEngine": {"UnderpressuredApplication", "UnderpressuredCore", "UpJpegli", "UpCodecs"},
    "MacPlatform": {"UnderpressuredApplication", "UnderpressuredCore"},
    "SoakHarness": {"UnderpressuredApplication", "UnderpressuredCore", "AppModel", "LocalFileSystem", "ImageEngine", "MacPlatform"},
    "QueueBenchmark": {"UnderpressuredApplication", "UnderpressuredCore", "AppModel", "LocalFileSystem", "ImageEngine", "MacPlatform"},
}

TEST_EDGES = {
    "UnderpressuredCoreTests": {"UnderpressuredCore"},
    "UnderpressuredApplicationTests": {"UnderpressuredApplication", "UnderpressuredCore", "QueueTestSupport"},
    "MacPlatformTests": {"MacPlatform", "UnderpressuredApplication", "UnderpressuredCore"},
    "AppModelTests": {"AppModel", "UnderpressuredApplication", "UnderpressuredCore", "QueueTestSupport"},
    "LocalFileSystemTests": {"LocalFileSystem", "UnderpressuredApplication", "UnderpressuredCore", "QueueTestSupport"},
    "ImageEngineTests": {"ImageEngine", "UnderpressuredApplication", "UnderpressuredCore"},
    "IntegrationTests": {"UnderpressuredApplication", "UnderpressuredCore", "LocalFileSystem", "ImageEngine", "QueueTestSupport"},
}

SUPPORT_EDGES = {
    "QueueTestSupport": {"UnderpressuredApplication", "UnderpressuredCore", "LocalFileSystem"},
}
REQUIRED_TARGETS = set(PRODUCTION_EDGES) | set(TEST_EDGES) | set(SUPPORT_EDGES)

CORE_ALLOWED_IMPORTS = {"Foundation", "Swift"}
ADAPTERS = {"LocalFileSystem", "ImageEngine", "MacPlatform"}


def strip_comments_and_strings(source: str) -> str:
    """Remove Swift comments and string literals while preserving line layout."""
    out: list[str] = []
    i = 0
    string_end: str | None = None
    raw_hashes = 0
    block_depth = 0
    while i < len(source):
        if block_depth:
            if source.startswith("/*", i):
                block_depth += 1
                out.extend("  ")
                i += 2
            elif source.startswith("*/", i):
                block_depth -= 1
                out.extend("  ")
                i += 2
            else:
                out.append("\n" if source[i] == "\n" else " ")
                i += 1
            continue
        if string_end is not None:
            if source.startswith(string_end, i):
                out.extend(" " * len(string_end))
                i += len(string_end)
                string_end = None
                raw_hashes = 0
            elif source[i] == "\\" and i + 1 < len(source) and (not raw_hashes or source[i + 1:i + 1 + raw_hashes] == "#" * raw_hashes):
                out.extend(" " * (2 + raw_hashes))
                i += 2 + raw_hashes
            else:
                out.append("\n" if source[i] == "\n" else " ")
                i += 1
            continue
        if source.startswith("/*", i):
            block_depth = 1
            out.extend("  ")
            i += 2
            continue
        if source.startswith("//", i):
            while i < len(source) and source[i] != "\n":
                out.append(" ")
                i += 1
            continue
        hashes = 0
        while i + hashes < len(source) and source[i + hashes] == "#":
            hashes += 1
        quote_start = i + hashes
        if quote_start < len(source) and source[quote_start] == '"':
            triple = source.startswith('"""', quote_start)
            delimiter = '"""' if triple else '"'
            raw_hashes = hashes
            string_end = delimiter + ("#" * hashes)
            out.extend(" " * (hashes + len(delimiter)))
            i = quote_start + len(delimiter)
            continue
        out.append(source[i])
        i += 1
    return "".join(out)


def imports_in(path: Path) -> list[str]:
    clean = strip_comments_and_strings(path.read_text(encoding="utf-8"))
    pattern = re.compile(r"(?:^|[;\n])\s*(?:(?:@\w+(?:\([^\n]*\))?)\s+)*(?:(?:public|private|fileprivate|internal|package|open)\s+)?(?:@_exported\s+|@_implementationOnly\s+)?import\s+(?:(?:class|struct|enum|protocol|typealias|func|var|let)\s+)?([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)", re.MULTILINE)
    return [match.group(1).split(".")[0] for match in pattern.finditer(clean)]


def dependency_name(dep: object) -> str | None:
    if isinstance(dep, str):
        return dep
    if isinstance(dep, dict):
        # SwiftPM dump-package represents target dependencies as {"byName": [name, location]}.
        for value in dep.values():
            if isinstance(value, list) and value and isinstance(value[0], str):
                return value[0]
    return None


def target_source_dir(target: dict, package_dir: Path) -> Path:
    default_root = "Tests" if target.get("type") == "test" else "Sources"
    path = target.get("path") or f"{default_root}/{target['name']}"
    return package_dir / path


def check(manifest: dict, package_dir: Path) -> list[str]:
    errors: list[str] = []
    targets = {target["name"]: target for target in manifest.get("targets", [])}
    missing = REQUIRED_TARGETS - targets.keys()
    if missing:
        errors.append("Package.swift is missing required architecture targets: " + ", ".join(sorted(missing)))
    owned_roots: list[tuple[str, Path]] = []
    for name, target in targets.items():
        if target.get("type") in {"regular", "test", "executable"}:
            root = target_source_dir(target, package_dir).resolve()
            for other_name, other_root in owned_roots:
                if root == other_root or root in other_root.parents or other_root in root.parents:
                    errors.append(f"source ownership overlaps: targets {other_name} ({other_root}) and {name} ({root})")
            owned_roots.append((name, root))
    for name, target in targets.items():
        expected = PRODUCTION_EDGES.get(name)
        if target.get("type") == "test":
            expected = TEST_EDGES.get(name)
        if name in SUPPORT_EDGES:
            expected = SUPPORT_EDGES[name]
        actual = {n for item in target.get("dependencies", []) if (n := dependency_name(item))}
        if expected is not None:
            for edge in sorted(actual - expected):
                errors.append(f"Package.swift target {name} has forbidden dependency {edge}")
        elif target.get("type") in {"regular", "test", "executable"}:
            errors.append(f"Package.swift target {name} has no architecture policy; add it to the checker")

    for name, target in targets.items():
        if target.get("type") in {"regular", "test", "executable"}:
            root = target_source_dir(target, package_dir)
            if not root.exists():
                continue
            for path in sorted(root.rglob("*.swift")):
                rel = path.relative_to(package_dir)
                declared = {n for item in target.get("dependencies", []) if (n := dependency_name(item))}
                for module in imports_in(path):
                    if name == "UnderpressuredCore" and module not in CORE_ALLOWED_IMPORTS:
                        errors.append(f"{rel}: UnderpressuredCore may import Foundation or Swift only, not {module}")
                    if name == "AppModel" and module in ADAPTERS:
                        errors.append(f"{rel}: AppModel must depend on adapter contracts, not concrete adapter {module}")
                    if name in ADAPTERS and module in ADAPTERS - {name}:
                        errors.append(f"{rel}: {name} must not import sibling adapter {module}")
                    if name == "QueueTestSupport" and module in ADAPTERS - {"LocalFileSystem"}:
                        errors.append(f"{rel}: QueueTestSupport may import LocalFileSystem fixtures only, not {module}")
                    if name == "QueueTestSupport" and module == "AppModel":
                        errors.append(f"{rel}: {name} must not import presentation target AppModel")
                    # Every cross-target source import must also appear in the manifest target's dependencies.
                    if module in targets and module != name:
                        if module not in declared:
                            errors.append(f"{rel}: {name} imports {module} but Package.swift does not declare that dependency")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", type=Path, default=Path("Packages/UnderpressuredKit"))
    parser.add_argument("--manifest-json", type=Path, help="Use saved swift package dump-package JSON (primarily for fixtures)")
    args = parser.parse_args()
    package = args.package.resolve()
    try:
        if args.manifest_json:
            manifest = json.loads(args.manifest_json.read_text(encoding="utf-8"))
        else:
            result = subprocess.run(["swift", "package", "dump-package", "--package-path", str(package)], check=True, text=True, capture_output=True)
            manifest = json.loads(result.stdout)
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        print(f"architecture check: could not read Swift package manifest: {exc}", file=sys.stderr)
        return 2
    errors = check(manifest, package)
    if errors:
        print("Architecture violations:", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 1
    print("Architecture boundaries are valid.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
