#!/usr/bin/env python3
"""Local Developer ID release pipeline. No publishing capability.

All subprocesses use argument vectors. Dry run performs only local reads and
prints the plan; it neither accesses Keychain nor creates output directories.
"""
import argparse
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
_CONFIG_SPEC = importlib.util.spec_from_file_location('direct_update_config', ROOT / 'scripts/validate-direct-update-config.py')
_UPDATE_CONFIG = importlib.util.module_from_spec(_CONFIG_SPEC)
_CONFIG_SPEC.loader.exec_module(_UPDATE_CONFIG)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(args):
    args = list(map(str, args))
    print('+ ' + shlex.join(args), flush=True)
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout.strip()


def versions(path):
    text = path.read_text()
    values = {}
    for key in ('MARKETING_VERSION', 'CURRENT_PROJECT_VERSION'):
        matches = re.findall(r'^\s*' + key + r'\s*=\s*([\d.]+)\s*$', text, re.M)
        require(len(matches) == 1, f'{path}: expected one {key}')
        values[key] = matches[0]
    require(re.fullmatch(r'\d+\.\d+\.\d+', values['MARKETING_VERSION']), 'marketing version must be X.Y.Z')
    require(re.fullmatch(r'[1-9]\d*', values['CURRENT_PROJECT_VERSION']), 'build must be a positive integer')
    return values['MARKETING_VERSION'], values['CURRENT_PROJECT_VERSION']


def history(path, build):
    data = json.loads(path.read_text())
    require(isinstance(data, dict) and isinstance(data.get('published_builds'), list), 'history requires published_builds array (explicit [] for first release)')
    builds = data['published_builds']
    require(all(type(n) is int and n > 0 for n in builds), 'history builds must be positive integers')
    require(len(builds) == len(set(builds)), 'history has duplicate builds')
    require(int(build) > max(builds, default=0), 'build must exceed every published build')


def https(url):
    p = urlsplit(url)
    require(p.scheme == 'https' and p.hostname and not p.username and not p.password and not p.query and not p.fragment and not any(c.isspace() for c in url), 'release URLs must be absolute HTTPS without credentials/query/fragment')


def tree_manifest(app):
    result = {}
    for p in sorted(app.rglob('*')):
        rel = str(p.relative_to(app))
        mode = stat.S_IMODE(p.lstat().st_mode)
        if not p.is_symlink():
            require(not mode & 0o022, f'group/world writable bundle entry: {rel}')
        if p.is_symlink():
            require(p.resolve().is_relative_to(app.resolve()) and p.exists(), f'escaping or dangling symlink: {rel}')
            result[rel] = ('link', os.readlink(p))
        elif p.is_file():
            result[rel] = ('file', mode, hashlib.sha256(p.read_bytes()).hexdigest())
        else:
            result[rel] = ('dir', mode)
    return result


def verify_app(app, version, build, feed, key):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    expected = dict(CFBundleShortVersionString=version, CFBundleVersion=build,
                    LSMinimumSystemVersion='27.0', CFBundleIdentifier='app.underpressured.Underpressured',
                    SUFeedURL=feed, SUPublicEDKey=key)
    for name, value in expected.items():
        require(info.get(name) == value, f'wrong app {name}: expected {value}')
    executable = app / 'Contents/MacOS' / info['CFBundleExecutable']
    require(os.access(executable, os.X_OK), 'app executable lost execute permission')
    require(run(['lipo', '-archs', executable]) == 'arm64', 'release executable must be arm64 only')
    signed = subprocess.run(['codesign', '-d', '--verbose=4', str(app)], capture_output=True, text=True, check=True)
    details = signed.stdout + signed.stderr
    require('runtime' in details and 'Timestamp=' in details and 'Authority=Developer ID Application:' in details, 'app needs timestamped Developer ID and Hardened Runtime')
    run([sys.executable, ROOT / 'scripts/inspect-update-bundle.py', 'release', app])
    tree_manifest(app)


