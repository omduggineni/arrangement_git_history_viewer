from __future__ import annotations

import argparse
import html
import subprocess
import sys
from pathlib import Path

from nicegui import app, background_tasks, run, ui

from app import cache, dialogs, diffing, git_ops, recent, remote_ops, session, theme
from app.models import WORKING_TREE_REF, BranchInfo, CommitInfo, SyncStatus

_CHANGE_STYLE = {  # status -> (letter, color, tooltip)
    "new": ("+", theme.GREEN, "New file"),
    "modified": ("M", theme.YELLOW, "Modified"),
    "deleted": ("−", theme.RED, "Deleted"),
}
_DIFF_TEXT_COLORS = {
    "meta": theme.TEXT_SECONDARY,
    "add": theme.GREEN,
    "remove": theme.RED,
    "hunk": theme.PURPLE,
}
_HEADER_HEIGHT = 56
# How often to re-check the working tree, so edits saved from MuseScore (or
# commits made in a terminal) show up without a manual refresh.
_POLL_SECONDS = 3.0


def _parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Diff viewer for MuseScore files in a git repo.")
    parser.add_argument("--repo", type=str, default=None, help="Path to the git repo containing .mscz files. If omitted, the most recently opened repo (or a welcome screen) is shown.")
    parser.add_argument("--port", type=int, default=None, help="default: 8080 in --web mode, an open port in native mode")
    parser.add_argument("--host", type=str, default=None, help="default: 0.0.0.0 in --web mode, 127.0.0.1 in native mode")
    parser.add_argument("--web", action="store_true", help="Run as an ordinary local web server in a browser tab instead of a native app window.")
    return parser.parse_args(argv)


def _commit_subtitle(c: CommitInfo) -> str:
    return f"{c.author} committed on {c.date}"


def _svg_url(path: Path) -> str:
    rel = path.relative_to(cache.CACHE_BASE)
    return "/cache/" + "/".join(rel.parts)


def _score_card(svg_path: Path | None) -> None:
    """A score excerpt sits on a deliberate white 'paper' card against the
    dark UI -- normal for sheet music -- or, if this version doesn't have
    this excerpt, a dashed placeholder of the same shape."""
    if svg_path is not None:
        with ui.element("div").style(f"background:#ffffff; border:1px solid {theme.BORDER}; border-radius:6px; padding:12px; width:100%"):
            ui.image(_svg_url(svg_path)).classes("w-full")
    else:
        with ui.element("div").style(
            f"border:1px dashed {theme.BORDER}; border-radius:6px; padding:24px; width:100%; "
            "display:flex; align-items:center; justify-content:center; min-height:80px"
        ):
            ui.label("Not present at this version.").style(f"color:{theme.TEXT_MUTED}; font-size:0.875rem")


def _colorize_diff_text(text: str) -> str:
    lines = []
    for line in text.splitlines():
        escaped = html.escape(line)
        if line.startswith("+++") or line.startswith("---"):
            style = f"color:{_DIFF_TEXT_COLORS['meta']}"
        elif line.startswith("+"):
            style = f"color:{_DIFF_TEXT_COLORS['add']}"
        elif line.startswith("-"):
            style = f"color:{_DIFF_TEXT_COLORS['remove']}"
        elif line.startswith("@@"):
            style = f"color:{_DIFF_TEXT_COLORS['hunk']};font-weight:bold"
        else:
            style = f"color:{theme.TEXT_PRIMARY}"
        lines.append(f'<span style="{style}">{escaped}</span>')
    return "<br>".join(lines)


def _toolbar_button(icon: str, caption: str, value: str, width: int = 240) -> ui.button:
    """A GitHub Desktop-style header button: small caption over a bold value."""
    btn = ui.button().props("flat no-caps align=left").style(
        f"width:{width}px; height:{_HEADER_HEIGHT}px; border-right:1px solid {theme.BORDER}; border-radius:0; color:{theme.TEXT_PRIMARY}"
    )
    with btn:
        with ui.row().classes("items-center no-wrap gap-3 w-full"):
            ui.icon(icon).style(f"color:{theme.TEXT_SECONDARY}")
            with ui.column().classes("gap-0 items-start min-w-0 flex-grow"):
                ui.label(caption).style(f"color:{theme.TEXT_SECONDARY}; font-size:0.7rem; line-height:1.1")
                ui.label(value).classes("truncate w-full text-left").style(
                    f"color:{theme.TEXT_PRIMARY}; font-weight:600; font-size:0.875rem; line-height:1.3"
                )
    return btn


