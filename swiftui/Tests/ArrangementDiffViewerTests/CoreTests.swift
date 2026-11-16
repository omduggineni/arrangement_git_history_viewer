import CryptoKit
import XCTest
@testable import ArrangementDiffViewer

/// git_ops / remote_ops / cache / settings against real throwaway repos
/// (the same checks as the Rust app's tests/core.rs).
final class CoreTests: XCTestCase {
    var tmp = ""

    override func setUpWithError() throws {
        let raw = NSTemporaryDirectory() + "adv-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: raw, withIntermediateDirectories: true)
        tmp = canonicalPath(raw)
        setenv("ADV_CONFIG_DIR", joinPath(tmp, "config"), 1)
        setenv("ADV_CACHE_DIR", joinPath(tmp, "cache"), 1)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: tmp)
    }

    func newRepo(_ name: String = "repo") throws -> String {
        let p = joinPath(tmp, name)
        try GitOps.initRepo(p)
        try GitOps.setIdentity(p, name: "Tester", email: "t@example.com", global: false)
        return p
    }

    func write(_ repo: String, _ path: String, _ text: String) throws {
        let full = joinPath(repo, path)
        try FileManager.default.createDirectory(atPath: parentPath(full), withIntermediateDirectories: true)
        try text.write(toFile: full, atomically: true, encoding: .utf8)
    }

    @discardableResult
    func commit(_ repo: String, _ paths: [String], _ msg: String = "msg") throws -> String {
        try GitOps.commitPaths(repo, paths, message: msg)
    }

    func shell(_ repo: String, _ args: String...) throws {
        let r = try GitOps.raw(repo, args)
        XCTAssertEqual(r.status, 0, r.stderr)
    }

    // --- local git --------------------------------------------------------------

    func testInitAndOpen() throws {
        let repo = try newRepo()
        try FileManager.default.createDirectory(atPath: joinPath(repo, "sub"), withIntermediateDirectories: true)
        XCTAssertEqual(canonicalPath(try GitOps.openRepo(repo)), repo)
        XCTAssertEqual(canonicalPath(try GitOps.openRepo(joinPath(repo, "sub"))), repo) // discovers upward
        XCTAssertTrue(GitOps.isGitRepo(repo))
        XCTAssertFalse(GitOps.isGitRepo(tmp))
        XCTAssertEqual(GitOps.currentBranchName(repo), "main")
        XCTAssertTrue(GitOps.headIsUnborn(repo))
        XCTAssertEqual(try GitOps.listBranches(repo).map(\.name), ["main"])
        XCTAssertEqual(try GitOps.listAllCommits(repo, maxCount: 10).count, 0)
        let bare = joinPath(tmp, "bare.git")
        try GitOps.run(tmp, ["init", "-q", "--bare", bare])
        XCTAssertThrowsError(try GitOps.openRepo(bare))
    }

    func testChangesStatusesAndSpecialNames() throws {
        let repo = try newRepo()
        try write(repo, "a.mscz", "1")
        try write(repo, "Song [v2].mscz", "1")
        try write(repo, "Song v.mscz", "1")
        try write(repo, "sub dir/b.txt", "1")
        try write(repo, ".gitignore", "ignored.txt\n")
        try write(repo, "ignored.txt", "x")
        var changes = try GitOps.listChanges(repo)
        XCTAssertEqual(changes.map(\.path), [".gitignore", "Song [v2].mscz", "Song v.mscz", "a.mscz", "sub dir/b.txt"])
        XCTAssertTrue(changes.allSatisfy { $0.status == .new })
        try commit(repo, changes.map(\.path))
        XCTAssertEqual(try GitOps.listChanges(repo), [])
        try write(repo, "a.mscz", "2")
        try FileManager.default.removeItem(atPath: joinPath(repo, "sub dir/b.txt"))
        try write(repo, "c.mscz", "new")
        changes = try GitOps.listChanges(repo)
        XCTAssertEqual(changes.map { "\($0.path):\($0.status.rawValue)" }, ["a.mscz:modified", "c.mscz:new", "sub dir/b.txt:deleted"])
        XCTAssertTrue(changes[0].isScore)
        let files = try GitOps.listRepoFiles(repo)
        XCTAssertTrue(files.contains("Song [v2].mscz") && files.contains("c.mscz"))
        XCTAssertFalse(files.contains("sub dir/b.txt") || files.contains("ignored.txt"))
    }

    func testCommitOnlySelectedAndStagedElsewhereDoesNotRideAlong() throws {
        let repo = try newRepo()
        try write(repo, "a.mscz", "1"); try write(repo, "b.mscz", "1")
        try commit(repo, ["a.mscz", "b.mscz"], "first\n\nbody text\n")
        try write(repo, "a.mscz", "2"); try write(repo, "b.mscz", "2"); try write(repo, "n.mscz", "n")
        try shell(repo, "add", "b.mscz", "n.mscz") // staged by some other tool
        let sha = try commit(repo, ["a.mscz"], "only a")
        XCTAssertEqual(sha.count, 40)
        XCTAssertEqual(try GitOps.changedMsczFilesInCommit(repo, sha), ["a.mscz"])
        XCTAssertEqual(try GitOps.listChanges(repo).map(\.path), ["b.mscz", "n.mscz"])
        let log = try GitOps.listAllCommits(repo, maxCount: 10)
        XCTAssertEqual(log.map(\.subject), ["only a", "first"])
        XCTAssertEqual(log[0].shortSha, String(sha.prefix(8)))
        XCTAssertEqual(try GitOps.run(repo, ["log", "-1", "--format=%B", "HEAD~1"]).trimmingCharacters(in: .whitespacesAndNewlines), "first\n\nbody text")
        // deletions are committable too
        try FileManager.default.removeItem(atPath: joinPath(repo, "b.mscz"))
        let d = try commit(repo, ["b.mscz"], "drop b")
        XCTAssertEqual(try GitOps.changedMsczFilesInCommit(repo, d), ["b.mscz"])
        XCTAssertThrowsError(try commit(repo, [], "nothing"))
    }

    func testNoChangesAndMissingIdentity() throws {
        let repo = try newRepo()
        try write(repo, "a.mscz", "1")
        try commit(repo, ["a.mscz"])
        XCTAssertThrowsError(try commit(repo, ["a.mscz"])) { XCTAssertTrue("\($0)".contains("no changes")) }
    }

    func testDiscard() throws {
        let repo = try newRepo()
        try write(repo, "Song [v2].mscz", "orig"); try write(repo, "Song v.mscz", "orig")
        try commit(repo, ["Song [v2].mscz", "Song v.mscz"])
        try write(repo, "Song [v2].mscz", "edited"); try write(repo, "Song v.mscz", "edited"); try write(repo, "new.mscz", "n")
        try shell(repo, "add", "new.mscz")
        try GitOps.discardChanges(repo, ["Song [v2].mscz", "new.mscz"])
        XCTAssertEqual(try String(contentsOfFile: joinPath(repo, "Song [v2].mscz"), encoding: .utf8), "orig")
        // a path with glob characters must not clobber its look-alike
        XCTAssertEqual(try String(contentsOfFile: joinPath(repo, "Song v.mscz"), encoding: .utf8), "edited")
        XCTAssertFalse(fileExists(joinPath(repo, "new.mscz")))
        XCTAssertEqual(try GitOps.listChanges(repo).map(\.path), ["Song v.mscz"])
        try FileManager.default.removeItem(atPath: joinPath(repo, "Song v.mscz"))
        try GitOps.discardChanges(repo, ["Song v.mscz"])
        XCTAssertEqual(try String(contentsOfFile: joinPath(repo, "Song v.mscz"), encoding: .utf8), "orig")
    }

    func testHistoryBlobsAndWorkingTree() throws {
        let repo = try newRepo()
        try write(repo, "a.mscz", "one")
        let c1 = try commit(repo, ["a.mscz"], "c1")
        try write(repo, "a.mscz", "two")
        let c2 = try commit(repo, ["a.mscz"], "c2")
        XCTAssertNil(try GitOps.parentSha(repo, c1))
        XCTAssertEqual(try GitOps.parentSha(repo, c2), c1)
        XCTAssertEqual(try GitOps.changedMsczFilesInCommit(repo, c1), ["a.mscz"]) // root commit
        let b1 = GitOps.blobSha(repo, c1, "a.mscz")
        XCTAssertNotNil(b1)
        XCTAssertNotEqual(b1, GitOps.blobSha(repo, c2, "a.mscz"))
        XCTAssertEqual(GitOps.blobSha(repo, "HEAD", "a.mscz"), GitOps.blobSha(repo, workingTreeRef, "a.mscz"))
        XCTAssertNil(GitOps.blobSha(repo, c1, "nope.mscz"))
        XCTAssertEqual(try GitOps.blobBytes(repo, c1, "a.mscz"), Data("one".utf8))
        XCTAssertEqual(try GitOps.blobBytes(repo, workingTreeRef, "a.mscz"), Data("two".utf8))
        // blob shas match what `git hash-object` says (cache keys stay compatible)
        XCTAssertEqual(b1, try GitOps.run(repo, ["rev-parse", "\(c1):a.mscz"]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testBranches() throws {
        let repo = try newRepo()
        try GitOps.createBranch(repo, "feature") // unborn: just renames the branch-to-be
        XCTAssertEqual(GitOps.currentBranchName(repo), "feature")
        try write(repo, "a.mscz", "1")
        try commit(repo, ["a.mscz"])
        try GitOps.createBranch(repo, "other")
        XCTAssertThrowsError(try GitOps.createBranch(repo, "other"))
        XCTAssertThrowsError(try GitOps.createBranch(repo, "bad name"))
        try write(repo, "dirty.mscz", "carried over")
        try GitOps.checkoutBranch(repo, BranchInfo(name: "feature", isRemote: false, isCurrent: false))
        XCTAssertEqual(GitOps.currentBranchName(repo), "feature")
        XCTAssertEqual(try GitOps.listBranches(repo).map { "\($0.name):\($0.isCurrent)" }, ["feature:true", "other:false"])
        XCTAssertEqual(try GitOps.listChanges(repo).map(\.path), ["dirty.mscz"])
    }

    func testCheckoutRefusesToClobber() throws {
        let repo = try newRepo()
        try write(repo, "a.mscz", "1")
        try commit(repo, ["a.mscz"])
        try GitOps.createBranch(repo, "other")
        try write(repo, "a.mscz", "other-side")
        try commit(repo, ["a.mscz"], "on other")
        try GitOps.checkoutBranch(repo, BranchInfo(name: "main", isRemote: false, isCurrent: false))
        try GitOps.checkoutBranch(repo, BranchInfo(name: "other", isRemote: false, isCurrent: false))
        try GitOps.checkoutBranch(repo, BranchInfo(name: "main", isRemote: false, isCurrent: false))
        try write(repo, "a.mscz", "local edit")
        XCTAssertThrowsError(try GitOps.checkoutBranch(repo, BranchInfo(name: "other", isRemote: false, isCurrent: false))) {
            XCTAssertTrue("\($0)".contains("Can't switch"))
        }
        XCTAssertEqual(GitOps.currentBranchName(repo), "main")
        XCTAssertEqual(try String(contentsOfFile: joinPath(repo, "a.mscz"), encoding: .utf8), "local edit")
    }

    // --- remotes -----------------------------------------------------------------

    func testRemoteLifecyclePushFetchPullClone() throws {
        let bare = joinPath(tmp, "origin.git")
        try GitOps.run(tmp, ["init", "-q", "--bare", "-b", "main", bare])
        let repo = try newRepo("work")
        XCTAssertFalse(try GitOps.syncStatus(repo).hasRemote)
        try write(repo, "a.mscz", "1")
        try commit(repo, ["a.mscz"], "c1")
        try GitOps.setRemote(repo, name: "origin", url: bare)
        try GitOps.setRemote(repo, name: "origin", url: bare) // update path
        XCTAssertEqual(try GitOps.listRemotes(repo).map { "\($0.name)=\($0.url)" }, ["origin=\(bare)"])
        XCTAssertEqual(GitOps.defaultRemote(repo), "origin")
        var s = try GitOps.syncStatus(repo)
        XCTAssertTrue(s.hasRemote); XCTAssertNil(s.upstream)
        try RemoteOps.push(repo, remote: "origin", branch: "main", setUpstream: true)
        s = try GitOps.syncStatus(repo)
        XCTAssertEqual(s.upstream, "origin/main"); XCTAssertEqual(s.ahead, 0); XCTAssertEqual(s.behind, 0)
        try write(repo, "a.mscz", "2")
        try commit(repo, ["a.mscz"], "c2")
        s = try GitOps.syncStatus(repo)
        XCTAssertEqual(s.ahead, 1); XCTAssertEqual(s.behind, 0)
        try RemoteOps.push(repo, remote: "origin", branch: "main", setUpstream: false)

        let clone = joinPath(tmp, "clone")
        try RemoteOps.clone(url: bare, dest: clone)
        XCTAssertThrowsError(try RemoteOps.clone(url: bare, dest: clone)) // not empty any more
        try GitOps.setIdentity(clone, name: "Other", email: "o@example.com", global: false)
        try write(clone, "a.mscz", "3")
        try commit(clone, ["a.mscz"], "c3 from clone")
        try RemoteOps.push(clone, remote: "origin", branch: "main", setUpstream: false)

        try RemoteOps.fetch(repo, remote: "origin")
        s = try GitOps.syncStatus(repo)
        XCTAssertEqual(s.behind, 1); XCTAssertEqual(s.ahead, 0)
        try RemoteOps.pullFFOnly(repo)
        XCTAssertEqual(try GitOps.syncStatus(repo).behind, 0)
        XCTAssertEqual(try GitOps.listAllCommits(repo, maxCount: 10).map(\.subject), ["c3 from clone", "c2", "c1"])

        // diverge: one commit each side -> ff-only pull is refused with an explanation
        try write(repo, "a.mscz", "mine"); try commit(repo, ["a.mscz"], "mine")
        try write(clone, "a.mscz", "theirs"); try commit(clone, ["a.mscz"], "theirs")
        try RemoteOps.push(clone, remote: "origin", branch: "main", setUpstream: false)
        try RemoteOps.fetch(repo, remote: "origin")
        s = try GitOps.syncStatus(repo)
        XCTAssertEqual(s.ahead, 1); XCTAssertEqual(s.behind, 1)
        XCTAssertThrowsError(try RemoteOps.pullFFOnly(repo))
        XCTAssertThrowsError(try RemoteOps.push(repo, remote: "origin", branch: "main", setUpstream: false)) {
            XCTAssertTrue("\($0)".contains("Pull them first"), "\($0)")
        }
    }

    func testRemoteOnlyBranchCheckout() throws {
        let bare = joinPath(tmp, "origin.git")
        try GitOps.run(tmp, ["init", "-q", "--bare", "-b", "main", bare])
        let a = try newRepo("a")
        try write(a, "x.mscz", "1")
        try commit(a, ["x.mscz"])
        try GitOps.createBranch(a, "feature")
        try GitOps.setRemote(a, name: "origin", url: bare)
        try RemoteOps.push(a, remote: "origin", branch: "main", setUpstream: true)
        try RemoteOps.push(a, remote: "origin", branch: "feature", setUpstream: true)
        let b = joinPath(tmp, "b")
        try RemoteOps.clone(url: bare, dest: b)
        let names = try GitOps.listBranches(b)
        XCTAssertTrue(names.contains { $0.name == "origin/feature" && $0.isRemote })
        try GitOps.checkoutBranch(b, BranchInfo(name: "origin/feature", isRemote: true, isCurrent: false))
        XCTAssertEqual(GitOps.currentBranchName(b), "feature")
        XCTAssertEqual(try GitOps.syncStatus(b).upstream, "origin/feature")
        XCTAssertFalse(try GitOps.listBranches(b).contains { $0.isRemote && $0.name == "origin/feature" })
    }

    func testRepoNameFromURL() {
        XCTAssertEqual(RemoteOps.repoName(fromURL: "https://github.com/you/scores.git"), "scores")
        XCTAssertEqual(RemoteOps.repoName(fromURL: "git@github.com:you/scores.git"), "scores")
        XCTAssertEqual(RemoteOps.repoName(fromURL: "git@github.com:scores"), "scores")
        XCTAssertEqual(RemoteOps.repoName(fromURL: "https://host/a/b/"), "b")
        XCTAssertEqual(RemoteOps.repoName(fromURL: ""), "repository")
    }

    // --- cache, settings, recents --------------------------------------------------

    func testCacheRootMatchesOtherPorts() {
        let repo = joinPath(tmp, "r")
        try? FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        let hex = SHA256.hash(data: Data(repo.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(Cache.cacheRoot(forRepo: repo), joinPath(AppPaths.cacheBase, String(hex.prefix(16))))
        let d = Cache.diffDir("/x", "aa", "bb", 65535)
        XCTAssertEqual(d, "/x/diffs/aa__bb__65535")
        try? FileManager.default.removeItem(atPath: "/x")
    }

    func testSettingsSaveClearsDefaultOverride() throws {
        let tool = Settings.mscore
        XCTAssertNil(Settings.savedPath(tool))
        let fake = joinPath(tmp, "fake-mscore")
        try "#!/bin/sh\necho 'MuseScore fake 1.0'\n".write(toFile: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake)
        try Settings.savePath(tool, fake)
        XCTAssertEqual(Settings.savedPath(tool), fake)
        XCTAssertEqual(Settings.resolve(tool).source, "custom")
        XCTAssertEqual(try Settings.version(tool, path: fake).get(), "MuseScore fake 1.0")
        if let d = Settings.defaultPath(tool).path {
            try Settings.savePath(tool, d)
            XCTAssertNil(Settings.savedPath(tool), "saving the default clears the override")
        }
        try Settings.savePath(tool, "")
        XCTAssertNil(Settings.savedPath(tool))
        XCTAssertThrowsError(try Settings.version(tool, path: "/nope").get())
        XCTAssertEqual(Settings.normalize("  ~/x  ", tool: nil), joinPath(AppPaths.home, "x"))
    }

    func testRecentsOrderAndPrune() throws {
        let a = joinPath(tmp, "a"), b = joinPath(tmp, "b")
        for p in [a, b] { try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true) }
        Recent.add(a); Recent.add(b); Recent.add(a)
        XCTAssertEqual(Recent.load(), [a, b])
        Recent.remove(b)
        XCTAssertEqual(Recent.load(), [a])
        try FileManager.default.removeItem(atPath: a)
        XCTAssertEqual(Recent.load(), [])
    }

    func testLoadCachedDiff() throws {
        let d = joinPath(tmp, "diff")
        try FileManager.default.createDirectory(atPath: joinPath(d, "excerpts"), withIntermediateDirectories: true)
        try "3".write(toFile: joinPath(d, "cost.txt"), atomically: true, encoding: .utf8)
        try "+ added\n- removed".write(toFile: joinPath(d, "text.txt"), atomically: true, encoding: .utf8)
        try #"[{"label":"Measures 2–4","start":2,"end":4,"has1":true,"has2":false}]"#.write(toFile: joinPath(d, "excerpts.json"), atomically: true, encoding: .utf8)
        let r = try Diffing.loadCached(d)
        XCTAssertEqual(r.cost, 3)
        XCTAssertEqual(r.excerpts.count, 1)
        XCTAssertEqual(r.excerpts[0].svg1, joinPath(d, "excerpts", "0_a.svg"))
        XCTAssertNil(r.excerpts[0].svg2)
        XCTAssertEqual(r.excerpts[0].label, "Measures 2–4")
    }

    func testProcessRunnerTimeoutAndStdin() throws {
        let r = try runProcess("/bin/cat", [], input: Data("hello".utf8))
        XCTAssertEqual(r.out, "hello")
        let t = try runProcess("/bin/sleep", ["5"], timeout: 0.3)
        XCTAssertNil(t.status)
    }

    // --- the real conversion + diff pipeline (skipped when the tools are absent) ----

    func testRealDiffPipelineIfToolsPresent() throws {
        guard Settings.pathFor(Settings.mscore) != nil, Settings.pathFor(Settings.python) != nil,
              let a = ProcessInfo.processInfo.environment["ADV_SAMPLE_A"], let b = ProcessInfo.processInfo.environment["ADV_SAMPLE_B"] else {
            throw XCTSkip("set ADV_SAMPLE_A / ADV_SAMPLE_B to two .mscz files to run this")
        }
        let repo = try newRepo()
        try FileManager.default.copyItem(atPath: a, toPath: joinPath(repo, "s.mscz"))
        try commit(repo, ["s.mscz"], "v1")
        try FileManager.default.removeItem(atPath: joinPath(repo, "s.mscz"))
        try FileManager.default.copyItem(atPath: b, toPath: joinPath(repo, "s.mscz"))
        let root = Cache.cacheRoot(forRepo: repo)
        let same = Diffing.diffVersions(repo: repo, cacheRoot: root, ref1: workingTreeRef, path1: "s.mscz", ref2: workingTreeRef, path2: "s.mscz") { _, _ in }
        XCTAssertNil(same.error); XCTAssertEqual(same.cost, 0)
        let diff = Diffing.diffVersions(repo: repo, cacheRoot: root, ref1: "HEAD", path1: "s.mscz", ref2: workingTreeRef, path2: "s.mscz") { _, _ in }
        XCTAssertNil(diff.error)
        XCTAssertGreaterThan(diff.cost, 0)
        let pages = try Cache.ensurePages(repo, root, workingTreeRef, "s.mscz")
        XCTAssertFalse(pages.isEmpty)
    }
}
