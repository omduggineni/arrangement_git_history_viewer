from __future__ import annotations

import hashlib
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pygit2

from app.models import WORKING_TREE_REF, BranchInfo, ChangedFile, CommitInfo, ScoreFile, SyncStatus

# All local git access goes through pygit2 (libgit2 bindings, in-process)
# rather than shelling out to the `git` binary. Network operations (fetch,
# push, pull, clone) are the exception -- see app/remote_ops.py for why.

_UNTRACKED = pygit2.GIT_STATUS_WT_NEW
_CHANGED = (
    pygit2.GIT_STATUS_WT_MODIFIED
    | pygit2.GIT_STATUS_WT_DELETED
    | pygit2.GIT_STATUS_WT_TYPECHANGE
    | pygit2.GIT_STATUS_WT_RENAMED
    | pygit2.GIT_STATUS_INDEX_NEW
    | pygit2.GIT_STATUS_INDEX_MODIFIED
    | pygit2.GIT_STATUS_INDEX_DELETED
    | pygit2.GIT_STATUS_INDEX_RENAMED
    | pygit2.GIT_STATUS_INDEX_TYPECHANGE
)


class GitError(RuntimeError):
    pass


def open_repo(path: Path) -> pygit2.Repository:
    repo_path = pygit2.discover_repository(str(path))
    if repo_path is None:
        raise GitError(f"{path} is not inside a git repository")
    repo = pygit2.Repository(repo_path)
    if repo.is_bare:
        raise GitError(f"{path} is a bare repository (it has no working folder of files to show)")
    return repo


def init_repo(path: Path) -> pygit2.Repository:
    """Create a new repo at `path` (creating the folder if needed), on a
    branch named "main". Initializing inside an existing folder of scores is
    fine -- the files just show up as new, uncommitted changes."""
    path.mkdir(parents=True, exist_ok=True)
    return pygit2.init_repository(str(path), initial_head="main")


def is_git_repo(path: Path) -> bool:
    try:
        open_repo(path)
        return True
    except GitError:
        return False


def list_score_files(repo: pygit2.Repository) -> list[ScoreFile]:
    files: dict[str, str] = {}

    if not repo.is_empty and not repo.head_is_unborn:
        for entry in repo.index:
            if entry.path.endswith(".mscz"):
                files[entry.path] = "clean"

    for path, flags in repo.status().items():
        if not path.endswith(".mscz"):
            continue
        if flags & _UNTRACKED:
            files[path] = "untracked"
        elif flags & _CHANGED:
            files[path] = "modified"

    return [ScoreFile(path=p, status=s) for p, s in sorted(files.items())]


def list_repo_files(repo: pygit2.Repository) -> list[str]:
    """Every file currently in the working tree (tracked or not, excluding ignored)."""
    paths: set[str] = set()
    if not repo.is_empty:
        paths.update(e.path for e in repo.index)
    for path, flags in repo.status().items():
        if flags & pygit2.GIT_STATUS_IGNORED:
            continue
        paths.add(path)
    return sorted(p for p in paths if _exists_in_workdir(repo, p))


def log_for_file(repo: pygit2.Repository, path: str, max_count: int = 200) -> list[CommitInfo]:
    """History of commits that changed `path`, newest first.

    This does not follow renames (libgit2 has no built-in equivalent of
    `git log --follow`); a commit is included whenever the blob at `path`
    differs from the same path in its first parent.
    """
    if repo.is_empty or repo.head_is_unborn:
        return []

    commits: list[CommitInfo] = []
    for commit in repo.walk(repo.head.target, pygit2.GIT_SORT_TOPOLOGICAL | pygit2.GIT_SORT_TIME):
        blob_id = _blob_id_at(commit, path)
        parent_blob_id = _blob_id_at(commit.parents[0], path) if commit.parents else None
        if blob_id != parent_blob_id:
            commits.append(_to_commit_info(commit))
        if len(commits) >= max_count:
            break
    return commits


