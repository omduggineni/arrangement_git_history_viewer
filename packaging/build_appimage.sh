#!/usr/bin/env bash
# Wraps the PyInstaller onedir build (dist/Arrangement Diff Viewer/) in an
# AppDir and packages it into an AppImage via appimagetool.
#
# Run after `pyinstaller packaging/arrangement_diff_viewer.spec` (Linux only),
# from the project root:
#   packaging/build_appimage.sh
set -euo pipefail

APP_NAME="Arrangement Diff Viewer"
APPDIR="AppDir"
DIST_DIR="dist/${APP_NAME}"
OUT_FILE="dist/Arrangement-Diff-Viewer.AppImage"

rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin"
cp -R "$DIST_DIR"/. "$APPDIR/usr/bin/"

cat > "$APPDIR/AppRun" <<'EOF'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/usr/bin/Arrangement Diff Viewer" "$@"
EOF
chmod +x "$APPDIR/AppRun"

cat > "$APPDIR/arrangement-diff-viewer.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=${APP_NAME}
Exec=AppRun
Icon=arrangement-diff-viewer
Categories=Utility;
EOF

# appimagetool requires an icon file at the AppDir root, matching the
# .desktop file's Icon= key.
cp packaging/arrangement-diff-viewer.png "$APPDIR/arrangement-diff-viewer.png"

if [ ! -x appimagetool ]; then
  curl -L -o appimagetool \
    https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage
  chmod +x appimagetool
fi

# --appimage-extract-and-run avoids needing FUSE, which CI containers
# typically don't have.
./appimagetool --appimage-extract-and-run "$APPDIR" "$OUT_FILE"

echo "Built: $OUT_FILE"
