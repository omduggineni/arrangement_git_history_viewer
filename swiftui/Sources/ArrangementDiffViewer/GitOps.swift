import Foundation

struct GitError: Error, CustomStringConvertible {
    var message: String
    init(_ m: String) { message = m }
    var description: String { message }
}

/// All local git access. Swift has no libgit2 binding in the standard
/// toolchain, so this drives the `git` CLI (the one Settings resolves) with
/// plumbing-style, machine-readable output. Every function takes a path, so
/// they can run from any worker thread.
enum GitOps {
    static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    static func gitExe() -> String { Settings.pathFor(Settings.git) ?? "git" }

    static func env(_ exe: String) -> [String: String] {
        var e = Settings.childEnv(exe)
        e["GIT_TERMINAL_PROMPT"] = "0"
        e["LC_ALL"] = "C" // stable English messages
        e["GIT_LITERAL_PATHSPECS"] = "1" // "Song [v2].mscz" is a file name, not a glob
        e["GIT_OPTIONAL_LOCKS"] = "0" // polling `status` must not fight a commit for index.lock
        return e
    }

    /// Run git in `repo`; returns the raw result (never throws on a non-zero exit).
    @discardableResult
    static func raw(_ repo: String, _ args: [String], input: Data? = nil, timeout: TimeInterval = 120) throws -> ProcResult {
        let exe = gitExe()
        do {
            return try runProcess(exe, args, cwd: repo, env: env(exe), input: input, timeout: timeout)
        } catch {
            throw GitError("The git command-line tool wasn't found or couldn't run (\(exe)). Set its location on the Settings page (the gear icon in the toolbar).")
        }
    }

    /// Run git and return stdout, throwing git's own message on failure.
    @discardableResult
    static func run(_ repo: String, _ args: [String], input: Data? = nil) throws -> String {
        let r = try raw(repo, args, input: input)
        if r.status != 0 {
            let msg = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError(msg.isEmpty ? "git \(args.first ?? "") failed" : msg.replacingOccurrences(of: "fatal: ", with: ""))
        }
        return r.out
    }

    static func nulList(_ s: String) -> [String] { s.split(separator: "\0").map(String.init) }
    static func lines(_ s: String) -> [String] { s.split(separator: "\n").map(String.init) }
    static func nulInput(_ paths: [String]) -> Data { Data(paths.map { $0 + "\0" }.joined().utf8) }

    // --- Opening and creating ------------------------------------------------

    /// The working folder of the repository containing `path`.
    static func openRepo(_ path: String) throws -> String {
        let notRepo = GitError("\(path) is not inside a git repository")
        guard isDirectory(path) else { throw notRepo }
        let bare = try raw(path, ["rev-parse", "--is-bare-repository"])
        if bare.status != 0 { throw notRepo }
        if bare.out.trimmingCharacters(in: .whitespacesAndNewlines) == "true" {
            throw GitError("\(path) is a bare repository (it has no working folder of files to show)")
        }
        let top = try raw(path, ["rev-parse", "--show-toplevel"])
        let dir = top.out.trimmingCharacters(in: .whitespacesAndNewlines)
        if top.status != 0 || dir.isEmpty { throw notRepo }
        return dir
    }

    /// Create a new repo at `path` (creating the folder if needed), on a branch
    /// named "main". Initializing inside an existing folder of scores is fine --
    /// the files just show up as new, uncommitted changes.
    static func initRepo(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try run(path, ["init", "-q", "-b", "main"])
    }

    static func isGitRepo(_ path: String) -> Bool { (try? openRepo(path)) != nil }

    // --- Repository state ----------------------------------------------------

