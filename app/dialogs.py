"""Modal dialogs and folder picking, shared by the welcome screen and the main
repository view. Every dialog here is awaitable and returns its result."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

from nicegui import app, run, ui

from app import git_ops, recent, remote_ops, session, theme

_MUSESCORE_GITIGNORE = """\
# MuseScore backups and autosaves
.mscbackup/
*.mscz~
*.mscz,
*.mscx~
.DS_Store
"""

native = False  # set by run_app: True when running in a pywebview window


# --- Folder picking ---------------------------------------------------------


def can_pick_folder() -> bool:
    return native or sys.platform == "darwin"


async def pick_folder(prompt: str, start: Path | None = None) -> Path | None:
    if native:
        import webview

        result = await app.native.main_window.create_file_dialog(
            webview.FileDialog.FOLDER, directory=str(start or "")
        )
        return Path(result[0]).resolve() if result else None
    if sys.platform == "darwin":
        # Web mode on a Mac: the server is still local, so osascript's native
        # "choose folder" dialog works. (This deliberately avoids tkinter,
        # which leaves a stray "tk" window on screen on macOS.)
        return await run.io_bound(_osascript_choose, "folder", prompt)
    return None


async def pick_file(prompt: str, start: Path | None = None) -> Path | None:
    # Not resolve()d: a symlink like /opt/homebrew/bin/mscore should stay a
    # symlink, so it keeps working after the thing it points to is upgraded.
    if native:
        import webview

        result = await app.native.main_window.create_file_dialog(webview.FileDialog.OPEN, directory=str(start or ""))
        return Path(result[0]) if result else None
    if sys.platform == "darwin":
        return await run.io_bound(_osascript_choose, "file", prompt)
    return None


def _osascript_choose(kind: str, prompt: str) -> Path | None:
    escaped = prompt.replace("\\", "\\\\").replace('"', '\\"')
    result = subprocess.run(
        ["osascript", "-e", f'POSIX path of (choose {kind} with prompt "{escaped}")'],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return None  # user cancelled
    path = Path(result.stdout.strip())
    return path.resolve() if kind == "folder" else path


def open_folder(path: Path) -> None:
    """Show `path` in the OS file manager (creating it first if it doesn't exist yet)."""
    path.mkdir(parents=True, exist_ok=True)
    try:
        if sys.platform == "darwin":
            subprocess.Popen(["open", str(path)])
        elif sys.platform == "win32":
            os.startfile(str(path))  # type: ignore[attr-defined]
        else:
            subprocess.Popen(["xdg-open", str(path)])
    except OSError as e:
        show_error("Couldn't open folder", str(e))


def default_location() -> Path:
    """Where new/cloned repos go by default: next to the most recently opened
    repo, else ~/Documents."""
    recents = recent.load()
    if recents:
        return recents[0].parent
    documents = Path.home() / "Documents"
    return documents if documents.is_dir() else Path.home()


# --- Building blocks --------------------------------------------------------


def _new_dialog() -> ui.dialog:
    # Always attach dialogs to the page root: a dialog created inside a menu's
    # click handler would otherwise be destroyed when the menu closes.
    with ui.context.client.layout:
        return ui.dialog()


def _title(text: str) -> None:
    ui.label(text).style(f"color:{theme.TEXT_PRIMARY}; font-size:1.125rem; font-weight:600")


def _help(text: str) -> ui.label:
    return ui.label(text).style(f"color:{theme.TEXT_SECONDARY}; font-size:0.85rem")


def _error_label() -> ui.label:
    return ui.label("").style(f"color:{theme.RED}; font-size:0.85rem; white-space:pre-wrap; font-family:monospace")


def _input(label: str, value: str = "", placeholder: str = "") -> ui.input:
    return ui.input(label, value=value, placeholder=placeholder).props("outlined dense").classes("w-full")


def _folder_input(label: str, value: Path) -> ui.input:
    field = _input(label, str(value))
    if can_pick_folder():

        async def browse() -> None:
            current = Path(field.value).expanduser()
            picked = await pick_folder("Choose a folder", current if current.is_dir() else None)
            if picked:
                field.set_value(str(picked))

        with field.add_slot("append"):
            ui.button(icon="folder_open", on_click=browse).props("flat round dense")
    return field


def _buttons(dialog: ui.dialog, confirm_label: str, on_confirm, danger: bool = False) -> ui.button:
    with ui.row().classes("w-full justify-end gap-2 mt-2"):
        ui.button("Cancel", on_click=lambda: dialog.submit(None)).props("flat no-caps")
        return ui.button(confirm_label, on_click=on_confirm).props(
            f"unelevated no-caps color={'negative' if danger else 'primary'}"
        )


async def _run_dialog(dialog: ui.dialog):
    result = await dialog
    dialog.delete()
    return result


# --- Simple dialogs ---------------------------------------------------------


def show_error(title: str, message: str) -> None:
    dialog = _new_dialog()
    with dialog, ui.card().style("min-width:480px; max-width:720px"):
        _title(title)
        ui.label(message).style(
            f"color:{theme.TEXT_PRIMARY}; white-space:pre-wrap; font-family:monospace; font-size:0.8rem; "
            f"background:{theme.BG_CHROME}; padding:12px; border-radius:6px; max-height:50vh; overflow:auto; width:100%"
        )
        with ui.row().classes("w-full justify-end"):
            ui.button("OK", on_click=dialog.close).props("unelevated no-caps")
    dialog.on("hide", dialog.delete)
    dialog.open()


async def confirm(title: str, message: str, confirm_label: str, danger: bool = False) -> bool:
    dialog = _new_dialog()
    with dialog, ui.card().style("min-width:420px; max-width:600px"):
        _title(title)
        _help(message).style("white-space:pre-wrap")
        _buttons(dialog, confirm_label, lambda: dialog.submit(True), danger=danger)
    return bool(await _run_dialog(dialog))


# --- Opening, creating, and cloning repositories ----------------------------


def switch_to_repo(path: Path) -> None:
    try:
        session.open_repo(path)
    except git_ops.GitError as e:
        show_error("Can't open repository", str(e))
        return
    ui.navigate.reload()


async def open_repository() -> None:
    """Pick a folder; open it if it's a repo, else offer to make it one."""
    if can_pick_folder():
        path = await pick_folder("Choose a repository folder (or a folder of scores to turn into one)")
    else:
        path = await _typed_path_dialog()
    if path is None:
        return
    if not path.is_dir():
        show_error("Folder not found", str(path))
        return
    if git_ops.is_git_repo(path):
        switch_to_repo(path)
        return
    if await confirm(
        "Not a git repository",
        f"{path}\n\nisn't a git repository yet. Create one here? Any scores already in the folder "
        "will show up as new changes, ready for a first commit.",
        "Create repository",
    ):
        try:
            await run.io_bound(_create_repo, path, True)
        except Exception as e:  # noqa: BLE001
            show_error("Couldn't create repository", str(e))
            return
        switch_to_repo(path)


async def _typed_path_dialog() -> Path | None:
    dialog = _new_dialog()
    with dialog, ui.card().style("min-width:520px"):
        _title("Open repository")
        field = _input("Folder path", placeholder="/path/to/your/scores")
        _buttons(dialog, "Open", lambda: dialog.submit(Path(field.value).expanduser().resolve()) if field.value.strip() else None)
    return await _run_dialog(dialog)


def _create_repo(path: Path, add_gitignore: bool) -> None:
    git_ops.init_repo(path)
    gitignore = path / ".gitignore"
    if add_gitignore and not gitignore.exists():
        gitignore.write_text(_MUSESCORE_GITIGNORE)


async def create_repository() -> None:
    dialog = _new_dialog()
    with dialog, ui.card().style("min-width:520px"):
        _title("Create a new repository")
        name = _input("Name", placeholder="my-arrangement")
        location = _folder_input("Location", default_location())
        target = _help("")
        ignore = ui.checkbox("Ignore MuseScore backup files (adds a .gitignore)", value=True)
        error = _error_label()

        def update_target() -> None:
            n = name.value.strip()
            target.set_text(f"Will be created at {Path(location.value).expanduser() / n}" if n else "")

        name.on_value_change(update_target)
        location.on_value_change(update_target)

        async def submit() -> None:
            n = name.value.strip()
            if not n:
                error.set_text("Enter a name for the repository.")
                return
            path = (Path(location.value).expanduser() / n).resolve()
            if (path / ".git").exists():
                error.set_text(f"{path} is already a git repository -- use Open instead.")
                return
            try:
                await run.io_bound(_create_repo, path, ignore.value)
            except Exception as e:  # noqa: BLE001
                error.set_text(str(e))
                return
            dialog.submit(path)

        _buttons(dialog, "Create repository", submit)
    path = await _run_dialog(dialog)
    if path:
        switch_to_repo(path)


async def clone_repository() -> None:
    dialog = _new_dialog()
    with dialog, ui.card().style("min-width:560px"):
        _title("Clone a repository")
        url = _input("Repository URL", placeholder="https://github.com/you/scores.git  or  git@github.com:you/scores.git")
        location = _folder_input("Location", default_location())
        target = _help("")
        error = _error_label()
        spinner_row = ui.row().classes("items-center gap-2")
        with spinner_row:
            ui.spinner(size="sm")
            _help("Cloning… this can take a while for large repositories.")
        spinner_row.set_visibility(False)

        def target_path() -> Path | None:
            u = url.value.strip()
            return (Path(location.value).expanduser() / remote_ops.repo_name_from_url(u)).resolve() if u else None

        def update_target() -> None:
            p = target_path()
            target.set_text(f"Will be cloned into {p}" if p else "")

        url.on_value_change(update_target)
        location.on_value_change(update_target)

        async def submit() -> None:
            dest = target_path()
            if dest is None:
                error.set_text("Enter the URL of the repository to clone.")
                return
            error.set_text("")
            confirm_btn.disable()
            spinner_row.set_visibility(True)
            try:
                await run.io_bound(remote_ops.clone, url.value.strip(), dest)
            except remote_ops.RemoteError as e:
                error.set_text(str(e))
                return
            finally:
                confirm_btn.enable()
                spinner_row.set_visibility(False)
            dialog.submit(dest)

        confirm_btn = _buttons(dialog, "Clone", submit)
    path = await _run_dialog(dialog)
    if path:
        switch_to_repo(path)


# --- Dialogs for the open repository ----------------------------------------


async def identity_dialog() -> bool:
    """Ask for user.name / user.email, which git needs before committing."""
    dialog = _new_dialog()
    with dialog, ui.card().style("min-width:480px"):
        _title("Who's committing?")
        _help("Git records a name and email address with every commit. This is only stored in your git settings.")
        name = _input("Name")
        email = _input("Email")
        everywhere = ui.checkbox("Use for all repositories on this computer", value=True)
        error = _error_label()

        async def submit() -> None:
            if not name.value.strip() or not email.value.strip():
                error.set_text("Both a name and an email are required.")
                return
            try:
                await run.io_bound(git_ops.set_identity, session.repo, name.value.strip(), email.value.strip(), everywhere.value)
            except Exception as e:  # noqa: BLE001
                error.set_text(str(e))
                return
            dialog.submit(True)

        _buttons(dialog, "Save", submit)
    return bool(await _run_dialog(dialog))


async def remote_dialog(publishing: bool) -> str | None:
    """View/set the URL of the repo's main remote. Returns the remote name
    once one is configured, or None if cancelled."""
    remotes = git_ops.list_remotes(session.repo)
    remote_name = git_ops.default_remote(session.repo) or "origin"
    dialog = _new_dialog()
    with dialog, ui.card().style("min-width:560px"):
        _title("Publish repository" if publishing else "Remote repository")
        _help(
            "To share this repository or back it up online, create an empty repository on GitHub, GitLab, "
            "or similar, then paste its URL here."
        )
        url = _input(f"URL for “{remote_name}”", value=remotes.get(remote_name, ""), placeholder="https://github.com/you/scores.git")
        error = _error_label()

        async def submit() -> None:
            u = url.value.strip()
            if not u:
                error.set_text("Enter the remote repository's URL.")
                return
            try:
                git_ops.set_remote(session.repo, remote_name, u)
            except Exception as e:  # noqa: BLE001
                error.set_text(str(e))
                return
            dialog.submit(remote_name)

        _buttons(dialog, "Publish" if publishing else "Save", submit)
    return await _run_dialog(dialog)


async def new_branch_dialog() -> str | None:
    dialog = _new_dialog()
    with dialog, ui.card().style("min-width:440px"):
        _title("Create a branch")
        current = git_ops.current_branch_name(session.repo)
        _help(f"Based on “{current}”. Any uncommitted changes come along to the new branch.")
        name = _input("Name", placeholder="e.g. strings-revision")
        error = _error_label()

        async def submit() -> None:
            async with session.write_lock:
                try:
                    await run.io_bound(git_ops.create_branch, session.repo, name.value)
                except git_ops.GitError as e:
                    error.set_text(str(e))
                    return
            dialog.submit(name.value.strip())

        name.on("keydown.enter", submit)
        _buttons(dialog, "Create branch", submit)
    return await _run_dialog(dialog)
