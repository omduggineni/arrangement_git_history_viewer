"""User settings: where to find the external programs this app runs (git and
the MuseScore CLI), and how to launch them.

Each tool resolves, in order, to: the path saved on the Settings page, the
tool's environment variable (GIT_PATH / MSCORE_PATH), the copy bundled with
the app (git only), or an auto-detected installed copy. Saving the default
path (or nothing) stores no override, so the default keeps applying if the
tool is upgraded or moved later.
"""

from __future__ import annotations

import glob
import json
import os
import plistlib
import shutil
import subprocess
import sys
from contextlib import nullcontext
from dataclasses import dataclass
from pathlib import Path

# Next to recent_repos.json, for the same reasons (see recent.py).
_FILE = Path.home() / ".config" / "arrangement-diff-viewer" / "settings.json"

_PLATFORM = "win32" if sys.platform == "win32" else "darwin" if sys.platform == "darwin" else "linux"


@dataclass(frozen=True)
class Tool:
    key: str  # settings.json key
    name: str
    env_var: str
    description: str
    # Per platform. Bare names are looked up on PATH; anything else has ~ and
    # %VARS%/$VARS expanded and is globbed.
    candidates: dict[str, tuple[str, ...]]
    preferred_names: tuple[str, ...]  # executable names to prefer inside a macOS .app bundle


# GUI apps don't get the user's shell PATH (an app launched from Finder only
# gets /usr/bin:/bin:/usr/sbin:/sbin), so common install locations are listed
# explicitly rather than relying on PATH.
GIT = Tool(
    key="git_path",
    name="Git",
    env_var="GIT_PATH",
    description="Used for clone, fetch, push and pull. A copy of git comes with this app; "
    "choose another here to use your own git setup instead.",
    candidates={
        "darwin": (
            # Before /usr/bin/git: without the Xcode Command Line Tools installed,
            # macOS's /usr/bin/git is a stub that pops up an install dialog.
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
            "git",
            "/usr/bin/git",
        ),
        "linux": (
            "git",
            "/usr/bin/git",
            "/usr/local/bin/git",
            "/home/linuxbrew/.linuxbrew/bin/git",
        ),
        "win32": (
            "git",
            r"%ProgramFiles%\Git\cmd\git.exe",
            r"%ProgramFiles(x86)%\Git\cmd\git.exe",
            r"%LOCALAPPDATA%\Programs\Git\cmd\git.exe",
            r"~\scoop\apps\git\current\cmd\git.exe",
        ),
    },
    preferred_names=("git",),
)

MSCORE = Tool(
    key="mscore_path",
    name="MuseScore",
    env_var="MSCORE_PATH",
    description="Used to convert .mscz scores to MusicXML so they can be compared.",
    candidates={
        "darwin": (
            "mscore",
            "/Applications/MuseScore*.app/Contents/MacOS/mscore*",
            "~/Applications/MuseScore*.app/Contents/MacOS/mscore*",
            "/opt/homebrew/bin/mscore",
            "/usr/local/bin/mscore",
        ),
        # Names per MuseScore's handbook (command-line usage): `mscore` /
        # `musescore` for distro packages, `mscore4portable` for an installed
        # AppImage. Desktop sessions often lack ~/.local/bin on PATH.
        "linux": (
            "mscore",
            "musescore",
            "mscore4portable",
            "musescore4",
            "~/.local/bin/mscore*portable",
            "~/Applications/MuseScore*.AppImage",
            "~/.local/bin/MuseScore*.AppImage",
            "/opt/MuseScore*.AppImage",
            "/opt/musescore*/bin/mscore*",
            "/var/lib/flatpak/exports/bin/org.musescore.MuseScore",
            "~/.local/share/flatpak/exports/bin/org.musescore.MuseScore",
            "/snap/bin/musescore",
            "/usr/bin/mscore",
            "/usr/bin/musescore",
            "/usr/local/bin/mscore",
        ),
        "win32": (
            "MuseScore4",
            "MuseScore3",
            r"%ProgramFiles%\MuseScore*\bin\MuseScore*.exe",
            r"%ProgramFiles(x86)%\MuseScore*\bin\MuseScore*.exe",
            r"%LOCALAPPDATA%\Programs\MuseScore*\bin\MuseScore*.exe",
        ),
    },
    preferred_names=("mscore", "mscore4portable", "MuseScore4", "MuseScore"),
)

