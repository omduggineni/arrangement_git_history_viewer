from __future__ import annotations

import hashlib
from pathlib import Path

from app import convert, git_ops


# Shared by every repo (each gets its own hashed subdirectory), so the UI can
# serve rendered SVGs for whichever repo is currently open from one route.
CACHE_BASE = Path.home() / ".cache" / "arrangement-diff-viewer"


def cache_root_for_repo(repo: Path) -> Path:
    repo_hash = hashlib.sha256(str(repo.resolve()).encode("utf-8")).hexdigest()[:16]
    root = CACHE_BASE / repo_hash
    root.mkdir(parents=True, exist_ok=True)
    return root


def ensure_musicxml(repo: Path, cache_root: Path, ref: str, path: str) -> tuple[str, Path]:
    """Return (blob_sha, musicxml_path) for the given file at the given ref,
    converting via MuseScore and caching the result if needed."""
    sha = git_ops.blob_sha(repo, ref, path)
    if sha is None:
        raise FileNotFoundError(f"{path} does not exist at {ref}")

    blobs_dir = cache_root / "blobs"
    blobs_dir.mkdir(parents=True, exist_ok=True)
    musicxml_path = blobs_dir / f"{sha}.musicxml"
    if musicxml_path.exists():
        return sha, musicxml_path

    suffix = Path(path).suffix or ".mscz"
    mscz_path = blobs_dir / f"{sha}{suffix}"
    if not mscz_path.exists():
        data = git_ops.blob_bytes(repo, ref, path)
        mscz_path.write_bytes(data)

    convert.mscz_to_musicxml(mscz_path, musicxml_path)
    return sha, musicxml_path


def ensure_pdf(repo: Path, cache_root: Path, ref: str, path: str) -> Path:
    """A PDF of the score at `ref`, rendered by MuseScore and cached by blob."""
    sha = git_ops.blob_sha(repo, ref, path)
    if sha is None:
        raise FileNotFoundError(f"{path} does not exist at {ref}")

    blobs_dir = cache_root / "blobs"
    blobs_dir.mkdir(parents=True, exist_ok=True)
    pdf_path = blobs_dir / f"{sha}.pdf"
    if pdf_path.exists():
        return pdf_path

    mscz_path = blobs_dir / f"{sha}{Path(path).suffix or '.mscz'}"
    if not mscz_path.exists():
        mscz_path.write_bytes(git_ops.blob_bytes(repo, ref, path))
    convert.mscz_to_pdf(mscz_path, pdf_path)
    return pdf_path


def diff_dir_for(cache_root: Path, sha1: str, sha2: str, detail: int) -> Path:
    d = cache_root / "diffs" / f"{sha1}__{sha2}__{detail}"
    d.mkdir(parents=True, exist_ok=True)
    return d


def diff_is_cached(diff_dir: Path) -> bool:
    return (diff_dir / "done.marker").exists()


def mark_diff_cached(diff_dir: Path) -> None:
    (diff_dir / "done.marker").write_text("ok")
