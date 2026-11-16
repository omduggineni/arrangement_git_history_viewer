#!/bin/bash
# Assemble "Arrangement Diff Viewer.app" from the release build.
#   [MUSESCORE_APP=path/to/MuseScore.app] packaging/bundle.sh OUT.app [FROZEN_SIDECAR_DIR]
# MUSESCORE_APP, if set, is copied into the app and used as the default MuseScore.
# FROZEN_SIDECAR_DIR is an optional PyInstaller output (containing diff_sidecar/diff_sidecar),
# built from ../arrangement_diff_viewer_rs/packaging/sidecar.spec. Without it the app runs
# sidecar/diff_sidecar.py with the Python chosen on the Settings page.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:?usage: bundle.sh OUT.app [FROZEN_SIDECAR_DIR]}"
BIN="$(swift build -c release --show-bin-path)/ArrangementDiffViewer"
[ -x "$BIN" ] || { echo "build first: swift build -c release" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources/sidecar"
cp "$BIN" "$OUT/Contents/MacOS/ArrangementDiffViewer"
cp sidecar/diff_sidecar.py "$OUT/Contents/Resources/sidecar/"
cp packaging/icon.icns "$OUT/Contents/Resources/icon.icns"
if [ -n "${2:-}" ]; then
  mkdir -p "$OUT/Contents/Resources/sidecar-bin"
  cp -R "$2/diff_sidecar" "$OUT/Contents/Resources/sidecar-bin/"
fi

if [ -n "${MUSESCORE_APP:-}" ]; then
  ditto "$MUSESCORE_APP" "$OUT/Contents/Resources/MuseScore.app"
fi

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Arrangement Diff Viewer</string>
  <key>CFBundleDisplayName</key><string>Arrangement Diff Viewer</string>
  <key>CFBundleIdentifier</key><string>io.github.arrangement_diff_viewer.swiftui</string>
  <key>CFBundleExecutable</key><string>ArrangementDiffViewer</string>
  <key>CFBundleIconFile</key><string>icon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST

codesign --force --deep --sign - "$OUT" >/dev/null
echo "built $OUT"
