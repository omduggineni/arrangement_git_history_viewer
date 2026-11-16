import AppKit
import SwiftUI

enum DiffState {
    case newlyAdded
    case running(Double, String)
    case done(DiffResult)
}

/// What the right-hand pane shows.
struct RightContent {
    enum Body {
        case none
        case message(String)
        case rendering
        case pages([String])
        case diff(DiffState)
    }
    var heading: String
    /// set for working-tree changes, which can be discarded from the heading row
    var discardPath: String?
    var subtitle: String?
    var body: Body
}

struct TreeRow: Identifiable {
    enum Kind { case dir(closed: Bool), file(path: String) }
    var id: String
    var name: String
    var depth: Int
    var kind: Kind
}

typealias Snapshot = (changes: [ChangedFile], sync: SyncStatus, head: String?, remote: String, branches: [BranchInfo])

let pollSeconds: UInt64 = 3

/// State and actions for the repository view (changes / files / history).
@MainActor @Observable final class RepoModel {
    enum Mode { case changes, files, history }

    let token: Int
    let repoPath: String
    let cacheRoot: String

    var mode: Mode = .changes
    var changedFiles: [ChangedFile] = []
    /// changed paths the user unchecked for the next commit
    var excluded: Set<String> = []
    var commits: [CommitInfo] = []
    /// every file in the working tree, for the Files tab
    var files: [String] = []
    /// folders the user collapsed in the Files tab
    var collapsed: Set<String> = []
    var selectedTreeFile: String?
    /// HEAD commit sha, to notice new commits (from us or elsewhere)
    var head: String?
    var sync: SyncStatus
    /// the remote to fetch/push, and the branch menu's contents; refreshed with each
    /// snapshot so rendering never has to run git
    var remote = "origin"
    var branches: [BranchInfo] = []
    /// label of an in-flight network operation, e.g. "Pushing"
    var busy: String?
    var committing = false
    var selectedFile: String?
    var selectedCommit: String?
    var commitFiles: [String] = []
    var selectedCommitFile: String?
    var right: RightContent?
    var summary = ""
    var desc = ""

    /// bumped whenever the right pane is cleared, to drop stale async results
    @ObservationIgnored private var rightGen = 0
    @ObservationIgnored private var polling = false
    private var app: AppModel { .shared }

    init(token: Int, open: OpenRepo) {
        self.token = token
        repoPath = open.repoPath
        cacheRoot = open.cacheRoot
        sync = (try? GitOps.syncStatus(open.repoPath)) ?? SyncStatus()
    }

    var alive: Bool { app.token == token }
    var branch: String { sync.branch }
    var repoName: String { baseName(repoPath) }

    var selectedPaths: [String] { changedFiles.filter { !excluded.contains($0.path) }.map(\.path) }
    var commitEnabled: Bool { !selectedPaths.isEmpty && !summary.trimmingCharacters(in: .whitespaces).isEmpty && !committing && busy == nil }
    var commitTitle: String {
        let n = selectedPaths.count
        return n == 0 ? "Commit to \(branch)" : "Commit \(n) file\(n != 1 ? "s" : "") to \(branch)"
    }

    func start() {
        Task {
            await refreshAll(rerenderSelection: false)
            while alive {
                try? await Task.sleep(nanoseconds: pollSeconds * 1_000_000_000)
                if !alive { break }
                await poll()
            }
        }
    }

    // --- Loading / refreshing -------------------------------------------------

    nonisolated static func snapshot(_ repo: String) throws -> Snapshot {
        (try GitOps.listChanges(repo), try GitOps.syncStatus(repo), GitOps.headSha(repo),
         GitOps.defaultRemote(repo) ?? "origin", (try? GitOps.listBranches(repo)) ?? [])
    }

    func refreshAll(rerenderSelection: Bool) async {
        let rp = repoPath
        guard let snap = try? await blocking({ Result { try RepoModel.snapshot(rp) } }).get() else { return }
        if !alive { return }
        applySnapshot(snap, force: true)
        if rerenderSelection && mode == .changes, let p = selectedFile {
            await selectChangedFile(p)
        }
    }

