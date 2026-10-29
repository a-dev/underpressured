# Build and test

## Build the app

You need an Apple Silicon Mac with macOS 27 or later, Xcode 27, CMake, Ninja, and Rust with Cargo. From the repository root, run:

```sh
scripts/build-deps.sh
open Underpressured.xcodeproj
```

Run the `Underpressured` scheme. The first dependency build downloads the pinned sources. Later builds use `Vendor/.stamp` again if the inputs did not change.

## Build variants

| Target | Distribution | Updates |
| --- | --- | --- |
| `Underpressured` | Direct download | Sparkle 2.10.0 |
| `UnderpressuredUpdaterFree` | App Sandbox | No Sparkle, no helpers, no update settings, no `DIRECT_DISTRIBUTION` code |

The two targets use the same app sources and package products.

Both targets build `Underpressured.app` with the bundle name `Underpressured`. The updater-free target keeps the Swift module name `UnderpressuredUpdaterFree`. Because the products have the same name, build each scheme with its own `-derivedDataPath`. The `Underpressured` scheme does not build the updater-free target.

### Updater-free target

- `Config/UpdaterFree.entitlements` enables the App Sandbox, read-write access to files that the user selects, and app-scoped bookmarks.
- Only this target ships `Resources/PrivacyInfo.xcprivacy` and sets `ITSAppUsesNonExemptEncryption` to `NO`.
- The privacy manifest declares no tracking and no collected data. It gives reason `CA92.1` for `UserDefaults`, which holds the app's settings. It gives reason `3B52.1` for file timestamps, which the app reads only from images and folders that the user opens or drops.
- If the app starts to use another required-reason API, update the manifest.

### Update settings in the direct target

- Debug builds disable updates, unless fixture settings enable them. Disabled updates show no controls and send no requests.
- Release needs an HTTPS feed URL with no credentials, query, or fragment, and a `SPARKLE_PUBLIC_ED_KEY` of 32 bytes. Bad settings stop the build.
- Release uses Sparkle's consent flow. Automatic installation is off.
- Direct Debug uses `Config/Direct-Debug.entitlements` for ad hoc Sparkle development. Release does not get its library-validation exception.

To test updates with a local feed:

```sh
xcodebuild build -project Underpressured.xcodeproj -scheme Underpressured \
  -configuration Debug -derivedDataPath /tmp/underpressured-fixture \
  SPARKLE_TEST_FEED=YES \
  SPARKLE_FEED_URL=http://127.0.0.1:8765/appcast.xml \
  SPARKLE_PUBLIC_ED_KEY='<fixture public key in base64>'
```

The fixture feed must be on localhost, 127.0.0.1, or ::1. Manual update checks use it. Scheduled checks stay disabled.

To inspect a built app:

```sh
python3 scripts/inspect-update-bundle.py MODE /absolute/path/to/App.app
```

`MODE` is `disabled`, `fixture`, `release`, or `updater-free`. The script checks metadata, Mach-O links and symbols, helpers, and signatures.

## Run tests

CI runs this script:

```sh
scripts/test.sh
```

It runs, in sequence:

1. Architecture and localization checks.
2. Update and release fixtures.
3. Rust tests.
4. Native dependency builds.
5. Swift package tests and app tests.
6. Checks of the compiler-extracted localization catalogs and the release signatures against the build from this run.
7. A build of the `UnderpressuredUpdaterFree` scheme in its own folder, and `inspect-update-bundle.py updater-free` on that app.

The first failure stops the script with a failing exit status.

The script prints its artifact folder: suite logs, `results.tsv`, native diagnostics, and the Xcode result bundle. `UP_TEST_ARTIFACTS` sets the parent folder. Each run uses new build folders. Delete them after you examine a failure.

For focused checks, build the dependencies first, then run:

```sh
swift test --package-path Packages/UnderpressuredKit --filter PresetListTests
cargo test --manifest-path rust/up-codecs/Cargo.toml
python3 scripts/check-architecture.py
python3 scripts/test_check_architecture.py
```

