# Release

This guide is for the release operator. Keep all signing credentials and keys out of the repository.

## Hosting

| Item | Value |
| --- | --- |
| Update feed | `https://a-dev.github.io/underpressured/appcast.xml`, from the `gh-pages` branch through GitHub Pages |
| ZIP and DMG | Assets of the GitHub Release with the tag `<VERSION>-<BUILD>` |
| Public EdDSA key | `NqMprqjIRcvw1MUhKIQJviJX+LLY6zB5vj7+yl2n7QU=` |

The Release build settings and `scripts/release.py` use these values by default.

## Steps

1. Set the version and the build in [Config/Version.xcconfig](../Config/Version.xcconfig). The build is a positive integer. It must be greater than all published builds, including withdrawn builds. Never use a build number again.
2. [Make a release candidate](#make-a-release-candidate) with `scripts/release.sh`. Do the dry run first.
3. [Publish](#publish) the candidate with `scripts/publish-github.py`. Do the plan first.
4. Add an arm64-only Homebrew cask to the personal tap, with the version, SHA-256, DMG URL, macOS 27 minimum, and uninstall paths. Run `brew audit --cask --strict`.
5. Do the [release build checks](#release-build-checks).
6. Add the DMG and Homebrew install commands to the root README.

## Make a release candidate

Prepare these local inputs:

- A history file with all published builds, for example `{"published_builds": [1, 2]}`. The script checks the file format. It does not check that the list is complete.
- The release notes in HTML.
- The private key file, outside the checkout, with mode `0600` or stricter.

Do the dry run:

```sh
scripts/release.sh --dry-run \
  --history /private/tmp/published-builds.json \
  --notes /private/tmp/release-notes.html \
  --output /private/tmp/underpressured-candidate \
  --key-file /secure/external/underpressured-ed25519.key \
  --identity 'Developer ID Application: NAME (TEAMID)' \
  --team TEAMID0000 --notary-profile underpressured-release
```

The dry run reads the inputs and prints the commands. It does not run them. It does not use Keychain, connect to a server, or write output.

`--feed-url`, `--public-key`, and `--download-url-prefix` use the GitHub hosting values by default. The default download prefix is `https://github.com/a-dev/underpressured/releases/download/<VERSION>-<BUILD>`.

For a real release, remove `--dry-run` and add `--acknowledgements-reviewed`. With this flag, you state that you examined the licenses. The script does not audit them. The real run needs:

- a clean checkout with `LICENSE`
- Xcode 27 or later
- the Developer ID identity
- a `notarytool` Keychain profile
- a private key that matches the public key
- the Sparkle 2.10.0 tools. Xcode puts them in `DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin`. For a different location, use `--sparkle-bin`.

The script does these steps:

1. Builds the native dependencies.
2. Archives an arm64 app with Hardened Runtime and a secure timestamp. Exports it with Developer ID.
3. Notarizes the app, requires `Accepted`, keeps the notary logs, and staples the app.
4. Makes the update ZIP from the stapled app with `ditto --keepParent --sequesterRsrc`.
5. Makes a DMG with the app and an Applications link. Signs, notarizes, and staples the DMG.
6. Signs the ZIP and makes a feed with one item. Sparkle and a separate CryptoKit check both verify the signature. Delta updates are off.
7. Writes `SHA256.json` with the hashes of the DMG, the ZIP, and the feed.

If a step fails, the script stops and keeps the partial output. Read the notary logs. Fix the cause. Run the script again with a new, empty output folder. Do not change files after signing, because a changed archive needs new signatures.

`scripts/test.sh` runs the local tests: `scripts/test_release.py` with mocks, and `scripts/test_release_crypto.py` with temporary keys.

## Publish

Before the first release, do this setup one time:

1. Create an empty `gh-pages` branch and push it.
2. In the repository settings, set Pages to deploy from the root of `gh-pages`.
3. Run `gh auth login` with an account that can create releases and push to `gh-pages`.

Make the plan. The plan sends no network requests:

```sh
scripts/publish-github.py --candidate /private/tmp/underpressured-candidate --notes /private/tmp/release-notes.md
```

To publish, add `--publish`. The script does these steps in this order:

1. Checks the candidate files against `SHA256.json`. Checks that the URLs are the GitHub hosting URLs.
2. Reads the live feed. Stops if the build is not greater than the live build.
3. Creates the GitHub Release `<VERSION>-<BUILD>` with the ZIP, the DMG, and `SHA256.json`.
4. Downloads the assets without credentials and compares the bytes.
5. Replaces `appcast.xml` on `gh-pages`. This step fails if the file changed after step 2.

The script changes the feed last, so a failure keeps the old feed.

- If step 3 or 4 fails, delete the incomplete release and its tag, then run the script again.
- If the candidate must change, make a new candidate with a greater build.
- GitHub Pages can need a few minutes to serve the new feed.
- To withdraw a release, put the previous `appcast.xml` back on `gh-pages`. Never use the withdrawn build number again.

`scripts/publish-release.py` and `scripts/publication-store.py` are an adapter for a possible self-hosted feed service. The GitHub release does not use them. Their docstrings and `scripts/test_publish_release.py` define the service contract.

## Update signing key

Make the key on a trusted Mac. `generate_keys` is in the Sparkle `bin` folder.

```sh
generate_keys --account underpressured-release
```

The public key goes into the app settings. Never put the private key in the repository, build output, CI logs, or shared folders.

- To export a copy, run `generate_keys --account underpressured-release -x /secure/external/underpressured-ed25519.key` with `umask 077`. Encrypt the copy immediately.
- Keep the key in an encrypted password manager or on encrypted offline storage. Give access only to release maintainers.
- Keep one encrypted backup in a different location. Keep the decryption material separate. Test the restore regularly.
- To restore, run `generate_keys --account underpressured-release -f <file>`. Then run `generate_keys --account underpressured-release -p`. Before you sign, compare the output with the published public key.
- If you lose all copies, or if the key is compromised, do not change to a new key without notice. Plan a key rotation for installed apps, and tell users first.

## Release build checks

Use the signed, notarized candidate from [Make a release candidate](#make-a-release-candidate). Record the commit, macOS version, language, reviewer, date, and result. All checks are pending until a person records a result.

- [ ] A clean checkout passes hosted CI.
- [ ] `App/AppIcon.icon` looks correct in the Dock.
- [ ] The notices in the signed archive are correct. Do this before you give `--acknowledgements-reviewed`.
- [ ] About shows the correct version, build, and notices link.
- [ ] On a Mac that never ran Underpressured, Gatekeeper and `spctl -a -vv` accept the app.
- [ ] An update from version N to N+1 keeps presets, names, preferences, language, and consent, and relaunches.
- [ ] An update that starts during processing waits for idle. Do the check again with new intake during the wait.
- [ ] A resumed installation and an installation without relaunch work. After them, the normal quit protection works.
- [ ] The app refuses an update with a bad signature.
- [ ] Published assets download without credentials, and their bytes match `SHA256.json`.
