# Q4: ImageIO downsampling vs vImage Lanczos in linear light

Task 0.11. Machine: Apple M2, macOS 27, Swift 6.4, 16 GB. Corpus: 20 photos (12-50 MP JPEG) and 10 PNG UI screenshots
from `bench/corpus`. Scored against an offline reference with `ssimulacra2` (higher is better, 100 = identical) and
`butteraugli_main` (first number, lower is better).

## Methods

| id | what | where the resize happens |
|---|---|---|
| A | `CGImageSourceCreateThumbnailAtIndex`, `ThumbnailMaxPixelSize`, `CreateThumbnailFromImageAlways`, `WithTransform=false`, `ShouldCacheImmediately` | ImageIO, straight from the file (JPEG DCT-domain scaling possible) |
| B | decode, `vImageScale_ARGB8888` + `kvImageHighQualityResampling` (Lanczos) | gamma-encoded 8-bit sRGB |
| C | decode, `vImageGamma_Planar8toPlanarF` (sRGB to linear), `vImageScale_ARGBFFFF` high quality, `vImageGamma_PlanarFtoPlanar8` (linear to sRGB) | linear light, float32 |
| D | decode, `CGContext.draw` with `interpolationQuality = .high` | gamma-encoded 8-bit sRGB |
| ref | hand-written separable Lanczos-4 (`--taps`), no vImage: sRGB LUT to linear float32, float64 accumulation, weights renormalised at edges, clamp, exact sRGB encode, round to 8-bit | linear light |

Sizes: long edge 2048 and 1280; short edge `round(short * target / long)`. Images whose long edge is not larger than the target are
skipped (2048: photos all qualify, screenshots 02, 08, 09, 10 do not, so n = 6; 1280: all 30).

### Colour handling (everything is sRGB before it is compared)

Photos 04, 06, 09 are Adobe RGB, photo 13 is ProPhoto, screenshots 01/03/04/05 carry display profiles (LG UltraFine, Color LCD), 06/08/09/10 are untagged
(treated as sRGB by ColorSync). Decode = `CGImageSourceCreateImageAtIndex` then a 1:1 `CGContext.draw` into an 8-bit sRGB (`kCGColorSpaceSRGB`)
RGBX context (ColorSync, default rendering intent, out-of-gamut clipped). Methods B, C, D and the reference all start from that same sRGB 8-bit buffer.
Method A scales in the source's own colour space (ImageIO thumbnail), and is converted to sRGB afterwards by the same 1:1 draw, so it also
absorbs any "scale in a wide-gamut space" difference. That is what the app would do if it used ImageIO thumbnails. Pixels are unrotated for all methods (EXIF orientation ignored; all corpus files are orientation 1 anyway).
Screenshot alpha is flattened over black (all are effectively opaque).

## Results

Median over images (minimum SSIMULACRA2 / maximum Butteraugli in brackets). Time columns are median ms per image, wall clock, after one warm-up, median of 3 reps.
`op` = the resize itself (A: file to scaled pixels including decode, since ImageIO fuses them; B/C/D: scale only, and for C including the gamma conversions both ways and float buffer allocation).
`decode` = ImageIO decode + sRGB conversion for B/C/D. `total` = per-image median of op + decode. CPU/wall = process CPU time over wall time.