If you run SwiftPM builds at the same time, give each one its own `--scratch-path`. The package always declares the local XCFrameworks, even when a test target imports only Core.

| Test location | Checks |
| --- | --- |
| `Packages/UnderpressuredKit/Tests/UnderpressuredCoreTests/` | Domain rules and pure policies |
| `Packages/UnderpressuredKit/Tests/UnderpressuredApplicationTests/` | Intake, queue, pipeline, paths, cancellation, and pixel budget |
| `Packages/UnderpressuredKit/Tests/MacPlatformTests/` | Saved settings and platform services |
| `Packages/UnderpressuredKit/Tests/AppModelTests/` | Presentation, selection, undo, and lifecycle |
| `Packages/UnderpressuredKit/Tests/ImageEngineTests/` | Codecs, resize, color, metadata, and fidelity |
| `Packages/UnderpressuredKit/Tests/LocalFileSystemTests/` | Real file operations and commit safety |
| `Packages/UnderpressuredKit/Tests/IntegrationTests/` | Real pipeline and cancellation stress |
| `AppTests/` | Native app integration and accessibility |

The [coverage map](../Packages/UnderpressuredKit/Tests/COVERAGE.md) shows which test checks each behavior.

### Cancellation stress

The test runs 1,000 rounds for each destination, with four items at the same time and a ten-minute limit. It checks final identities, source preservation, output validity, marks, savings, and temporary-file cleanup.

```sh
swift test --package-path Packages/UnderpressuredKit --filter CancelStressTests
UP_CANCEL_SEED=20261028 UP_CANCEL_ROUNDS=5 swift test --package-path Packages/UnderpressuredKit --filter CancelStressTests
```

The second command is a short replay for development. For acceptance, do not set the overrides. The seed repeats the delay choices. It cannot repeat OS scheduling.

The stress test uses fixture dates in whole seconds. `StoredOptimizationMarkTests` checks the mark date boundaries.

### Trash and volume tests

- Real Trash tests need a writable volume Trash. Each test removes only the Trash URL that it owns. Never search the account's Trash for fixtures.
- `trashCleanup_onlyRemovesOwnedURL_afterSuccessOrFailure` records one known issue on purpose. It checks cleanup after an assertion failure.

To test case sensitivity on a real volume, set `UP_TEST_VOLUME_ROOT` to a mounted volume that you can erase:

```sh
UP_TEST_VOLUME_ROOT=/path/to/mount swift test --package-path Packages/UnderpressuredKit --filter volumeCaseSensitivity_matchesURLResourceValue
```

To check both policies, use one APFS image and one case-sensitive APFS image. After the tests, detach the mounts, also after a failure.

### Native UI and localization

Native tests need Xcode 27 and a logged-in macOS GUI session. They check accessibility identifiers, selection, focus, geometry, and actions. Only the reviewed checkmark crop uses a pixel comparison.

The tests read the SwiftUI accessibility tree in the test process. They do not need Accessibility permission in System Settings. SwiftUI builds the full tree only when an assistive client, such as VoiceOver, sets `AXEnhancedUserInterface` on the app. Without one, `NSHostingView` exposes almost no children. `NativeVisualEvidence` sets that attribute before it reads the tree. Do not remove it. [AppTests/Fixtures/README.md](../AppTests/Fixtures/README.md) has its environment and review policy.

```sh
xcodebuild test -project Underpressured.xcodeproj -scheme Underpressured \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/underpressured-native-ui
scripts/check-localized-ui.sh
```

