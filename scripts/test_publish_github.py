#!/usr/bin/env python3
"""Offline tests for the GitHub publisher's candidate checks and ordering."""

import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('publish_github', Path(__file__).with_name('publish-github.py'))
pub = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(pub)

FEED = b'''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
<item><sparkle:version>%d</sparkle:version></item></channel></rss>'''


def make_candidate(root, build=2, prefix=None):
    c = Path(root)
    (c / 'updates').mkdir()
    files = {f'updates/Underpressured-1.1.0-{build}.zip': b'zip', f'Underpressured-1.1.0-{build}.dmg': b'dmg', 'updates/appcast.xml': FEED % build}
    for name, data in files.items():
        (c / name).write_bytes(data)
    (c / 'SHA256.json').write_text(json.dumps({n: hashlib.sha256(d).hexdigest() for n, d in files.items()}))
    (c / 'publication.json').write_text(json.dumps({
        'version': '1.1.0', 'build': build,
        'feed_url': 'https://a-dev.github.io/underpressured/appcast.xml',
        'download_url_prefix': prefix or f'https://github.com/a-dev/underpressured/releases/download/1.1.0-{build}',
    }))
    return c


class CandidateTests(unittest.TestCase):
    def test_accepts_matching_candidate(self):
        with tempfile.TemporaryDirectory() as d:
            meta, tag, _, _, assets = pub.candidate(make_candidate(d))
            self.assertEqual(tag, '1.1.0-2')
            self.assertEqual(sorted(a.name for a in assets), ['SHA256.json', 'Underpressured-1.1.0-2.dmg', 'Underpressured-1.1.0-2.zip'])

    def test_refuses_changed_bytes(self):
        with tempfile.TemporaryDirectory() as d:
            c = make_candidate(d)
            (c / 'Underpressured-1.1.0-2.dmg').write_bytes(b'other')
            with self.assertRaisesRegex(ValueError, 'SHA256'):
                pub.candidate(c)

    def test_refuses_foreign_download_prefix(self):
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaisesRegex(ValueError, 'GitHub release'):
                pub.candidate(make_candidate(d, prefix='https://example.test/1.1.0-2'))


class PublishOrderTests(unittest.TestCase):
    def run_publish(self, d, live):
        calls = []
        with patch.object(pub, 'live_feed', return_value=('blob', live)), \
             patch.object(pub, 'gh', side_effect=lambda *a: calls.append(('gh',) + a[:2]) or ''), \
             patch.object(pub, 'verify_public', side_effect=lambda *a: calls.append(('verify',))), \
             patch.object(pub.subprocess, 'run', side_effect=lambda *a, **k: calls.append(('feed',))), \
             patch('sys.argv', ['publish-github.py', '--candidate', str(make_candidate(d)), '--publish']):
            return pub.main(), calls

    def test_feed_replaced_last(self):
        with tempfile.TemporaryDirectory() as d:
            code, calls = self.run_publish(d, FEED % 1)
            self.assertEqual(code, 0)
            self.assertEqual([c[0] for c in calls], ['gh', 'verify', 'feed'])

    def test_refuses_build_not_above_live_feed(self):
        with tempfile.TemporaryDirectory() as d:
            code, calls = self.run_publish(d, FEED % 2)
            self.assertEqual((code, calls), (1, []))


if __name__ == '__main__':
    unittest.main()
