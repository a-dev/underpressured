#!/bin/zsh
# Reproduce Q4. Run from the repo root: bench/q4/run.sh
# Timed sweeps take the shared bench timing lock, one method at a time.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
LOCK="$ROOT/bench/out/.timelock"
mkdir -p "$ROOT/bench/out"
swift build -c release --package-path bench/resize
R=$(swift build -c release --package-path bench/resize --show-bin-path)/resize

$R selftest
$R ref                                  # reference downscales (untimed, parallel)
for m in A B C D; do
  until mkdir "$LOCK" 2>/dev/null; do sleep 2; done
  $R time $m                            # timed sweep, 1 warm-up + 3 reps, median
  rmdir "$LOCK"
done
$R score --jobs 2                       # SSIMULACRA2 + Butteraugli (untimed)
$R report > bench/out/q4/report.md
