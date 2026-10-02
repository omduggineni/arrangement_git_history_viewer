from __future__ import annotations

import os
import shutil
import subprocess
import threading
import time
from pathlib import Path

# .mscz is MuseScore's own proprietary file format (a zipped, version-specific XML
# schema). There is no maintained pure-Python reader for it, and music21 /
# converter21 do not understand it either -- so converting it to MusicXML is the
# one step in this app that has to shell out to the MuseScore CLI itself. Every
# other step (diffing, rendering) runs in-process.

_MSCORE_CANDIDATES = [
    "mscore",
    "mscore4portable",
    "musescore",
    "/Applications/MuseScore 4.app/Contents/MacOS/mscore",
    "/Applications/MuseScore 4.app/Contents/MacOS/mscore4portable",
    "/opt/homebrew/bin/mscore",
    "/usr/bin/mscore",
]

# MuseScore's CLI behaves like a single-instance GUI app under the hood and is
# unreliable when invoked concurrently, so conversions are serialized.
_MSCORE_LOCK = threading.Lock()

_mscore_path_cache: str | None = None


class ConversionError(RuntimeError):
    pass


def mscore_path() -> str:
    global _mscore_path_cache
    if _mscore_path_cache:
        return _mscore_path_cache

    env_path = os.environ.get("MSCORE_PATH")
    if env_path and Path(env_path).exists():
        _mscore_path_cache = env_path
        return env_path

    for candidate in _MSCORE_CANDIDATES:
        if candidate.startswith("/"):
            found = candidate if Path(candidate).exists() else None
        else:
            found = shutil.which(candidate)
        if found:
            _mscore_path_cache = found
            return found

    raise ConversionError(
        "Could not find a MuseScore CLI binary (mscore). "
        "Set the MSCORE_PATH environment variable to its full path."
    )


def _last_meaningful_line(stderr: str) -> str:
    # mscore's stderr on a crash is dominated by macOS crash-reporter noise
    # (mach_o_image_annotations_reader lines for every loaded framework); the
    # actual reason, if any, is usually the last non-blank line before that.
    for line in reversed(stderr.splitlines()):
        line = line.strip()
        if line and "mach_o_image_annotations_reader" not in line:
            return line
    return stderr.strip()[-300:]


def mscz_to_musicxml(mscz_path: Path, out_musicxml_path: Path, timeout: int = 180, retries: int = 4) -> Path:
    """Convert via the MuseScore CLI.

    MuseScore's CLI is a full GUI app under the hood (not a true headless
    tool), and its startup races with its own crash-reporter/single-instance
    machinery when another MuseScore process is already running (e.g. the
    user editing a score in the GUI at the same time) -- this shows up as an
    intermittent SIGABRT that a retry usually clears.
    """
    out_musicxml_path.parent.mkdir(parents=True, exist_ok=True)
    exe = mscore_path()

    last_error: ConversionError | None = None
    for attempt in range(retries + 1):
        with _MSCORE_LOCK:
            proc = subprocess.run(
                [exe, "-o", str(out_musicxml_path), str(mscz_path)],
                capture_output=True,
                timeout=timeout,
                check=False,
            )
        if proc.returncode == 0 and out_musicxml_path.exists():
            return out_musicxml_path

        stderr = proc.stderr.decode("utf-8", errors="replace")
        reason = _last_meaningful_line(stderr)
        last_error = ConversionError(
            f"mscore failed to convert {mscz_path.name} (exit {proc.returncode}): {reason}\n"
            "This can happen when MuseScore is already open elsewhere; closing it may help."
        )
        if attempt < retries:
            time.sleep(0.5 * (attempt + 1))

    assert last_error is not None
    raise last_error
