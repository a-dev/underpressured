# Q7 — performance: 100 photos x ~12 MP, 4 workers (task 0.14)

## Verdict: PASS. Measured 4.45 s on M2; extrapolated base M1 about 5.3 s (about 6.7 s with a pessimistic 1.5x); budget is 30 s (spec §8). Margin is more than 4x.

## Machine
Apple M2, 4P + 4E cores, 16 GB, macOS 27.0 (see out/q7/machine.txt). Swift 6.4, release build (`swift build -c release`). Timing lock (`out/.timelock`) held for all runs. Other jobs were serialised by the lock, but the machine was not otherwise idle-checked.

## Method (run.sh reproduces everything: `bench/q7/run.sh`)
Per photo, in each of 4 worker threads (`DispatchQueue.concurrentPerform`, shared atomic work counter, one photo per worker at a time):
1. Decode: ImageIO `CGImageSourceCreateImageAtIndex` (ShouldCacheImmediately), drawn 1:1 into an 8-bit sRGB RGBX buffer (`decodeSRGB8`, copied from bench/resize Common.swift).
2. Resize to 2048 px long edge: method C from bench/resize (copied into Sources/q7/ResizeC.swift): `vImageGamma_Planar8toPlanarF` (sRGB forward) -> `vImageScale_ARGBFFFF` with `kvImageHighQualityResampling` -> `vImageGamma_PlanarFtoPlanar8` (sRGB reverse). Single-threaded vImage (`kvImageDoNotTile`), parallelism comes from the 4 workers.
3. Encode: jpegli linked in-process (libjpegli.a + libhwy.a, headers from .tools/include/jpegli) via a small C++ shim (Sources/CJpegli): `jpegli_set_defaults`, `jpegli_set_quality(cinfo, 80, TRUE)`, scanline loop (RGBX -> RGB row copy included), `jpegli_mem_dest`. Chroma subsampling/progressive etc. are jpegli defaults.
4. Write the JPEG to out/q7/outputs/ with `Data.write`.

Wall time is measured around the whole 100-photo run (from before spawning workers to after the last worker finishes), excluding process start. Stage times are per-photo wall time measured inside the worker, median over the 100 photos (so they include contention from the 4 concurrent workers).
1 warm-up run, then 3 timed runs; median of the 3 reported. Outputs: 100 files, 47.7 MB total (about 477 KB each, 2048 px long edge).

## Input set (out/q7/inputs, built by `q7 prep`, log in out/q7/prep.log)
Each of the 20 corpus photos (bench/corpus/photo, 4288x2848 up to 8000x6212) was downscaled with ImageIO (`CGImageSourceCreateThumbnailAtIndex`, no EXIF transform, max pixel size chosen so the area is about 12 MP, aspect preserved; photos already at about 12 MP are essentially unchanged) and written as JPEG at Quality 0.9 (`CGImageDestination`). That file is `photo-NN-v1.jpg`; v2..v5 are byte-identical copies of it (`photo-NN-v2..v5.jpg`), giving 100 inputs. Resulting sizes are 3931x3052 to 4598x2610 (11.0-12.0 MP). Copies mean the decoder sees the same bytes five times (page cache warm; no effect on CPU work, which is per-pixel).

## Results (M2, 4 workers, 100 photos)
| run | wall (s) | dec ms | resize ms | encode ms | write ms |
|---|---|---|---|---|---|
| warm-up | 4.541 | 42.2 | 90.9 | 20.1 | 0.5 |
| 1 | 4.359 | 31.3 | 94.3 | 20.7 | 0.5 |
| 2 | 4.452 | 31.8 | 95.0 | 21.3 | 0.5 |
| 3 | 4.492 | 31.9 | 95.5 | 21.4 | 0.5 |
| **median of 3** | **4.452** | **31.8** | **95.0** | **21.3** | **0.5** |

Per-stage medians per photo (with 4 workers in parallel): decode 31.8 ms, resize 95.0 ms, encode 21.3 ms, write 0.5 ms; sum about 149 ms. 4 workers x 4.45 s / 100 = about 178 ms of worker time per photo, so about 30 ms per photo is allocation, page-faulting of the large buffers and scheduling gaps not attributed to a stage. Resize (method C, float, 16 B/px) dominates at about 64% of staged time. Throughput: about 22.5 photos/s.

Memory: about 200 MB per worker (as estimated), about 0.8 GB peak total, not a constraint.

## Extrapolation to base M1 (4P+4E)
Assumption (explicit, not measured): M1 performance cores are about 1.15-1.2x slower single-threaded than M2 (P-core clock 3.2 vs 3.5 GHz plus IPC/memory-bandwidth gains), same 4P+4E topology, and the workload scales the same way with 4 workers on the P cores (compute-bound, per-worker memory about 200 MB, M1 bandwidth 68 vs 100 GB/s may hurt the float resize somewhat). Taking 1.2x: 4.45 s x 1.2 = about 5.3 s. Pessimistic 1.5x (extra penalty for memory bandwidth, 8 GB base-model memory pressure at 0.8 GB working set is negligible): about 6.7 s. Even a 3x slowdown would be 13.4 s.

## Verdict
Budget: 100 photos in 30 s (spec §8). Measured 4.45 s on M2; extrapolated 5.3 s (about 6.7 s pessimistic) on base M1. **PASS** with more than 4x margin in the pessimistic case. Caveats: inputs are 11-12 MP JPEG and the run is warm-cache; cold-disk reads and real 12 MP HEIC/RAW-ish inputs (slower decode) are not covered, but there is room for decode to be several times slower and still pass.

## Files
- bench/q7/run.sh, Package.swift, Sources/q7/{main,Common,ResizeC}.swift, Sources/CJpegli/{cjpegli.cpp,include/cjpegli.h}
- bench/out/q7/: inputs/ (100), outputs/ (100), runs.log, prep.log, machine.txt, run.out
