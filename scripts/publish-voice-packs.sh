#!/usr/bin/env bash
# Uploads the voice packs in Voices/dist as assets of the GitHub release that
# VOICE_BASE_URL in scripts/versions.env points at (voices-v1 on Palvaran/KITTWatch), then
# downloads each one back and checks its SHA-256 against versions.env.
#
# The watch downloads them without signing in, so the release must be on a public
# repository. Needs the GitHub CLI (gh), signed in. Nothing is uploaded until you run this.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source scripts/versions.env

TAG="${VOICE_BASE_URL##*/}"
REPO="$(sed -E 's#https://github.com/([^/]+/[^/]+)/releases/download/.*#\1#' <<<"$VOICE_BASE_URL")"
for file in "$VOICE_HEART_FILE" "$VOICE_MICHAEL_FILE"; do
  [[ -f "Voices/dist/$file" ]] || { echo "Voices/dist/$file is missing. Run scripts/build-voice-packs.sh." >&2; exit 1; }
done
if [[ "$(gh repo view "$REPO" --json visibility --jq .visibility)" != "PUBLIC" ]]; then
  echo "$REPO is not public, so the watch couldn't download from its releases." >&2
  echo "Make it public, or host the packs elsewhere and change VOICE_BASE_URL." >&2
  exit 1
fi
gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 \
  || gh release create "$TAG" --repo "$REPO" --title "Guide voices ($TAG)" \
       --notes "Optional KITT guide voice packs (Kokoro-82M, Apache 2.0). Downloaded from the watch: More › Voice."
gh release upload "$TAG" --repo "$REPO" --clobber "Voices/dist/$VOICE_HEART_FILE" "Voices/dist/$VOICE_MICHAEL_FILE"

check() {   # URL SHA256
  local got
  got="$(curl -fsSL "$1" | shasum -a 256 | cut -d' ' -f1)"
  [[ "$got" == "$2" ]] && echo "OK  $1" || { echo "MISMATCH  $1 ($got)" >&2; return 1; }
}
check "$VOICE_HEART_URL" "$VOICE_HEART_SHA256"
check "$VOICE_MICHAEL_URL" "$VOICE_MICHAEL_SHA256"
