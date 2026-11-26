#!/usr/bin/env bash
# Xcode post-build phase for the watch app. Writes when, and from which commit, this build
# was made into the built app's Info.plist as KITTBuild ("2026-11-26 10:42 · d875bab+"),
# which the watch shows at the bottom of More and in About. "+" means the build had
# uncommitted changes. CFBundleVersion is left alone: a watch app's must match its
# iPhone app's.
set -euo pipefail
PLIST="${TARGET_BUILD_DIR:?}/${INFOPLIST_PATH:?}"
STAMP="$(date '+%Y-%m-%d %H:%M')"
REV="$(git -C "${SRCROOT:?}" rev-parse --short HEAD 2>/dev/null || echo "no git")"
if [[ "$REV" != "no git" && -n "$(git -C "$SRCROOT" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
  REV="$REV+"
fi
plutil -replace KITTBuild -string "$STAMP · $REV" "$PLIST"
echo "Stamped $(basename "$PLIST"): $STAMP · $REV"
