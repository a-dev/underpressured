#!/usr/bin/env bash
# Build the pinned benchmark tools into bench/.tools/ (dev-only, never linked into the app).
# Idempotent: each tool is skipped if its output already exists. No sudo.
# Sources/build dirs: bench/.tools/src (git-ignored). Binaries: bench/.tools/bin.
# Force a rebuild of one tool by deleting its output (see the "check" lines below).
# Pins are mirrored in bench/README.md "## Pins".
set -euo pipefail

# ---- Pins ---------------------------------------------------------------
LIBJXL_REPO=https://github.com/libjxl/libjxl
LIBJXL_TAG=v0.12.0
LIBJXL_COMMIT=a7a9c787341cf703dede03c2009fa460cae5e5df

JPEGLI_REPO=https://github.com/google/jpegli          # no release tags; pinned by commit
JPEGLI_COMMIT=031a0077f5799a6041004267fc12b956c1f52a20

OXIPNG_VERSION=10.2.1                                  # crates.io, --locked

QUANTIZR_CRATE_VERSION=1.4.3                           # DarthSim/quantizr, pinned in tools-src/quantizr-cli/Cargo.lock
PNG_CRATE_VERSION=0.18.1

PNGQUANT_VERSION=3.0.3                                 # crates.io (libimagequant 4.x inside), GPL-3
PNGQUANT_TAG_COMMIT=53a332a58f44357b6b41842a54d74aa1e245913d   # kornelski/pngquant tag 3.0.3

LIBPNG_REPO=https://github.com/pnggroup/libpng         # only to build pngquant (its vendored libpng-sys is broken)
LIBPNG_TAG=v1.6.59
LIBPNG_COMMIT=cd952f49f95bb27154ae77dbb103032d95f6e580
# -------------------------------------------------------------------------

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS="$HERE/.tools"
SRC="$TOOLS/src"
BIN="$TOOLS/bin"
JOBS="$(sysctl -n hw.ncpu)"
mkdir -p "$SRC" "$BIN"

log() { printf '\n==> %s\n' "$*"; }

# clone_at <repo> <dir> <commit>: shallow-ish clone checked out at an exact commit.
clone_at() {
  local repo=$1 dir=$2 commit=$3
  if [ ! -d "$dir/.git" ]; then
    git clone --quiet "$repo" "$dir"
  fi
  git -C "$dir" checkout --quiet "$commit"
  [ "$(git -C "$dir" rev-parse HEAD)" = "$commit" ] || { echo "pin mismatch in $dir" >&2; exit 1; }
}

# init submodules (except the big testdata one)
init_submodules() {
  local dir=$1
  git -C "$dir" submodule update --quiet --init --depth 1 -- third_party
}

# libjpeg-turbo (the libjxl-pinned submodule, 2.1.5.1) so the metric tools and cjpegli can
# read JPEG input; macOS ships no libjpeg headers/lib. Built static into a private prefix.
JPEG_PREFIX="$SRC/libjpeg-turbo-prefix"
ensure_libjpeg_turbo() {
  [ -f "$JPEG_PREFIX/lib/libjpeg.a" ] && return
  log "libjpeg-turbo (libjxl submodule)"
  clone_at "$LIBJXL_REPO" "$SRC/libjxl" "$LIBJXL_COMMIT"
  init_submodules "$SRC/libjxl"
  cmake -S "$SRC/libjxl/third_party/libjpeg-turbo" -B "$SRC/libjpeg-turbo-build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$JPEG_PREFIX" -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DWITH_TURBOJPEG=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON
  cmake --build "$SRC/libjpeg-turbo-build" -j "$JOBS"
  cmake --install "$SRC/libjpeg-turbo-build"
  # this old libjpeg-turbo does not install the static lib when TurboJPEG is off
  mkdir -p "$JPEG_PREFIX/lib"
  cp "$SRC/libjpeg-turbo-build/libjpeg.a" "$JPEG_PREFIX/lib/"
}

build_libjxl_metrics() {
  if [ -x "$BIN/ssimulacra2" ] && [ -x "$BIN/butteraugli_main" ]; then
    log "libjxl metrics: already built"; return
  fi
  ensure_libjpeg_turbo
  log "libjxl $LIBJXL_TAG: ssimulacra2 + butteraugli_main"
  clone_at "$LIBJXL_REPO" "$SRC/libjxl" "$LIBJXL_COMMIT"
  init_submodules "$SRC/libjxl"
  cmake -S "$SRC/libjxl" -B "$SRC/libjxl/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF \
    -DJPEGXL_ENABLE_DEVTOOLS=ON -DJPEGXL_ENABLE_TOOLS=ON \
    -DJPEGXL_ENABLE_BENCHMARK=OFF -DJPEGXL_ENABLE_EXAMPLES=OFF -DJPEGXL_ENABLE_MANPAGES=OFF \
    -DJPEGXL_ENABLE_DOXYGEN=OFF -DJPEGXL_ENABLE_JNI=OFF -DJPEGXL_ENABLE_SJPEG=OFF \
    -DJPEGXL_ENABLE_OPENEXR=OFF -DJPEGXL_ENABLE_PLUGINS=OFF -DJPEGXL_ENABLE_VIEWERS=OFF \
    -DJPEGXL_ENABLE_FUZZERS=OFF -DJPEGXL_ENABLE_TCMALLOC=OFF -DJPEGXL_ENABLE_WASM_THREADS=OFF \
    -DJPEGXL_BUNDLE_LIBPNG=ON -DCMAKE_PREFIX_PATH="$JPEG_PREFIX" \
    -DJPEGXL_STATIC=ON -DJPEGXL_FORCE_SYSTEM_BROTLI=OFF -DJPEGXL_FORCE_SYSTEM_HWY=OFF
  cmake --build "$SRC/libjxl/build" --target ssimulacra2 butteraugli_main -j "$JOBS"
  cp "$SRC/libjxl/build/tools/ssimulacra2" "$SRC/libjxl/build/tools/butteraugli_main" "$BIN/"
}