| size | category | method | n | SSIMULACRA2 median (min) | Butteraugli median (max) | op ms median | decode ms | total ms | CPU/wall |
|---|---|---|---|---|---|---|---|---|---|
| 2048 | photo | A | 20 | 70.29 (46.5) | 8.223 (14.65) | 66 | - | 66 | 0.66 |
| 2048 | photo | B | 20 | 82.14 (71.8) | 5.345 (9.83) | 33 | 52 | 98 | 1.00 |
| 2048 | photo | C | 20 | 92.88 (91.6) | 1.126 (1.85) | 96 | 52 | 169 | 1.00 |
| 2048 | photo | D | 20 | 68.77 (56.4) | 7.499 (12.36) | 51 | 52 | 112 | 1.12 |
| 2048 | screenshot | A | 6 | 64.35 (42.0) | 12.450 (22.03) | 35 | - | 35 | 1.12 |
| 2048 | screenshot | B | 6 | 71.15 (48.7) | 10.461 (20.48) | 9 | 35 | 43 | 1.00 |
| 2048 | screenshot | C | 6 | 89.75 (87.0) | 1.386 (2.19) | 39 | 34 | 78 | 1.00 |
| 2048 | screenshot | D | 6 | 64.30 (42.0) | 12.757 (22.03) | 25 | 34 | 59 | 1.23 |
| 1280 | photo | A | 20 | 65.36 (34.7) | 9.073 (16.01) | 50 | - | 50 | 0.60 |
| 1280 | photo | B | 20 | 77.42 (63.2) | 6.825 (13.54) | 26 | 52 | 94 | 1.00 |
| 1280 | photo | C | 20 | 93.85 (90.7) | 1.061 (1.94) | 94 | 52 | 155 | 1.00 |
| 1280 | photo | D | 20 | 63.20 (47.9) | 8.445 (14.84) | 41 | 52 | 99 | 1.10 |
| 1280 | screenshot | A | 10 | 53.84 (12.8) | 13.251 (19.57) | 26 | - | 26 | 1.00 |
| 1280 | screenshot | B | 10 | 61.67 (18.9) | 10.915 (16.57) | 5 | 35 | 40 | 1.00 |
| 1280 | screenshot | C | 10 | 90.78 (87.6) | 1.494 (2.01) | 23 | 34 | 58 | 1.00 |
| 1280 | screenshot | D | 10 | 54.47 (14.7) | 12.937 (18.70) | 13 | 34 | 49 | 1.31 |

Paired per-image SSIMULACRA2 difference (first minus second), median [wins of first / n]:

| size | category | pair | median diff | first wins |
|---|---|---|---|---|
| 2048 | photo | C-B | 10.37 | 20/20 |
| 2048 | photo | C-A | 22.98 | 20/20 |
| 2048 | photo | A-B | -12.02 | 0/20 |
| 2048 | photo | C-D | 23.67 | 20/20 |
| 2048 | photo | B-D | 9.10 | 20/20 |
| 2048 | screenshot | C-B | 18.36 | 6/6 |
| 2048 | screenshot | C-A | 25.14 | 6/6 |
| 2048 | screenshot | A-B | -6.02 | 0/6 |
| 2048 | screenshot | C-D | 25.27 | 6/6 |
| 2048 | screenshot | B-D | 6.24 | 6/6 |
| 1280 | photo | C-B | 15.22 | 20/20 |
| 1280 | photo | C-A | 29.00 | 20/20 |
| 1280 | photo | A-B | -11.03 | 0/20 |
| 1280 | photo | C-D | 30.49 | 20/20 |
| 1280 | photo | B-D | 12.80 | 20/20 |
| 1280 | screenshot | C-B | 28.04 | 10/10 |
| 1280 | screenshot | C-A | 37.49 | 10/10 |
| 1280 | screenshot | A-B | -7.62 | 1/10 |
| 1280 | screenshot | C-D | 36.86 | 10/10 |
| 1280 | screenshot | B-D | 7.23 | 9/10 |

Peak memory (`/usr/bin/time -l`, peak memory footprint, whole process on photo-20, 8000x6212 = 49.7 MP, one image resident): A 139 MB, B 602 MB, D 602 MB, **C 1.30 GB**
(the 8-bit decoded buffer is ~200 MB; C adds a 795 MB float source buffer plus the small float output). C scales with source pixel count at 16 bytes/pixel, so a
parallel pipeline with 8 workers on 50 MP inputs would need ~10 GB for C alone.

Per-image numbers: `bench/out/q4/scores.csv`, `bench/out/q4/time-{A,B,C,D}.csv`. Outputs and references are PNGs under `bench/out/q4/{A,B,C,D,ref,ref-alt}/<size>/`.

## Findings

