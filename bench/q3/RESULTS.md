# Q3: oxipng level for PNG (default vs `-o 4` vs `-o max` vs zopfli)

Machine: Apple M2 (4 performance cores), 16 GB. oxipng 10.2.1. All runs use `--strip safe --out bench/out/q3/<config>-<mt|st>/<file>`; the corpus is never modified. Reproduce with `bench/q3/run.sh` (writes `bench/out/q3/results.csv`), tables from `python3 bench/q3/report.py`.

Configs: `-o 2` (default), `-o 4`, `-o max`, `-o max --zopfli` (flag is `-z`/`--zopfli`, default 15 iterations, `--zi` unchanged). Each config ran once with default threads (MT, 8 logical CPUs) and once with `--threads 1` (ST). Wall ms is one run per file under `bench/out/.timelock` (no repeats, so treat differences under ~10% as noise). Losslessness: `pixeldiff src out` printed `identical` for every output that finished (all of them).

"median saved %" is the median over files of per-file savings versus the source; "total saved %" is on summed bytes. The screenshot set is 10 files / 9.5 MB, alpha 5 files / 5.4 MB, edge16 is `edge-02.png` (16-bit gray, 36.8 MB).

## Zopfli could not be measured on the full set

`-o max --zopfli` costs 40 to 85 s per 1 MB file with all 8 threads, and over 100 s single-threaded for a 160 KB file (3 of 5 files hit the 180 s single-thread timeout; the probe on screenshot-01, 1.2 MB, ran past 300 s with 8 threads before I killed it). A 100-file run of this would take hours. So zopfli ran only on a subset: screenshot-02, screenshot-05, alpha-03, alpha-05, plus edge-02. In the first three tables its row covers that subset only (n shows it); compare it using the like-for-like tables below. A trailing `+ (timeouts)` means some ST runs were cut at 180 s and counted as 180 s, so that total is a lower bound.

## Tables (full corpus for -o 2/4/max)


#### screenshot

| config | n | ok | median saved % | total out bytes | total src bytes | total saved % | MT median ms | MT total ms | ST median ms | ST total ms | lossless |
|---|---|---|---|---|---|---|---|---|---|---|---|
| -o 2 (default) | 10 | 10 | 33.75 | 6804740 | 9500474 | 28.37 | 1269 | 14267 | 1544 | 17556 | all identical |
| -o 4 | 10 | 10 | 35.83 | 6678657 | 9500474 | 29.70 | 2376 | 25852 | 3094 | 32767 | all identical |
| -o max | 10 | 10 | 36.40 | 6657620 | 9500474 | 29.92 | 5738 | 60719 | 20082 | 209532 | all identical |
| -o max --zopfli | 2 | 2 | 48.36 | 240914 | 453113 | 46.83 | 41466 | 82932 | 145661 | 291322+ (timeouts) | all identical |

#### alpha

| config | n | ok | median saved % | total out bytes | total src bytes | total saved % | MT median ms | MT total ms | ST median ms | ST total ms | lossless |
|---|---|---|---|---|---|---|---|---|---|---|---|
| -o 2 (default) | 5 | 5 | 16.08 | 3806436 | 5441897 | 30.05 | 2778 | 9769 | 3674 | 13105 | all identical |
| -o 4 | 5 | 5 | 18.23 | 3783988 | 5441897 | 30.47 | 4595 | 19188 | 6622 | 23184 | all identical |
| -o max | 5 | 5 | 18.23 | 3779093 | 5441897 | 30.56 | 10574 | 39275 | 32956 | 131986 | all identical |
| -o max --zopfli | 2 | 2 | 15.69 | 228618 | 259326 | 11.84 | 38920 | 77839 | 122726 | 245453+ (timeouts) | all identical |

#### edge16

