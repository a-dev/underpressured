#!/usr/bin/env python3
"""Offline publication tests using disposable candidates and a loopback store."""

import base64
import hashlib
import http.server
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import threading
from concurrent.futures import ThreadPoolExecutor
import unittest
import urllib.error
from unittest import mock
from contextlib import redirect_stdout
from io import StringIO
from urllib.parse import unquote, urlsplit


SCRIPTS = Path(__file__).parent
PUBLISHER_PATH = SCRIPTS / "publish-release.py"
STORE_PATH = SCRIPTS / "publication-store.py"
PUB_SPEC = importlib.util.spec_from_file_location("publish_release", PUBLISHER_PATH)
publisher = importlib.util.module_from_spec(PUB_SPEC)
PUB_SPEC.loader.exec_module(publisher)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def snapshot(root):
    return {str(path.relative_to(root)): path.read_bytes() for path in Path(root).rglob("*") if path.is_file()}


def make_candidate(root, build=42, version="2.3.1", channel="test", base="https://updates.example.test"):
    root = Path(root)
    candidate = root / f"candidate-{channel}-{build}"
    updates = candidate / "updates"
    updates.mkdir(parents=True)
    prefix = f"{base}/{'production-downloads' if channel == 'production' else 'downloads'}/{version}-{build}"
    archive = f"Underpressured-{version}-{build}.zip"
    archive_data = b"fixture zip bytes for build " + str(build).encode()
    dmg_name = f"Underpressured-{version}-{build}.dmg"
    dmg_data = b"fixture dmg bytes for build " + str(build).encode()
    feed = (f'''<?xml version="1.0" encoding="UTF-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
<title>Release</title><description>Fixture notes</description>
<sparkle:minimumSystemVersion>27.0</sparkle:minimumSystemVersion>
<enclosure url="{prefix}/{archive}" length="{len(archive_data)}"
 sparkle:version="{build}" sparkle:shortVersionString="{version}"
 sparkle:edSignature="{base64.b64encode(bytes(range(64))).decode()}" />
</item></channel></rss>''').encode()
    (updates / archive).write_bytes(archive_data)
    (candidate / dmg_name).write_bytes(dmg_data)
    (updates / "appcast.xml").write_bytes(feed)
    files = {"updates/appcast.xml": feed, "updates/" + archive: archive_data, dmg_name: dmg_data}
    (candidate / "SHA256.json").write_text(json.dumps({name: sha(data) for name, data in files.items()}))
    (candidate / "published-history-input.json").write_text('{"published_builds": []}')
    config = {
        "channel": channel,
        "feed_url": f"{base}/feed/{channel}.xml",
        "production_feed_url": f"{base}/feed/production.xml",
        "download_url_prefix": prefix,
        "service_url": f"{base}/service",
        "production_service_url": f"{base}/production-service",
        "production_download_url_prefix": f"{base}/production-downloads/{version}-{build}",
    }
    if channel == "production":
        config["feed_url"] = config["production_feed_url"]
        config["service_url"] = config["production_service_url"]
    config_path = root / f"{channel}-config.json"
    config_path.write_text(json.dumps(config))
    (candidate / "publication.json").write_text(json.dumps({
        "version": version, "build": build, "feed_url": config["feed_url"],
        "download_url_prefix": config["download_url_prefix"].rstrip("/"),
        "public_key": base64.b64encode(bytes(range(32))).decode(),
    }))
    return candidate, config, config_path, files


def reservation(c, config, expected_revision, feed_sha256):
    return {"channel": config["channel"], "destination_feed_url": config["feed_url"],
            "expected_revision": expected_revision, "build": c["build"],
            "identity": c["identity"], "feed_sha256": feed_sha256,
            "assets": c["assets"], "candidate_feed_sha256": c["feed_sha256"]}


