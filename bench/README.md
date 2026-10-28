# Bench

Codec and quantizer comparisons use a downloadable image corpus, SSIMULACRA2,
and Butteraugli. These tools are for development and are not linked into the app.

The corpus is downloaded by a script and is not stored in git. Tools are built
from pinned sources into `bench/.tools/`.

## How to run

```sh
bench/fetch-corpus.sh   # download corpus into bench/corpus/<category>/, verify sha256
bench/build-tools.sh    # build pinned tools into bench/.tools/
swift run -c release --package-path bench/upbench upbench --help
```

Corpus metadata (id, category, url, license, author, sha256) is in
`bench/corpus.tsv`.

## Pins

Pinned in `bench/build-tools.sh` (the script is the source of truth; keep this table in sync).
Binaries land in `bench/.tools/bin/`, sources and build dirs in `bench/.tools/src/` (git-ignored).

| Tool | Pin | Source | License |
|------|-----|--------|---------|
| `ssimulacra2`, `butteraugli_main` | libjxl tag `v0.12.0`, commit `a7a9c787341cf703dede03c2009fa460cae5e5df` | github.com/libjxl/libjxl | BSD-3 |
| `cjpegli`, `djpegli`, `libjpegli.a` | jpegli commit `031a0077f5799a6041004267fc12b956c1f52a20` (no release tags) | github.com/google/jpegli | BSD-3 |
| `oxipng` | `10.2.1` (`cargo install --locked`) | crates.io | MIT |
| `quantizr-cli` | quantizr crate `=1.4.3` (tag `v1.4.3`, commit `cfb26aaf3039ac1179d42a66cc7988c8c6feeba9`), png crate `=0.18.1`; full dependency set in `bench/tools-src/quantizr-cli/Cargo.lock` | github.com/DarthSim/quantizr | MIT-style (see repo `LICENSE`) |
| `pngquant` | `3.0.3` (`cargo install --locked`; tag `3.0.3` = commit `53a332a58f44357b6b41842a54d74aa1e245913d`), bundles libimagequant 4.x | crates.io / github.com/kornelski/pngquant | GPL-3.0-or-later |
| build helpers | libjpeg-turbo `2.1.5.1` (commit `8ecba3647edb6dd940463fedf38ca33a8e2a73d1`, libjxl submodule) for JPEG input; libpng `v1.6.59` (commit `cd952f49f95bb27154ae77dbb103032d95f6e580`) only to link pngquant; libjxl/jpegli submodules at the commits those repos pin | | zlib / libpng |

**License warning:** `pngquant` and the libimagequant it contains are GPL-3. They are
benchmark-only tools, never linked into or shipped with the app. Do not copy their code or
link `libimagequant` into the Swift app. The permissively licensed alternative under test is
quantizr.

**Linking jpegli from a Swift or C++ harness** (headers and static lib are installed by
`build-tools.sh`): `-I bench/.tools/include/jpegli -L bench/.tools/lib -ljpegli -lhwy -lc++`.
The API is the `jpegli_*` family (`jpegli_create_compress`, `jpegli_set_quality`, ...) declared in
`encode.h`/`decode.h`; the headers are C++ (`<cstddef>`), so use a C++ shim for Swift.

CLI invocations:

```sh
T=bench/.tools/bin
$T/ssimulacra2 ref.png dist.jpg            # prints score (100 = identical)
$T/butteraugli_main ref.png dist.jpg       # prints max distance, then "3-norm: N"
$T/cjpegli in.png out.jpg -q 75            # or -d DISTANCE; --chroma_subsampling=420; -p 0..2
$T/djpegli in.jpg out.png
$T/oxipng -o 2 --strip safe file.png       # in place; --out other.png to keep the source
$T/quantizr-cli in.png out.png --max-colors 64 --dither 1.0
$T/pngquant 64 --quality 0-100 --speed 1 -f --output out.png in.png
```

## Historical experiments

The `q1` through `q7` results record earlier codec experiments. Q5 has been removed because production now implements lossless JPEG rewriting.
These measurements explain codec choices and quality thresholds; they do not verify current app performance.
Use `scripts/bench.sh` for the current image pipeline and `bench/t8/run.sh` for the current queue.
