# Arrangement Diff Viewer

A local web GUI for browsing the git history of a folder of MuseScore (`.mscz`)
files and viewing notation-level diffs between any two versions — including
uncommitted working-tree changes — using [musicdiff](https://github.com/gregchapman-dev/musicdiff).

The UI is modeled on GitHub Desktop: a **Changes** tab for uncommitted edits,
a **History** tab for commits (with the score files each commit touched), and
a right-hand panel that shows the score diff instead of a code diff.

It's also a complete (if deliberately simple) git client for a folder of scores:

- **Repositories**: open an existing repo, turn a plain folder of scores into
  one, create a new one (optionally with a `.gitignore` for MuseScore backup
  files), or clone one from a URL. Recently opened repos are listed on the
  welcome screen and in the *Current repository* menu, and the app reopens the
  last one on launch.
- **Committing**: every changed file (not just `.mscz`) is listed with a
  checkbox; tick the ones to include, write a summary, and commit. Like GitHub
  Desktop, git's staging area is hidden -- exactly the ticked files are
  committed. If git doesn't know your name/email yet, you're asked once.
  Individual files can also be discarded back to their last committed version.
- **Branches**: switch branches (including ones that only exist on the remote)
  or create a new one from the *Current branch* menu. Switching is refused,
  never forced, if it would overwrite uncommitted changes.
- **Syncing**: the third header button does whatever is next -- *Publish
  repository* (asks for a remote URL), *Publish branch*, *Push*, *Pull*, or
  *Fetch*. Pulls are fast-forward only: `.mscz` files are zip archives, so git
  can't merge two edited versions of a score, and a diverged branch is shown as
  such rather than producing an unresolvable merge.

The working tree is re-checked every few seconds, so saving in MuseScore (or
committing from a terminal) shows up without a manual refresh.

## Design: (almost) all Python, minimal shelling out

This is a single Python codebase end to end — [NiceGUI](https://nicegui.io)
serves the whole UI from Python with no separate frontend project to write or
build.

Two things that would normally shell out to external tools instead run
in-process:

- **Git access** uses [pygit2](https://www.pygit2.org/) (libgit2 bindings),
  not the `git` CLI.
- **Score rendering** uses [verovio](https://www.verovio.org/)'s Python
  bindings (a C++ engine exposed via pybind11), not MuseScore's CLI.

There are two exceptions. The first is **network git operations** (clone,
fetch, push, pull), which run the `git` CLI. libgit2 doesn't use git's
credential helpers or `~/.ssh/config`, so in-process pushing would mean
reimplementing authentication; the `git` binary already handles it. You don't
need git installed: the app ships its own copy (see
[External programs](#external-programs)), which includes
[Git Credential Manager](https://github.com/git-ecosystem/git-credential-manager),
so signing in over HTTPS opens a sign-in window the first time. These run
headless, so they fail with an explanation rather than hanging if they'd need
a terminal prompt, such as accepting a new SSH host key. Everything local
(status, commit, branches, history) still goes through pygit2.

The other unavoidable exception: **converting `.mscz` to MusicXML** shells out to
the MuseScore CLI (`mscore -o out.musicxml in.mscz`). `.mscz` is MuseScore's
own proprietary, version-specific file format — there is no maintained
pure-Python reader for it, and music21/converter21 (which musicdiff is built
on) don't understand it either. MuseScore is the only program this app needs
that it doesn't ship itself.

## Known limitation: MuseScore must not be busy at the same time

MuseScore's CLI is a full GUI app under the hood, not a true headless tool.
If MuseScore is open and actively doing something (editing, autosaving) at the
exact moment this app shells out to it, the conversion can crash
intermittently (SIGABRT). The app retries automatically a few times, which
clears most transient cases, but if you see a conversion error, **close
MuseScore** (or at least let it sit idle) and try again.

Requires MuseScore 4 to be installed; see below for how it's found.

## External programs

The app's **Settings** page (the gear icon in the toolbar, or on the welcome
screen) shows where `git` and the MuseScore CLI are being run from. Each
location is filled in automatically and can be changed, browsed for, or
tested there. Picking `MuseScore 4.app` itself is fine; the executable
inside the bundle is used. For each program, the first of these that applies
wins:

1. A location saved on the Settings page.
2. The `GIT_PATH` / `MSCORE_PATH` environment variable.
3. For git, the copy bundled with the app.
4. Auto-detection: `PATH`, plus each platform's usual install locations,
   since GUI apps don't get your shell's `PATH`:
   - **macOS**: `/Applications/MuseScore*.app`, `/opt/homebrew/bin`, `/usr/local/bin`.
   - **Linux**: `mscore` / `musescore` / `mscore4portable`, AppImages in
     `~/Applications`, `~/.local/bin` or `/opt`, Flatpak and Snap installs.
   - **Windows**: `MuseScore4.exe` / `MuseScore3.exe` under `Program Files`,
     and Git for Windows (system, per-user, or Scoop).

A saved location that matches the default anyway isn't stored as an
override, so the default keeps applying after upgrades. Settings are kept in
`~/.config/arrangement-diff-viewer/settings.json`.

The bundled git is [dugite-native](https://github.com/desktop/dugite-native),
the portable build GitHub Desktop ships. It uses your `~/.gitconfig` and
`~/.ssh` as usual, but not credentials saved by another git's credential
helper (for example the macOS keychain entries Apple's git saves), so you'll
sign in once through Git Credential Manager. To keep using your own git's
setup instead, choose that git on the Settings page. On Linux, Git Credential
Manager saves credentials to the desktop keyring (Secret Service).

## Running it

By default this runs as a **native app window** (via [pywebview](https://pywebview.flowrl.com/)),
not a browser tab — that's what `make app` below also packages up.

```bash
make run                        # native window; no --repo -> reopens the last repo, or a welcome screen
make run REPO=/path/to/repo     # native window, pointed at a specific repo
make run-web REPO=/path/to/repo # ordinary local web server instead, for development
```

(`make run`/`make run-web` create `.venv` and install the project the first
time they're run. Add `.venv/bin` to your `PATH`, or just run
`.venv/bin/python3 -m app.main [--web] [--repo ...]` directly, if you'd rather
not use `make`.)

If `--repo` is omitted, the most recently opened repository is reopened, or a
welcome screen (open / create / clone) is shown if there isn't one — this is
what makes the packaged app usable by just double-clicking it, with no command
line involved at all. Recent repositories are remembered in
`~/.config/arrangement-diff-viewer/recent_repos.json`.

## Building a standalone macOS app

```bash
make app
```

This bundles Python and every Python dependency into
`dist/Arrangement Diff Viewer.app` via [PyInstaller](https://pyinstaller.org/),
using the spec at `packaging/arrangement_diff_viewer.spec`. Double-click it, or
drag it to `/Applications`; with no arguments it reopens the last repository,
or shows the welcome screen. A portable git is bundled too: the first build
downloads it for the build machine's platform (checksum-pinned, via
`packaging/fetch_git.py`) into `vendor/git`, which later builds reuse.
MuseScore itself is *not* bundled and still needs to be installed separately
(see above).

The bundle is large (~400 MB): about 250 MB is music21's corpus/metadata
files and a full Python runtime, and about 150 MB is the bundled git, mostly
Git Credential Manager's .NET runtime. That's expected for a self-contained,
dependency-free app.

## How diffs are computed

For a chosen pair of versions of a `.mscz` file:

1. Each version's git blob is converted to MusicXML via MuseScore (cached on
   disk, keyed by git blob hash — including a content hash for uncommitted
   working-tree files, so edits are picked up immediately).
2. `musicdiff` parses both with music21 and computes the notation-level diff
   (an "OMR edit distance" plus a structured list of differences).
3. The changed measure numbers are extracted from that diff and clustered
   into a handful of small excerpts (e.g. "Measures 65–66"). Each excerpt is
   rendered independently, by measure number, for *both* versions using
   verovio's measure-range selection.

Rendering by measure number rather than by page matters: the two versions of
a score often paginate completely differently (e.g. adding a whole vocal
part reflows everything after it), so showing "page 12 vs. page 12" can
silently compare unrelated music. Showing "measures 65–66 vs. measures 65–66"
for both sides doesn't have that problem.

A **Text diff** tab is also available with musicdiff's git-style textual diff
for the full list of changes, including ones with no visual location (e.g.
metadata).

Results are cached on disk under `~/.cache/arrangement-diff-viewer/`, keyed
by the repo path and the git blob hashes being compared, so re-viewing a diff
is instant.
