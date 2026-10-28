# Q1: jpegli vs. ImageIO JPEG at matched SSIMULACRA2 (task 0.7)

Reproduce: `bench/build-tools.sh && bench/fetch-corpus.sh && bench/q1/run.sh`, then the summary below from `bench/out/q1/<encoder>-<target>.csv`.

Method: `upbench --match-ssimulacra2 T --jobs 2` on the 20 corpus photos (12–50 MP). For each file and encoder, Quality is bisected to the lowest value whose output reaches SSIMULACRA2 ≥ T. Both encoders start from the same decoded pixels. Apple M2, macOS 27. jpegli is the `cjpegli` CLI at the pinned commit (default settings: 4:4:4 at high Quality, adaptive quantization). ImageIO is `CGImageDestination` with `kCGImageDestinationLossyCompressionQuality = Q/100`.

| Target SSIMULACRA2 | Files | jpegli / ImageIO bytes (median per file) | Median Quality jpegli / ImageIO | Median Butteraugli jpegli / ImageIO | Median ms jpegli / ImageIO |
|---|---|---|---|---|---|
| 70 | 20 | 0.862 (−13.8%) | 57.5 / 41 | 3.17 / 3.85 | 581 / 291 |
| 80 | 20 | 0.890 (−11.0%) | 84.5 / 59 | 2.08 / 2.44 | 633 / 334 |
| 90 | 9 reached by both | 0.447 (−55%) | 98 / 100 | n/a | 826 / 519 |

- At 90, ImageIO missed the target on 11 of 20 photos even at Quality 100; jpegli missed on 7. Where both reach it, jpegli is less than half the size.
- jpegli also has the lower Butteraugli at the same SSIMULACRA2, so the gain isn't an artifact of one metric.
- The ms columns aren't like for like: jpegli's time includes starting `cjpegli` and decoding its PNG input, while ImageIO's time covers encoding only. Linked in-process (Phase 4), jpegli will be faster than shown. Even as measured, about 0.6 s per 12–50 MP photo fits spec §8 (see Q7).

**Worth the dependency: yes.** About 11–14% fewer bytes at the same quality in the useful range, more at high quality, and better on both metrics.

Quality scale: jpegli takes the standard libjpeg 0–100 scale (`jpegli_set_quality`), so the app passes Quality through unchanged. ImageIO's scale is not the same scale: a jpegli Quality of about 85 matches an ImageIO Quality of about 59 at SSIMULACRA2 80.