    private func applySnapshot(_ snap: Snapshot, force: Bool) {
        let changesChanged = snap.changes != changedFiles
        if changesChanged {
            let paths = Set(snap.changes.map(\.path))
            changedFiles = snap.changes
            excluded = excluded.filter { paths.contains($0) }
            if let s = selectedFile, !paths.contains(s) {
                selectedFile = nil
                if mode == .changes { clearRight() }
            }
        }
        if snap.sync != sync || force { sync = snap.sync }
        if snap.remote != remote { remote = snap.remote }
        if snap.branches != branches { branches = snap.branches }
        let headChanged = snap.head != head
        head = snap.head
        if headChanged {
            commits = [] // reloaded lazily, next time History is shown
            if mode == .history { Task { await loadCommits() } }
        }
        if mode == .files && (changesChanged || headChanged || force) {
            Task { await loadFiles() }
        }
    }

    func loadCommits() async {
        let rp = repoPath
        let c = await blocking { (try? GitOps.listAllCommits(rp, maxCount: 300)) ?? [] }
        commits = c
    }

    func loadFiles() async {
        let rp = repoPath
        let f = await blocking { (try? GitOps.listRepoFiles(rp)) ?? [] }
        if mode == .files && alive { files = f }
    }

    private func poll() async {
        if polling || app.writeLock.isLocked || !alive { return }
        polling = true
        defer { polling = false }
        // Hold the lock so a commit can't mutate the index while status reads it.
        let rp = repoPath
        let snap = await app.writeLock.with { await blocking { Result { try RepoModel.snapshot(rp) } } }
        if let s = try? snap.get(), alive { applySnapshot(s, force: false) }
    }

    // --- Actions ---------------------------------------------------------------

    func doCommit() async {
        let paths = selectedPaths
        let title = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if paths.isEmpty || title.isEmpty || committing || busy != nil { return }
        let rp = repoPath
        let hasSig = await blocking { GitOps.getSignature(rp) != nil }
        if !hasSig, !(await app.identityDialog()) { return }
        var message = "\(title)\n"
        let d = desc.trimmingCharacters(in: .whitespacesAndNewlines)
        if !d.isEmpty { message += "\n\(d)\n" }
        committing = true
        let msg = message
        let res = await app.writeLock.with { await blocking { Result { try GitOps.commitPaths(rp, paths, message: msg) } } }
        committing = false
        switch res {
        case .failure(let e):
            app.showError("Commit failed", "\(e)")
        case .success(let sha):
            summary = ""
            desc = ""
            selectedFile = nil
            clearRight()
            app.notify("Committed \(sha.prefix(8)) to \(branch)")
            await refreshAll(rerenderSelection: false)
        }
    }

    func discard(_ path: String) async {
        guard let f = changedFiles.first(where: { $0.path == path }) else { return }
        let what = f.status == .new ? "delete this new file" : "restore it to the last committed version"
        let msg = "\(path)\n\nThis will \(what). Your uncommitted changes to it will be lost permanently."
        if !(await app.confirm("Discard changes?", msg, confirmLabel: "Discard changes", danger: true)) { return }
        let rp = repoPath
        let res = await app.writeLock.with { await blocking { Result { try GitOps.discardChanges(rp, [path]) } } }
        if case .failure(let e) = res { app.showError("Couldn't discard changes", "\(e)") }
        await refreshAll(rerenderSelection: false)
    }

    func switchBranch(_ b: BranchInfo) async {
        if b.isCurrent { return }
        let rp = repoPath
        let res = await app.writeLock.with { await blocking { Result { try GitOps.checkoutBranch(rp, b) } } }
        if case .failure(let e) = res { app.showError("Couldn't switch branch", "\(e)"); return }
        app.notify("Switched to \(b.name)")
        await resetView()
    }

    func newBranch() async {
        if let name = await app.newBranchDialog() {
            app.notify("Created and switched to \(name)")
            await resetView()
        }
    }

    private func resetView() async {
        selectedFile = nil
        selectedCommit = nil
        selectedCommitFile = nil
        commits = []
        clearRight()
        await refreshAll(rerenderSelection: false)
        if mode == .history { await loadCommits() }
    }

