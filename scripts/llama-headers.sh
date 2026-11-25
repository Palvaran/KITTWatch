#!/usr/bin/env bash
# Copy the public llama.cpp headers and write the `llama` module map.
# Usage: llama-headers.sh <llama.cpp checkout> <destination include dir> [--link-cxx]
# --link-cxx makes the module pull in libc++ (needed for the xcframework on Apple platforms).
set -euo pipefail
SRC="$1"; DEST="$2"; LINK=""
[[ "${3:-}" == "--link-cxx" ]] && LINK=$'\n    link "c++"'
mkdir -p "$DEST"
cp "$SRC/include/llama.h" "$DEST/"
for f in ggml.h ggml-cpu.h ggml-backend.h ggml-alloc.h ggml-opt.h gguf.h; do cp "$SRC/ggml/include/$f" "$DEST/"; done
cat > "$DEST/module.modulemap" <<MAP
module llama {
    header "llama.h"$LINK
    export *
}
MAP
