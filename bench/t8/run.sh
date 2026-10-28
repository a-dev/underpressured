#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
package="$repo_root/Packages/UnderpressuredKit"
binary="$package/.build/release/QueueBenchmark"

swift build -c release --package-path "$package" --product QueueBenchmark >&2
"$binary"
