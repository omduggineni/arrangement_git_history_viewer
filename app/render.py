from __future__ import annotations

import os

import verovio

# Verovio's Python bindings wrap its C++ engine directly (pybind11), so this
# renders MusicXML -> SVG entirely in-process -- no external executable involved.
#
# Verovio's own resource-path auto-detection silently fails when toolkit() is
# first used from a thread other than the main thread (as NiceGUI's run.io_bound
# does via a ThreadPoolExecutor), which makes loadFile() return False with no
# usable error. Setting the resource path explicitly on every toolkit avoids it.
_RESOURCE_PATH = os.path.join(os.path.dirname(verovio.__file__), "data")

# pageHeight is a ceiling, not a target: adjustPageHeight shrinks the actual
# page to fit its content, so making this generous costs nothing and lets
# bigger measure ranges (see render_measure_range) still fit on one page.
_VEROVIO_OPTIONS = {
    "pageWidth": 2100,
    "pageHeight": 20000,
    "scale": 40,
    "adjustPageHeight": True,
    "breaks": "auto",
}


def render_measure_range(musicxml_path, start: int, end: int) -> str | None:
    """Render just measures [start, end] of a score as a single SVG.

    Renders each side of a diff by its own measure numbers rather than by
    page, so "measures 65-66" always means the same music on both sides even
    when the two versions paginate completely differently (e.g. because a
    voice part was added). Returns None if that measure range doesn't exist
    in this score (verovio silently falls back to rendering the whole score
    in that case, which shows up here as more than the one page we asked for).
    """
    tk = verovio.toolkit()
    tk.setResourcePath(_RESOURCE_PATH)
    tk.setOptions(_VEROVIO_OPTIONS)
    tk.select({"measureRange": f"{start}-{end}"})
    if not tk.loadFile(str(musicxml_path)):
        return None
    if tk.getPageCount() != 1:
        return None
    return tk.renderToSVG(1)
