from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

WORKING_TREE_REF = "WORKING"


@dataclass(frozen=True)
class CommitInfo:
    sha: str
    short_sha: str
    author: str
    date: str
    subject: str


@dataclass(frozen=True)
class VersionRef:
    """A single version of a score file: either a commit, or the working tree."""

    ref: str  # commit sha, or WORKING_TREE_REF
    label: str

    @property
    def is_working_tree(self) -> bool:
        return self.ref == WORKING_TREE_REF


@dataclass(frozen=True)
class ChangedFile:
    """Any uncommitted change in the working tree (not just .mscz files)."""

    path: str  # repo-relative path
    status: str  # "new" | "modified" | "deleted"

    @property
    def is_score(self) -> bool:
        return self.path.endswith(".mscz")


@dataclass(frozen=True)
class BranchInfo:
    name: str  # e.g. "main", or "origin/feature" for a remote-only branch
    is_remote: bool
    is_current: bool


@dataclass(frozen=True)
class SyncStatus:
    """Where the current branch stands relative to its remote."""

    branch: str
    is_unborn: bool  # no commits yet on this branch
    has_remote: bool  # the repo has at least one remote configured
    upstream: str | None  # e.g. "origin/main", or None if not published
    ahead: int = 0
    behind: int = 0


@dataclass
class ScoreFile:
    path: str  # repo-relative path
    status: str  # "clean" | "modified" | "untracked"


@dataclass
class Excerpt:
    """One contiguous cluster of changed measures, rendered independently for
    each side by measure number (not by page) so the two sides always line up
    even when the two scores paginate differently."""

    label: str
    start: int
    end: int
    svg1: Path | None = None
    svg2: Path | None = None


@dataclass
class DiffResult:
    cost: int
    text: str
    excerpts: list[Excerpt] = field(default_factory=list)
    error: str | None = None
