import Foundation

/// Network git operations (clone, fetch, push, pull). They run headless, so
/// anything that would wait for a password or host-key prompt is told to fail
/// immediately instead of hanging forever.
enum RemoteOps {
    static let hints: [([String], String)] = [
        (["could not read Username", "terminal prompts disabled", "Authentication failed"],
         "Signing in didn't complete. Try again and finish signing in in the window that opens, or use an SSH remote URL. To use credentials your own git has already saved, choose that git in Settings."),
        (["Host key verification failed"], "Connect to this host once with ssh in Terminal to accept its host key, then try again."),
        (["Permission denied (publickey)"], "Your SSH key wasn't accepted. Make sure it's added to ssh-agent and to your account on the server."),
        (["[rejected]", "fetch first", "non-fast-forward"], "The remote has commits you don't have yet. Pull them first, then push again."),
        (["Not possible to fast-forward", "diverging branches"],
         "Your branch and the remote branch have both gained commits. Score files can't be merged automatically, so this needs to be resolved with git in a terminal."),
    ]

    private static func run(_ args: [String], cwd: String, timeout: TimeInterval) throws {
        let exe = GitOps.gitExe()
        var env = GitOps.env(exe)
        env["GIT_SSH_COMMAND"] = env["GIT_SSH_COMMAND"] ?? "ssh -o BatchMode=yes"
        env["GIT_LITERAL_PATHSPECS"] = nil
        env["GIT_OPTIONAL_LOCKS"] = nil
        let r: ProcResult
        do {
            r = try runProcess(exe, args, cwd: cwd, env: env, timeout: timeout)
        } catch {
            throw GitError("The git command-line tool wasn't found. Install it, or set its location on the Settings page (the gear icon in the toolbar).")
        }
        guard let code = r.status else { throw GitError("git \(args[0]) timed out after \(Int(timeout))s.") }
        if code != 0 {
            var message = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.isEmpty { message = r.out.trimmingCharacters(in: .whitespacesAndNewlines) }
            if message.isEmpty { message = "git \(args[0]) failed" }
            if let hint = hints.first(where: { $0.0.contains(where: message.contains) }) {
                message += "\n\n\(hint.1)"
            }
            throw GitError(message)
        }
    }

    static func clone(url: String, dest: String) throws {
        if let items = try? FileManager.default.contentsOfDirectory(atPath: dest), !items.isEmpty {
            throw GitError("\(dest) already exists and isn't empty.")
        }
        let parent = parentPath(dest)
        try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        try run(["clone", "--", url, dest], cwd: parent, timeout: 1800)
    }

    static func fetch(_ repo: String, remote: String) throws {
        try run(["fetch", "--prune", remote], cwd: repo, timeout: 300)
    }

    static func push(_ repo: String, remote: String, branch: String, setUpstream: Bool) throws {
        var args = ["push"]
        if setUpstream { args.append("--set-upstream") }
        args += [remote, "refs/heads/\(branch):refs/heads/\(branch)"]
        try run(args, cwd: repo, timeout: 1800)
    }

    /// Fast-forward only: .mscz files are zip archives, so a real merge would just
    /// conflict on every changed score with no way to resolve it here.
    static func pullFFOnly(_ repo: String) throws {
        try run(["pull", "--ff-only"], cwd: repo, timeout: 1800)
    }

    static func repoName(fromURL url: String) -> String {
        var last = url.trimmingCharacters(in: CharacterSet(charactersIn: "/")).components(separatedBy: "/").last ?? ""
        last = last.components(separatedBy: ":").last ?? last
        if last.hasSuffix(".git") { last = String(last.dropLast(4)) }
        return last.isEmpty ? "repository" : last
    }
}
