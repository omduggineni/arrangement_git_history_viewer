"""Notation diff engine sidecar.

musicdiff / music21 / converter21 / verovio exist only as Python libraries, so
the Rust app runs this script for that one step. Usage:

    diff_sidecar.py MUSICXML1 MUSICXML2 NAME1 NAME2 DIFF_DIR DETAIL

It writes the same cache layout the app reads (text.txt, cost.txt,
excerpts.json, excerpts/*.svg, done.marker) and prints one JSON object per line
on stdout: {"progress": 0..1, "message": str} while working, then either
{"done": true} or {"error": str}.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import converter21
import music21 as m21
import verovio
from musicdiff.annotation import AnnScore
from musicdiff.comparison import Comparison, DiffOperation
from musicdiff.m21utils import M21Utilities
from musicdiff.visualization import Visualization

converter21.register()

_RESOURCE_PATH = os.path.join(os.path.dirname(verovio.__file__), "data")
_VEROVIO_OPTIONS = {"pageWidth": 2100, "pageHeight": 20000, "scale": 40, "adjustPageHeight": True, "breaks": "auto"}


def render_measure_range(musicxml_path, start: int, end: int):
    tk = verovio.toolkit()
    tk.setResourcePath(_RESOURCE_PATH)
    tk.setOptions(_VEROVIO_OPTIONS)
    tk.select({"measureRange": f"{start}-{end}"})
    if not tk.loadFile(str(musicxml_path)):
        return None
    if tk.getPageCount() != 1:
        return None
    return tk.renderToSVG(1)


def emit(**kw) -> None:
    print(json.dumps(kw), flush=True)


# How close two touched measures need to be (in measure numbers) to be shown
# as one excerpt instead of two separate ones.
_CLUSTER_GAP = 2


def _measure_ranges(diff_list: list[DiffOperation]) -> list[tuple[int, int]]:
    """Cluster the measure numbers touched by `diff_list` (from either side of
    the diff) into contiguous ranges, so nearby changes render as one excerpt.
    """
    nums: set[int] = set()
    for op in diff_list:
        obj1, obj2 = op.get_m21_objs()
        for obj in (obj1, obj2):
            if obj is None:
                continue
            measure_number = getattr(obj, "measureNumber", None)
            if isinstance(measure_number, int):
                nums.add(measure_number)

    if not nums:
        return []

    sorted_nums = sorted(nums)
    ranges: list[tuple[int, int]] = []
    start = prev = sorted_nums[0]
    for n in sorted_nums[1:]:
        if n - prev <= _CLUSTER_GAP:
            prev = n
            continue
        ranges.append((start, prev))
        start = prev = n
    ranges.append((start, prev))
    return ranges


def _excerpt_label(start: int, end: int) -> str:
    return f"Measure {start}" if start == end else f"Measures {start}–{end}"


def _touched_parts(diff_list: list[DiffOperation]) -> list[tuple[int, str]]:
    """(measureNumber, partName) for every diffed object on either side that
    has both -- used to figure out which staves actually changed in a given
    measure range, so unchanged staves can be left out of that excerpt."""
    touched: list[tuple[int, str]] = []
    for op in diff_list:
        for obj in op.get_m21_objs():
            if obj is None:
                continue
            measure_number = getattr(obj, "measureNumber", None)
            if not isinstance(measure_number, int):
                continue
            part = obj.getContextByClass(m21.stream.Part)
            if part is None or not part.partName:
                continue
            touched.append((measure_number, part.partName))
    return touched


def _active_part_names(touched: list[tuple[int, str]], start: int, end: int) -> set[str]:
    return {name for measure_number, name in touched if start <= measure_number <= end}


def _filtered_score(sc: m21.stream.Score, active_names: set[str]) -> m21.stream.Score:
    """A copy of `sc` containing only the parts named in `active_names` (by
    partName, since one instrument's staves -- e.g. a piano grand staff --
    share a partName even when music21 represents them as separate Part
    streams). Falls back to the full score if nothing matches, so an excerpt
    never ends up with no staves at all."""
    kept = [part for part in sc.parts if part.partName in active_names]
    if not kept:
        return sc

    filtered = m21.stream.Score()
    for part in kept:
        filtered.insert(0, part)
    return filtered


def _compute_and_cache(musicxml1: Path, musicxml2: Path, name1: str, name2: str, diff_dir: Path, detail: int, progress) -> int:
    progress(0.4, "Parsing scores")
    sc1 = m21.converter.parse(musicxml1, forceSource=True)
    sc2 = m21.converter.parse(musicxml2, forceSource=True)

    progress(0.5, "Comparing notation")
    ann1 = AnnScore(sc1, detail)
    ann2 = AnnScore(sc2, detail)
    diff_list, cost = Comparison.annotated_scores_diff(ann1, ann2)

    text = ""
    manifest: list[dict] = []

    if cost != 0:
        progress(0.7, "Rendering differences")
        text = Visualization.get_text_output(sc1, sc2, diff_list, score1Name=name1, score2Name=name2)
        ranges = _measure_ranges(diff_list)
        touched = _touched_parts(diff_list)

        Visualization.mark_diffs(sc1, sc2, diff_list)
        M21Utilities.fixupComplexHiddenRests(sc1, inPlace=True)
        M21Utilities.fixupComplexHiddenRests(sc2, inPlace=True)

        excerpts_dir = diff_dir / "excerpts"
        excerpts_dir.mkdir(parents=True, exist_ok=True)

        for i, (start, end) in enumerate(ranges):
            progress(0.7 + 0.3 * i / len(ranges), f"Rendering differences ({i + 1}/{len(ranges)})")
            active_names = _active_part_names(touched, start, end)
            excerpt_sc1 = _filtered_score(sc1, active_names)
            excerpt_sc2 = _filtered_score(sc2, active_names)

            excerpt_musicxml1 = excerpts_dir / f"{i}_a.musicxml"
            excerpt_musicxml2 = excerpts_dir / f"{i}_b.musicxml"
            excerpt_sc1.write("musicxml", fp=excerpt_musicxml1)
            excerpt_sc2.write("musicxml", fp=excerpt_musicxml2)

            svg1_text = render_measure_range(excerpt_musicxml1, start, end)
            svg2_text = render_measure_range(excerpt_musicxml2, start, end)

            svg1_path = None
            if svg1_text:
                svg1_path = excerpts_dir / f"{i}_a.svg"
                svg1_path.write_text(svg1_text, encoding="utf-8")
            svg2_path = None
            if svg2_text:
                svg2_path = excerpts_dir / f"{i}_b.svg"
                svg2_path.write_text(svg2_text, encoding="utf-8")

            label = _excerpt_label(start, end)
            manifest.append({"label": label, "start": start, "end": end, "has1": svg1_path is not None, "has2": svg2_path is not None})

    (diff_dir / "text.txt").write_text(text, encoding="utf-8")
    (diff_dir / "cost.txt").write_text(str(cost), encoding="utf-8")
    (diff_dir / "excerpts.json").write_text(json.dumps(manifest), encoding="utf-8")
    (diff_dir / "done.marker").write_text("ok")

    return cost




def main(argv: list[str]) -> int:
    mx1, mx2, name1, name2, diff_dir, detail = argv[1:7]
    try:
        _compute_and_cache(Path(mx1), Path(mx2), name1, name2, Path(diff_dir), int(detail), lambda f, m: emit(progress=f, message=m))
    except Exception as e:  # noqa: BLE001
        emit(error=str(e))
        return 1
    emit(done=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
