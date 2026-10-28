#!/usr/bin/env bash
# Builds the native dependencies into Vendor/ (git-ignored):
#   Vendor/UpJpegli.xcframework  jpegli + libhwy + the C shim in native/up-jpegli (one static lib)
#   Vendor/UpCodecs.xcframework  rust/up-codecs (oxipng + quantizr) via cargo
# Both are arm64-only static libraries built for macOS $DEPLOYMENT_TARGET.
#
# Idempotent: Vendor/.stamp holds a hash of this script (which includes the pins), the shim
# sources and the up-codecs crate inputs. If it matches and both xcframeworks exist, the script
# exits at once. Rust dependency pins live in rust/up-codecs/Cargo.lock.
#
#   scripts/build-deps.sh              build (or no-op)
#   scripts/build-deps.sh --print-hash print the stamp hash; builds nothing (CI cache key)
set -euo pipefail

# ---- Pins ---------------------------------------------------------------
JPEGLI_REPO=https://github.com/google/jpegli          # no release tags; pinned by commit
JPEGLI_COMMIT=031a0077f5799a6041004267fc12b956c1f52a20
DEPLOYMENT_TARGET=27.0
# -------------------------------------------------------------------------

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELF="$ROOT/scripts/build-deps.sh"
VENDOR="$ROOT/Vendor"
BUILD="$VENDOR/.build"
STAMP="$VENDOR/.stamp"
SHIM="$ROOT/native/up-jpegli"
CRATE="$ROOT/rust/up-codecs"

compute_hash() {
  # Paths are hashed relative to ROOT so the hash is the same in every checkout.
  ( cd "$ROOT"
    {
      echo "target=$DEPLOYMENT_TARGET arch=arm64"
      find scripts/build-deps.sh native/up-jpegli rust/up-codecs/src rust/up-codecs/Cargo.toml \
        rust/up-codecs/Cargo.lock rust/up-codecs/build.rs rust/up-codecs/cbindgen.toml \
        -type f ! -name .DS_Store | LC_ALL=C sort | xargs shasum -a 256
    } | shasum -a 256 | cut -d' ' -f1 )
}