    func editRemote() async {
        if await app.remoteDialog(publishing: false) != nil { await refreshAll(rerenderSelection: false) }
    }

    @discardableResult
    private func network(_ label: String, _ f: @escaping () throws -> Void) async -> Bool {
        if busy != nil || committing { app.notify("Another operation is still running."); return false }
        busy = label
        let res = await app.writeLock.with { await blocking { Result { try f() } } }
        var ok = true
        if case .failure(let e) = res {
            app.showError("\(label) failed", "\(e)")
            ok = false
        }
        busy = nil
        await refreshAll(rerenderSelection: false)
        return ok
    }

    func fetch() async {
        let rp = repoPath
        let remote = self.remote
        if await network("Fetching", { try RemoteOps.fetch(rp, remote: remote) }) {
            app.notify(sync.behind > 0 ? "\(sync.behind) new commit(s) to pull" : "Up to date")
        }
    }

    func push(setUpstream: Bool) async {
        let rp = repoPath, b = branch
        let remote = self.remote
        if await network("Pushing", { try RemoteOps.push(rp, remote: remote, branch: b, setUpstream: setUpstream) }) {
            app.notify("Pushed \(b) to \(remote)")
        }
    }

    func pull() async {
        let rp = repoPath
        if await network("Pulling", { try RemoteOps.pullFFOnly(rp) }) {
            app.notify("Pulled latest commits")
            await resetView()
        }
    }

    func publishRepository() async {
        if await app.remoteDialog(publishing: true) != nil { await push(setUpstream: true) }
    }

    func explainDivergence() {
        let up = sync.upstream ?? ""
        app.showError("Branch has diverged", """
            “\(sync.branch)” has \(sync.ahead) commit(s) that \(up) doesn't, and \(up) has \(sync.behind) commit(s) that “\(sync.branch)” doesn't.

            Score files are zip archives, so git can't merge two edited versions of the same score automatically. Resolve this with git in a terminal, e.g. by moving your commits to a new branch, or by keeping one side's version of each conflicting score.
            """)
    }

    // --- Selection ---------------------------------------------------------------

    private func clearRight() {
        rightGen += 1
        right = nil
    }

    func switchMode(_ m: Mode) async {
        mode = m
        selectedTreeFile = nil
        selectedFile = nil
        selectedCommit = nil
        selectedCommitFile = nil
        clearRight()
        if m == .history && commits.isEmpty {
            await loadCommits()
        } else if m == .files {
            await loadFiles()
        }
    }

    func selectTreeFile(_ path: String) async {
        selectedTreeFile = path
        clearRight()
        let gen = rightGen
        right = RightContent(heading: path, body: path.hasSuffix(".mscz") ? .rendering : .message("Only .mscz scores can be previewed."))
        guard path.hasSuffix(".mscz") else { return }
        let (rp, cr) = (repoPath, cacheRoot)
        let res = await blocking { Result { try Cache.ensurePages(rp, cr, workingTreeRef, path) } }
        if rightGen != gen { return } // user moved on while MuseScore was working
        switch res {
        case .success(let pages): right?.body = .pages(pages)
        case .failure(let e):
            right?.body = .message("")
            app.showError("Couldn't render score", "\(e)")
        }
    }

    func selectChangedFile(_ path: String) async {
        selectedFile = path
        guard let f = changedFiles.first(where: { $0.path == path }) else { return }
        if !f.isScore || f.status == .deleted {
            clearRight()
            let message: String
            switch f.status {
            case .deleted: message = "This file was deleted. Commit to record the deletion, or discard to bring it back."
            case .new: message = "New file. Only .mscz scores get a notation diff."
            case .modified: message = "Modified. Only .mscz scores get a notation diff."
            }
            right = RightContent(heading: path, discardPath: path, body: .message(message))
            return
        }
        await showDiff(path: path, refA: f.status == .modified ? "HEAD" : nil, refB: workingTreeRef,
                       labelA: "Last commit", labelB: "Working tree", discardPath: path)
    }

