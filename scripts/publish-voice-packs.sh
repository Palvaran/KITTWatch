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
# Refuse before uploading anything if a pack isn't the one the app pins: replacing a
# published pack with different bytes would make every watch's download fail its check.
for pair in "$VOICE_HEART_FILE:$VOICE_HEART_SHA256" "$VOICE_MICHAEL_FILE:$VOICE_MICHAEL_SHA256"; do
  file="${pair%%:*}"; pinned="${pair##*:}"
  [[ -f "Voices/dist/$file" ]] || { echo "Voices/dist/$file is missing. Run scripts/build-voice-packs.sh." >&2; exit 1; }
  if [[ "$(shasum -a 256 "Voices/dist/$file" | cut -d' ' -f1)" != "$pinned" ]]; then
    echo "Voices/dist/$file is not the pack scripts/versions.env pins. Nothing was uploaded." >&2
    echo "For new recordings, give them a new release and file names (voices-v2), run" >&2
    echo "scripts/build-voice-packs.sh --update, rebuild the app, then publish." >&2
    exit 1
  fi
done
if [[ "$(gh repo view "$REPO" --json visibility --jq .visibility)" != "PUBLIC" ]]; then
  echo "$REPO is not public, so the watch couldn't download from its releases." >&2
  echo "Make it public, or host the packs elsewhere and change VOICE_BASE_URL." >&2
  exit 1
fi
check() {   # URL SHA256
  local got
  got="$(curl -fsSL "$1" | shasum -a 256 | cut -d' ' -f1)"
  [[ "$got" == "$2" ]] && echo "OK  $1" || { echo "MISMATCH  $1 ($got)" >&2; return 1; }
}
# Treat each published URL as immutable, even if a developer regenerated the local pins.
# If the tag lookup failed for a reason other than a missing release, creation fails closed.
if ! assets="$(gh release view "$TAG" --repo "$REPO" --json assets --jq '.assets[].name')"; then
  gh release create "$TAG" --repo "$REPO" --title "Guide voices ($TAG)" \
    --notes "Optional KITT guide voice packs (Kokoro-82M, Apache 2.0)."
  assets=""
fi
missing=()
queue_missing() {
  local file="$1" url="$2" pinned="$3"
  if grep -Fxq -- "$file" <<<"$assets"; then
    check "$url" "$pinned"
  else
    missing+=("Voices/dist/$file")
  fi
}
queue_missing "$VOICE_HEART_FILE" "$VOICE_HEART_URL" "$VOICE_HEART_SHA256"
queue_missing "$VOICE_MICHAEL_FILE" "$VOICE_MICHAEL_URL" "$VOICE_MICHAEL_SHA256"
# Without --clobber, a concurrent publish cannot replace a file between checking and upload.
if (( ${#missing[@]} )); then
  gh release upload "$TAG" --repo "$REPO" "${missing[@]}"
fi
check "$VOICE_HEART_URL" "$VOICE_HEART_SHA256"
check "$VOICE_MICHAEL_URL" "$VOICE_MICHAEL_SHA256"
