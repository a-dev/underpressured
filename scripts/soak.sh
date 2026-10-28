#!/usr/bin/env bash
# Soak test (plan 6.5, spec §7.6, §7.7, §8 Safety). Generates SOAK_SMALL small files (default 10000)
# and SOAK_LARGE 48 MP images (default 100) in a temporary folder, runs the real Queue headlessly
# (Packages/UnderpressuredKit/Sources/SoakHarness) over them SOAK_ROUNDS times (default 6) cancelling
# at a random moment each time, then once more to the end. Afterwards it checks: no temporary files,
# no partial files, no unfinished Items, peak memory (task_info phys_footprint) under
# SOAK_MEMORY_LIMIT_MB (default 5120 = the 120 MP pixel budget at the measured ~30 B/px, ~3.6 GB, plus 1.5 GB headroom).
# One PASS/FAIL line per check; exits non-zero on any failure. Needs about 2 GB of free disk.
#
# Quick run: SOAK_SMALL=500 SOAK_LARGE=5 scripts/soak.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SMALL="${SOAK_SMALL:-10000}"
LARGE="${SOAK_LARGE:-100}"
ROUNDS="${SOAK_ROUNDS:-6}"
LIMIT="${SOAK_MEMORY_LIMIT_MB:-5120}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/underpressured-soak.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

echo "==> build SoakHarness (release)"
swift build -c release --package-path Packages/UnderpressuredKit \
  --scratch-path "$ROOT/.build/soak" --product SoakHarness >&2
BIN="$(swift build -c release --package-path Packages/UnderpressuredKit \
  --scratch-path "$ROOT/.build/soak" --show-bin-path)/SoakHarness"

echo "==> soak: small=$SMALL large=$LARGE cancelled rounds=$ROUNDS memory limit=${LIMIT} MB"
status=0
"$BIN" --root "$WORK" --small "$SMALL" --large "$LARGE" --rounds "$ROUNDS" --memory-limit-mb "$LIMIT" || status=$?

if [ "$status" -eq 0 ]; then echo "==> soak PASSED"; else echo "==> soak FAILED (exit $status)"; fi
exit "$status"
