#!/usr/bin/env bash
# Runs the full Underpressured test suite: native deps, the UnderpressuredKit package tests,
# then the app's xcodebuild tests. This is the single command CI and developers run.
# Pipes through xcbeautify when it is installed; otherwise prints raw xcodebuild output.
# --fast stops after the package tests: no app build, catalog audit or release signature.
set -euo pipefail

FAST=0
case "${1:-}" in
  --fast) FAST=1 ;;
  "") ;;
  *) printf 'usage: %s [--fast]\n' "$0" >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ARTIFACT_PARENT="${UP_TEST_ARTIFACTS:-${TMPDIR:-/tmp}}"
mkdir -p "$ARTIFACT_PARENT"
RUN_ROOT="$(mktemp -d "$ARTIFACT_PARENT/underpressured-tests.XXXXXX")"
printf 'Test artifacts: %s\n' "$RUN_ROOT"
printf 'suite\texit_status\n' > "$RUN_ROOT/results.tsv"

run() {
  local name="$1" status
  shift
  step "$name"
  if "$@" 2>&1 | tee "$RUN_ROOT/$name.log"; then
    status=0
  else
    status=$?
  fi
  printf '%s\t%s\n' "$name" "$status" >> "$RUN_ROOT/results.tsv"
  return "$status"
}

step() { printf '\n==> %s\n' "$*"; }

pretty() {
  if command -v xcbeautify >/dev/null 2>&1; then
    xcbeautify
  else
    cat
  fi
}

run architecture-fixtures python3 scripts/test_check_architecture.py
run architecture-check python3 scripts/check-architecture.py
run localization-fixtures python3 scripts/test_check_localization.py
run direct-update-config python3 scripts/test_validate_direct_update_config.py
run update-fixture-server python3 scripts/test_update_fixture_server.py
run release-fixtures python3 scripts/test_release.py
run publication-fixtures python3 scripts/test_publish_release.py
run github-publication-fixtures python3 scripts/test_publish_github.py
run rust cargo test --manifest-path rust/up-codecs/Cargo.toml
run build-deps scripts/build-deps.sh

# Fresh, run-owned paths prevent extraction from an earlier build or checkout
# from satisfying the actual-catalog audit.
run swift-package swift test --package-path Packages/UnderpressuredKit \
  --scratch-path "$RUN_ROOT/package"
if [ "$FAST" = 1 ]; then
  step "fast tests passed (results: $RUN_ROOT/results.tsv)"
  exit 0
fi
export UP_UI_ARTIFACTS="$RUN_ROOT/native-ui"
export TEST_RUNNER_UP_UI_ARTIFACTS="$UP_UI_ARTIFACTS"
# TEMPORARY: CI sets UP_SKIP_CI_UNSTABLE_UI_TESTS=1 to skip these tests.
# Local runs do not set the variable, so they run all tests.
# The first three tests read the SwiftUI AX tree. SwiftUI builds that tree only when an assistive client is active.
# NativeVisualEvidence now sets AXEnhancedUserInterface to activate it, which fixes the local failure.
# The same cause probably explains the empty tree on the hosted runner. Remove these three skips after a full CI run passes without them.
# The checkmark pixel baseline is valid only for Xcode 27.1, build 27A9275. See AppTests/Fixtures/README.md.
skip_testing=()
if [ "${UP_SKIP_CI_UNSTABLE_UI_TESTS:-0}" = 1 ]; then
  skip_testing=(
    -skip-testing:UnderpressuredTests/NativeAppTests/ItemListFocusTests/selectedFilterAccessibilityAndAction\(\)
    -skip-testing:UnderpressuredTests/NativeAppTests/LocalizationLayoutTests/localizedSurfacesAtMinimumSize\(\)
    -skip-testing:UnderpressuredTests/NativeAppTests/ConstrainedLayoutTests/longDestinationAndClearRemainVisibleAndOperable\(\)
    -skip-testing:UnderpressuredTests/NativeAppTests/ItemListFocusTests/selectedFilterMatchesReviewedCheckmark\(\)
  )
fi
run native-app xcodebuild test \
  -project Underpressured.xcodeproj \
  -scheme Underpressured \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$RUN_ROOT/app" \
  ${skip_testing[@]+"${skip_testing[@]}"} \
  | pretty
run localization-catalogs python3 scripts/check-localization.py \
  --package-build "$RUN_ROOT/package" \
  --app-build "$RUN_ROOT/app/Build/Intermediates.noindex"
run release-signature env \
  UP_RELEASE_TEST_APP="$RUN_ROOT/app/Build/Products/Debug/Underpressured.app" \
  UP_RELEASE_TEST_SPARKLE_BIN="$RUN_ROOT/app/SourcePackages/artifacts/sparkle/Sparkle/bin" \
  python3 scripts/test_release_crypto.py

# The App Store target shares the product name with the direct target, so it builds in its own folder.
# The project signs this target with the team's Apple Development identity, which hosted runners lack.
# UP_ADHOC_SIGNING=1 overrides signing for this build only; the project settings that MAS archives use stay unchanged.
adhoc_signing=()
if [ "${UP_ADHOC_SIGNING:-0}" = 1 ]; then
  adhoc_signing=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=)
fi
run app-store-build xcodebuild build \
  -project Underpressured.xcodeproj \
  -scheme UnderpressuredUpdaterFree \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$RUN_ROOT/app-store" \
  ${adhoc_signing[@]+"${adhoc_signing[@]}"} \
  | pretty
run app-store-bundle python3 scripts/inspect-update-bundle.py updater-free \
  "$RUN_ROOT/app-store/Build/Products/Debug/Underpressured.app"

step "all tests passed (results: $RUN_ROOT/results.tsv)"