    func selectCommit(_ sha: String) async {
        selectedCommit = sha
        selectedCommitFile = nil
        let rp = repoPath
        let list = await blocking { (try? GitOps.changedMsczFilesInCommit(rp, sha)) ?? [] }
        if selectedCommit != sha { return }
        commitFiles = list
        selectedCommitFile = list.first
        if let f = list.first { await selectCommitFile(f) } else { clearRight() }
    }

    func selectCommitFile(_ path: String) async {
        selectedCommitFile = path
        guard let sha = selectedCommit else { return } // tabs switched while loading
        let rp = repoPath
        let parent = await blocking { (try? GitOps.parentSha(rp, sha)) ?? nil }
        var existedBefore = false
        if let par = parent { existedBefore = await blocking { GitOps.blobSha(rp, par, path) != nil } }
        let existsAfter = await blocking { GitOps.blobSha(rp, sha, path) != nil }
        if selectedCommit != sha { return }
        if !existedBefore || !existsAfter {
            clearRight()
            let reason = parent == nil ? "This is the first commit — no earlier version to compare against."
                : !existedBefore ? "This file was added in this commit — no earlier version to compare against."
                : "This file was removed or renamed away in this commit — no version to show here."
            right = RightContent(heading: path, body: .message(reason))
            return
        }
        await showDiff(path: path, refA: parent, refB: sha, labelA: "Parent commit", labelB: "This commit", discardPath: nil)
    }

    private func showDiff(path: String, refA: String?, refB: String, labelA: String, labelB: String, discardPath: String?) async {
        clearRight()
        let gen = rightGen
        var content = RightContent(heading: path, discardPath: discardPath, subtitle: "\(labelA) → \(labelB)", body: .none)
        guard let refA else {
            content.body = .diff(.newlyAdded)
            right = content
            return
        }
        content.body = .diff(.running(0, "Starting"))
        right = content
        let (rp, cr) = (repoPath, cacheRoot)
        let result = await blocking {
            Diffing.diffVersions(repo: rp, cacheRoot: cr, ref1: refA, path1: path, ref2: refB, path2: path) { f, m in
                Task { @MainActor in RepoModel.liveProgress(self, gen, f, m) }
            }
        }
        if rightGen != gen { return } // navigated away (or picked another file) while the diff was computing
        right?.body = .diff(.done(result))
    }

    private static func liveProgress(_ model: RepoModel, _ gen: Int, _ f: Double, _ m: String) {
        guard model.rightGen == gen, case .diff(.running) = model.right?.body else { return }
        model.right?.body = .diff(.running(f, m))
    }

    // --- Files tab tree --------------------------------------------------------------

    func toggleFolder(_ key: String) {
        if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
    }

    var treeRows: [TreeRow] {
        final class Node { var dirs: [String: Node] = [:]; var files: [String: String] = [:] }
        let root = Node()
        for path in files {
            let parts = path.split(separator: "/").map(String.init)
            var n = root
            for d in parts.dropLast() {
                if let next = n.dirs[d] { n = next } else { let x = Node(); n.dirs[d] = x; n = x }
            }
            if let last = parts.last { n.files[last] = path }
        }
        var rows: [TreeRow] = []
        func walk(_ n: Node, prefix: String, depth: Int) {
            // folders first, then files, each alphabetical
            for name in n.dirs.keys.sorted(by: { $0.lowercased() < $1.lowercased() }) {
                let key = prefix + name
                let closed = collapsed.contains(key)
                rows.append(TreeRow(id: "d:" + key, name: name, depth: depth, kind: .dir(closed: closed)))
                if !closed { walk(n.dirs[name]!, prefix: key + "/", depth: depth + 1) }
            }
            for name in n.files.keys.sorted(by: { $0.lowercased() < $1.lowercased() }) {
                rows.append(TreeRow(id: "f:" + n.files[name]!, name: name, depth: depth, kind: .file(path: n.files[name]!)))
            }
        }
        walk(root, prefix: "", depth: 0)
        return rows
    }

    func status(of path: String) -> FileStatus? { changedFiles.first { $0.path == path }?.status }
}
