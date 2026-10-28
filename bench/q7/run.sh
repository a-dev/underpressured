#!/bin/bash
# Q7 (task 0.14): 100 x ~12 MP photos, decode -> resize (method C) -> jpegli q80 -> write, 4 workers.
# Usage: bench/q7/run.sh [workers]   (default 4 = M2 performance cores)
set -euo pipefail
cd "$(dirname "$0")/.."            # bench/
B=$PWD
W=${1:-4}
OUT=$B/out/q7
T=$B/.tools
mkdir -p "$OUT"

(cd q7 && swift build -c release \
  -Xcxx -I"$T/include/jpegli" -Xcc -I"$T/include/jpegli" \
  -Xlinker -L"$T/lib" -Xlinker -ljpegli -Xlinker -lhwy -Xlinker -lc++) 2>&1 | grep -v "ld: warning" | tail -5
BIN=$B/q7/.build/release/q7

if [ "$(ls "$OUT/inputs" 2>/dev/null | wc -l)" -ne 100 ]; then
  rm -rf "$OUT/inputs"
  "$BIN" prep "$B/corpus/photo" "$OUT/inputs" | tee "$OUT/prep.log"
fi

{
  echo "date: $(date)"; sysctl -n machdep.cpu.brand_string
  echo "perf cores: $(sysctl -n hw.perflevel0.physicalcpu), eff: $(sysctl -n hw.perflevel1.physicalcpu), RAM: $(( $(sysctl -n hw.memsize) / 1073741824 )) GB"
  sw_vers | tr '\n' ' '; echo
} > "$OUT/machine.txt"

# Timing lock shared with other bench jobs.
until mkdir "$B/out/.timelock" 2>/dev/null; do sleep 2; done
trap 'rmdir "$B/out/.timelock"' EXIT
echo "lock acquired $(date)"

"$BIN" run "$OUT/inputs" "$OUT/outputs" "$W" warmup | tee "$OUT/runs.log"
for i in 1 2 3; do
  "$BIN" run "$OUT/inputs" "$OUT/outputs" "$W" "run$i" | tee -a "$OUT/runs.log"
done
