#!/usr/bin/env python3
"""Exercise audit failures with isolated catalogs and compiler artifacts."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class LocalizationAuditTests(unittest.TestCase):
    def audit(self, entry, extraction=True, source_alias=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            script = root / 'scripts/check-localization.py'
            script.parent.mkdir()
            shutil.copy(Path(__file__).with_name('check-localization.py'), script)
            alias = root / 'checkout-alias'
            if source_alias:
                alias.symlink_to(root, target_is_directory=True)
            for owner, build in [('App', 'DerivedData/Build/Intermediates.noindex'),
                                 ('Packages/UnderpressuredKit/Sources/AppModel', 'Packages/UnderpressuredKit/.build')]:
                catalog = root / owner / ('Localizable.xcstrings' if owner == 'App' else 'Resources/Localizable.xcstrings')
                catalog.parent.mkdir(parents=True)
                catalog.write_text(json.dumps({'sourceLanguage': 'en', 'strings': {'Example': entry}}))
                if extraction:
                    artifact = root / build / 'Example.stringsdata'
                    artifact.parent.mkdir(parents=True)
                    artifact.write_text(json.dumps({'source': str((alias if source_alias else root) / owner / 'Example.swift'),
                                                    'tables': {'Localizable': [{'key': 'Example'}]}}))
            return subprocess.run(['python3', str(script)], capture_output=True, text=True)

    def test_missing_localizations_reports_key_and_languages(self):
        result = self.audit({})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no explicit English value for 'Example'", result.stderr)
        self.assertIn("missing ja value for 'Example'", result.stderr)
        self.assertNotIn('Traceback', result.stderr)

    def test_malformed_nodes_are_actionable(self):
        for entry in [None, {'localizations': None}, {'localizations': {'en': None, 'ja': []}},
                      {'localizations': {'en': {'stringUnit': {'value': 42}},
                                         'ar': {'variations': {'plural': None}}}}]:
            with self.subTest(entry=entry):
                result = self.audit(entry)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Example', result.stderr)
                self.assertNotIn('Traceback', result.stderr)

    def test_missing_build_artifacts_are_prerequisites(self):
        entry = {'localizations': {language: {'stringUnit': {'value': 'Example'}}
                                  for language in ['en', 'es', 'pt-BR', 'de', 'fr', 'ar', 'ja', 'zh-Hans']}}
        result = self.audit(entry, extraction=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('no compiler extraction found', result.stderr)
        self.assertIn('build first', result.stderr)
        self.assertNotIn('missing ja', result.stderr)
        self.assertNotIn('Traceback', result.stderr)

    def test_source_path_alias_matches_the_same_checkout(self):
        entry = {'localizations': {language: {'stringUnit': {'value': 'Example'}}
                                  for language in ['en', 'es', 'pt-BR', 'de', 'fr', 'ar', 'ja', 'zh-Hans']}}
        result = self.audit(entry, source_alias=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_complete_catalog_and_extraction_pass(self):
        entry = {'localizations': {language: {'stringUnit': {'value': 'Example'}}
                                  for language in ['en', 'es', 'pt-BR', 'de', 'fr', 'ar', 'ja', 'zh-Hans']}}
        result = self.audit(entry)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('audit passed', result.stdout)


if __name__ == '__main__':
    unittest.main()
