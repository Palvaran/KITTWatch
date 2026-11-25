#!/usr/bin/env bash
# Build a CPU-only llama.cpp for watchOS (device: arm64_32 + arm64, simulator: arm64)
# at the pinned revision and package it as Packages/KITTEngine/Frameworks/llama.xcframework,
# where the KITTEngine Swift package picks it up as its `llama` binary target.
#
# Upstream build-xcframework.sh has no watchOS target, so this script does the minimum:
#   1. ggml's architecture check compares CMAKE_OSX_ARCHITECTURES with STREQUAL "arm64",
#      which misses arm64_32 and silently drops the NEON kernels. We change it to
#      MATCHES "^arm64" in the local checkout.
#   2. watchOS is not in ggml's _DARWIN_C_SOURCE list, so we pass it as a compiler flag.
#   3. Metal, BLAS, OpenMP, common/, tools/, and the HTTP client are all off.
# Then it checks that the arm64_32 slice really contains NEON code and nothing the
# S5 cannot run (dot-product / matrix-multiply instructions).
#
# For the Mac and Linux command-line build of the same revision, see build-llama-host.sh.
#
# Usage: scripts/build-llama.sh            (Accelerate off)
#        GGML_ACCELERATE=ON scripts/build-llama.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/versions.env"

WORK="$ROOT/.build-llama"
SRC="$WORK/llama.cpp"
OUT="$ROOT/Packages/KITTEngine/Frameworks/llama.xcframework"
ACCEL="${GGML_ACCELERATE:-OFF}"
JOBS="$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)"

command -v cmake >/dev/null || { echo "error: cmake not found (brew install cmake)" >&2; exit 1; }
xcrun --sdk watchos --show-sdk-path >/dev/null || { echo "error: watchOS SDK not found; install Xcode's watchOS platform" >&2; exit 1; }

# --- 1. Source at the pinned revision -------------------------------------------------
"$ROOT/scripts/fetch-llama.sh"

# --- 2. arm64_32 architecture fix -----------------------------------------------------
COMMON="$SRC/ggml/cmake/common.cmake"
git -C "$SRC" checkout -q -- ggml/cmake/common.cmake
sed -i '' -E 's/(CMAKE_OSX_ARCHITECTURES[[:space:]]+)STREQUAL "arm64"/\1MATCHES "^arm64"/' "$COMMON"
grep -q 'CMAKE_OSX_ARCHITECTURES      MATCHES "\^arm64"' "$COMMON" \
  || { echo "error: arm64_32 patch did not apply; upstream changed ggml_get_system_arch. Re-check before building." >&2; exit 1; }

# --- 3. Build ---------------------------------------------------------------------------
# One architecture per build directory, with CMake's Makefile generator. This is the
# recipe that built on the M4 Max on 2026-11-23 (watchOS 27.2 SDK). The Xcode generator
# was dropped because it needs a working xcodebuild at configure time and failed with
# "No CMAKE_C_COMPILER could be found" where xcodebuild was restricted.
build() {  # name sdk arch
  local name="$1" sdk="$2" arch="$3"
  local b="$WORK/build-$name"
  local sysroot; sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  echo "Configuring $name ($sdk, $arch)"
  cmake -S "$SRC" -B "$b" -G "Unix Makefiles" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=watchOS \
    -DCMAKE_OSX_SYSROOT="$sysroot" \
    -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$WATCHOS_MIN" \
    -DCMAKE_C_FLAGS="-D_DARWIN_C_SOURCE -Wno-shorten-64-to-32" \
    -DCMAKE_CXX_FLAGS="-D_DARWIN_C_SOURCE -Wno-shorten-64-to-32" \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_METAL=OFF -DGGML_BLAS=OFF -DGGML_ACCELERATE="$ACCEL" \
    -DGGML_OPENMP=OFF -DGGML_NATIVE=OFF \
    -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_APP=OFF \
    -DLLAMA_BUILD_MTMD=OFF -DLLAMA_OPENSSL=OFF \
    > "$WORK/configure-$name.log" 2>&1 || { tail -40 "$WORK/configure-$name.log"; exit 1; }
  grep -q "GGML_SYSTEM_ARCH: ARM" "$WORK/configure-$name.log" \
    || { echo "error: ggml did not detect ARM for $name (see configure-$name.log)" >&2; exit 1; }
  echo "Building $name"
  cmake --build "$b" -j "$JOBS" > "$WORK/build-$name.log" 2>&1 \
    || { tail -60 "$WORK/build-$name.log"; exit 1; }

  local libs=()
  for l in libllama.a libggml.a libggml-base.a libggml-cpu.a libvendor-hash.a; do
    local f; f="$(find "$b" -name "$l" | head -1)"
    [[ -n "$f" ]] || { echo "error: $l not found in $b" >&2; exit 1; }
    libs+=("$f")
  done
  mkdir -p "$WORK/out"
  xcrun libtool -static -o "$WORK/out/$name.a" "${libs[@]}" 2>/dev/null
}

build s5 watchos arm64_32          # Series 4 to 8, SE: the Series 5 slice
build device64 watchos arm64       # Series 9 and later
build sim watchsimulator arm64

mkdir -p "$WORK/out/device" "$WORK/out/sim"
xcrun lipo -create "$WORK/out/s5.a" "$WORK/out/device64.a" -output "$WORK/out/device/libllama-watch.a"
cp "$WORK/out/sim.a" "$WORK/out/sim/libllama-watch.a"

# --- 4. Instruction check on the S5 slice -------------------------------------------------
DIS="$WORK/out/s5.dis"
xcrun otool -tv "$WORK/out/s5.a" > "$DIS"
NEON=$(grep -cE '\b(fmla|fmul|fadd)\.(4s|8h|2d)\b|\bfmla[[:space:]]+v[0-9]+\.' "$DIS" || true)
BAD=$(grep -cE '\b(sdot|udot|usdot|smmla|ummla|bfdot|bfmmla)\b' "$DIS" || true)
echo "arm64_32 slice: $NEON NEON float vector instructions, $BAD unsupported (dotprod/i8mm/bf16)"
[[ "$NEON" -gt 100 ]] || { echo "error: arm64_32 slice has almost no NEON code; the arch fix did not take" >&2; exit 1; }
[[ "$BAD" -eq 0 ]] || { echo "error: arm64_32 slice uses instructions the S5 cannot execute" >&2; exit 1; }

# --- 5. Headers + module map, then the xcframework ----------------------------------------------
H="$WORK/headers"
rm -rf "$H"
"$ROOT/scripts/llama-headers.sh" "$SRC" "$H" --link-cxx

rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
xcodebuild -create-xcframework \
  -library "$WORK/out/device/libllama-watch.a" -headers "$H" \
  -library "$WORK/out/sim/libllama-watch.a" -headers "$H" \
  -output "$OUT" >/dev/null
cp "$SRC/LICENSE" "$(dirname "$OUT")/llama.cpp-LICENSE"
echo "$LLAMA_CPP_REV" > "$(dirname "$OUT")/llama.cpp-REVISION"
echo "Built $OUT (Accelerate: $ACCEL)"
