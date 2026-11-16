"""Recently opened repositories, for the welcome screen and repo switcher."""

from __future__ import annotations

import json
from pathlib import Path

# Kept out of ~/.cache (which is safe to wipe) and out of NiceGUI's own
# storage (which defaults to the cwd -- "/" for an app launched from Finder).
_FILE = Path.home() / ".config" / "arrangement-diff-viewer" / "recent_repos.json"
_MAX = 12


def load() -> list[Path]:
    try:
        raw = json.loads(_FILE.read_text())
    except (OSError, ValueError):
        return []
    return [Path(p) for p in raw if isinstance(p, str) and Path(p).is_dir()]


def add(path: Path) -> None:
    paths = [path] + [p for p in load() if p != path]
    _save(paths[:_MAX])


def remove(path: Path) -> None:
    _save([p for p in load() if p != path])


def _save(paths: list[Path]) -> None:
    try:
        _FILE.parent.mkdir(parents=True, exist_ok=True)
        _FILE.write_text(json.dumps([str(p) for p in paths], indent=2))
    except OSError:
        pass  # a missing recents list is not worth failing over
