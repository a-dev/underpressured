#!/usr/bin/env python3
"""Plan offline by default; --publish explicitly writes to a configured service.

The service must implement publication-store.py's atomic state transitions.
It is a future hosting adapter boundary, not an installed public service.
"""
import argparse
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import posixpath
import re
import sys
from urllib.parse import urlsplit, quote, unquote
from urllib.request import Request, build_opener, HTTPRedirectHandler
import xml.etree.ElementTree as ET

SPEC = importlib.util.spec_from_file_location('release', Path(__file__).with_name('release.py'))
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)
require = release.require


def digest(data):
    return hashlib.sha256(data).hexdigest()


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':')).encode()


def url(value, loopback=False):
    p = urlsplit(value)
    if loopback and p.scheme == 'http' and p.hostname == '127.0.0.1' and not p.username and not p.password and not p.query and not p.fragment:
        return
    release.https(value)


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise ValueError('publication redirects are forbidden; configure final URLs')


class HTTP:
    def __init__(self, config, token=None):
        self.config = config
        self.token = token
        self.opener = build_opener(NoRedirect())

    def request(self, method, target, data=None, service=False):
        headers = {'Content-Type': 'application/json' if method == 'POST' else 'application/octet-stream', 'Cache-Control': 'no-cache'}
        if service and self.token:
            headers['Authorization'] = 'Bearer ' + self.token
        with self.opener.open(Request(target, data=data, headers=headers, method=method), timeout=30) as response:
            return response.read()

    def call(self, method, path, value=None, raw=None):
        data = raw if raw is not None else (encoded(value) if value is not None else None)
        response = self.request(method, self.config['service_url'].rstrip('/') + path, data, service=True)
        return json.loads(response) if response else None

    def anonymous(self, target):
        # A fresh opener sends no service credentials, cookies, or ambient auth.
        return HTTP(self.config).request('GET', target)


def candidate(path, config, loopback=False):
    require(config.get('channel') in ('test', 'production'), 'channel must be test or production')
    for key in ('feed_url', 'download_url_prefix', 'service_url', 'production_feed_url', 'production_service_url', 'production_download_url_prefix'):
        require(isinstance(config.get(key), str), f'missing {key}')
        url(config[key], loopback)
    def destination(value):
        parsed = urlsplit(value)
        port = parsed.port or (443 if parsed.scheme == 'https' else 80)
        return (parsed.scheme.lower(), parsed.hostname.lower().rstrip('.'), port, posixpath.normpath(unquote(parsed.path)))
    if config['channel'] == 'test':
        for key in ('feed_url', 'service_url', 'download_url_prefix'):
            require(destination(config[key]) != destination(config['production_' + key]), f'test {key} must differ from production {key}')
    else:
        for key in ('feed_url', 'service_url', 'download_url_prefix'):
            require(config[key] == config['production_' + key], f'production {key} must equal production_{key}')
    hashes = json.loads((path / 'SHA256.json').read_text())
    require(isinstance(hashes, dict) and len(hashes) == 3, 'candidate needs exact ZIP, DMG and feed hashes')
    files = {}
    for name, expected in hashes.items():
        require(isinstance(name, str) and not Path(name).is_absolute() and '..' not in Path(name).parts, 'unsafe manifest path')
        p = path / name
        require(p.resolve().is_relative_to(path.resolve()) and not p.is_symlink() and p.is_file(), 'unsafe candidate file')
        data = p.read_bytes()
        require(digest(data) == expected, f'candidate hash mismatch: {name}')
        files[name] = data
    feed = files.get('updates/appcast.xml')
    require(feed is not None, 'missing appcast')
    root = ET.fromstring(feed)
    items = root.findall('./channel/item')
    require(len(items) == 1, 'candidate needs one feed item')
    item = items[0]
    enclosure = item.find('enclosure')
    require(enclosure is not None, 'missing enclosure')
    def version_field(name):
        return enclosure.get(f'{{{release.SPARKLE}}}{name}') or item.findtext(f'{{{release.SPARKLE}}}{name}')
    build, version = version_field('version'), version_field('shortVersionString')
    require(build is not None and re.fullmatch(r'[1-9]\d*', build), 'invalid build')
    require(version is not None and re.fullmatch(r'\d+\.\d+\.\d+', version), 'invalid version')
    metadata = json.loads((path / 'publication.json').read_text())
    require(metadata.get('version') == version and metadata.get('build') == int(build), 'candidate publication metadata version mismatch')
    require(metadata.get('feed_url') == config['feed_url'], 'candidate built for a different feed')
    prefix = config['download_url_prefix'].rstrip('/')
    require(metadata.get('download_url_prefix') == prefix, 'candidate built for different download URLs')
    require(urlsplit(prefix).path.endswith('/' + version + '-' + build), 'download prefix must end in /VERSION-BUILD')
    archive = path / 'updates' / f'Underpressured-{version}-{build}.zip'
    dmg = f'Underpressured-{version}-{build}.dmg'
    require(set(files) == {'updates/appcast.xml', 'updates/' + archive.name, dmg}, 'unexpected candidate assets')
    release.verify_feed(path / 'updates/appcast.xml', archive, version, build, prefix)
    local_history = json.loads((path / 'published-history-input.json').read_text())
    release.history(path / 'published-history-input.json', build)
    assets = [{'name': Path(name).name, 'sha256': digest(data), 'url': prefix + '/' + Path(name).name} for name, data in sorted(files.items()) if name != 'updates/appcast.xml']
    identity = digest(encoded({'channel': config['channel'], 'feed_url': config['feed_url'], 'build': int(build), 'assets': assets, 'feed_sha256': digest(feed)}))
    return {'build': int(build), 'identity': identity, 'feed_sha256': digest(feed), 'assets': assets, 'local_history': local_history['published_builds'], 'files': {Path(k).name: v for k, v in files.items()}, 'feed': feed}