def verify_feed(path, archive, version, build, prefix):
    root = ET.parse(path).getroot()
    items = root.findall('./channel/item')
    require(len(items) == 1, 'candidate feed must contain exactly one item')
    item = items[0]
    enclosure = item.find('enclosure')
    require(enclosure is not None, 'feed missing enclosure')
    def value(name):
        return enclosure.get(f'{{{SPARKLE}}}{name}') or item.findtext(f'{{{SPARKLE}}}{name}')
    require(value('version') == build and value('shortVersionString') == version, 'feed version mismatch')
    require(item.findtext(f'{{{SPARKLE}}}minimumSystemVersion') == '27.0', 'feed minimum OS mismatch')
    # macOS 27 is arm64-only; Sparkle may omit hardwareRequirements for it.
    hardware = item.findtext(f'{{{SPARKLE}}}hardwareRequirements')
    require(hardware in (None, 'arm64'), 'feed architecture mismatch')
    require(enclosure.get('url') == prefix.rstrip('/') + '/' + archive.name, 'feed download URL mismatch')
    require(enclosure.get('length') == str(archive.stat().st_size), 'feed archive length mismatch')
    signature = enclosure.get(f'{{{SPARKLE}}}edSignature', '')
    require(len(base64.b64decode(signature, validate=True)) == 64, 'missing EdDSA signature')
    require(item.find('description') is not None or item.find(f'{{{SPARKLE}}}releaseNotesLink') is not None, 'feed missing release notes')
    return signature


def prerequisites(a, build):
    history(a.history, build)
    https(a.feed_url)
    _UPDATE_CONFIG.validate('Release', a.feed_url, a.public_key, 'NO')
    https(a.download_url_prefix)
    require(len(base64.b64decode(a.public_key, validate=True)) == 32, 'public key must decode to 32 bytes')
    require(a.notes.is_file() and a.notes.stat().st_size > 0, 'nonempty HTML release notes required')
    require(not a.output.exists(), 'output must not exist; use a fresh candidate directory')
    pins = json.loads((ROOT / 'Underpressured.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved').read_text())['pins']
    sparkle_pins = [p for p in pins if p.get('identity') == 'sparkle']
    require(len(sparkle_pins) == 1, 'resolved package must contain exactly one Sparkle pin')
    pin = sparkle_pins[0]
    require(pin['state']['version'] == '2.10.0', 'review pipeline before changing Sparkle pin')
    # Binary package layout is verified against the resolved package version.
    candidates = list(a.sparkle_bin.parent.glob('Sparkle.xcframework/**/Resources/Info.plist'))
    require(any(plistlib.loads(p.read_bytes()).get('CFBundleShortVersionString') == '2.10.0' for p in candidates), 'Sparkle tools package must be version 2.10.0')
    for name in ('sign_update', 'generate_appcast'):
        require(os.access(a.sparkle_bin / name, os.X_OK), f'missing Sparkle {name}')
    require(a.key_file.is_file() and not a.key_file.is_symlink(), 'private key must be a regular external file')
    require(not a.key_file.resolve().is_relative_to(ROOT.resolve()), 'private key must be outside repository')
    require(stat.S_IMODE(a.key_file.stat().st_mode) & 0o077 == 0, 'private key permissions must be 0600 or stricter')
    require(a.identity.startswith('Developer ID Application:'), 'Developer ID Application identity required')
    require(re.fullmatch(r'[A-Z0-9]{10}', a.team), 'team must be a 10-character Apple Team ID')
    require(bool(a.notary_profile.strip()), 'notarytool keychain profile required')
    if a.dry_run:
        return
    require(not run(['git', '-C', ROOT, 'status', '--porcelain']), 'release requires a clean working tree')
    require((ROOT / 'LICENSE').is_file(), 'complete LICENSE prerequisite in docs/release.md')
    require(a.acknowledgements_reviewed, 'review bundled acknowledgements; pass --acknowledgements-reviewed')
    for tool in ('xcodebuild', 'xcrun', 'codesign', 'security', 'ditto', 'hdiutil', 'lipo', 'spctl', 'swift', 'cmake', 'cargo'):
        require(shutil.which(tool), f'missing tool: {tool}')
    require(re.search(r'Xcode (?:27|[3-9]\d)\.', run(['xcodebuild', '-version'])), 'Xcode 27 or later required')
    require(a.identity in run(['security', 'find-identity', '-v', '-p', 'codesigning']), 'signing identity unavailable')
    run(['xcrun', 'notarytool', 'history', '--keychain-profile', a.notary_profile, '--output-format', 'json'])
    # Verify key matches public metadata without ever printing the secret.
    with tempfile.TemporaryDirectory(prefix='underpressured-key-probe-') as d:
        probe = Path(d) / 'probe'
        probe.write_bytes(b'Underpressured release key preflight')
        sig = run([a.sparkle_bin / 'sign_update', '--ed-key-file', a.key_file, '-p', probe])
        verify_public(a.public_key, probe, sig)


