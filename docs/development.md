# Build and test

## Build the app

Use an Apple Silicon Mac with macOS 27 or later and Xcode 27.
Install CMake, Ninja, and Rust with Cargo.
Run these commands from the repository root:

```sh
scripts/build-deps.sh
open Underpressured.xcodeproj
```

Run the `Underpressured` scheme. The first dependency build fetches pinned sources.
Later builds reuse `Vendor/.stamp` when inputs match.

## Distribution variants

| Target | Update support |
| --- | --- |
| `Underpressured` | Direct distribution with Sparkle 2.10.0 |
| `UnderpressuredUpdaterFree` | No Sparkle, helpers, update configuration, or `DIRECT_DISTRIBUTION` code |

The updater-free target shares app sources and package products. It does not enable sandboxing.
Debug builds disable updates unless explicit fixture settings enable them.
Disabled updates show no controls and send no requests.

For a local update fixture:

```sh
xcodebuild build -project Underpressured.xcodeproj -scheme Underpressured \
  -configuration Debug -derivedDataPath /tmp/underpressured-fixture \
  SPARKLE_TEST_FEED=YES \
  SPARKLE_FEED_URL=http://127.0.0.1:8765/appcast.xml \
  SPARKLE_PUBLIC_ED_KEY='<fixture public key in base64>'
```

Fixtures accept only localhost, 127.0.0.1, or ::1. Manual checks use the fixture feed. Scheduled checks remain disabled.

Direct Release requires an HTTPS feed URL without credentials, query, or fragment.
`SPARKLE_PUBLIC_ED_KEY` must decode to 32 bytes. Invalid configuration fails the build.
Release uses Sparkle's consent flow and disables automatic installation.
Direct Debug uses `Config/Direct-Debug.entitlements` for ad hoc Sparkle development.
Its library-validation exception does not apply to Release.
See [Release](release.md) for distribution signing.

Inspect a built bundle:

```sh
python3 scripts/inspect-update-bundle.py MODE /absolute/path/to/App.app
```

Use `disabled`, `fixture`, `release`, or `updater-free` for `MODE`.
The check inspects metadata, Mach-O links and symbols, helpers, and signatures.

## Run tests

Run the same entry point as CI:

```sh
scripts/test.sh
```

The gate runs architecture and localization checks, update and release fixtures, Rust tests, native dependency builds, Swift package tests, and app tests.
It then checks compiler-extracted localization catalogs and release signatures against that run's build.
A failure stops later checks and returns a failing exit status.

Each run creates fresh package and app build directories.
The printed artifact directory contains suite logs, `results.tsv`, native diagnostics, and the Xcode result bundle.
`UP_TEST_ARTIFACTS` selects the parent directory. Remove retained builds after diagnosis.

After building dependencies, use focused commands during development:

```sh
swift test --package-path Packages/UnderpressuredKit --filter PresetListTests
cargo test --manifest-path rust/up-codecs/Cargo.toml
python3 scripts/check-architecture.py
python3 scripts/test_check_architecture.py
```

Use separate `--scratch-path` directories for concurrent SwiftPM builds.
The package still declares local XCFrameworks, even when a selected test target imports Core alone.

| Test location | Responsibility |
| --- | --- |
| `Packages/UnderpressuredKit/Tests/UnderpressuredCoreTests/` | Domain invariants and pure policies |
| `Packages/UnderpressuredKit/Tests/UnderpressuredApplicationTests/` | Intake, queue, pipeline, paths, cancellation, and pixel budgets |
| `Packages/UnderpressuredKit/Tests/MacPlatformTests/` | Saved settings and platform services |
| `Packages/UnderpressuredKit/Tests/AppModelTests/` | Presentation, selection, undo, and lifecycle decisions |
| `Packages/UnderpressuredKit/Tests/ImageEngineTests/` | Codecs, resize, color, metadata, and fidelity |
| `Packages/UnderpressuredKit/Tests/LocalFileSystemTests/` | Real file operations and commit safety |
| `Packages/UnderpressuredKit/Tests/IntegrationTests/` | Real pipeline and cancellation stress |
| `AppTests/` | Native app integration and accessibility checks |

The [coverage map](../Packages/UnderpressuredKit/Tests/COVERAGE.md) locates individual behavior checks.
Test source defines fixtures, thresholds, and assertions.

### Cancellation and file checks

Cancellation stress runs 1,000 rounds per destination with four concurrent items and a ten-minute limit.
It checks terminal identities, source preservation, output validity, marks, savings, and temporary-file cleanup.
The seed repeats delay choices. It cannot repeat OS scheduling.

```sh
swift test --package-path Packages/UnderpressuredKit --filter CancelStressTests
UP_CANCEL_SEED=20261028 UP_CANCEL_ROUNDS=5 swift test --package-path Packages/UnderpressuredKit --filter CancelStressTests
```

The second command is a short development replay. Omit overrides for acceptance.
Cancellation stress uses whole-second fixture dates; mark boundary coverage is in `StoredOptimizationMarkTests`.

Real Trash tests require a writable volume Trash. Each test removes only its exact owned Trash URL.
Never search the account's Trash for fixtures.
`trashCleanup_onlyRemovesOwnedURL_afterSuccessOrFailure` records one deliberate known issue to check cleanup after assertion failure.

Set `UP_TEST_VOLUME_ROOT` to a disposable mounted volume for actual volume case checks:

```sh
UP_TEST_VOLUME_ROOT=/path/to/mount swift test --package-path Packages/UnderpressuredKit --filter volumeCaseSensitivity_matchesURLResourceValue
```

Use separate owned APFS and case-sensitive APFS images to check both policies. Detach owned mounts after the tests, including failures.

