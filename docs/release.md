# Release

This guide is for the release operator. Keep all signing credentials and keys out of the repository.

The project has no published release or configured production host, signing identity, or update key.

## Steps

1. Set the version and build in [Config/Version.xcconfig](../Config/Version.xcconfig). The build is a positive integer. It must be greater than every published build, also withdrawn ones. Never use a build number again.
2. Make a release candidate with `scripts/release.sh`. Do the dry run first.
3. Publish the candidate with `scripts/publish-release.py`. Do the plan first.
4. Make a draft GitHub Release and attach the DMG.
5. Add an arm64-only Homebrew cask to the personal tap: version, SHA-256, DMG URL, macOS 27 minimum, and uninstall paths. Run `brew audit --cask --strict`.
6. Do the release-build checks in [Release build checks](#release-build-checks).
7. Add the DMG and Homebrew install commands to the root README.

## Make a release candidate

Prepare these local inputs:

- A history file with all published builds, for example `{"published_builds": [1, 2]}`. For the first release, use `{"published_builds": []}`. The script checks the file format. It does not check that the list is complete.
- HTML release notes.
- The HTTPS feed URL, a download URL prefix for this version and build, and the public EdDSA key.
- The private key file, outside the checkout, with mode `0600` or stricter.

Run the dry run:

```sh
scripts/release.sh --dry-run \
  --history /private/tmp/published-builds.json \
  --notes /private/tmp/release-notes.html \
  --output /private/tmp/underpressured-candidate \
  --key-file /secure/external/underpressured-ed25519.key \
  --feed-url https://HOST/appcast.xml \
  --download-url-prefix https://HOST/releases/0.1.0-1/ \
  --public-key PUBLIC_BASE64_KEY \
  --identity 'Developer ID Application: NAME (TEAMID)' \
  --team TEAMID0000 --notary-profile underpressured-release
```

The dry run reads the inputs and prints the commands. It does not run them, use Keychain, connect to a server, or write output.

For a real release, remove `--dry-run` and add `--acknowledgements-reviewed`. This flag is your statement that you examined the licenses. It is not an automatic audit. The live run needs:

- a clean checkout with `LICENSE`
- Xcode 27 or later
- the Developer ID identity
- a `notarytool` Keychain profile
- a private key that matches the public key
- Sparkle 2.10.0 tools, resolved by Xcode into `DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin`. Use `--sparkle-bin` for a different location.

The script does these steps:

1. Builds the native dependencies.
2. Archives an arm64 app with Hardened Runtime and a secure timestamp, and exports it with Developer ID.
3. Notarizes the app, requires `Accepted`, keeps the notary logs, and staples the app.
4. Makes the update ZIP from the stapled app with `ditto --keepParent --sequesterRsrc`.
5. Makes a DMG with the app and an Applications link, then signs, notarizes, and staples it.
6. Signs the ZIP and makes a feed with one item. Sparkle and a separate CryptoKit check both check the signature. Deltas are off.
7. Writes `SHA256.json` with the hashes of the DMG, ZIP, and feed.

If a step fails, the script stops and keeps the partial output. Read the notary logs. Fix the cause and run again into a new, empty output directory. Do not change the files after signing. A changed archive needs new signatures.

Local tests: `python3 scripts/test_release.py` with mocks and `python3 scripts/test_release_crypto.py` with temporary keys. `scripts/test.sh` runs both.

## Publish

`scripts/publish-release.py` uses a candidate directory. It does not build, sign, or change the candidate files. Without `--publish`, it only prints a plan and makes no network requests.

Make a JSON config. Test and production must use different feeds, services, and asset locations. All URLs use HTTPS. The download prefix ends in `/<VERSION>-<BUILD>`.

```json
{
  "channel": "test",
  "feed_url": "https://HOST/test/appcast.xml",
  "download_url_prefix": "https://HOST/test/releases/0.1.0-1",
  "service_url": "https://SERVICE/test",
  "production_feed_url": "https://HOST/appcast.xml",
  "production_download_url_prefix": "https://HOST/releases/0.1.0-1",
  "production_service_url": "https://SERVICE/production"
}
```

```sh
python3 scripts/publish-release.py --candidate /private/tmp/underpressured-candidate \
  --config /secure/external/publish-test.json
```

Read the plan. To publish, add `--publish`. If the service needs a token, set `UNDERPRESSURED_PUBLISH_TOKEN`. The script sends the token only to the service.

The publisher does the steps in this order. It changes the feed last, so a failure keeps the old feed:

1. Reserve the build.
2. Upload the assets.
3. Make the assets public.
4. Download the assets without credentials and compare the bytes.
5. Replace the feed.

If a run fails, read the service state and run again with the same identity. The publisher continues from the last good step. If the candidate must change, make a new candidate with a higher build. Never use a reserved build again.

### Service contract

No production service exists yet. `scripts/publication-store.py` is a local reference store for tests. It is not a deployed service.

Each service URL is a base. The service must implement:

- `GET /state` returns the revision, `feed_sha256`, releases, and `published_builds`. An empty feed uses a null hash. Each release includes build, identity, and status. Status is `reserved`, `assets`, or `feed`. The build list includes failed and withdrawn builds.
- `POST /reserve`: takes `{channel, destination_feed_url, expected_revision, build, identity, feed_sha256, assets:[{name,sha256,url}], candidate_feed_sha256}`. It checks the revision and that the build is greater than all earlier reservations. It returns `{feed_sha256}`. A store accepts only its first channel and feed. A reservation is never removed.
- `PUT /assets/<identity>/<filename>`: creates an asset. The service accepts repeated identical bytes. It refuses different bytes.
- `POST /activate/<identity>`: makes the assets public.
- `POST /commit/<identity>`: takes `{expected_feed_sha256, feed:<base64>}`. It replaces the feed and records the release in one atomic step. It refuses a feed hash that does not match.

A failed precondition returns a non-2xx status and changes nothing. The service must not redirect. The publisher refuses redirects.

## First update-enabled release

Builds without the updater cannot find the first update-enabled release. Tell users to:

1. Finish processing.
2. Quit Underpressured.
3. Open the DMG.
4. Replace the app in Applications.
5. Eject the DMG.
6. Open the app.
7. Check the version in About.
8. Choose the automatic-update preference.

Users keep their presets and preferences. Later releases install through **Check for Updates…**. Manual install is also the recovery path when the updater fails.

## Update signing key

Generate the key on a trusted Mac:

```sh
generate_keys --account underpressured-release
```

The public key goes into the app configuration. The private key must never go into the repository, build output, CI logs, or shared folders.

- Export a copy under `umask 077` with `generate_keys --account underpressured-release -x /secure/external/underpressured-ed25519.key`. Encrypt it at once.
- Keep the key in an encrypted password manager or on encrypted offline storage. Only release maintainers get access.
- Keep one encrypted backup in a different location. Keep the decryption material separate. Test the restore from time to time.
- To restore, run `generate_keys --account underpressured-release -f <file>`. Then run `generate_keys --account underpressured-release -p` and compare with the published public key before you sign.
- If all copies are lost or the key is compromised, do not silently use a new key. Plan a key rotation for installed apps and tell users first.

`generate_keys` is in the Sparkle `bin` directory.

## Release build checks

Record the commit, macOS version, language, reviewer, date, and result.
All checks remain pending until a person records a result.

Use the signed, notarized candidate from the [release procedure](#make-a-release-candidate).

- [ ] Check that a clean checkout passes hosted CI.
- [ ] Review `App/AppIcon.icon` in the Dock.
- [ ] Review notices in the signed archive before giving the acknowledgement attestation.
- [ ] Check About's version, build, and notices link.
- [ ] Install on a Mac that never ran Underpressured. Check Gatekeeper and `spctl -a -vv` acceptance.
- [ ] Update version N to N+1. Check presets, names, preferences, language, consent, and relaunch.
- [ ] Start an update during processing. Check that installation waits for idle. Repeat with new intake during the wait.
- [ ] Check resumed installation and installation without relaunch. Check normal quit protection afterward.
- [ ] Supply an update with an invalid signature. Check that the app refuses it.
- [ ] Download published assets without credentials. Compare their bytes with `SHA256.json`.