def verify_public(key, path, signature):
    # Apple's CryptoKit verifies against the configured PUBLIC key, independently
    # of the key file used by Sparkle's --verify command.
    with tempfile.TemporaryDirectory(prefix='underpressured-swift-cache-') as cache:
        run(['swift', '-module-cache-path', cache, ROOT / 'scripts/verify-release-signature.swift', key, path, signature])


def commands(a, version, build):
    out = a.output
    archive = out / 'Underpressured.xcarchive'
    app = out / 'export/Underpressured.app'
    zip_path = out / 'updates' / f'Underpressured-{version}-{build}.zip'
    dmg = out / f'Underpressured-{version}-{build}.dmg'
    common = ['xcodebuild', '-project', ROOT / 'Underpressured.xcodeproj', '-scheme', 'Underpressured', '-configuration', 'Release']
    return [
        ['bash', ROOT / 'scripts/build-deps.sh'],
        common + ['archive', '-archivePath', archive, '-derivedDataPath', out / 'DerivedData', '-onlyUsePackageVersionsFromResolvedFile', 'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=NO', 'ENABLE_HARDENED_RUNTIME=YES', 'CODE_SIGN_STYLE=Manual', f'CODE_SIGN_IDENTITY={a.identity}', f'DEVELOPMENT_TEAM={a.team}', 'OTHER_CODE_SIGN_FLAGS=--timestamp', f'SPARKLE_FEED_URL={a.feed_url}', f'SPARKLE_PUBLIC_ED_KEY={a.public_key}'],
        ['xcodebuild', '-exportArchive', '-archivePath', archive, '-exportPath', out / 'export', '-exportOptionsPlist', out / 'ExportOptions.plist'],
        ['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app, out / 'notarize-app.zip'],
        ['xcrun', 'notarytool', 'submit', out / 'notarize-app.zip', '--keychain-profile', a.notary_profile, '--wait', '--output-format', 'json'],
        ['xcrun', 'stapler', 'staple', app], ['xcrun', 'stapler', 'validate', app],
        ['spctl', '--assess', '--type', 'execute', '--verbose=4', app],
        ['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app, zip_path],
        ['hdiutil', 'create', '-volname', 'Underpressured', '-srcfolder', out / 'dmg-root', '-format', 'UDZO', dmg],
        ['codesign', '--sign', a.identity, '--timestamp', dmg],
        ['xcrun', 'notarytool', 'submit', dmg, '--keychain-profile', a.notary_profile, '--wait', '--output-format', 'json'],
        ['xcrun', 'stapler', 'staple', dmg], ['xcrun', 'stapler', 'validate', dmg],
        ['codesign', '--verify', '--strict', dmg],
        ['spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', '--verbose=4', dmg],
        [a.sparkle_bin / 'sign_update', '--ed-key-file', a.key_file, '-p', zip_path],
        [a.sparkle_bin / 'generate_appcast', '--ed-key-file', a.key_file, '--download-url-prefix', a.download_url_prefix.rstrip('/') + '/', '--embed-release-notes', '--maximum-deltas', '0', '-o', out / 'updates/appcast.xml', out / 'updates'],
    ]


def execute(a, version, build, plan):
    a.output.mkdir(parents=True, mode=0o700)
    (a.output / 'updates').mkdir()
    (a.output / 'ExportOptions.plist').write_bytes(plistlib.dumps(dict(method='developer-id', teamID=a.team, signingStyle='manual', signingCertificate=a.identity)))
    app = a.output / 'export/Underpressured.app'
    zip_path = a.output / 'updates' / f'Underpressured-{version}-{build}.zip'
    for cmd in plan:
        if cmd[0] == 'ditto' and cmd[-1] == a.output / 'notarize-app.zip':
            verify_app(app, version, build, a.feed_url, a.public_key)
        if cmd[0] == 'hdiutil':
            stage = a.output / 'dmg-root'
            stage.mkdir()
            run(['ditto', app, stage / app.name])
            os.symlink('/Applications', stage / 'Applications')
        if str(cmd[0]).endswith('generate_appcast'):
            run(['ditto', '-x', '-k', zip_path, a.output / 'roundtrip'])
            restored = a.output / 'roundtrip/Underpressured.app'
            require(tree_manifest(app) == tree_manifest(restored), 'ZIP changed bytes, modes, or symlinks')
            verify_app(restored, version, build, a.feed_url, a.public_key)
            (zip_path.with_suffix('.html')).write_bytes(a.notes.read_bytes())
        result = run(cmd)
        if cmd[:3] == ['xcrun', 'notarytool', 'submit']:
            submission = json.loads(result)
            (a.output / (Path(cmd[3]).name + '.notary.json')).write_text(result + '\n')
            require(submission.get('status') == 'Accepted', 'notarization was not Accepted')
            if submission.get('id'):
                log = run(['xcrun', 'notarytool', 'log', submission['id'], '--keychain-profile', a.notary_profile])
                (a.output / (Path(cmd[3]).name + '.notary-log.json')).write_text(log + '\n')
    signature = verify_feed(a.output / 'updates/appcast.xml', zip_path, version, build, a.download_url_prefix)
    run([a.sparkle_bin / 'sign_update', '--ed-key-file', a.key_file, '--verify', zip_path, signature])
    verify_public(a.public_key, zip_path, signature)
    (a.output / 'published-history-input.json').write_bytes(a.history.read_bytes())
    (a.output / 'publication.json').write_text(json.dumps({'version': version, 'build': int(build), 'feed_url': a.feed_url, 'download_url_prefix': a.download_url_prefix.rstrip('/'), 'public_key': a.public_key}, indent=2) + '\n')
    hashes = {str(p.relative_to(a.output)): hashlib.sha256(p.read_bytes()).hexdigest() for p in [zip_path, a.output / f'Underpressured-{version}-{build}.dmg', a.output / 'updates/appcast.xml']}
    (a.output / 'SHA256.json').write_text(json.dumps(hashes, indent=2) + '\n')
    print('Local candidate verified. Nothing published. Preserve exact bytes for later publication.')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--dry-run', action='store_true')
    for name in ('history', 'notes', 'output', 'key-file'):
        p.add_argument('--' + name, type=Path, required=True)
    p.add_argument('--sparkle-bin', type=Path, default=ROOT / 'DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin')
    for name in ('feed-url', 'download-url-prefix', 'public-key', 'identity', 'team', 'notary-profile'):
        p.add_argument('--' + name, required=True)
    p.add_argument('--acknowledgements-reviewed', action='store_true')
    a = p.parse_args()
    try:
        version, build = versions(ROOT / 'Config/Version.xcconfig')
        prerequisites(a, build)
        plan = commands(a, version, build)
        if a.dry_run:
            print(f'DRY RUN: {version} ({build}); local candidate only. Credential/toolchain checks deferred; no writes or network.')
            for cmd in plan:
                print(shlex.join(list(map(str, cmd))))
        else:
            execute(a, version, build, plan)
    except (ValueError, OSError, subprocess.CalledProcessError, ET.ParseError) as e:
        print(f'error: {e}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
