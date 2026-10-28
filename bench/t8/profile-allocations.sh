#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
package="$repo_root/Packages/UnderpressuredKit"
binary="$package/.build/release/QueueBenchmark"
report_path="${1:-/tmp/underpressured-t8-allocation-history.txt}"
output_path="${report_path%.txt}.csv"

if [[ -e "$report_path" || -e "$output_path" ]]; then
    printf 'Profile output already exists: %s or %s\nChoose a new report path as the first argument.\n' \
        "$report_path" "$output_path" >&2
    exit 2
fi

swift build -c release --package-path "$package" --product QueueBenchmark
mkdir -p "$(dirname "$report_path")"
env -u MallocStackLogging MallocStackLoggingNoCompact=1 T8_PROFILE_HOLD_SECONDS=30 \
    T8_PROFILE_MODE=1 "$binary" >"$output_path" 2>&1 &
benchmark_pid=$!
cleanup() {
    if [[ -n "${benchmark_pid:-}" ]] && kill -0 "$benchmark_pid" 2>/dev/null; then
        kill "$benchmark_pid" 2>/dev/null || true
        wait "$benchmark_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT
# Wait for the exact 1,000-item workload to finish before sampling its full event history.
ready=0
for _ in $(seq 1 100); do
    if rg -q '^T8_PROFILE_READY$' "$output_path"; then
        ready=1
        break
    fi
    if ! kill -0 "$benchmark_pid" 2>/dev/null; then
        wait "$benchmark_pid"
        printf 'Benchmark exited before the profile-ready marker. See %s\n' "$output_path" >&2
        exit 1
    fi
    sleep 0.1
done
if [[ "$ready" != 1 ]]; then
    kill "$benchmark_pid" 2>/dev/null || true
    wait "$benchmark_pid" || true
    printf 'Timed out waiting for the profile-ready marker. See %s\n' "$output_path" >&2
    exit 1
fi
malloc_history "$benchmark_pid" -allEvents -fullStacks >"$report_path"
wait "$benchmark_pid"
benchmark_pid=""
printf 'Benchmark output: %s\nAllocation stack history: %s\n' "$output_path" "$report_path"