class PublicationHTTP:
    """Small HTTP adapter that exercises the real publication Store over loopback."""

    def __init__(self, state_dir):
        if not STORE_PATH.exists():
            raise RuntimeError("publication-store.py has not been added yet")
        spec = importlib.util.spec_from_file_location("publication_store", STORE_PATH)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.module = module
        self.store = module.Store(state_dir)
        self.events = []
        self.anonymous_faults = {}
        self.upload_failure_after = None
        self.upload_count = 0
        self.redirect_paths = {}

        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *_args):
                pass

            def reply(self, status, data, content_type="application/json"):
                self.send_response(status)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def record(self, method):
                outer.events.append((method, urlsplit(self.path).path, self.headers.get("Authorization")))

            def do_GET(self):
                self.record("GET")
                path = self.path
                if path in outer.redirect_paths:
                    self.send_response(302)
                    self.send_header("Location", outer.redirect_paths[path])
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                if path == "/service/state":
                    data = json.dumps(outer.store.state()).encode()
                    return self.reply(200, data)
                if path.startswith("/downloads/"):
                    fault = outer.anonymous_faults.get(path)
                    if fault == "unavailable":
                        return self.reply(503, b"temporarily unavailable", "text/plain")
                    try:
                        identity, name = outer.asset_route(path)
                        data = outer.store.asset(identity, name)
                        if data is None:
                            return self.reply(404, b"not found", "text/plain")
                        if fault == "wrong":
                            data += b"unexpected bytes"
                        return self.reply(200, data, "application/octet-stream")
                    except (KeyError, ValueError, IndexError):
                        return self.reply(404, b"not found", "text/plain")
                if path.startswith("/feed/"):
                    data = outer.feed_for(path)
                    if data is None:
                        return self.reply(404, b"not found", "text/plain")
                    return self.reply(200, data, "application/xml")
                return self.reply(404, b"not found", "text/plain")

            def do_POST(self):
                self.record("POST")
                length = int(self.headers.get("Content-Length", "0"))
                body = self.rfile.read(length)
                try:
                    value = json.loads(body) if body else {}
                    if self.path == "/service/reserve":
                        result = outer.store.reserve(value)
                    elif self.path.startswith("/service/activate/"):
                        result = outer.store.activate(self.path.rsplit("/", 1)[1])
                    elif self.path.startswith("/service/commit/"):
                        result = outer.store.commit(self.path.rsplit("/", 1)[1], value)
                    else:
                        return self.reply(404, b"not found", "text/plain")
                    return self.reply(200, json.dumps(result or {}).encode())
                except Exception as exc:
                    return self.reply(409, json.dumps({"error": str(exc)}).encode())

            def do_PUT(self):
                self.record("PUT")
                outer.upload_count += 1
                if outer.upload_failure_after is not None and outer.upload_count > outer.upload_failure_after:
                    return self.reply(503, b"simulated upload failure", "text/plain")
                parts = self.path.split("/", 4)
                if len(parts) != 5 or parts[1:3] != ["service", "assets"]:
                    return self.reply(404, b"not found", "text/plain")
                identity, name = parts[3], unquote(parts[4])
                data = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                try:
                    result = outer.store.upload(identity, name, data)
                    return self.reply(200, json.dumps(result or {}).encode())
                except Exception as exc:
                    return self.reply(409, json.dumps({"error": str(exc)}).encode())

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = f"http://127.0.0.1:{self.server.server_port}"

    def asset_route(self, path):
        filename = unquote(path.rsplit("/", 1)[-1])
        state = self.store.state()
        for release in reversed(state["releases"]):
            if any(a["name"] == filename for a in release.get("assets", [])):
                return release["identity"], filename
        raise KeyError(filename)

    def feed_for(self, _path):
        feed_method = getattr(self.store, "feed", None)
        return feed_method() if feed_method else None

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)