def _base_page() -> None:
    ui.dark_mode(True)  # so NiceGUI's own components (tabs, spinner, buttons) match our palette too
    ui.query("body").style(f"margin:0; background:{theme.BG_SURFACE}")
    ui.query(".nicegui-content").classes("p-0")  # panes are sized to exactly fill the window


@ui.page("/")
async def index() -> None:
    _base_page()
    if session.repo is None:
        _welcome_page()
    else:
        await _repo_page()


# --- Welcome screen (no repository open) ------------------------------------


def _welcome_page() -> None:
    with ui.column().classes("w-full items-center").style("padding:64px 16px"):
        with ui.column().classes("gap-6").style("width:100%; max-width:640px"):
            with ui.column().classes("gap-1"):
                ui.label("Arrangement Diff Viewer").style(f"color:{theme.TEXT_PRIMARY}; font-size:1.75rem; font-weight:600")
                ui.label("Track versions of your MuseScore arrangements with git, and see exactly what changed in the notation.").style(
                    f"color:{theme.TEXT_SECONDARY}"
                )

            with ui.row().classes("w-full gap-3 no-wrap items-stretch"):
                for icon, title, subtitle, handler in [
                    ("folder_open", "Open a folder", "An existing repository, or a folder of scores", dialogs.open_repository),
                    ("create_new_folder", "Create new", "Start a new, empty repository", dialogs.create_repository),
                    ("cloud_download", "Clone", "Copy a repository from GitHub etc.", dialogs.clone_repository),
                ]:
                    with ui.card().classes("flex-1 cursor-pointer gap-1").style(
                        f"background:{theme.BG_CHROME}; border:1px solid {theme.BORDER}; box-shadow:none"
                    ).on("click", handler):
                        ui.icon(icon, size="md").style(f"color:{theme.ACCENT}")
                        ui.label(title).style(f"color:{theme.TEXT_PRIMARY}; font-weight:600")
                        ui.label(subtitle).style(f"color:{theme.TEXT_SECONDARY}; font-size:0.8rem")

            recents = recent.load()
            if recents:
                ui.label("RECENT").style(f"color:{theme.TEXT_MUTED}; font-size:0.75rem; letter-spacing:0.05em; margin-bottom:-12px")
                with ui.column().classes("w-full gap-0").style(f"border:1px solid {theme.BORDER}; border-radius:6px; overflow:hidden"):
                    for path in recents:
                        _recent_row(path)

            if not dialogs.can_pick_folder():
                ui.label("Tip: run with --repo /path/to/repo to open a repository directly.").style(f"color:{theme.TEXT_MUTED}; font-size:0.8rem")


def _recent_row(path: Path) -> None:
    row = ui.row().classes("w-full items-center no-wrap gap-3 cursor-pointer px-4 py-2").style(f"border-bottom:1px solid {theme.BORDER}")
    with row:
        ui.icon("folder").style(f"color:{theme.TEXT_SECONDARY}")
        with ui.column().classes("gap-0 min-w-0 flex-grow").on("click", lambda: dialogs.switch_to_repo(path)):
            ui.label(path.name).style(f"color:{theme.TEXT_PRIMARY}; font-weight:500")
            ui.label(str(path)).classes("truncate w-full").style(f"color:{theme.TEXT_MUTED}; font-size:0.75rem")

        def forget() -> None:
            recent.remove(path)
            row.delete()

        ui.button(icon="close", on_click=forget).props("flat round dense size=sm").style(f"color:{theme.TEXT_MUTED}").tooltip("Remove from list")


# --- Repository view --------------------------------------------------------


