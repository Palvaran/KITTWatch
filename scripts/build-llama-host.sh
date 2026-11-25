#!/usr/bin/env bash
# Build llama.cpp for THIS machine (macOS or Linux), CPU only, at the pinned revision,
# into .build-llama/host/{include,lib}. The `kitt` command-line tool and the engine
# tests link against it via KITT_LLAMA_PREFIX (scripts/kitt sets that for you).
#
# This is the off-watch twin of scripts/build-llama.sh: same source revision, same
# engine code, so prompts and guide changes can be evaluated without the watch.
# Metal is off on purpose: the watch has no GPU path and answers should match.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/versions.env"

WORK="$ROOT/.build-llama"
SRC="$WORK/llama.cpp"
PREFIX="$WORK/host"
JOBS="$( (sysctl -n hw.logicalcpu 2>/dev/null || nproc) )"

command -v cmake >/dev/null || { echo "error: cmake not found (brew install cmake)" >&2; exit 1; }
"$ROOT/scripts/fetch-llama.sh"

cmake -S "$SRC" -B "$WORK/build-host" -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DGGML_METAL=OFF -DGGML_BLAS=OFF -DGGML_ACCELERATE=OFF -DGGML_OPENMP=OFF -DGGML_NATIVE=ON \
  -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_APP=OFF \
  -DLLAMA_BUILD_MTMD=OFF -DLLAMA_OPENSSL=OFF \
  > "$WORK/configure-host.log" 2>&1 || { tail -40 "$WORK/configure-host.log"; exit 1; }
cmake --build "$WORK/build-host" --config Release -j "$JOBS" > "$WORK/build-host.log" 2>&1 \
  || { tail -60 "$WORK/build-host.log"; exit 1; }

LIBS=()
for l in libllama.a libggml.a libggml-base.a libggml-cpu.a libvendor-hash.a; do
  f="$(find "$WORK/build-host" -name "$l" | head -1)"
  [[ -n "$f" ]] || { echo "error: $l not found in $WORK/build-host" >&2; exit 1; }
  LIBS+=("$f")
done

rm -rf "$PREFIX"; mkdir -p "$PREFIX/lib" "$PREFIX/include"
if [[ "$(uname)" == Darwin ]]; then
  xcrun libtool -static -o "$PREFIX/lib/libllama-kitt.a" "${LIBS[@]}" 2>/dev/null
else
  { echo "create $PREFIX/lib/libllama-kitt.a"; for f in "${LIBS[@]}"; do echo "addlib $f"; done; echo save; echo end; } | ar -M
fi
"$ROOT/scripts/llama-headers.sh" "$SRC" "$PREFIX/include"
echo "$LLAMA_CPP_REV" > "$PREFIX/REVISION"
echo "Built $PREFIX (llama.cpp $LLAMA_CPP_REV)"
