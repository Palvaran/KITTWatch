#!/usr/bin/env bash
# Checks Models/<MODEL_FILE>, the copy the Mac tools use (kitt ask, kitt eval), against the
# pinned SHA-256. Runs from fetch-model.sh. The watch app does not bundle
# the model; it verifies its own download (KITTCore's ModelStore).
set -euo pipefail
ROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
source "$ROOT/scripts/versions.env"
FILE="$ROOT/Models/$MODEL_FILE"

if [[ ! -f "$FILE" ]]; then
  echo "error: $FILE is missing. Run scripts/fetch-model.sh" >&2
  exit 1
fi

# Cache the hash by size+mtime so incremental builds stay fast.
STAMP="$ROOT/Models/.verified"
if [[ "$(uname)" == Darwin ]]; then SIG="$(stat -L -f '%z %m' "$FILE")"; else SIG="$(stat -L -c '%s %Y' "$FILE")"; fi
if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$SIG $MODEL_SHA256" ]]; then
  echo "Model verified (cached): $MODEL_FILE"
  exit 0
fi

ACTUAL="$( (shasum -a 256 "$FILE" 2>/dev/null || sha256sum "$FILE") | awk '{print $1}')"
if [[ "$ACTUAL" != "$MODEL_SHA256" ]]; then
  echo "error: $MODEL_FILE checksum $ACTUAL does not match pinned $MODEL_SHA256" >&2
  exit 1
fi
echo "$SIG $MODEL_SHA256" > "$STAMP"
echo "Model verified: $MODEL_FILE ($ACTUAL)"
