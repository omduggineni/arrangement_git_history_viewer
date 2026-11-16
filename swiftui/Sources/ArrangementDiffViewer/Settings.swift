import Foundation

/// User settings: where to find the external programs this app runs (git, the
/// MuseScore CLI, and the Python diff engine), and how to launch them.
///
/// Each tool resolves, in order, to: the path saved on the Settings page, the
/// tool's environment variable (GIT_PATH / MSCORE_PATH / PYTHON_PATH), the
/// copy bundled with the app (git only), or an auto-detected installed copy.
/// Saving the default path (or nothing) stores no override.
struct Tool: Equatable {
    var key: String
    var name: String
    var envVar: String
    var description: String
    /// Bare names are looked up on PATH; anything else has ~ and $VARS expanded and is globbed.
    var candidates: [String]
    /// executable names to prefer inside a macOS .app bundle
    var preferredNames: [String]
    /// arguments used by the "Test" button
    var versionArgs: [String]
}

enum Settings {
    static let git = Tool(
        key: "git_path", name: "Git", envVar: "GIT_PATH",
        description: "Used for all git operations: status, commits, branches, history, clone, fetch, push and pull. Choose another here to use your own git setup instead.",
        // Before /usr/bin/git: without the Xcode Command Line Tools installed,
        // macOS's /usr/bin/git is a stub that pops up an install dialog.
        candidates: ["/opt/homebrew/bin/git", "/usr/local/bin/git", "git", "/usr/bin/git"],
        preferredNames: ["git"], versionArgs: ["--version"])

    static let mscore = Tool(
        key: "mscore_path", name: "MuseScore", envVar: "MSCORE_PATH",
        description: "Used to convert .mscz scores to MusicXML so they can be compared.",
        candidates: [
            "mscore",
            "/Applications/MuseScore*.app/Contents/MacOS/mscore*",
            "~/Applications/MuseScore*.app/Contents/MacOS/mscore*",
            "/opt/homebrew/bin/mscore",
            "/usr/local/bin/mscore",
        ],
        preferredNames: ["mscore", "mscore4portable", "MuseScore4", "MuseScore"], versionArgs: ["--version"])

    /// The one part of the app that isn't Swift: musicdiff and music21 are Python
    /// libraries, so notation diffs run in a small Python sidecar (sidecar/diff_sidecar.py).
    static let python = Tool(
        key: "python_path", name: "Python (diff engine)", envVar: "PYTHON_PATH",
        description: "A Python with musicdiff, music21, converter21 and verovio installed. Used to compute notation diffs.",
        candidates: [
            "$ADV_ROOT/.venv/bin/python3",
            "$ADV_ROOT/../arrangement_diff_viewer_py/.venv/bin/python3",
            "$ADV_ROOT/../arrangement_git_history_viewer/.venv-gtk/bin/python3",
            "$ADV_ROOT/../../arrangement_git_history_viewer/.venv/bin/python3",
            "$ADV_ROOT/../../arrangement_git_history_viewer/.venv-gtk/bin/python3",
            "python3",
        ],
        preferredNames: ["python3", "python"],
        versionArgs: ["-c", "import musicdiff, music21, converter21, verovio; print('Python', __import__('sys').version.split()[0], '| musicdiff', musicdiff.__version__ if hasattr(musicdiff,'__version__') else 'ok', '| verovio', verovio.__version__ if hasattr(verovio,'__version__') else 'ok')"])

    static let all = [git, mscore, python]

    /// The tools shown on the Settings page. Inside an app bundle with a frozen
    /// diff engine, the Python entry is hidden.
    static var tools: [Tool] {
        all.filter { !($0 == python && Diffing.bundledSidecar() != nil) }
    }

    private static var file: String { joinPath(AppPaths.dataDir, "settings.json") }

    private static func load() -> [String: Any] {
        guard let d = FileManager.default.contents(atPath: file),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }

    private static func save(_ data: [String: Any]) throws {
        try FileManager.default.createDirectory(atPath: AppPaths.dataDir, withIntermediateDirectories: true)
        let d = try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
        try d.write(to: URL(fileURLWithPath: file))
    }

