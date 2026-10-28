#!/usr/bin/env python3
"""Fixtures for the Swift package architecture checker."""

from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("check-architecture.py")
spec = importlib.util.spec_from_file_location("check_architecture", SCRIPT)
checker = importlib.util.module_from_spec(spec)
assert spec and spec.loader
spec.loader.exec_module(checker)


def fixture_manifest() -> dict:
    names = {
        "UnderpressuredCore": ("regular", []),
        "UnderpressuredApplication": ("regular", ["UnderpressuredCore"]),
        "AppModel": ("regular", ["UnderpressuredApplication", "UnderpressuredCore"]),
        "LocalFileSystem": ("regular", ["UnderpressuredApplication", "UnderpressuredCore"]),
        "ImageEngine": ("regular", ["UnderpressuredApplication", "UnderpressuredCore", "UpJpegli", "UpCodecs"]),
        "MacPlatform": ("regular", ["UnderpressuredApplication", "UnderpressuredCore"]),
        "SoakHarness": ("executable", ["UnderpressuredApplication", "UnderpressuredCore", "LocalFileSystem", "ImageEngine", "MacPlatform"]),
        "QueueBenchmark": ("executable", ["UnderpressuredApplication", "UnderpressuredCore"]),
        "UnderpressuredCoreTests": ("test", ["UnderpressuredCore"]),
        "UnderpressuredApplicationTests": ("test", ["UnderpressuredApplication", "UnderpressuredCore", "QueueTestSupport"]),
        "MacPlatformTests": ("test", ["MacPlatform", "UnderpressuredApplication", "UnderpressuredCore"]),
        "AppModelTests": ("test", ["AppModel", "UnderpressuredApplication", "UnderpressuredCore", "QueueTestSupport"]),
        "LocalFileSystemTests": ("test", ["LocalFileSystem", "UnderpressuredApplication", "UnderpressuredCore", "QueueTestSupport"]),
        "ImageEngineTests": ("test", ["ImageEngine", "UnderpressuredApplication", "UnderpressuredCore"]),
        "IntegrationTests": ("test", ["UnderpressuredApplication", "UnderpressuredCore", "LocalFileSystem", "ImageEngine", "QueueTestSupport"]),
        "QueueTestSupport": ("regular", ["UnderpressuredApplication", "UnderpressuredCore", "LocalFileSystem"]),
        "UpJpegli": ("binary", []),
        "UpCodecs": ("binary", []),
    }
    return {"targets": [{"name": name, "type": kind, "dependencies": deps,
                         "path": ("Tests/QueueTestSupport" if name == "QueueTestSupport" else
                                  f"{'Tests' if kind == 'test' else 'Sources'}/{name}")}
                        for name, (kind, deps) in names.items()]}


class ArchitectureCheckerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.manifest = fixture_manifest()

    def tearDown(self) -> None:
        self.temp.cleanup()

    def put_source(self, target: str, source: str, filename: str = "Sample.swift") -> Path:
        directory = self.root / "Sources" / target
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / filename
        path.write_text(source, encoding="utf-8")
        return path

    def errors(self) -> list[str]:
        return checker.check(self.manifest, self.root)

    def test_accepts_allowed_graph_foundation_and_native_adapter_imports(self) -> None:
        self.put_source("UnderpressuredCore", "import Foundation\nstruct Value { let id: UUID }\n")
        self.put_source("ImageEngine", "import UnderpressuredCore\nimport UpCodecs\nimport ImageIO\n")
        self.put_source("LocalFileSystem", "import Foundation\nimport UniformTypeIdentifiers\n")
        self.put_source("MacPlatform", "import Foundation\nimport UserNotifications\n")
        self.assertEqual(self.errors(), [])

    def test_ignores_imports_inside_line_and_nested_block_comments(self) -> None:
        self.put_source("UnderpressuredCore", """// import AppKit
/* outer comment
   /* import UnderpressuredApplication */
*/
import Foundation
""")
        self.assertEqual(self.errors(), [])

    def test_ignores_import_text_inside_multiline_strings_and_reads_semicolon_imports(self) -> None:
        path = self.put_source("UnderpressuredCore", '''let sample = """
import AppKit
"""
import Foundation; import Swift
''')
        self.assertEqual(checker.imports_in(path), ["Foundation", "Swift"])
        self.assertEqual(self.errors(), [])

    def test_rejects_core_dependency_on_application(self) -> None:
        self.manifest["targets"][0]["dependencies"] = ["UnderpressuredApplication"]
        self.assertTrue(any("UnderpressuredCore has forbidden dependency UnderpressuredApplication" in e for e in self.errors()))

    def test_rejects_core_source_import_of_application(self) -> None:
        self.put_source("UnderpressuredCore", "import UnderpressuredApplication\n")
        self.assertTrue(any("UnderpressuredCore may import Foundation or Swift only, not UnderpressuredApplication" in e
                            for e in self.errors()))

    def test_rejects_app_model_import_of_concrete_adapter(self) -> None:
        self.put_source("AppModel", "import LocalFileSystem\n")
        self.assertTrue(any("AppModel must depend on adapter contracts" in e for e in self.errors()))

    def test_rejects_platform_import_in_core(self) -> None:
        self.put_source("UnderpressuredCore", "import UniformTypeIdentifiers\n")
        self.assertTrue(any("UnderpressuredCore may import Foundation or Swift only, not UniformTypeIdentifiers" in e
                            for e in self.errors()))

    def test_rejects_cross_target_import_missing_from_manifest_dependencies(self) -> None:
        self.put_source("AppModel", "import UnderpressuredApplication\nimport UnderpressuredCore\n")
        app_model = next(t for t in self.manifest["targets"] if t["name"] == "AppModel")
        app_model["dependencies"].remove("UnderpressuredApplication")
        self.assertTrue(any("AppModel imports UnderpressuredApplication but Package.swift does not declare" in e
                            for e in self.errors()))

    def test_rejects_core_tests_importing_an_adapter(self) -> None:
        directory = self.root / "Tests" / "UnderpressuredCoreTests"
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "AdapterImport.swift").write_text("import LocalFileSystem\n", encoding="utf-8")
        self.assertTrue(any("UnderpressuredCoreTests imports LocalFileSystem but Package.swift does not declare" in e
                            for e in self.errors()))

    def test_rejects_overlapping_source_ownership(self) -> None:
        app_target = next(t for t in self.manifest["targets"] if t["name"] == "UnderpressuredApplication")
        app_target["path"] = "Sources/UnderpressuredCore"
        self.assertTrue(any("source ownership overlaps" in e for e in self.errors()))

    def test_reports_missing_required_target_and_unmodeled_edge(self) -> None:
        self.manifest["targets"] = [t for t in self.manifest["targets"] if t["name"] != "MacPlatform"]
        self.manifest["targets"].append({"name": "NewTarget", "type": "regular", "dependencies": []})
        errors = self.errors()
        self.assertTrue(any("missing required architecture targets" in e for e in errors))
        self.assertTrue(any("NewTarget has no architecture policy" in e for e in errors))


if __name__ == "__main__":
    unittest.main()
