#!/usr/bin/env bash
# Builds the downloadable guide voice packs from the recordings in Voices/narration:
#   Voices/dist/kitt-voice-heart-v1.kvoice and Voices/dist/kitt-voice-michael-v1.kvoice
#
#   scripts/build-voice-packs.sh            build and report
#   scripts/build-voice-packs.sh --update   also write each pack's size and SHA-256 into
#                                           scripts/versions.env and project.yml
#
# Only recordings of what the guide says now go in; the report counts any reply without a
# recording (the Apple voice reads those). After --update, run xcodegen generate, publish
# the packs (scripts/publish-voice-packs.sh), and rebuild the app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source scripts/versions.env

swift build -c release --package-path Packages/KITTCore --product guide-voice-lines >/dev/null
swift build -c release --package-path Packages/KITTCore --product voice-pack >/dev/null
BIN="$(swift build -c release --package-path Packages/KITTCore --show-bin-path)"
LINES="$(mktemp)"
trap 'rm -f "$LINES"' EXIT
"$BIN/guide-voice-lines" > "$LINES"

pack() {   # VOICE FILE  -> prints FILE= / SHA256= / BYTES=
  "$BIN/voice-pack" --voice "$1" --from Voices/narration --out "Voices/dist/$2" --lines "$LINES"
}
HEART="$(pack Heart "$VOICE_HEART_FILE")"
MICHAEL="$(pack Michael "$VOICE_MICHAEL_FILE")"
value() { sed -n "s/^$2=//p" <<<"$1"; }

if [[ "${1:-}" == "--update" ]]; then
  python3 - "$(value "$HEART" SHA256)" "$(value "$HEART" BYTES)" \
            "$(value "$MICHAEL" SHA256)" "$(value "$MICHAEL" BYTES)" <<'PY'
import re, sys
hs, hb, ms, mb = sys.argv[1:]
values = {"HEART_SHA256": hs, "HEART_BYTES": hb, "MICHAEL_SHA256": ms, "MICHAEL_BYTES": mb}
env = open("scripts/versions.env").read()
yml = open("project.yml").read()
for name, value in values.items():
    env, n = re.subn(rf"^VOICE_{name}=.*$", f"VOICE_{name}={value}", env, flags=re.M)
    assert n == 1, name
    voice, field = name.split("_")
    key = f"KITTVoice{voice.title()}{'SHA256' if field == 'SHA256' else 'Bytes'}"
    yml, n = re.subn(rf"^(\s*{key}: )\S+", rf"\g<1>{value}", yml, flags=re.M)
    assert n == 1, key
open("scripts/versions.env", "w").write(env)
open("project.yml", "w").write(yml)
PY
  echo "Updated scripts/versions.env and project.yml. Run xcodegen generate."
elif [[ "$(value "$HEART" SHA256)" == "$VOICE_HEART_SHA256" && "$(value "$MICHAEL" SHA256)" == "$VOICE_MICHAEL_SHA256" ]]; then
  echo "Both packs match the pins in scripts/versions.env."
else
  echo "These packs differ from the pins in scripts/versions.env. To pin them: scripts/build-voice-packs.sh --update"
fi