### Native UI and localization

Native tests require Xcode 27 and a logged-in macOS GUI session.
They check accessibility identifiers, selection, focus, geometry, and actions.
Only the reviewed checkmark crop uses a pixel comparison.
Its pinned environment and review policy are in [AppTests/Fixtures/README.md](../AppTests/Fixtures/README.md).

```sh
xcodebuild test -project Underpressured.xcodeproj -scheme Underpressured \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/underpressured-native-ui
scripts/check-localized-ui.sh
```

The companion starts a fresh process for each of seven languages.
It produces logs, screenshots, accessibility dumps, and contact sheets.
`LOCALIZATION_BUILD_PATH` selects its build directory. `UP_UI_ARTIFACTS` selects a fresh artifact directory.
Captures require [human review](#native-gestures-and-voiceover). They do not establish VoiceOver speech or gesture quality.

## Run performance checks

Build native dependencies first. These scripts build the Release SoakHarness and remove temporary image data:

```sh
scripts/bench.sh
SOAK_SMALL=500 SOAK_LARGE=5 scripts/soak.sh
scripts/soak.sh
```

The benchmark defaults to three runs of 100 generated 12-megapixel JPEGs with Web and export settings.
The full soak uses 10,000 small files, 100 large images, six cancelled rounds, and completed replacement and export rounds.
Allow about 2 GB of free disk space. The soak checks output decoding, cleanup, completion, failures, and peak memory.
Its default memory limit is 5,120 MB.

Scheduler tests use an operation budget of at most three state-transition attempts per admitted item.
They check workloads of 1,000, 5,000, and 10,000 items, terminal identities, and resource retirement.
Use [bench/README.md](../bench/README.md) for codec comparisons and corpus setup.

## Configure CI

`.github/workflows/ci.yml` handles pull requests, pushes to `main`, tags, and manual dispatch.
It uses the ephemeral hosted arm64 `xcode-27` runner with read-only repository permissions.
It cancels older work for the same ref. Never route fork code to a persistent self-hosted runner.

The workflow runs `scripts/test.sh`, then the seven-language UI companion.
Its final upload step retains available evidence after success or failure.
An early failure leaves later checks unexecuted.
A real server-side run and required branch protection remain unverified.
Inspect a real pull-request run on the hosted runner and check repository eligibility.
The private repository's protection API requires a plan upgrade.

## Change workflow

1. Read the [architecture](architecture.md) and [glossary](GLOSSARY.md).
2. Identify the owner and product rule that the change affects.
3. Update behavior, glossary, and architecture text when their meaning changes.
4. Check construction, mutation, and restoration paths where relevant.
5. Run focused behavior checks. Run `scripts/test.sh` for integration acceptance.
6. Report executed commands, results, and limitations. Keep unexecuted checks marked as pending.

Place product rules in Core, execution and ports in Application, OS effects in adapters, and UI state in presentation.
Review effects and public APIs as well as imports.

## Build and test constraints

- Keep Rust LTO disabled unless Xcode linking succeeds with it enabled.
- Keep ad hoc Hardened Runtime flags limited to Release. Debug library validation rejects test bundles and debug dylibs.
- Set extended attributes before applying read-only permissions to temporary files.
- Check user metadata when testing stripping. ImageIO can synthesize EXIF fields for PNG.
- Give gated queue tests a time limit and release gates during cleanup.

## Native gestures and VoiceOver

Record the commit, macOS version, language, reviewer, date, and result for each check.
Attach observations or captures for failures. All checks remain pending until a person records a result.

Prepare completed, skipped, failed, and unavailable rows.
Use several presets, a 70-character name, and a long export path.
Repeat layout checks at minimum window width. Use VoiceOver for speech checks.

| Check | Expected behavior |
| --- | --- |
| Click, Command-click, and Shift-click rows | Select one row, toggle membership, and select a range. |
| Context-click selected and unselected rows | Target the selected set or the clicked unselected row. Keep eligible files in list order. |
| Admit files without an active editor. Use arrows, Return, and Space. | Arrows navigate. Return opens available files. Space toggles Quick Look. Unavailable rows cannot open. |
| Focus a preset. Press Space, then Return. | Space activates it. Return opens its editor. |
| Edit a name while another batch enters. Change a filter while another control has focus. | Preserve the editor, text, caret, and other control's focus. |
| Move a preset through its menu and VoiceOver actions | Offer valid moves only. Retain focus and announce the new position. |
| Delete from an editor. Undo and redo. | Wait for popover closure. Restore ID, values, and position without reopening it. Focus the survivor or restored badge. |
| Open Quick Look. Change selection, filter rows, delete a selected file, then Clear at idle. | Follow available selection. Hidden rows lose selection. Close with no available selection. Recheck files. Clear leaves image files intact. |
| Visit and toggle each filter with VoiceOver | Speak its name, selected state, and selected "showing" value. Do not speak the decorative checkmark separately. |
| Inspect a long destination at minimum width. Use Clear with completed history. | Keep Clear visible and usable. Truncate the path. Expose its full value through help and accessibility. |
| Inspect Arabic layout and seven-language captures. Navigate with keyboard and VoiceOver. | Keep controls readable without overlap. Preserve coherent RTL layout, focus, and speech order. |
| Quit or close during processing. Test Escape, Command-period, and Return separately. | Escape and Command-period keep processing. Return cancels and quits after queue idle. |

The [coverage map](../Packages/UnderpressuredKit/Tests/COVERAGE.md) locates automated assertions and diagnostic captures.
Passing accessibility assertions does not establish VoiceOver speech or physical gesture quality.