def list_all_commits(repo: pygit2.Repository, max_count: int = 300) -> list[CommitInfo]:
    """Full repo commit history, newest first (like GitHub Desktop's History tab)."""
    if repo.is_empty or repo.head_is_unborn:
        return []
    commits = []
    for commit in repo.walk(repo.head.target, pygit2.GIT_SORT_TOPOLOGICAL | pygit2.GIT_SORT_TIME):
        commits.append(_to_commit_info(commit))
        if len(commits) >= max_count:
            break
    return commits


def changed_mscz_files_in_commit(repo: pygit2.Repository, sha: str) -> list[str]:
    """.mscz paths added/modified/deleted by `sha`, relative to its first parent
    (or to the empty tree, for a root commit)."""
    commit = repo.revparse_single(sha)
    parent = commit.parents[0] if commit.parents else None
    diff = repo.diff(parent, commit) if parent is not None else commit.tree.diff_to_tree(swap=True)
    paths: set[str] = set()
    for delta in diff.deltas:
        for path in (delta.old_file.path, delta.new_file.path):
            if path and path.endswith(".mscz"):
                paths.add(path)
    return sorted(paths)


def parent_sha(repo: pygit2.Repository, sha: str) -> str | None:
    commit = repo.revparse_single(sha)
    return str(commit.parents[0].id) if commit.parents else None


def _blob_id_at(commit: pygit2.Commit, path: str):
    try:
        return commit.tree[path].id
    except KeyError:
        return None


def _to_commit_info(commit: pygit2.Commit) -> CommitInfo:
    sha = str(commit.id)
    tz = timezone(timedelta(minutes=commit.author.offset))
    dt = datetime.fromtimestamp(commit.author.time, tz=tz)
    subject = commit.message.splitlines()[0] if commit.message else ""
    return CommitInfo(sha=sha, short_sha=sha[:8], author=commit.author.name, date=dt.strftime("%Y-%m-%d"), subject=subject)


def _git_blob_hash(data: bytes) -> str:
    header = f"blob {len(data)}\0".encode()
    return hashlib.sha1(header + data).hexdigest()


def blob_sha(repo: pygit2.Repository, ref: str, path: str) -> str | None:
    if ref == WORKING_TREE_REF:
        full = Path(repo.workdir) / path
        if not full.exists():
            return None
        return _git_blob_hash(full.read_bytes())
    try:
        commit = repo.revparse_single(ref)
        return str(commit.tree[path].id)
    except (KeyError, ValueError):
        return None


def blob_bytes(repo: pygit2.Repository, ref: str, path: str) -> bytes:
    if ref == WORKING_TREE_REF:
        return (Path(repo.workdir) / path).read_bytes()
    commit = repo.revparse_single(ref)
    entry = commit.tree[path]
    return repo[entry.id].data


# --- Uncommitted changes and committing -------------------------------------

_STAGED = (
    pygit2.GIT_STATUS_INDEX_NEW
    | pygit2.GIT_STATUS_INDEX_MODIFIED
    | pygit2.GIT_STATUS_INDEX_DELETED
    | pygit2.GIT_STATUS_INDEX_RENAMED
    | pygit2.GIT_STATUS_INDEX_TYPECHANGE
)


def _head_tree(repo: pygit2.Repository) -> pygit2.Tree | None:
    if repo.head_is_unborn:
        return None
    return repo.head.peel(pygit2.Commit).tree


def _in_tree(tree: pygit2.Tree | None, path: str) -> bool:
    if tree is None:
        return False
    try:
        tree[path]
        return True
    except KeyError:
        return False


def _exists_in_workdir(repo: pygit2.Repository, path: str) -> bool:
    full = Path(repo.workdir) / path
    return full.exists() or full.is_symlink()


def list_changes(repo: pygit2.Repository) -> list[ChangedFile]:
    """Every file whose working-tree content differs from HEAD, of any type.

    Like GitHub Desktop, this deliberately flattens git's staged/unstaged
    distinction: each file is simply new, modified, or deleted relative to the
    last commit, and the user picks which ones go into the next commit.
    """
    head_tree = _head_tree(repo)
    changes = []
    for path, flags in repo.status().items():
        if flags & pygit2.GIT_STATUS_IGNORED:
            continue
        in_head = _in_tree(head_tree, path)
        if not _exists_in_workdir(repo, path):
            if not in_head:
                continue  # staged as new, then deleted again: nothing to commit
            status = "deleted"
        elif not in_head:
            status = "new"
        else:
            status = "modified"
        changes.append(ChangedFile(path=path, status=status))
    return sorted(changes, key=lambda c: c.path)