TOOLS = (GIT, MSCORE)


# --- Persistence ------------------------------------------------------------


def _load() -> dict:
    try:
        raw = json.loads(_FILE.read_text())
    except (OSError, ValueError):
        return {}
    return raw if isinstance(raw, dict) else {}


def _save(data: dict) -> None:
    _FILE.parent.mkdir(parents=True, exist_ok=True)
    _FILE.write_text(json.dumps(data, indent=2))


def saved_path(tool: Tool) -> str | None:
    value = _load().get(tool.key)
    return value if isinstance(value, str) and value else None


def save_path(tool: Tool, value: str) -> None:
    """Store `value` as this tool's location. Blank, or the same as what would
    be found anyway, clears the override instead."""
    value = normalize(value, tool)
    data = _load()
    if not value or value == default_path(tool)[0]:
        data.pop(tool.key, None)
    else:
        data[tool.key] = value
    _save(data)


# --- Resolution -------------------------------------------------------------


def is_executable(path: str) -> bool:
    return bool(path) and os.path.isfile(path) and os.access(path, os.X_OK)


def normalize(value: str, tool: Tool | None = None) -> str:
    """Expand ~ and, for a macOS .app bundle (which file pickers treat as a
    single file), point at the executable inside it."""
    value = value.strip()
    if not value:
        return ""
    path = Path(value).expanduser()
    if path.suffix == ".app" and path.is_dir():
        return str(_bundle_executable(path, tool.preferred_names if tool else ()) or path)
    return str(path)


def _bundle_executable(bundle: Path, preferred_names: tuple[str, ...]) -> Path | None:
    macos = bundle / "Contents" / "MacOS"
    for name in preferred_names:
        if is_executable(str(macos / name)):
            return macos / name
    try:
        with open(bundle / "Contents" / "Info.plist", "rb") as f:
            name = plistlib.load(f).get("CFBundleExecutable")
        if name and is_executable(str(macos / name)):
            return macos / name
    except (OSError, plistlib.InvalidFileException):
        pass
    return None


def _is_bare_name(candidate: str) -> bool:
    return not any(sep in candidate for sep in "/\\")


def detect(tool: Tool) -> str | None:
    """An installed copy of this tool, if one can be found."""
    for candidate in tool.candidates.get(_PLATFORM, ()):
        if _is_bare_name(candidate):
            found = shutil.which(candidate)
            if found:
                return found
            continue
        pattern = os.path.expandvars(os.path.expanduser(candidate))
        if "%" in pattern or "$" in pattern:
            continue  # an unset environment variable
        for match in sorted(glob.glob(pattern), reverse=True):  # newest version first
            if is_executable(match):
                return match
    return None


def default_path(tool: Tool) -> tuple[str | None, str]:
    """The path used when nothing is saved, and where it came from."""
    env_value = os.environ.get(tool.env_var)
    if env_value and is_executable(env_value):
        return env_value, f"from ${tool.env_var}"
    if tool is GIT and is_executable(bundled_git()):
        return bundled_git(), "bundled"
    found = detect(tool)
    return found, "auto-detected" if found else "not found"


def resolve(tool: Tool) -> tuple[str | None, str]:
    """The path to run for this tool, and where it came from. Re-resolved on
    every call (it's only a few stats), so changes apply immediately."""
    saved = saved_path(tool)
    if saved:
        return saved, "custom"
    return default_path(tool)


def path_for(tool: Tool) -> str | None:
    return resolve(tool)[0]


