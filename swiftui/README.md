# Arrangement Diff Viewer — SwiftUI (macOS)

Native macOS port of the Python/NiceGUI and Rust/GTK apps: git history and notation-level
diffs for a folder of MuseScore (`.mscz`) files. The window layout follows the GTK/Rust
version (GitHub Desktop style): a header bar with *Current repository / Current branch /
Fetch·Pull·Push* buttons, a sidebar with **Changes / Files / History** tabs and a commit box,
a commit's changed-score list, and a right pane with the score preview or the diff
(Visual diff: before/after excerpts on white "paper" cards; Text diff: colored musicdiff output).

Settings, the recent-repositories list and cache keys/layout are identical to the other two
apps, so all three share `~/.config/arrangement-diff-viewer` and `~/.cache/arrangement-diff-viewer`.

## What is Swift, and what isn't

Module layout mirrors the Rust app: `Models`, `Session` (in `AppModel`), `Recent`, `Settings`,
`Cache`, `Convert`, `GitOps`, `RemoteOps`, `Diffing`, `Dialogs`, `Theme`, `RepoView`/`WelcomeView`/`SettingsView`.

| Step | Implementation |
|---|---|
| UI, state, polling (every 3 s), dialogs | SwiftUI + Observation |
| Local git (status, commit, branches, history, discard) | the `git` CLI (plumbing / `-z` output; no libgit2 in the Swift toolchain) |
| Clone / fetch / push / pull | the `git` CLI, headless (no prompts), with the same error hints |
| `.mscz` → MusicXML / page PNGs | MuseScore CLI (only program that reads `.mscz`) |
| **Notation diff** (musicdiff on music21, verovio excerpts) | **Python sidecar** `sidecar/diff_sidecar.py` (same script as the Rust app) |

musicdiff, music21 and converter21 have no Swift equivalent, so that one step runs in Python
(JSON progress lines on stdout drive the progress bar; results land in the shared cache). Its
interpreter is the third entry on the Settings page, auto-detected at `$ADV_ROOT/.venv`,
`../arrangement_git_history_viewer/.venv{,-gtk}` or `$PYTHON_PATH`. Git (`$GIT_PATH`) and
MuseScore (`$MSCORE_PATH`, `/Applications/MuseScore*.app`) are auto-detected too.

## Build / run

    swift run ArrangementDiffViewer -- [--repo /path/to/repo]     # or: make run REPO=/path
    make app                                                      # dist/Arrangement Diff Viewer.app

Without `--repo`, the most recently opened repo (or the welcome screen) is shown.
`make app` produces an ad-hoc-signed bundle; to distribute it elsewhere it needs a Developer ID
signature and notarization. The bundle can carry a PyInstaller-frozen sidecar
(`make app SIDECAR_DIST=…`, built with the Rust project's `packaging/sidecar.spec`).

## Tests

    swift test                                   # git/remote/cache/settings against throwaway repos
    ADV_SAMPLE_A=a.mscz ADV_SAMPLE_B=b.mscz swift test   # also runs the real MuseScore + diff pipeline

`ADV_CONFIG_DIR` / `ADV_CACHE_DIR` redirect settings and cache (the tests use them).

End-to-end driver (like the Rust `e2e` bin): drives the real window and writes a PNG after each step.

    ADV_E2E_OUT=/tmp/shots ADV_E2E_STEPS="file:song.mscz,tab:files,treefile:song.mscz,tab:history,commit:0,settings" \
        .build/debug/ArrangementDiffViewer --repo /path/to/repo
