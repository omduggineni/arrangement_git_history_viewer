"""The currently open repository. This is a single-user desktop app, so there
is one open repo per process, switchable at runtime from the UI."""

from __future__ import annotations

import asyncio
from pathlib import Path

import pygit2

from app import cache, git_ops, recent

repo: pygit2.Repository | None = None
repo_path: Path | None = None
cache_root: Path | None = None

# Serializes everything that writes to the repo (commit, checkout, push...),
# since those all run in worker threads against the one shared Repository.
write_lock = asyncio.Lock()


def open_repo(path: Path) -> None:
    global repo, repo_path, cache_root
    opened = git_ops.open_repo(path)
    repo = opened
    repo_path = Path(opened.workdir).resolve()
    cache_root = cache.cache_root_for_repo(repo_path)
    recent.add(repo_path)


def close_repo() -> None:
    global repo, repo_path, cache_root
    repo = repo_path = cache_root = None
