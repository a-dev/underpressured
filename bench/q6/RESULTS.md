# Q6: Quality → quantizr palette and the "kept full color" rule (task 0.13)

Source data: the Q2 sweep (`bench/out/q2/sweep.csv`, quantizr rows, 15 screenshot and alpha PNGs).

## Idea

Quality means the same perceptual target for PNG as for JPEG. Q1 measured which SSIMULACRA2 score jpegli reaches at each Quality (median over photos). PNG reuses that curve as a floor: a palette result is accepted only if it scores at least the floor. This avoids a fixed Quality → palette-size table, which can't work: at 64 colors, SSIMULACRA2 ranges from 33 to over 80 depending on the image.

Median SSIMULACRA2 of quantizr over all 15 files, by palette size and dither:

| colors | dither 0 | dither 0.5 | dither 1 |
|---|---|---|---|
| 16 | 22 | 26 | 32 |
| 32 | 47 | 51 | 57 |
| 64 | 63 | 70 | 74 |
| 128 | 76 | 79 | 80 |
| 256 | 83 | 85 | 85 |

Dithering always raises the score. Whether it also lowers bytes depends on the file, so the search tries more than one dither level.

## Mapping (Phase 4 implements this)

```
// Floor curve: piecewise linear through the Q1 jpegli medians.
// (Quality, SSIMULACRA2): (0,30) (57,70) (85,80) (98,90) (100,90)
func ssimFloor(q) -> Double

func pngLossy(image, q):
    lossless = oxipngLossless(image)              // the -o 2 path, always computed
    if q >= 98: return lossless, note: nil          // floor 90 is out of palette reach
    floor = ssimFloor(q)
    sizes = [16, 32, 64, 128, 256]
    // 1. Smallest palette that meets the floor with full dithering (binary search, ≤ 3 trials).
    c0 = smallest c in sizes where ssim(quantize(image, c, dither: 1.0)) >= floor
    if c0 == nil: return lossless, note: "kept full color"
    // 2. Refine: c0 and the next size up, dither {0, 0.5, 1}; keep the smallest passing output.
    best = min bytes over c in [c0, next(c0)], d in [0, 0.5, 1]
           where ssim(oxipng(quantize(image, c, d))) >= floor
    if best.bytes >= lossless.bytes: return lossless, note: "kept full color"
    return best, note: nil
```

- SSIMULACRA2 is measured on the composited RGBA, the same way as in Q2, against the source pixels.
- The "visibly degraded" threshold of spec §7 is exactly `ssim < ssimFloor(q)`. No palette size meets the floor, so the image keeps full color.
- Cost: at most 3 + 6 quantize-and-score trials. Typical screenshots take well under a second per trial. If that's too slow, Phase 4 can skip the refine step, but then outputs are up to 18% larger.

## Check against the sweep

Rule versus the best possible pick from the sweep ("oracle"):

| Quality (floor) | kept full color | rule/oracle bytes |
|---|---|---|
| ~55 (70) | 0 / 15 | median 1.00, max 1.15 |
| ~70 (75) | 0 / 15 | median 1.00, max 1.18 |
| ~85 (80) | 4 / 15 | identical on all 11 |

The larger gaps at Quality 55–70 come from dither 0.5 picks on sizes the refine step doesn't reach.

At the default Web Preset Quality, 4 of 10 screenshots keep full color. This matches Q2: complex UI screenshots don't fit in 256 colors at that quality.