build_jpegli() {
  if [ -x "$BIN/cjpegli" ] && [ -x "$BIN/djpegli" ] && [ -f "$TOOLS/include/jpegli/encode.h" ] && [ -f "$TOOLS/lib/libjpegli.a" ]; then
    log "jpegli: already built"; return
  fi
  ensure_libjpeg_turbo
  log "jpegli @ ${JPEGLI_COMMIT:0:10}"
  clone_at "$JPEGLI_REPO" "$SRC/jpegli" "$JPEGLI_COMMIT"
  init_submodules "$SRC/jpegli"
  cmake -S "$SRC/jpegli" -B "$SRC/jpegli/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF -DCMAKE_INSTALL_PREFIX="$TOOLS" \
    -DBUILD_SHARED_LIBS=OFF -DJPEGLI_STATIC=ON -DJPEGLI_BUNDLE_LIBPNG=ON \
    -DCMAKE_PREFIX_PATH="$JPEG_PREFIX" \
    -DJPEGLI_ENABLE_TOOLS=ON -DJPEGLI_ENABLE_DEVTOOLS=OFF -DJPEGLI_ENABLE_BENCHMARK=OFF \
    -DJPEGLI_ENABLE_DOXYGEN=OFF -DJPEGLI_ENABLE_MANPAGES=OFF -DJPEGLI_ENABLE_JNI=OFF \
    -DJPEGLI_ENABLE_SJPEG=OFF -DJPEGLI_ENABLE_OPENEXR=OFF -DJPEGLI_ENABLE_FUZZERS=OFF \
    -DJPEGLI_ENABLE_TCMALLOC=OFF -DJPEGLI_ENABLE_WASM_THREADS=OFF
  cmake --build "$SRC/jpegli/build" -j "$JOBS"
  cmake --build "$SRC/jpegli/build" --target jpegli-static -j "$JOBS"
  cmake --install "$SRC/jpegli/build"
  # `cmake --install` on macOS ships only the libjpeg-6.2 headers (include/jpegli/jpeglib.h)
  # and not the library itself. Install the static lib plus the jpegli_* API headers
  # (made self-contained) so a Swift/C++ harness can link it:
  #   -I$TOOLS/include/jpegli -L$TOOLS/lib -ljpegli -lhwy -lc++
  cp "$SRC/jpegli/build/lib/libjpegli-static.a" "$TOOLS/lib/libjpegli.a"
  local h
  for h in types common encode decode; do
    sed -e 's|#include "lib/jpegli/\([a-z]*\.h\)"|#include "\1"|' \
        -e 's|#include "lib/base/include_jpeglib.h".*|#include <stdio.h>\n#include "jpeglib.h"\n#include <setjmp.h>|' \
        "$SRC/jpegli/lib/jpegli/$h.h" > "$TOOLS/include/jpegli/$h.h"
  done
}

build_oxipng() {
  if [ -x "$BIN/oxipng" ] && "$BIN/oxipng" --version | grep -q " $OXIPNG_VERSION\$"; then
    log "oxipng: already built"; return
  fi
  log "oxipng $OXIPNG_VERSION"
  CARGO_TARGET_DIR="$SRC/cargo-target" cargo install oxipng --version "$OXIPNG_VERSION" --locked --root "$TOOLS" --force
}

build_quantizr() {
  if [ -x "$BIN/quantizr-cli" ]; then log "quantizr-cli: already built"; return; fi
  log "quantizr-cli (quantizr $QUANTIZR_CRATE_VERSION, png $PNG_CRATE_VERSION)"
  cargo build --release --locked --manifest-path "$HERE/tools-src/quantizr-cli/Cargo.toml" \
    --target-dir "$SRC/quantizr-cli-target"
  cp "$SRC/quantizr-cli-target/release/quantizr-cli" "$BIN/"
}

# pngquant's crates.io dep libpng-sys 1.1.9 fails to compile its vendored libpng on
# macOS (no pnglibconf.h), so build libpng ourselves and point pkg-config at it.
build_libpng() {
  if [ -f "$SRC/libpng-prefix/lib/pkgconfig/libpng16.pc" ]; then return; fi
  log "libpng $LIBPNG_TAG (static, for pngquant)"
  clone_at "$LIBPNG_REPO" "$SRC/libpng" "$LIBPNG_COMMIT"
  cmake -S "$SRC/libpng" -B "$SRC/libpng/build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$SRC/libpng-prefix" -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_TESTS=OFF -DPNG_TOOLS=OFF -DPNG_FRAMEWORK=OFF
  cmake --build "$SRC/libpng/build" -j "$JOBS"
  cmake --install "$SRC/libpng/build"
}

build_pngquant() {
  if [ -x "$BIN/pngquant" ] && "$BIN/pngquant" --version | grep -q "^$PNGQUANT_VERSION"; then
    log "pngquant: already built"; return
  fi
  build_libpng
  log "pngquant $PNGQUANT_VERSION (GPL-3, benchmark-only)"
  PKG_CONFIG_PATH="$SRC/libpng-prefix/lib/pkgconfig" \
    CARGO_TARGET_DIR="$SRC/cargo-target-pngquant" \
    cargo install pngquant --version "$PNGQUANT_VERSION" --locked --root "$TOOLS" --force
}

build_libjxl_metrics
build_jpegli
build_oxipng
build_quantizr
build_pngquant

log "done. tools in $BIN"
ls -1 "$BIN"