| config | n | ok | median saved % | total out bytes | total src bytes | total saved % | MT median ms | MT total ms | ST median ms | ST total ms | lossless |
|---|---|---|---|---|---|---|---|---|---|---|---|
| -o 2 (default) | 1 | 1 | 0.54 | 36626276 | 36824602 | 0.54 | 2079 | 2079 | 3902 | 3902 | all identical |
| -o 4 | 1 | 1 | 0.54 | 36626221 | 36824602 | 0.54 | 6278 | 6278 | 9613 | 9613 | all identical |
| -o max | 1 | 1 | 0.54 | 36626221 | 36824602 | 0.54 | 16446 | 16446 | 25028 | 25028 | all identical |
| -o max --zopfli | 1 | 1 | 0.54 | 36625234 | 36824602 | 0.54 | 84389 | 84389 | 180016 | 180016+ (timeouts) | all identical |

### Like-for-like on the zopfli subset

#### screenshot (zopfli subset: screenshot-02.png, screenshot-05.png)

| config | n | ok | median saved % | total out bytes | total src bytes | total saved % | MT median ms | MT total ms | ST median ms | ST total ms | lossless |
|---|---|---|---|---|---|---|---|---|---|---|---|
| -o 2 (default) | 2 | 2 | 44.92 | 256155 | 453113 | 43.47 | 521 | 1042 | 636 | 1272 | all identical |
| -o 4 | 2 | 2 | 46.04 | 251205 | 453113 | 44.56 | 935 | 1870 | 1170 | 2339 | all identical |
| -o max | 2 | 2 | 46.89 | 247895 | 453113 | 45.29 | 2158 | 4315 | 7338 | 14676 | all identical |
| -o max --zopfli | 2 | 2 | 48.36 | 240914 | 453113 | 46.83 | 41466 | 82932 | 145661 | 291322+ (timeouts) | all identical |

#### alpha (zopfli subset: alpha-03.png, alpha-05.png)

| config | n | ok | median saved % | total out bytes | total src bytes | total saved % | MT median ms | MT total ms | ST median ms | ST total ms | lossless |
|---|---|---|---|---|---|---|---|---|---|---|---|
| -o 2 (default) | 2 | 2 | 11.46 | 237974 | 259326 | 8.23 | 374 | 747 | 498 | 996 | all identical |
| -o 4 | 2 | 2 | 13.43 | 233207 | 259326 | 10.07 | 842 | 1683 | 994 | 1987 | all identical |
| -o max | 2 | 2 | 13.56 | 232605 | 259326 | 10.30 | 1984 | 3969 | 7506 | 15013 | all identical |
| -o max --zopfli | 2 | 2 | 15.69 | 228618 | 259326 | 11.84 | 38920 | 77839 | 122726 | 245453+ (timeouts) | all identical |

#### edge16 (edge-02, 36.8 MB)

| config | n | ok | median saved % | total out bytes | total src bytes | total saved % | MT median ms | MT total ms | ST median ms | ST total ms | lossless |
|---|---|---|---|---|---|---|---|---|---|---|---|
| -o 2 (default) | 1 | 1 | 0.54 | 36626276 | 36824602 | 0.54 | 2079 | 2079 | 3902 | 3902 | all identical |
| -o 4 | 1 | 1 | 0.54 | 36626221 | 36824602 | 0.54 | 6278 | 6278 | 9613 | 9613 | all identical |
| -o max | 1 | 1 | 0.54 | 36626221 | 36824602 | 0.54 | 16446 | 16446 | 25028 | 25028 | all identical |
| -o max --zopfli | 1 | 1 | 0.54 | 36625234 | 36824602 | 0.54 | 84389 | 84389 | 180016 | 180016+ (timeouts) | all identical |

Non-clean rows: 3
{'category': 'screenshot', 'file': 'screenshot-02.png', 'config': 'omaxzop', 'threads': 'st', 'src_bytes': '295038', 'out_bytes': '', 'ms': '180009', 'exit': '124', 'lossless': 'timeout'}
{'category': 'alpha', 'file': 'alpha-03.png', 'config': 'omaxzop', 'threads': 'st', 'src_bytes': '220132', 'out_bytes': '', 'ms': '180018', 'exit': '124', 'lossless': 'timeout'}
{'category': 'edge16', 'file': 'edge-02.png', 'config': 'omaxzop', 'threads': 'st', 'src_bytes': '36824602', 'out_bytes': '', 'ms': '180016', 'exit': '124', 'lossless': 'timeout'}

## Reading the numbers

