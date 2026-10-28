#!/usr/bin/env python3
"""Publish a release candidate to GitHub Releases and the GitHub Pages feed.

Plans offline by default; --publish runs `gh`. Order: check the live feed,
upload assets to a release tagged <VERSION>-<BUILD>, download them without
credentials and compare bytes, then replace appcast.xml on the gh-pages branch.
The feed changes last, so a failure keeps the old feed. The feed update is a
compare-and-swap on the branch file's blob SHA.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import shlex
import subprocess
import sys
from urllib.error import HTTPError
from urllib.request import urlopen
import xml.etree.ElementTree as ET

REPO = 'a-dev/underpressured'
PAGES_BRANCH = 'gh-pages'
FEED_PATH = 'appcast.xml'
SPARKLE = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def feed_builds(data):
    return [int(v.text) for v in ET.fromstring(data).iter(SPARKLE + 'version')]


def candidate(path):
    meta = json.loads((path / 'publication.json').read_text())
    hashes = json.loads((path / 'SHA256.json').read_text())
    version, build = meta['version'], meta['build']
    tag = f'{version}-{build}'
    require(meta['download_url_prefix'] == f'https://github.com/{REPO}/releases/download/{tag}',
            f'candidate download prefix must be the GitHub release for tag {tag}')
    require(meta['feed_url'] == f'https://{REPO.split("/")[0]}.github.io/{REPO.split("/")[1]}/{FEED_PATH}',
            'candidate feed URL must be the GitHub Pages feed')
    for name, expected in hashes.items():
        require(digest((path / name).read_bytes()) == expected, f'{name} does not match SHA256.json')
    feed = (path / 'updates/appcast.xml').read_bytes()
    require(feed_builds(feed) == [build], 'candidate feed must contain exactly its own build')
    assets = [path / name for name in hashes if not name.endswith('appcast.xml')] + [path / 'SHA256.json']
    return meta, tag, hashes, feed, assets


def gh(*args):
    return subprocess.run(['gh', *args], check=True, capture_output=True, text=True).stdout


def live_feed():
    try:
        out = json.loads(gh('api', f'repos/{REPO}/contents/{FEED_PATH}?ref={PAGES_BRANCH}'))
    except subprocess.CalledProcessError as e:
        require('Not Found' in e.stderr, e.stderr.strip())
        return None, b''
    return out['sha'], base64.b64decode(out['content'])


def verify_public(meta, hashes):
    for name, expected in hashes.items():
        if name.endswith('appcast.xml'):
            continue
        url = f"{meta['download_url_prefix']}/{Path(name).name}"
        try:
            data = urlopen(url, timeout=120).read()
        except HTTPError as e:
            raise ValueError(f'{url}: HTTP {e.code}') from e
        require(digest(data) == expected, f'{url} bytes differ from SHA256.json')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--candidate', type=Path, required=True)
    p.add_argument('--notes', type=Path, help='Markdown release notes for the GitHub release page')
    p.add_argument('--publish', action='store_true')
    a = p.parse_args()
    try:
        meta, tag, hashes, feed, assets = candidate(a.candidate)
        notes = ['--notes-file', str(a.notes)] if a.notes else ['--notes', '']
        create = ['release', 'create', tag, '--repo', REPO, '--title', f"Underpressured {meta['version']}", *notes, *map(str, assets)]
        if not a.publish:
            print(f'PLAN: {tag}; no network requests.')
            print('check live feed: gh api repos/%s/contents/%s?ref=%s' % (REPO, FEED_PATH, PAGES_BRANCH))
            print(shlex.join(['gh', *create]))
            print('verify unauthenticated downloads against SHA256.json')
            print(f'replace {FEED_PATH} on {PAGES_BRANCH}')
            return 0
        sha, current = live_feed()
        if current:
            require(all(b < meta['build'] for b in feed_builds(current)), 'live feed already has this build or a later one')
        gh(*create)
        verify_public(meta, hashes)
        body = {'message': f'appcast: {tag}', 'branch': PAGES_BRANCH, 'content': base64.b64encode(feed).decode()}
        if sha:
            body['sha'] = sha
        subprocess.run(['gh', 'api', '-X', 'PUT', f'repos/{REPO}/contents/{FEED_PATH}', '--input', '-'],
                       input=json.dumps(body), check=True, capture_output=True, text=True)
        print(f'Published {tag}. Feed: {meta["feed_url"]}')
    except (ValueError, OSError, KeyError, ET.ParseError, subprocess.CalledProcessError) as e:
        print(f'error: {getattr(e, "stderr", None) or e}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