    static func savedPath(_ tool: Tool) -> String? {
        (load()[tool.key] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Store `value` as this tool's location. Blank, or the same as what would be
    /// found anyway, clears the override instead.
    static func savePath(_ tool: Tool, _ value: String) throws {
        let value = normalize(value, tool: tool)
        var data = load()
        if value.isEmpty || value == defaultPath(tool).path {
            data.removeValue(forKey: tool.key)
        } else {
            data[tool.key] = value
        }
        try save(data)
    }

    static func isExecutable(_ path: String) -> Bool {
        if path.isEmpty { return false }
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &d) && !d.boolValue && FileManager.default.isExecutableFile(atPath: path)
    }

    private static func expandHome(_ s: String) -> String {
        if s.hasPrefix("~/") { return joinPath(AppPaths.home, String(s.dropFirst(2))) }
        if s == "~" { return AppPaths.home }
        return s
    }

    /// Expand ~ and, for a macOS .app bundle (which file pickers treat as a single
    /// file), point at the executable inside it.
    static func normalize(_ value: String, tool: Tool?) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return "" }
        var path = expandHome(value)
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix(".app"), isDirectory(path), let exe = bundleExecutable(path, preferred: tool?.preferredNames ?? []) {
            return exe
        }
        return path
    }

    private static func bundleExecutable(_ bundle: String, preferred: [String]) -> String? {
        let macos = joinPath(bundle, "Contents", "MacOS")
        for name in preferred {
            let p = joinPath(macos, name)
            if isExecutable(p) { return p }
        }
        if let b = Bundle(path: bundle), let exe = b.executablePath, isExecutable(exe) { return exe }
        // otherwise the first real program in the bundle (not a helper like crashpad_handler)
        let found = (try? FileManager.default.contentsOfDirectory(atPath: macos))?.sorted()
            .first { !$0.lowercased().contains("crashpad") && isExecutable(joinPath(macos, $0)) }
        return found.map { joinPath(macos, $0) }
    }

    private static func which(_ name: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in path.split(separator: ":") {
            let p = joinPath(String(dir), name)
            if isExecutable(p) { return p }
        }
        return nil
    }

    static func glob(_ pattern: String) -> [String] {
        var g = glob_t()
        defer { globfree(&g) }
        guard Darwin.glob(pattern, 0, nil, &g) == 0 else { return [] }
        return (0..<Int(g.gl_pathc)).compactMap { g.gl_pathv[$0].map { String(cString: $0) } }
    }

    /// An installed copy of this tool, if one can be found.
    static func detect(_ tool: Tool) -> String? {
        for cand in tool.candidates {
            if !cand.contains("/") {
                if let f = which(cand) { return f }
                continue
            }
            var pattern = expandHome(cand)
            if pattern.contains("$ADV_ROOT") {
                pattern = pattern.replacingOccurrences(of: "$ADV_ROOT", with: AppPaths.projectRoot)
            }
            if pattern.contains("$") { continue } // an unset environment variable
            // newest version first
            if let m = glob(pattern).map({ URL(fileURLWithPath: $0).standardized.path }).sorted().reversed().first(where: isExecutable) { return m }
        }
        return nil
    }

    /// The path used when nothing is saved, and where it came from.
    static func defaultPath(_ tool: Tool) -> (path: String?, source: String) {
        if let v = ProcessInfo.processInfo.environment[tool.envVar], isExecutable(v) {
            return (v, "from $\(tool.envVar)")
        }
        if tool == git, isExecutable(bundledGit) { return (bundledGit, "bundled") }
        if tool == mscore, isExecutable(bundledMuseScore) { return (bundledMuseScore, "bundled") }
        if let f = detect(tool) { return (f, "auto-detected") }
        return (nil, "not found")
    }

    /// The path to run for this tool, and where it came from. Re-resolved on every
    /// call (it's only a few stats), so changes apply immediately.
    static func resolve(_ tool: Tool) -> (path: String?, source: String) {
        if let s = savedPath(tool) { return (s, "custom") }
        return defaultPath(tool)
    }

    static func pathFor(_ tool: Tool) -> String? { resolve(tool).path }

    /// MuseScore.app shipped inside the app by `make app-with-bundled-musescore`.
    static var bundledMuseScore: String { joinPath(AppPaths.projectRoot, "MuseScore.app", "Contents", "MacOS", "mscore") }

    static var bundledGitDir: String { joinPath(AppPaths.projectRoot, "vendor", "git") }
    static var bundledGit: String { joinPath(bundledGitDir, "bin", "git") }

    /// Environment for running one of these programs from this app. A bundled
    /// git is a relocatable build (dugite-native) that has to be told where its
    /// own files are.
    static func childEnv(_ exe: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if isExecutable(bundledGit), canonicalPath(exe) == canonicalPath(bundledGit) {
            let root = bundledGitDir
            env["GIT_EXEC_PATH"] = joinPath(root, "libexec/git-core")
            if env["GIT_CONFIG_SYSTEM"] == nil { env["GIT_CONFIG_SYSTEM"] = joinPath(root, "etc/gitconfig") }
            env["GIT_TEMPLATE_DIR"] = joinPath(root, "share/git-core/templates")
        }
        return env
    }

    /// Run `<path> <version args>`; return its first line of output, or an explanation.
    static func version(_ tool: Tool, path: String) -> Result<String, ProcError> {
        if !isExecutable(path) { return .failure(ProcError(message: "No executable file at this path.")) }
        // MuseScore's CLI starts its whole GUI runtime even for --version, and is
        // unreliable when run concurrently with a conversion.
        let lock: NSLock? = tool == mscore ? Convert.mscoreLock : nil
        lock?.lock()
        defer { lock?.unlock() }
        do {
            let r = try runProcess(path, tool.versionArgs, env: childEnv(path), timeout: 60)
            guard let code = r.status else { return .failure(ProcError(message: "Didn't respond within 60s.")) }
            let text = r.out.contains(where: { !$0.isWhitespace }) ? r.out : r.stderr
            let lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
            let first = lines.first.flatMap { $0.isEmpty ? nil : $0 }
            if code != 0 {
                return .failure(ProcError(message: "Exited with code \(code)" + (lines.last.flatMap { $0.isEmpty ? nil : ": \($0)" } ?? ".")))
            }
            return .success(first ?? "OK")
        } catch {
            return .failure(ProcError(message: "\(error)"))
        }
    }
}
