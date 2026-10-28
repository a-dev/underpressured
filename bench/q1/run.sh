#!/usr/bin/env bash
# Q1 (task 0.7): jpegli vs. ImageIO JPEG at matched SSIMULACRA2 70, 80, 90 on the photo set.
# Writes bench/out/q1/<encoder>-<target>.csv. Holds bench/out/.timelock while timing.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
bench="$here/.."
(cd "$bench/upbench" && swift build -c release)
upbench="$bench/upbench/.build/release/upbench"
out="$bench/out/q1"
mkdir -p "$out"
until mkdir "$bench/out/.timelock" 2>/dev/null; do sleep 2; done
trap 'rmdir "$bench/out/.timelock"' EXIT
for target in 70 80 90; do
  for encoder in jpegli imageio-jpeg; do
    "$upbench" --encoder "$encoder" --match-ssimulacra2 "$target" \
      --input "$bench/corpus/photo" --out "$out/$encoder-$target.csv" --jobs 2
  done
done
