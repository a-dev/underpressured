#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
baseline_ref="1987bd6"
report_path="${1:-/tmp/underpressured-t8-baseline-allocation-history.txt}"
output_path="${report_path%.txt}.csv"
temp_root="$(mktemp -d /tmp/underpressured-t8-baseline.XXXXXX)"
benchmark_pid=""

cleanup() {
    if [[ -n "$benchmark_pid" ]] && kill -0 "$benchmark_pid" 2>/dev/null; then
        kill "$benchmark_pid" 2>/dev/null || true
        wait "$benchmark_pid" 2>/dev/null || true
    fi
    rm -rf "$temp_root"
}
trap cleanup EXIT

if [[ -e "$report_path" || -e "$output_path" ]]; then
    printf 'Profile output already exists: %s or %s\nChoose a new report path as the first argument.\n' \
        "$report_path" "$output_path" >&2
    exit 2
fi

mkdir -p "$temp_root"
git -C "$repo_root" archive "$baseline_ref" Packages/UnderpressuredKit/Sources/UnderpressuredCore \
    | tar -x -C "$temp_root"
mkdir -p "$temp_root/Sources/QueueBaseline"
mv "$temp_root/Packages/UnderpressuredKit/Sources/UnderpressuredCore" "$temp_root/Sources/UnderpressuredCore"
cp "$repo_root/bench/t8/baseline/Package.swift" "$temp_root/Package.swift"
cp "$repo_root/bench/t8/baseline/Sources/QueueBaseline/main.swift" "$temp_root/Sources/QueueBaseline/main.swift"

swift build -c release --package-path "$temp_root" --product QueueBaseline
mkdir -p "$(dirname "$report_path")"
env -u MallocStackLogging MallocStackLoggingNoCompact=1 T8_PROFILE_HOLD_SECONDS=30 \
    "$temp_root/.build/release/QueueBaseline" >"$output_path" 2>&1 &
benchmark_pid=$!
ready=0
for _ in $(seq 1 100); do
    if rg -q '^T8_PROFILE_READY$' "$output_path"; then
        ready=1
        break
    fi
    if ! kill -0 "$benchmark_pid" 2>/dev/null; then
        wait "$benchmark_pid"
        printf 'Baseline exited before the profile-ready marker. See %s\n' "$output_path" >&2
        exit 1
    fi
    sleep 0.1
done
if [[ "$ready" != 1 ]]; then
    printf 'Timed out waiting for the baseline profile-ready marker. See %s\n' "$output_path" >&2
    exit 1
fi
malloc_history "$benchmark_pid" -allEvents -fullStacks >"$report_path"
wait "$benchmark_pid"
benchmark_pid=""
printf 'Baseline ref: %s\nBenchmark output: %s\nAllocation stack history: %s\n' \
    "$baseline_ref" "$output_path" "$report_path"
