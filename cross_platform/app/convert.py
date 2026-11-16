from __future__ import annotations

import subprocess
import threading
import time
from pathlib import Path

from app import settings

# .mscz is MuseScore's own proprietary file format (a zipped, version-specific XML
# schema). There is no maintained pure-Python reader for it, and music21 /
# converter21 do not understand it either -- so converting it to MusicXML is the
# one step in this app that has to shell out to the MuseScore CLI itself. Every
# other step (diffing, rendering) runs in-process.

# MuseScore's CLI behaves like a single-instance GUI app under the hood and is
# unreliable when invoked concurrently, so conversions are serialized.
_MSCORE_LOCK = threading.Lock()


class ConversionError(RuntimeError):
    pass


def mscore_path() -> str:
    path = settings.path_for(settings.MSCORE)
    if path:
        return path
    raise ConversionError(
        "Could not find the MuseScore command-line program (mscore). "
        "Set its location on the Settings page (the gear icon in the toolbar)."
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


def mscz_convert(mscz_path: Path, out_musicxml_path: Path, timeout: int = 180, retries: int = 4) -> Path:
    """Convert via the MuseScore CLI; the output format follows the output
    file's extension (.musicxml, .pdf, ...).

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
            try:
                proc = subprocess.run(
                    [exe, "-o", str(out_musicxml_path), str(mscz_path)],
                    env=settings.child_env(exe),
                    creationflags=settings.CREATIONFLAGS,
                    capture_output=True,
                    timeout=timeout,
                    check=False,
                )
            except OSError as e:  # e.g. a saved path that no longer exists
                raise ConversionError(
                    f"Couldn't run MuseScore at {exe}: {e.strerror or e}\n"
                    "Check its location on the Settings page (the gear icon in the toolbar)."
                ) from e
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


mscz_to_musicxml = mscz_convert
mscz_to_pdf = mscz_convert
