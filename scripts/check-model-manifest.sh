#!/usr/bin/env bash
# Xcode pre-build phase for the watch app: fails the build if the download manifests in the
# watch app's Info.plist (from project.yml) differ from scripts/versions.env: the offline
# model and the two guide voice packs. The watch refuses a download unless its size and
# SHA-256 match, so a mismatch here would ship an app that can never install it.
# It also fails if guide recordings ended up inside the watch app instead of a voice pack.
set -euo pipefail
ROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
source "$ROOT/scripts/versions.env"
PLIST="$ROOT/${INFOPLIST_FILE:-Apps/KITTWatch/Info.plist}"

if [[ ! -f "$PLIST" ]]; then
  echo "error: $PLIST is missing. Run xcodegen generate." >&2
  exit 1
fi

read_key() {
  if [[ -x /usr/libexec/PlistBuddy ]]; then
    /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null || true
  else
    python3 -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1],"rb")).get(sys.argv[2],""))' "$PLIST" "$1"
  fi
}

status=0
check() {
  local key="$1" expected="$2" actual
  actual="$(read_key "$key")"
  if [[ "$actual" != "$expected" ]]; then
    echo "error: Info.plist $key is '$actual' but scripts/versions.env says '$expected'. Update project.yml, then run xcodegen generate." >&2
    status=1
  fi
}
check KITTModelFile "$MODEL_FILE"
check KITTModelSHA256 "$MODEL_SHA256"
check KITTModelBytes "$MODEL_BYTES"
check KITTModelURL "$MODEL_URL"
check KITTVoiceHeartFile "$VOICE_HEART_FILE"
check KITTVoiceHeartSHA256 "$VOICE_HEART_SHA256"
check KITTVoiceHeartBytes "$VOICE_HEART_BYTES"
check KITTVoiceHeartURL "$VOICE_HEART_URL"
check KITTVoiceMichaelFile "$VOICE_MICHAEL_FILE"
check KITTVoiceMichaelSHA256 "$VOICE_MICHAEL_SHA256"
check KITTVoiceMichaelBytes "$VOICE_MICHAEL_BYTES"
check KITTVoiceMichaelURL "$VOICE_MICHAEL_URL"
if find "$ROOT/Apps/KITTWatch" -name 'Guide-*.mp3' -print -quit | grep -q .; then
  echo "error: guide recordings are inside Apps/KITTWatch, so they would be bundled into the app. Move them to Voices/narration and rebuild the voice packs (scripts/build-voice-packs.sh)." >&2
  status=1
fi
[[ $status == 0 ]] && echo "Download manifests match versions.env: $MODEL_FILE, $VOICE_HEART_FILE, $VOICE_MICHAEL_FILE"
exit $status
