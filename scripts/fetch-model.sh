#!/usr/bin/env bash
# Download the pinned SmolLM2 GGUF into Models/ for the Mac tools (kitt ask, kitt eval)
# and verify its SHA-256. It fetches MODEL_URL, the same file the watch downloads, so a
# successful run also confirms the hosted copy is the pinned one.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=versions.env
source "$ROOT/scripts/versions.env"

mkdir -p "$ROOT/Models"
DEST="$ROOT/Models/$MODEL_FILE"
URL="$MODEL_URL"

if [[ -f "$DEST" ]] && "$ROOT/scripts/verify-model.sh" >/dev/null 2>&1; then
  echo "Model already present and verified: $DEST"
  exit 0
fi

echo "Downloading $MODEL_FILE @ $MODEL_REV"
curl -fL --retry 3 --progress-bar -o "$DEST.part" "$URL"
mv "$DEST.part" "$DEST"
"$ROOT/scripts/verify-model.sh"
