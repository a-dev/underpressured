#!/usr/bin/env bash
# Q2 (task 0.8): quantizr vs. libimagequant (pngquant) on the screenshot and alpha sets.
# For every file, sweeps palette size × dithering for both quantizers, runs the same
# oxipng pass on every output, and scores SSIMULACRA2 against the source.
# Writes bench/out/q2/sweep.csv; bench/q2/analyze.py turns it into the matched table and crops.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
bench="$here/.."
bin="$bench/.tools/bin"
out="$bench/out/q2"
work="$out/work"
mkdir -p "$work"

until mkdir "$bench/out/.timelock" 2>/dev/null; do sleep 2; done
trap 'rmdir "$bench/out/.timelock"' EXIT

csv="$out/sweep.csv"
echo "file,category,quantizer,colors,dither,bytes,ssimulacra2" > "$csv"

score() { "$bin/ssimulacra2" "$1" "$2" | head -1 | awk '{print $1}'; }

for src in "$bench"/corpus/screenshot/*.png "$bench"/corpus/alpha/*.png; do
  name="$(basename "$src" .png)"
  category="$(basename "$(dirname "$src")")"
  # Reference: the source without color chunks, so both quantizers and the metric
  # see the same pixels (quantizr-cli writes no iCCP/gAMA).
  ref="$work/$name.ref.png"
  "$bin/oxipng" -q -o 0 --strip all --out "$ref" "$src"
  for colors in 16 32 64 128 256; do
    for dither in 0 0.5 1; do
      q="$work/$name.quantizr.$colors.$dither.png"
      "$bin/quantizr-cli" "$ref" "$q" --max-colors "$colors" --dither "$dither"
      "$bin/oxipng" -q -o 2 --strip all "$q"
      echo "$name,$category,quantizr,$colors,$dither,$(stat -f %z "$q"),$(score "$ref" "$q")" >> "$csv"

      p="$work/$name.pngquant.$colors.$dither.png"
      case "$dither" in
        0) fs=(--nofs) ;;
        *) fs=(--floyd="$dither") ;;
      esac
      "$bin/pngquant" "$colors" --speed 1 "${fs[@]}" -f --output "$p" "$ref"
      "$bin/oxipng" -q -o 2 --strip all "$p"
      echo "$name,$category,pngquant,$colors,$dither,$(stat -f %z "$p"),$(score "$ref" "$p")" >> "$csv"
    done
  done
  echo "done $name" >&2
done
