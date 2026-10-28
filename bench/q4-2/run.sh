#!/bin/zsh
# Q4.2 check: Butteraugli distance between the source's pixels and the visually lossless re-encode, per photo.
# The reference is the source as ImageIO sees it (a PNG with the profile ImageIO assigns, e.g. Adobe RGB from
# the EXIF interoperability tag), because the re-encode embeds that profile and butteraugli_main reads untagged
# JPEGs as sRGB.
# Usage: bench/q4-2/run.sh <dir of re-encoded photo-*.jpg>
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
REF=$(mktemp -d)
for f in "$ROOT"/bench/corpus/photo/*.jpg; do
  n=$(basename "$f" .jpg)
  sips -s format png "$f" --out "$REF/$n.png" >/dev/null
  printf '%s %s\n' "$n" "$("$ROOT/bench/.tools/bin/butteraugli_main" "$REF/$n.png" "$1/$n.jpg" 2>&1 | head -1)"
  rm "$REF/$n.png"
done
rmdir "$REF"