def get_signature(repo: pygit2.Repository) -> pygit2.Signature | None:
    """The configured user.name/user.email, or None if git doesn't know who
    the user is yet (common on a fresh machine)."""
    try:
        return repo.default_signature
    except (KeyError, pygit2.GitError):
        return None


def set_identity(repo: pygit2.Repository, name: str, email: str, global_: bool) -> None:
    if global_:
        try:
            config = pygit2.Config.get_global_config()
        except (OSError, pygit2.GitError):
            # No global config file exists yet; create the conventional one.
            gitconfig = Path.home() / ".gitconfig"
            gitconfig.touch()
            config = pygit2.Config(str(gitconfig))
    else:
        config = repo.config
    config["user.name"] = name
    config["user.email"] = email


def commit_paths(repo: pygit2.Repository, paths: list[str], message: str) -> str:
    """Commit exactly `paths` (new, modified, or deleted) and nothing else,
    returning the new commit's sha. Anything that was staged by some other
    tool but isn't in `paths` is reset back to HEAD in the index first, so it
    doesn't silently ride along."""
    signature = get_signature(repo)
    if signature is None:
        raise GitError("No git identity configured (user.name / user.email).")
    if not paths:
        raise GitError("No files selected to commit.")

    index = repo.index
    index.read()
    head_tree = _head_tree(repo)
    selected = set(paths)

    for path, flags in repo.status().items():
        if path in selected or not flags & _STAGED:
            continue
        if _in_tree(head_tree, path):
            entry = head_tree[path]
            index.add(pygit2.IndexEntry(path, entry.id, entry.filemode))
        else:
            _index_remove(index, path)

    for path in selected:
        if _exists_in_workdir(repo, path):
            index.add(path)
        else:
            _index_remove(index, path)

    tree_id = index.write_tree()
    if head_tree is not None and tree_id == head_tree.id:
        raise GitError("The selected files have no changes to commit.")
    index.write()

    parents = [] if repo.head_is_unborn else [repo.head.target]
    commit_id = repo.create_commit("HEAD", signature, signature, message, tree_id, parents)
    return str(commit_id)


def discard_changes(repo: pygit2.Repository, paths: list[str]) -> None:
    """Throw away uncommitted changes to `paths`: restore them to their HEAD
    version, or delete them if they're new since HEAD. Irreversible."""
    head_tree = _head_tree(repo)
    index = repo.index
    index.read()
    tracked = [p for p in paths if _in_tree(head_tree, p)]
    for path in paths:
        if path in tracked:
            continue
        _index_remove(index, path)
        full = Path(repo.workdir) / path
        if full.exists() or full.is_symlink():
            full.unlink()
    index.write()
    if tracked:
        # Without DISABLE_PATHSPEC_MATCH, libgit2 treats `paths` as glob
        # patterns: discarding "Song [v2].mscz" would also clobber "Song v.mscz".
        repo.checkout_head(
            strategy=pygit2.enums.CheckoutStrategy.FORCE | pygit2.enums.CheckoutStrategy.DISABLE_PATHSPEC_MATCH,
            paths=tracked,
        )


def _index_remove(index: pygit2.Index, path: str) -> None:
    try:
        index.remove(path)
    except (KeyError, OSError, pygit2.GitError):
        pass  # wasn't in the index to begin with


# --- Branches and remotes ---------------------------------------------------


def current_branch_name(repo: pygit2.Repository) -> str:
    if repo.head_is_detached:
        return str(repo.head.target)[:8]
    # Works even when HEAD is unborn (a brand-new repo with no commits yet).
    return repo.references["HEAD"].target.removeprefix("refs/heads/")