# --- Launching --------------------------------------------------------------


def _bundled_git_dir() -> Path:
    # PyInstaller unpacks bundled data under sys._MEIPASS; in a dev checkout,
    # packaging/fetch_git.py downloads the same thing to vendor/git.
    if getattr(sys, "frozen", False):
        return Path(sys._MEIPASS) / "git"  # type: ignore[attr-defined]
    return Path(__file__).resolve().parent.parent / "vendor" / "git"


def bundled_git() -> str:
    exe = Path("cmd", "git.exe") if _PLATFORM == "win32" else Path("bin", "git")
    return str(_bundled_git_dir() / exe)


def _bundled_git_env(env: dict[str, str]) -> None:
    """The bundled git is a relocatable build (dugite-native, as used by
    GitHub Desktop) that has to be told where its own files are. Mirrors
    setupEnvironment() in dugite's lib/git-environment.ts."""
    root = _bundled_git_dir()
    if _PLATFORM == "win32":
        sub = next((d for d in ("mingw64", "clangarm64", "mingw32") if (root / d).is_dir()), "mingw64")
        env["PATH"] = os.pathsep.join([str(root / sub / "bin"), str(root / "usr" / "bin"), env.get("PATH", "")])
        env["GIT_EXEC_PATH"] = str(root / sub / "libexec" / "git-core")
        return
    env["GIT_EXEC_PATH"] = str(root / "libexec" / "git-core")
    env.setdefault("GIT_CONFIG_SYSTEM", str(root / "etc" / "gitconfig"))
    env["GIT_TEMPLATE_DIR"] = str(root / "share" / "git-core" / "templates")
    if _PLATFORM == "linux":
        env["PREFIX"] = str(root)
        env.setdefault("GIT_SSL_CAINFO", str(root / "ssl" / "cacert.pem"))


def child_env(exe: str) -> dict[str, str]:
    """Environment for running one of these programs from this app."""
    env = dict(os.environ)
    # A frozen app on Linux runs with LD_LIBRARY_PATH pointing at its own
    # bundled libraries; other programs must get the user's original value
    # back, or they can load the wrong libssl/libstdc++ and crash.
    if getattr(sys, "frozen", False) and _PLATFORM == "linux":
        original = env.pop("LD_LIBRARY_PATH_ORIG", None)
        if original is not None:
            env["LD_LIBRARY_PATH"] = original
        else:
            env.pop("LD_LIBRARY_PATH", None)
    if os.path.normcase(os.path.abspath(exe)) == os.path.normcase(os.path.abspath(bundled_git())):
        _bundled_git_env(env)
    return env


# Without this, each git/MuseScore call from the (windowless) app flashes up a
# console window on Windows.
CREATIONFLAGS = subprocess.CREATE_NO_WINDOW if _PLATFORM == "win32" else 0


def version(tool: Tool, path: str, timeout: int = 60) -> str:
    """Run `<path> --version`; return its first line of output, or raise
    RuntimeError with an explanation."""
    if not is_executable(path):
        raise RuntimeError("No executable file at this path.")
    # MuseScore's CLI starts its whole GUI runtime even for --version, and is
    # unreliable when run concurrently with a conversion.
    from app.convert import _MSCORE_LOCK

    try:
        with _MSCORE_LOCK if tool is MSCORE else nullcontext():
            proc = subprocess.run(
                [path, "--version"],
                env=child_env(path),
                creationflags=CREATIONFLAGS,
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                errors="replace",
                timeout=timeout,
            )
    except subprocess.TimeoutExpired as e:
        raise RuntimeError(f"Didn't respond within {timeout}s.") from e
    except OSError as e:
        raise RuntimeError(str(e)) from e
    output = (proc.stdout.strip() or proc.stderr.strip()).splitlines()
    if proc.returncode != 0:
        raise RuntimeError(f"Exited with code {proc.returncode}" + (f": {output[-1]}" if output else "."))
    return output[0] if output else "OK"