if [ "${1:-}" = "--print-hash" ]; then compute_hash; exit 0; fi
[ $# -eq 0 ] || { echo "usage: $0 [--print-hash]" >&2; exit 2; }

HASH="$(compute_hash)"
if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$HASH" ] \
   && [ -d "$VENDOR/UpJpegli.xcframework" ] && [ -d "$VENDOR/UpCodecs.xcframework" ]; then
  echo "build-deps: up to date ($HASH)"
  exit 0
fi

log() { printf '\n==> %s\n' "$*"; }
JOBS="$(sysctl -n hw.ncpu)"
export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"

mkdir -p "$BUILD"
rm -f "$STAMP"   # a failed run must not look complete

GENERATOR=()
command -v ninja >/dev/null && GENERATOR=(-G Ninja)

# ---- jpegli ------------------------------------------------------------
SRC="$BUILD/jpegli"
if [ ! -d "$SRC/.git" ]; then
  log "clone jpegli"
  git clone --quiet "$JPEGLI_REPO" "$SRC"
fi
git -C "$SRC" checkout --quiet "$JPEGLI_COMMIT"
[ "$(git -C "$SRC" rev-parse HEAD)" = "$JPEGLI_COMMIT" ] || { echo "jpegli pin mismatch" >&2; exit 1; }
git -C "$SRC" submodule update --quiet --init --depth 1 -- third_party

log "jpegli @ ${JPEGLI_COMMIT:0:10}"
cmake -S "$SRC" -B "$BUILD/jpegli-build" ${GENERATOR[@]+"${GENERATOR[@]}"} \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DJPEGLI_STATIC=ON -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DJPEGLI_ENABLE_TOOLS=OFF -DJPEGLI_ENABLE_DEVTOOLS=OFF -DJPEGLI_ENABLE_BENCHMARK=OFF \
  -DJPEGLI_ENABLE_DOXYGEN=OFF -DJPEGLI_ENABLE_MANPAGES=OFF -DJPEGLI_ENABLE_JNI=OFF \
  -DJPEGLI_ENABLE_SJPEG=OFF -DJPEGLI_ENABLE_OPENEXR=OFF -DJPEGLI_ENABLE_FUZZERS=OFF \
  -DJPEGLI_ENABLE_TCMALLOC=OFF -DJPEGLI_ENABLE_WASM_THREADS=OFF -DJPEGLI_ENABLE_PLUGINS=OFF \
  -DJPEGLI_ENABLE_VIEWERS=OFF -DJPEGLI_ENABLE_EXAMPLES=OFF
cmake --build "$BUILD/jpegli-build" --target jpegli-static jpegli_cms lcms2 -j "$JOBS"

# `cmake --install` ships neither the jpegli_* headers nor the library, so stage them by hand
# (context gotcha 0.4): self-contained copies of the API headers for the shim to include.
INC="$BUILD/jpegli-include"
rm -rf "$INC"; mkdir -p "$INC"
for h in types common encode decode; do
  sed -e 's|#include "lib/jpegli/\([a-z]*\.h\)"|#include "\1"|' \
      -e 's|#include "lib/base/include_jpeglib.h".*|#include <stdio.h>\n#include "jpeglib.h"\n#include <setjmp.h>|' \
      "$SRC/lib/jpegli/$h.h" > "$INC/$h.h"
done
cp "$SRC/lib/jpegli/jpeglib.h" "$SRC/lib/jpegli/jconfig.h" "$SRC/lib/jpegli/jmorecfg.h" "$INC/" 2>/dev/null || true
for h in jpeglib.h jconfig.h jmorecfg.h; do
  [ -f "$INC/$h" ] || cp "$(find "$SRC/lib" "$BUILD/jpegli-build" -name "$h" -print -quit)" "$INC/$h"
done

# ---- shim --------------------------------------------------------------
log "C shim"
SHIM_OBJ="$BUILD/shim/up_jpegli.o"
mkdir -p "$BUILD/shim"
xcrun clang++ -std=c++17 -O2 -Wall -Wextra -arch arm64 -mmacosx-version-min="$DEPLOYMENT_TARGET" \
  -fPIC -I "$SHIM/include" -I "$INC" -c "$SHIM/up_jpegli.cc" -o "$SHIM_OBJ"

# SSIMULACRA2 (up_metrics.cc) uses jpegli's devtool sources. The cmake devtools target needs
# libraries that are not built here, so compile the sources it needs directly (context 4.5).
METRIC_SRCS=(tools/ssimulacra2.cc tools/gauss_blur.cc tools/no_memory_manager.cc lib/extras/image.cc
  lib/extras/image_color_transform.cc lib/extras/packed_image.cc lib/extras/simd_util.cc
  lib/extras/xyb_transform.cc lib/extras/memory_manager_internal.cc lib/extras/butteraugli.cc
  lib/extras/convolve_separable5.cc lib/extras/convolve_slow.cc
  lib/extras/packed_image_convert.cc lib/extras/dec/color_description.cc)
METRIC_FLAGS=(-std=c++17 -O2 -w -arch arm64 -mmacosx-version-min="$DEPLOYMENT_TARGET" -fPIC
  -I "$SRC" -I "$SRC/third_party/highway" -I "$BUILD/jpegli-build/lib/include" -I "$BUILD/jpegli-build")
METRIC_OBJS=("$BUILD/shim/up_metrics.o")
xcrun clang++ "${METRIC_FLAGS[@]}" -I "$SHIM/include" -c "$SHIM/up_metrics.cc" -o "$BUILD/shim/up_metrics.o"
for f in "${METRIC_SRCS[@]}"; do
  o="$BUILD/shim/metric_$(echo "$f" | tr / _).o"
  xcrun clang++ "${METRIC_FLAGS[@]}" -c "$SRC/$f" -o "$o"
  METRIC_OBJS+=("$o")
done

HWY_LIB="$(find "$BUILD/jpegli-build" -name libhwy.a -print -quit)"
JPEGLI_LIB="$(find "$BUILD/jpegli-build" -name libjpegli-static.a -print -quit)"
CMS_LIB="$(find "$BUILD/jpegli-build" -name libjpegli_cms.a -print -quit)"
LCMS_LIB="$(find "$BUILD/jpegli-build" -name liblcms2.a -print -quit)"
[ -n "$HWY_LIB" ] && [ -n "$JPEGLI_LIB" ] && [ -n "$CMS_LIB" ] && [ -n "$LCMS_LIB" ] || { echo "jpegli libs not found" >&2; exit 1; }

# ---- xcframeworks ------------------------------------------------------
# Headers live in Headers/<Module>/: SwiftPM copies every binary target's headers into one
# include/ dir, so two flat module.modulemap files would collide.
make_xcframework() { # <Name> <static lib> <header dir>
  local name=$1 lib=$2 headers=$3
  rm -rf "$VENDOR/$name.xcframework"
  xcodebuild -create-xcframework -library "$lib" -headers "$headers" -output "$VENDOR/$name.xcframework" >/dev/null
}

log "UpJpegli.xcframework"
OUT="$BUILD/UpJpegli"; rm -rf "$OUT"; mkdir -p "$OUT/headers/UpJpegli"
libtool -static -arch_only arm64 -o "$OUT/libUpJpegli.a" "$SHIM_OBJ" "${METRIC_OBJS[@]}" "$JPEGLI_LIB" "$CMS_LIB" "$LCMS_LIB" "$HWY_LIB" 2>&1 \
  | { grep -v "has no symbols" || true; }
cp "$SHIM/include/up_jpegli.h" "$OUT/headers/UpJpegli/"
cat > "$OUT/headers/UpJpegli/module.modulemap" <<'MAP'
module UpJpegli {
    header "up_jpegli.h"
    export *
}
MAP
make_xcframework UpJpegli "$OUT/libUpJpegli.a" "$OUT/headers"

# ---- up-codecs ---------------------------------------------------------
log "up-codecs (cargo, aarch64-apple-darwin, release)"
cargo build --release --locked --target aarch64-apple-darwin \
  --manifest-path "$CRATE/Cargo.toml" --target-dir "$BUILD/cargo-target"
log "UpCodecs.xcframework"
OUT="$BUILD/UpCodecs"; rm -rf "$OUT"; mkdir -p "$OUT/headers/UpCodecs"
cp "$BUILD/cargo-target/aarch64-apple-darwin/release/libup_codecs.a" "$OUT/libup_codecs.a"
cp "$CRATE/include/up_codecs.h" "$OUT/headers/UpCodecs/"
cat > "$OUT/headers/UpCodecs/module.modulemap" <<'MAP'
module UpCodecs {
    header "up_codecs.h"
    export *
}
MAP
make_xcframework UpCodecs "$OUT/libup_codecs.a" "$OUT/headers"

echo "$HASH" > "$STAMP"
echo "build-deps: done ($HASH)"