class PublishReleaseTests(unittest.TestCase):
    def test_offline_cli_validates_exact_assets_and_never_opens_network(self):
        with tempfile.TemporaryDirectory() as directory:
            candidate, config, config_path, files = make_candidate(directory)
            # Candidate validation checks all three exact hashes and parses the actual feed.
            result = publisher.candidate(candidate, config, loopback=True)
            self.assertEqual(result["files"], {Path(k).name: v for k, v in files.items()})
            output = StringIO()
            before = snapshot(directory)
            with mock.patch.object(sys, "argv", [str(PUBLISHER_PATH), "--candidate", str(candidate), "--config", str(config_path)]), \
                 mock.patch.object(publisher, "build_opener", side_effect=AssertionError("network opened")), \
                 redirect_stdout(output):
                self.assertEqual(publisher.main(), 0)
            self.assertIn("OFFLINE PLAN: no network or writes", output.getvalue())
            self.assertEqual(snapshot(directory), before)

    def test_channel_and_download_prefix_must_match(self):
        with tempfile.TemporaryDirectory() as directory:
            candidate, config, _, _ = make_candidate(directory)
            bad = dict(config, feed_url=config["production_feed_url"])
            with self.assertRaisesRegex(ValueError, "test feed_url must differ"):
                publisher.candidate(candidate, bad, loopback=True)
            for key in ("service_url", "download_url_prefix"):
                bad = dict(config, **{key: config["production_" + key]})
                with self.subTest(key=key), self.assertRaisesRegex(ValueError, f"test {key} must differ"):
                    publisher.candidate(candidate, bad, loopback=True)
            bad = dict(config, download_url_prefix="http://127.0.0.1:1/downloads/2.3.1-41")
            with self.assertRaisesRegex(ValueError, "different download URLs"):
                publisher.candidate(candidate, bad, loopback=True)

    def test_loopback_publish_verifies_anonymous_assets_and_commits_feed_last(self):
        with tempfile.TemporaryDirectory() as directory:
            server = PublicationHTTP(Path(directory) / "store")
            self.addCleanup(server.close)
            candidate_dir, config, _, _ = make_candidate(directory, base=server.base)
            c = publisher.candidate(candidate_dir, config, loopback=True)
            # Every service write and anonymous read goes through actual HTTP loopback.
            transport = publisher.HTTP(config, "fixture-token")
            self.assertEqual(publisher.publish(c, config, transport), "published; anonymous assets and feed verified")
            events = list(server.events)
            commit_index = next(i for i, event in enumerate(events) if event[1].startswith("/service/commit/"))
            self.assertTrue(any(e[1] == "/service/reserve" and e[2] == "Bearer fixture-token" for e in events))
            self.assertTrue(any(e[1].startswith("/service/assets/") and e[0] == "PUT" and e[2] == "Bearer fixture-token" for e in events))
            self.assertTrue(any(e[1].startswith("/service/activate/") and e[2] == "Bearer fixture-token" for e in events))
            precommit = events[:commit_index]
            self.assertEqual(sum(e[1].startswith("/downloads/") for e in precommit), len(c["assets"]))
            self.assertTrue(all(e[2] is None for e in precommit if e[1].startswith("/downloads/")))
            self.assertGreater(next(i for i, e in enumerate(events) if e[1] == "/feed/test.xml"), commit_index)
            self.assertTrue(all(e[2] is None for e in events if e[1].startswith(("/downloads/", "/feed/"))))
            self.assertEqual(transport.anonymous(config["feed_url"]), c["feed"])
            state = server.store.state()
            self.assertEqual(state["feed_sha256"], c["feed_sha256"])
            self.assertIn(c["build"], state["published_builds"])
            for asset in c["assets"]:
                self.assertEqual(sha(transport.anonymous(asset["url"])), asset["sha256"])
            self.assertEqual(publisher.publish(c, config, transport), "already published; exact bytes verified")

    def test_unavailable_or_wrong_anonymous_asset_keeps_previous_feed(self):
        for fault in ("unavailable", "wrong"):
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as directory:
                server = PublicationHTTP(Path(directory) / "store")
                self.addCleanup(server.close)
                old_dir, old_config, _, _ = make_candidate(directory, build=41, base=server.base)
                old = publisher.candidate(old_dir, old_config, loopback=True)
                transport = publisher.HTTP(old_config)
                publisher.publish(old, old_config, transport)
                new_dir, new_config, _, _ = make_candidate(directory, build=42, base=server.base)
                new = publisher.candidate(new_dir, new_config, loopback=True)
                target = new["assets"][0]["url"]
                server.anonymous_faults[urlsplit(target).path] = fault
                if fault == "unavailable":
                    with self.assertRaises(urllib.error.HTTPError) as caught:
                        publisher.publish(new, new_config, transport)
                    caught.exception.close()
                else:
                    with self.assertRaisesRegex(ValueError, "anonymous asset hash mismatch"):
                        publisher.publish(new, new_config, transport)
                self.assertEqual(server.store.feed(), old["feed"])
                self.assertEqual(server.store.state()["feed_sha256"], old["feed_sha256"])

    def test_upload_failure_after_one_asset_keeps_feed_and_retry_completes(self):
        with tempfile.TemporaryDirectory() as directory:
            server = PublicationHTTP(Path(directory) / "store")
            self.addCleanup(server.close)
            old_dir, config, _, _ = make_candidate(directory, build=41, base=server.base)
            old = publisher.candidate(old_dir, config, loopback=True)
            transport = publisher.HTTP(config)
            publisher.publish(old, config, transport)
            new_dir, new_config, _, _ = make_candidate(directory, build=42, base=server.base)
            new = publisher.candidate(new_dir, new_config, loopback=True)
            server.upload_count = 0
            server.upload_failure_after = 1
            with self.assertRaises(urllib.error.HTTPError) as caught:
                publisher.publish(new, new_config, transport)
            caught.exception.close()
            self.assertEqual(server.store.feed(), old["feed"])
            server.upload_failure_after = None
            self.assertEqual(publisher.publish(new, new_config, transport), "published; anonymous assets and feed verified")
            self.assertEqual(server.store.feed(), new["feed"])

    def test_commit_response_loss_is_reconciled_by_exact_rerun(self):
        with tempfile.TemporaryDirectory() as directory:
            server = PublicationHTTP(Path(directory) / "store")
            self.addCleanup(server.close)
            candidate_dir, config, _, _ = make_candidate(directory, base=server.base)
            c = publisher.candidate(candidate_dir, config, loopback=True)
            transport = publisher.HTTP(config)
            real_call = transport.call
            lose_commit_response = True

            def commit_then_drop(method, path, value=None, raw=None):
                nonlocal lose_commit_response
                result = real_call(method, path, value, raw)
                if path.startswith("/commit/") and lose_commit_response:
                    lose_commit_response = False
                    raise OSError("commit succeeded but response was lost")
                return result

            transport.call = commit_then_drop
            with self.assertRaisesRegex(OSError, "response was lost"):
                publisher.publish(c, config, transport)
            self.assertEqual(server.store.feed(), c["feed"])
            self.assertEqual(publisher.publish(c, config, transport), "already published; exact bytes verified")

    def test_destination_aliases_cannot_mix_channels(self):
        with tempfile.TemporaryDirectory() as directory:
            candidate, config, _, _ = make_candidate(directory)
            for key in ('feed_url', 'service_url', 'download_url_prefix'):
                bad = dict(config)
                bad['production_' + key] = config[key].replace('updates.example.test', 'UPDATES.EXAMPLE.TEST.:443')
                with self.subTest(destination=key), self.assertRaisesRegex(ValueError, 'must differ'):
                    publisher.candidate(candidate, bad)

    def test_production_config_requires_canonical_feed_url(self):
        with tempfile.TemporaryDirectory() as directory:
            candidate, config, _, _ = make_candidate(directory, channel="production")
            self.assertEqual(publisher.candidate(candidate, config, loopback=True)["build"], 42)
            bad = dict(config, feed_url="http://127.0.0.1:1/feed/test.xml")
            with self.assertRaisesRegex(ValueError, "production feed"):
                publisher.candidate(candidate, bad, loopback=True)
            bad = dict(config, service_url="http://127.0.0.1:1/service")
            with self.assertRaisesRegex(ValueError, "production service_url"):
                publisher.candidate(candidate, bad, loopback=True)
            bad = dict(config, download_url_prefix="http://127.0.0.1:1/downloads/2.3.1-42")
            with self.assertRaisesRegex(ValueError, "production download_url_prefix"):
                publisher.candidate(candidate, bad, loopback=True)

    def test_interrupted_asset_upload_and_commit_can_be_resumed(self):
        with tempfile.TemporaryDirectory() as directory:
            server = PublicationHTTP(Path(directory) / "store")
            self.addCleanup(server.close)
            candidate_dir, config, _, _ = make_candidate(directory, base=server.base)
            c = publisher.candidate(candidate_dir, config, loopback=True)
            transport = publisher.HTTP(config)
            real_call = transport.call
            faults = {"upload": True, "commit": True}

            def fail_once(method, path, value=None, raw=None):
                if path.startswith("/assets/") and faults["upload"]:
                    faults["upload"] = False
                    raise OSError("simulated connection loss during upload")
                if path.startswith("/commit/") and faults["commit"]:
                    faults["commit"] = False
                    raise OSError("simulated connection loss during commit")
                return real_call(method, path, value, raw)

            transport.call = fail_once
            with self.assertRaisesRegex(OSError, "upload"):
                publisher.publish(c, config, transport)
            self.assertIsNone(server.store.state()["feed_sha256"])
            with self.assertRaisesRegex(OSError, "commit"):
                publisher.publish(c, config, transport)
            self.assertIsNone(server.store.state()["feed_sha256"])
            # The same reservation and immutable uploaded bytes are safe to retry.
            self.assertEqual(publisher.publish(c, config, transport), "published; anonymous assets and feed verified")
            self.assertEqual(server.store.state()["feed_sha256"], c["feed_sha256"])

    def test_store_rejects_conflicting_build_and_stale_reservation_revision(self):
        with tempfile.TemporaryDirectory() as directory:
            server = PublicationHTTP(Path(directory) / "store")
            self.addCleanup(server.close)
            candidate_dir, config, _, _ = make_candidate(directory)
            c = publisher.candidate(candidate_dir, config)
            payload = reservation(c, config, 0, None)
            server.store.reserve(payload)
            conflicting = dict(payload, identity="0" * 64)
            with self.assertRaisesRegex(ValueError, "conflicting build"):
                server.store.reserve(conflicting)
            stale = dict(payload, build=c["build"] + 1, identity="1" * 64)
            with self.assertRaisesRegex(ValueError, "stale revision"):
                server.store.reserve(stale)
            production_dir, production_config, _, _ = make_candidate(directory, channel="production")
            production = publisher.candidate(production_dir, production_config)
            with self.assertRaisesRegex(ValueError, "different channel/feed"):
                server.store.reserve(reservation(production, production_config, 1, None))

    def test_local_history_missing_remotely_stops_before_reservation(self):
        with tempfile.TemporaryDirectory() as directory:
            server = PublicationHTTP(Path(directory) / "store")
            self.addCleanup(server.close)
            candidate_dir, config, _, _ = make_candidate(directory, base=server.base)
            (candidate_dir / "published-history-input.json").write_text('{"published_builds": [7]}')
            c = publisher.candidate(candidate_dir, config, loopback=True)
            with self.assertRaisesRegex(ValueError, "remote history omits local"):
                publisher.publish(c, config, publisher.HTTP(config))
            self.assertEqual(server.store.state()["releases"], [])

    def test_same_build_with_changed_bytes_conflicts(self):
        with tempfile.TemporaryDirectory() as directory:
            server = PublicationHTTP(Path(directory) / "store")
            self.addCleanup(server.close)
            candidate_dir, config, _, _ = make_candidate(directory, base=server.base)
            original = publisher.candidate(candidate_dir, config, loopback=True)
            transport = publisher.HTTP(config)
            publisher.publish(original, config, transport)
            dmg = candidate_dir / "Underpressured-2.3.1-42.dmg"
            dmg.write_bytes(b"changed dmg bytes for build 42")
            hashes_path = candidate_dir / "SHA256.json"
            hashes = json.loads(hashes_path.read_text())
            hashes["Underpressured-2.3.1-42.dmg"] = sha(dmg.read_bytes())
            hashes_path.write_text(json.dumps(hashes))
            changed = publisher.candidate(candidate_dir, config, loopback=True)
            self.assertNotEqual(changed["identity"], original["identity"])
            with self.assertRaisesRegex(ValueError, "build conflicts"):
                publisher.publish(changed, config, transport)
            self.assertEqual(server.store.feed(), original["feed"])

    def test_newer_reservation_blocks_old_commit_then_higher_build_recovers_without_rollback(self):
        with tempfile.TemporaryDirectory() as directory:
            state_dir = Path(directory) / "store"
            server = PublicationHTTP(state_dir)
            self.addCleanup(server.close)
            def candidate(build):
                path, config, _, _ = make_candidate(directory, build=build, base=server.base)
                return publisher.candidate(path, config, loopback=True), config

            c41, config = candidate(41)
            transport = publisher.HTTP(config)
            publisher.publish(c41, config, transport)
            c42, config = candidate(42)
            publisher.publish(c42, config, transport)
            c43, config = candidate(43)
            c44, config = candidate(44)

            reserve_newer_during_read = True
            real_anonymous = transport.anonymous

            def interleave_reservation(target):
                nonlocal reserve_newer_during_read
                if reserve_newer_during_read and target in {a["url"] for a in c43["assets"]}:
                    reserve_newer_during_read = False
                    state = server.store.state()
                    server.store.reserve(reservation(c44, config, state["revision"], state["feed_sha256"]))
                return real_anonymous(target)

            transport.anonymous = interleave_reservation
            with self.assertRaises(urllib.error.HTTPError) as caught:
                publisher.publish(c43, config, transport)
            caught.exception.close()
            self.assertEqual(server.store.feed(), c42["feed"])
            transport.anonymous = real_anonymous
            self.assertEqual(publisher.publish(c44, config, transport), "published; anonymous assets and feed verified")
            with self.assertRaisesRegex(ValueError, "completed release superseded"):
                publisher.publish(c42, config, transport)
            with self.assertRaises(urllib.error.HTTPError) as caught:
                publisher.publish(c43, config, transport)
            caught.exception.close()
            state = server.store.state()
            self.assertEqual(state["published_builds"], [41, 42, 43, 44])
            self.assertEqual(state["feed_sha256"], c44["feed_sha256"])
            restarted = server.store.__class__(state_dir)
            self.assertEqual(restarted.state()["published_builds"], [41, 42, 43, 44])
            self.assertEqual(restarted.feed(), c44["feed"])

    def test_concurrent_reservations_with_same_revision_have_one_winner(self):
        with tempfile.TemporaryDirectory() as directory:
            server = PublicationHTTP(Path(directory) / "store")
            self.addCleanup(server.close)
            payloads = []
            for build in (41, 42):
                candidate_dir, config, _, _ = make_candidate(directory, build=build)
                c = publisher.candidate(candidate_dir, config)
                payloads.append(reservation(c, config, 0, None))
            stores = [server.store.__class__(Path(directory) / "store") for _ in range(2)]
            barrier = threading.Barrier(2)

            def attempt(index):
                barrier.wait()
                try:
                    stores[index].reserve(payloads[index])
                    return "reserved"
                except ValueError:
                    return "stale"

            with ThreadPoolExecutor(max_workers=2) as pool:
                outcomes = list(pool.map(attempt, range(2)))
            self.assertCountEqual(outcomes, ["reserved", "stale"])
            state = server.store.state()
            self.assertEqual(len(state["releases"]), 1)
            self.assertEqual(len(state["published_builds"]), 1)

    def test_draft_assets_stay_private_and_bad_upload_bytes_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            server = PublicationHTTP(Path(directory) / "store")
            self.addCleanup(server.close)
            candidate_dir, config, _, _ = make_candidate(directory)
            c = publisher.candidate(candidate_dir, config)
            payload = reservation(c, config, 0, None)
            server.store.reserve(payload)
            asset = c["assets"][0]
            with self.assertRaisesRegex(ValueError, "asset hash mismatch"):
                server.store.upload(c["identity"], asset["name"], b"wrong bytes")
            with self.assertRaisesRegex(ValueError, "draft assets are private"):
                server.store.asset(c["identity"], asset["name"])

    def test_state_replace_failure_preserves_feed_and_history_then_retry_succeeds(self):
        with tempfile.TemporaryDirectory() as directory:
            state_dir = Path(directory) / "store"
            server = PublicationHTTP(state_dir)
            self.addCleanup(server.close)
            old_dir, config, _, _ = make_candidate(directory, build=41, base=server.base)
            old = publisher.candidate(old_dir, config, loopback=True)
            transport = publisher.HTTP(config)
            publisher.publish(old, config, transport)
            new_dir, new_config, _, _ = make_candidate(directory, build=42, base=server.base)
            new = publisher.candidate(new_dir, new_config, loopback=True)
            real_replace = server.module.os.replace
            failed = False

            def fail_state_replace(source, destination):
                nonlocal failed
                if Path(destination).name == "state.json" and not failed:
                    failed = True
                    raise OSError("simulated atomic state replacement failure")
                return real_replace(source, destination)

            real_call = transport.call

            def fail_during_commit(method, path, value=None, raw=None):
                if path.startswith("/commit/"):
                    with mock.patch.object(server.module.os, "replace", side_effect=fail_state_replace):
                        return real_call(method, path, value, raw)
                return real_call(method, path, value, raw)

            transport.call = fail_during_commit
            with self.assertRaises(urllib.error.HTTPError) as caught:
                publisher.publish(new, new_config, transport)
            caught.exception.close()
            restarted = server.module.Store(state_dir)
            self.assertEqual(restarted.feed(), old["feed"])
            self.assertEqual(restarted.state()["published_builds"], [41, 42])
            self.assertEqual(next(r for r in restarted.state()["releases"] if r["build"] == 42)["status"], "assets")
            self.assertEqual(publisher.publish(new, new_config, transport), "published; anonymous assets and feed verified")
            self.assertEqual(restarted.feed(), new["feed"])

    def test_candidate_tampered_zip_or_dmg_hash_is_rejected(self):
        for name in ("Underpressured-2.3.1-42.zip", "Underpressured-2.3.1-42.dmg"):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                candidate_dir, config, _, _ = make_candidate(directory)
                path = candidate_dir / (Path("updates") / name if name.endswith(".zip") else Path(name))
                path.write_bytes(path.read_bytes() + b"tampered")
                with self.assertRaisesRegex(ValueError, "candidate hash mismatch"):
                    publisher.candidate(candidate_dir, config)

    def test_candidate_feed_url_must_match_built_download_url(self):
        with tempfile.TemporaryDirectory() as directory:
            candidate_dir, config, _, _ = make_candidate(directory)
            feed_path = candidate_dir / "updates" / "appcast.xml"
            feed = feed_path.read_bytes().replace(b"/downloads/2.3.1-42/", b"/downloads/2.3.1-41/")
            feed_path.write_bytes(feed)
            manifest_path = candidate_dir / "SHA256.json"
            manifest = json.loads(manifest_path.read_text())
            manifest["updates/appcast.xml"] = sha(feed)
            manifest_path.write_text(json.dumps(manifest))
            with self.assertRaisesRegex(ValueError, "feed download URL mismatch"):
                publisher.candidate(candidate_dir, config)

    def test_http_redirects_are_rejected_without_following_target(self):
        with tempfile.TemporaryDirectory() as directory:
            server = PublicationHTTP(Path(directory) / "store")
            self.addCleanup(server.close)
            redirect_path = "/redirect-service/state"
            server.redirect_paths[redirect_path] = server.base + "/service/state"
            config = {"service_url": server.base + "/redirect-service"}
            transport = publisher.HTTP(config, "fixture-token")
            with self.assertRaisesRegex(ValueError, "redirects are forbidden"):
                transport.call("GET", "/state")
            self.assertEqual([event for event in server.events if event[1] == redirect_path][0][2], "Bearer fixture-token")
            self.assertFalse(any(event[1] == "/service/state" for event in server.events))


if __name__ == "__main__":
    unittest.main()
