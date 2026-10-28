# Q2: quantizr vs. libimagequant (pngquant) (task 0.8)

Reproduce: `bench/q2/run.sh && python3 -I bench/q2/analyze.py`.

Method:
- Inputs: 10 screenshots and 5 alpha PNGs.
- Sweep: palette sizes {16, 32, 64, 128, 256} × dithering {0, 0.5, 1} for each quantizer. pngquant runs with `--speed 1`.
- Every output then gets `oxipng -o 2 --strip all`.
- Scoring: SSIMULACRA2 against the color-stripped source.
- For each target, the table takes the smallest output per file and quantizer that reaches the target.

| Target | Category | Files matched by both | Median quantizr/pngquant bytes | Unmatched (quantizr / pngquant) |
|---|---|---|---|---|
| 80 | screenshot | 6 | 0.909 (-9.1%) | 4 / 1 |
| 80 | alpha | 5 | 0.873 (-12.7%) | 0 / 0 |
| 80 | all | 11 | 0.873 (-12.7%) | 4 / 1 |
| 85 | screenshot | 3 | 0.988 (-1.2%) | 5 / 7 |
| 85 | alpha | 3 | 0.802 (-19.8%) | 2 / 0 |
| 85 | all | 6 | 0.888 (-11.2%) | 7 / 7 |
| 90 | screenshot | 1 | 0.980 (-2.0%) | 9 / 9 |
| 90 | alpha | 1 | 1.059 (+5.9%) | 4 / 4 |
| 90 | all | 2 | 1.020 (+2.0%) | 13 / 13 |

Findings:
- **Size gate (ADR 0002, >10% larger fails): pass.** Where both quantizers reach the target, quantizr is the same size or smaller. Its median is −12.7% at 80 and −11.2% at 85. At 90 it is +2%, but that rests on only 2 files.
- **Quality ceiling:**
  - At 80, quantizr fails to reach the target on 4 screenshots, against 1 for pngquant. On those files the app falls back to full color (see 0.13).
  - At 85 and 90, both quantizers fail on most screenshots. Text and UI gradients need more than 256 colors to score high.
- **Visual check (0.9):** a human reviewed `bench/out/q2/crops/index.html`: quantizr OK.