async def _repo_page() -> None:
    repo = session.repo
    state: dict = {
        "mode": "changes",
        "changed_files": [],
        "excluded": set(),  # changed paths the user unchecked for the next commit
        "commits": [],
        "head": None,  # HEAD commit sha, to notice new commits (from us or elsewhere)
        "sync": git_ops.sync_status(repo),
        "busy": None,  # label of an in-flight network operation, e.g. "Pushing"
        "committing": False,
        "selected_file": None,
        "selected_commit": None,
        "commit_files": [],
        "selected_commit_file": None,
    }

    # -- Header: repository / branch / sync ---------------------------------

    @ui.refreshable
    def header_bar() -> None:
        sync: SyncStatus = state["sync"]
        with _toolbar_button("folder", "Current repository", session.repo_path.name, width=260):
            with ui.menu().props("auto-close").style(f"min-width:260px; background:{theme.BG_CHROME}"):
                others = [p for p in recent.load() if p != session.repo_path]
                for path in others[:8]:
                    ui.menu_item(path.name, on_click=lambda p=path: dialogs.switch_to_repo(p))
                if others:
                    ui.separator()
                ui.menu_item("Open folder…", on_click=dialogs.open_repository)
                ui.menu_item("Create new repository…", on_click=dialogs.create_repository)
                ui.menu_item("Clone repository…", on_click=dialogs.clone_repository)
                ui.separator()
                ui.menu_item("Remote settings…", on_click=edit_remote)
                if sys.platform == "darwin":
                    ui.menu_item("Show in Finder", on_click=lambda: subprocess.run(["open", str(session.repo_path)]))
                ui.menu_item("Close repository", on_click=close_repository)

        with _toolbar_button("call_split", "Current branch", sync.branch, width=240):
            with ui.menu().props("auto-close").style(f"min-width:240px; background:{theme.BG_CHROME}"):
                branches = git_ops.list_branches(repo)
                for b in branches:
                    with ui.menu_item(on_click=lambda b=b: switch_branch(b)).classes("items-center gap-2"):
                        ui.icon("check" if b.is_current else ("cloud" if b.is_remote else "")).style("width:20px")
                        ui.label(b.name)
                ui.separator()
                ui.menu_item("New branch…", on_click=new_branch)

        sync_button(sync)
        ui.space()
        ui.button(icon="refresh", on_click=lambda: refresh_all(rerender_selection=True)).props("flat round").style(
            f"color:{theme.TEXT_SECONDARY}; margin-right:8px"
        ).tooltip("Refresh")

    def sync_button(sync: SyncStatus) -> None:
        if state["busy"]:
            with _toolbar_button("sync", state["busy"] + "…", "Please wait") as btn:
                ui.spinner(size="sm").style("position:absolute; right:16px")
            btn.disable()
            return
        remote = git_ops.default_remote(repo) or "origin"
        if sync.is_unborn:
            btn = _toolbar_button("cloud_upload", "Publish repository", "Commit something first")
            btn.disable()
        elif not sync.has_remote:
            _toolbar_button("cloud_upload", "Publish repository", "Not on any server yet").on("click", publish_repository)
        elif sync.upstream is None:
            _toolbar_button("cloud_upload", "Publish branch", f"Push to {remote}").on("click", lambda: push(set_upstream=True))
        elif sync.ahead and sync.behind:
            _toolbar_button("warning", f"Diverged from {sync.upstream}", f"↑{sync.ahead} ↓{sync.behind}").on("click", explain_divergence)
        elif sync.behind:
            _toolbar_button("cloud_download", f"Pull {remote}", f"↓ {sync.behind} new commit{'s' if sync.behind != 1 else ''}").on("click", pull)
        elif sync.ahead:
            _toolbar_button("cloud_upload", f"Push {remote}", f"↑ {sync.ahead} commit{'s' if sync.ahead != 1 else ''}").on("click", lambda: push(set_upstream=False))
        else:
            _toolbar_button("sync", f"Fetch {remote}", "Check for new commits").on("click", fetch)

    # -- Body: left sidebar / middle (commit files) / right (diff) ----------

    with ui.row().classes("w-full no-wrap gap-0").style(f"height: calc(100vh - {_HEADER_HEIGHT}px)"):
        with ui.column().classes("h-full gap-0 no-wrap").style(
            f"width:300px; min-width:300px; background:{theme.BG_SURFACE}; border-right:1px solid {theme.BORDER}; padding:0"
        ):
            tabs_box = ui.element("div").classes("w-full")
            list_box = ui.column().classes("w-full gap-0 no-wrap overflow-y-auto").style("flex:1 1 auto; min-height:0")
            commit_box = ui.column().classes("w-full gap-2").style(f"border-top:1px solid {theme.BORDER}; padding:12px; background:{theme.BG_CHROME}")
        middle_col = ui.column().classes("h-full overflow-y-auto gap-1").style(
            f"width:220px; min-width:220px; background:{theme.BG_CHROME}; border-right:1px solid {theme.BORDER}; padding:10px; display:none"
        )
        right_col = ui.column().classes("flex-grow h-full overflow-y-auto gap-2").style(f"background:{theme.BG_SURFACE}; padding:20px")

    with commit_box:
        summary_input = ui.input(placeholder="Summary (required)").props("outlined dense").classes("w-full")
        description_input = ui.textarea(placeholder="Description").props("outlined dense autogrow").classes("w-full")
        commit_btn = ui.button("Commit", on_click=lambda: do_commit()).props("unelevated no-caps color=primary").classes("w-full")
        summary_input.on_value_change(lambda: update_commit_button())
        summary_input.on("keydown.enter", lambda: do_commit())

    def selected_paths() -> list[str]:
        return [f.path for f in state["changed_files"] if f.path not in state["excluded"]]

    def update_commit_button() -> None:
        n = len(selected_paths())
        if n == 0:
            commit_btn.set_text(f"Commit to {state['sync'].branch}")
        else:
            commit_btn.set_text(f"Commit {n} file{'s' if n != 1 else ''} to {state['sync'].branch}")
        commit_btn.set_enabled(bool(n and summary_input.value.strip()) and not state["committing"] and not state["busy"])

    def render_tabs() -> None:
        tabs_box.clear()
        with tabs_box:
            with ui.row().classes("w-full gap-0").style(f"border-bottom:1px solid {theme.BORDER}"):
                for mode_key, label in [("changes", "Changes"), ("history", "History")]:
                    active = state["mode"] == mode_key
                    if mode_key == "changes" and state["changed_files"]:
                        label += f" ({len(state['changed_files'])})"
                    border = f"2px solid {theme.ACCENT}" if active else "2px solid transparent"
                    color = theme.TEXT_PRIMARY if active else theme.TEXT_SECONDARY
                    weight = "600" if active else "400"
                    ui.label(label).classes("cursor-pointer px-4 py-3 text-sm").style(
                        f"color:{color}; border-bottom:{border}; font-weight:{weight}"
                    ).on("click", lambda _, m=mode_key: switch_mode(m))

    def render_left() -> None:
        render_tabs()
        list_box.clear()
        with list_box:
            if state["mode"] == "changes":
                render_changes_list()
            else:
                render_history_list()
        commit_box.set_visibility(state["mode"] == "changes")
        update_commit_button()

    def render_changes_list() -> None:
        files = state["changed_files"]
        if not files:
            with ui.column().classes("w-full items-center gap-1").style("padding:32px 16px"):
                ui.label("No local changes").style(f"color:{theme.TEXT_SECONDARY}")
                ui.label("Save a score in MuseScore and it will show up here.").classes("text-center").style(
                    f"color:{theme.TEXT_MUTED}; font-size:0.8rem"
                )
            return

        all_checked = not state["excluded"]
        with ui.row().classes("w-full items-center no-wrap gap-1 px-1").style(f"border-bottom:1px solid {theme.BORDER}"):
            select_all = ui.checkbox(value=all_checked).props("dense size=sm").classes("q-pa-sm")
            ui.label(f"{len(files)} changed file{'s' if len(files) != 1 else ''}").style(f"color:{theme.TEXT_SECONDARY}; font-size:0.8rem")

        boxes: dict[str, ui.checkbox] = {}
        syncing = {"on": False}  # set while select_all is updated programmatically

        def toggle_all(checked: bool) -> None:
            if syncing["on"]:
                return
            state["excluded"] = set() if checked else {f.path for f in files}
            for box in boxes.values():
                box.set_value(checked)
            update_commit_button()

        def toggle(path: str, checked: bool) -> None:
            if checked:
                state["excluded"].discard(path)
            else:
                state["excluded"].add(path)
            syncing["on"] = True
            select_all.set_value(not state["excluded"])
            syncing["on"] = False
            update_commit_button()

        select_all.on_value_change(lambda e: toggle_all(e.value))

        for f in files:
            selected = state["selected_file"] == f.path
            letter, color, tooltip = _CHANGE_STYLE[f.status]
            with ui.row().classes("items-center w-full no-wrap gap-0 px-1").style(f"background:{_bg(selected)}"):
                boxes[f.path] = ui.checkbox(
                    value=f.path not in state["excluded"], on_change=lambda e, p=f.path: toggle(p, e.value)
                ).props("dense size=sm").classes("q-pa-sm")
                with ui.row().classes("items-center gap-2 no-wrap flex-grow min-w-0 cursor-pointer py-2 pr-2").on(
                    "click", lambda _, p=f.path: select_changed_file(p)
                ):
                    ui.label(f.path).classes("text-sm truncate flex-grow").style(
                        f"color:{theme.TEXT_PRIMARY if f.is_score else theme.TEXT_SECONDARY}"
                    )
                    ui.label(letter).classes("text-xs font-bold w-4 text-center").style(
                        f"color:{color}; border:1px solid {color}; border-radius:3px; line-height:14px"
                    ).tooltip(tooltip)

    def render_history_list() -> None:
        if not state["commits"]:
            ui.label("No commits yet").classes("text-sm p-4").style(f"color:{theme.TEXT_SECONDARY}")
        for c in state["commits"]:
            with ui.column().classes("w-full cursor-pointer px-3 py-2 gap-0").style(
                f"background:{_bg(state['selected_commit'] == c.sha)}; border-bottom:1px solid {theme.BORDER}"
            ).on("click", lambda _, sha=c.sha: select_commit(sha)):
                ui.label(c.subject).classes("text-sm truncate w-full").style(f"color:{theme.TEXT_PRIMARY}")
                ui.label(_commit_subtitle(c)).classes("text-xs truncate w-full").style(f"color:{theme.TEXT_MUTED}")

    def render_middle() -> None:
        middle_col.clear()
        if state["mode"] != "history" or not state["selected_commit"]:
            middle_col.style("display:none")
            return
        middle_col.style("display:flex")
        with middle_col:
            commit = next((c for c in state["commits"] if c.sha == state["selected_commit"]), None)
            if commit:
                ui.label(commit.subject).classes("text-sm font-semibold").style(f"color:{theme.TEXT_PRIMARY}")
                ui.label(_commit_subtitle(commit)).classes("text-xs").style(f"color:{theme.TEXT_MUTED}")
                ui.label(commit.short_sha).classes("text-xs font-mono mb-2").style(f"color:{theme.TEXT_MUTED}")
            ui.label(f"{len(state['commit_files'])} SCORE FILE(S) CHANGED").classes("text-xs mb-1 tracking-wide").style(f"color:{theme.TEXT_MUTED}")
            if not state["commit_files"]:
                ui.label("No .mscz files changed in this commit.").classes("text-sm").style(f"color:{theme.TEXT_MUTED}")
            for path in state["commit_files"]:
                with ui.row().classes("items-center gap-2 w-full cursor-pointer px-2 py-1 no-wrap").style(
                    f"background:{_bg(state['selected_commit_file'] == path)}"
                ).on("click", lambda _, p=path: select_commit_file(p)):
                    ui.label("M").classes("text-xs font-bold w-4 text-center").style(f"color:{theme.YELLOW}")
                    ui.label(path).classes("text-sm truncate").style(f"color:{theme.TEXT_PRIMARY}")

    # -- Loading / refreshing -------------------------------------------------

    def _snapshot():
        head = None if repo.head_is_unborn else str(repo.head.target)
        return git_ops.list_changes(repo), git_ops.sync_status(repo), head

    async def refresh_all(rerender_selection: bool = False) -> None:
        """Re-read everything from disk and update whatever changed."""
        changes, sync, head = await run.io_bound(_snapshot)
        apply_snapshot(changes, sync, head, force=True)
        if rerender_selection and state["mode"] == "changes" and state["selected_file"]:
            await select_changed_file(state["selected_file"])

    def apply_snapshot(changes, sync: SyncStatus, head: str | None, force: bool = False) -> None:
        changes_changed = changes != state["changed_files"]
        if changes_changed:
            paths = {c.path for c in changes}
            state["changed_files"] = changes
            state["excluded"] &= paths
            if state["selected_file"] and state["selected_file"] not in paths:
                state["selected_file"] = None
                if state["mode"] == "changes":
                    right_col.clear()
        if sync != state["sync"] or force:
            state["sync"] = sync
            header_bar.refresh()
        head_changed = head != state["head"]
        state["head"] = head
        if head_changed:
            state["commits"] = []  # reloaded lazily, next time History is shown
            if state["mode"] == "history":
                background_tasks.create(load_commits())
        if changes_changed or force:
            render_left()

    async def load_commits() -> None:
        state["commits"] = await run.io_bound(git_ops.list_all_commits, repo)
        if state["mode"] == "history":
            render_left()

    polling = {"active": False}

    async def poll() -> None:
        if polling["active"] or session.write_lock.locked() or session.repo is not repo:
            return
        polling["active"] = True
        try:
            # Hold the lock so a commit can't mutate the shared index while
            # status() is reading it on another thread.
            async with session.write_lock:
                changes, sync, head = await run.io_bound(_snapshot)
            apply_snapshot(changes, sync, head)
        except Exception:  # noqa: BLE001 - e.g. the folder was moved away; just try again next tick
            pass
        finally:
            polling["active"] = False

    # -- Actions ---------------------------------------------------------------

    async def do_commit() -> None:
        paths = selected_paths()
        summary = summary_input.value.strip()
        if not paths or not summary or state["committing"] or state["busy"]:
            return
        if git_ops.get_signature(repo) is None and not await dialogs.identity_dialog():
            return
        message = summary + "\n"
        if description_input.value.strip():
            message += "\n" + description_input.value.strip() + "\n"
        state["committing"] = True
        update_commit_button()
        try:
            async with session.write_lock:
                sha = await run.io_bound(git_ops.commit_paths, repo, paths, message)
        except git_ops.GitError as e:
            dialogs.show_error("Commit failed", str(e))
            return
        finally:
            state["committing"] = False
            update_commit_button()
        summary_input.set_value("")
        description_input.set_value("")
        state["selected_file"] = None
        right_col.clear()
        ui.notify(f"Committed {sha[:8]} to {state['sync'].branch}", type="positive")
        await refresh_all()

    async def discard(path: str) -> None:
        f = next((c for c in state["changed_files"] if c.path == path), None)
        if f is None:
            return
        what = "delete this new file" if f.status == "new" else "restore it to the last committed version"
        if not await dialogs.confirm(
            "Discard changes?",
            f"{path}\n\nThis will {what}. Your uncommitted changes to it will be lost permanently.",
            "Discard changes",
            danger=True,
        ):
            return
        async with session.write_lock:
            try:
                await run.io_bound(git_ops.discard_changes, repo, [path])
            except Exception as e:  # noqa: BLE001
                dialogs.show_error("Couldn't discard changes", str(e))
        await refresh_all()

    async def switch_branch(branch: BranchInfo) -> None:
        if branch.is_current:
            return
        async with session.write_lock:
            try:
                await run.io_bound(git_ops.checkout_branch, repo, branch)
            except git_ops.GitError as e:
                dialogs.show_error("Couldn't switch branch", str(e))
                return
        ui.notify(f"Switched to {branch.name}")
        await reset_view()

    async def new_branch() -> None:
        name = await dialogs.new_branch_dialog()
        if name:
            ui.notify(f"Created and switched to {name}")
            await reset_view()

    async def reset_view() -> None:
        state["selected_file"] = state["selected_commit"] = state["selected_commit_file"] = None
        state["commits"] = []
        right_col.clear()
        render_middle()
        await refresh_all()
        if state["mode"] == "history":
            await load_commits()

    async def edit_remote() -> None:
        if await dialogs.remote_dialog(publishing=False):
            await refresh_all()

    async def network(label: str, fn, *args) -> bool:
        if state["busy"] or state["committing"]:
            ui.notify("Another operation is still running.")
            return False
        state["busy"] = label
        header_bar.refresh()
        update_commit_button()
        try:
            async with session.write_lock:
                await run.io_bound(fn, *args)
            return True
        except remote_ops.RemoteError as e:
            dialogs.show_error(f"{label} failed", str(e))
            return False
        finally:
            state["busy"] = None
            await refresh_all()

    async def fetch() -> None:
        remote = git_ops.default_remote(repo)
        if await network("Fetching", remote_ops.fetch, session.repo_path, remote):
            sync = state["sync"]
            ui.notify(f"{sync.behind} new commit(s) to pull" if sync.behind else "Up to date", type="positive")

    async def push(set_upstream: bool) -> None:
        remote = git_ops.default_remote(repo)
        branch = state["sync"].branch
        if await network("Pushing", remote_ops.push, session.repo_path, remote, branch, set_upstream):
            ui.notify(f"Pushed {branch} to {remote}", type="positive")

    async def pull() -> None:
        if await network("Pulling", remote_ops.pull_ff_only, session.repo_path):
            ui.notify("Pulled latest commits", type="positive")
            await reset_view()

    async def publish_repository() -> None:
        remote = await dialogs.remote_dialog(publishing=True)
        if remote:
            await push(set_upstream=True)

    async def explain_divergence() -> None:
        sync = state["sync"]
        dialogs.show_error(
            "Branch has diverged",
            f"“{sync.branch}” has {sync.ahead} commit(s) that {sync.upstream} doesn't, and {sync.upstream} has "
            f"{sync.behind} commit(s) that “{sync.branch}” doesn't.\n\n"
            "Score files are zip archives, so git can't merge two edited versions of the same score "
            "automatically. Resolve this with git in a terminal, e.g. by moving your commits to a new branch, "
            "or by keeping one side's version of each conflicting score.",
        )

    async def close_repository() -> None:
        session.close_repo()
        ui.navigate.reload()

    # -- Selection -------------------------------------------------------------

    async def switch_mode(mode: str) -> None:
        state["mode"] = mode
        state["selected_file"] = None
        state["selected_commit"] = None
        state["selected_commit_file"] = None
        render_left()
        render_middle()
        right_col.clear()
        if mode == "history" and not state["commits"]:
            await load_commits()

    async def select_changed_file(path: str) -> None:
        state["selected_file"] = path
        render_left()
        f = next((c for c in state["changed_files"] if c.path == path), None)
        if f is None:
            return
        if not f.is_score or f.status == "deleted":
            right_col.clear()
            with right_col:
                changed_file_heading(path)
                if f.status == "deleted":
                    message = "This file was deleted. Commit to record the deletion, or discard to bring it back."
                elif f.status == "new":
                    message = "New file. Only .mscz scores get a notation diff."
                else:
                    message = "Modified. Only .mscz scores get a notation diff."
                ui.label(message).style(f"color:{theme.TEXT_SECONDARY}")
            return
        ref_a = "HEAD" if f.status == "modified" else None
        await show_diff(path, ref_a, WORKING_TREE_REF, "Last commit", "Working tree", heading=lambda: changed_file_heading(path))

    def changed_file_heading(path: str) -> None:
        with ui.row().classes("w-full items-center no-wrap"):
            ui.label(path).classes("flex-grow truncate").style(f"color:{theme.TEXT_PRIMARY}; font-size:1.125rem; font-weight:600")
            ui.button("Discard changes…", icon="undo", on_click=lambda: discard(path)).props("flat no-caps dense color=negative")

    async def select_commit(sha: str) -> None:
        state["selected_commit"] = sha
        state["selected_commit_file"] = None
        render_left()
        files = await run.io_bound(git_ops.changed_mscz_files_in_commit, repo, sha)
        state["commit_files"] = files
        state["selected_commit_file"] = files[0] if files else None
        render_middle()
        if state["selected_commit_file"]:
            await select_commit_file(state["selected_commit_file"])
        else:
            right_col.clear()

    async def select_commit_file(path: str) -> None:
        state["selected_commit_file"] = path
        render_middle()
        sha = state["selected_commit"]
        parent = await run.io_bound(git_ops.parent_sha, repo, sha)
        existed_before = parent is not None and await run.io_bound(git_ops.blob_sha, repo, parent, path) is not None
        exists_after = await run.io_bound(git_ops.blob_sha, repo, sha, path) is not None

        if not existed_before or not exists_after:
            right_col.clear()
            with right_col:
                ui.label(path).style(f"color:{theme.TEXT_PRIMARY}; font-size:1.125rem; font-weight:600")
                if parent is None:
                    reason = "This is the first commit — no earlier version to compare against."
                elif not existed_before:
                    reason = "This file was added in this commit — no earlier version to compare against."
                else:
                    reason = "This file was removed or renamed away in this commit — no version to show here."
                ui.label(reason).style(f"color:{theme.TEXT_SECONDARY}")
            return
        await show_diff(path, parent, sha, "Parent commit", "This commit")

    async def show_diff(path: str, ref_a: str | None, ref_b: str, label_a: str, label_b: str, heading=None) -> None:
        right_col.clear()
        with right_col:
            if heading:
                heading()
            else:
                ui.label(path).style(f"color:{theme.TEXT_PRIMARY}; font-size:1.125rem; font-weight:600")
            ui.label(f"{label_a} → {label_b}").style(f"color:{theme.TEXT_SECONDARY}; font-size:0.875rem")
            body = ui.column().classes("w-full mt-2")
            with body:
                if ref_a is None:
                    ui.label("Newly added — nothing to compare against yet.").style(f"color:{theme.TEXT_SECONDARY}")
                else:
                    ui.spinner(size="lg")
        if ref_a is None:
            return
        try:
            result = await run.io_bound(diffing.diff_versions, repo, session.cache_root, ref_a, path, ref_b, path)
        except Exception as e:  # noqa: BLE001 - always resolve the spinner, even on an unexpected failure
            if body.is_deleted:
                return
            body.clear()
            with body:
                ui.label(f"Error: {e}").style(f"color:{theme.RED}; font-family:monospace; white-space:pre-wrap")
            return
        if body.is_deleted:
            return  # navigated away (or picked another file) while the diff was computing
        body.clear()
        with body:
            render_diff_result(result)

    def render_diff_result(result) -> None:
        if result.error:
            ui.label(f"Error: {result.error}").style(f"color:{theme.RED}; font-family:monospace; white-space:pre-wrap")
            return
        if result.cost == 0:
            ui.label("No notation differences detected.").style(f"color:{theme.GREEN}; font-weight:600")
            return

        ui.label(f"{result.cost} notation differences (OMR edit distance)").style(f"color:{theme.TEXT_PRIMARY}; font-weight:600")

        with ui.tabs().classes("w-full") as tabs:
            visual_tab = ui.tab("Visual diff")
            text_tab = ui.tab("Text diff")
        with ui.tab_panels(tabs, value=visual_tab).classes("w-full").style(f"background:{theme.BG_SURFACE}"):
            with ui.tab_panel(visual_tab):
                if not result.excerpts:
                    ui.label("No differences render visibly in the score — see the text diff.").style(f"color:{theme.TEXT_SECONDARY}")
                for excerpt in result.excerpts:
                    with ui.column().classes("w-full mb-6 gap-1"):
                        ui.label(excerpt.label).style(f"color:{theme.TEXT_PRIMARY}; font-weight:600")
                        with ui.row().classes("w-full items-start gap-4 no-wrap"):
                            with ui.column().classes("flex-1 min-w-0 gap-1"):
                                ui.label("Before").style(f"color:{theme.TEXT_SECONDARY}; font-size:0.75rem; text-transform:uppercase")
                                _score_card(excerpt.svg1)
                            with ui.column().classes("flex-1 min-w-0 gap-1"):
                                ui.label("After").style(f"color:{theme.TEXT_SECONDARY}; font-size:0.75rem; text-transform:uppercase")
                                _score_card(excerpt.svg2)
            with ui.tab_panel(text_tab).style(f"background:{theme.BG_SURFACE}"):
                ui.html(_colorize_diff_text(result.text)).classes("font-mono text-sm")

    with ui.header().classes("items-center gap-0 no-wrap").style(f"background:{theme.BG_CHROME}; padding:0; height:{_HEADER_HEIGHT}px; border-bottom:1px solid {theme.BORDER}"):
        header_bar()
    render_left()
    render_middle()
    await refresh_all()
    ui.timer(_POLL_SECONDS, poll)


def _bg(selected: bool) -> str:
    return theme.SELECTED_BG if selected else "transparent"


def run_app(argv: list[str] | None = None) -> None:
    args = _parse_args(argv)

    if args.repo:
        repo_path = Path(args.repo).expanduser().resolve()
        try:
            session.open_repo(repo_path)
        except git_ops.GitError as e:
            print(f"error: {e}", file=sys.stderr)
            raise SystemExit(1)
    else:
        # No --repo (this is how the packaged app is launched): reopen the most
        # recent repo, like GitHub Desktop, or show the welcome screen.
        for path in recent.load():
            try:
                session.open_repo(path)
                break
            except git_ops.GitError:
                recent.remove(path)

    cache.CACHE_BASE.mkdir(parents=True, exist_ok=True)
    app.add_static_files("/cache", str(cache.CACHE_BASE))

    native = not args.web
    dialogs.native = native
    ui.run(
        host=args.host or "127.0.0.1",  # localhost-only by default; this browses a private repo
        port=args.port,
        title="Arrangement Diff Viewer",
        reload=False,
        show=False,
        native=native,
        window_size=(1400, 900) if native else None,
    )


if __name__ in {"__main__", "__mp_main__"}:
    run_app()