`scripts/check-localized-ui.sh` starts a new process for each of the seven languages. It makes logs, screenshots, accessibility dumps, and contact sheets. `LOCALIZATION_BUILD_PATH` sets its build folder. `UP_UI_ARTIFACTS` sets a new artifact folder. A person must [review the captures](#native-gestures-and-voiceover). The captures do not prove VoiceOver speech or gesture quality.

## Run performance checks

Build the native dependencies first. These scripts build the Release SoakHarness and delete their temporary images:

```sh
scripts/bench.sh
SOAK_SMALL=500 SOAK_LARGE=5 scripts/soak.sh
scripts/soak.sh
```

- The benchmark makes three runs of 100 generated 12-megapixel JPEGs, with Web and export settings.
- The full soak uses 10,000 small files, 100 large images, six cancelled rounds, and full replace and export rounds. It needs about 2 GB of free disk space. It checks output decoding, cleanup, completion, failures, and peak memory. The default memory limit is 5,120 MB.
- Scheduler tests allow at most three state-change attempts for each admitted item. They use 1,000, 5,000, and 10,000 items, and check final identities and resource retirement.

[bench/README.md](../bench/README.md) explains codec comparisons and the corpus.

## Configure CI

`.github/workflows/ci.yml` runs for pull requests, pushes to `main`, tags, and manual dispatch. It uses the hosted arm64 `xcode-27` runner, which is new for each job, with read-only repository permissions. A new run cancels older runs for the same ref. Never send fork code to a persistent self-hosted runner.

| Trigger | Gate |
| --- | --- |
| Pull request | Fast gate, `scripts/test.sh --fast`: script fixtures, architecture check, Rust, native dependencies, and package tests |
| Push to `main`, tag, manual run, or pull request with the `full-ci` label | Full gate: `scripts/test.sh`, then the seven-language UI check |
| Changes only to `docs/**` and Markdown files | No CI |

Add the `full-ci` label to pull requests that change the app target, localization, the UI, or release signing. The last CI step uploads the artifacts, also after a failure.

Pending: no one has examined a real pull-request run on the hosted runner yet. Branch protection is not set, because the protection API for a private repository needs a paid plan.

## Change workflow

1. Read the [architecture](architecture.md) and the [glossary](GLOSSARY.md).
2. Find the owner and the product rule that the change affects.
3. If the meaning changes, update the behavior, the glossary, and the architecture text.
4. Where it applies, check construction, mutation, and restoration paths.
5. Run the focused checks. Run `scripts/test.sh` for integration acceptance.
6. Report the commands that you ran, the results, and the limits. Mark checks that you did not run as pending.

Put product rules in Core, execution and ports in Application, OS effects in adapters, and UI state in presentation. Review effects and public APIs, not only imports.

## Build and test constraints

- Keep Rust LTO disabled, unless Xcode linking works with it enabled.
- Use the ad hoc Hardened Runtime flags only in Release. In Debug, library validation rejects test bundles and debug dylibs.
- Set extended attributes before you make temporary files read-only.
- When you test metadata removal, check the user metadata. ImageIO can add EXIF fields to PNG.
- Give gated queue tests a time limit. Release the gates during cleanup.

## Native gestures and VoiceOver

A person must do these checks. Accessibility tests that pass do not prove VoiceOver speech or gesture quality. Record the commit, macOS version, language, reviewer, date, and result. Attach notes or captures for a failure. All checks are pending until a person records a result.

Prepare completed, skipped, failed, and unavailable rows, several presets, a 70-character name, and a long export path. Do the layout checks at the minimum window width too.

| Check | Expected result |
| --- | --- |
| Click, Command-click, and Shift-click rows | Select one row, toggle one row, and select a range. |
| Context-click selected and unselected rows | Target the selection or the clicked unselected row. Keep eligible files in list order. |
| Admit files with no editor open. Use the arrows, Return, and Space. | Arrows move. Return opens available files. Space toggles Quick Look. Unavailable rows do not open. |
| Focus a preset. Press Space, then Return. | Space activates it. Return opens its editor. |
| Edit a name while another batch arrives. Change a filter while another control has focus. | The editor, text, caret, and the other control's focus stay. |
| Move a preset with its menu and with VoiceOver actions | Only valid moves show. Focus stays. VoiceOver announces the new position. |
| Delete from an editor. Undo, then redo. | As in [Undo](SPEC.md#undo): the delete waits for the popover, undo restores the preset without the popover, and focus moves correctly. |
| Open Quick Look. Change the selection, filter rows, delete a selected file, then Clear at idle. | Quick Look follows the available selection and closes when none remains. Hidden rows lose selection. Clear does not change image files. |
| Go to each filter with VoiceOver and toggle it | VoiceOver speaks its name, selected state, and "showing" value. It does not speak the checkmark. |
| Examine a long destination at minimum width. Use Clear with completed history. | Clear stays visible and usable. The path is cut. Help and accessibility give the full path. |
| Examine the Arabic layout and the seven-language captures. Use the keyboard and VoiceOver. | Controls are readable and do not overlap. The right-to-left layout, focus, and speech order are correct. |
| Quit or close during processing. Test Escape, Command-period, and Return one at a time. | Escape and Command-period keep processing. Return cancels and quits after the queue is idle. |


## Sandboxed app checks

Use a signed `UnderpressuredUpdaterFree` build. Package tests run without the App Sandbox, so they cannot show sandbox denials. Record the commit, macOS version, reviewer, date, and result. All checks are pending until a person records a result.

In this table, "convert" means Replace Originals with a different output format.

| Check | Expected result |
| --- | --- |
| Drop one file. Replace Originals in the original format, with Trash on, then off. | The file is replaced. No panel and no `.tmp` file show. |
| Drop one file from an external volume. Replace Originals. | The file is replaced. |
| Drop one file. Convert. Click Grant Access. | A panel opens at the file's folder. The converted file shows next to the source. |
| Drop one file. Convert. Cancel the panel. | The item fails with "No permission". The source does not change. |
| Drop two files from one folder and one from a second folder. Convert. | One panel shows for each folder. |
| Drop a folder. Convert. | No panel shows. Outputs show next to their sources. |
| Select an Export folder. Quit, open the app again, and process. | The app uses the remembered folder and does not ask again. |
| Delete `~/Library/Containers/app.underpressured.Underpressured`. Run a direct build. Add a preset, select an Export folder, and turn Trash off. Quit. Open the sandboxed build. | `container-migration.plist` moves `~/Library/Preferences/app.underpressured.Underpressured.plist` into the container. The sandboxed build shows the presets, the active preset, the destination, the Trash setting, and the Export folder name. After this, the direct build starts with initial settings. |
| After the migration, select Replace Originals, then select the Export folder entry. | The folder picker opens, because the migrated folder is not writable in the sandbox. After you select a folder, the app keeps it after a relaunch and does not ask again. |
| After the migration, with the Export folder selected, drop one file. Click Grant Access. | A folder panel opens at the Export folder before the scan. The copy shows in the folder. After a relaunch, the next drop shows no panel. |
| After the migration, with the Export folder selected, drop one file. Cancel the panel. | The item fails with "No permission". The next drop shows the panel again. |

Recorded results:

| Check | Commit | macOS | Reviewer | Date | Result |
| --- | --- | --- | --- | --- | --- |
| Drop one file. Convert. Click Grant Access. (Trash off, PNG to JPEG, Debug build signed Apple Development) | `683d3a9` | 27.0.1 (26A434) | a-dev | 2026-10-30 | Pass. The JPEG shows next to the source. The kernel log has no `file-write` deny for the process. |
| Drop one file. Convert. Click Grant Access. (TestFlight 1.1.0 build 3) | `b9239bf`, build number 3 | 27.0.1 (26A434) | a-dev | 2026-10-30 | Pass. The JPEG shows next to the source. |
| Drop one file. Convert. Cancel the panel. (TestFlight 1.1.0 build 3) | `b9239bf`, build number 3 | 27.0.1 (26A434) | a-dev | 2026-10-30 | Pass. The item fails with "No permission". The source does not change. |
| Drop one file. Convert with Trash on. Click Grant Access. (TestFlight 1.1.0 build 3) | `b9239bf`, build number 3 | 27.0.1 (26A434) | a-dev | 2026-10-30 | Pass. The JPEG shows next to the source. The original is in the Trash. |
