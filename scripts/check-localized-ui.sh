#!/usr/bin/env bash
# Capture native fixtures with app AND package resources resolved in a fresh process per language.
set -euo pipefail
cd "$(dirname "$0")/.."
LOCALIZATION_BUILD_PATH="${LOCALIZATION_BUILD_PATH:-$(mktemp -d /tmp/underpressured-localized-build.XXXXXX)}"
ARTIFACT_ROOT="${UP_UI_ARTIFACTS:-$(mktemp -d /tmp/underpressured-localized-ui.XXXXXX)}"
mkdir -p "$ARTIFACT_ROOT"
export UP_UI_ARTIFACTS="$ARTIFACT_ROOT"
export TEST_RUNNER_UP_UI_ARTIFACTS="$ARTIFACT_ROOT"
xcodebuild build-for-testing -project Underpressured.xcodeproj -scheme Underpressured \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$LOCALIZATION_BUILD_PATH" \
  > "$ARTIFACT_ROOT/build.log" 2>&1
for language in es pt-BR de fr ar ja zh-Hans; do
  xcodebuild test-without-building -project Underpressured.xcodeproj -scheme Underpressured \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$LOCALIZATION_BUILD_PATH" \
    -only-testing:UnderpressuredTests/NativeAppTests/LocalizationLayoutTests \
    -testLanguage "$language" -testRegion US \
    > "$ARTIFACT_ROOT/$language.log" 2>&1
  rg -Fq "LOCALIZATION UI language=$language," "$ARTIFACT_ROOT/$language.log"
  rg -Fq 'Test run with 2 tests' "$ARTIFACT_ROOT/$language.log"
  printf '%s: ' "$language"
  rg 'LOCALIZATION UI|Test run with' "$ARTIFACT_ROOT/$language.log"
done
swift scripts/localization-contact-sheets.swift "$ARTIFACT_ROOT/contact-sheets" "$ARTIFACT_ROOT"
printf "Manual-review screenshots, AX trees and contact sheets: %s\n" "$ARTIFACT_ROOT"
