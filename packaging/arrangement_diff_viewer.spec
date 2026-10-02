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

from pathlib import Path

from PyInstaller.utils.hooks import collect_all

# SPECPATH is injected by PyInstaller into the spec file's exec namespace.
PROJECT_ROOT = Path(SPECPATH).resolve().parent  # noqa: F821

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

datas = []
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
    icon=None,
    bundle_identifier="com.omduggineni.arrangement-diff-viewer",
    info_plist={
        "NSHighResolutionCapable": True,
        "LSMinimumSystemVersion": "11.0",
    },
)
