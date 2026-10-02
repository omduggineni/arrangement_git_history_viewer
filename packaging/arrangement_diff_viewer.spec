# -*- mode: python ; coding: utf-8 -*-
#
# PyInstaller spec for the Arrangement Diff Viewer native app.
#
# Several dependencies ship non-code data (verovio's font/glyph data, music21's
# corpus and metadata, nicegui's bundled web assets) or dynamically-imported
# submodules (uvicorn's protocol backends) that PyInstaller's static analysis
# can't find on its own, so we pull each of them in wholesale with
# collect_all() rather than hand-enumerating what's needed.
#
# Build with `make app` (see the Makefile), or directly:
#   pyinstaller packaging/arrangement_diff_viewer.spec --noconfirm

import sys
from pathlib import Path

from PyInstaller.utils.hooks import collect_all

# SPECPATH is injected by PyInstaller into the spec file's exec namespace.
PROJECT_ROOT = Path(SPECPATH).resolve().parent  # noqa: F821

# A portable git, so the app doesn't depend on git being installed (see
# fetch_git.py). Downloaded on first build, then reused from vendor/git.
sys.path.insert(0, SPECPATH)  # noqa: F821
from fetch_git import fetch as fetch_git  # noqa: E402

GIT_DIR = fetch_git()

COLLECT_ALL_PACKAGES = [
    "nicegui",
    "webview",  # pywebview's importable module name
    "verovio",
    "music21",
    "converter21",
    "musicdiff",
    "pygit2",
    "uvicorn",
    "starlette",
    "websockets",
    "h11",
]

# App icon, in each platform's native format and shape (see make_icons.py).
# The PNGs are also bundled for the app to use at runtime (favicon, window and
# dock icons).
ICON_PNG = PROJECT_ROOT / "packaging" / "arrangement-diff-viewer.png"
ICON_MACOS_PNG = PROJECT_ROOT / "packaging" / "icon-macos.png"
ICON_ICNS = PROJECT_ROOT / "packaging" / "icon.icns"
ICON_ICO = PROJECT_ROOT / "packaging" / "icon.ico"

datas = [
    (str(GIT_DIR), "git"),  # -> sys._MEIPASS/git, where app/settings.py looks for it
    (str(ICON_PNG), "."),  # -> sys._MEIPASS/arrangement-diff-viewer.png
    (str(ICON_MACOS_PNG), "."),  # -> sys._MEIPASS/icon-macos.png
]
binaries = []
hiddenimports = []
for package in COLLECT_ALL_PACKAGES:
    pkg_datas, pkg_binaries, pkg_hiddenimports = collect_all(package)
    datas += pkg_datas
    binaries += pkg_binaries
    hiddenimports += pkg_hiddenimports

a = Analysis(
    [str(PROJECT_ROOT / "entry.py")],
    pathex=[str(PROJECT_ROOT)],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
)
pyz = PYZ(a.pure, a.zipped_data)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="Arrangement Diff Viewer",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=False,
    icon=str(ICON_ICO) if sys.platform == "win32" else None,
)

coll = COLLECT(
    exe,
    a.binaries,
    a.zipfiles,
    a.datas,
    strip=False,
    upx=False,
    name="Arrangement Diff Viewer",
)

app = BUNDLE(
    coll,
    name="Arrangement Diff Viewer.app",
    icon=str(ICON_ICNS),
    bundle_identifier="com.omduggineni.arrangement-diff-viewer",
    info_plist={
        "NSHighResolutionCapable": True,
        "LSMinimumSystemVersion": "11.0",
    },
)
