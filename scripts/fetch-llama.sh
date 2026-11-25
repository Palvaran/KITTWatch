#!/usr/bin/env bash
# Check out llama.cpp at the pinned revision into .build-llama/llama.cpp.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/versions.env"
SRC="$ROOT/.build-llama/llama.cpp"

mkdir -p "$ROOT/.build-llama"
if [[ ! -d "$SRC/.git" ]]; then
  git init -q "$SRC"
  git -C "$SRC" remote add origin "$LLAMA_CPP_REPO"
fi
if [[ "$(git -C "$SRC" rev-parse HEAD 2>/dev/null || true)" != "$LLAMA_CPP_REV" ]]; then
  git -C "$SRC" fetch -q --depth 1 origin "$LLAMA_CPP_REV"
  git -C "$SRC" checkout -q --force FETCH_HEAD
fi
[[ "$(git -C "$SRC" rev-parse HEAD)" == "$LLAMA_CPP_REV" ]] || { echo "error: checkout is not $LLAMA_CPP_REV" >&2; exit 1; }
echo "llama.cpp at $LLAMA_CPP_REV"
