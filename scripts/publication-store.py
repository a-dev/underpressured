#!/usr/bin/env python3
"""Reference local publication state machine for future hosting adapters.

Not a server or production hosting setup. All mutable state (including feed
bytes) commits via one atomic file replacement under a process-shared lock.
Adapters must preserve these transitions, immutable asset storage and anonymous
activation. Assets may be orphaned on failure; feeds must never be orphaned.
"""
import base64
from contextlib import contextmanager
import copy
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


class Store:
    def __init__(self, directory):
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True)

    @contextmanager
    def locked(self):
        with (self.directory / 'lock').open('a+b') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            path = self.directory / 'state.json'
            state = json.loads(path.read_text()) if path.exists() else {'revision': 0, 'feed_sha256': None, 'feed': None, 'releases': [], 'published_builds': [], 'channel': None, 'destination_feed_url': None}
            yield state

    def save(self, state):
        state['revision'] += 1
        fd, name = tempfile.mkstemp(dir=self.directory, prefix='.state-')
        try:
            with os.fdopen(fd, 'w') as stream:
                json.dump(state, stream, sort_keys=True)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(name, self.directory / 'state.json')
            self.sync_directory()
        finally:
            if os.path.exists(name):
                os.unlink(name)

    def sync_directory(self):
        fd = os.open(self.directory, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)

    def state(self):
        with self.locked() as state:
            result = copy.deepcopy(state)
            result.pop('feed')
            return result

    def find(self, state, identity):
        require(isinstance(identity, str) and re.fullmatch(r'[0-9a-f]{64}', identity), 'invalid identity')
        found = next((r for r in state['releases'] if r['identity'] == identity), None)
        require(found is not None, 'unknown reservation')
        return found

    def reserve(self, p):
        with self.locked() as state:
            require(p.get('channel') in ('test', 'production'), 'invalid channel')
            require(isinstance(p.get('destination_feed_url'), str), 'missing destination feed')
            require(state['channel'] in (None, p['channel']) and state['destination_feed_url'] in (None, p['destination_feed_url']), 'service store belongs to a different channel/feed')
            require(type(p['build']) is int and p['build'] > 0, 'invalid build')
            require(isinstance(p['identity'], str) and re.fullmatch(r'[0-9a-f]{64}', p['identity']), 'invalid identity')
            existing = next((r for r in state['releases'] if r['build'] == p['build']), None)
            if existing:
                require(existing['identity'] == p['identity'], 'conflicting build')
                require(all(existing[k] == p[k] for k in ('assets', 'candidate_feed_sha256')), 'reservation content changed')
                require(p['build'] == max(state['published_builds']), 'newer build reserved; use a higher build')
                return {'feed_sha256': existing['feed_sha256']}
            require(p['expected_revision'] == state['revision'], 'stale revision; reread state')
            require(p['feed_sha256'] == state['feed_sha256'], 'stale feed')
            require(p['build'] > max(state['published_builds'], default=0), 'build must increase')
            require(re.fullmatch(r'[0-9a-f]{64}', p['candidate_feed_sha256']), 'invalid feed hash')
            assets = p['assets']
            require(isinstance(assets, list) and len(assets) == 2, 'two assets required')
            require(len({a['name'] for a in assets}) == len(assets), 'duplicate asset names')
            for a in assets:
                require(re.fullmatch(r'Underpressured-[0-9]+\.[0-9]+\.[0-9]+-' + str(p['build']) + r'\.(zip|dmg)', a['name']), 'invalid asset name')
                require(re.fullmatch(r'[0-9a-f]{64}', a['sha256']), 'invalid asset hash')
                require(isinstance(a['url'], str), 'invalid asset URL')
            require({Path(a['name']).suffix for a in assets} == {'.zip', '.dmg'}, 'ZIP and DMG required')
            known_urls = {a['url'] for r in state['releases'] for a in r['assets']}
            require(not any(a['url'] in known_urls for a in assets), 'immutable URL already reserved')
            state['channel'] = p['channel']
            state['destination_feed_url'] = p['destination_feed_url']
            state['releases'].append({k: copy.deepcopy(p[k]) for k in ('build', 'identity', 'feed_sha256', 'assets', 'candidate_feed_sha256')} | {'status': 'reserved'})
            state['published_builds'].append(p['build'])
            self.save(state)
            return {'feed_sha256': p['feed_sha256']}

    def upload(self, identity, name, data):
        with self.locked() as state:
            record = self.find(state, identity)
            asset = next((a for a in record['assets'] if a['name'] == name), None)
            require(asset is not None, 'unreserved asset')
            require(digest(data) == asset['sha256'], 'asset hash mismatch')
            path = self.directory / (identity + '-' + name)
            if path.exists():
                require(path.read_bytes() == data, 'immutable asset conflict')
                return
            # A partial asset write is never visible: stage, fsync, atomic rename.
            fd, temporary = tempfile.mkstemp(dir=self.directory, prefix='.asset-')
            try:
                with os.fdopen(fd, 'wb') as stream:
                    stream.write(data)
                    stream.flush()
                    os.fsync(stream.fileno())
                os.replace(temporary, path)
                self.sync_directory()
            finally:
                if os.path.exists(temporary):
                    os.unlink(temporary)

    def activate(self, identity):
        with self.locked() as state:
            record = self.find(state, identity)
            for a in record['assets']:
                path = self.directory / (identity + '-' + a['name'])
                require(path.exists() and digest(path.read_bytes()) == a['sha256'], 'assets incomplete')
            if record['status'] == 'reserved':
                record['status'] = 'assets'
                self.save(state)

    def asset(self, identity, name):
        with self.locked() as state:
            record = self.find(state, identity)
            require(record['status'] in ('assets', 'feed'), 'draft assets are private')
            require(any(a['name'] == name for a in record['assets']), 'unknown asset')
            return (self.directory / (identity + '-' + name)).read_bytes()

    def commit(self, identity, p):
        data = base64.b64decode(p['feed'], validate=True)
        with self.locked() as state:
            record = self.find(state, identity)
            require(digest(data) == record['candidate_feed_sha256'], 'feed hash mismatch')
            if record['status'] == 'feed':
                require(state['feed_sha256'] == digest(data), 'completed release superseded')
                return
            require(record['build'] == max(state['published_builds']), 'newer reservation exists')
            require(record['status'] == 'assets', 'assets not activated')
            require(p['expected_feed_sha256'] == record['feed_sha256'] == state['feed_sha256'], 'feed conflict; use a higher build')
            for a in record['assets']:
                require(digest((self.directory / (identity + '-' + a['name'])).read_bytes()) == a['sha256'], 'asset changed')
            state['feed'] = p['feed']
            state['feed_sha256'] = digest(data)
            record['status'] = 'feed'
            self.save(state)

    def feed(self):
        with self.locked() as state:
            require(state['feed'] is not None, 'no published feed')
            return base64.b64decode(state['feed'])
