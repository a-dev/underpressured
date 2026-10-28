#!/usr/bin/env bash
# Runs the full Underpressured test suite: native deps, the UnderpressuredKit package tests,
# then the app's xcodebuild tests. This is the single command CI and developers run.
# Pipes through xcbeautify when it is installed; otherwise prints raw xcodebuild output.
set -euo pipefail

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
export UP_UI_ARTIFACTS="$RUN_ROOT/native-ui"
export TEST_RUNNER_UP_UI_ARTIFACTS="$UP_UI_ARTIFACTS"
run native-app xcodebuild test \
  -project Underpressured.xcodeproj \
  -scheme Underpressured \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$RUN_ROOT/app" \
  | pretty
run localization-catalogs python3 scripts/check-localization.py \
  --package-build "$RUN_ROOT/package" \
  --app-build "$RUN_ROOT/app/Build/Intermediates.noindex"
run release-signature env \
  UP_RELEASE_TEST_APP="$RUN_ROOT/app/Build/Products/Debug/Underpressured.app" \
  UP_RELEASE_TEST_SPARKLE_BIN="$RUN_ROOT/app/SourcePackages/artifacts/sparkle/Sparkle/bin" \
  python3 scripts/test_release_crypto.py

step "all tests passed (results: $RUN_ROOT/results.tsv)"
