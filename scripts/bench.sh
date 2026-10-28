#!/usr/bin/env bash
# Performance benchmark (plan 6.7, spec §8): 100 generated 12 MP JPEGs through the real Queue/Pipeline/
# LocalFileAccess/NativeCodec with the Web Preset (quality 80, max long edge 2048, no metadata), Export
# destination, timed from enqueue to idle. BENCH_RUNS (default 3), BENCH_COUNT (default 100).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/underpressured-bench.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

echo "==> build SoakHarness (release)"
swift build -c release --package-path Packages/UnderpressuredKit \
  --scratch-path "$ROOT/.build-6-7" --product SoakHarness >&2
BIN="$(swift build -c release --package-path Packages/UnderpressuredKit \
  --scratch-path "$ROOT/.build-6-7" --show-bin-path)/SoakHarness"

echo "==> bench"
"$BIN" --bench --root "$WORK" --count "${BENCH_COUNT:-100}" --runs "${BENCH_RUNS:-3}"
