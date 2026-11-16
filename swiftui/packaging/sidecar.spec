# -*- mode: python ; coding: utf-8 -*-
# PyInstaller spec for the notation-diff sidecar (the one Python piece of the
# app). verovio's font data and music21's corpus/metadata files are non-code
# data that static analysis can't find, so they're pulled in wholesale.
from pathlib import Path

from PyInstaller.utils.hooks import collect_all

ROOT = Path(SPECPATH).resolve().parent  # noqa: F821

datas, binaries, hiddenimports = [], [], []
for package in ["verovio", "music21", "converter21", "musicdiff"]:
    d, b, h = collect_all(package)
    datas += d
    binaries += b
    hiddenimports += h

a = Analysis(
    [str(ROOT / "sidecar" / "diff_sidecar.py")],
    pathex=[],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports,
    excludes=["tkinter", "matplotlib.tests", "IPython", "jupyter"],
)
pyz = PYZ(a.pure)
exe = EXE(pyz, a.scripts, [], exclude_binaries=True, name="diff_sidecar", console=True)
coll = COLLECT(exe, a.binaries, a.datas, name="diff_sidecar")