def list_branches(repo: pygit2.Repository) -> list[BranchInfo]:
    """Local branches, followed by remote branches that don't have a local
    branch of the same name yet (selecting one of those creates it)."""
    current = current_branch_name(repo)
    local_names = sorted(repo.branches.local)
    branches = [BranchInfo(name=n, is_remote=False, is_current=n == current) for n in local_names]
    for name in sorted(repo.branches.remote):
        if name.endswith("/HEAD"):
            continue
        remote_name = repo.branches.remote[name].remote_name
        short = name.removeprefix(remote_name + "/")
        if short not in local_names:
            branches.append(BranchInfo(name=name, is_remote=True, is_current=False))
    if repo.head_is_unborn and current not in local_names:
        branches.insert(0, BranchInfo(name=current, is_remote=False, is_current=True))
    return branches


def create_branch(repo: pygit2.Repository, name: str) -> None:
    """Create a branch at the current commit and switch to it. Uncommitted
    changes are carried over to the new branch, as with `git switch -c`."""
    name = name.strip()
    if not name or not pygit2.reference_is_valid_name(f"refs/heads/{name}"):
        raise GitError(f"'{name}' is not a valid branch name.")
    if name in repo.branches.local:
        raise GitError(f"A branch named '{name}' already exists.")
    if repo.head_is_unborn:
        # Nothing to branch from yet; just rename the branch-to-be.
        repo.set_head(f"refs/heads/{name}")
        return
    repo.branches.local.create(name, repo.head.peel(pygit2.Commit))
    repo.set_head(f"refs/heads/{name}")


def checkout_branch(repo: pygit2.Repository, branch: BranchInfo) -> None:
    """Switch to `branch`, creating a local tracking branch first if it's a
    remote-only one. Uses libgit2's default safe checkout, which refuses
    (rather than clobbering) if uncommitted changes would be overwritten."""
    if branch.is_remote:
        remote_branch = repo.branches.remote[branch.name]
        local_name = branch.name.removeprefix(remote_branch.remote_name + "/")
        local = repo.branches.local.create(local_name, remote_branch.peel(pygit2.Commit))
        local.upstream = remote_branch
    else:
        local_name = branch.name
        local = repo.branches.local[local_name]
    if repo.head_is_unborn:
        repo.set_head(local.name)
        return
    try:
        repo.checkout(local)
    except pygit2.GitError as e:
        raise GitError(
            f"Can't switch to '{local_name}': {e}. Commit or discard your changes to the conflicting files first."
        ) from e


def list_remotes(repo: pygit2.Repository) -> dict[str, str]:
    return {r.name: r.url for r in repo.remotes}


def set_remote(repo: pygit2.Repository, name: str, url: str) -> None:
    if name in list_remotes(repo):
        repo.remotes.set_url(name, url)
    else:
        repo.remotes.create(name, url)


def default_remote(repo: pygit2.Repository) -> str | None:
    """The remote to publish/fetch from: the current branch's upstream remote,
    else 'origin', else whichever remote exists."""
    remotes = list_remotes(repo)
    if not remotes:
        return None
    if not repo.head_is_unborn and not repo.head_is_detached:
        local = repo.branches.local.get(current_branch_name(repo))
        upstream = _upstream(local) if local else None
        if upstream is not None:
            return upstream.remote_name
    return "origin" if "origin" in remotes else sorted(remotes)[0]


def _upstream(branch: pygit2.Branch) -> pygit2.Branch | None:
    try:
        return branch.upstream
    except (KeyError, pygit2.GitError):
        return None  # upstream configured, but its remote ref is gone


def sync_status(repo: pygit2.Repository) -> SyncStatus:
    branch = current_branch_name(repo)
    has_remote = bool(list_remotes(repo))
    if repo.head_is_unborn or repo.head_is_detached:
        return SyncStatus(branch=branch, is_unborn=repo.head_is_unborn, has_remote=has_remote, upstream=None)
    local = repo.branches.local.get(branch)
    upstream = _upstream(local) if local else None
    if upstream is None:
        return SyncStatus(branch=branch, is_unborn=False, has_remote=has_remote, upstream=None)
    ahead, behind = repo.ahead_behind(local.target, upstream.target)
    return SyncStatus(branch=branch, is_unborn=False, has_remote=has_remote, upstream=upstream.shorthand, ahead=ahead, behind=behind)
