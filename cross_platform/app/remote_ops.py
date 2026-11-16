"""Network git operations (clone, fetch, push, pull), via the `git` CLI.

This is the one place git access shells out instead of using pygit2. libgit2
doesn't use git's credential helpers or `~/.ssh/config`, so doing these
in-process would mean reimplementing credential prompting ourselves. The `git`
binary already knows how to authenticate. It's the copy bundled with the app
by default (which signs in over HTTPS through Git Credential Manager's own
window), or the user's own git if they choose it in Settings.

These run headless, so anything that would wait for a password or host-key
prompt in a terminal is told to fail immediately instead of hanging forever.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

from app import settings


class RemoteError(RuntimeError):
    pass


_HINTS = [
    (
        ("could not read Username", "terminal prompts disabled", "Authentication failed"),
        "Signing in didn't complete. Try again and finish signing in in the window that opens, or use "
        "an SSH remote URL. To use credentials your own git has already saved, choose that git in Settings.",
    ),
    (
        ("Host key verification failed",),
        "Connect to this host once with ssh in Terminal to accept its host key, then try again.",
    ),
    (
        ("Permission denied (publickey)",),
        "Your SSH key wasn't accepted. Make sure it's added to ssh-agent and to your account on the server.",
    ),
    (
        ("[rejected]", "fetch first", "non-fast-forward"),
        "The remote has commits you don't have yet. Pull them first, then push again.",
    ),
    (
        ("Not possible to fast-forward", "diverging branches"),
        "Your branch and the remote branch have both gained commits. Score files can't be merged "
        "automatically, so this needs to be resolved with git in a terminal.",
    ),
]


def _git_exe() -> str:
    return settings.path_for(settings.GIT) or "git"


def _run(args: list[str], cwd: Path, timeout: int = 300) -> str:
    exe = _git_exe()
    env = settings.child_env(exe)
    env["GIT_TERMINAL_PROMPT"] = "0"
    env.setdefault("GIT_SSH_COMMAND", "ssh -o BatchMode=yes")
    env["LC_ALL"] = "C"  # stable English messages, so _HINTS can match them
    try:
        result = subprocess.run(
            [exe, *args],
            cwd=str(cwd),
            env=env,
            creationflags=settings.CREATIONFLAGS,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except FileNotFoundError as e:
        raise RemoteError(
            "The git command-line tool wasn't found. Install it, or set its location on the "
            "Settings page (the gear icon in the toolbar)."
        ) from e
    except subprocess.TimeoutExpired as e:
        raise RemoteError(f"git {args[0]} timed out after {timeout}s.") from e
    if result.returncode != 0:
        message = (result.stderr or result.stdout).strip() or f"git {args[0]} failed"
        for needles, hint in _HINTS:
            if any(n in message for n in needles):
                message += f"\n\n{hint}"
                break
        raise RemoteError(message)
    return (result.stdout + result.stderr).strip()


def clone(url: str, dest: Path) -> Path:
    if dest.exists() and any(dest.iterdir()):
        raise RemoteError(f"{dest} already exists and isn't empty.")
    dest.parent.mkdir(parents=True, exist_ok=True)
    _run(["clone", "--", url, str(dest)], cwd=dest.parent, timeout=1800)
    return dest


def fetch(repo_path: Path, remote: str) -> None:
    _run(["fetch", "--prune", remote], cwd=repo_path)


def push(repo_path: Path, remote: str, branch: str, set_upstream: bool) -> None:
    args = ["push"]
    if set_upstream:
        args.append("--set-upstream")
    args += [remote, f"refs/heads/{branch}:refs/heads/{branch}"]
    _run(args, cwd=repo_path, timeout=1800)


def pull_ff_only(repo_path: Path) -> None:
    """Fast-forward only: .mscz files are zip archives, so a real merge would
    just conflict on every changed score with no way to resolve it here."""
    _run(["pull", "--ff-only"], cwd=repo_path, timeout=1800)


def repo_name_from_url(url: str) -> str:
    name = url.rstrip("/").rsplit("/", 1)[-1].rsplit(":", 1)[-1]
    return name.removesuffix(".git") or "repository"
