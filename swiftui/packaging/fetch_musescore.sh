#!/bin/bash
# Download the latest MuseScore Studio release for macOS and extract MuseScore.app.
#   packaging/fetch_musescore.sh OUT_DIR
# Leaves OUT_DIR/MuseScore.app (reused on later runs); set REFRESH=1 to re-download.
set -euo pipefail
OUT="${1:?usage: fetch_musescore.sh OUT_DIR}"
mkdir -p "$OUT"
[ -z "${REFRESH:-}" ] && [ -d "$OUT/MuseScore.app" ] && { echo "using $OUT/MuseScore.app"; exit 0; }

RELEASE="$(curl -fsSL https://api.github.com/repos/musescore/MuseScore/releases/latest)"
# the macOS build is the universal .dmg (the only asset without an architecture suffix)
read -r NAME URL < <(printf '%s' "$RELEASE" | python3 -c '
import json, sys
for a in json.load(sys.stdin)["assets"]:
    if a["name"].endswith(".dmg"):
        print(a["name"], a["browser_download_url"]); break
else:
    sys.exit("no .dmg asset in the latest MuseScore release")')
echo "downloading $NAME"
DMG="$OUT/$NAME"
curl -fL --progress-bar -o "$DMG" "$URL"

# verify against the release's published checksums when present
SUMS_URL="$(printf '%s' "$RELEASE" | python3 -c '
import json, sys
print(next((a["browser_download_url"] for a in json.load(sys.stdin)["assets"] if a["name"] == "checksums.sha256.txt"), ""))')"
if [ -n "$SUMS_URL" ]; then
  WANT="$(curl -fsSL "$SUMS_URL" | awk -v n="$NAME" '$2 == n || $2 == "*"n {print $1}')"
  if [ -n "$WANT" ]; then
    GOT="$(shasum -a 256 "$DMG" | awk '{print $1}')"
    [ "$WANT" = "$GOT" ] || { echo "checksum mismatch for $NAME" >&2; exit 1; }
  fi
fi

MNT="$(mktemp -d)"
trap 'hdiutil detach "$MNT" -quiet >/dev/null 2>&1 || true' EXIT
hdiutil attach "$DMG" -mountpoint "$MNT" -nobrowse -readonly -quiet
SRC="$(ls -d "$MNT"/*.app | head -1)"
rm -rf "$OUT/MuseScore.app"
ditto "$SRC" "$OUT/MuseScore.app"
rm -f "$DMG"
echo "extracted $OUT/MuseScore.app"