    static func headSha(_ repo: String) -> String? {
        guard let r = try? raw(repo, ["rev-parse", "--verify", "-q", "HEAD"]), r.ok else { return nil }
        let s = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    static func headIsUnborn(_ repo: String) -> Bool { headSha(repo) == nil }

    static func headIsDetached(_ repo: String) -> Bool {
        guard let r = try? raw(repo, ["symbolic-ref", "-q", "HEAD"]) else { return false }
        return !r.ok && headSha(repo) != nil
    }

    private static func existsInWorkdir(_ repo: String, _ path: String) -> Bool {
        let full = joinPath(repo, path)
        return fileExists(full) || (try? FileManager.default.destinationOfSymbolicLink(atPath: full)) != nil
    }

    private static func headPaths(_ repo: String) -> Set<String> {
        guard let r = try? raw(repo, ["ls-tree", "-r", "--name-only", "-z", "HEAD"]), r.ok else { return [] }
        return Set(nulList(r.out))
    }

    /// Every file currently in the working tree (tracked or not, excluding ignored).
    static func listRepoFiles(_ repo: String) throws -> [String] {
        let out = try run(repo, ["ls-files", "-z", "--cached", "--others", "--exclude-standard"])
        return Set(nulList(out)).filter { existsInWorkdir(repo, $0) }.sorted()
    }

    static func listChanges(_ repo: String) throws -> [ChangedFile] {
        let out = try run(repo, ["status", "--porcelain=v1", "-z", "-uall", "--no-renames", "--ignore-submodules"])
        let inHead = headPaths(repo)
        var changes: [ChangedFile] = []
        for entry in nulList(out) where entry.count > 3 {
            let code = entry.prefix(2)
            if code == "!!" { continue }
            let path = String(entry.dropFirst(3))
            let status: FileStatus
            if !existsInWorkdir(repo, path) {
                if !inHead.contains(path) { continue } // staged as new, then deleted again: nothing to commit
                status = .deleted
            } else if !inHead.contains(path) {
                status = .new
            } else {
                status = .modified
            }
            changes.append(ChangedFile(path: path, status: status))
        }
        return changes.sorted { $0.path < $1.path }
    }

    // --- History -------------------------------------------------------------

    /// Full repo commit history, newest first (like GitHub Desktop's History tab).
    static func listAllCommits(_ repo: String, maxCount: Int) throws -> [CommitInfo] {
        guard headSha(repo) != nil else { return [] }
        let fmt = "%H%x1f%an%x1f%ad%x1f%s%x1e"
        let out = try run(repo, ["log", "-n", String(maxCount), "--date=short", "--format=\(fmt)", "HEAD", "--"])
        return out.components(separatedBy: "\u{1e}").compactMap { rec in
            let f = rec.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\u{1f}")
            guard f.count >= 4, f[0].count >= 8 else { return nil }
            return CommitInfo(sha: f[0], shortSha: String(f[0].prefix(8)), author: f[1], date: f[2], subject: f[3])
        }
    }

    static func parentSha(_ repo: String, _ sha: String) throws -> String? {
        let r = try raw(repo, ["rev-parse", "--verify", "-q", "\(sha)^1"])
        let s = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.ok && !s.isEmpty ? s : nil
    }

    /// .mscz paths added/modified/deleted by `sha`, relative to its first parent
    /// (or to the empty tree, for a root commit).
    static func changedMsczFilesInCommit(_ repo: String, _ sha: String) throws -> [String] {
        let base = try parentSha(repo, sha) ?? emptyTree
        let out = try run(repo, ["diff", "--name-only", "-z", "--no-renames", base, sha, "--"])
        return Array(Set(nulList(out).filter { $0.hasSuffix(".mscz") })).sorted()
    }

    static func blobSha(_ repo: String, _ ref: String, _ path: String) -> String? {
        if ref == workingTreeRef {
            guard fileExists(joinPath(repo, path)) else { return nil }
            guard let r = try? raw(repo, ["hash-object", "--no-filters", "--", path]), r.ok else { return nil }
            return r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let r = try? raw(repo, ["rev-parse", "--verify", "-q", "\(ref):\(path)"]), r.ok else { return nil }
        let s = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    static func blobBytes(_ repo: String, _ ref: String, _ path: String) throws -> Data {
        if ref == workingTreeRef {
            do { return try Data(contentsOf: URL(fileURLWithPath: joinPath(repo, path))) } catch { throw GitError("\(error.localizedDescription)") }
        }
        let r = try raw(repo, ["cat-file", "blob", "\(ref):\(path)"])
        if !r.ok { throw GitError(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return r.stdout
    }

    // --- Committing ----------------------------------------------------------

    /// The configured user.name/user.email, or nil if git doesn't know who the
    /// user is yet (common on a fresh machine).
    static func getSignature(_ repo: String) -> (name: String, email: String)? {
        func cfg(_ k: String) -> String? {
            guard let r = try? raw(repo, ["config", "--get", k]), r.ok else { return nil }
            let s = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s
        }
        guard let n = cfg("user.name"), let e = cfg("user.email") else { return nil }
        return (n, e)
    }

    static func setIdentity(_ repo: String, name: String, email: String, global: Bool) throws {
        let scope = global ? ["--global"] : []
        try run(repo, ["config"] + scope + ["user.name", name])
        try run(repo, ["config"] + scope + ["user.email", email])
    }

    /// Commit exactly `paths` (new, modified, or deleted) and nothing else,
    /// returning the new commit's sha. Anything that was staged by some other
    /// tool but isn't in `paths` is reset out of the index first, so it
    /// doesn't silently ride along.
    static func commitPaths(_ repo: String, _ paths: [String], message: String) throws -> String {
        if paths.isEmpty { throw GitError("No files selected to commit.") }
        guard getSignature(repo) != nil else { throw GitError("No git identity configured (user.name / user.email).") }
        let selected = Set(paths)
        let staged = nulList(try run(repo, ["diff", "--cached", "--name-only", "-z", "--no-renames"])).filter { !selected.contains($0) }
        if !staged.isEmpty {
            try run(repo, ["reset", "-q", "--pathspec-from-file=-", "--pathspec-file-nul"], input: nulInput(staged))
        }
        try run(repo, ["add", "-A", "--pathspec-from-file=-", "--pathspec-file-nul"], input: nulInput(paths))
        let staging = try raw(repo, ["diff", "--cached", "--quiet"])
        if staging.status == 0 { throw GitError("The selected files have no changes to commit.") }
        try run(repo, ["commit", "-q", "--no-verify", "-F", "-"], input: Data(message.utf8))
        return headSha(repo) ?? ""
    }

    /// Throw away uncommitted changes to `paths`: restore them to their HEAD
    /// version, or delete them if they're new since HEAD. Irreversible.
    static func discardChanges(_ repo: String, _ paths: [String]) throws {
        let inHead = headPaths(repo)
        let tracked = paths.filter { inHead.contains($0) }
        for p in paths where !inHead.contains(p) {
            _ = try? raw(repo, ["rm", "--cached", "-q", "--ignore-unmatch", "--", p])
            let full = joinPath(repo, p)
            if fileExists(full) { try? FileManager.default.removeItem(atPath: full) }
        }
        if !tracked.isEmpty {
            try run(repo, ["restore", "--source=HEAD", "--staged", "--worktree", "--pathspec-from-file=-", "--pathspec-file-nul"], input: nulInput(tracked))
        }
    }

    // --- Branches and remotes ------------------------------------------------

    static func currentBranchName(_ repo: String) -> String {
        if let r = try? raw(repo, ["symbolic-ref", "-q", "--short", "HEAD"]), r.ok {
            return r.out.trimmingCharacters(in: .whitespacesAndNewlines) // works even when HEAD is unborn
        }
        return headSha(repo).map { String($0.prefix(8)) } ?? ""
    }

    /// Local branches, followed by remote branches that don't have a local branch
    /// of the same name yet (selecting one of those creates it).
    static func listBranches(_ repo: String) throws -> [BranchInfo] {
        let current = currentBranchName(repo)
        let local = lines(try run(repo, ["for-each-ref", "--format=%(refname:short)", "refs/heads"])).sorted()
        var branches = local.map { BranchInfo(name: $0, isRemote: false, isCurrent: $0 == current) }
        let remote = lines(try run(repo, ["for-each-ref", "--format=%(refname:short)", "refs/remotes"])).sorted()
        for name in remote {
            if name.hasSuffix("/HEAD") || !name.contains("/") { continue }
            let short = String(name[name.index(after: name.firstIndex(of: "/")!)...])
            if !local.contains(short) { branches.append(BranchInfo(name: name, isRemote: true, isCurrent: false)) }
        }
        if headIsUnborn(repo) && !local.contains(current) {
            branches.insert(BranchInfo(name: current, isRemote: false, isCurrent: true), at: 0)
        }
        return branches
    }

    /// Create a branch at the current commit and switch to it. Uncommitted changes
    /// are carried over to the new branch, as with `git switch -c`.
    static func createBranch(_ repo: String, _ rawName: String) throws {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let validName = try !name.isEmpty && raw(repo, ["check-ref-format", "--branch", name]).ok
        if !validName {
            throw GitError("'\(name)' is not a valid branch name.")
        }
        if try raw(repo, ["show-ref", "--verify", "-q", "refs/heads/\(name)"]).ok {
            throw GitError("A branch named '\(name)' already exists.")
        }
        if headIsUnborn(repo) {
            // Nothing to branch from yet; just rename the branch-to-be.
            try run(repo, ["symbolic-ref", "HEAD", "refs/heads/\(name)"])
            return
        }
        try run(repo, ["switch", "-q", "-c", name])
    }

    /// Switch to `branch`, creating a local tracking branch first if it's a
    /// remote-only one. git refuses (rather than clobbering) if uncommitted
    /// changes would be overwritten.
    static func checkoutBranch(_ repo: String, _ branch: BranchInfo) throws {
        let local = branch.isRemote ? String(branch.name[branch.name.index(after: branch.name.firstIndex(of: "/") ?? branch.name.startIndex)...]) : branch.name
        if headIsUnborn(repo) {
            try run(repo, ["symbolic-ref", "HEAD", "refs/heads/\(local)"])
            return
        }
        do {
            if branch.isRemote {
                try run(repo, ["switch", "-q", "-c", local, "--track", branch.name])
            } else {
                try run(repo, ["switch", "-q", local])
            }
        } catch let e as GitError {
            throw GitError("Can't switch to '\(local)': \(e.message)\nCommit or discard your changes to the conflicting files first.")
        }
    }

    static func listRemotes(_ repo: String) throws -> [(name: String, url: String)] {
        let r = try raw(repo, ["config", "--get-regexp", #"^remote\..*\.url$"#])
        var out: [(String, String)] = []
        for line in lines(r.out) {
            guard let sp = line.firstIndex(of: " ") else { continue }
            var key = String(line[..<sp])
            let url = String(line[line.index(after: sp)...])
            key = String(key.dropFirst("remote.".count).dropLast(".url".count))
            out.append((key, url))
        }
        return out
    }

    static func setRemote(_ repo: String, name: String, url: String) throws {
        if try listRemotes(repo).contains(where: { $0.name == name }) {
            try run(repo, ["remote", "set-url", name, url])
        } else {
            try run(repo, ["remote", "add", name, url])
        }
    }

    private static func upstreamOf(_ repo: String, _ local: String) -> String? {
        guard let r = try? raw(repo, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "\(local)@{upstream}"]), r.ok else { return nil }
        let s = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// The remote to publish/fetch from: the current branch's upstream remote,
    /// else 'origin', else whichever remote exists.
    static func defaultRemote(_ repo: String) -> String? {
        guard let remotes = try? listRemotes(repo), !remotes.isEmpty else { return nil }
        if !headIsUnborn(repo) && !headIsDetached(repo),
           let up = upstreamOf(repo, currentBranchName(repo)), let slash = up.firstIndex(of: "/") {
            return String(up[..<slash])
        }
        if remotes.contains(where: { $0.name == "origin" }) { return "origin" }
        return remotes.map(\.name).sorted().first
    }

    static func syncStatus(_ repo: String) throws -> SyncStatus {
        let branch = currentBranchName(repo)
        let hasRemote = !((try? listRemotes(repo)) ?? []).isEmpty
        let unborn = headIsUnborn(repo)
        if unborn || headIsDetached(repo) {
            return SyncStatus(branch: branch, isUnborn: unborn, hasRemote: hasRemote)
        }
        guard let up = upstreamOf(repo, branch) else {
            return SyncStatus(branch: branch, hasRemote: hasRemote)
        }
        let counts = try run(repo, ["rev-list", "--left-right", "--count", "\(branch)...\(up)"])
            .split(whereSeparator: { $0 == "\t" || $0 == " " || $0 == "\n" }).compactMap { Int($0) }
        return SyncStatus(branch: branch, hasRemote: hasRemote, upstream: up, ahead: counts.first ?? 0, behind: counts.count > 1 ? counts[1] : 0)
    }
}
