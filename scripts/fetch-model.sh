#!/usr/bin/env bash
# Download the pinned SmolLM2 GGUF into Models/ and verify its SHA-256.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=versions.env
source "$ROOT/scripts/versions.env"

mkdir -p "$ROOT/Models"
DEST="$ROOT/Models/$MODEL_FILE"
URL="https://huggingface.co/$MODEL_REPO/resolve/$MODEL_REV/$MODEL_FILE"

if [[ -f "$DEST" ]] && "$ROOT/scripts/verify-model.sh" >/dev/null 2>&1; then
  echo "Model already present and verified: $DEST"
  exit 0
fi

echo "Downloading $MODEL_FILE @ $MODEL_REV"
curl -fL --retry 3 --progress-bar -o "$DEST.part" "$URL"
mv "$DEST.part" "$DEST"
"$ROOT/scripts/verify-model.sh"