1. **C (linear light) is by far the closest to the reference**: SSIMULACRA2 ~93 on photos (min 90.7), ~90 on screenshots, Butteraugli ~1.1-1.5. It wins on all 20/20 photos and 16/16 screenshot cases against every other method.
2. **Gamma-space scaling (B) loses 10 points (2048) to 15 points (1280) of SSIMULACRA2 on photos and 18-28 points on screenshots** relative to C, with the same kernel family. That is the gamma error: fine bright-on-dark and dark-on-bright detail (text, foliage, specular edges) is darkened or lightened, and the effect grows with the reduction factor. Butteraugli worst case: 9.8 vs 1.9 at 2048.
3. **A (ImageIO thumbnail) is about as poor as D, and worse than B**: about 12 points below B on photos (A never beats B on a photo), 22-29 below C. It is not only the gamma error (B has that too): A is 11-12 points below B on photos, so the ImageIO resampler (or its DCT-domain pre-scaling, not separated out) is lower quality than vImage Lanczos in the same gamma space. The cause was not isolated further.
4. D (CGContext `.high`) is similar to A and ~9-13 points below B on photos.
5. Time (single image, M2, loaded machine): photos total (decode + resize) ~100 ms for B, ~170 ms for C, 66 ms for A at 2048. C's resize step costs ~3x B (96 vs 33 ms); in absolute terms the cost of C over B is ~60-70 ms per 12-50 MP photo. A is the fastest on large photos only because it skips full-resolution work.
6. A returned a size 1 px smaller in the short edge on 5 outputs (A floors, the reference rounds): photo-02 @2048, 07 @1280, 12 @1280, 13 @2048, 15 @1280. For those, A was scored against an alternate reference at A's exact size (`ref-alt`), so the scores are comparable. The app must not assume `ThumbnailMaxPixelSize` gives round-to-nearest dimensions.

## Recommendation (v0)

Use **method C: decode to sRGB 8-bit, convert to linear float, `vImageScale_ARGBFFFF` with `kvImageHighQualityResampling`, convert back to sRGB 8-bit**.
It costs roughly 60-70 ms more than gamma-space B per photo and, for 50 MP inputs, ~1.3 GB peak per in-flight image, but it removes the gamma error that B, D and A all have and is within ~7 SSIMULACRA2 points of a Lanczos-4 float reference.

- **ImageIO thumbnails (A) are not acceptable as the default resizer**: they are the least faithful (median 70/65 on photos at 2048/1280) and the dimension rounding differs. They are only worth using if memory/time dominates (e.g. a preview or thumbnail in the UI, not the output file).
- **Gamma-space vImage (B) is the fallback** when memory is the constraint (e.g. very large input with many workers): it is ~10 points worse but needs 1/2 the memory. If the app caps parallelism by pixel count, C can stay the default. A middle option not measured here: process C in horizontal strips to bound the float buffer.
- Plan for memory in the Q7 performance task: C needs ~16 bytes per source pixel in float, so budget `megapixels * 16 MB` per concurrent worker (plus 4 MB per MP for the 8-bit decode).

## Gotchas

- Timing was done on a shared, loaded machine (load average 8-22 from other benchmark jobs; the lock only serialises jobs that take it). Absolute ms are noisy (an earlier full sweep gave A 97 / B 50 / C 145 / D 111 ms at 2048 photos; the reported sweep is the second). Ratios and rankings were stable.
- "Single-threaded": vImage runs with `kvImageDoNotTile` (CPU/wall = 1.00). `CGContext.draw` (D) and ImageIO decode may use more than one thread (CPU/wall up to 1.3); A's CPU/wall below 1 means waiting on I/O or other load. Nothing could pin them to one core.
- The reference uses Lanczos-4 while vImage's high-quality resampler is Lanczos-3-class, so even a perfect C does not reach 100. The gap between C and the reference (~7 points) is mostly that kernel plus rounding. The reference is also linear-light, so it favours C by construction; that is the point of the test, but metrics do not measure whether the gamma-space look is preferred by users.
- A's thumbnail is lazily decoded unless `kCGImageSourceShouldCacheImmediately` is set; the harness sets it and also forces a 1:1 draw.
- vImage gamma functions are the `*_half_precision` variants; round trip over all 256 codes is exact (`resize selftest`).
- Running `resize time` with `--ids` writes to `time-subset-<M>.csv`, so quick runs do not overwrite the sweep.
- Metrics read the PNGs as written (8-bit sRGB-tagged RGB); no ICC conversion happens in the tools.

## Reproduce

```sh
# from the repo root (Swift 6 package, builds with no warnings)
bench/q4/run.sh            # build, selftest, reference, locked sweeps A..D, scoring, report
# or by hand:
swift build -c release --package-path bench/resize
R=$(swift build -c release --package-path bench/resize --show-bin-path)/resize
$R ref                                    # reference downscales -> bench/out/q4/ref
for m in A B C D; do until mkdir bench/out/.timelock 2>/dev/null; do sleep 2; done; $R time $m; rmdir bench/out/.timelock; done
$R score --jobs 2                         # scores.csv (re-run after `time A` also creates ref-alt for off-by-one sizes)
$R report > bench/out/q4/report.md        # the tables above
# memory: /usr/bin/time -l $R time C --ids photo-20 --reps 1
```