def publish(c, config, transport):
    state = transport.call('GET', '/state')
    require(set(c['local_history']).issubset(state['published_builds']), 'remote history omits local published builds; reconcile before publication')
    existing = next((r for r in state['releases'] if r['build'] == c['build']), None)
    if existing:
        require(existing['identity'] == c['identity'], 'build conflicts with another candidate')
        if existing['status'] == 'feed':
            require(state['feed_sha256'] == c['feed_sha256'], 'completed release superseded; refusing to roll back feed')
            require(transport.anonymous(config['feed_url']) == c['feed'], 'published feed differs from candidate')
            for asset in c['assets']:
                require(digest(transport.anonymous(asset['url'])) == asset['sha256'], 'published asset differs')
            return 'already published; exact bytes verified'
    else:
        require(c['build'] > max(state['published_builds'], default=0), 'build must exceed all remote reservations')
    reserved = transport.call('POST', '/reserve', {'channel': config['channel'], 'destination_feed_url': config['feed_url'], 'expected_revision': state['revision'], 'build': c['build'], 'identity': c['identity'], 'feed_sha256': state['feed_sha256'], 'assets': c['assets'], 'candidate_feed_sha256': c['feed_sha256']})
    for asset in c['assets']:
        transport.call('PUT', '/assets/' + c['identity'] + '/' + quote(asset['name']), raw=c['files'][asset['name']])
    transport.call('POST', '/activate/' + c['identity'], {})
    for asset in c['assets']:
        require(digest(transport.anonymous(asset['url'])) == asset['sha256'], 'anonymous asset hash mismatch: ' + asset['name'])
    transport.call('POST', '/commit/' + c['identity'], {'expected_feed_sha256': reserved['feed_sha256'], 'feed': base64.b64encode(c['feed']).decode()})
    require(transport.anonymous(config['feed_url']) == c['feed'], 'feed response differs after commit; reconcile by rerunning')
    return 'published; anonymous assets and feed verified'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--publish', action='store_true', help='explicitly authorize configured service writes')
    a = parser.parse_args()
    try:
        config = json.loads(a.config.read_text())
        c = candidate(a.candidate, config)
        if not a.publish:
            print(json.dumps({'mode': 'OFFLINE PLAN: no network or writes', 'channel': config['channel'], 'build': c['build'], 'identity': c['identity'], 'assets': c['assets'], 'feed_url': config['feed_url'], 'steps': ['reserve draft/build atomically', 'upload immutable assets', 'activate asset URLs', 'verify anonymous asset hashes', 'commit feed last with compare-and-swap', 'verify anonymous feed']}, indent=2))
        else:
            print(publish(c, config, HTTP(config, os.environ.get('UNDERPRESSURED_PUBLISH_TOKEN'))))
    except (ValueError, OSError, KeyError, TypeError, ET.ParseError) as e:
        print(f'error: {e}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
