#!/bin/bash
# Q3: oxipng -o 2 / -o 4 / -o max / -o max --zopfli, bytes + wall ms + losslessness.
# Usage: bench/q3/run.sh            (all configs)   CONFIGS="o2 o4" bench/q3/run.sh (subset)
# Output: bench/out/q3/results.csv (+ the optimized files). Never modifies the corpus.
# Timed sweeps hold bench/out/.timelock (one config x one threading mode at a time).
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1
OXI=$ROOT/bench/.tools/bin/oxipng
PD=$ROOT/bench/.tools/bin/pixeldiff
OUT=$ROOT/bench/out/q3
LOCK=$ROOT/bench/out/.timelock
CSV=$OUT/results.csv
TMO=${TMO:-900}   # per-run timeout, seconds (zopfli: TMO_ZOP)
TMO_ZOP=${TMO_ZOP:-180}
mkdir -p "$OUT"

ALL_FILES=$(ls bench/corpus/screenshot/*.png bench/corpus/alpha/*.png bench/corpus/edge/edge-02.png)
# zopfli (-o max -z) costs ~85+ s wall PER 1 MB file even multithreaded, so the full set is infeasible:
# it runs on a subset (2 screenshots, 2 alphas) plus edge-02 (expected to hit the timeout).
ZOP_FILES="bench/corpus/screenshot/screenshot-02.png bench/corpus/screenshot/screenshot-05.png bench/corpus/alpha/alpha-03.png bench/corpus/alpha/alpha-05.png bench/corpus/edge/edge-02.png"
# config name -> oxipng args
cfg_args() { case $1 in
  o2)      echo "-o 2";;
  o4)      echo "-o 4";;
  omax)    echo "-o max";;
  omaxzop) echo "-o max --zopfli";;   # zopfli default 15 iterations
esac; }
CONFIGS=${CONFIGS:-"o2 o4 omax omaxzop"}
MODES=${MODES:-"mt st"}

echo "category,file,config,threads,src_bytes,out_bytes,ms,exit,lossless" > "$CSV"

ms_now() { gdate +%s%N; }
cat_of() { case $1 in *screenshot*) echo screenshot;; *alpha*) echo alpha;; *) echo edge16;; esac; }

for c in $CONFIGS; do
 for m in $MODES; do
  targs=""; [ "$m" = st ] && targs="--threads 1"
  mkdir -p "$OUT/$c-$m"
  FILES=$ALL_FILES; T=$TMO
  if [ "$c" = omaxzop ]; then FILES=$ZOP_FILES; T=$TMO_ZOP; fi
  # --- timed sweep under the lock ---
  until mkdir "$LOCK" 2>/dev/null; do sleep 2; done
  for f in $FILES; do
    b=$(basename "$f"); o="$OUT/$c-$m/$b"; rm -f "$o"
    s=$(ms_now)
    timeout "$T" "$OXI" $(cfg_args $c) --strip safe $targs --out "$o" "$f" >/dev/null 2>&1
    rc=$?
    e=$(ms_now)
    echo "$(cat_of "$f"),$b,$c,$m,$(stat -f %z "$f"),$o,$(( (e-s)/1000000 )),$rc," >> "$CSV.tmp.$c.$m"
  done
  rmdir "$LOCK"
  # --- untimed: sizes (oxipng leaves the file untouched if it can't shrink: --out then may not exist) + pixel check ---
  while IFS=, read -r cat b cc mm src o ms rc _; do
    if [ "$rc" = 124 ]; then ob=; ll=timeout; rm -f "$o"
    elif [ -f "$o" ]; then ob=$(stat -f %z "$o"); ll=$("$PD" "bench/corpus/$( [ "$cat" = screenshot ] && echo screenshot || { [ "$cat" = alpha ] && echo alpha || echo edge; } )/$b" "$o" 2>&1 | head -1)
    else ob=$src; ll=no-output-copy-of-source; fi
    echo "$cat,$b,$cc,$mm,$src,$ob,$ms,$rc,$ll" >> "$CSV"
  done < "$CSV.tmp.$c.$m"
  rm -f "$CSV.tmp.$c.$m"
 done
done
echo "wrote $CSV"