Per-file cost of one extra level, summed over the 10 screenshots (9.5 MB):

| step | extra bytes saved (of the output) | MT time | ST time |
|---|---|---|---|
| `-o 2` to `-o 4` | 1.9% fewer bytes (6.80 to 6.68 MB) | 1.8x (14.3 to 25.9 s) | 1.9x (17.6 to 32.8 s) |
| `-o 4` to `-o max` | 0.3% fewer bytes (6.68 to 6.66 MB) | 2.3x (to 60.7 s) | 6.4x (to 209.5 s) |
| `-o max` to `--zopfli` | about 2.8% fewer bytes on the 2-file subset (247.9 to 240.9 KB) | 19x | 20x or more (timeouts) |

Alpha is the same shape (`-o 4` saves 0.6% of output over `-o 2`; `-o max` another 0.1%). The 16-bit gray file barely compresses at any level (0.54% saved by all four configs, zopfli 0.54% too), yet `-o max` costs 8x the default and zopfli 40x for no gain. Single-thread `-o max` is 3.5x (screenshots) and 3.4x (alpha) slower than its MT time, because max parallelises its trials internally; `-o 2` barely changes (1.2x), so its per-file cost holds when the app runs Items in parallel.

Throughput at the app's parallelism (4 Items at once, so ST per-file cost applies; screenshots average 0.95 MB): `-o 2` about 1.8 s per file, so 300 files take about 2 min; `-o 4` about 3.3 s, about 4 min; `-o max` about 21 s, about 26 min; zopfli hours.

## Recommendation: `-o 2` (the oxipng default) for v0, with `--strip safe`

Reason:

1. The knee of the bytes/time curve is at `-o 2`. Each step after it buys little: `-o 4` removes 1.9% of the already-optimized bytes for about twice the time; `-o max` another 0.3% for 6x the single-thread time; zopfli adds a few percent for 20 to 100x and is unusable at hundreds of files (the app would sit at one file for minutes).
2. The app processes hundreds of files with Items in parallel, so single-thread cost per file is what counts. `-o 2` stays near 1.5 to 3.7 s per file for ordinary screenshots and alpha PNGs, and 3.9 s for a 36 MB image. `-o max` is 20 to 33 s per file ST and 25 s for the 36 MB file.
3. Spec §8's 30 s target covers 100 photos with the Web Preset (JPEG), not PNG; PNG work shouldn't eat that headroom, and `-o 2` costs 1 to 2 s per file where `-o max` would not.
4. `-o 4` is the only credible alternative (1.3 points more total saved on screenshots, 0.4 on alpha, at about 1.9x the time). It is not a clear knee, so it is not recommended. If product wants slightly smaller PNGs it is a one-line change that still stays under 4 s per typical file; `-o max` and zopfli are not worth offering, even as an opt-in "slow" mode, without a per-file time cap.
5. Real PNG savings come mostly from the cheap early trials (28 to 30% of bytes on screenshots and alpha at `-o 2`); deflate effort beyond that is marginal.

## Gotchas

- Timing ran while other benchmarks (q1, q2, q4) were active; only the lock-protected timed commands are serialized, so untimed work from other tasks may still have overlapped. Single runs, no repeats.
- Run order was MT then ST per config; the lock was held for each whole config x mode sweep and released between.
- Zopfli timings for the ST mode are lower bounds (timeouts at 180 s, env `TMO_ZOP`); the zopfli subset is tiny (n = 2 per category) so its saved-% is indicative, not statistical.
- `--zopfli` is `-z`. oxipng's help suggests pairing it with `--fast`. Probe (screenshot-01, 8 threads, unlocked, not in the CSV): `-o 2 -z` 634 KB in 90 s; `-o max -z --fast` 606 KB in 88 s; `-o max -z --zi 3` 607 KB in 81 s; plain `-o max` 626 KB in 12 s. Fewer iterations or `--fast` do not make zopfli cheap.
- Output of `--out` is a copy even when oxipng cannot shrink the file; `run.sh` handles a missing output (it records the source size).
- `pixeldiff` compares ImageIO-decoded pixels, which includes 16-bit gray decoded by CoreGraphics; this is what the app will see.
