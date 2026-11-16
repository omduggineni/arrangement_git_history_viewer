"""Download the portable git that gets bundled into the app.

Uses dugite-native (https://github.com/desktop/dugite-native), the relocatable
git builds GitHub Desktop ships: git itself, git-lfs, and Git Credential
Manager (so HTTPS sign-in works without any git installed on the machine).
Each archive is pinned by sha256.

Run from the project root (the PyInstaller spec also calls this):
    python packaging/fetch_git.py           # -> vendor/git, for this machine
"""

from __future__ import annotations

import hashlib
import platform
import shutil
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path

VERSION = "v2.53.0-4"
_BASE = f"https://github.com/desktop/dugite-native/releases/download/{VERSION}/dugite-native-v2.53.0-4098283"
_SHA256 = {
    "macOS-arm64": "f9dc64635a5b62fbd7ad95db73268bbb8912255ac516d65d37bf7af22fcb8ffe",
    "macOS-x64": "ae6686718aa34f4140424db16b92a47dcffd6d1f312eb8b5f3b267f7404e2680",
    "ubuntu-x64": "cca76aa31ad9e835e771ee7f55b73934777fbd8d16757a10d307ba06de860901",
    "ubuntu-arm64": "a161f45af4626bb7e0c688854bd4a9aee47cc514bca404cff0a5e3536ef1c0af",
    "windows-x64": "7b76bc5c32c0d7c5984efdc2a8a32697cf1e8a43bc55176fbf9869c0ee995130",
    "windows-arm64": "1abbeb3a2ce06e9b80e75bb888dce959b6c73bdb11ccc670a01a71d64f4422a5",
}

PROJECT_ROOT = Path(__file__).resolve().parent.parent
DEST = PROJECT_ROOT / "vendor" / "git"

# Appended to dugite's own system gitconfig on macOS/Linux (Windows' already
# sets helper = manager). The app runs git with terminal prompts disabled, so
# without a GUI-capable credential helper there'd be no way to sign in over
# HTTPS on a machine that has never had git set up.
_CREDENTIAL_CONFIG = {
    "macOS": "\n[credential]\n  helper = manager\n",
    # GCM has no default credential store on Linux; Secret Service is the
    # desktop keyring (GNOME Keyring / KWallet).
    "ubuntu": "\n[credential]\n  helper = manager\n  credentialStore = secretservice\n",
}


def target() -> str:
    machine = platform.machine().lower()
    arch = {"arm64": "arm64", "aarch64": "arm64", "x86_64": "x64", "amd64": "x64"}.get(machine)
    os_name = {"darwin": "macOS", "linux": "ubuntu", "win32": "windows"}.get(sys.platform)
    if not arch or not os_name:
        raise SystemExit(f"No bundled git available for {sys.platform}/{machine}.")
    return f"{os_name}-{arch}"


def _download(url: str, out: Path) -> None:
    with urllib.request.urlopen(url) as response, open(out, "wb") as f:
        shutil.copyfileobj(response, f)


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _flatten_symlinks(root: Path) -> None:
    """PyInstaller copies a symlink as a full copy of its target, which would
    turn git's ~140 dashed-builtin symlinks (git-add -> git, ...) into ~450 MB.
    git runs builtins internally and doesn't need them (this matches git's own
    SKIP_DASHED_BUILT_INS build option); any other symlink becomes a copy."""
    for link in sorted(p for p in root.rglob("*") if p.is_symlink()):
        target_path = link.resolve()
        link.unlink()
        if target_path.name != "git" and target_path.is_file():
            shutil.copy2(target_path, link)


def fetch(force: bool = False) -> Path:
    name = target()
    stamp = DEST / ".dugite-version"
    if not force and stamp.exists() and stamp.read_text().strip() == f"{VERSION} {name}":
        return DEST

    with tempfile.TemporaryDirectory() as tmp:
        archive = Path(tmp) / "git.tar.gz"
        url = f"{_BASE}-{name}.tar.gz"
        print(f"Downloading bundled git: {url}")
        _download(url, archive)
        actual = _sha256(archive)
        if actual != _SHA256[name]:
            raise SystemExit(f"Checksum mismatch for {url}: expected {_SHA256[name]}, got {actual}")

        staging = Path(tmp) / "git"
        with tarfile.open(archive) as tar:
            tar.extractall(staging, filter="tar")
        _flatten_symlinks(staging)
        os_name = name.split("-")[0]
        if os_name in _CREDENTIAL_CONFIG:
            with open(staging / "etc" / "gitconfig", "a") as f:
                f.write(_CREDENTIAL_CONFIG[os_name])
        (staging / ".dugite-version").write_text(f"{VERSION} {name}\n")

        if DEST.exists():
            shutil.rmtree(DEST)
        DEST.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(staging), DEST)
    print(f"Bundled git ready in {DEST}")
    return DEST


if __name__ == "__main__":
    fetch(force="--force" in sys.argv)
